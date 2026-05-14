#!/usr/bin/env node
import fs from "node:fs";
import process from "node:process";

type JsonObject = Record<string, unknown>;
type Mode = "create" | "update" | "append" | "merge_review";

type MappedRecord = {
  kind: "mapped_record";
  mapping?: string;
  destination_table: string;
  operation?: "insert" | "upsert" | "update";
  record: JsonObject;
  meta?: JsonObject;
  issues?: string[];
};

type TargetRecord = {
  destination_table: string;
  record: JsonObject;
};

type KeySpec = {
  table: string;
  fields: string[];
};

type CliOptions = {
  input: string;
  existing?: string;
  mode: Mode;
  keySpecs: KeySpec[];
  defaultKeyFields: string[];
  clearNulls: boolean;
};

type PlannedRecord = {
  mapped: MappedRecord;
  keyFields: string[];
  key: JsonObject;
  keyString: string | null;
};

const GENERIC_KEY_CANDIDATES = [
  ["id"],
  ["external_id"],
  ["legacy_name"],
  ["source_id"],
  ["slug"],
  ["key"],
  ["name"],
];

const WRAPPER_KEYS = new Set(["data", "rows", "records", "results", "result", "items"]);
const METADATA_FIELDS = new Set(["date_created", "date_updated", "created_at", "updated_at"]);

const options = parseArgs(process.argv.slice(2));
const mappedRecords = readMappedNdjson(options.input);
const existingRecords = options.existing ? loadExistingSnapshot(options.existing) : [];
const changePlan = buildChangePlan(mappedRecords, existingRecords, options);

process.stdout.write(`${JSON.stringify(changePlan, null, 2)}\n`);

function parseArgs(args: string[]): CliOptions {
  const options: CliOptions = {
    input: "",
    mode: "merge_review",
    keySpecs: [],
    defaultKeyFields: [],
    clearNulls: false,
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--input") {
      options.input = requiredArg(args, ++index, arg);
    } else if (arg === "--existing") {
      options.existing = requiredArg(args, ++index, arg);
    } else if (arg === "--mode") {
      options.mode = parseMode(requiredArg(args, ++index, arg));
    } else if (arg === "--key") {
      options.keySpecs.push(parseKeySpec(requiredArg(args, ++index, arg)));
    } else if (arg === "--default-key") {
      options.defaultKeyFields = parseFieldList(requiredArg(args, ++index, arg));
    } else if (arg === "--clear-nulls") {
      options.clearNulls = true;
    } else if (arg === "--help") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!options.input) {
    throw new Error("Pass --input <mapped-records.ndjson>.");
  }

  return options;
}

function printHelp(): void {
  process.stdout.write(`Usage:
  node skills/rye-tabular-intake/scripts/tabular_change_plan.mts --input /tmp/mapped.ndjson
  node skills/rye-tabular-intake/scripts/tabular_change_plan.mts --input /tmp/mapped.ndjson --existing /tmp/existing-target.json --key contacts:external_id
  node skills/rye-tabular-intake/scripts/tabular_change_plan.mts --input /tmp/mapped.ndjson --existing /tmp/existing-target.json --key invoice_lines:invoice_id,line_number --mode append

Options:
  --input <path>        mapped_record NDJSON from tabular_map.mts or tabular_group.mts
  --existing <path>     optional existing target-table JSON or NDJSON snapshot
  --mode <mode>         create, update, append, or merge_review; default merge_review
  --key <table:fields>  repeatable table-specific key fields, e.g. contacts:external_id
  --default-key <csv>   fallback key fields for tables without --key
  --clear-nulls         treat explicit nulls as field-clearing changes; default is no change

The command is read-only and table-independent. It emits a review plan and never writes to a destination.
`);
}

function parseMode(value: string): Mode {
  if (value === "create" || value === "update" || value === "append" || value === "merge_review") {
    return value;
  }
  throw new Error(`Unsupported mode ${value}. Use create, update, append, or merge_review.`);
}

function parseKeySpec(value: string): KeySpec {
  const separator = value.indexOf(":");
  if (separator < 1) {
    throw new Error(`Invalid --key ${value}. Expected table:field[,field].`);
  }
  const table = value.slice(0, separator).trim();
  const fields = parseFieldList(value.slice(separator + 1));
  if (!table || !fields.length) {
    throw new Error(`Invalid --key ${value}. Expected table:field[,field].`);
  }
  return { table, fields };
}

