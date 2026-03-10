#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  CliError,
  getRequiredString,
  getString,
  runCli,
  type HelpSpec,
} from "./lib/cli.mts";
import {
  isMappedRecord,
  isPipelineRecord,
  isRyeStageRecord,
  isSourceRow,
  type PipelineRecord,
  type SourceDescriptor,
} from "./lib/contracts.mts";
import { readNdjson } from "./lib/ndjson.mts";
import {
  buildPsqlTarget,
  runPsql,
  runPsqlCapture,
  sqlJson,
  sqlText,
  type PsqlTarget,
} from "./lib/psql_target.mts";
import { validateSchemaFile } from "./lib/json_schema.mts";
import {
  assertionTypeForRecord,
  buildClaim,
  buildRowEventProperties,
  buildRowNodeProperties,
  buildRunEventProperties,
  buildRunNodeProperties,
  buildSourceFileArtifactContent,
  buildSourceFileArtifactLocation,
  eventTypeForRecord,
  RYE_TABULAR_INTAKE,
  schemaFileForClaim,
  summaryForRecord,
  uniqueSorted,
} from "./lib/rye_contracts.mts";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

const help: HelpSpec = {
  name: "tabular_commit_rye.mts",
  summary: "Write extracted, mapped, or staged NDJSON records into Rye nodes, events, assertions, and artifacts.",
  usage: [
    "node skills/rye-tabular-intake/scripts/tabular_commit_rye.mts (--db-url <postgresql://...> | --docker-container <name>) --input <ndjson>",
  ],
  options: [
    { flag: "--input <path>", description: "NDJSON file containing source_row, mapped_record, or rye_stage_record objects." },
    { flag: "--db-url <url>", description: "Target PostgreSQL database URL." },
    { flag: "--docker-container <name>", description: "Run psql through docker exec against a running Postgres container." },
    { flag: "--docker-user <name>", description: "Database user for --docker-container. Default: rye." },
    { flag: "--docker-db <name>", description: "Database name for --docker-container. Default: rye." },
    { flag: "--run-id <value>", description: "Stable run identifier. Default: generated UUID." },
    { flag: "--run-node-type <value>", description: "Run node type. Default: rye_tabular_intake_run." },
    { flag: "--row-node-type <value>", description: "Row node type. Default: rye_tabular_intake_row." },
    { flag: "--scenario <value>", description: "Optional scenario tag stored on Rye records." },
    { flag: "--agent-id <value>", description: "Actor label used on Rye events. Default: rye_tabular_intake." },
    { flag: "--allow-duplicate-source", description: "Allow a run even if the same source-file SHA1 fingerprint was already committed for the same run kind." },
    { flag: "--help", description: "Print command help." },
  ],
  examples: [
    "node skills/rye-tabular-intake/scripts/tabular_commit_rye.mts --db-url postgresql://rye:rye@127.0.0.1:54329/rye --input /tmp/source_rows.ndjson --run-id customer-import-2026-03-10",
    "node skills/rye-tabular-intake/scripts/tabular_commit_rye.mts --docker-container rye-fixture-db --input /tmp/stage_rows.ndjson --scenario contacts-basic",
  ],
};

