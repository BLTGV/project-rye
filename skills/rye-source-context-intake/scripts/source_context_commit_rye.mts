#!/usr/bin/env node
import crypto from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  CliError,
  getRequiredString,
  getString,
  hasFlag,
  runCli,
  type HelpSpec,
} from "../../rye-tabular-intake/scripts/lib/cli.mts";
import { readNdjson } from "../../rye-tabular-intake/scripts/lib/ndjson.mts";
import {
  buildPsqlTarget,
  runPsqlCapture,
  sqlJson,
  sqlText,
} from "../../rye-tabular-intake/scripts/lib/psql_target.mts";

type ConfirmationStatus = "needs_confirmation" | "confirmed" | "rejected";

interface BaseRecord {
  kind: string;
  id?: string;
  label?: string;
  metadata?: Record<string, unknown>;
  evidence?: string[];
}

interface SourceAccountRecord extends BaseRecord {
  kind: "source_account";
  id: string;
  label: string;
  provider?: string;
  confirmation_status?: ConfirmationStatus;
  purpose?: string;
}

interface SourceContainerRecord extends BaseRecord {
  kind: "source_container";
  id: string;
  label: string;
  source_account_id: string;
  container_type?: string;
  confirmation_status?: ConfirmationStatus;
  purpose?: string;
  holding_context_id?: string;
  allowed_context_ids?: string[];
  default_context_ids?: string[];
  never_infer?: string[];
}

interface SourceItemRecord extends BaseRecord {
  kind: "source_item";
  id: string;
  label?: string;
  source_account_id?: string;
  source_container_id?: string;
  item_type: string;
  occurred_at?: string;
  external_url?: string;
  source_value?: string;
  visibility?: string;
  persistence_reason?: string;
  content?: unknown;
  content_hash?: string;
  classification?: {
    context_ids?: string[];
    confidence?: number;
    rationale?: string;
    evidence?: string[];
  };
}

interface ContextProfileRecord extends BaseRecord {
  kind: "context_profile";
  id: string;
  label: string;
  purpose: string;
  relevance_rules?: string[];
  edge_policies?: string[];
  task_policy?: string;
}

interface ContextConfirmationRecord extends BaseRecord {
  kind: "context_confirmation";
  subject_id: string;
  status: ConfirmationStatus;
  confirmed_by?: string;
  confirmed_at?: string;
  purpose?: string;
  allowed_context_ids?: string[];
  default_context_ids?: string[];
  never_infer?: string[];
  notes?: string;
}

type SourceContextRecord =
  | SourceAccountRecord
  | SourceContainerRecord
  | SourceItemRecord
  | ContextProfileRecord
  | ContextConfirmationRecord;

interface Summary {
  records: number;
  source_accounts: number;
  source_containers: number;
  source_items: number;
  context_profiles: number;
  context_confirmations: number;
}

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const externalSource = "source_context";
const contextProfileExternalSource = "context_profile";

const help: HelpSpec = {
  name: "source_context_commit_rye.mts",
  summary: "Validate and commit connector-neutral source context records into Rye.",
  usage: [
    "node skills/rye-source-context-intake/scripts/source_context_commit_rye.mts --validate-only --input <ndjson>",
    "node skills/rye-source-context-intake/scripts/source_context_commit_rye.mts --emit-sql --input <ndjson>",
    "node skills/rye-source-context-intake/scripts/source_context_commit_rye.mts (--db-url <postgresql://...> | --docker-container <name>) --input <ndjson>",
  ],
  options: [
    { flag: "--input <path>", description: "NDJSON file containing source context records." },
    { flag: "--db-url <url>", description: "Target PostgreSQL database URL." },
    { flag: "--docker-container <name>", description: "Run psql through docker exec against a running Postgres container." },
    { flag: "--docker-user <name>", description: "Database user for --docker-container. Default: rye." },
    { flag: "--docker-db <name>", description: "Database name for --docker-container. Default: rye." },
    { flag: "--run-id <value>", description: "Stable run identifier. Default: generated UUID." },
    { flag: "--agent-id <value>", description: "Actor label used on Rye events. Default: rye_source_context_intake." },
    { flag: "--validate-only", description: "Validate input and print a JSON summary without writing." },
    { flag: "--emit-sql", description: "Print a PostgreSQL SQL script instead of connecting to the database." },
    { flag: "--help", description: "Print command help." },
  ],
  examples: [
    "node skills/rye-source-context-intake/scripts/source_context_commit_rye.mts --validate-only --input /tmp/source-context.ndjson",
    "node skills/rye-source-context-intake/scripts/source_context_commit_rye.mts --emit-sql --input /tmp/source-context.ndjson > /tmp/source-context.sql",
    "node skills/rye-source-context-intake/scripts/source_context_commit_rye.mts --db-url postgresql://rye:rye@127.0.0.1:54329/rye --input /tmp/source-context.ndjson",
  ],
};