function parseFieldList(value: string): string[] {
  return value
    .split(",")
    .map((field) => field.trim())
    .filter(Boolean);
}

function requiredArg(args: string[], index: number, flag: string): string {
  const value = args[index];
  if (!value) {
    throw new Error(`${flag} requires a value.`);
  }
  return value;
}

function readMappedNdjson(filePath: string): MappedRecord[] {
  return fs
    .readFileSync(filePath, "utf8")
    .split(/\r?\n/)
    .filter((line) => line.trim())
    .map((line, index) => {
      const parsed = JSON.parse(line) as MappedRecord;
      if (!isObject(parsed) || parsed.kind !== "mapped_record" || typeof parsed.destination_table !== "string" || !isObject(parsed.record)) {
        throw new Error(`Line ${index + 1} is not a valid mapped_record.`);
      }
      return parsed;
    });
}

function loadExistingSnapshot(filePath: string): TargetRecord[] {
  const content = fs.readFileSync(filePath, "utf8");
  try {
    return normalizeExisting(JSON.parse(content));
  } catch {
    return content
      .split(/\r?\n/)
      .filter((line) => line.trim())
      .flatMap((line) => normalizeExisting(JSON.parse(line)));
  }
}

function normalizeExisting(value: unknown, tableHint?: string): TargetRecord[] {
  if (Array.isArray(value)) {
    return value.flatMap((item) => normalizeExisting(item, tableHint));
  }

  if (!isObject(value)) {
    return [];
  }

  const wrappedRecord = recordFromWrappedValue(value);
  if (wrappedRecord) {
    return [wrappedRecord];
  }

  const records: TargetRecord[] = [];
  for (const [key, nested] of Object.entries(value)) {
    if (WRAPPER_KEYS.has(key)) {
      records.push(...normalizeExisting(nested, tableHint));
    } else if (Array.isArray(nested)) {
      records.push(...nested.flatMap((item) => normalizeExisting(item, key)));
    } else if (isObject(nested) && looksLikeRecord(nested)) {
      records.push({ destination_table: key, record: nested });
    }
  }

  if (!records.length && tableHint && looksLikeRecord(value)) {
    records.push({ destination_table: tableHint, record: value });
  }

  return records;
}

function recordFromWrappedValue(value: JsonObject): TargetRecord | null {
  const table = stringValue(value.destination_table ?? value.table ?? value.target_table ?? value.collection);
  const record = isObject(value.record) ? value.record : isObject(value.row) ? value.row : null;
  if (table && record) {
    return { destination_table: table, record };
  }

  if (table && looksLikeRecord(value)) {
    const { destination_table, table: _table, target_table, collection, record: _record, row: _row, ...recordFields } = value;
    return { destination_table: table, record: recordFields };
  }

  return null;
}

function looksLikeRecord(value: JsonObject): boolean {
  return Object.values(value).some((entry) => !Array.isArray(entry) && !isObject(entry));
}

function buildChangePlan(mappedRecords: MappedRecord[], existingRecords: TargetRecord[], options: CliOptions): JsonObject {
  const planned = mappedRecords.map((mapped) => buildPlannedRecord(mapped, options));
  const issues = mappedRecords.flatMap((record) => (record.issues ?? []).map((issue) => `${record.destination_table}: ${issue}`));

  if (options.mode !== "create" && !options.existing) {
    issues.push("No existing target snapshot supplied; update due diligence is incomplete.");
  }

  for (const plannedRecord of planned) {
    if (!plannedRecord.keyString) {
      issues.push(`No usable key found for ${plannedRecord.mapped.destination_table}; pass --key ${plannedRecord.mapped.destination_table}:<field[,field]>.`);
    }
  }
  for (const duplicate of duplicatePlannedKeys(planned)) {
    issues.push(`Mapped input contains ${duplicate.count} records for ${duplicate.table} key ${JSON.stringify(duplicate.key)}; review whether these should be grouped before write planning.`);
  }

  const existingByTable = groupBy(existingRecords, (record) => record.destination_table);
  const existingByExactKey = new Map<string, TargetRecord>();
  for (const existing of existingRecords) {
    const keyFields = keyFieldsForTable(existing.destination_table, options, existing.record);
    const keyString = keyStringForRecord(existing.destination_table, existing.record, keyFields);
    if (keyString) {
      existingByExactKey.set(keyString, existing);
    }
  }

  const changes = planned.map((plannedRecord) => {
    const exact = plannedRecord.keyString ? existingByExactKey.get(plannedRecord.keyString) : undefined;
    const candidates = existingByTable.get(plannedRecord.mapped.destination_table) ?? [];
    return classifyRecord(plannedRecord, exact, candidates, options);
  });

  return {
    kind: "rye_tabular_change_plan",
    schema_version: 1,
    mode: options.mode,
    generated_at: new Date().toISOString(),
    input: {
      mapped_record_count: mappedRecords.length,
      planned_table_counts: countBy(planned, (record) => record.mapped.destination_table),
      existing_snapshot_supplied: Boolean(options.existing),
      existing_table_counts: countBy(existingRecords, (record) => record.destination_table),
      key_specs: options.keySpecs,
      default_key_fields: options.defaultKeyFields,
      clear_nulls: options.clearNulls,
    },
    summary: summarizeChanges(changes),
    issues: [...new Set(issues)],
    due_diligence: [
      "Review every action other than no_change before running target-specific writes.",
      "Blank or omitted mapped values are treated as no change unless --clear-nulls is set.",
      "Append mode treats exact key collisions as review blockers.",
      "possible_merge means the planner found a plausible existing row, but the match is not safe for automatic writes.",
    ],
    changes,
  };
}