await runCli(help, async (args) => {
  const inputPath = getRequiredString(args, "input", help.name);
  const records: PipelineRecord[] = [];

  for await (const value of readNdjson(inputPath)) {
    if (!isPipelineRecord(value)) {
      throw new CliError(
        "unsupported_commit_input",
        "tabular_commit_rye.mts accepts only source_row, mapped_record, or rye_stage_record input.",
        `Received kind: ${typeof value === "object" && value && "kind" in value ? String((value as { kind?: unknown }).kind) : "unknown"}`,
        [`Run tabular_extract.mts, tabular_map.mts, or tabular_stage_rye.mts first.`],
      );
    }
    records.push(value);
  }

  if (records.length === 0) {
    throw new CliError(
      "empty_commit_input",
      "The input NDJSON stream was empty.",
      "There were no records to commit into Rye.",
      [`Check the upstream extraction or mapping step.`],
    );
  }

  const target = buildPsqlTarget({
    dbUrl: getString(args, "db-url"),
    dockerContainer: getString(args, "docker-container"),
    dockerUser: getString(args, "docker-user") ?? "rye",
    dockerDb: getString(args, "docker-db") ?? "rye",
  });
  const runId = getString(args, "run-id") ?? crypto.randomUUID();
  const runNodeType = getString(args, "run-node-type") ?? RYE_TABULAR_INTAKE.defaultRunNodeType;
  const rowNodeType = getString(args, "row-node-type") ?? RYE_TABULAR_INTAKE.defaultRowNodeType;
  const scenario = getString(args, "scenario");
  const agentId = getString(args, "agent-id") ?? RYE_TABULAR_INTAKE.defaultAgentId;
  const allowDuplicateSource = getString(args, "allow-duplicate-source") === "true";
  const runContext = await buildRunContext(records);

  if (!allowDuplicateSource) {
    await rejectDuplicateRun(target, runId, runContext);
  }

  const runNodeId = await upsertRunNode(target, runId, runNodeType, scenario, inputPath, runContext);
  const startedEventId = await recordRunEvent(
    target,
    runNodeId,
    RYE_TABULAR_INTAKE.runStartedEventType,
    `Tabular intake run ${runId} started`,
    buildRunEventProperties({
      runId,
      scenario,
      phase: "started",
      inputPath: path.resolve(inputPath),
      inputRecords: records.length,
      inputKinds: runContext.inputKinds,
      mappings: runContext.mappings,
      stageStatuses: runContext.stageStatuses,
      sourceFiles: runContext.sourceFiles,
      runFingerprintSha1: runContext.runFingerprintSha1,
    }),
    agentId,
  );

  await ensureSourceArtifacts(target, runNodeId, startedEventId, runContext.sourceFiles, scenario);

  const summary = {
    source_rows: 0,
    mapped_records: 0,
    stage_records: 0,
  };

  for (const record of records) {
    if (isSourceRow(record)) {
      summary.source_rows += 1;
    } else if (isMappedRecord(record)) {
      summary.mapped_records += 1;
    } else if (isRyeStageRecord(record)) {
      summary.stage_records += 1;
    }
    await commitRecord(target, runNodeId, runId, rowNodeType, scenario, agentId, record);
  }

  await updateRunNodeSummary(target, runNodeId, runId, scenario, summary);
  const completedEventId = await recordRunEvent(
    target,
    runNodeId,
    RYE_TABULAR_INTAKE.runCompletedEventType,
    `Tabular intake run ${runId} completed`,
    buildRunEventProperties({
      runId,
      scenario,
      phase: "completed",
      summary,
      inputKinds: runContext.inputKinds,
      mappings: runContext.mappings,
      stageStatuses: runContext.stageStatuses,
      sourceFiles: runContext.sourceFiles,
      runFingerprintSha1: runContext.runFingerprintSha1,
    }),
    agentId,
  );

  process.stdout.write(
    `${JSON.stringify({
      kind: "tabular_commit_rye_summary",
      schema_type: "rye.tabular_intake.commit_summary.v1",
      schema_version: 1,
      run_id: runId,
      run_node_id: runNodeId,
      started_event_id: startedEventId,
      completed_event_id: completedEventId,
      scenario,
      input_kinds: runContext.inputKinds,
      mappings: runContext.mappings,
      stage_statuses: runContext.stageStatuses,
      source_files: runContext.sourceFiles,
      run_fingerprint_sha1: runContext.runFingerprintSha1,
      ...summary,
    })}\n`,
  );
});

interface SourceFileFingerprint {
  path: string;
  format: string;
  table_name: string;
  sheet_name: string | null;
  content_sha1: string;
}

interface RunContext {
  inputKinds: string[];
  mappings: string[];
  stageStatuses: string[];
  sourceFiles: SourceFileFingerprint[];
  runFingerprintSha1: string;
}

