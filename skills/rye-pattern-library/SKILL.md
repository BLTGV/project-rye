---
name: rye-pattern-library
description: Select and draft reusable Rye modeling patterns. Use when a user wants to define common node, edge, assertion, event, artifact, JSON Schema, or assertion-key contracts for a domain or customer skill without changing Rye core tables.
---

# Rye Pattern Library

Use this skill when the user is designing a reusable Rye convention and needs a compact pattern contract rather than a customer-specific implementation.

Good outputs include:

1. a pattern contract for a customer or domain skill
2. JSON Schema contracts for node properties, assertion claims, event properties, or artifact content
3. assertion-key and supersession rules
4. examples that show how to write the pattern safely
5. test cases or fixture requirements for the pattern

## Workflow

1. Check the target instance or repo context first:
   - If a database is available, run `SELECT rye_catalog();`
   - If working in this repo, scan `docs/conventions-catalog.md` and relevant `design/` files.
2. Decide which Rye surface owns each part:
   - stable descriptive fields -> node or edge `properties`
   - changing beliefs -> `assertions`
   - things that happened -> `events` via `record_event()`
   - source material or extracted content -> `artifacts` via `record_artifact()`
   - system metadata, teams, or classification -> `attrs`
3. Choose one or more base patterns from [references/common-patterns.md](references/common-patterns.md).
4. Draft the contract with [references/pattern-contract-template.md](references/pattern-contract-template.md).
5. If schemas are requested, follow [references/schema-authoring.md](references/schema-authoring.md).
6. Keep the result convention-based unless the user explicitly asks for a profile migration or helper function.

## Pattern Selection

| User Need | Prefer This Pattern |
|---|---|
| Connect an existing application row | Source-backed entity |
| Track current state with history | Current state assertion |
| Track many active claims of the same type | Multi-valued assertion set |
| Record a relationship that can end | Temporal relationship |
| Record membership, containment, or grouping | Membership or containment |
| Preserve source evidence | Evidence-backed claim |
| Attach parsed source material | Document or artifact reference |
| Record who participated in something | Activity event |
| Handle contradictory information | Candidate review pattern |
| Load CSV/XLSX with lineage | Tabular intake boundary |

## Guardrails

- Do not add columns to Rye core tables for a pattern.
- Do not make customer-specific vocabulary part of this generic skill.
- Do not put operational source data in Rye when a domain table should own it.
- Do not insert into `events` and `event_participants` separately. Use `record_event()`.
- Do not mutate assertion claims. Supersede accepted knowledge or create a
  candidate for review.
- Do not treat JSON Schema files as database enforcement unless the caller adds an explicit validation layer.

## Handoff

- Use `rye-domain-onboarding` when the pattern becomes an installable Rye profile or migration.
- Use `rye-agent-ops` when the user wants executable read/write SQL.
- Use `rye-tabular-intake` when source data starts in CSV or XLSX files.
