import {
  isMappedRecord,
  isRyeStageRecord,
  isSourceRow,
  type MappedRecord,
  type PipelineRecord,
  type SourceDescriptor,
  type SourceRow,
} from "./contracts.mts";

export const RYE_TABULAR_INTAKE = {
  runExternalSource: "rye.tabular_intake.run",
  rowExternalSource: "rye.tabular_intake.row",
  defaultRunNodeType: "rye_tabular_intake_run",
  defaultRowNodeType: "rye_tabular_intake_row",
  defaultStageNodeType: "rye_tabular_intake_stage_row",
  runStartedEventType: "rye_tabular_intake_run_started",
  runCompletedEventType: "rye_tabular_intake_run_completed",
  sourceRowEventType: "rye_tabular_intake_row_extracted",
  mappedRecordEventType: "rye_tabular_intake_row_mapped",
  stageRecordEventType: "rye_tabular_intake_row_staged",
  sourceRowAssertionType: "rye_tabular_intake_source_row",
  mappedRecordAssertionType: "rye_tabular_intake_mapped_record",
  stageRecordAssertionType: "rye_tabular_intake_stage_record",
  sourceFileArtifactType: "rye_tabular_intake_source_file",
  defaultAgentId: "rye_tabular_intake",
} as const;

export function buildRunNodeProperties(input: {
  runId: string;
  scenario?: string;
  inputPath: string;
  completedAt?: string | null;
  summary?: Record<string, number>;
  inputKinds?: string[];
  mappings?: string[];
  stageStatuses?: string[];
  sourceFiles?: Array<{
    path: string;
    format: string;
    table_name: string;
    sheet_name: string | null;
    content_sha1: string;
  }>;
  runFingerprintSha1?: string;
}): Record<string, unknown> {
  return {
    schema_type: "rye.tabular_intake.run_node.v1",
    schema_version: 1,
    run_id: input.runId,
    scenario: input.scenario ?? null,
    input_path: input.inputPath,
    completed_at: input.completedAt ?? null,
    input_kinds: input.inputKinds ?? [],
    mappings: input.mappings ?? [],
    stage_statuses: input.stageStatuses ?? [],
    source_files: input.sourceFiles ?? [],
    run_fingerprint_sha1: input.runFingerprintSha1 ?? null,
    ...(input.summary ? { summary: input.summary } : {}),
  };
}

export function buildRowNodeProperties(input: {
  record: PipelineRecord;
  runId: string;
  scenario?: string;
}): Record<string, unknown> {
  return {
    schema_type: "rye.tabular_intake.row_node.v1",
    schema_version: 1,
    source: input.record.source,
    scenario: input.scenario ?? null,
    latest_run_id: input.runId,
    latest_event_type: eventTypeForRecord(input.record),
    latest_ingest_status: statusForRecord(input.record),
    latest_lineage: "lineage" in input.record ? input.record.lineage : [],
    latest_mapping: isMappedRecord(input.record) ? input.record.mapping : null,
    latest_destination_table: isMappedRecord(input.record) ? input.record.destination_table : null,
  };
}

export function buildRunEventProperties(input: {
  runId: string;
  scenario?: string;
  phase: "started" | "completed";
  inputPath?: string;
  inputRecords?: number;
  summary?: Record<string, number>;
  inputKinds?: string[];
  mappings?: string[];
  stageStatuses?: string[];
  sourceFiles?: Array<{
    path: string;
    format: string;
    table_name: string;
    sheet_name: string | null;
    content_sha1: string;
  }>;
  runFingerprintSha1?: string;
}): Record<string, unknown> {
  return {
    schema_type: "rye.tabular_intake.run_event_properties.v1",
    schema_version: 1,
    run_id: input.runId,
    scenario: input.scenario ?? null,
    event_phase: input.phase,
    input_path: input.inputPath ?? null,
    input_records: input.inputRecords ?? null,
    source_rows: input.summary?.source_rows ?? null,
    mapped_records: input.summary?.mapped_records ?? null,
    stage_records: input.summary?.stage_records ?? null,
    input_kinds: input.inputKinds ?? [],
    mappings: input.mappings ?? [],
    stage_statuses: input.stageStatuses ?? [],
    source_files: input.sourceFiles ?? [],
    run_fingerprint_sha1: input.runFingerprintSha1 ?? null,
  };
}

export function buildRowEventProperties(input: {
  runId: string;
  scenario?: string;
  record: PipelineRecord;
}): Record<string, unknown> {
  return {
    schema_type: "rye.tabular_intake.row_event_properties.v1",
    schema_version: 1,
    run_id: input.runId,
    scenario: input.scenario ?? null,
    input_kind: input.record.kind,
    source: input.record.source,
    stage_status: statusForRecord(input.record),
    lineage: "lineage" in input.record ? input.record.lineage : [],
    mapping: isMappedRecord(input.record) ? input.record.mapping : null,
    destination_table: isMappedRecord(input.record) ? input.record.destination_table : null,
  };
}

