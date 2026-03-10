# CLI Contract

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
- `--run-id <value>` optional
- `--scenario <value>` optional
- `--allow-duplicate-source` optional override to permit a repeated source-file SHA1 fingerprint for the same run kind

Output:
- one JSON summary describing the Rye run node and inserted counts
- the summary includes `source_files[].content_sha1` and `run_fingerprint_sha1`

## When PostgreSQL Is Written

Only `tabular_commit_rye.mts` writes to PostgreSQL.

- `tabular_inspect.mts` is read-only
- `tabular_extract.mts` is read-only
- `tabular_map.mts` is read-only
- `tabular_stage_rye.mts` is read-only
- `tabular_commit_rye.mts` is the database write step

That means you can inspect, extract, map, and stage files freely without creating Rye records, as long as you do not run `tabular_commit_rye.mts`.

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
  "source": {
    "path": "/abs/path/customers.xlsx",
    "format": "xlsx",
    "table_name": "Customers",
    "sheet_name": "Customers",
    "header_row": 1,
    "row_number": 2,
    "record_number": 1
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
  "properties": {
    "schema_type": "rye.tabular_intake.stage_properties.v1",
    "schema_version": 1,
    "ingest_status": "extracted",
    "source_format": "xlsx",
    "source_path": "/abs/path/customers.xlsx",
    "source_table": "Customers",
    "source_sheet": "Customers",
    "source_row_number": 2,
    "raw_fields": {
      "Customer ID": "C-100",
      "Name": "Ada Lovelace"
    }
  }
}
```

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

For conversational setup, it is often better to build a JSON config first, then upgrade to TypeScript only if the mapping stops fitting the declarative format.

## Rye Tracking Guidance

The staging CLI does not write to PostgreSQL. It emits a stable envelope that can be turned into Rye writes by `tabular_commit_rye.mts`.

`tabular_commit_rye.mts` stores the intake trail in Rye as:

- one run node in `nodes`
- one row node per source row in `nodes`
- `rye_tabular_intake_run_started`, `rye_tabular_intake_run_completed`, `rye_tabular_intake_row_extracted`, `rye_tabular_intake_row_mapped`, and `rye_tabular_intake_row_staged` entries in `events`
- `rye_tabular_intake_source_row`, `rye_tabular_intake_mapped_record`, and `rye_tabular_intake_stage_record` entries in `assertions`
- `rye_tabular_intake_source_file` entries in `artifacts`

This keeps raw extraction, mapping output, and staging transitions in Rye’s append-only audit model before final domain-table load.

Every JSONB payload written by `tabular_commit_rye.mts` also carries a namespaced contract marker:

- `schema_type`
- `schema_version`

The concrete JSON Schema files live under `skills/rye-tabular-intake/assets/schemas/` and are validated by the CLI before anything is written to PostgreSQL.

Run-level duplicate protection works like this:

- `tabular_commit_rye.mts` reads the original source file paths from the NDJSON records
- each distinct source file is hashed with SHA1
- the CLI builds a run fingerprint from:
  - source file SHA1 values
  - input kinds such as `source_row`, `mapped_record`, or `rye_stage_record`
  - mapping names for mapped runs
  - stage statuses for staged runs
- if another active `rye.tabular_intake.run` node already has the same `run_fingerprint_sha1`, the commit is rejected
- pass `--allow-duplicate-source` when you intentionally want to reprocess the same source content

It can then be turned into final domain records by:

- creating a `rye_tabular_intake_row` node per source row
- storing `raw_fields` and mapped payloads in `properties`
- asserting load state such as `extracted`, `mapped`, `loaded`, or `rejected`
- recording import events with `record_event(...)`
- attaching original files as artifacts with `record_artifact(...)`

Keep the raw extracted row available somewhere in Rye before destructive normalization. That preserves auditability and lets later mapping corrections replay cleanly.
