#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const VALID_OPERATIONS = new Set(["insert", "upsert", "update"]);
const REVIEW_ACTIONS = new Set(["update", "append", "possible_merge", "needs_review"]);
const NON_WRITE_ACTIONS = new Set(["no_change"]);

const options = parseArgs(process.argv.slice(2));
const findings = [];

let sources = [];
let mapped = [];
let ryeAudit = [];
let changePlan = null;
let existing = null;
let metadata = {};

try {
  sources = readManyNdjson(options.source);
  mapped = readManyNdjson(options.mapped);
  ryeAudit = readManyNdjson(options.ryeAudit);
  changePlan = options.changePlan ? readJson(options.changePlan) : null;
  existing = options.existing ? readJsonOrNdjson(options.existing) : null;
  metadata = options.metadata ? readJson(options.metadata) : {};
} catch (error) {
  findings.push(finding("blocker", "input.read_failed", error.message));
}

inspectSourceRows(sources);
inspectMappedRecords(mapped, changePlan);
inspectChangePlan(changePlan);
inspectMetadata(metadata, mapped, changePlan, ryeAudit, existing);

const report = buildReport();

if (options.emitStage) {
  process.stdout.write(`${JSON.stringify(buildStageRecord(report, sources, mapped, ryeAudit))}\n`);
} else {
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}

if (!options.exitZero && report.status === "fail") {
  process.exitCode = 1;
}

function parseArgs(args) {
  const parsed = {
    source: [],
    mapped: [],
    ryeAudit: [],
    phase: "prewrite",
    emitStage: false,
    exitZero: false,
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--source") {
      parsed.source.push(requiredArg(args, ++index, arg));
    } else if (arg === "--mapped") {
      parsed.mapped.push(requiredArg(args, ++index, arg));
    } else if (arg === "--change-plan") {
      parsed.changePlan = requiredArg(args, ++index, arg);
    } else if (arg === "--existing") {
      parsed.existing = requiredArg(args, ++index, arg);
    } else if (arg === "--rye-audit") {
      parsed.ryeAudit.push(requiredArg(args, ++index, arg));
    } else if (arg === "--metadata") {
      parsed.metadata = requiredArg(args, ++index, arg);
    } else if (arg === "--phase") {
      parsed.phase = requiredArg(args, ++index, arg);
    } else if (arg === "--emit-stage") {
      parsed.emitStage = true;
    } else if (arg === "--exit-zero") {
      parsed.exitZero = true;
    } else if (arg === "--help") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!["prewrite", "postwrite"].includes(parsed.phase)) {
    throw new Error("--phase must be prewrite or postwrite.");
  }

  return parsed;
}

function requiredArg(args, index, flag) {
  const value = args[index];
  if (!value) {
    throw new Error(`${flag} requires a value.`);
  }
  return value;
}

function printHelp() {
  process.stdout.write(`Usage:
  node skills/rye-import-inspector/scripts/inspect_import_run.mjs --source source.ndjson --mapped mapped.ndjson --change-plan change-plan.json --metadata metadata.json

Options:
  --source <path>       source_row NDJSON; repeatable
  --mapped <path>       mapped_record NDJSON; repeatable
  --change-plan <path>  JSON change plan from tabular_change_plan.mts
  --existing <path>     target snapshot JSON or NDJSON
  --rye-audit <path>    NDJSON destined for tabular_commit_rye.mts; repeatable
  --metadata <path>     process metadata JSON
  --phase <value>       prewrite or postwrite; default prewrite
  --emit-stage          emit one rye_stage_record containing the inspection report
  --exit-zero           always exit 0 after printing the report
`);
}

function readManyNdjson(paths) {
  return paths.flatMap((filePath) => readNdjson(filePath));
}

