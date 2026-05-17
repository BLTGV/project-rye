# Pattern Contract Template

Use this template when drafting a reusable Rye pattern. Delete sections that do not apply.

```markdown
# Pattern: <name>

## Purpose

<What this pattern represents and when to use it.>

## Non-Goals

- <What this pattern intentionally does not model.>

## Node Contracts

| `node_type` | Purpose | Required Properties | Optional Properties | Label Rule |
|---|---|---|---|---|
| `<type>` | <purpose> | `<field>` | `<field>` | <rule> |

Property schema:

- file: `assets/schemas/<node_type>_properties.schema.json`
- `schema_type`: `<namespace>.<node_type>.properties.v1`
- `schema_version`: `1`

## Edge Contracts

| `edge_type` | Direction | Temporal | Required Properties | Notes |
|---|---|---|---|---|
| `<type>` | `<source>` -> `<target>` | yes/no | `<field>` | <notes> |

Temporal rule:

- active edge: `archived_at IS NULL`
- bounded edge: use `effective_from` and `effective_to`

## Assertion Contracts

| `assertion_type` | Subject | Key Rule | Claim Schema | Supersession |
|---|---|---|---|---|
| `<type>` | `<node_type>` | `default` or `<stable-key-rule>` | `<schema file>` | <rule> |

Claim schema:

- file: `assets/schemas/<assertion_type>_claim.schema.json`
- `schema_type`: `<namespace>.<assertion_type>.claim.v1`
- `schema_version`: `1`

## Event Contracts

| `event_type` | Purpose | Participant Roles | Required Properties |
|---|---|---|---|
| `<type>` | <purpose> | `<role>` | `<field>` |

Write rule:

- use `record_event()`
- never insert into `events` and `event_participants` separately

## Artifact Contracts

| `artifact_type` | Purpose | Content Schema | Location Schema | Dedup Key |
|---|---|---|---|---|
| `<type>` | <purpose> | `<schema file>` | `<schema file>` | `content_hash` |

Write rule:

- use `record_artifact()`
- provide `p_content_hash` when source bytes or normalized content are available

## Source Integration

- system of record:
- domain table:
- link rule:
- CDC rule:
- duplicate handling:

## Security

- classification rule:
- team rule:
- assertion type access:
- redacted fields:

## Read Models

- view or materialized view:
- refresh rule:
- indexes:

## Examples

Include one create example, one update/supersession example, and one query example.

## Tests

- conformance cases:
- security cases:
- duplicate/idempotency cases:
- fixture data:
```

## Compact JSON Form

Use this shape when a machine-readable contract is useful. Validate it with `assets/schemas/rye_pattern_contract.schema.json`.

```json
{
  "schema_type": "rye.pattern_library.pattern_contract.v1",
  "schema_version": 1,
  "name": "reviewable_item_status",
  "status": "draft",
  "purpose": "Track the current status of a reviewable node while preserving history.",
  "non_goals": ["Owning the operational source table"],
  "node_contracts": [],
  "edge_contracts": [],
  "assertion_contracts": [
    {
      "assertion_type": "review_status",
      "subject": "reviewable node",
      "key_rule": "default",
      "claim_schema": "assets/schemas/review_status_claim.schema.json",
      "supersession": "Use supersede_assertion() for every status change."
    }
  ],
  "event_contracts": [
    {
      "event_type": "status_change",
      "purpose": "Audit each status transition.",
      "participant_roles": ["subject"],
      "properties": ["from_status", "to_status", "reason"]
    }
  ],
  "artifact_contracts": [],
  "security": {
    "classification": "inherit from subject node",
    "teams": "inherit from subject node"
  },
  "tests": ["one active default assertion per subject"]
}
```
