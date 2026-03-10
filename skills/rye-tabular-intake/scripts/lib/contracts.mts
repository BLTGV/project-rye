export type TabularFormat = "csv" | "xlsx";

export interface SourceDescriptor {
  path: string;
  format: TabularFormat;
  table_name: string;
  sheet_name: string | null;
  header_row: number;
  row_number: number;
  record_number: number;
}

export interface SourceRow {
  kind: "source_row";
  source: SourceDescriptor;
  lineage: string[];
  row: Record<string, string | null>;
  raw: Array<string | null>;
}

export interface MappedRecord {
  kind: "mapped_record";
  mapping: string;
  destination_table: string;
  operation: "insert" | "upsert" | "update";
  source: SourceDescriptor;
  lineage: string[];
  record: Record<string, unknown>;
  meta: Record<string, unknown>;
  issues: string[];
}

export interface RyeStageRecord {
  kind: "rye_stage_record";
  node_type: string;
  label: string;
  source: SourceDescriptor;
  lineage: string[];
  properties: Record<string, unknown>;
}

export type PipelineRecord = SourceRow | MappedRecord | RyeStageRecord;

export interface MapRecordSpec {
  destination_table: string;
  operation?: "insert" | "upsert" | "update";
  record: Record<string, unknown>;
  meta?: Record<string, unknown>;
  issues?: string[];
}

export interface MappingMetadata {
  name?: string;
}

export type TransformResult = MapRecordSpec | MapRecordSpec[] | null;
export type TransformFunction = (input: SourceRow | MappedRecord) => TransformResult | Promise<TransformResult>;

export function isObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

export function isSourceRow(value: unknown): value is SourceRow {
  return isObject(value) && value.kind === "source_row" && isObject(value.source) && isObject(value.row);
}

export function isMappedRecord(value: unknown): value is MappedRecord {
  return (
    isObject(value) &&
    value.kind === "mapped_record" &&
    typeof value.mapping === "string" &&
    typeof value.destination_table === "string" &&
    isObject(value.source) &&
    isObject(value.record)
  );
}

export function isPipelineRecord(value: unknown): value is PipelineRecord {
  return isSourceRow(value) || isMappedRecord(value) || isRyeStageRecord(value);
}

export function isRyeStageRecord(value: unknown): value is RyeStageRecord {
  return (
    isObject(value) &&
    value.kind === "rye_stage_record" &&
    typeof value.node_type === "string" &&
    typeof value.label === "string" &&
    isObject(value.source) &&
    isObject(value.properties)
  );
}

export function appendLineage(existing: unknown, step: string): string[] {
  const lineage = Array.isArray(existing) ? existing.filter((item): item is string => typeof item === "string") : [];
  return [...lineage, step];
}

export function sourceFromRecord(record: SourceRow | MappedRecord | RyeStageRecord): SourceDescriptor {
  return record.source;
}

export function slugify(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "") || "record";
}