await runCli(help, async (args) => {
  const inputPath = getRequiredString(args, "input", help.name);
  const records: SourceContextRecord[] = [];
  let lineNumber = 0;

  for await (const value of readNdjson(inputPath)) {
    lineNumber += 1;
    records.push(validateRecord(value, lineNumber));
  }

  validateReferences(records);

  const runId = getString(args, "run-id") ?? crypto.randomUUID();
  const agentId = getString(args, "agent-id") ?? "rye_source_context_intake";
  const summary = summarize(records);

  if (hasFlag(args, "validate-only")) {
    process.stdout.write(`${JSON.stringify({ ok: true, run_id: runId, summary })}\n`);
    return;
  }

  const sql = buildCommitSql(records, runId, agentId, summary);

  if (hasFlag(args, "emit-sql")) {
    process.stdout.write(sql);
    return;
  }

  const target = buildPsqlTarget({
    dbUrl: getString(args, "db-url"),
    dockerContainer: getString(args, "docker-container"),
    dockerUser: getString(args, "docker-user") ?? "rye",
    dockerDb: getString(args, "docker-db") ?? "rye",
  });
  const output = await runPsqlCapture(target, ["-Atq", "-v", "ON_ERROR_STOP=1", "-f", "-"], sql, repoRoot);
  process.stdout.write(output.trim() ? `${output.trim()}\n` : `${JSON.stringify({ ok: true, run_id: runId, summary })}\n`);
});

function validateRecord(value: unknown, lineNumber: number): SourceContextRecord {
  if (!isObject(value)) {
    throw invalid(lineNumber, "Record must be a JSON object.");
  }

  const kind = requiredString(value, "kind", lineNumber);
  switch (kind) {
    case "source_account":
      return {
        ...value,
        id: requiredString(value, "id", lineNumber),
        label: requiredString(value, "label", lineNumber),
        provider: optionalString(value, "provider", lineNumber),
        confirmation_status: optionalStatus(value, "confirmation_status", lineNumber) ?? "needs_confirmation",
        purpose: optionalString(value, "purpose", lineNumber),
        metadata: optionalObject(value, "metadata", lineNumber),
        evidence: optionalStringArray(value, "evidence", lineNumber),
      } as SourceAccountRecord;

    case "source_container": {
      const record = {
        ...value,
        id: requiredString(value, "id", lineNumber),
        label: requiredString(value, "label", lineNumber),
        source_account_id: requiredString(value, "source_account_id", lineNumber),
        container_type: optionalString(value, "container_type", lineNumber),
        confirmation_status: optionalStatus(value, "confirmation_status", lineNumber) ?? "needs_confirmation",
        purpose: optionalString(value, "purpose", lineNumber),
        holding_context_id: optionalString(value, "holding_context_id", lineNumber),
        allowed_context_ids: optionalStringArray(value, "allowed_context_ids", lineNumber),
        default_context_ids: optionalStringArray(value, "default_context_ids", lineNumber),
        never_infer: optionalStringArray(value, "never_infer", lineNumber),
        metadata: optionalObject(value, "metadata", lineNumber),
        evidence: optionalStringArray(value, "evidence", lineNumber),
      } as SourceContainerRecord;
      if (record.default_context_ids && record.default_context_ids.length > 0 && record.confirmation_status !== "confirmed") {
        throw invalid(lineNumber, "`default_context_ids` requires `confirmation_status: \"confirmed\"`. Use `holding_context_id` while unconfirmed.");
      }
      return record;
    }

    case "source_item": {
      const record = {
        ...value,
        id: requiredString(value, "id", lineNumber),
        label: optionalString(value, "label", lineNumber),
        source_account_id: optionalString(value, "source_account_id", lineNumber),
        source_container_id: optionalString(value, "source_container_id", lineNumber),
        item_type: requiredString(value, "item_type", lineNumber),
        occurred_at: optionalTimestamp(value, "occurred_at", lineNumber),
        external_url: optionalUrl(value, "external_url", lineNumber),
        source_value: optionalString(value, "source_value", lineNumber),
        visibility: optionalString(value, "visibility", lineNumber),
        persistence_reason: optionalString(value, "persistence_reason", lineNumber),
        content_hash: optionalString(value, "content_hash", lineNumber),
        metadata: optionalObject(value, "metadata", lineNumber),
        evidence: optionalStringArray(value, "evidence", lineNumber),
        classification: optionalClassification(value, lineNumber),
      } as SourceItemRecord;
      if (!record.source_account_id && !record.source_container_id) {
        throw invalid(lineNumber, "`source_item` requires `source_account_id` or `source_container_id`.");
      }
      return record;
    }

    case "context_profile":
      return {
        ...value,
        id: requiredString(value, "id", lineNumber),
        label: requiredString(value, "label", lineNumber),
        purpose: requiredString(value, "purpose", lineNumber),
        relevance_rules: optionalStringArray(value, "relevance_rules", lineNumber),
        edge_policies: optionalStringArray(value, "edge_policies", lineNumber),
        task_policy: optionalString(value, "task_policy", lineNumber),
        metadata: optionalObject(value, "metadata", lineNumber),
        evidence: optionalStringArray(value, "evidence", lineNumber),
      } as ContextProfileRecord;

    case "context_confirmation": {
      const record = {
        ...value,
        subject_id: requiredString(value, "subject_id", lineNumber),
        status: requiredStatus(value, "status", lineNumber),
        confirmed_by: optionalString(value, "confirmed_by", lineNumber),
        confirmed_at: optionalTimestamp(value, "confirmed_at", lineNumber),
        purpose: optionalString(value, "purpose", lineNumber),
        allowed_context_ids: optionalStringArray(value, "allowed_context_ids", lineNumber),
        default_context_ids: optionalStringArray(value, "default_context_ids", lineNumber),
        never_infer: optionalStringArray(value, "never_infer", lineNumber),
        notes: optionalString(value, "notes", lineNumber),
        evidence: optionalStringArray(value, "evidence", lineNumber),
        metadata: optionalObject(value, "metadata", lineNumber),
      } as ContextConfirmationRecord;
      if (record.default_context_ids && record.default_context_ids.length > 0 && record.status !== "confirmed") {
        throw invalid(lineNumber, "`context_confirmation.default_context_ids` requires `status: \"confirmed\"`.");
      }
      return record;
    }

    default:
      throw invalid(lineNumber, `Unsupported source context kind: ${kind}`);
  }
}