function buildPlannedRecord(mapped: MappedRecord, options: CliOptions): PlannedRecord {
  const keyFields = keyFieldsForMappedRecord(mapped, options);
  const key = keyObject(mapped.record, keyFields);
  const keyString = keyStringForRecord(mapped.destination_table, mapped.record, keyFields);
  return { mapped, keyFields, key, keyString };
}

function classifyRecord(
  planned: PlannedRecord,
  exact: TargetRecord | undefined,
  candidates: TargetRecord[],
  options: CliOptions,
): JsonObject {
  const table = planned.mapped.destination_table;
  const after = planned.mapped.record;

  if (!planned.keyString) {
    return changeRecord(table, "needs_review", planned, after, null, [], [], [
      "No exact key could be built for this mapped record.",
    ]);
  }

  if (exact) {
    const diff = diffRecords(after, exact.record, options);
    if (options.mode === "append") {
      return changeRecord(table, "needs_review", planned, after, exact.record, diff.field_changes, diff.uncompared_fields, [
        "Append mode found an exact key collision; choose a new key or approve an update.",
      ]);
    }
    if (!diff.field_changes.length) {
      return changeRecord(table, "no_change", planned, after, exact.record, [], diff.uncompared_fields, []);
    }
    if (options.mode === "create") {
      return changeRecord(table, "needs_review", planned, after, exact.record, diff.field_changes, diff.uncompared_fields, [
        "Create mode found an existing row; review before converting this into an update.",
      ]);
    }
    return changeRecord(table, "update", planned, after, exact.record, diff.field_changes, diff.uncompared_fields, [
      "Existing target row values would change.",
    ]);
  }

  const best = bestGenericMatch(after, candidates);
  if (options.mode === "update") {
    if (best && best.score >= 0.75) {
      const diff = diffRecords(after, best.record.record, options);
      return changeRecord(table, "possible_merge", planned, after, best.record.record, diff.field_changes, diff.uncompared_fields, [
        `No exact key matched, but an existing row matched at score ${best.score}.`,
        ...best.reasons,
      ]);
    }
    return changeRecord(table, "needs_review", planned, after, null, [], [], [
      "Update mode could not find an exact or high-confidence existing row match.",
    ]);
  }

  if (options.mode === "merge_review" && best && best.score >= 0.75) {
    const diff = diffRecords(after, best.record.record, options);
    return changeRecord(table, "possible_merge", planned, after, best.record.record, diff.field_changes, diff.uncompared_fields, [
      `No exact key matched, but an existing row matched at score ${best.score}.`,
      ...best.reasons,
    ]);
  }

  if (options.mode === "merge_review" && best && best.score >= 0.55) {
    return changeRecord(table, "needs_review", planned, after, best.record.record, [], [], [
      `Ambiguous possible row match at score ${best.score}; review before treating as append or merge.`,
      ...best.reasons,
    ]);
  }

  const action = options.mode === "create" ? "create" : "append";
  return changeRecord(table, action, planned, after, null, [], [], [
    candidates.length ? "No existing row matched strongly enough; planned as a new row." : "No existing rows were found for this table.",
  ]);
}

