import fs from "node:fs/promises";
import path from "node:path";

import { CliError } from "./cli.mts";
import type { MapRecordSpec, MappingMetadata, TransformFunction } from "./contracts.mts";

type ConversionKind = "integer" | "number" | "boolean" | "date" | "timestamp" | "json" | "string";

interface FieldRule {
  column?: string;
  literal?: unknown;
  trim?: boolean;
  lowercase?: boolean;
  uppercase?: boolean;
  null_if?: unknown[];
  required?: boolean;
  convert?: ConversionKind;
  map?: Record<string, unknown>;
  join?: {
    columns: string[];
    separator?: string;
    skip_nulls?: boolean;
  };
}

interface FilterRule {
  column: string;
  equals?: unknown;
  not_equals?: unknown;
  in?: unknown[];
  exists?: boolean;
  matches?: string;
}

interface DeclarativeMapConfig {
  name?: string;
  destination_table: string;
  operation?: "insert" | "upsert" | "update";
  filter?: FilterRule | FilterRule[];
  record: Record<string, FieldRule>;
}

export async function loadMappingConfig(
  configPath: string,
): Promise<{ metadata: MappingMetadata; transform: TransformFunction }> {
  const resolvedPath = path.resolve(configPath);
  let parsed: unknown;

  try {
    parsed = JSON.parse(await fs.readFile(resolvedPath, "utf8"));
  } catch (error) {
    const message = error instanceof Error ? error.message : "Invalid JSON";
    throw new CliError(
      "invalid_mapping_config",
      `Failed to load mapping config ${resolvedPath}.`,
      message,
      [`Validate the JSON syntax.`, `Check that the file is readable.`],
    );
  }

  const config = validateConfig(parsed, resolvedPath);
  return {
    metadata: { name: config.name ?? path.basename(resolvedPath, path.extname(resolvedPath)) },
    transform: async (input) => {
      if (!matchesFilters(input, config.filter)) {
        return null;
      }

      const record: Record<string, unknown> = {};
      for (const [targetField, rule] of Object.entries(config.record)) {
        record[targetField] = resolveFieldValue(input, targetField, rule);
      }

      const output: MapRecordSpec = {
        destination_table: config.destination_table,
        operation: config.operation ?? "upsert",
        record,
      };

      return output;
    },
  };
}

function validateConfig(parsed: unknown, source: string): DeclarativeMapConfig {
  if (!isObject(parsed)) {
    throw invalidConfig(source, "Expected a JSON object at the top level.");
  }
  if (typeof parsed.destination_table !== "string" || parsed.destination_table.trim() === "") {
    throw invalidConfig(source, "destination_table must be a non-empty string.");
  }
  if (!isObject(parsed.record) || Object.keys(parsed.record).length === 0) {
    throw invalidConfig(source, "record must be a non-empty object.");
  }
  return parsed as DeclarativeMapConfig;
}

function resolveFieldValue(
  input: Parameters<TransformFunction>[0],
  targetField: string,
  rule: FieldRule,
): unknown {
  let value: unknown;

  if (rule.literal !== undefined) {
    value = rule.literal;
  } else if (rule.join) {
    value = joinColumns(input, rule.join.columns, rule.join.separator ?? " ", rule.join.skip_nulls ?? true);
  } else if (rule.column) {
    value = getSourceValue(input, rule.column);
  } else {
    throw new CliError(
      "invalid_mapping_rule",
      `Field "${targetField}" has no source.`,
      `Provide column, literal, or join in the mapping config.`,
      [`Update the mapping config for ${targetField}.`],
    );
  }

  value = applyConversions(value, rule);

  if (rule.required && (value === null || value === undefined || value === "")) {
    throw new CliError(
      "required_mapping_value_missing",
      `Field "${targetField}" resolved to an empty value.`,
      `The mapping config marked this field as required.`,
      [`Fix the source data or remove required: true for ${targetField}.`],
    );
  }

  return value;
}

