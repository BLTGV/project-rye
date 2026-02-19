# Rye Agent SQL Patterns

## Record an event

Always use `record_event()` to create events with participants:

```sql
SELECT record_event(
    p_event_type        := 'meeting',
    p_summary           := 'Quarterly review with Acme',
    p_properties        := '{"location": "zoom"}',
    p_participant_ids   := ARRAY['<node_uuid_1>', '<node_uuid_2>']::uuid[],
    p_participant_roles := ARRAY['organizer', 'attendee']
);
```

Do NOT insert into `events` and `event_participants` separately. The function handles UUID generation and participant linking atomically, avoiding an RLS interaction where `INSERT ... RETURNING id` on events fails.

## Compact retrieval

```sql
SELECT agent_node_summary('<node_uuid>', 15);
```

## Supersede singleton fact

```sql
SELECT supersede_assertion(
  p_old_assertion_id := '<old_assertion_uuid>',
  p_new_assertion_type := 'task_status',
  p_new_subject_node_id := '<task_uuid>',
  p_new_subject_edge_id := NULL,
  p_new_claim := '{"status": "in_progress"}',
  p_new_assertion_key := 'default',
  p_new_source_event_id := '<event_uuid>',
  p_new_confidence := 0.9
);
```

Direct `UPDATE assertions ...` is intentionally blocked by policy.

## Multi-valued fact keying

```sql
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
VALUES (
  'ownership',
  'owner:<owner_uuid>',
  '<parcel_uuid>',
  '{"owner_node_id": "<owner_uuid>", "fraction": "1/16"}',
  0.95
);
```

## See what's in the instance

```sql
SELECT rye_catalog();
```

Returns node types, edge types, assertion types, tracked tables, and totals.

## Link a domain table record to the graph

```sql
SELECT link_record(
    p_source_schema := 'public',
    p_source_table  := 'customers',
    p_source_id     := '42',
    p_node_type     := 'org',
    p_label         := 'Acme Corp',
    p_properties    := '{"plan": "growth", "mrr": 299}'
);
```

Each distinct `source_id` creates a new node. Calling again with the same `(schema, table, source_id)` updates the existing node's properties.

## Track changes on a domain table

```sql
SELECT track_table('public', 'customers');
```

Attaches a CDC trigger. Changes to linked rows produce `domain_change` events.

## Audit log for agent interaction

```sql
SELECT log_agent_query('triage-bot', 'What changed on Acme?', 'Returned customer summary', ARRAY['<node_uuid>'::uuid]);
```

## Create a node with proper classification

Team-scoped nodes must have a classification:

```sql
INSERT INTO nodes (node_type, label, attrs)
VALUES ('task', 'Build feature X',
    '{"classification": "internal", "teams": ["engineering"]}'
);
```

Public nodes (visible to all) omit both teams and classification:

```sql
INSERT INTO nodes (node_type, label, properties)
VALUES ('pipeline', 'Enterprise Pipeline', '{"code": "ENT"}');
```
