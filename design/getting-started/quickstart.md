# Quickstart

## Connect Your Data in 5 Minutes

Rye sits alongside your existing tables. It doesn't replace them — it connects them. Your domain tables stay exactly as they are. Rye adds a graph layer that lets you track relationships, record events, and assert facts across all of them.

**Prerequisite:** Complete the [Installation](/docs/getting-started/installation/) steps first — Rye should be installed, the search path set, and session variables configured.

---

## 1. Set Up Your Session

```sql
SET search_path = rye, public, pg_catalog;
SET LOCAL "app.current_user_id" = 'quickstart-user';
SET LOCAL "app.current_teams" = 'default';
SET LOCAL "app.current_role" = 'operator';
```

---

## 2. Link Your Existing Records

Say you have a `customers` table and a `tickets` table that already work. Link them to the graph:

```sql
-- Link a customer record to the graph
SELECT link_record(
    p_source_schema := 'public',
    p_source_table  := 'customers',
    p_source_id     := '42',
    p_node_type     := 'org',
    p_label         := 'Acme Corp',
    p_properties    := '{"plan": "growth", "mrr": 299}'
);

-- Link a support ticket
SELECT link_record(
    p_source_schema := 'public',
    p_source_table  := 'tickets',
    p_source_id     := '1087',
    p_node_type     := 'ticket',
    p_label         := 'Cannot export CSV reports',
    p_properties    := '{"priority": "high", "channel": "chat"}'
);
```

`link_record()` creates a graph node and maps it back to the source table via `node_source_map`. Each distinct `source_id` creates a new node. Calling it again with the same `(schema, table, source_id)` updates the existing node's properties instead of creating a duplicate.

---

## 3. Connect Them With Edges

Now draw the relationship that neither table knows about:

```sql
-- The ticket is about the customer
INSERT INTO edges (edge_type, source_id, target_id, properties)
SELECT 'regarding', ticket.id, customer.id, '{"context": "billing issue"}'
FROM nodes ticket, nodes customer
WHERE ticket.external_id = '1087' AND ticket.external_source = 'public.tickets'
  AND customer.external_id = '42' AND customer.external_source = 'public.customers';
```

---

## 4. Assert a Fact

Add a belief about the customer. This doesn't change the `customers` table — it lives in the graph:

```sql
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
SELECT 'churn_risk', 'default', id,
    '{"level": "high", "signals": ["3 open tickets", "no login 14d"]}',
    0.75
FROM nodes
WHERE external_id = '42' AND external_source = 'public.customers';
```

---

## 5. Record an Event

```sql
SELECT record_event(
    p_event_type     := 'escalation',
    p_summary        := 'Ticket #1087 escalated to engineering',
    p_properties     := '{"reason": "requires code fix"}',
    p_participant_ids := ARRAY[
        (SELECT id FROM nodes WHERE external_id = '1087' AND external_source = 'public.tickets'),
        (SELECT id FROM nodes WHERE external_id = '42' AND external_source = 'public.customers')
    ]::uuid[],
    p_participant_roles := ARRAY['subject', 'regarding']
);
```

---

## 6. Track Changes Automatically

Want the graph to know when a customer or ticket changes in the source table? Attach a CDC trigger:

```sql
SELECT track_table('public', 'customers');
SELECT track_table('public', 'tickets');
```

Now any INSERT, UPDATE, or DELETE on those tables automatically records a `domain_change` event in the graph — with the full before/after diff — for every row that has a linked node.

---

## 7. Query Across Everything

```sql
-- What do we know about Acme?
SELECT * FROM node_context
WHERE label = 'Acme Corp';

-- What's the current churn risk?
SELECT claim, confidence
FROM current_assertions
WHERE subject_node_id = (SELECT id FROM nodes WHERE external_id = '42' AND external_source = 'public.customers')
  AND assertion_type = 'churn_risk';

-- What changed on the customers table in the last week?
SELECT e.occurred_at, e.summary, e.properties->'changed_fields'
FROM events e
JOIN event_participants ep ON ep.event_id = e.id
WHERE ep.node_id = (SELECT id FROM nodes WHERE external_id = '42' AND external_source = 'public.customers')
  AND e.event_type = 'domain_change'
ORDER BY e.occurred_at DESC;

-- Join back to the source table when you need the full record
SELECT n.label, c.*
FROM nodes n
JOIN node_source_map nsm ON nsm.node_id = n.id
    AND nsm.source_table = 'customers'
JOIN customers c ON c.id = nsm.source_id::int
WHERE n.node_type = 'org';
```

---

## 8. See What's Connected

```sql
SELECT rye_catalog();
```

Returns a summary of everything in the instance — node types, edge types, assertion types, event types, tracked tables, and totals.

---

## 9. Supersede a Fact

A month later, the churn risk drops:

```sql
SELECT supersede_assertion(
    p_old_assertion_id := (
        SELECT id FROM current_assertions
        WHERE subject_node_id = (SELECT id FROM nodes WHERE external_id = '42' AND external_source = 'public.customers')
          AND assertion_type = 'churn_risk'
    ),
    p_new_assertion_type := 'churn_risk',
    p_new_subject_node_id := (SELECT id FROM nodes WHERE external_id = '42' AND external_source = 'public.customers'),
    p_new_subject_edge_id := NULL,
    p_new_claim := '{"level": "low", "signals": ["renewed contract", "active usage"]}',
    p_new_confidence := 0.9
);
```

Both the old and new belief are preserved. `current_assertions` shows only the latest.

---

## What You Didn't Have To Do

- Change your `customers` or `tickets` tables
- Add foreign keys from domain tables to the graph
- Replace any existing system
- Write an ETL pipeline

Your domain tables are the system of record. Rye connects them. If you drop the Rye schema, your application keeps working.

---

## Next Steps

- [Integration Guide](/docs/model/integration/) — deep dive on domain table overlay, CDC, and materialized views
- [Core Contract](/docs/model/core-contract-and-conformance/) — what Rye guarantees
- [Agent Operations](/docs/reference/agent-ops-guide/) — safe read/write patterns for LLM agents
- [SaaS Customer Operations](/docs/cookbooks/saas-customer-operations/) — full worked example with Stripe, Intercom, and Linear
