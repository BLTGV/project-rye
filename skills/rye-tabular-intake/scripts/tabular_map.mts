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
  type MapRecordSpec,
  type MappedRecord,
  type MappingMetadata,
  type TransformFunction,
} from "./lib/contracts.mts";
import { loadMappingConfig } from "./lib/mapping_config.mts";
import { readNdjson, writeNdjson } from "./lib/ndjson.mts";

const help: HelpSpec = {
  name: "tabular_map.mts",
  summary: "Apply a TypeScript transform module to source_row or mapped_record NDJSON input.",
  usage: [
    "node skills/rye-tabular-intake/scripts/tabular_map.mts (--config <path> | --module <path>) [--input <ndjson>]",
  ],
  options: [
    { flag: "--config <path>", description: "Declarative JSON mapping config." },
    { flag: "--module <path>", description: "TypeScript module exporting transform(input)." },
    { flag: "--export <name>", description: "Named export to call. Default: transform." },
    { flag: "--input <path>", description: "Optional NDJSON input file. Default: stdin." },
    { flag: "--mapping <name>", description: "Override the emitted mapping name." },
    { flag: "--help", description: "Print command help." },
  ],
  examples: [
    "node skills/rye-tabular-intake/scripts/tabular_extract.mts --input data/customers.csv | node skills/rye-tabular-intake/scripts/tabular_map.mts --config mappings/customers_to_contacts.json",
    "node skills/rye-tabular-intake/scripts/tabular_extract.mts --input data/customers.csv | node skills/rye-tabular-intake/scripts/tabular_map.mts --module mappings/customers_to_contacts.mts",
    "node skills/rye-tabular-intake/scripts/tabular_map.mts --input /tmp/source.ndjson --module mappings/customers_to_addresses.mts",
  ],
};

await runCli(help, async (args) => {
  const configPath = getString(args, "config");
  const moduleValue = getString(args, "module");
  const inputPath = getString(args, "input");
  const exportName = getString(args, "export") ?? "transform";
  const mappingOverride = getString(args, "mapping");

  if (Boolean(configPath) === Boolean(moduleValue)) {
    throw new CliError(
      "mapping_input_choice_required",
      "Pass exactly one of --config or --module.",
      "tabular_map.mts needs either a declarative config or a transform module.",
      [`Use --config for column mapping and conversions.`, `Use --module for custom TypeScript logic.`],
    );
  }

  const loaded = configPath
    ? await loadMappingConfig(configPath)
    : await loadMappingModule(path.resolve(getRequiredString(args, "module", help.name)), exportName);

  const mappingName =
    mappingOverride ??
    loaded.metadata.name ??
    (configPath
      ? path.basename(configPath, path.extname(configPath))
      : path.basename(moduleValue as string, path.extname(moduleValue as string)));

  for await (const value of readNdjson(inputPath)) {
    if (!isSourceRow(value) && !isMappedRecord(value)) {
      throw new CliError(
        "unsupported_mapping_input",
        "tabular_map.mts accepts only source_row or mapped_record input.",
        `Received kind: ${isObject(value) && typeof value.kind === "string" ? value.kind : "unknown"}`,
        [`Run tabular_extract.mts first, or pipe from a prior tabular_map.mts command.`],
      );
    }

    const transformed = await loaded.transform(value);
    if (transformed === null) {
      continue;
    }

    const outputs = Array.isArray(transformed) ? transformed : [transformed];
    for (const item of outputs) {
      writeNdjson(buildMappedRecord(value, item, mappingName));
    }
  }
});

async function loadMappingModule(
  modulePath: string,
  exportName: string,
): Promise<{ metadata: MappingMetadata; transform: TransformFunction }> {
  const loaded = (await import(pathToFileURL(modulePath).href)) as {
    default?: TransformFunction;
    transform?: TransformFunction;
    mapping?: MappingMetadata;
    [key: string]: unknown;
  };

  const transformCandidate = loaded[exportName];
  const transform = (typeof transformCandidate === "function"
    ? transformCandidate
    : exportName === "transform" && typeof loaded.default === "function"
      ? loaded.default
      : undefined) as TransformFunction | undefined;

  if (!transform) {
    throw new CliError(
      "mapping_export_not_found",
      `No callable export named "${exportName}" was found in ${modulePath}.`,
      `Expected a function like export function ${exportName}(input) { ... }`,
      [`Check the module path.`, `Add the requested export, or pass --export with the correct name.`],
    );
  }

  return {
    metadata: loaded.mapping ?? {},
    transform,
  };
}

function buildMappedRecord(input: Parameters<TransformFunction>[0], spec: MapRecordSpec, mappingName: string): MappedRecord {
  if (!spec || typeof spec.destination_table !== "string" || !isObject(spec.record)) {
    throw new CliError(
      "invalid_mapping_output",
      "Mapping output must include destination_table and record.",
      "Each transform result should be { destination_table, record, ... }.",
      [`Return null to drop a row.`, `Return an object or array of objects with destination_table and record.`],
    );
  }

  return {
    kind: "mapped_record",
    mapping: mappingName,
    destination_table: spec.destination_table,
    operation: spec.operation ?? "upsert",
    source: input.source,
    lineage: appendLineage(input.lineage, `map:${mappingName}`),
    record: spec.record,
    meta: isObject(spec.meta) ? spec.meta : {},
    issues: Array.isArray(spec.issues) ? spec.issues.filter((value): value is string => typeof value === "string") : [],
  };
}
