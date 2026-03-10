---
name: rye-tabular-intake
description: Extract CSV and XLSX source tables for Rye-tracked imports. Use when a user needs to inspect tabular source files, emit row-level NDJSON with lineage, map source fields into one or more destination-table records, or stage extracted data for Rye load tracking with composable TypeScript CLI scripts.
---

# Rye Tabular Intake

Use this skill when source data starts in CSV or XLSX files and needs to be:

1. inspected before mapping
2. extracted into row-level NDJSON with stable source lineage
3. mapped into destination-table shaped records
4. staged as Rye tracking records before final database load

## Conversation First

When the destination mapping is not already specified, use the file inspection output to drive a short mapping conversation with the user before writing transforms.

Confirm:

1. which source sheet or table matters
2. which source columns map to which destination fields
3. what conversions are required
4. which fields are required, optional, or defaulted
5. whether one source row should emit one record or multiple records

Prefer a declarative JSON mapping config when the requested mapping is mostly column selection and coercion. Use a TypeScript mapping module when the logic is conditional, one-to-many, or depends on prior mapped output.

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
5. Commit the intake trail into Rye:
   - `node skills/rye-tabular-intake/scripts/tabular_commit_rye.mts --db-url "$DATABASE_URL" --input /tmp/source_rows.ndjson --run-id customer-import-2026-03-10`

## When It Writes

The pipeline is read-only until the commit step.

- `tabular_inspect.mts`
  - reads CSV/XLSX and prints one JSON inspection document
- `tabular_extract.mts`
  - reads CSV/XLSX and emits `source_row` NDJSON
- `tabular_map.mts`
  - reads NDJSON and emits `mapped_record` NDJSON
- `tabular_stage_rye.mts`
  - reads NDJSON and emits `rye_stage_record` NDJSON
- `tabular_commit_rye.mts`
  - reads NDJSON and writes Rye nodes, events, assertions, and artifacts into PostgreSQL

If the user wants to inspect, extract, map, or stage data without touching the database, stop before `tabular_commit_rye.mts`.

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
- `tabular_stage_rye.mts`
  - wraps extracted or mapped rows in a Rye-friendly staging envelope
- `tabular_commit_rye.mts`
  - writes extracted, mapped, or staged records into Rye nodes, events, assertions, and source-file artifacts
  - fingerprints original source files with SHA1 and rejects duplicate runs of the same run kind unless `--allow-duplicate-source` is passed

## Mapping Strategy

Use the lightest mapping mechanism that fits:

- declarative JSON config for conversationally defined column maps and conversions
- TypeScript module for difficult cases

TypeScript modules remain the escape hatch for:

- one source row to one destination record
- one source row to many destination records
- chained transforms over prior mapped output
- filtering rows by returning `null`

Read [references/cli-contract.md](references/cli-contract.md) when you need:

- the NDJSON object contracts
- the mapping module API
- the declarative mapping config format
- example mapping modules
- guidance on staging records into Rye nodes/assertions/artifacts
- the distinct `rye_tabular_intake_*` event, assertion, artifact, and node types
- the JSON Schema contracts under `assets/schemas/`

Read [references/mapping-conversation.md](references/mapping-conversation.md) when the user wants to configure mappings interactively in chat before you write the config or module.

Read [references/testing-fixtures.md](references/testing-fixtures.md) when you need Docker-runnable fixture data for one-to-one, one-to-many, or many-to-one import scenarios.

## Guardrails

- Inspect before extracting when the header row or target sheet is unclear.
- When column meaning is ambiguous, ask the user before hard-coding a conversion.
- Keep extraction lossless. Preserve source lineage and raw field names before coercing into destination shapes.
- Use `tabular_map.mts` for deterministic transforms; avoid ad hoc one-off rewrites in chat when a reusable module is appropriate.
- Use Rye staging records to track intake status before writing final domain-table records.
- Prefer `tabular_commit_rye.mts` when the user wants extraction and staging history stored in Rye itself.
- Prefer pipelines that keep stdout machine-readable and stderr reserved for actionable errors.