function changeRecord(
  table: string,
  action: string,
  planned: PlannedRecord,
  after: JsonObject,
  before: JsonObject | null,
  fieldChanges: JsonObject[],
  uncomparedFields: string[],
  reviewReasons: string[],
): JsonObject {
  return {
    table,
    action,
    operation: planned.mapped.operation ?? "upsert",
    approval_required: action !== "no_change",
    review_required: action !== "no_change",
    key_fields: planned.keyFields,
    key: planned.key,
    existing_id: before?.id ?? null,
    review_reasons: reviewReasons,
    field_changes: fieldChanges,
    uncompared_fields: uncomparedFields,
    mapping: planned.mapped.mapping ?? null,
    after,
    before: before ? pickComparableBefore(before, after) : null,
  };
}

function diffRecords(after: JsonObject, before: JsonObject, options: CliOptions): { field_changes: JsonObject[]; uncompared_fields: string[] } {
  const fieldChanges: JsonObject[] = [];
  const uncomparedFields: string[] = [];

  for (const field of Object.keys(after).sort()) {
    if (METADATA_FIELDS.has(field)) {
      continue;
    }

    const afterValue = after[field];
    if ((afterValue === undefined || afterValue === null || afterValue === "") && !options.clearNulls) {
      continue;
    }

    if (!Object.prototype.hasOwnProperty.call(before, field)) {
      uncomparedFields.push(field);
      continue;
    }

    const beforeValue = before[field];
    if (!equivalentFieldValue(beforeValue, afterValue)) {
      fieldChanges.push({ field, before: beforeValue ?? null, after: afterValue ?? null });
    }
  }

  return { field_changes: fieldChanges, uncompared_fields: uncomparedFields };
}

function equivalentFieldValue(left: unknown, right: unknown): boolean {
  const leftNumber = numberValue(left);
  const rightNumber = numberValue(right);
  if (leftNumber !== null && rightNumber !== null) {
    return Math.abs(leftNumber - rightNumber) < 0.000001;
  }
  return normalizedString(left) === normalizedString(right);
}

function bestGenericMatch(after: JsonObject, candidates: TargetRecord[]): { record: TargetRecord; score: number; reasons: string[] } | null {
  let best: { record: TargetRecord; score: number; reasons: string[] } | null = null;
  for (const candidate of candidates) {
    const scored = scoreGenericMatch(after, candidate.record);
    if (!best || scored.score > best.score) {
      best = { record: candidate, ...scored };
    }
  }
  return best && best.score > 0 ? best : null;
}

function scoreGenericMatch(after: JsonObject, before: JsonObject): { score: number; reasons: string[] } {
  const comparableFields = Object.keys(after)
    .filter((field) => !METADATA_FIELDS.has(field))
    .filter((field) => after[field] !== null && after[field] !== undefined && after[field] !== "")
    .filter((field) => before[field] !== null && before[field] !== undefined && before[field] !== "");

  if (!comparableFields.length) {
    return { score: 0, reasons: [] };
  }

  const matched = comparableFields.filter((field) => equivalentFieldValue(before[field], after[field]));
  const weightedMatches = matched.reduce((total, field) => total + fieldWeight(field), 0);
  const weightedTotal = comparableFields.reduce((total, field) => total + fieldWeight(field), 0);

  return {
    score: weightedTotal ? round(weightedMatches / weightedTotal, 2) : 0,
    reasons: matched.slice(0, 8).map((field) => `Matched field ${field}.`),
  };
}

function fieldWeight(field: string): number {
  if (/^(id|.*_id|external_id|legacy_name|source_id|slug|key)$/i.test(field)) {
    return 3;
  }
  if (/name|email|url|link|parcel|tax|county|district/i.test(field)) {
    return 2;
  }
  return 1;
}

function keyFieldsForMappedRecord(mapped: MappedRecord, options: CliOptions): string[] {
  const fromMeta = keyFieldsFromMappedMeta(mapped);
  return keyFieldsForTable(mapped.destination_table, options, mapped.record, fromMeta);
}

function keyFieldsForTable(table: string, options: CliOptions, record: JsonObject, preferred: string[] = []): string[] {
  const tableSpec = options.keySpecs.find((spec) => spec.table === table);
  if (tableSpec) {
    return tableSpec.fields;
  }
  if (preferred.length) {
    return preferred;
  }
  if (options.defaultKeyFields.length) {
    return options.defaultKeyFields;
  }
  for (const candidate of GENERIC_KEY_CANDIDATES) {
    if (candidate.every((field) => hasValue(record[field]))) {
      return candidate;
    }
  }
  return [];
}