function validateReferences(records: SourceContextRecord[]): void {
  const inputIds = new Map<string, string>();
  for (const record of records) {
    if (record.kind === "context_confirmation") {
      continue;
    }
    const existingKind = inputIds.get(record.id);
    if (existingKind) {
      throw new CliError(
        "duplicate_source_context_id",
        `Duplicate source context id: ${record.id}`,
        `The id is used by both ${existingKind} and ${record.kind}.`,
        ["Use globally stable IDs across source accounts, containers, items, and context profiles."],
      );
    }
    inputIds.set(record.id, record.kind);
  }

  for (const record of records) {
    if (record.kind === "source_container" && !inputIds.has(record.source_account_id)) {
      continue;
    }
    if (record.kind === "source_item" && record.source_container_id && !inputIds.has(record.source_container_id)) {
      continue;
    }
    if (record.kind === "source_item" && record.source_account_id && !inputIds.has(record.source_account_id)) {
      continue;
    }
  }
}

function buildCommitSql(records: SourceContextRecord[], runId: string, agentId: string, summary: Summary): string {
  const lines: string[] = [];
  lines.push("-- Rye source context intake SQL.");
  lines.push("-- Execute this whole script in one database session, for example through a SQL console or SQL-execution MCP tool.");
  lines.push("BEGIN;");
  lines.push("SET LOCAL search_path = rye, public, pg_catalog;");
  lines.push("DO $rye_source_context_session$");
  lines.push("BEGIN");
  lines.push("  PERFORM set_config('app.current_role', 'admin', false);");
  lines.push("  PERFORM set_config('app.current_user_id', 'rye-source-context-intake', false);");
  lines.push("  PERFORM set_config('app.current_teams', 'system', false);");
  lines.push("END");
  lines.push("$rye_source_context_session$;");
  lines.push("");
  lines.push("CREATE TEMP TABLE IF NOT EXISTS _rye_source_context_ref (key text PRIMARY KEY, value text NOT NULL);");
  lines.push("TRUNCATE _rye_source_context_ref;");
  lines.push("");
  lines.push(buildRunNodeSql(runId, summary));
  lines.push("");
  lines.push(buildRunEventSql(runId, agentId, "source_context_intake_started", `Source context intake ${runId} started`, { run_id: runId, phase: "started", summary }, "started_event_id"));
  lines.push("");

  for (const record of records) {
    if (record.kind !== "context_confirmation") {
      lines.push(buildNodeSql(record));
      lines.push("");
      lines.push(buildRecordObservedEventSql(record, agentId));
      lines.push("");
    }
  }

  for (const record of records) {
    lines.push(...buildSemanticSql(record));
  }

  lines.push(buildRunEventSql(runId, agentId, "source_context_intake_completed", `Source context intake ${runId} completed`, { run_id: runId, phase: "completed", summary }, "completed_event_id"));
  lines.push("");
  lines.push("COMMIT;");
  lines.push("");
  lines.push(`SELECT ${sqlJson(JSON.stringify({ ok: true, run_id: runId, summary }))};`);
  return `${lines.join("\n")}\n`;
}