async function buildRunContext(records: PipelineRecord[]): Promise<RunContext> {
  const inputKinds = uniqueSorted(records.map((record) => record.kind));
  const mappings = uniqueSorted(
    records.filter(isMappedRecord).map((record) => record.mapping),
  );
  const stageStatuses = uniqueSorted(
    records
      .filter(isRyeStageRecord)
      .map((record) => (typeof record.properties.ingest_status === "string" ? record.properties.ingest_status : "staged")),
  );
  const sourceFiles = await fingerprintSourceFiles(records);
  const runFingerprintPayload = JSON.stringify({
    input_kinds: inputKinds,
    mappings,
    stage_statuses: stageStatuses,
    source_files: sourceFiles.map((sourceFile) => ({
      format: sourceFile.format,
      table_name: sourceFile.table_name,
      sheet_name: sourceFile.sheet_name,
      content_sha1: sourceFile.content_sha1,
    })),
  });

  return {
    inputKinds,
    mappings,
    stageStatuses,
    sourceFiles,
    runFingerprintSha1: crypto.createHash("sha1").update(runFingerprintPayload).digest("hex"),
  };
}

async function fingerprintSourceFiles(records: PipelineRecord[]): Promise<SourceFileFingerprint[]> {
  const byPath = new Map<string, SourceDescriptor>();
  for (const record of records) {
    if (!byPath.has(record.source.path)) {
      byPath.set(record.source.path, record.source);
    }
  }

  const fingerprints: SourceFileFingerprint[] = [];
  for (const descriptor of byPath.values()) {
    const absolutePath = path.resolve(descriptor.path);
    const contentSha1 = await hashFileSha1(absolutePath);
    fingerprints.push({
      path: absolutePath,
      format: descriptor.format,
      table_name: descriptor.table_name,
      sheet_name: descriptor.sheet_name,
      content_sha1: contentSha1,
    });
  }

  return fingerprints.sort((left, right) => left.path.localeCompare(right.path));
}

async function hashFileSha1(filePath: string): Promise<string> {
  await fs.promises.access(filePath, fs.constants.R_OK);

  return await new Promise<string>((resolve, reject) => {
    const hash = crypto.createHash("sha1");
    const stream = fs.createReadStream(filePath);
    stream.on("data", (chunk) => hash.update(chunk));
    stream.on("error", (error) => {
      reject(
        new CliError(
          "source_file_unreadable",
          `Could not read source file for SHA1 fingerprinting: ${filePath}`,
          error.message,
          [`Ensure the original CSV or XLSX source file still exists and is readable.`, `Use --allow-duplicate-source to bypass duplicate detection if needed.`],
        ),
      );
    });
    stream.on("end", () => resolve(hash.digest("hex")));
  });
}

async function rejectDuplicateRun(target: PsqlTarget, runId: string, runContext: RunContext): Promise<void> {
  const sql = `
SET search_path = rye, public, pg_catalog;
SELECT external_id
FROM rye.nodes
WHERE external_source = ${sqlText(RYE_TABULAR_INTAKE.runExternalSource)}
  AND archived_at IS NULL
  AND external_id <> ${sqlText(runId)}
  AND properties->>'run_fingerprint_sha1' = ${sqlText(runContext.runFingerprintSha1)}
LIMIT 1;`;
  const existingRunId = (await runPsqlCapture(target, ["-Atqc", sql], undefined, repoRoot)).trim();
  if (existingRunId.length > 0) {
    throw new CliError(
      "duplicate_source_run",
      "A run with the same source-file SHA1 fingerprint and run kind already exists.",
      `Existing run_id: ${existingRunId}; fingerprint: ${runContext.runFingerprintSha1}`,
      [
        `Reuse the existing run instead of committing a duplicate.`,
        `If you intend to reprocess the same file, rerun with --allow-duplicate-source.`,
      ],
    );
  }
}

