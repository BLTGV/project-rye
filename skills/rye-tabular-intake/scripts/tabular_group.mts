#!/usr/bin/env node
import path from "node:path";
import { pathToFileURL } from "node:url";

import {
  CliError,
  getRequiredString,
  getString,
  runCli,
  type HelpSpec,
} from "./lib/cli.mts";
import {
  appendLineage,
  isMappedRecord,
  isObject,
  isSourceRow,
  mergeSourceSets,
  type MapRecordSpec,
  type MappedRecord,
  type MappingMetadata,
  type SourceRow,
} from "./lib/contracts.mts";
import { readNdjson, writeNdjson } from "./lib/ndjson.mts";

type GroupableRecord = SourceRow | MappedRecord;
type GroupKeyFunction = (input: GroupableRecord) => string | number | null | undefined | Promise<string | number | null | undefined>;
type ReduceFunction = (group: GroupContext) => MapRecordSpec | MapRecordSpec[] | null | Promise<MapRecordSpec | MapRecordSpec[] | null>;

interface GroupContext {
  key: string;
  records: GroupableRecord[];
  source_set: ReturnType<typeof mergeSourceSets>;
  first: (field: string) => unknown;
  distinct: (field: string) => unknown[];
  sum: (field: string | ((record: GroupableRecord) => unknown)) => number;
}

const help: HelpSpec = {
  name: "tabular_group.mts",
  summary: "Group source_row or mapped_record NDJSON input and reduce each group into mapped_record output.",
  usage: [
    "node skills/rye-tabular-intake/scripts/tabular_group.mts --module <path> [--input <ndjson>]",
  ],
  options: [
    { flag: "--module <path>", description: "TypeScript module exporting groupKey(input) and reduce(group)." },
    { flag: "--key-export <name>", description: "Named export for the grouping key function. Default: groupKey." },
    { flag: "--reduce-export <name>", description: "Named export for the reducer function. Default: reduce." },
    { flag: "--input <path>", description: "Optional NDJSON input file. Default: stdin." },
    { flag: "--mapping <name>", description: "Override the emitted mapping name." },
    { flag: "--help", description: "Print command help." },
  ],
  examples: [
    "node skills/rye-tabular-intake/scripts/tabular_extract.mts --input interests.xlsx | node skills/rye-tabular-intake/scripts/tabular_group.mts --module mappings/interests_to_opportunities.mts",
  ],
};

await runCli(help, async (args) => {
  const modulePath = path.resolve(getRequiredString(args, "module", help.name));
  const inputPath = getString(args, "input");
  const keyExport = getString(args, "key-export") ?? "groupKey";
  const reduceExport = getString(args, "reduce-export") ?? "reduce";
  const mappingOverride = getString(args, "mapping");
  const loaded = await loadGroupingModule(modulePath, keyExport, reduceExport);
  const mappingName =
    mappingOverride ??
    loaded.metadata.name ??
    path.basename(modulePath, path.extname(modulePath));

  const groups = new Map<string, GroupableRecord[]>();

  for await (const value of readNdjson(inputPath)) {
    if (!isSourceRow(value) && !isMappedRecord(value)) {
      throw new CliError(
        "unsupported_group_input",
        "tabular_group.mts accepts only source_row or mapped_record input.",
        `Received kind: ${isObject(value) && typeof value.kind === "string" ? value.kind : "unknown"}`,
        [`Run tabular_extract.mts first, or pipe from a prior tabular_map.mts command.`],
      );
    }

    const rawKey = await loaded.groupKey(value);
    if (rawKey === null || rawKey === undefined || String(rawKey).trim() === "") {
      continue;
    }

    const key = String(rawKey);
    const existing = groups.get(key) ?? [];
    existing.push(value);
    groups.set(key, existing);
  }

  for (const key of Array.from(groups.keys()).sort()) {
    const records = groups.get(key) as GroupableRecord[];
    const sourceSet = mergeSourceSets(records, key);
    const context = buildGroupContext(key, records, sourceSet);
    const reduced = await loaded.reduce(context);
    if (reduced === null) {
      continue;
    }

    const outputs = Array.isArray(reduced) ? reduced : [reduced];
    for (const output of outputs) {
      writeNdjson(buildMappedRecord(output, mappingName, key, records, sourceSet));
    }
  }
});