export function buildClaim(input: {
  runId: string;
  scenario?: string;
  record: PipelineRecord;
  payloadHash: string;
}): Record<string, unknown> {
  if (isSourceRow(input.record)) {
    return {
      schema_type: "rye.tabular_intake.source_row_claim.v1",
      schema_version: 1,
      kind: input.record.kind,
      source: input.record.source,
      lineage: input.record.lineage,
      row: input.record.row,
      raw: input.record.raw,
      run_id: input.runId,
      scenario: input.scenario ?? null,
      payload_hash: input.payloadHash,
      recorded_via: "tabular_commit_rye.mts",
    };
  }

  if (isMappedRecord(input.record)) {
    return {
      schema_type: "rye.tabular_intake.mapped_record_claim.v1",
      schema_version: 1,
      kind: input.record.kind,
      mapping: input.record.mapping,
      destination_table: input.record.destination_table,
      operation: input.record.operation,
      source: input.record.source,
      lineage: input.record.lineage,
      record: input.record.record,
      meta: input.record.meta,
      issues: input.record.issues,
      run_id: input.runId,
      scenario: input.scenario ?? null,
      payload_hash: input.payloadHash,
      recorded_via: "tabular_commit_rye.mts",
    };
  }

  return {
    schema_type: "rye.tabular_intake.stage_record_claim.v1",
    schema_version: 1,
    kind: input.record.kind,
    node_type: input.record.node_type,
    label: input.record.label,
    source: input.record.source,
    lineage: input.record.lineage,
    properties: input.record.properties,
    run_id: input.runId,
    scenario: input.scenario ?? null,
    payload_hash: input.payloadHash,
    recorded_via: "tabular_commit_rye.mts",
  };
}

export function buildStageProperties(input: {
  record: SourceRow | MappedRecord;
  status: string;
}): Record<string, unknown> {
  const base: Record<string, unknown> = {
    schema_type: "rye.tabular_intake.stage_properties.v1",
    schema_version: 1,
    ingest_status: input.status,
    source_format: input.record.source.format,
    source_path: input.record.source.path,
    source_table: input.record.source.table_name,
    source_sheet: input.record.source.sheet_name,
    source_row_number: input.record.source.row_number,
  };

  if (input.record.kind === "source_row") {
    base.raw_fields = input.record.row;
    return base;
  }

  base.destination_table = input.record.destination_table;
  base.mapping = input.record.mapping;
  base.mapped_record = input.record.record;
  if (input.record.issues.length > 0) {
    base.mapping_issues = input.record.issues;
  }
  return base;
}

export function buildSourceFileArtifactContent(input: {
  descriptor: SourceDescriptor;
  scenario?: string;
  contentSha1?: string | null;
}): Record<string, unknown> {
  return {
    schema_type: "rye.tabular_intake.source_file_artifact.v1",
    schema_version: 1,
    path: input.descriptor.path,
    format: input.descriptor.format,
    table_name: input.descriptor.table_name,
    sheet_name: input.descriptor.sheet_name,
    scenario: input.scenario ?? null,
    content_sha1: input.contentSha1 ?? null,
  };
}

export function buildSourceFileArtifactLocation(descriptor: SourceDescriptor): Record<string, unknown> {
  return {
    schema_type: "rye.tabular_intake.source_file_location.v1",
    schema_version: 1,
    path: descriptor.path,
  };
}

export function eventTypeForRecord(record: PipelineRecord): string {
  if (isSourceRow(record)) {
    return RYE_TABULAR_INTAKE.sourceRowEventType;
  }
  if (isMappedRecord(record)) {
    return RYE_TABULAR_INTAKE.mappedRecordEventType;
  }
  return RYE_TABULAR_INTAKE.stageRecordEventType;
}

export function assertionTypeForRecord(record: PipelineRecord): string {
  if (isSourceRow(record)) {
    return RYE_TABULAR_INTAKE.sourceRowAssertionType;
  }
  if (isMappedRecord(record)) {
    return RYE_TABULAR_INTAKE.mappedRecordAssertionType;
  }
  return RYE_TABULAR_INTAKE.stageRecordAssertionType;
}

export function statusForRecord(record: PipelineRecord): string {
  if (isSourceRow(record)) {
    return "extracted";
  }
  if (isMappedRecord(record)) {
    return "mapped";
  }
  return typeof record.properties.ingest_status === "string" ? record.properties.ingest_status : "staged";
}

export function summaryForRecord(record: PipelineRecord): string {
  if (isSourceRow(record)) {
    return `Extracted ${record.source.table_name} row ${record.source.row_number}`;
  }
  if (isMappedRecord(record)) {
    return `Mapped ${record.source.table_name} row ${record.source.row_number} to ${record.destination_table}`;
  }
  return `Staged ${record.source.table_name} row ${record.source.row_number}`;
}

export function schemaFileForClaim(record: PipelineRecord): string {
  if (isSourceRow(record)) {
    return "rye_source_row_claim.schema.json";
  }
  if (isMappedRecord(record)) {
    return "rye_mapped_record_claim.schema.json";
  }
  return "rye_stage_record_claim.schema.json";
}

export function uniqueSorted(values: Iterable<string>): string[] {
  return Array.from(new Set(values)).sort();
}