function keyFieldsFromMappedMeta(mapped: MappedRecord): string[] {
  const idempotency = isObject(mapped.meta?.idempotency) ? mapped.meta.idempotency : null;
  const conflictColumns = idempotency && Array.isArray(idempotency.conflict_columns)
    ? idempotency.conflict_columns.filter((field): field is string => typeof field === "string")
    : [];
  if (conflictColumns.length) {
    return conflictColumns;
  }

  const conflictKey = idempotency && isObject(idempotency.conflict_key) ? idempotency.conflict_key : null;
  return conflictKey ? Object.keys(conflictKey) : [];
}

function keyObject(record: JsonObject, fields: string[]): JsonObject {
  return Object.fromEntries(fields.map((field) => [field, record[field] ?? null]));
}

function keyStringForRecord(table: string, record: JsonObject, fields: string[]): string | null {
  if (!fields.length || fields.some((field) => !hasValue(record[field]))) {
    return null;
  }
  return JSON.stringify({ table, key: keyObject(record, fields) });
}

function duplicatePlannedKeys(planned: PlannedRecord[]): Array<{ table: string; key: JsonObject; count: number }> {
  const counts = new Map<string, { table: string; key: JsonObject; count: number }>();
  for (const record of planned) {
    if (!record.keyString) {
      continue;
    }
    const current = counts.get(record.keyString) ?? {
      table: record.mapped.destination_table,
      key: record.key,
      count: 0,
    };
    current.count += 1;
    counts.set(record.keyString, current);
  }
  return [...counts.values()].filter((entry) => entry.count > 1);
}

function summarizeChanges(changes: JsonObject[]): JsonObject {
  let approvalRequired = 0;
  let reviewRequired = 0;
  for (const change of changes) {
    if (change.approval_required === true) {
      approvalRequired += 1;
    }
    if (change.review_required === true) {
      reviewRequired += 1;
    }
  }

  return {
    total_changes: changes.length,
    by_action: countBy(changes, (change) => stringValue(change.action) ?? "unknown"),
    by_table: countBy(changes, (change) => stringValue(change.table) ?? "unknown"),
    approval_required_count: approvalRequired,
    review_required_count: reviewRequired,
  };
}

function pickComparableBefore(before: JsonObject, after: JsonObject): JsonObject {
  const output: JsonObject = {};
  for (const key of Object.keys(after).sort()) {
    if (Object.prototype.hasOwnProperty.call(before, key)) {
      output[key] = before[key];
    }
  }
  if (before.id !== undefined) {
    output.id = before.id;
  }
  return output;
}

function countBy<T>(records: T[], keyForRecord: (record: T) => string): JsonObject {
  const counts: JsonObject = {};
  for (const record of records) {
    const key = keyForRecord(record);
    counts[key] = (numberValue(counts[key]) ?? 0) + 1;
  }
  return counts;
}

function groupBy<T>(records: T[], keyForRecord: (record: T) => string): Map<string, T[]> {
  const grouped = new Map<string, T[]>();
  for (const record of records) {
    const key = keyForRecord(record);
    const current = grouped.get(key) ?? [];
    current.push(record);
    grouped.set(key, current);
  }
  return grouped;
}

function hasValue(value: unknown): boolean {
  return value !== null && value !== undefined && value !== "";
}

function stringValue(value: unknown): string | null {
  if (value === null || value === undefined) {
    return null;
  }
  const string = String(value).trim();
  return string || null;
}

function normalizedString(value: unknown): string | null {
  const string = stringValue(value);
  return string ? string.toLowerCase().replace(/\s+/g, " ") : null;
}

function numberValue(value: unknown): number | null {
  if (value === null || value === undefined || value === "") {
    return null;
  }
  if (typeof value === "number") {
    return Number.isFinite(value) ? value : null;
  }
  const parsed = Number.parseFloat(String(value).replace(/[$,%]/g, "").replace(/,/g, ""));
  return Number.isFinite(parsed) ? parsed : null;
}

function round(value: number, digits: number): number {
  const scale = 10 ** digits;
  return Math.round((value + Number.EPSILON) * scale) / scale;
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