async function loadGroupingModule(
  modulePath: string,
  keyExport: string,
  reduceExport: string,
): Promise<{ metadata: MappingMetadata; groupKey: GroupKeyFunction; reduce: ReduceFunction }> {
  const loaded = (await import(pathToFileURL(modulePath).href)) as {
    mapping?: MappingMetadata;
    [key: string]: unknown;
  };

  const groupKey = loaded[keyExport];
  const reduce = loaded[reduceExport];

  if (typeof groupKey !== "function") {
    throw new CliError(
      "group_key_export_not_found",
      `No callable export named "${keyExport}" was found in ${modulePath}.`,
      `Expected a function like export function ${keyExport}(input) { ... }`,
      [`Check the module path.`, `Add the requested export, or pass --key-export with the correct name.`],
    );
  }

  if (typeof reduce !== "function") {
    throw new CliError(
      "group_reduce_export_not_found",
      `No callable export named "${reduceExport}" was found in ${modulePath}.`,
      `Expected a function like export function ${reduceExport}(group) { ... }`,
      [`Check the module path.`, `Add the requested export, or pass --reduce-export with the correct name.`],
    );
  }

  return {
    metadata: loaded.mapping ?? {},
    groupKey: groupKey as GroupKeyFunction,
    reduce: reduce as ReduceFunction,
  };
}

function buildGroupContext(
  key: string,
  records: GroupableRecord[],
  sourceSet: ReturnType<typeof mergeSourceSets>,
): GroupContext {
  return {
    key,
    records,
    source_set: sourceSet,
    first: (field) => firstValue(records, field),
    distinct: (field) => distinctValues(records, field),
    sum: (fieldOrGetter) => sumValues(records, fieldOrGetter),
  };
}

function buildMappedRecord(
  spec: MapRecordSpec,
  mappingName: string,
  groupKey: string,
  records: GroupableRecord[],
  sourceSet: ReturnType<typeof mergeSourceSets>,
): MappedRecord {
  if (!spec || typeof spec.destination_table !== "string" || !isObject(spec.record)) {
    throw new CliError(
      "invalid_group_output",
      "Grouped output must include destination_table and record.",
      "Each reducer result should be { destination_table, record, ... }.",
      [`Return null to drop a group.`, `Return an object or array of objects with destination_table and record.`],
    );
  }

  return {
    kind: "mapped_record",
    mapping: mappingName,
    destination_table: spec.destination_table,
    operation: spec.operation ?? "upsert",
    source_set: sourceSet,
    lineage: appendLineage(mergedLineage(records), `group:${mappingName}`),
    record: spec.record,
    meta: {
      ...(isObject(spec.meta) ? spec.meta : {}),
      group_key: groupKey,
      source_row_count: sourceSet.row_count,
    },
    issues: Array.isArray(spec.issues) ? spec.issues.filter((value): value is string => typeof value === "string") : [],
  };
}

function mergedLineage(records: GroupableRecord[]): string[] {
  return Array.from(new Set(records.flatMap((record) => record.lineage))).sort();
}

function firstValue(records: GroupableRecord[], field: string): unknown {
  for (const record of records) {
    const value = getRecordValue(record, field);
    if (value !== null && value !== undefined && value !== "") {
      return value;
    }
  }
  return null;
}

function distinctValues(records: GroupableRecord[], field: string): unknown[] {
  const values = new Map<string, unknown>();
  for (const record of records) {
    const value = getRecordValue(record, field);
    if (value === null || value === undefined || value === "") {
      continue;
    }
    values.set(JSON.stringify(value), value);
  }
  return Array.from(values.values()).sort((left, right) => String(left).localeCompare(String(right)));
}

function sumValues(records: GroupableRecord[], fieldOrGetter: string | ((record: GroupableRecord) => unknown)): number {
  return records.reduce((total, record) => {
    const value = typeof fieldOrGetter === "string" ? getRecordValue(record, fieldOrGetter) : fieldOrGetter(record);
    const parsed = Number.parseFloat(String(value ?? ""));
    return Number.isFinite(parsed) ? total + parsed : total;
  }, 0);
}

function getRecordValue(record: GroupableRecord, field: string): unknown {
  return record.kind === "source_row" ? record.row[field] : record.record[field];
}
