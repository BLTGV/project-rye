# CLI Contract

This file defines command and NDJSON contracts. For guidance on building a domain-specific skill that consumes these contracts, read [extension-patterns.md](extension-patterns.md).

## Commands

### `tabular_inspect.mts`

Input:
- `--input <path>` required
- `--sheet <name-or-index>` optional for XLSX
- `--header-row <n>` optional, default `1`
- `--sample <n>` optional, default `5`

Output:
- one JSON document describing the source file, discovered tables/sheets, row counts, header preview, and sample rows

### `tabular_extract.mts`

Input:
- `--input <path>` required
- `--sheet <name-or-index>` optional for XLSX
- `--header-row <n>` optional, default `1`
- `--columns <csv>` optional override for headers
- `--table-name <name>` optional override
- `--blank-as-null` optional

Output:
- NDJSON stream of `source_row` objects

### `tabular_map.mts`

Input:
- NDJSON on stdin or `--input <path>`
- `--config <path>` or `--module <path>` required
- `--export <name>` optional, default `transform`
- `--mapping <name>` optional override for output metadata

Output:
- NDJSON stream of `mapped_record` objects

### `tabular_group.mts`

Input:
- NDJSON on stdin or `--input <path>`
- `--module <path>` required
- `--key-export <name>` optional, default `groupKey`
- `--reduce-export <name>` optional, default `reduce`
- `--mapping <name>` optional override for output metadata

Output:
- NDJSON stream of grouped `mapped_record` objects
- each output has a multi-row `source_set`

### `tabular_change_plan.mts`

Input:
- mapped_record NDJSON on `--input <path>` required
- existing target-table snapshot on `--existing <path>` optional
- `--mode <create|update|append|merge_review>` optional, default `merge_review`
- `--key <table:field[,field]>` optional and repeatable for table-specific identity keys
- `--default-key <field[,field]>` optional fallback key for tables without a table-specific key
- `--clear-nulls` optional; by default blank/null mapped values do not clear existing values

Output:
- one JSON review document with:
  - planned record counts by table
  - existing snapshot counts by table
  - action counts
  - table/action classification for every planned row
  - field-level before/after diffs where an existing row matched
  - review reasons for ambiguous or non-idempotent writes

The command is read-only and table-independent. It never connects to, writes to, or assumes a specific destination system.

### `tabular_stage_rye.mts`

Input:
- NDJSON on stdin or `--input <path>`
- `--node-type <value>` optional, default `rye_tabular_intake_stage_row`
- `--status <value>` optional, default `extracted`
- `--label-prefix <value>` optional

Output:
- NDJSON stream of `rye_stage_record` objects

### `tabular_commit_rye.mts`

Input:
- NDJSON on `--input <path>`
- `--db-url <url>` or `--docker-container <name>` required
- `--emit-sql` optional alternative to `--db-url` / `--docker-container`
- `--run-id <value>` optional
- `--scenario <value>` optional
- `--allow-duplicate-source` optional override to permit a repeated source-file SHA1 fingerprint for the same run kind

Output:
- direct execution mode: one JSON summary describing the Rye run node and inserted counts
- SQL-only mode: one PostgreSQL SQL script ending with a summary `SELECT`
- the summary includes `source_files[].content_sha1` and `run_fingerprint_sha1`

## When PostgreSQL Is Written

Only `tabular_commit_rye.mts` writes to PostgreSQL.

- `tabular_inspect.mts` is read-only
- `tabular_extract.mts` is read-only
- `tabular_map.mts` is read-only
- `tabular_group.mts` is read-only
- `tabular_stage_rye.mts` is read-only
- `tabular_commit_rye.mts` is the database write step

That means you can inspect, extract, map, and stage files freely without creating Rye records, as long as you do not run `tabular_commit_rye.mts`.

`tabular_commit_rye.mts --emit-sql` does not connect to PostgreSQL by itself. It prints the SQL that will write to PostgreSQL when executed by another tool.

## Run Identity vs Duplicate Detection

`tabular_commit_rye.mts` tracks two different run values:

- `run_id`
  - the identity of the run
  - stored as the run node `external_id`
  - chosen by the caller or generated if omitted
- `run_fingerprint_sha1`
  - the duplicate-detection key
  - derived from source file SHA1 values plus run metadata

The fingerprint is built from:

- source file SHA1 values
- input kinds such as `source_row`, `mapped_record`, or `rye_stage_record`
- mapping names for mapped runs
- stage statuses for staged runs
- source table and sheet metadata

So the behavior is:

- same file content, same run kind, different `run_id`
  - blocked as a duplicate by default
- same file content, but extract vs map vs stage
  - allowed, because the fingerprint differs
- same file content, same run kind, `--allow-duplicate-source`
  - allowed intentionally

## SQL-Only Commit Mode

Use `--emit-sql` when the agent cannot open a PostgreSQL connection but can execute SQL through another surface, such as a SQL console or Supabase MCP.

```bash
node skills/rye-tabular-intake/scripts/tabular_commit_rye.mts \
  --emit-sql \
  --input /tmp/parent-records.ndjson \
  --run-id example-domain:parents:2026-04-29 \
  > /tmp/rye-tabular-intake-commit.sql
```

Then execute `/tmp/rye-tabular-intake-commit.sql` through the SQL-only tool.

Requirements:

- run the whole script in one call/session
- the SQL tool must allow multi-statement scripts
- the SQL tool must allow a temporary table inside a transaction
- Rye must already be installed in the target database
- the source files referenced by the NDJSON must be readable locally when the SQL is generated, because the CLI computes source hashes before emitting SQL

The emitted script:

- starts a transaction
- sets `search_path` locally
- creates a temporary context table for generated UUIDs
- applies the same duplicate-source guard unless `--allow-duplicate-source` is used
- writes run, row, event, assertion, and artifact records
- commits and ends with a JSON summary `SELECT`

If the SQL-only tool rejects duplicate source content, regenerate the script with `--allow-duplicate-source` only when the repeated import is intentional.

## NDJSON Objects

### `source_row`

```json
{
  "kind": "source_row",
  "source": {
    "path": "/abs/path/customers.xlsx",
    "format": "xlsx",
    "table_name": "Customers",
    "sheet_name": "Customers",
    "header_row": 1,
    "row_number": 2,
    "record_number": 1
  },
  "lineage": ["extract:Customers"],
  "row": {
    "Customer ID": "C-100",
    "Name": "Ada Lovelace"
  },
  "raw": ["C-100", "Ada Lovelace"]
}
```

### `mapped_record`

```json
{
  "kind": "mapped_record",
  "mapping": "customers_to_contacts",
  "destination_table": "contacts",
  "operation": "upsert",
  "source_set": {
    "group_key": null,
    "primary": {
      "path": "/abs/path/customers.xlsx",
      "format": "xlsx",
      "table_name": "Customers",
      "sheet_name": "Customers",
      "header_row": 1,
      "row_number": 2,
      "record_number": 1
    },
    "sources": [
      {
        "path": "/abs/path/customers.xlsx",
        "format": "xlsx",
        "table_name": "Customers",
        "sheet_name": "Customers",
        "header_row": 1,
        "row_number": 2,
        "record_number": 1
      }
    ],
    "row_count": 1
  },
  "lineage": ["extract:Customers", "map:customers_to_contacts"],
  "record": {
    "external_id": "C-100",
    "full_name": "Ada Lovelace"
  },
  "meta": {},
  "issues": []
}
```

### `rye_stage_record`

```json
{
  "kind": "rye_stage_record",
  "node_type": "rye_tabular_intake_stage_row",
  "label": "Customers row 2",
  "source_set": {
    "group_key": null,
    "primary": {
      "path": "/abs/path/customers.xlsx",
      "format": "xlsx",
      "table_name": "Customers",
      "sheet_name": "Customers",
      "header_row": 1,
      "row_number": 2,
      "record_number": 1
    },
    "sources": [
      {
        "path": "/abs/path/customers.xlsx",
        "format": "xlsx",
        "table_name": "Customers",
        "sheet_name": "Customers",
        "header_row": 1,
        "row_number": 2,
        "record_number": 1
      }
    ],
    "row_count": 1
  },
  "lineage": ["extract:Customers"],
  "properties": {
    "schema_type": "rye.tabular_intake.stage_properties.v2",
    "schema_version": 2,
    "ingest_status": "extracted",
    "source_set": {
      "group_key": null,
      "primary": {
        "path": "/abs/path/customers.xlsx",
        "format": "xlsx",
        "table_name": "Customers",
        "sheet_name": "Customers",
        "header_row": 1,
        "row_number": 2,
        "record_number": 1
      },
      "sources": [
        {
          "path": "/abs/path/customers.xlsx",
          "format": "xlsx",
          "table_name": "Customers",
          "sheet_name": "Customers",
          "header_row": 1,
          "row_number": 2,
          "record_number": 1
        }
      ],
      "row_count": 1
    },
    "raw_fields": {
      "Customer ID": "C-100",
      "Name": "Ada Lovelace"
    }
  }
}
```

