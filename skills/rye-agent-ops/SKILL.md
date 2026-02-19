---
name: rye-agent-ops
description: Operate Rye data safely for LLM agents. Use when implementing or executing agent read/write flows, connecting domain tables, selecting assertion keys, enforcing provenance, and applying agent-safe SQL patterns for context retrieval and auditable writes.
---

# Rye Agent Ops

## Orient

1. Run `SELECT rye_catalog()` to see what's in the instance — node types, edge types, assertion types, tracked tables, and totals.
2. Use `agent_node_summary(node_id, max_items)` for compact context on a specific node.

## Connect Domain Tables

1. Use `link_record(schema, table, id, node_type, label, properties)` to connect a domain table row to the graph. Idempotent.
2. Use `track_table(schema, table)` to attach CDC triggers that capture INSERT/UPDATE/DELETE as graph events.

## Write Events

Use `record_event(...)` for all event creation:
```sql
SELECT record_event(
    p_event_type := 'meeting',
    p_summary := 'Weekly sync',
    p_participant_ids := ARRAY[node1, node2]::uuid[],
    p_participant_roles := ARRAY['organizer', 'attendee']
);
```
Do not insert into `events` and `event_participants` separately.

## Write Assertions

- Insert assertions directly (subject to RLS).
- For single-valued facts: `assertion_key = 'default'`, supersede with `supersede_assertion(...)`.
- For multi-valued facts: use stable domain keys in `assertion_key`.
- Do not run direct `UPDATE assertions`.

## Provenance

- Log agent queries with `log_agent_query(agent_id, query, summary, node_ids)`.
- Attach `source_event_id` to assertions when the fact came from an event.

## Safety

- Keep reads scoped and ranked.
- Avoid dumping full history to the model by default.
- Gate high-risk actions behind explicit user confirmation.