async function upsertRunNode(
  target: PsqlTarget,
  runId: string,
  nodeType: string,
  scenario: string | undefined,
  inputPath: string,
  runContext: RunContext,
): Promise<string> {
  const properties = buildRunNodeProperties({
    runId,
    scenario,
    inputPath: path.resolve(inputPath),
    inputKinds: runContext.inputKinds,
    mappings: runContext.mappings,
    stageStatuses: runContext.stageStatuses,
    sourceFiles: runContext.sourceFiles,
    runFingerprintSha1: runContext.runFingerprintSha1,
  });
  await assertValidPayload(
    "rye_run_node_properties.schema.json",
    properties,
    `Run node properties for run ${runId}`,
  );
  const sql = `
SET search_path = rye, public, pg_catalog;
WITH existing AS (
    SELECT id FROM rye.nodes
    WHERE external_source = ${sqlText(RYE_TABULAR_INTAKE.runExternalSource)}
      AND external_id = ${sqlText(runId)}
      AND archived_at IS NULL
),
updated AS (
    UPDATE rye.nodes
    SET label = ${sqlText(`Tabular intake run ${runId}`)},
        properties = properties || ${sqlJson(JSON.stringify(properties))},
        updated_at = now()
    WHERE id IN (SELECT id FROM existing)
    RETURNING id
),
inserted AS (
    INSERT INTO rye.nodes (node_type, label, external_source, external_id, properties)
    SELECT ${sqlText(nodeType)},
           ${sqlText(`Tabular intake run ${runId}`)},
           ${sqlText(RYE_TABULAR_INTAKE.runExternalSource)},
           ${sqlText(runId)},
           ${sqlJson(JSON.stringify(properties))}
    WHERE NOT EXISTS (SELECT 1 FROM existing)
    RETURNING id
)
SELECT id FROM updated
UNION ALL
SELECT id FROM inserted;`;

  return (await runPsqlCapture(target, ["-Atqc", sql], undefined, repoRoot)).trim();
}

async function recordRunEvent(
  target: PsqlTarget,
  runNodeId: string,
  eventType: string,
  summary: string,
  properties: Record<string, unknown>,
  agentId: string,
): Promise<string> {
  await assertValidPayload(
    "rye_run_event_properties.schema.json",
    properties,
    `Run event properties for ${eventType}`,
  );
  const sql = `
SET search_path = rye, public, pg_catalog;
SELECT rye.record_event(
  p_event_type := ${sqlText(eventType)},
  p_summary := ${sqlText(summary)},
  p_properties := ${sqlJson(JSON.stringify(properties))},
  p_participant_ids := ARRAY[${sqlText(runNodeId)}::uuid],
  p_participant_roles := ARRAY['run'],
  p_actor := ${sqlText(`agent:${agentId}`)}
);`;
  return (await runPsqlCapture(target, ["-Atqc", sql], undefined, repoRoot)).trim();
}

async function ensureSourceArtifacts(
  target: PsqlTarget,
  runNodeId: string,
  startedEventId: string,
  sourceFiles: SourceFileFingerprint[],
  scenario: string | undefined,
): Promise<void> {
  for (const sourceFile of sourceFiles) {
    const descriptor: SourceDescriptor = {
      path: sourceFile.path,
      format: sourceFile.format as SourceDescriptor["format"],
      table_name: sourceFile.table_name,
      sheet_name: sourceFile.sheet_name,
      header_row: 1,
      row_number: 1,
      record_number: 1,
    };
    const content = buildSourceFileArtifactContent({
      descriptor,
      scenario,
      contentSha1: sourceFile.content_sha1,
    });
    const location = buildSourceFileArtifactLocation(descriptor);
    await assertValidPayload(
      "rye_source_file_artifact_content.schema.json",
      content,
      `Source file artifact content for ${sourceFile.path}`,
    );
    await assertValidPayload(
      "rye_source_file_artifact_location.schema.json",
      location,
      `Source file artifact location for ${sourceFile.path}`,
    );
    const sql = `
SET search_path = rye, public, pg_catalog;
SELECT rye.record_artifact(
  p_artifact_type := ${sqlText(RYE_TABULAR_INTAKE.sourceFileArtifactType)},
  p_content := ${sqlJson(JSON.stringify(content))},
  p_source_event_id := ${sqlText(startedEventId)}::uuid,
  p_source_node_id := ${sqlText(runNodeId)}::uuid,
  p_related_node_ids := ARRAY[${sqlText(runNodeId)}::uuid],
  p_location := ${sqlJson(JSON.stringify(location))},
  p_content_hash := ${sqlText(`sha1:${sourceFile.content_sha1}`)}
);`;
    await runPsql(target, ["-v", "ON_ERROR_STOP=1", "-c", sql], undefined, repoRoot);
  }
}