function buildRunNodeSql(runId: string, summary: Summary): string {
  const properties = {
    run_id: runId,
    summary,
    contract: "rye_source_context_intake.v1",
  };
  return `${upsertNodeSql({
    refKey: "run_node_id",
    nodeType: "source_context_intake_run",
    label: `Source context intake ${runId}`,
    externalSource: "rye_source_context_intake_run",
    externalId: runId,
    properties,
  })}`;
}

function buildNodeSql(record: Exclude<SourceContextRecord, ContextConfirmationRecord>): string {
  return upsertNodeSql({
    refKey: `node:${record.id}`,
    nodeType: nodeTypeFor(record),
    label: labelFor(record),
    externalSource: externalSourceFor(record),
    externalId: record.id,
    properties: propertiesFor(record),
  });
}

function buildRecordObservedEventSql(record: Exclude<SourceContextRecord, ContextConfirmationRecord>, agentId: string): string {
  return buildEventSql({
    refKey: `event:${record.kind}:${record.id}`,
    eventType: "source_context_record_observed",
    summary: `Source context ${record.kind} observed: ${labelFor(record)}`,
    properties: {
      record_kind: record.kind,
      source_context_id: record.id,
      contract: "rye_source_context_intake.v1",
    },
    participantRefs: ["run_node_id", `node:${record.id}`],
    participantRoles: ["run", record.kind],
    agentId,
  });
}

function buildRunEventSql(
  runId: string,
  agentId: string,
  eventType: string,
  summary: string,
  properties: Record<string, unknown>,
  refKey: string,
): string {
  return buildEventSql({
    refKey,
    eventType,
    summary,
    properties,
    participantRefs: ["run_node_id"],
    participantRoles: ["run"],
    agentId,
  });
}

function buildSemanticSql(record: SourceContextRecord): string[] {
  const lines: string[] = [];

  if (record.kind === "source_account") {
    if (record.purpose) {
      lines.push(buildAssertionSql(record.id, "source_purpose", "default", { text: record.purpose }, `event:${record.kind}:${record.id}`));
      lines.push("");
    }
    return lines;
  }

  if (record.kind === "source_container") {
    lines.push(buildEdgeSql(record.source_account_id, record.id, "contains_item", {
      reason_type: "provenance",
      source_context_edge: "account_contains_container",
      contract: "rye_source_context_intake.v1",
    }));
    lines.push("");

    if (record.purpose) {
      lines.push(buildAssertionSql(record.id, "source_purpose", "default", { text: record.purpose }, `event:${record.kind}:${record.id}`));
      lines.push("");
    }
    if (record.holding_context_id) {
      lines.push(buildAssertionSql(record.id, "holding_review_context", record.holding_context_id, { context_id: record.holding_context_id }, `event:${record.kind}:${record.id}`));
      lines.push("");
    }
    if (record.default_context_ids && record.confirmation_status === "confirmed") {
      for (const contextId of record.default_context_ids) {
        lines.push(buildEdgeSql(record.id, contextId, "default_context_for", {
          default: true,
          reason_type: "confirmed_source_context",
          contract: "rye_source_context_intake.v1",
        }));
        lines.push(buildAssertionSql(record.id, "default_review_context", contextId, { context_id: contextId }, `event:${record.kind}:${record.id}`));
        lines.push("");
      }
    }
    return lines;
  }

  if (record.kind === "source_item") {
    const parentId = record.source_container_id ?? record.source_account_id;
    if (parentId) {
      lines.push(buildEdgeSql(parentId, record.id, "contains_item", {
        reason_type: "provenance",
        source_context_edge: "source_contains_item",
        item_type: record.item_type,
        contract: "rye_source_context_intake.v1",
      }));
      lines.push("");
    }
    if (record.content !== undefined || record.metadata !== undefined) {
      lines.push(buildArtifactSql(record));
      lines.push("");
    }
    if (record.classification?.context_ids && record.classification.context_ids.length > 0) {
      for (const contextId of record.classification.context_ids) {
        lines.push(buildEdgeSql(record.id, contextId, "reviewed_under", {
          reason_type: "classification_proposal",
          confidence: record.classification.confidence,
          rationale: record.classification.rationale,
          evidence: record.classification.evidence ?? [],
          contract: "rye_source_context_intake.v1",
        }));
      }
      lines.push(buildAssertionSql(record.id, "classification_rationale", "default", {
        context_ids: record.classification.context_ids,
        confidence: record.classification.confidence,
        text: record.classification.rationale,
        evidence: record.classification.evidence ?? [],
      }, `event:${record.kind}:${record.id}`, record.classification.confidence));
      lines.push("");
    }
    return lines;
  }

  if (record.kind === "context_profile") {
    lines.push(buildAssertionSql(record.id, "purpose", "default", { text: record.purpose }, `event:${record.kind}:${record.id}`));
    lines.push("");
    for (const [index, rule] of (record.relevance_rules ?? []).entries()) {
      lines.push(buildAssertionSql(record.id, "relevance_rule", `rule:${index}`, { text: rule }, `event:${record.kind}:${record.id}`));
      lines.push("");
    }
    for (const [index, policy] of (record.edge_policies ?? []).entries()) {
      lines.push(buildAssertionSql(record.id, "edge_policy", `policy:${index}`, { text: policy }, `event:${record.kind}:${record.id}`));
      lines.push("");
    }
    if (record.task_policy) {
      lines.push(buildAssertionSql(record.id, "task_policy", "default", { text: record.task_policy }, `event:${record.kind}:${record.id}`));
      lines.push("");
    }
    return lines;
  }

  if (record.kind === "context_confirmation") {
    const eventKey = `event:context_confirmation:${record.subject_id}:${record.status}`;
    lines.push(buildConfirmationEventSql(record, eventKey));
    lines.push("");
    lines.push(buildNodePropertyMergeSql(record));
    lines.push("");
    lines.push(buildAssertionSql(record.subject_id, "source_context_confirmation", "default", confirmationClaim(record), eventKey));
    lines.push("");
    if (record.purpose) {
      lines.push(buildAssertionSql(record.subject_id, "source_purpose", "default", { text: record.purpose }, eventKey));
      lines.push("");
    }
    if (record.status === "confirmed") {
      for (const contextId of record.default_context_ids ?? []) {
        lines.push(buildEdgeSql(record.subject_id, contextId, "default_context_for", {
          default: true,
          reason_type: "confirmed_source_context",
          contract: "rye_source_context_intake.v1",
        }));
        lines.push(buildAssertionSql(record.subject_id, "default_review_context", contextId, { context_id: contextId }, eventKey));
        lines.push("");
      }
    }
  }

  return lines;
}