function readNdjson(filePath) {
  const text = fs.readFileSync(filePath, "utf8");
  return text
    .split(/\r?\n/)
    .map((line, index) => ({ line, index }))
    .filter(({ line }) => line.trim())
    .map(({ line, index }) => {
      try {
        return JSON.parse(line);
      } catch (error) {
        throw new Error(`${filePath}:${index + 1}: invalid JSON: ${error.message}`);
      }
    });
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function readJsonOrNdjson(filePath) {
  const text = fs.readFileSync(filePath, "utf8").trim();
  if (!text) {
    return [];
  }
  if (text.startsWith("[") || text.startsWith("{")) {
    return JSON.parse(text);
  }
  return readNdjson(filePath);
}

function inspectSourceRows(records) {
  for (const [index, record] of records.entries()) {
    const where = { index };
    if (record?.kind !== "source_row") {
      findings.push(finding("blocker", "source.kind_invalid", "Source NDJSON entries must have kind source_row.", where));
      continue;
    }
    inspectSourceDescriptor(record.source, "source.source", where);
    requireObject(record.row, "source.row", where);
    requireArray(record.lineage, "source.lineage", where);
    if (!("raw" in record)) {
      findings.push(finding("warning", "source.raw_missing", "Source row is missing raw cell values.", where));
    }
  }
}

function inspectMappedRecords(records, plan) {
  const planBeforeByKey = beforeEvidenceByMappedKey(plan);
  for (const [index, record] of records.entries()) {
    const where = { index, table: record?.destination_table ?? null };
    if (record?.kind !== "mapped_record") {
      findings.push(finding("blocker", "mapped.kind_invalid", "Mapped NDJSON entries must have kind mapped_record.", where));
      continue;
    }
    if (!nonEmptyString(record.destination_table)) {
      findings.push(finding("blocker", "mapped.destination_table_missing", "Mapped record must include destination_table.", where));
    }
    if (record.operation && !VALID_OPERATIONS.has(record.operation)) {
      findings.push(finding("blocker", "mapped.operation_invalid", "Mapped operation must be insert, upsert, or update.", { ...where, operation: record.operation }));
    }
    requireObject(record.record, "mapped.record", where);
    requireArray(record.lineage, "mapped.lineage", where);
    inspectSourceSet(record.source_set, "mapped.source_set", where);
    if (!Array.isArray(record.issues)) {
      findings.push(finding("warning", "mapped.issues_missing", "Mapped record should include an issues array.", where));
    }
    if ((record.issues ?? []).length > 0) {
      findings.push(finding("blocker", "mapped.issues_present", "Mapped record still has unresolved mapping issues.", { ...where, issues: record.issues }));
    }
    if (record.operation === "update" && !hasOldValueEvidence(record) && !planBeforeByKey.has(mappedKey(record))) {
      findings.push(finding("blocker", "update.old_values_missing", "Update records must include old values or be backed by change-plan before evidence.", where));
    }
  }
}

function inspectChangePlan(plan) {
  if (!plan) {
    return;
  }
  if (!isObject(plan)) {
    findings.push(finding("blocker", "change_plan.invalid", "Change plan must be a JSON object."));
    return;
  }
  if (!Array.isArray(plan.changes)) {
    findings.push(finding("blocker", "change_plan.changes_missing", "Change plan must include a changes array."));
    return;
  }
  for (const [index, change] of plan.changes.entries()) {
    const where = { index, table: change?.table ?? null, action: change?.action ?? null };
    if (!nonEmptyString(change?.table)) {
      findings.push(finding("blocker", "change_plan.table_missing", "Change-plan entry must include table.", where));
    }
    if (!nonEmptyString(change?.action)) {
      findings.push(finding("blocker", "change_plan.action_missing", "Change-plan entry must include action.", where));
    }
    if ((change.action === "update" || change.operation === "update") && !Array.isArray(change.field_changes)) {
      findings.push(finding("blocker", "change_plan.update_diff_missing", "Update change-plan entries must include field_changes.", where));
    }
    if (change.action === "possible_merge" || change.action === "needs_review") {
      findings.push(finding("blocker", "change_plan.unresolved_review", "possible_merge and needs_review entries must be resolved before target writes.", where));
    }
  }
}

function inspectMetadata(meta, mappedRecords, plan, auditRecords, existingSnapshot) {
  const mappedTables = unique(mappedRecords.map((record) => record.destination_table).filter(Boolean));
  const plannedTables = unique((plan?.changes ?? []).map((change) => change.table).filter(Boolean));
  const tables = unique([...mappedTables, ...plannedTables]);
  const mappedOps = unique(mappedRecords.map((record) => record.operation).filter(Boolean));
  const plannedOps = unique((plan?.changes ?? []).map((change) => change.action ?? change.operation).filter(isWriteOperationName));
  const operations = unique([...mappedOps, ...plannedOps]);

  if (tables.length > 0) {
    requireStringArrayEquivalent(meta.target_tables, tables, "metadata.target_tables", "metadata.target_tables must exactly match the mapped or planned target tables.");
  }
  if (operations.length > 0) {
    requireStringArrayEquivalent(meta.operation_types, operations, "metadata.operation_types", "metadata.operation_types must exactly match mapped operations or change-plan actions.");
  }

  const hasReviewAction = (plan?.changes ?? []).some((change) => REVIEW_ACTIONS.has(change.action));
  if (options.phase === "prewrite" && hasReviewAction && approvalStatus(meta) !== "approved") {
    findings.push(finding("blocker", "approval.missing", "Review-required target writes need explicit approval metadata before execution."));
  }

  if (options.phase === "prewrite" && (auditRecords.length > 0 || meta?.rye?.committed)) {
    findings.push(finding("info", "rye.audit_present", "Rye audit evidence is present before target write."));
  }

  if (options.phase === "postwrite") {
    if (!hasTouchedIds(meta)) {
      findings.push(finding("blocker", "postwrite.touched_ids_missing", "Post-write metadata must include touched target IDs."));
    }
    if (!meta?.verification?.readback) {
      findings.push(finding("blocker", "postwrite.readback_missing", "Post-write metadata must record readback verification."));
    }
  }

  if (existingSnapshot && countSnapshotRows(existingSnapshot) === 0 && mappedRecords.some((record) => record.operation === "update")) {
    findings.push(finding("blocker", "existing.empty_for_update", "Update runs need a non-empty target snapshot."));
  }
}

function requireStringArrayEquivalent(actual, expected, codeSuffix, message) {
  if (!Array.isArray(actual) || actual.some((value) => typeof value !== "string")) {
    findings.push(finding("blocker", `${codeSuffix}.missing`, message, { expected }));
    return;
  }
  const actualSorted = unique(actual).sort();
  const expectedSorted = unique(expected).sort();
  if (JSON.stringify(actualSorted) !== JSON.stringify(expectedSorted)) {
    findings.push(finding("blocker", `${codeSuffix}.mismatch`, message, { expected: expectedSorted, actual: actualSorted }));
  }
}

function inspectSourceSet(sourceSet, label, evidence) {
  if (!isObject(sourceSet)) {
    findings.push(finding("blocker", `${label}.missing`, "Mapped records must include source_set lineage.", evidence));
    return;
  }
  inspectSourceDescriptor(sourceSet.primary, `${label}.primary`, evidence);
  if (!Array.isArray(sourceSet.sources) || sourceSet.sources.length === 0) {
    findings.push(finding("blocker", `${label}.sources_missing`, "source_set.sources must contain at least one source descriptor.", evidence));
  } else {
    for (const [sourceIndex, source] of sourceSet.sources.entries()) {
      inspectSourceDescriptor(source, `${label}.sources`, { ...evidence, sourceIndex });
    }
  }
  if (!Number.isInteger(sourceSet.row_count) || sourceSet.row_count < 1) {
    findings.push(finding("blocker", `${label}.row_count_invalid`, "source_set.row_count must be a positive integer.", evidence));
  }
}

function inspectSourceDescriptor(source, label, evidence) {
  if (!isObject(source)) {
    findings.push(finding("blocker", `${label}.missing`, "Source descriptor is required.", evidence));
    return;
  }
  for (const field of ["path", "format", "table_name", "header_row", "row_number", "record_number"]) {
    if (source[field] === undefined || source[field] === null || source[field] === "") {
      findings.push(finding("blocker", `${label}.${field}_missing`, `Source descriptor must include ${field}.`, evidence));
    }
  }
}

function requireObject(value, label, evidence) {
  if (!isObject(value)) {
    findings.push(finding("blocker", `${label}.missing`, `${label} must be an object.`, evidence));
  }
}

function requireArray(value, label, evidence) {
  if (!Array.isArray(value)) {
    findings.push(finding("blocker", `${label}.missing`, `${label} must be an array.`, evidence));
  }
}

function hasOldValueEvidence(record) {
  const meta = record.meta;
  return Boolean(
    isObject(meta) &&
    (isObject(meta.existing_record_before_update) ||
      isObject(meta.old_values) ||
      isObject(meta.before) ||
      (Array.isArray(meta.planned_field_changes) && meta.planned_field_changes.some((change) => isObject(change) && "before" in change))),
  );
}

function beforeEvidenceByMappedKey(plan) {
  const keys = new Set();
  for (const change of plan?.changes ?? []) {
    if (change.before || Array.isArray(change.field_changes)) {
      keys.add(`${change.table}:${JSON.stringify(change.key ?? change.after ?? {})}`);
    }
  }
  return keys;
}

function mappedKey(record) {
  const key = record.meta?.idempotency?.conflict_key ?? record.record;
  return `${record.destination_table}:${JSON.stringify(key ?? {})}`;
}

function countSnapshotRows(snapshot) {
  if (Array.isArray(snapshot)) {
    return snapshot.length;
  }
  if (!isObject(snapshot)) {
    return 0;
  }
  for (const key of ["data", "rows", "records", "results"]) {
    if (Array.isArray(snapshot[key])) {
      return snapshot[key].length;
    }
  }
  return Object.values(snapshot).reduce((sum, value) => sum + (Array.isArray(value) ? value.length : 0), 0);
}

function approvalStatus(meta) {
  return typeof meta?.approval?.status === "string" ? meta.approval.status.toLowerCase() : null;
}

function hasTouchedIds(meta) {
  if (!isObject(meta?.touched_ids)) {
    return false;
  }
  return Object.values(meta.touched_ids).some((value) => Array.isArray(value) && value.length > 0);
}

function buildReport() {
  const blockerCount = findings.filter((item) => item.severity === "blocker").length;
  const warningCount = findings.filter((item) => item.severity === "warning").length;
  return {
    schema_type: "rye.import_inspection.report.v1",
    schema_version: 1,
    kind: "rye_import_inspection_report",
    generated_at: new Date().toISOString(),
    phase: options.phase,
    status: blockerCount > 0 ? "fail" : "pass",
    summary: {
      source_rows: sources.length,
      mapped_records: mapped.length,
      rye_audit_records: ryeAudit.length,
      change_plan_changes: changePlan?.changes?.length ?? null,
      existing_snapshot_rows: existing ? countSnapshotRows(existing) : null,
      blockers: blockerCount,
      warnings: warningCount,
      target_tables: unique([...mapped.map((record) => record.destination_table), ...((changePlan?.changes ?? []).map((change) => change.table))].filter(Boolean)),
      operation_types: unique([...mapped.map((record) => record.operation), ...((changePlan?.changes ?? []).map((change) => change.action ?? change.operation))].filter(isWriteOperationName)),
    },
    findings,
  };
}

function buildStageRecord(report, sourceRecords, mappedRecords, auditRecords) {
  const sourceSet = firstSourceSet(mappedRecords) ?? firstSourceSet(auditRecords) ?? sourceSetFromSourceRow(sourceRecords[0]);
  if (!sourceSet) {
    throw new Error("--emit-stage requires at least one source_row, mapped_record, or rye_stage_record with source lineage.");
  }
  return {
    kind: "rye_stage_record",
    node_type: "rye_import_inspection_report",
    label: `Import inspection ${report.phase} ${report.status}`,
    source_set: sourceSet,
    lineage: ["inspect:rye-import-inspector"],
    properties: {
      schema_type: "rye.tabular_intake.stage_properties.v2",
      schema_version: 2,
      ingest_status: report.status === "pass" ? "inspection_passed" : "inspection_failed",
      source_set: sourceSet,
      validation_report: report,
      report_sha1: sha1(JSON.stringify(report)),
    },
  };
}

function firstSourceSet(records) {
  for (const record of records) {
    if (isObject(record?.source_set)) {
      return record.source_set;
    }
    if (isObject(record?.properties?.source_set)) {
      return record.properties.source_set;
    }
  }
  return null;
}

function sourceSetFromSourceRow(record) {
  if (!isObject(record?.source)) {
    return null;
  }
  return {
    group_key: null,
    primary: record.source,
    sources: [record.source],
    row_count: 1,
  };
}

function finding(severity, code, message, evidence = {}) {
  return { severity, code, message, evidence };
}

function unique(values) {
  return [...new Set(values)];
}

function nonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function isWriteOperationName(value) {
  return Boolean(value && !NON_WRITE_ACTIONS.has(value));
}

function isObject(value) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function sha1(value) {
  return crypto.createHash("sha1").update(value).digest("hex");
}
