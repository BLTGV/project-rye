#!/usr/bin/env bash
set -euo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node unavailable; governed process contract test not run"
  exit 0
fi

node <<'NODE'
const fs = require("node:fs");

function load(path) {
  return JSON.parse(fs.readFileSync(path, "utf8"));
}

function matchesType(type, value) {
  if (type === "object") return value !== null && typeof value === "object" && !Array.isArray(value);
  if (type === "array") return Array.isArray(value);
  if (type === "string") return typeof value === "string";
  if (type === "integer") return Number.isInteger(value);
  if (type === "number") return typeof value === "number" && Number.isFinite(value);
  if (type === "boolean") return typeof value === "boolean";
  if (type === "null") return value === null;
  return false;
}

function validate(schema, value, path = "$") {
  const errors = [];
  if (schema.const !== undefined && JSON.stringify(value) !== JSON.stringify(schema.const)) {
    return [`${path} must equal ${JSON.stringify(schema.const)}`];
  }
  if (schema.enum && !schema.enum.some((entry) => JSON.stringify(entry) === JSON.stringify(value))) {
    return [`${path} must be one of ${schema.enum.join(", ")}`];
  }
  if (schema.type) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!types.some((type) => matchesType(type, value))) return [`${path} must be ${types.join(" or ")}`];
  }
  if (schema.type === "object" && matchesType("object", value)) {
    for (const key of schema.required ?? []) {
      if (!(key in value)) errors.push(`${path}.${key} is required`);
    }
    for (const [key, child] of Object.entries(schema.properties ?? {})) {
      if (key in value) errors.push(...validate(child, value[key], `${path}.${key}`));
    }
    if (schema.additionalProperties === false) {
      for (const key of Object.keys(value)) {
        if (!(key in (schema.properties ?? {}))) errors.push(`${path}.${key} is not allowed`);
      }
    }
  }
  if (schema.type === "array" && Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      errors.push(`${path} requires at least ${schema.minItems} item(s)`);
    }
    if (schema.items) value.forEach((entry, index) => errors.push(...validate(schema.items, entry, `${path}[${index}]`)));
  }
  if (schema.type === "string" && typeof value === "string" && schema.minLength && value.length < schema.minLength) {
    errors.push(`${path} is too short`);
  }
  return errors;
}

const processSchema = load("plugins/rye-org/schemas/process_definition_claim.schema.json");
const transitionSchema = load("plugins/rye-org/schemas/process_transition_policy_claim.schema.json");
const slackSchema = load("plugins/rye-source-context/schemas/slack_conversation_source_item.schema.json");
const process = load("tests/fixtures/governed-process/process-definition.json");
const transition = load("tests/fixtures/governed-process/process-transition-policy.json");
const slack = load("tests/fixtures/governed-process/slack-source-item.json");

for (const [name, schema, fixture] of [
  ["process definition", processSchema, process],
  ["transition policy", transitionSchema, transition],
  ["Slack source item", slackSchema, slack],
]) {
  const errors = validate(schema, fixture);
  if (errors.length) throw new Error(`${name} fixture failed: ${errors.join("; ")}`);
}

if (!process.states.includes(process.initial_state)) throw new Error("Initial state must be in process states");
for (const state of process.terminal_states) {
  if (!process.states.includes(state)) throw new Error(`Terminal state ${state} is not in process states`);
}
for (const state of [...transition.from_states, transition.to_state]) {
  if (!process.states.includes(state)) throw new Error(`Transition state ${state} is not in process states`);
}

const invalidTransition = structuredClone(transition);
delete invalidTransition.transition_key;
if (validate(transitionSchema, invalidTransition).length === 0) {
  throw new Error("Transition without transition_key unexpectedly passed");
}

const orgManifest = load("plugins/rye-org/rye-plugin.json");
const sourceManifest = load("plugins/rye-source-context/rye-plugin.json");
for (const type of ["process_definition", "process_transition_policy"]) {
  if (!orgManifest.contributes.assertion_types.includes(type)) throw new Error(`rye-org missing ${type}`);
}
if (!orgManifest.contributes.edge_types.includes("holds_role")) throw new Error("rye-org missing holds_role");
if (!sourceManifest.contributes.node_types.includes("source_identity")) throw new Error("source-context missing source_identity");
if (!sourceManifest.contributes.edge_types.includes("identity_of")) throw new Error("source-context missing identity_of");

console.log("Governed process contract test passed");
NODE