function upsertNodeSql(input: {
  refKey: string;
  nodeType: string;
  label: string;
  externalSource: string;
  externalId: string;
  properties: Record<string, unknown>;
}): string {
  const nodeId = deterministicNodeId(input.nodeType, input.externalId);
  return `WITH existing AS (
    SELECT id
    FROM rye.nodes
    WHERE external_source = ${sqlText(input.externalSource)}
      AND external_id = ${sqlText(input.externalId)}
      AND archived_at IS NULL
    LIMIT 1
),
updated AS (
    UPDATE rye.nodes
    SET label = ${sqlText(input.label)},
        properties = properties || ${sqlJson(JSON.stringify(input.properties))},
        updated_at = now()
    WHERE id IN (SELECT id FROM existing)
    RETURNING id
),
inserted AS (
    INSERT INTO rye.nodes (id, node_type, label, external_source, external_id, properties)
    SELECT ${sqlText(nodeId)}::uuid,
           ${sqlText(input.nodeType)},
           ${sqlText(input.label)},
           ${sqlText(input.externalSource)},
           ${sqlText(input.externalId)},
           ${sqlJson(JSON.stringify(input.properties))}
    WHERE NOT EXISTS (SELECT 1 FROM existing)
    RETURNING id
),
node_ref AS (
    SELECT id FROM updated
    UNION ALL
    SELECT id FROM inserted
)
INSERT INTO _rye_source_context_ref (key, value)
SELECT ${sqlText(input.refKey)}, id::text FROM node_ref
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;`;
}

function buildEventSql(input: {
  refKey: string;
  eventType: string;
  summary: string;
  properties: Record<string, unknown>;
  participantRefs: string[];
  participantRoles: string[];
  agentId: string;
}): string {
  return `WITH event_ref AS (
    SELECT rye.record_event(
      p_event_type := ${sqlText(input.eventType)},
      p_summary := ${sqlText(input.summary)},
      p_properties := ${sqlJson(JSON.stringify(input.properties))},
      p_participant_ids := ARRAY[${input.participantRefs.map(ctxUuid).join(", ")}],
      p_participant_roles := ARRAY[${input.participantRoles.map(sqlText).join(", ")}],
      p_actor := ${sqlText(`agent:${input.agentId}`)}
    ) AS id
)
INSERT INTO _rye_source_context_ref (key, value)
SELECT ${sqlText(input.refKey)}, id::text FROM event_ref
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;`;
}