### `source_set`

`mapped_record` and `rye_stage_record` use `source_set` instead of a single source row.

- row-level outputs set `group_key` to `null` and contain one source
- grouped outputs set `group_key` and contain every source row that contributed to the parent record
- `primary` is the first deterministic source reference for labels and compact summaries
- `row_count` is the number of unique source row references

## Mapping Module API

`tabular_map.mts` loads a TypeScript module and calls `transform(input)` unless `--export` points elsewhere.

Accepted input:
- `source_row`
- `mapped_record`

Expected return value:
- `null` to drop the row
- one object
- an array of objects

Returned objects must have:

```ts
type MapRecordSpec = {
  destination_table: string;
  operation?: "insert" | "upsert" | "update";
  record: Record<string, unknown>;
  meta?: Record<string, unknown>;
  issues?: string[];
};
```

## Mapping Module Example

```ts
import type { MapRecordSpec, SourceRow } from "../skills/rye-tabular-intake/scripts/lib/contracts.mts";

export const mapping = {
  name: "customers_to_contacts"
};

export function transform(input: SourceRow): MapRecordSpec | null {
  if (input.kind !== "source_row") {
    return null;
  }

  if (!input.row.Email) {
    return null;
  }

  return {
    destination_table: "contacts",
    operation: "upsert",
    record: {
      external_id: input.row["Customer ID"],
      full_name: input.row.Name,
      email: String(input.row.Email).toLowerCase()
    }
  };
}
```

## Grouping Module API

`tabular_group.mts` loads a TypeScript module and calls `groupKey(input)` for each input record, then calls `reduce(group)` once per group.

Accepted input:
- `source_row`
- `mapped_record`

Expected `groupKey(input)` return value:
- string or number to include the row in a group
- `null`, `undefined`, or empty string to drop the row

Expected `reduce(group)` return value:
- `null` to drop the group
- one `MapRecordSpec`
- an array of `MapRecordSpec`

The group object has:

```ts
type GroupContext = {
  key: string;
  records: Array<SourceRow | MappedRecord>;
  source_set: SourceSet;
  first(field: string): unknown;
  distinct(field: string): unknown[];
  sum(field: string | ((record) => unknown)): number;
};
```

Grouped outputs are emitted as `mapped_record` objects with `lineage` ending in `group:<mapping-name>` and a multi-row `source_set`.

## Grouping Module Example

```ts
export const mapping = {
  name: "invoice_rows_to_invoices"
};

export function groupKey(input) {
  return input.kind === "source_row" ? input.row["Invoice Number"] : null;
}

export function reduce(group) {
  return {
    destination_table: "invoices",
    operation: "upsert",
    record: {
      invoice_number: group.key,
      customer_external_id: group.first("Customer External ID"),
      line_count: group.records.length,
      total_amount: group.sum((record) => {
        const row = record.kind === "source_row" ? record.row : record.record;
        return Number(row.Quantity ?? 0) * Number(row["Unit Price"] ?? 0);
      })
    }
  };
}
```

## Declarative Mapping Config

Use a JSON config when the mapping can be described as column selection plus conversions.

```json
{
  "name": "customers_to_contacts",
  "destination_table": "contacts",
  "operation": "upsert",
  "filter": {
    "column": "Status",
    "in": ["Active", "Prospect"]
  },
  "record": {
    "external_id": {
      "column": "Customer ID",
      "trim": true,
      "required": true
    },
    "full_name": {
      "column": "Name",
      "trim": true
    },
    "email": {
      "column": "Email",
      "trim": true,
      "lowercase": true,
      "null_if": ["", "n/a"]
    },
    "is_active": {
      "column": "Status",
      "map": {
        "Active": true,
        "Prospect": true,
        "Inactive": false
      }
    },
    "created_at": {
      "column": "Created At",
      "convert": "timestamp"
    },
    "source_system": {
      "literal": "legacy_spreadsheet"
    }
  }
}
```

Supported field rule keys:

- `column`
- `literal`
- `join`
- `trim`
- `lowercase`
- `uppercase`
- `null_if`
- `required`
- `convert`
- `map`

Supported `convert` values:

- `string`
- `integer`
- `number`
- `boolean`
- `date`
- `timestamp`
- `json`

## Composing Multi-Table Loads

Use separate mapping modules over the same extracted stream:

```bash
node skills/rye-tabular-intake/scripts/tabular_extract.mts --input data/customers.xlsx --sheet Customers \
  | tee /tmp/customers.ndjson \
  | node skills/rye-tabular-intake/scripts/tabular_stage_rye.mts --node-type rye_tabular_intake_stage_row > /tmp/rye-stage.ndjson

node skills/rye-tabular-intake/scripts/tabular_map.mts --input /tmp/customers.ndjson --module mappings/customers_to_contacts.mts > /tmp/contacts.ndjson
node skills/rye-tabular-intake/scripts/tabular_map.mts --input /tmp/customers.ndjson --module mappings/customers_to_addresses.mts > /tmp/addresses.ndjson
```

Or chain map steps when the second step depends on the first:

```bash
node skills/rye-tabular-intake/scripts/tabular_extract.mts --input data/customers.csv \
  | node skills/rye-tabular-intake/scripts/tabular_map.mts --module mappings/customers_to_contacts.mts \
  | node skills/rye-tabular-intake/scripts/tabular_map.mts --module mappings/contacts_to_assignments.mts
```

Use `tabular_group.mts` when multiple rows should produce a parent record:

```bash
node skills/rye-tabular-intake/scripts/tabular_extract.mts --input data/invoice_lines.csv > /tmp/invoice-lines.ndjson
node skills/rye-tabular-intake/scripts/tabular_map.mts --input /tmp/invoice-lines.ndjson --config mappings/invoice_lines.json > /tmp/invoice-line-records.ndjson
node skills/rye-tabular-intake/scripts/tabular_group.mts --input /tmp/invoice-lines.ndjson --module mappings/invoices.mts > /tmp/invoice-records.ndjson
```

For conversational setup, it is often better to build a JSON config first, then upgrade to TypeScript only if the mapping stops fitting the declarative format.

## Rye Tracking Guidance

The staging CLI does not write to PostgreSQL. It emits a stable envelope that can be turned into Rye writes by `tabular_commit_rye.mts`.

`tabular_commit_rye.mts` stores the intake trail in Rye as:

- one run node in `nodes`
- one row node per `source_set` in `nodes`
- `rye_tabular_intake_run_started`, `rye_tabular_intake_run_completed`, `rye_tabular_intake_row_extracted`, `rye_tabular_intake_row_mapped`, and `rye_tabular_intake_row_staged` entries in `events`
- `rye_tabular_intake_source_row`, `rye_tabular_intake_mapped_record`, and `rye_tabular_intake_stage_record` entries in `assertions`
- `rye_tabular_intake_source_file` entries in `artifacts`

This keeps raw extraction, mapping output, and staging transitions in Rye’s append-only audit model before final domain-table load.

Every JSONB payload written by `tabular_commit_rye.mts` also carries a namespaced contract marker:

- `schema_type`
- `schema_version`

The concrete JSON Schema files live under `skills/rye-tabular-intake/assets/schemas/` and are validated by the CLI before anything is written to PostgreSQL.

Run-level duplicate protection works like this:

- `tabular_commit_rye.mts` reads the original source file paths from the NDJSON records and their `source_set.sources`
- each distinct source file is hashed with SHA1
- the CLI builds a run fingerprint from:
  - source file SHA1 values
  - input kinds such as `source_row`, `mapped_record`, or `rye_stage_record`
  - mapping names for mapped runs
  - stage statuses for staged runs
- if another active `rye.tabular_intake.run` node already has the same `run_fingerprint_sha1`, the commit is rejected
- pass `--allow-duplicate-source` when you intentionally want to reprocess the same source content

It can then be turned into final domain records by:

- creating a `rye_tabular_intake_row` node per source row or grouped `source_set`
- storing `raw_fields` and mapped payloads in `properties`
- asserting load state such as `extracted`, `mapped`, `loaded`, or `rejected`
- recording import events with `record_event(...)`
- attaching original files as artifacts with `record_artifact(...)`

Keep the raw extracted row available somewhere in Rye before destructive normalization. That preserves auditability and lets later mapping corrections replay cleanly.
