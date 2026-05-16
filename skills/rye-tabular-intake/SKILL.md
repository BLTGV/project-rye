---
name: rye-tabular-intake
description: Extract CSV and XLSX source tables for Rye-tracked imports. Use when a user needs to inspect tabular source files, emit row-level NDJSON with lineage, map source fields into destination records, group many source rows into parent records with source_set lineage, stage extracted data, or build a domain-specific intake skill on top of generic tabular primitives.
---

# Rye Tabular Intake

Use this skill when source data starts in CSV or XLSX files and needs to be:

1. inspected before mapping
2. extracted into row-level NDJSON with stable source lineage
3. mapped into destination-table shaped records
4. grouped into parent records when many source rows describe one destination record
5. staged as Rye tracking records before final database load

## Conversation First

When the destination mapping is not already specified, use the file inspection output to drive a short mapping conversation with the user before writing transforms.

Confirm:

1. which source sheet or table matters
2. which source columns map to which destination fields
3. what conversions are required
4. which fields are required, optional, or defaulted
5. whether one source row should emit one record or multiple records

Prefer a declarative JSON mapping config when the requested mapping is mostly column selection and coercion. Use a TypeScript mapping module when the logic is conditional, one-to-many, or depends on prior mapped output.

If the user is creating a domain-specific intake skill on top of this one, keep this skill generic and put source-column aliases, validation rules, destination-table choices, and domain examples in the consuming skill.

## Workflow

1. Inspect the file first:
   - `node skills/rye-tabular-intake/scripts/tabular_inspect.mts --input data/customers.xlsx`
2. Extract rows as NDJSON:
   - `node skills/rye-tabular-intake/scripts/tabular_extract.mts --input data/customers.xlsx --sheet Customers`
3. Configure mappings with the user, then choose one of:
   - declarative config:
     - `node skills/rye-tabular-intake/scripts/tabular_extract.mts --input data/customers.xlsx --sheet Customers | node skills/rye-tabular-intake/scripts/tabular_map.mts --config mappings/customers_to_contacts.json`
   - TypeScript module:
   - `node skills/rye-tabular-intake/scripts/tabular_extract.mts --input data/customers.xlsx --sheet Customers | node skills/rye-tabular-intake/scripts/tabular_map.mts --module mappings/customers_to_contacts.mts`
4. Stage extracted or mapped rows for Rye load tracking:
   - `node skills/rye-tabular-intake/scripts/tabular_extract.mts --input data/customers.xlsx --sheet Customers | node skills/rye-tabular-intake/scripts/tabular_stage_rye.mts --node-type rye_tabular_intake_stage_row`
5. For many-to-one records, group extracted or mapped rows:
   - `node skills/rye-tabular-intake/scripts/tabular_extract.mts --input data/interests.xlsx | node skills/rye-tabular-intake/scripts/tabular_group.mts --module mappings/interests_to_opportunities.mts`
6. For updates, appends, or agent-assisted merges, compare mapped records with a target-table snapshot:
   - `node skills/rye-tabular-intake/scripts/tabular_change_plan.mts --input /tmp/mapped.ndjson --existing /tmp/existing-target.json --key contacts:external_id --mode merge_review > /tmp/change-plan.json`
7. Validate the import/change process before target writes when the consuming workflow needs an explicit gate:
   - `node skills/rye-import-inspector/scripts/inspect_import_run.mjs --source /tmp/source.ndjson --mapped /tmp/mapped.ndjson --change-plan /tmp/change-plan.json --metadata /tmp/import-metadata.json --phase prewrite > /tmp/import-inspection.json`
8. Commit the intake trail into Rye:
   - `node skills/rye-tabular-intake/scripts/tabular_commit_rye.mts --db-url "$DATABASE_URL" --input /tmp/source_rows.ndjson --run-id customer-import-2026-03-10`
   - if only SQL execution is available: `node skills/rye-tabular-intake/scripts/tabular_commit_rye.mts --emit-sql --input /tmp/source_rows.ndjson --run-id customer-import-2026-03-10 > /tmp/rye-intake.sql`

## When It Writes

The pipeline is read-only until the commit step.

Local NDJSON, snapshot, change-plan, and SQL files are intermediate execution artifacts. Rye is the durable traceability record once `tabular_commit_rye.mts` writes run nodes, events, assertions, and source-file artifacts.

- `tabular_inspect.mts`
  - reads CSV/XLSX and prints one JSON inspection document
- `tabular_extract.mts`
  - reads CSV/XLSX and emits `source_row` NDJSON
- `tabular_map.mts`
  - reads NDJSON and emits `mapped_record` NDJSON
- `tabular_group.mts`
  - reads NDJSON and emits grouped `mapped_record` NDJSON with multi-row `source_set` lineage
- `tabular_change_plan.mts`
  - reads mapped records plus an optional existing target-table snapshot and emits a read-only change-review plan
- `tabular_stage_rye.mts`
  - reads NDJSON and emits `rye_stage_record` NDJSON
- `tabular_commit_rye.mts`
  - reads NDJSON and writes Rye nodes, events, assertions, and artifacts into PostgreSQL
  - with `--emit-sql`, prints a SQL script instead of connecting to PostgreSQL

If the user wants to inspect, extract, map, or stage data without touching the database, stop before `tabular_commit_rye.mts`.

If the user has no `DATABASE_URL` but can execute SQL through a tool such as a SQL console or Supabase MCP, use `tabular_commit_rye.mts --emit-sql`, then execute the generated SQL in one call/session. The source files referenced by the NDJSON must still be readable locally when the SQL is generated so the tool can compute source hashes.

## Runs And Duplicates

A run is created only when `tabular_commit_rye.mts` is called.