function buildConfirmationEventSql(record: ContextConfirmationRecord, eventKey: string): string {
  return `WITH event_ref AS (
    SELECT rye.record_event(
      p_event_type := ${sqlText("source_context_confirmed")},
      p_summary := ${sqlText(`Source context ${record.status}: ${record.subject_id}`)},
      p_properties := ${sqlJson(JSON.stringify(confirmationClaim(record)))},
      p_participant_ids := ARRAY[${nodeUuid(record.subject_id)}],
      p_participant_roles := ARRAY['subject'],
      p_actor := ${sqlText(record.confirmed_by ? `user:${record.confirmed_by}` : "agent:rye_source_context_intake")}
    ) AS id
)
INSERT INTO _rye_source_context_ref (key, value)
SELECT ${sqlText(eventKey)}, id::text FROM event_ref
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;`;
}

function buildNodePropertyMergeSql(record: ContextConfirmationRecord): string {
  const properties = {
    confirmation_status: record.status,
    context_confirmation: confirmationClaim(record),
  };
  return `DO $rye_source_context_node_update$
BEGIN
  PERFORM rye.update_node_properties(
    p_node_id := ${nodeUuid(record.subject_id)},
    p_properties := ${sqlJson(JSON.stringify(properties))},
    p_summary := ${sqlText(`Source context ${record.status}: ${record.subject_id}`)}
  );
END
$rye_source_context_node_update$;`;
}

function buildEdgeSql(sourceId: string, targetId: string, edgeType: string, properties: Record<string, unknown>): string {
  const edgeKey = crypto.createHash("sha1").update(`${edgeType}\u0000${sourceId}\u0000${targetId}`).digest("hex");
  const edgeProperties = {
    ...properties,
    source_context_edge_key: edgeKey,
  };
  return `INSERT INTO rye.edges (edge_type, source_id, target_id, properties)
SELECT ${sqlText(edgeType)}, ${nodeUuid(sourceId)}, ${nodeUuid(targetId)}, ${sqlJson(JSON.stringify(edgeProperties))}
WHERE NOT EXISTS (
  SELECT 1
  FROM rye.edges
  WHERE edge_type = ${sqlText(edgeType)}
    AND source_id = ${nodeUuid(sourceId)}
    AND target_id = ${nodeUuid(targetId)}
    AND archived_at IS NULL
);`;
}

function buildAssertionSql(
  subjectId: string,
  assertionType: string,
  assertionKey: string,
  claim: Record<string, unknown>,
  eventRefKey: string,
  confidence?: number,
): string {
  return `DO $rye_source_context_assertion$
DECLARE
  v_subject_id uuid := ${nodeUuid(subjectId)};
  v_event_id uuid := ${ctxUuid(eventRefKey)};
  v_existing_id uuid;
  v_existing_claim jsonb;
  v_claim jsonb := ${sqlJson(JSON.stringify(claim))};
BEGIN
  SELECT id, claim
  INTO v_existing_id, v_existing_claim
  FROM rye.assertions
  WHERE subject_node_id = v_subject_id
    AND assertion_type = ${sqlText(assertionType)}
    AND assertion_key = ${sqlText(assertionKey)}
    AND superseded_at IS NULL
  LIMIT 1;

  IF v_existing_id IS NULL THEN
    INSERT INTO rye.assertions (
      assertion_type,
      assertion_key,
      subject_node_id,
      claim,
      source_event_id,
      confidence
    ) VALUES (
      ${sqlText(assertionType)},
      ${sqlText(assertionKey)},
      v_subject_id,
      v_claim,
      v_event_id,
      ${confidence == null ? "NULL" : String(confidence)}
    );
  ELSIF v_existing_claim IS DISTINCT FROM v_claim THEN
    PERFORM rye.supersede_assertion(
      p_old_assertion_id := v_existing_id,
      p_new_assertion_type := ${sqlText(assertionType)},
      p_new_subject_node_id := v_subject_id,
      p_new_subject_edge_id := NULL,
      p_new_claim := v_claim,
      p_new_assertion_key := ${sqlText(assertionKey)},
      p_new_source_event_id := v_event_id,
      p_new_confidence := ${confidence == null ? "NULL" : String(confidence)}
    );
  END IF;
END
$rye_source_context_assertion$;`;
}

function buildArtifactSql(record: SourceItemRecord): string {
  const content = {
    source_context_id: record.id,
    item_type: record.item_type,
    external_url: record.external_url,
    source_value: record.source_value,
    visibility: record.visibility,
    persistence_reason: record.persistence_reason,
    metadata: record.metadata ?? {},
    content: record.content ?? null,
  };
  const location = {
    source_context_id: record.id,
    source_account_id: record.source_account_id,
    source_container_id: record.source_container_id,
    external_url: record.external_url,
  };
  const hash = record.content_hash ?? `sha256:${crypto.createHash("sha256").update(JSON.stringify(content)).digest("hex")}`;
  return `DO $rye_source_context_artifact$
BEGIN
  PERFORM rye.record_artifact(
    p_artifact_type := 'source_item_content',
    p_content := ${sqlJson(JSON.stringify(content))},
    p_source_event_id := ${ctxUuid(`event:${record.kind}:${record.id}`)},
    p_source_node_id := ${nodeUuid(record.id)},
    p_related_node_ids := ARRAY[${nodeUuid(record.id)}],
    p_location := ${sqlJson(JSON.stringify(location))},
    p_content_hash := ${sqlText(hash)}
  );
END
$rye_source_context_artifact$;`;
}

