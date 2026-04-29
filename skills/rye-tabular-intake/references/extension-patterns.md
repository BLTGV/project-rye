# Extension Patterns

Use this reference when a domain-specific intake skill should consume `rye-tabular-intake` instead of adding domain rules to the base skill.

## Boundary

`rye-tabular-intake` owns generic mechanics:

- CSV/XLSX inspection and extraction
- row-level `source_row` NDJSON
- row mapping with `tabular_map.mts`
- grouped mapping with `tabular_group.mts`
- `source_set` lineage
- Rye audit commits for extracted, mapped, grouped, and staged records

A consuming domain skill owns domain decisions:

- expected source columns and column aliases
- required fields and domain validation
- destination table or graph conventions
- row mapping modules
- grouping modules
- domain fixtures and expected counts
- final domain-table materialization or loading SQL

Do not add domain vocabulary to `rye-tabular-intake` unless it is only a fixture example. Put repeatable import rules in the consuming skill.

## Consuming Skill Shape

```text
skills/example-domain-intake/
  SKILL.md
  references/source-columns.md
  references/domain-mapping.md
  mappings/source_rows_to_child_records.mts
  mappings/source_rows_to_parent_records.mts
  assets/fixtures/example-source.csv
```

In the consuming `SKILL.md`, route the agent to this base skill first:

```markdown
Use `rye-tabular-intake` to inspect, extract, map, group, stage, and commit tabular lineage. This skill owns only the domain mapping modules and validation rules.
```

## Basic Pipeline

Extract once, then branch into child and parent outputs:

```bash
node skills/rye-tabular-intake/scripts/tabular_extract.mts \
  --input data/source.xlsx \
  --sheet "Source Rows" \
  --blank-as-null \
  > /tmp/source-rows.ndjson

node skills/rye-tabular-intake/scripts/tabular_map.mts \
  --input /tmp/source-rows.ndjson \
  --module skills/example-domain-intake/mappings/source_rows_to_child_records.mts \
  > /tmp/child-records.ndjson

node skills/rye-tabular-intake/scripts/tabular_group.mts \
  --input /tmp/source-rows.ndjson \
  --module skills/example-domain-intake/mappings/source_rows_to_parent_records.mts \
  > /tmp/parent-records.ndjson
```

Stage or commit each stream based on the audit trail you want:

```bash
node skills/rye-tabular-intake/scripts/tabular_stage_rye.mts \
  --input /tmp/parent-records.ndjson \
  --status grouped \
  > /tmp/parent-stage.ndjson

node skills/rye-tabular-intake/scripts/tabular_commit_rye.mts \
  --db-url "$DATABASE_URL" \
  --input /tmp/parent-records.ndjson \
  --run-id example-domain:parents:2026-04-29
```

If the consuming environment only exposes SQL execution, emit a SQL script and run that script through the available SQL tool:

```bash
node skills/rye-tabular-intake/scripts/tabular_commit_rye.mts \
  --emit-sql \
  --input /tmp/parent-records.ndjson \
  --run-id example-domain:parents:2026-04-29 \
  > /tmp/parent-records-commit.sql
```

The emitted SQL must be executed as one multi-statement call/session because it uses a temporary context table inside a transaction. The source files referenced by the NDJSON must be readable when the SQL is generated so the base skill can compute duplicate-detection hashes.

## Row Mapping Example

Use `tabular_map.mts` when one source row becomes one child record.

```ts
export const mapping = {
  name: "source_rows_to_child_records"
};

export function transform(input) {
  if (input.kind !== "source_row") {
    return null;
  }

  const row = input.row;
  const childId = String(row["Child ID"] ?? "").trim();
  const parentId = String(row["Parent ID"] ?? "").trim();

  if (!childId || !parentId) {
    return {
      destination_table: "child_records",
      operation: "upsert",
      record: {
        external_id: childId || `missing-child-id-row-${input.source.row_number}`,
        parent_external_id: parentId || null
      },
      issues: ["Missing Child ID or Parent ID"]
    };
  }

  return {
    destination_table: "child_records",
    operation: "upsert",
    record: {
      external_id: childId,
      parent_external_id: parentId,
      status: String(row.Status ?? "").trim() || "unknown",
      quantity: Number(row.Quantity ?? 0),
      estimated_value: Number(row["Estimated Value"] ?? 0)
    }
  };
}
```

The output `mapped_record` will have a one-row `source_set`.

## Grouped Parent Example

Use `tabular_group.mts` when many source rows produce one parent record. This example groups child rows by `Parent ID`, counts the children, sums numeric values, and preserves every contributing source row in `source_set`.

```ts
function value(input, field) {
  return input.kind === "source_row" ? input.row[field] : input.record[field];
}

function numberValue(input, field) {
  const parsed = Number.parseFloat(String(value(input, field) ?? ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

export const mapping = {
  name: "source_rows_to_parent_records"
};

export function groupKey(input) {
  return String(value(input, "Parent ID") ?? "").trim();
}

export function reduce(group) {
  const first = group.records[0];
  let estimatedValue = 0;

  for (const record of group.records) {
    estimatedValue += numberValue(record, "Estimated Value");
  }

  return {
    destination_table: "parent_records",
    operation: "upsert",
    record: {
      external_id: group.key,
      name: String(value(first, "Parent Name") ?? group.key).trim(),
      child_count: group.records.length,
      total_estimated_value: Number(estimatedValue.toFixed(2)),
      regions: group.distinct("Region")
    },
    meta: {
      grouping_column: "Parent ID"
    }
  };
}
```

The output `mapped_record.source_set` will have:

- `group_key`: the parent ID
- `sources`: every source row in the group
- `row_count`: the number of source rows used for the parent record

For an acquisition workflow, a domain skill can use this same shape with `Parent ID` mapped to buyer, package, tract group, or another stable opportunity key.

## Extension Checklist

When adding a consuming skill:

1. Inspect the source file with `tabular_inspect.mts`.
2. Decide whether each destination is row-level, one-to-many, or grouped many-to-one.
3. Write row mappings with `tabular_map.mts`.
4. Write parent/group mappings with `tabular_group.mts`.
5. Keep raw extraction lossless; do not normalize before `source_row` exists.
6. Preserve rejected or questionable rows with `issues` when possible.
7. Add a fixture that proves row counts, grouped parent counts, and representative aggregates.
8. Commit extracted, mapped, grouped, or staged NDJSON to Rye when the import needs an audit trail.
9. If the target only supports SQL execution, use `tabular_commit_rye.mts --emit-sql` and document that the SQL must run as one script.

## What Not To Put In The Base Skill

- domain-specific table names except fixtures
- source-column aliases for one customer or source system
- business-specific validation thresholds
- final domain-table loading rules
- graph conventions that belong in a domain layer

Those belong in the consuming skill or in project domain docs.
