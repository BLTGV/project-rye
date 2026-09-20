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
   - `node skills/rye-tabular-intake/scripts/tabular_commit_rye.mts --role team_member --db-url "$DATABASE_URL" --input /tmp/source_rows.ndjson --run-id customer-import-2026-03-10`
   - if only SQL execution is available: `node skills/rye-tabular-intake/scripts/tabular_commit_rye.mts --role team_member --emit-sql --input /tmp/source_rows.ndjson --run-id customer-import-2026-03-10 > /tmp/rye-intake.sql`

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

The commit step writes with the authority of a person, so it will not start without one. Pass `--role <name>`, or set `RYE_SESSION_ROLE`; there is no default. `team_member` is enough for everything this skill does, and an agent does not pick a person's role for them — ask which role to use. `viewer` and an agent role are refused, because a session with no role set or set to `viewer` writes nothing at all: every insert into `nodes`, `events`, `assertions`, `artifacts`, and `node_source_map` comes back refused. The role goes into the SQL the script runs and into the script it emits, so do not strip those lines out.

`assets/postgres/link_stage_records.sql` takes the role the same way, as a psql variable: `psql "$DATABASE_URL" -v rye_role=team_member -f link_stage_records.sql`. Through a tool with no psql variables, replace `:'rye_role'` with the role in quotes.

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

## Intake Consistency: Three Of Four Rules

A spreadsheet carries the same defects a conversation does: a termination date
column, a start/end date column, a computed column. Three of the four intake
rules bind a tabular run. The fourth does not: this skill writes source claims
and never calls `record_distillation()`, so "a digest asserts nothing its
sources establish" has nothing here to apply to. If a consuming skill distils
over what a run wrote, that rule binds the consuming skill.

The reads that find breakage after a run are in
`skills/rye-pattern-library/references/intake-consistency-checks.md`. Run them
over what the run wrote, as part of post-write verification. Each example below
is executable against the fixture in `eval/intake_consistency/` and runs under
the role the commit step already takes.

**A termination date closes the edges it contradicts.** A roster export with a
termination date produces an `employment_status` claim. The `employs` and role
edges have to end on the same date, or the graph contradicts the column that
was just imported. The commit role can do this; an agent role cannot touch
`edges` at all.

```sql
-- As the role the run was given. team_member is enough.
SELECT set_config('app.current_role', 'team_member', false);

UPDATE edges e
SET effective_to = d.departed_at
FROM (
    SELECT a.subject_node_id AS person_id,
           a.effective_at    AS departed_at
    FROM current_valid_assertions a
    WHERE a.assertion_type = 'employment_status'
      AND a.claim->>'status' = 'departed'
      AND a.effective_at IS NOT NULL
) d
WHERE (e.source_id = d.person_id OR e.target_id = d.person_id)
  AND e.edge_type IN ('employs', 'reports_to', 'assigned_to',
                      'member_of', 'project_member', 'affiliated_with')
  AND e.archived_at IS NULL
  AND e.effective_to IS NULL;
```

**A row's effective date and the edge window tell one story.** When a row dates
a relationship, the claim's `effective_at` and the edge's `effective_from` come
from the same column. Point the claim at the edge with `subject_edge_id` or
`attrs.edge_id`. Rerunning a corrected file does not fix a date on its own:
`record_assertion()` matches on claim, basis and confidence, returns the
incumbent's id and writes nothing when only the date changed. Use
`supersede_assertion()`.

```sql
SELECT set_config('app.current_role', 'team_member', false);

SELECT supersede_assertion(
    p_old_assertion_id := a.id,
    p_new_assertion_type := a.assertion_type,
    p_new_subject_node_id := NULL,
    p_new_subject_edge_id := e.id,
    p_new_claim := a.claim,
    p_new_assertion_key := a.assertion_key,
    p_new_effective_at := e.effective_from,
    p_new_basis := a.basis,
    p_new_evidence := ARRAY[jsonb_build_object(
        'kind', 'source',
        'event_id', (SELECT id FROM events
                     WHERE summary LIKE 'Staffing channel:%' LIMIT 1)
    )]
)
FROM assertions a
JOIN edges e ON e.id = a.subject_edge_id
WHERE a.assertion_type = 'assignment_status'
  AND a.superseded_at IS NULL
  AND a.effective_at < e.effective_from;
```

**A computed column cites the window it was computed from.** A total, a rate,
an average over rows is a derived number. Put the period the rows cover in
`attrs.source_window = {"from": ..., "to": ...}`, ISO 8601, covering the
evidence the claim cites. A sum over a file whose rows span March to June and
whose window says June cannot be recomputed by anyone.

```sql
SELECT set_config('app.current_role', 'team_member', false);

SELECT supersede_assertion(
    p_old_assertion_id := a.id,
    p_new_assertion_type := a.assertion_type,
    p_new_subject_node_id := a.subject_node_id,
    p_new_subject_edge_id := NULL,
    p_new_claim := a.claim,
    p_new_assertion_key := a.assertion_key,
    p_new_effective_at := a.effective_at,
    p_new_basis := a.basis,
    p_new_evidence := ARRAY[jsonb_build_object(
        'kind', 'derivation',
        'source_assertion_id', (SELECT s.id FROM current_valid_assertions s
                                WHERE s.assertion_type = 'task_status'
                                LIMIT 1)
    )],
    p_new_attrs := '{"source_window":{"from":"2026-09-01T00:00:00Z",
                                      "to":"2026-09-30T00:00:00Z"}}'::jsonb
)
FROM assertions a
WHERE a.assertion_type = 'throughput_estimate'
  AND a.superseded_at IS NULL;
```

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