async function commitRecord(
  target: PsqlTarget,
  runNodeId: string,
  runId: string,
  rowNodeType: string,
  scenario: string | undefined,
  agentId: string,
  record: PipelineRecord,
): Promise<void> {
  const rowKey = buildRowKey(record.source);
  const assertionKey = assertionKeyForRecord(runId, record);
  const payloadHash = crypto.createHash("sha256").update(JSON.stringify(record)).digest("hex");
  const claim = buildClaim({
    runId,
    scenario,
    record,
    payloadHash,
  });
  const rowNodeProperties = buildRowNodeProperties({
    record,
    runId,
    scenario,
  });
  const eventProperties = buildRowEventProperties({
    runId,
    scenario,
    record,
  });
  await assertValidPayload(
    "rye_row_node_properties.schema.json",
    rowNodeProperties,
    `Row node properties for ${rowKey}`,
  );
  await assertValidPayload(
    "rye_row_event_properties.schema.json",
    eventProperties,
    `Row event properties for ${rowKey}`,
  );
  await assertValidPayload(
    schemaFileForClaim(record),
    claim,
    `Assertion claim for ${rowKey}`,
  );

  const sql = `
SET search_path = rye, public, pg_catalog;
WITH existing AS (
    SELECT id FROM rye.nodes
    WHERE external_source = ${sqlText(RYE_TABULAR_INTAKE.rowExternalSource)}
      AND external_id = ${sqlText(rowKey)}
      AND archived_at IS NULL
),
updated AS (
    UPDATE rye.nodes
    SET label = ${sqlText(labelForRecord(record))},
        properties = properties || ${sqlJson(JSON.stringify(rowNodeProperties))},
        updated_at = now()
    WHERE id IN (SELECT id FROM existing)
    RETURNING id
),
inserted AS (
    INSERT INTO rye.nodes (node_type, label, external_source, external_id, properties)
    SELECT ${sqlText(rowNodeType)},
           ${sqlText(labelForRecord(record))},
           ${sqlText(RYE_TABULAR_INTAKE.rowExternalSource)},
           ${sqlText(rowKey)},
           ${sqlJson(JSON.stringify(rowNodeProperties))}
    WHERE NOT EXISTS (SELECT 1 FROM existing)
    RETURNING id
),
node_ref AS (
    SELECT id FROM updated
    UNION ALL
    SELECT id FROM inserted
),
event_ref AS (
    SELECT rye.record_event(
      p_event_type := ${sqlText(eventTypeForRecord(record))},
      p_summary := ${sqlText(summaryForRecord(record))},
      p_properties := ${sqlJson(JSON.stringify(eventProperties))},
      p_participant_ids := ARRAY[${sqlText(runNodeId)}::uuid, (SELECT id FROM node_ref)],
      p_participant_roles := ARRAY['run', 'subject'],
      p_actor := ${sqlText(`agent:${agentId}`)}
    ) AS id
)
INSERT INTO rye.assertions (
    assertion_type,
    assertion_key,
    subject_node_id,
    claim,
    source_event_id,
    confidence
)
SELECT
    ${sqlText(assertionTypeForRecord(record))},
    ${sqlText(assertionKey)},
    (SELECT id FROM node_ref),
    ${sqlJson(JSON.stringify(claim))},
    (SELECT id FROM event_ref),
    1.0
WHERE NOT EXISTS (
    SELECT 1
    FROM rye.assertions
    WHERE subject_node_id = (SELECT id FROM node_ref)
      AND assertion_type = ${sqlText(assertionTypeForRecord(record))}
      AND assertion_key = ${sqlText(assertionKey)}
      AND claim->>'payload_hash' = ${sqlText(claim.payload_hash)}
      AND superseded_at IS NULL
);`;

  await runPsql(target, ["-v", "ON_ERROR_STOP=1", "-c", sql], undefined, repoRoot);
}

