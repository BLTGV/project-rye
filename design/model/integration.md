# Rye — Integration

## Connecting Domain Tables to the Graph

---

## 1. The Overlay Principle

Rye sits alongside your existing tables. Domain tables are the system of record — Rye adds connectivity, temporal facts, and event history without modifying them.

```
┌─────────────────┐         ┌──────────────────┐         ┌─────────────────┐
│   Graph Layer   │────────>│  node_source_map  │────────>│  Domain Tables  │
│  (nodes, edges, │         │  (node_id,        │         │  (customers,    │
│   events, etc.) │         │   source_schema,  │         │   tickets,      │
│                 │         │   source_table,   │         │   invoices)     │
│                 │         │   source_id)      │         │                 │
└─────────────────┘         └──────────────────┘         └─────────────────┘
```

- The graph points to domain tables. Domain tables never point to the graph.
- If the graph schema is dropped, all operational systems continue functioning.
- Domain tables are **encouraged**. If a use case is well-defined, keep it in a domain table. Use Rye to connect it to everything else.

---

## 2. Linking Records

Use `link_record()` to connect a domain table row to the graph. It creates a node and maps it back to the source via `node_source_map`. Each distinct `source_id` creates a new node; calling again with the same identity updates the existing node:

```sql
SELECT link_record(
    p_source_schema := 'billing',
    p_source_table  := 'customers',
    p_source_id     := 'cus_abc123',
    p_node_type     := 'org',
    p_label         := 'Acme Corp',
    p_properties    := '{"plan": "growth", "mrr": 299}',
    p_source_id_type := 'text'
);
```

Calling it again with updated properties merges them into the existing node.

### Bulk import

```sql
-- Link all customers at once
SELECT link_record(
    'billing', 'customers', id::text, 'org',
    name, jsonb_build_object('plan', plan, 'mrr', mrr)
)
FROM billing.customers;
```

---

## 3. Joining Back to Domain Tables

The graph node has the `external_id` and `node_source_map` entry. Join back to your domain table when you need the full record:

```sql
-- From graph node to billing customer
SELECT n.id AS node_id, n.label, c.*
FROM nodes n
JOIN node_source_map nsm ON nsm.node_id = n.id
    AND nsm.source_schema = 'billing'
    AND nsm.source_table = 'customers'
JOIN billing.customers c ON c.id = nsm.source_id::int
WHERE n.node_type = 'org';

-- From graph node to support ticket
SELECT n.id AS node_id, n.label, t.*
FROM nodes n
JOIN node_source_map nsm ON nsm.node_id = n.id
    AND nsm.source_schema = 'support'
    AND nsm.source_table = 'tickets'
JOIN support.tickets t ON t.id = nsm.source_id::int
WHERE n.node_type = 'ticket';
```

---

## 4. Change Data Capture (CDC)

A built-in trigger function captures INSERT, UPDATE, and DELETE on domain tables as `domain_change` events in the graph. Includes full before/after state and a diff of changed fields.

### Attaching CDC

```sql
-- Track all changes on the customers table
SELECT track_table('billing', 'customers');

-- Track changes on the tickets table
SELECT track_table('support', 'tickets');
```

`track_table()` creates an AFTER trigger that fires on every row change. Only rows that have a linked node (via `node_source_map`) produce events — unlinked rows are silently skipped.

### Selective CDC

For tables with high write volume, use a WHEN clause to ignore operational columns:

```sql
CREATE TRIGGER rye_cdc_contacts_selective
    AFTER UPDATE ON crm.contacts
    FOR EACH ROW
    WHEN (
        OLD.name IS DISTINCT FROM NEW.name
        OR OLD.email IS DISTINCT FROM NEW.email
        OR OLD.status IS DISTINCT FROM NEW.status
    )
    EXECUTE FUNCTION capture_domain_change();
```

### Querying change history

```sql
SELECT
    e.occurred_at,
    e.properties->>'schema' AS source_schema,
    e.properties->>'table' AS source_table,
    e.properties->>'operation' AS operation,
    e.properties->'changed_fields' AS what_changed
FROM events e
JOIN event_participants ep ON ep.event_id = e.id
WHERE ep.node_id = '<node_uuid>'
  AND e.event_type = 'domain_change'
ORDER BY e.occurred_at;
```

**Recommendation:** Start with explicit `link_record()` calls for correctness. Add CDC triggers when you've validated the graph model against your domain.

---

## 5. Introspection

Use `rye_catalog()` to see what's connected:

```sql
SELECT rye_catalog();
```

Returns:
- `node_types` — counts by type
- `edge_types` — counts by type
- `assertion_types` — counts by type (current only)
- `event_types` — counts by type
- `tracked_tables` — which domain tables are linked and how many nodes each has
- `totals` — overall counts

---

## 6. Materialized Views for Frequent Access

When a particular node type is queried heavily against domain columns, create a materialized view that flattens JSONB into typed columns:

```sql
CREATE MATERIALIZED VIEW customers_flat AS
SELECT
    n.id AS node_id,
    n.properties->>'name' AS name,
    n.properties->>'email' AS email,
    n.properties->>'plan' AS plan,
    (n.properties->>'mrr')::numeric AS mrr,
    n.label,
    n.created_at
FROM nodes n
WHERE n.node_type = 'customer' AND n.archived_at IS NULL;

CREATE UNIQUE INDEX idx_cf_node ON customers_flat (node_id);
CREATE INDEX idx_cf_plan ON customers_flat (plan);

-- Concurrent refresh allows reads during rebuild
REFRESH MATERIALIZED VIEW CONCURRENTLY customers_flat;
```

**Guidance:** Start with regular views. Promote to materialized views only after measuring real query pressure. See [Scaling](../scale.md) for refresh strategies.
