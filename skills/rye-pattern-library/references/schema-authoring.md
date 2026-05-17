# Schema Authoring

Rye stores flexible JSONB. JSON Schema files are contracts for agents, import tools, tests, and customer skills. They are not database constraints unless the caller adds validation.

## When To Write A Schema

Write a schema when:

- multiple agents or imports will produce the same JSON shape
- a claim shape has required identity fields
- a customer skill needs stable examples
- tests need to validate generated payloads

Do not write a schema for one-off exploratory notes.

## Naming

Use stable names:

- node properties: `<namespace>.<node_type>.properties.v1`
- edge properties: `<namespace>.<edge_type>.edge_properties.v1`
- assertion claim: `<namespace>.<assertion_type>.claim.v1`
- event properties: `<namespace>.<event_type>.event_properties.v1`
- artifact content: `<namespace>.<artifact_type>.artifact_content.v1`

Use `schema_type` and `schema_version` inside generated payloads when the JSON crosses a boundary, such as imports, artifacts, or agent-generated claims.

## Versioning

- Additive optional fields can stay on the same version.
- New required fields should create a new version.
- Changed meaning should create a new version.
- Keep old schemas when old artifacts or assertions may still be read.

## Strictness

Prefer:

- `additionalProperties: false` for generated import envelopes and artifacts
- `additionalProperties: true` for domain node properties unless the customer wants strict validation
- explicit `required` arrays for identity and lifecycle fields
- `anyOf: [{ "type": "string" }, { "type": "null" }]` for nullable values

Do not use JSON Schema to hide uncertainty. If a value is unknown, allow null or omit the field by design.

## Claim Schema Checklist

For assertion claims, include:

- the business value being asserted
- identity fields used by the assertion key
- source identifiers needed for explanation
- effective date or observed date when relevant
- confidence inputs when useful

Keep provenance connected through `source_event_id`; do not rely on claim JSON alone for provenance.

## Property Schema Checklist

For node or edge properties, include:

- stable display fields
- source system identifiers if useful for search
- denormalized values needed for summaries
- values that do not require assertion history

Do not put teams, classification, or redaction metadata in `properties`. Use `attrs` and Rye security conventions.

## Minimal Claim Schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["schema_type", "schema_version", "value", "basis"],
  "properties": {
    "schema_type": { "const": "customer.pattern.example_claim.v1" },
    "schema_version": { "const": 1 },
    "value": { "type": "string" },
    "basis": { "type": "string" },
    "observed_at": {
      "anyOf": [
        { "type": "string", "format": "date-time" },
        { "type": "null" }
      ]
    }
  },
  "additionalProperties": true
}
```

## Review Questions

- Can an agent choose the correct `assertion_key` from this schema?
- Can a reviewer explain where the value came from?
- Does this belong in a domain table instead?
- Is the schema generic enough for the pattern, or did customer vocabulary leak in?
- Is there a test fixture that proves one valid and one invalid example?