function applyConversions(value: unknown, rule: FieldRule): unknown {
  let current = value;

  if (rule.trim && typeof current === "string") {
    current = current.trim();
  }

  if (Array.isArray(rule.null_if) && rule.null_if.some((candidate) => candidate === current)) {
    current = null;
  }

  if (rule.map && current !== null && current !== undefined) {
    const mapped = rule.map[String(current)];
    if (mapped !== undefined) {
      current = mapped;
    }
  }

  if (rule.lowercase && typeof current === "string") {
    current = current.toLowerCase();
  }

  if (rule.uppercase && typeof current === "string") {
    current = current.toUpperCase();
  }

  if (rule.convert) {
    current = convertValue(current, rule.convert);
  }

  return current;
}

function convertValue(value: unknown, kind: ConversionKind): unknown {
  if (value === null || value === undefined || value === "") {
    return value;
  }

  switch (kind) {
    case "string":
      return String(value);
    case "integer": {
      const parsed = Number.parseInt(String(value), 10);
      if (Number.isNaN(parsed)) {
        throw new CliError("invalid_integer_conversion", `Could not parse integer from "${value}".`);
      }
      return parsed;
    }
    case "number": {
      const parsed = Number.parseFloat(String(value));
      if (Number.isNaN(parsed)) {
        throw new CliError("invalid_number_conversion", `Could not parse number from "${value}".`);
      }
      return parsed;
    }
    case "boolean": {
      const normalized = String(value).trim().toLowerCase();
      if (["true", "t", "yes", "y", "1"].includes(normalized)) {
        return true;
      }
      if (["false", "f", "no", "n", "0"].includes(normalized)) {
        return false;
      }
      throw new CliError("invalid_boolean_conversion", `Could not parse boolean from "${value}".`);
    }
    case "date":
    case "timestamp": {
      const parsed = new Date(String(value));
      if (Number.isNaN(parsed.getTime())) {
        throw new CliError(`invalid_${kind}_conversion`, `Could not parse ${kind} from "${value}".`);
      }
      return parsed.toISOString();
    }
    case "json": {
      if (typeof value !== "string") {
        return value;
      }
      try {
        return JSON.parse(value);
      } catch (error) {
        const message = error instanceof Error ? error.message : "Invalid JSON";
        throw new CliError("invalid_json_conversion", `Could not parse JSON from "${value}".`, message);
      }
    }
    default:
      return value;
  }
}

function matchesFilters(input: Parameters<TransformFunction>[0], filter: DeclarativeMapConfig["filter"]): boolean {
  if (!filter) {
    return true;
  }

  const filters = Array.isArray(filter) ? filter : [filter];
  return filters.every((rule) => matchesFilter(input, rule));
}

function matchesFilter(input: Parameters<TransformFunction>[0], rule: FilterRule): boolean {
  const value = getSourceValue(input, rule.column);

  if (rule.exists !== undefined) {
    const exists = value !== null && value !== undefined && value !== "";
    if (exists !== rule.exists) {
      return false;
    }
  }

  if (rule.equals !== undefined && value !== rule.equals) {
    return false;
  }

  if (rule.not_equals !== undefined && value === rule.not_equals) {
    return false;
  }

  if (Array.isArray(rule.in) && !rule.in.includes(value)) {
    return false;
  }

  if (rule.matches !== undefined) {
    const regex = new RegExp(rule.matches);
    if (!regex.test(String(value ?? ""))) {
      return false;
    }
  }

  return true;
}

function joinColumns(
  input: Parameters<TransformFunction>[0],
  columns: string[],
  separator: string,
  skipNulls: boolean,
): string {
  const values = columns
    .map((column) => getSourceValue(input, column))
    .filter((value) => (skipNulls ? value !== null && value !== undefined && value !== "" : true))
    .map((value) => String(value ?? ""));
  return values.join(separator);
}

function getSourceValue(input: Parameters<TransformFunction>[0], column: string): unknown {
  if (input.kind === "source_row") {
    return input.row[column];
  }
  return input.record[column];
}

function invalidConfig(source: string, detail: string): CliError {
  return new CliError(
    "invalid_mapping_config",
    `Mapping config ${source} is not valid.`,
    detail,
    [`Add destination_table and a non-empty record object.`, `See references/cli-contract.md for examples.`],
  );
}

function isObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}
