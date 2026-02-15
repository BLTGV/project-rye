# Rye — Integration

## Domain Table Overlay and Change Tracking

---

## 1. Directionality Principle

The graph points to domain tables. Domain tables do not point to the graph.

- Domain tables are the **system of record** — used by operational applications (CRM, billing, support tools). They are not modified to accommodate the graph.
- The graph is a **read-overlay and relationship index**. It adds intelligence and connectivity without coupling operational systems to it.
- If the graph schema is dropped, all operational systems continue functioning.

```
┌─────────────────┐         ┌──────────────────┐         ┌─────────────────┐
│   Graph Layer   │────────>│  node_source_map  │────────>│  Domain Tables  │
│  (nodes, edges, │         │  (node_id,        │         │  (customers,    │
│   events, etc.) │         │   source_schema,  │         │   tickets,      │
│                 │         │   source_table,   │         │   invoices)     │
│                 │         │   source_id)      │         │                 │
└─────────────────┘         └──────────────────┘         └─────────────────┘
```

---

## 2. Joining Back to Domain Tables

```sql
-- From graph node to Stripe customer
SELECT n.id AS node_id, n.label, c.*
FROM nodes n
JOIN node_source_map nsm ON nsm.node_id = n.id
    AND nsm.source_schema = 'billing'
    AND nsm.source_table = 'customers'
JOIN billing.customers c ON c.id = nsm.source_id::int
WHERE n.node_type = 'customer';

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

## 3. Change Data Capture (CDC)

A generic trigger function that captures INSERT, UPDATE, and DELETE operations on domain tables as events in the graph. Includes the full before/after state and a diff of changed fields.

**Recommendation:** Start with explicit application writes for correctness. Add CDC triggers as a phase-2 automation when you've validated the graph model against your domain.

```sql
CREATE FUNCTION capture_domain_change() RETURNS trigger AS $$
DECLARE
    v_node_id uuid;
    v_event_id uuid;
    v_change_type text;
    v_old_data jsonb;
    v_new_data jsonb;
    v_record_id text;
BEGIN
    v_record_id := CASE TG_OP WHEN 'DELETE' THEN OLD.id::text ELSE NEW.id::text END;

    -- Find the graph node for this domain record
    SELECT node_id INTO v_node_id
    FROM node_source_map
    WHERE source_schema = TG_TABLE_SCHEMA
      AND source_table = TG_TABLE_NAME
      AND source_id = v_record_id;

    -- No graph node mapped; skip silently
    IF v_node_id IS NULL THEN RETURN COALESCE(NEW, OLD); END IF;

    v_change_type := lower(TG_OP);
    v_old_data := CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END;
    v_new_data := CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END;

    INSERT INTO events (event_type, occurred_at, summary, properties, actor_system)
    VALUES (
        'domain_change', now(),
        format('%s.%s %s (record %s)', TG_TABLE_SCHEMA, TG_TABLE_NAME, v_change_type, v_record_id),
        jsonb_build_object(
            'schema', TG_TABLE_SCHEMA,
            'table', TG_TABLE_NAME,
            'operation', v_change_type,
            'record_id', v_record_id,
            'old', v_old_data,
            'new', v_new_data,
            'changed_fields', CASE
                WHEN TG_OP = 'UPDATE' THEN (
                    SELECT jsonb_object_agg(key, jsonb_build_object('old', v_old_data->key, 'new', value))
                    FROM jsonb_each(v_new_data)
                    WHERE v_old_data->key IS DISTINCT FROM v_new_data->key
                )
                ELSE NULL
            END
        ),
        'system:cdc_trigger'
    )
    RETURNING id INTO v_event_id;

    INSERT INTO event_participants (event_id, node_id, role)
    VALUES (v_event_id, v_node_id, 'subject');

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;
```

### Attaching triggers

```sql
-- Only fire when meaningful columns change
CREATE TRIGGER cdc_customers
    AFTER INSERT OR UPDATE OR DELETE ON billing.customers
    FOR EACH ROW EXECUTE FUNCTION capture_domain_change();

-- Selective CDC: ignore purely operational columns
CREATE TRIGGER cdc_contacts_selective
    AFTER UPDATE ON crm.contacts
    FOR EACH ROW
    WHEN (
        OLD.name IS DISTINCT FROM NEW.name
        OR OLD.email IS DISTINCT FROM NEW.email
        OR OLD.phone IS DISTINCT FROM NEW.phone
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

---

## 4. Materialized Views for Frequent Access

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