function deterministicNodeId(nodeType: string, externalId: string): string {
  const keyType = nodeType === "review_context" ? "review_context" : nodeType;
  return uuidFromKey(`node:${keyType}:${externalId}`);
}

function uuidFromKey(key: string): string {
  const bytes = crypto.createHash("sha1").update(key).digest("hex").slice(0, 32).split("");
  bytes[12] = "5";
  bytes[16] = ((Number.parseInt(bytes[16], 16) & 0x3) | 0x8).toString(16);
  const hex = bytes.join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function nodeUuid(id: string): string {
  return `COALESCE(
    (SELECT value::uuid FROM _rye_source_context_ref WHERE key = ${sqlText(`node:${id}`)}),
    (
      SELECT n.id
      FROM rye.nodes n
      WHERE n.archived_at IS NULL
        AND (
          (n.external_source = ${sqlText(externalSource)} AND n.external_id = ${sqlText(id)})
          OR (n.external_source = ${sqlText(contextProfileExternalSource)} AND n.external_id = ${sqlText(id)})
        )
      ORDER BY CASE WHEN n.external_source = ${sqlText(externalSource)} THEN 0 ELSE 1 END
      LIMIT 1
    )
  )`;
}

function ctxUuid(key: string): string {
  return `(SELECT value::uuid FROM _rye_source_context_ref WHERE key = ${sqlText(key)})`;
}

function nodeTypeFor(record: Exclude<SourceContextRecord, ContextConfirmationRecord>): string {
  switch (record.kind) {
    case "context_profile":
      return "review_context";
    case "source_account":
      return "source_account";
    case "source_container":
      return "source_container";
    case "source_item":
      return "source_item";
  }
}

function externalSourceFor(record: Exclude<SourceContextRecord, ContextConfirmationRecord>): string {
  return record.kind === "context_profile" ? contextProfileExternalSource : externalSource;
}

function labelFor(record: Exclude<SourceContextRecord, ContextConfirmationRecord>): string {
  if (record.kind === "source_item") {
    return record.label ?? record.id;
  }
  return record.label;
}

function propertiesFor(record: Exclude<SourceContextRecord, ContextConfirmationRecord>): Record<string, unknown> {
  const base = {
    source_context_record_kind: record.kind,
    source_context_id: record.id,
    contract: "rye_source_context_intake.v1",
    metadata: record.metadata ?? {},
    evidence: record.evidence ?? [],
  };

  if (record.kind === "source_account") {
    return {
      ...base,
      provider: record.provider,
      confirmation_status: record.confirmation_status ?? "needs_confirmation",
      context_confirmation: {
        status: record.confirmation_status ?? "needs_confirmation",
        evidence: record.evidence ?? [],
      },
    };
  }

  if (record.kind === "source_container") {
    return {
      ...base,
      source_account_id: record.source_account_id,
      container_type: record.container_type,
      confirmation_status: record.confirmation_status ?? "needs_confirmation",
      holding_context_id: record.holding_context_id,
      allowed_context_ids: record.allowed_context_ids ?? [],
      default_context_ids: record.default_context_ids ?? [],
      never_infer: record.never_infer ?? [],
      context_confirmation: {
        status: record.confirmation_status ?? "needs_confirmation",
        evidence: record.evidence ?? [],
      },
    };
  }

  if (record.kind === "source_item") {
    return {
      ...base,
      source_account_id: record.source_account_id,
      source_container_id: record.source_container_id,
      item_type: record.item_type,
      occurred_at: record.occurred_at,
      external_url: record.external_url,
      source_value: record.source_value,
      visibility: record.visibility,
      persistence_reason: record.persistence_reason,
      content_hash: record.content_hash,
      classification: record.classification,
    };
  }

  return {
    ...base,
    context_id: record.id,
    purpose: record.purpose,
    relevance_rules: record.relevance_rules ?? [],
    edge_policies: record.edge_policies ?? [],
    task_policy: record.task_policy,
  };
}

function confirmationClaim(record: ContextConfirmationRecord): Record<string, unknown> {
  return {
    subject_id: record.subject_id,
    status: record.status,
    confirmed_by: record.confirmed_by,
    confirmed_at: record.confirmed_at,
    purpose: record.purpose,
    allowed_context_ids: record.allowed_context_ids ?? [],
    default_context_ids: record.default_context_ids ?? [],
    never_infer: record.never_infer ?? [],
    notes: record.notes,
    evidence: record.evidence ?? [],
    metadata: record.metadata ?? {},
    contract: "rye_source_context_intake.v1",
  };
}

function summarize(records: SourceContextRecord[]): Summary {
  return {
    records: records.length,
    source_accounts: records.filter((record) => record.kind === "source_account").length,
    source_containers: records.filter((record) => record.kind === "source_container").length,
    source_items: records.filter((record) => record.kind === "source_item").length,
    context_profiles: records.filter((record) => record.kind === "context_profile").length,
    context_confirmations: records.filter((record) => record.kind === "context_confirmation").length,
  };
}

function requiredString(record: Record<string, unknown>, field: string, lineNumber: number): string {
  const value = record[field];
  if (typeof value !== "string" || value.trim() === "") {
    throw invalid(lineNumber, `Missing required string field: ${field}`);
  }
  return value;
}

function optionalString(record: Record<string, unknown>, field: string, lineNumber: number): string | undefined {
  const value = record[field];
  if (value == null) {
    return undefined;
  }
  if (typeof value !== "string") {
    throw invalid(lineNumber, `Expected ${field} to be a string.`);
  }
  return value;
}

function optionalTimestamp(record: Record<string, unknown>, field: string, lineNumber: number): string | undefined {
  const value = optionalString(record, field, lineNumber);
  if (!value) {
    return undefined;
  }
  if (Number.isNaN(Date.parse(value))) {
    throw invalid(lineNumber, `Expected ${field} to be an ISO-compatible timestamp.`);
  }
  return value;
}

function optionalUrl(record: Record<string, unknown>, field: string, lineNumber: number): string | undefined {
  const value = optionalString(record, field, lineNumber);
  if (!value) {
    return undefined;
  }
  try {
    const parsed = new URL(value);
    if (parsed.protocol === "http:" || parsed.protocol === "https:") {
      return value;
    }
  } catch {
    // Fall through to a contract validation error.
  }
  throw invalid(lineNumber, `Expected ${field} to be an http(s) URL.`);
}

function requiredStatus(record: Record<string, unknown>, field: string, lineNumber: number): ConfirmationStatus {
  const value = requiredString(record, field, lineNumber);
  if (!isStatus(value)) {
    throw invalid(lineNumber, `Invalid ${field}: ${value}`);
  }
  return value;
}

function optionalStatus(record: Record<string, unknown>, field: string, lineNumber: number): ConfirmationStatus | undefined {
  const value = optionalString(record, field, lineNumber);
  if (!value) {
    return undefined;
  }
  if (!isStatus(value)) {
    throw invalid(lineNumber, `Invalid ${field}: ${value}`);
  }
  return value;
}

function optionalStringArray(record: Record<string, unknown>, field: string, lineNumber: number): string[] | undefined {
  const value = record[field];
  if (value == null) {
    return undefined;
  }
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw invalid(lineNumber, `Expected ${field} to be an array of strings.`);
  }
  return value;
}