async function updateRunNodeSummary(
  target: PsqlTarget,
  runNodeId: string,
  runId: string,
  scenario: string | undefined,
  summary: Record<string, number>,
): Promise<void> {
  const inputPathSql = `
SET search_path = rye, public, pg_catalog;
SELECT COALESCE(properties->>'input_path', '')
FROM rye.nodes
WHERE id = ${sqlText(runNodeId)}::uuid;`;
  const inputPath = (await runPsqlCapture(target, ["-Atqc", inputPathSql], undefined, repoRoot)).trim();
  const currentProperties = await fetchRunProperties(target, runNodeId);
  const properties = buildRunNodeProperties({
    runId,
    scenario,
    inputPath,
    completedAt: new Date().toISOString(),
    summary,
    inputKinds: currentProperties.input_kinds,
    mappings: currentProperties.mappings,
    stageStatuses: currentProperties.stage_statuses,
    sourceFiles: currentProperties.source_files,
    runFingerprintSha1: currentProperties.run_fingerprint_sha1,
  });
  await assertValidPayload(
    "rye_run_node_properties.schema.json",
    properties,
    `Completed run node properties for run ${runId}`,
  );
  const sql = `
SET search_path = rye, public, pg_catalog;
UPDATE rye.nodes
SET properties = properties || ${sqlJson(JSON.stringify(properties))},
    updated_at = now()
WHERE id = ${sqlText(runNodeId)}::uuid;`;
  await runPsql(target, ["-v", "ON_ERROR_STOP=1", "-c", sql], undefined, repoRoot);
}

interface ExistingRunProperties {
  input_kinds: string[];
  mappings: string[];
  stage_statuses: string[];
  source_files: SourceFileFingerprint[];
  run_fingerprint_sha1: string | null;
}

async function fetchRunProperties(target: PsqlTarget, runNodeId: string): Promise<ExistingRunProperties> {
  const sql = `
SET search_path = rye, public, pg_catalog;
SELECT properties::text
FROM rye.nodes
WHERE id = ${sqlText(runNodeId)}::uuid;`;
  const stdout = (await runPsqlCapture(target, ["-Atqc", sql], undefined, repoRoot)).trim();
  const properties = JSON.parse(stdout) as Record<string, unknown>;
  return {
    input_kinds: Array.isArray(properties.input_kinds) ? properties.input_kinds.filter((value): value is string => typeof value === "string") : [],
    mappings: Array.isArray(properties.mappings) ? properties.mappings.filter((value): value is string => typeof value === "string") : [],
    stage_statuses: Array.isArray(properties.stage_statuses) ? properties.stage_statuses.filter((value): value is string => typeof value === "string") : [],
    source_files: Array.isArray(properties.source_files) ? properties.source_files.filter(isSourceFileFingerprint) : [],
    run_fingerprint_sha1: typeof properties.run_fingerprint_sha1 === "string" ? properties.run_fingerprint_sha1 : null,
  };
}

function isSourceFileFingerprint(value: unknown): value is SourceFileFingerprint {
  return Boolean(value)
    && typeof value === "object"
    && typeof (value as { path?: unknown }).path === "string"
    && typeof (value as { format?: unknown }).format === "string"
    && typeof (value as { table_name?: unknown }).table_name === "string"
    && ("sheet_name" in (value as Record<string, unknown>))
    && typeof (value as { content_sha1?: unknown }).content_sha1 === "string";
}

function buildRowKey(source: SourceDescriptor): string {
  return crypto
    .createHash("sha256")
    .update(`${source.path}|${source.table_name}|${source.sheet_name ?? ""}|${source.row_number}|${source.record_number}`)
    .digest("hex");
}

function labelForRecord(record: PipelineRecord): string {
  return isRyeStageRecord(record) ? record.label : `${record.source.table_name} row ${record.source.row_number}`;
}

function assertionKeyForRecord(runId: string, record: PipelineRecord): string {
  if (isSourceRow(record)) {
    return `${runId}:source_row`;
  }
  if (isMappedRecord(record)) {
    const digest = crypto.createHash("sha256").update(JSON.stringify(record.record)).digest("hex").slice(0, 12);
    return `${runId}:mapped:${record.mapping}:${record.destination_table}:${digest}`;
  }
  return `${runId}:stage:${String(record.properties.ingest_status ?? "staged")}`;
}

async function assertValidPayload(schemaFile: string, value: unknown, context: string): Promise<void> {
  const errors = await validateSchemaFile(schemaFile, value);
  if (errors.length > 0) {
    throw new CliError(
      "invalid_rye_payload",
      `${context} did not match the Rye tabular-intake JSON schema.`,
      errors.join("; "),
      [
        `Inspect skills/rye-tabular-intake/assets/schemas/${schemaFile}.`,
        `Check the upstream extraction, mapping, or staging output for unexpected values.`,
      ],
    );
  }
}
