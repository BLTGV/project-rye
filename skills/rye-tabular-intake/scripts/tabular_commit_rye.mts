#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  CliError,
  getRequiredString,
  getString,
  hasFlag,
  runCli,
  type HelpSpec,
} from "./lib/cli.mts";
import {
  isMappedRecord,
  isPipelineRecord,
  isRyeStageRecord,
  isSourceRow,
  primarySourceFromRecord,
  sourceKey,
  sourceSetFromRecord,
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
    "node skills/rye-tabular-intake/scripts/tabular_commit_rye.mts --emit-sql --input <ndjson>",
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
    { flag: "--emit-sql", description: "Print a PostgreSQL SQL script instead of connecting to the database." },
    { flag: "--help", description: "Print command help." },
  ],
  examples: [
    "node skills/rye-tabular-intake/scripts/tabular_commit_rye.mts --db-url postgresql://rye:rye@127.0.0.1:54329/rye --input /tmp/source_rows.ndjson --run-id customer-import-2026-03-10",
    "node skills/rye-tabular-intake/scripts/tabular_commit_rye.mts --docker-container rye-fixture-db --input /tmp/stage_rows.ndjson --scenario contacts-basic",
    "node skills/rye-tabular-intake/scripts/tabular_commit_rye.mts --emit-sql --input /tmp/stage_rows.ndjson --run-id customer-import-2026-03-10",
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

  const emitSql = hasFlag(args, "emit-sql");
  const runId = getString(args, "run-id") ?? crypto.randomUUID();
  const runNodeType = getString(args, "run-node-type") ?? RYE_TABULAR_INTAKE.defaultRunNodeType;
  const rowNodeType = getString(args, "row-node-type") ?? RYE_TABULAR_INTAKE.defaultRowNodeType;
  const scenario = getString(args, "scenario");
  const agentId = getString(args, "agent-id") ?? RYE_TABULAR_INTAKE.defaultAgentId;
  const allowDuplicateSource = getString(args, "allow-duplicate-source") === "true";
  const runContext = await buildRunContext(records);
  const summary = summarizeRecords(records);

  if (emitSql) {
    process.stdout.write(await buildSqlOnlyCommit({
      inputPath,
      records,
      runId,
      runNodeType,
      rowNodeType,
      scenario,
      agentId,
      allowDuplicateSource,
      runContext,
      summary,
    }));
    return;
  }

  const target = buildPsqlTarget({
    dbUrl: getString(args, "db-url"),
    dockerContainer: getString(args, "docker-container"),
    dockerUser: getString(args, "docker-user") ?? "rye",
    dockerDb: getString(args, "docker-db") ?? "rye",
  });

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

  for (const record of records) {
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

interface CommitSummary {
  source_rows: number;
  mapped_records: number;
  stage_records: number;
}

interface SqlOnlyCommitInput {
  inputPath: string;
  records: PipelineRecord[];
  runId: string;
  runNodeType: string;
  rowNodeType: string;
  scenario?: string;
  agentId: string;
  allowDuplicateSource: boolean;
  runContext: RunContext;
  summary: CommitSummary;
}

function summarizeRecords(records: PipelineRecord[]): CommitSummary {
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
  }

  return summary;
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
    for (const source of sourceSetFromRecord(record).sources) {
      if (!byPath.has(source.path)) {
        byPath.set(source.path, source);
      }
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

async function buildSqlOnlyCommit(input: SqlOnlyCommitInput): Promise<string> {
  const lines: string[] = [];
  const inputPath = path.resolve(input.inputPath);

  lines.push("-- Rye tabular intake SQL-only commit.");
  lines.push("-- Execute this whole script in one database session, for example through a SQL console or SQL-execution MCP tool.");
  lines.push("BEGIN;");
  lines.push("SET LOCAL search_path = rye, public, pg_catalog;");
  lines.push("");
  lines.push("CREATE TEMP TABLE IF NOT EXISTS _rye_tabular_intake_context (");
  lines.push("    key text PRIMARY KEY,");
  lines.push("    value text NOT NULL");
  lines.push(");");
  lines.push("TRUNCATE _rye_tabular_intake_context;");
  lines.push("");

  if (!input.allowDuplicateSource) {
    lines.push(buildDuplicateGuardSql(input.runId, input.runContext));
    lines.push("");
  }

  lines.push(await buildSqlOnlyRunNodeSql(input, inputPath));
  lines.push("");
  lines.push(await buildSqlOnlyRunEventSql({
    runId: input.runId,
    scenario: input.scenario,
    eventType: RYE_TABULAR_INTAKE.runStartedEventType,
    summary: `Tabular intake run ${input.runId} started`,
    properties: buildRunEventProperties({
      runId: input.runId,
      scenario: input.scenario,
      phase: "started",
      inputPath,
      inputRecords: input.records.length,
      inputKinds: input.runContext.inputKinds,
      mappings: input.runContext.mappings,
      stageStatuses: input.runContext.stageStatuses,
      sourceFiles: input.runContext.sourceFiles,
      runFingerprintSha1: input.runContext.runFingerprintSha1,
    }),
    agentId: input.agentId,
    contextKey: "started_event_id",
  }));
  lines.push("");

  for (const sourceFile of input.runContext.sourceFiles) {
    lines.push(await buildSqlOnlySourceArtifactSql(sourceFile, input.scenario));
    lines.push("");
  }

  for (const record of input.records) {
    lines.push(await buildSqlOnlyRecordSql({
      runId: input.runId,
      rowNodeType: input.rowNodeType,
      scenario: input.scenario,
      agentId: input.agentId,
      record,
    }));
    lines.push("");
  }

  lines.push(await buildSqlOnlyRunSummarySql(input, inputPath));
  lines.push("");
  lines.push(await buildSqlOnlyRunEventSql({
    runId: input.runId,
    scenario: input.scenario,
    eventType: RYE_TABULAR_INTAKE.runCompletedEventType,
    summary: `Tabular intake run ${input.runId} completed`,
    properties: buildRunEventProperties({
      runId: input.runId,
      scenario: input.scenario,
      phase: "completed",
      summary: input.summary,
      inputKinds: input.runContext.inputKinds,
      mappings: input.runContext.mappings,
      stageStatuses: input.runContext.stageStatuses,
      sourceFiles: input.runContext.sourceFiles,
      runFingerprintSha1: input.runContext.runFingerprintSha1,
    }),
    agentId: input.agentId,
    contextKey: "completed_event_id",
  }));
  lines.push("");
  lines.push("COMMIT;");
  lines.push("");
  lines.push(buildSqlOnlySummarySelect(input));

  return `${lines.join("\n")}\n`;
}

function buildDuplicateGuardSql(runId: string, runContext: RunContext): string {
  return `DO $rye_tabular_intake$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM rye.nodes
    WHERE external_source = ${sqlText(RYE_TABULAR_INTAKE.runExternalSource)}
      AND archived_at IS NULL
      AND external_id <> ${sqlText(runId)}
      AND properties->>'run_fingerprint_sha1' = ${sqlText(runContext.runFingerprintSha1)}
  ) THEN
    RAISE EXCEPTION 'duplicate_source_run: fingerprint ${runContext.runFingerprintSha1} already exists';
  END IF;
END
$rye_tabular_intake$;`;
}

async function buildSqlOnlyRunNodeSql(input: SqlOnlyCommitInput, inputPath: string): Promise<string> {
  const properties = buildRunNodeProperties({
    runId: input.runId,
    scenario: input.scenario,
    inputPath,
    inputKinds: input.runContext.inputKinds,
    mappings: input.runContext.mappings,
    stageStatuses: input.runContext.stageStatuses,
    sourceFiles: input.runContext.sourceFiles,
    runFingerprintSha1: input.runContext.runFingerprintSha1,
  });
  await assertValidPayload(
    "rye_run_node_properties.schema.json",
    properties,
    `Run node properties for run ${input.runId}`,
  );

  return `WITH existing AS (
    SELECT id FROM rye.nodes
    WHERE external_source = ${sqlText(RYE_TABULAR_INTAKE.runExternalSource)}
      AND external_id = ${sqlText(input.runId)}
      AND archived_at IS NULL
),
updated AS (
    UPDATE rye.nodes
    SET label = ${sqlText(`Tabular intake run ${input.runId}`)},
        properties = properties || ${sqlJson(JSON.stringify(properties))},
        updated_at = now()
    WHERE id IN (SELECT id FROM existing)
    RETURNING id
),
inserted AS (
    INSERT INTO rye.nodes (node_type, label, external_source, external_id, properties)
    SELECT ${sqlText(input.runNodeType)},
           ${sqlText(`Tabular intake run ${input.runId}`)},
           ${sqlText(RYE_TABULAR_INTAKE.runExternalSource)},
           ${sqlText(input.runId)},
           ${sqlJson(JSON.stringify(properties))}
    WHERE NOT EXISTS (SELECT 1 FROM existing)
    RETURNING id
),
run_ref AS (
    SELECT id FROM updated
    UNION ALL
    SELECT id FROM inserted
)
INSERT INTO _rye_tabular_intake_context (key, value)
SELECT 'run_node_id', id::text FROM run_ref
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;`;
}

async function buildSqlOnlyRunEventSql(input: {
  runId: string;
  scenario?: string;
  eventType: string;
  summary: string;
  properties: Record<string, unknown>;
  agentId: string;
  contextKey: "started_event_id" | "completed_event_id";
}): Promise<string> {
  await assertValidPayload(
    "rye_run_event_properties.schema.json",
    input.properties,
    `Run event properties for ${input.eventType}`,
  );

  return `WITH event_ref AS (
    SELECT rye.record_event(
      p_event_type := ${sqlText(input.eventType)},
      p_summary := ${sqlText(input.summary)},
      p_properties := ${sqlJson(JSON.stringify(input.properties))},
      p_participant_ids := ARRAY[${ctxUuid("run_node_id")}],
      p_participant_roles := ARRAY['run'],
      p_actor := ${sqlText(`agent:${input.agentId}`)}
    ) AS id
)
INSERT INTO _rye_tabular_intake_context (key, value)
SELECT ${sqlText(input.contextKey)}, id::text FROM event_ref
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;`;
}

async function buildSqlOnlySourceArtifactSql(
  sourceFile: SourceFileFingerprint,
  scenario: string | undefined,
): Promise<string> {
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

  return `SELECT rye.record_artifact(
  p_artifact_type := ${sqlText(RYE_TABULAR_INTAKE.sourceFileArtifactType)},
  p_content := ${sqlJson(JSON.stringify(content))},
  p_source_event_id := ${ctxUuid("started_event_id")},
  p_source_node_id := ${ctxUuid("run_node_id")},
  p_related_node_ids := ARRAY[${ctxUuid("run_node_id")}],
  p_location := ${sqlJson(JSON.stringify(location))},
  p_content_hash := ${sqlText(`sha1:${sourceFile.content_sha1}`)}
);`;
}

async function buildSqlOnlyRecordSql(input: {
  runId: string;
  rowNodeType: string;
  scenario: string | undefined;
  agentId: string;
  record: PipelineRecord;
}): Promise<string> {
  const rowKey = buildRowKey(input.record);
  const assertionKey = assertionKeyForRecord(input.runId, input.record);
  const payloadHash = crypto.createHash("sha256").update(JSON.stringify(input.record)).digest("hex");
  const claim = buildClaim({
    runId: input.runId,
    scenario: input.scenario,
    record: input.record,
    payloadHash,
  });
  const rowNodeProperties = buildRowNodeProperties({
    record: input.record,
    runId: input.runId,
    scenario: input.scenario,
  });
  const eventProperties = buildRowEventProperties({
    runId: input.runId,
    scenario: input.scenario,
    record: input.record,
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
    schemaFileForClaim(input.record),
    claim,
    `Assertion claim for ${rowKey}`,
  );

  return `WITH existing AS (
    SELECT id FROM rye.nodes
    WHERE external_source = ${sqlText(RYE_TABULAR_INTAKE.rowExternalSource)}
      AND external_id = ${sqlText(rowKey)}
      AND archived_at IS NULL
),
updated AS (
    UPDATE rye.nodes
    SET label = ${sqlText(labelForRecord(input.record))},
        properties = properties || ${sqlJson(JSON.stringify(rowNodeProperties))},
        updated_at = now()
    WHERE id IN (SELECT id FROM existing)
    RETURNING id
),
inserted AS (
    INSERT INTO rye.nodes (node_type, label, external_source, external_id, properties)
    SELECT ${sqlText(input.rowNodeType)},
           ${sqlText(labelForRecord(input.record))},
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
      p_event_type := ${sqlText(eventTypeForRecord(input.record))},
      p_summary := ${sqlText(summaryForRecord(input.record))},
      p_properties := ${sqlJson(JSON.stringify(eventProperties))},
      p_participant_ids := ARRAY[${ctxUuid("run_node_id")}, (SELECT id FROM node_ref)],
      p_participant_roles := ARRAY['run', 'subject'],
      p_actor := ${sqlText(`agent:${input.agentId}`)}
    ) AS id
)
SELECT rye.record_assertion(
    p_assertion_type := ${sqlText(assertionTypeForRecord(input.record))},
    p_assertion_key := ${sqlText(assertionKey)},
    p_subject_node_id := (SELECT id FROM node_ref),
    p_claim := ${sqlJson(JSON.stringify(claim))},
    p_confidence := 1.0,
    p_basis := 'observed',
    p_evidence := ARRAY[
      jsonb_build_object('kind', 'source', 'event_id', (SELECT id FROM event_ref))
    ]
)
WHERE NOT EXISTS (
    SELECT 1
    FROM rye.current_valid_assertions
    WHERE subject_node_id = (SELECT id FROM node_ref)
      AND assertion_type = ${sqlText(assertionTypeForRecord(input.record))}
      AND assertion_key = ${sqlText(assertionKey)}
      AND claim->>'payload_hash' = ${sqlText(claim.payload_hash)}
);`;
}

async function buildSqlOnlyRunSummarySql(input: SqlOnlyCommitInput, inputPath: string): Promise<string> {
  const properties = buildRunNodeProperties({
    runId: input.runId,
    scenario: input.scenario,
    inputPath,
    completedAt: new Date().toISOString(),
    summary: input.summary,
    inputKinds: input.runContext.inputKinds,
    mappings: input.runContext.mappings,
    stageStatuses: input.runContext.stageStatuses,
    sourceFiles: input.runContext.sourceFiles,
    runFingerprintSha1: input.runContext.runFingerprintSha1,
  });
  await assertValidPayload(
    "rye_run_node_properties.schema.json",
    properties,
    `Completed run node properties for run ${input.runId}`,
  );

  return `UPDATE rye.nodes
SET properties = properties || ${sqlJson(JSON.stringify(properties))},
    updated_at = now()
WHERE id = ${ctxUuid("run_node_id")};`;
}

function buildSqlOnlySummarySelect(input: SqlOnlyCommitInput): string {
  return `SELECT json_build_object(
  'kind', 'tabular_commit_rye_summary',
  'schema_type', 'rye.tabular_intake.commit_summary.v1',
  'schema_version', 1,
  'run_id', ${sqlText(input.runId)},
  'run_node_id', (SELECT value FROM _rye_tabular_intake_context WHERE key = 'run_node_id'),
  'started_event_id', (SELECT value FROM _rye_tabular_intake_context WHERE key = 'started_event_id'),
  'completed_event_id', (SELECT value FROM _rye_tabular_intake_context WHERE key = 'completed_event_id'),
  'scenario', ${input.scenario == null ? "NULL" : sqlText(input.scenario)},
  'input_kinds', ${sqlJson(JSON.stringify(input.runContext.inputKinds))},
  'mappings', ${sqlJson(JSON.stringify(input.runContext.mappings))},
  'stage_statuses', ${sqlJson(JSON.stringify(input.runContext.stageStatuses))},
  'source_files', ${sqlJson(JSON.stringify(input.runContext.sourceFiles))},
  'run_fingerprint_sha1', ${sqlText(input.runContext.runFingerprintSha1)},
  'source_rows', ${input.summary.source_rows},
  'mapped_records', ${input.summary.mapped_records},
  'stage_records', ${input.summary.stage_records}
) AS tabular_commit_rye_summary;`;
}

function ctxUuid(key: string): string {
  return `(SELECT value::uuid FROM _rye_tabular_intake_context WHERE key = ${sqlText(key)})`;
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
  const rowKey = buildRowKey(record);
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
SELECT rye.record_assertion(
    p_assertion_type := ${sqlText(assertionTypeForRecord(record))},
    p_assertion_key := ${sqlText(assertionKey)},
    p_subject_node_id := (SELECT id FROM node_ref),
    p_claim := ${sqlJson(JSON.stringify(claim))},
    p_confidence := 1.0,
    p_basis := 'observed',
    p_evidence := ARRAY[
      jsonb_build_object('kind', 'source', 'event_id', (SELECT id FROM event_ref))
    ]
)
WHERE NOT EXISTS (
    SELECT 1
    FROM rye.current_valid_assertions
    WHERE subject_node_id = (SELECT id FROM node_ref)
      AND assertion_type = ${sqlText(assertionTypeForRecord(record))}
      AND assertion_key = ${sqlText(assertionKey)}
      AND claim->>'payload_hash' = ${sqlText(claim.payload_hash)}
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

function buildRowKey(record: PipelineRecord): string {
  const sourceSet = sourceSetFromRecord(record);
  return crypto
    .createHash("sha256")
    .update(JSON.stringify({
      group_key: sourceSet.group_key,
      sources: sourceSet.sources.map(sourceKey),
    }))
    .digest("hex");
}

function labelForRecord(record: PipelineRecord): string {
  if (isRyeStageRecord(record)) {
    return record.label;
  }
  const source = primarySourceFromRecord(record);
  const sourceSet = sourceSetFromRecord(record);
  if (sourceSet.row_count > 1) {
    return `${source.table_name} group ${sourceSet.group_key ?? source.row_number}`;
  }
  return `${source.table_name} row ${source.row_number}`;
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