- `run_id`
  - the identity of the run
  - becomes the run node `external_id`
  - can be any stable label such as `customers:extract:2026-03-10`
- `run_fingerprint_sha1`
  - the duplicate-detection key
  - built from source file SHA1 values plus run-kind metadata
  - used only to decide whether a new run should be rejected as a duplicate

These are different things:

- two different `run_id` values can still be treated as duplicates if they produce the same `run_fingerprint_sha1`
- extract, map, and stage runs over the same file are allowed because they produce different fingerprints
- `--allow-duplicate-source` permits a new run even when the fingerprint already exists

The duplicate check is database-wide for the connected Rye instance. If a later machine writes to the same Rye database and has the same source file bytes, the second commit is rejected unless `--allow-duplicate-source` is used.

## Command Set

- `tabular_inspect.mts`
  - discovers sheets/tables, row counts, header preview, sample rows
- `tabular_extract.mts`
  - emits one `source_row` JSON object per data row
- `tabular_map.mts`
  - reads NDJSON from stdin or file and applies either a declarative JSON mapping config or a TypeScript transform module
- `tabular_group.mts`
  - groups `source_row` or `mapped_record` input and reduces each group into one or more `mapped_record` outputs
  - emits `source_set` lineage for every source row that contributed to the grouped output
- `tabular_change_plan.mts`
  - compares destination-table shaped `mapped_record` objects with an existing target snapshot
  - classifies each planned row as `create`, `update`, `append`, `possible_merge`, `no_change`, or `needs_review`
  - treats blank or omitted mapped values as no change and never writes to the database
- `tabular_stage_rye.mts`
  - wraps extracted or mapped rows in a Rye-friendly staging envelope
- `tabular_commit_rye.mts`
  - writes extracted, mapped, or staged records into Rye nodes, events, assertions, and source-file artifacts
  - fingerprints original source files with SHA1 and rejects duplicate runs of the same run kind unless `--allow-duplicate-source` is passed
  - can emit a transaction SQL script for SQL-only environments
- `rye-import-inspector`
  - validates source rows, mapped records, change plans, metadata, old-value evidence, target table declarations, approvals, and post-write verification
  - emits `rye_stage_record` validation reports that can be committed through `tabular_commit_rye.mts`

## Mapping Strategy

Use the lightest mapping mechanism that fits:

- declarative JSON config for conversationally defined column maps and conversions
- TypeScript module for difficult cases

TypeScript modules remain the escape hatch for:

- one source row to one destination record
- one source row to many destination records
- chained transforms over prior mapped output
- filtering rows by returning `null`

Use `tabular_group.mts` when many source rows produce one destination record, such as invoice lines grouped into invoices or vetted interests grouped into acquisition opportunities.

## Update And Change Review

Use `tabular_change_plan.mts` when a mapped import may update, append to, or merge with existing target-table records.

The change planner is table-independent. It only looks at `mapped_record.destination_table`, mapped `record` values, caller-supplied key fields, and a caller-supplied existing snapshot. It does not know about any destination database, API, or write path.

Existing snapshots may be JSON or NDJSON. Useful shapes include:

- a list of objects with `destination_table` and `record`
- an object keyed by destination table name
- an object with generic wrappers such as `data`, `rows`, `records`, or `results`

Default policy:

- blank or omitted mapped values mean no change
- field clearing requires `--clear-nulls` and explicit review
- exact key collisions in append mode are classified as `needs_review`
- fuzzy or agent-assisted matches are classified as `possible_merge` or `needs_review`
- the command is read-only; final writes belong to the consuming domain skill
- before target writes, the consuming skill should record the source, mapped records, old values or target snapshot, change-plan outcome, approval, target tables, operation types, touched IDs, and verification result in Rye

Read [references/cli-contract.md](references/cli-contract.md) when you need:

- the NDJSON object contracts
- the mapping module API
- the declarative mapping config format
- example mapping modules
- guidance on staging records into Rye nodes/assertions/artifacts
- the distinct `rye_tabular_intake_*` event, assertion, artifact, and node types
- the JSON Schema contracts under `assets/schemas/`

Read [references/mapping-conversation.md](references/mapping-conversation.md) when the user wants to configure mappings interactively in chat before you write the config or module.

Read [references/extension-patterns.md](references/extension-patterns.md) when you need to create or evaluate a domain-specific skill that consumes these CLIs, especially for many-to-one grouped imports.

Read [references/testing-fixtures.md](references/testing-fixtures.md) when you need Docker-runnable fixture data for one-to-one, one-to-many, or many-to-one import scenarios.

## Guardrails

- Inspect before extracting when the header row or target sheet is unclear.
- When column meaning is ambiguous, ask the user before hard-coding a conversion.
- Keep extraction lossless. Preserve source lineage and raw field names before coercing into destination shapes.
- Use `tabular_map.mts` for deterministic transforms; avoid ad hoc one-off rewrites in chat when a reusable module is appropriate.
- Use `tabular_group.mts` for many-to-one reductions; keep domain-specific grouping rules in the consuming skill or mapping module.
- Use `tabular_change_plan.mts` before rare update, append, or merge writes so due diligence is separate from final target-specific SQL or API calls.
- Use `rye-import-inspector` as the generic validation gate before and after target writes; keep domain-specific policy in consuming skills.
- Use Rye staging records to track intake status before writing final domain-table records.
- Prefer `tabular_commit_rye.mts` when the user wants extraction and staging history stored in Rye itself.
- Prefer `--emit-sql` when the available database interface can execute SQL but cannot provide a connection string.
- Prefer pipelines that keep stdout machine-readable and stderr reserved for actionable errors.
