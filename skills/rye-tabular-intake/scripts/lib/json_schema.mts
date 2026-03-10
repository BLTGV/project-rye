import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

export interface JsonSchema {
  $schema?: string;
  type?: string | string[];
  const?: unknown;
  enum?: unknown[];
  anyOf?: JsonSchema[];
  required?: string[];
  properties?: Record<string, JsonSchema>;
  additionalProperties?: boolean | JsonSchema;
  items?: JsonSchema;
  minimum?: number;
  minItems?: number;
}

const schemaCache = new Map<string, JsonSchema>();
const schemaRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "assets", "schemas");

export async function validateSchemaFile(schemaFile: string, value: unknown): Promise<string[]> {
  const schema = await loadSchema(schemaFile);
  return validateSchema(schema, value, "$");
}

async function loadSchema(schemaFile: string): Promise<JsonSchema> {
  const cached = schemaCache.get(schemaFile);
  if (cached) {
    return cached;
  }

  const text = await fs.readFile(path.join(schemaRoot, schemaFile), "utf8");
  const schema = JSON.parse(text) as JsonSchema;
  schemaCache.set(schemaFile, schema);
  return schema;
}

function validateSchema(schema: JsonSchema, value: unknown, location: string): string[] {
  const errors: string[] = [];

  if (schema.anyOf) {
    const branchErrors = schema.anyOf.map((candidate) => validateSchema(candidate, value, location));
    if (!branchErrors.some((candidateErrors) => candidateErrors.length === 0)) {
      errors.push(`${location} did not match any allowed schema branch`);
      return errors;
    }
  }

  if (schema.const !== undefined && !isDeepEqual(value, schema.const)) {
    errors.push(`${location} must equal ${JSON.stringify(schema.const)}`);
    return errors;
  }

  if (schema.enum && !schema.enum.some((candidate) => isDeepEqual(value, candidate))) {
    errors.push(`${location} must be one of ${schema.enum.map((candidate) => JSON.stringify(candidate)).join(", ")}`);
    return errors;
  }

  if (schema.type) {
    const allowedTypes = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!allowedTypes.some((candidate) => matchesType(candidate, value))) {
      errors.push(`${location} must be ${allowedTypes.join(" or ")}`);
      return errors;
    }
  }

  if (schema.type === "object" && isPlainObject(value)) {
    const required = schema.required ?? [];
    for (const key of required) {
      if (!(key in value)) {
        errors.push(`${location}.${key} is required`);
      }
    }

    const properties = schema.properties ?? {};
    for (const [key, childSchema] of Object.entries(properties)) {
      if (key in value) {
        errors.push(...validateSchema(childSchema, value[key], `${location}.${key}`));
      }
    }

    const additionalProperties = schema.additionalProperties;
    if (additionalProperties === false) {
      for (const key of Object.keys(value)) {
        if (!(key in properties)) {
          errors.push(`${location}.${key} is not allowed`);
        }
      }
    } else if (isSchema(additionalProperties)) {
      for (const [key, childValue] of Object.entries(value)) {
        if (!(key in properties)) {
          errors.push(...validateSchema(additionalProperties, childValue, `${location}.${key}`));
        }
      }
    }
  }

  if (schema.type === "array" && Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      errors.push(`${location} must contain at least ${schema.minItems} item(s)`);
    }
    if (schema.items) {
      value.forEach((item, index) => {
        errors.push(...validateSchema(schema.items as JsonSchema, item, `${location}[${index}]`));
      });
    }
  }

  if (schema.type === "integer" && typeof value === "number" && schema.minimum !== undefined && value < schema.minimum) {
    errors.push(`${location} must be >= ${schema.minimum}`);
  }

  if (schema.type === "number" && typeof value === "number" && schema.minimum !== undefined && value < schema.minimum) {
    errors.push(`${location} must be >= ${schema.minimum}`);
  }

  return errors;
}

function matchesType(type: string, value: unknown): boolean {
  switch (type) {
    case "object":
      return isPlainObject(value);
    case "array":
      return Array.isArray(value);
    case "string":
      return typeof value === "string";
    case "integer":
      return typeof value === "number" && Number.isInteger(value);
    case "number":
      return typeof value === "number" && Number.isFinite(value);
    case "boolean":
      return typeof value === "boolean";
    case "null":
      return value === null;
    default:
      return false;
  }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function isSchema(value: unknown): value is JsonSchema {
  return isPlainObject(value);
}

function isDeepEqual(left: unknown, right: unknown): boolean {
  if (left === right) {
    return true;
  }

  if (Array.isArray(left) && Array.isArray(right)) {
    return left.length === right.length && left.every((value, index) => isDeepEqual(value, right[index]));
  }

  if (isPlainObject(left) && isPlainObject(right)) {
    const leftKeys = Object.keys(left);
    const rightKeys = Object.keys(right);
    return (
      leftKeys.length === rightKeys.length &&
      leftKeys.every((key) => key in right && isDeepEqual(left[key], right[key]))
    );
  }

  return false;
}