function optionalObject(record: Record<string, unknown>, field: string, lineNumber: number): Record<string, unknown> | undefined {
  const value = record[field];
  if (value == null) {
    return undefined;
  }
  if (!isObject(value)) {
    throw invalid(lineNumber, `Expected ${field} to be an object.`);
  }
  return value;
}

function optionalClassification(record: Record<string, unknown>, lineNumber: number): SourceItemRecord["classification"] | undefined {
  const value = record.classification;
  if (value == null) {
    return undefined;
  }
  if (!isObject(value)) {
    throw invalid(lineNumber, "Expected classification to be an object.");
  }
  const contextIds = optionalStringArray(value, "context_ids", lineNumber);
  const confidence = value.confidence;
  if (confidence != null && (typeof confidence !== "number" || confidence < 0 || confidence > 1)) {
    throw invalid(lineNumber, "Expected classification.confidence to be between 0 and 1.");
  }
  return {
    context_ids: contextIds,
    confidence: confidence as number | undefined,
    rationale: optionalString(value, "rationale", lineNumber),
    evidence: optionalStringArray(value, "evidence", lineNumber),
  };
}

function isStatus(value: string): value is ConfirmationStatus {
  return value === "needs_confirmation" || value === "confirmed" || value === "rejected";
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function invalid(lineNumber: number, message: string): CliError {
  return new CliError(
    "invalid_source_context_record",
    `Invalid source context record at line ${lineNumber}.`,
    message,
    [
      "Check skills/rye-source-context-intake/references/source-context-contract.md.",
      "Run with --validate-only before committing.",
    ],
  );
}
