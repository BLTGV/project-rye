# Rye Agent Operations Guide

## Schema Setup

All Rye objects live in the `rye` schema. Set the search path at the start of each session or transaction:

```sql
SET search_path = rye, public, pg_catalog;
```

All Rye functions include `SET search_path` in their definitions, so calling `rye.record_event(...)` works regardless of session state. But for queries against tables and views (`SELECT * FROM nodes`), the search path must include `rye`.

## Safe Read Path

- Use `agent_node_summary(node_id, max_items)` for compact context retrieval
- Keep `max_items` conservative (10-20) for context-window efficiency
- Use `current_assertions` view for non-superseded facts (never query `assertions` directly for current state)

## Safe Write Path

### Tabular intake workflow

For CSV and XLSX imports that need inspection, conversational mapping, Rye staging, and duplicate-run protection, use the tabular intake skill:

- `skills/rye-tabular-intake/SKILL.md`

That skill provides:

- file inspection before mapping
- row-level NDJSON extraction
- conversational or declarative column mapping
- Rye staging envelopes for import tracking
- commit-time writes into `nodes`, `events`, `assertions`, and `artifacts`
- SHA1-based duplicate-run detection for repeated source content

Use it when source data starts outside PostgreSQL and needs to be normalized into Rye-tracked intake runs before final domain-table load.

### Recording events

Use `record_event()` for all event creation. It handles UUID generation and participant linking in a single call:

```sql
SELECT record_event(
    p_event_type     := 'meeting',
    p_summary        := 'Quarterly review with Acme',
    p_properties     := '{"location": "zoom"}',
    p_participant_ids   := ARRAY['<node_uuid_1>', '<node_uuid_2>']::uuid[],
    p_participant_roles := ARRAY['organizer', 'attendee']
);
```

**Do not** insert events and event_participants separately. The `record_event()` function exists to prevent a known RLS interaction where `INSERT ... RETURNING id` on the events table fails because the event_read_policy requires participants to exist before the event is visible.

### Updating node properties

When a node IS the system of record (no backing domain table), use `update_node_properties()` to update its properties. This is the only way agents can update nodes — direct `UPDATE nodes` is blocked by RLS.

```sql
SELECT update_node_properties(
    p_node_id    := '<node_uuid>',
    p_properties := '{"email": "jane@newdomain.com", "title": "VP Engineering"}',
    p_label      := 'Jane Smith',  -- optional, only changes if provided
    p_summary    := 'Updated contact info from sales call'
);
```

- Properties are merged (`||`) — new keys overlay old, existing keys preserved.
- Returns the UUID of a `node_properties_updated` audit event with before/after diff.
- Archived nodes raise an exception.

For nodes backed by a domain table, update the domain table instead (CDC will propagate the change).

### Writing assertions

- Insert assertions directly (subject to RLS and assertion-type gating):

```sql
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
VALUES ('sentiment', 'default', '<node_uuid>', '{"score": 0.8}', 0.9);
```

- For single-valued facts, supersede existing active assertions with `supersede_assertion(...)`:

```sql
SELECT supersede_assertion(
    p_old_assertion_id    := '<old_assertion_uuid>',
    p_new_assertion_type  := 'task_status',
    p_new_subject_node_id := '<task_uuid>',
    p_new_subject_edge_id := NULL,
    p_new_claim           := '{"status": "in_progress"}',
    p_new_assertion_key   := 'default',
    p_new_source_event_id := '<event_uuid>',
    p_new_confidence      := 0.9
);
```

- Use `assertion_key = 'default'` for singleton facts
- Do not run direct `UPDATE assertions`; RLS allows supersession updates only through scoped function context

### Assertion-type restrictions

Some assertion types are write-gated by role:

| assertion_type | Roles that can INSERT |
|---|---|
| `financial_terms` | `deal_manager`, `admin` |
| `compensation` | `hr_admin`, `admin` |
| All others | Any role |

Attempting to insert a gated type with the wrong role raises an RLS violation.

## Auditability

- Log agent queries using `log_agent_query(...)`:

```sql
SELECT log_agent_query(
    'triage-bot',
    'What changed on Acme?',
    'Returned customer summary',
    ARRAY['<node_uuid>'::uuid]
);
```

- Link all writes to related nodes via `event_participants`

## Node Classification

When creating nodes with team scoping, always set `classification` in `attrs`:

```sql
INSERT INTO nodes (node_type, label, attrs)
VALUES ('task', 'Build feature X',
    '{"classification": "internal", "teams": ["engineering"]}'
);
```

Nodes with `teams` but no `classification` will be rejected. Nodes without teams or classification are visible to all users (public).

## Role Expectations

Session variables must be set per transaction:

```sql
SET LOCAL "app.current_user_id" = 'user:alice';
SET LOCAL "app.current_teams"   = 'engineering,sales';
SET LOCAL "app.current_role"    = 'team_member';
```

Internal write-path flags (`app.write_path`, `app.supersede_assertion_id`) are set by database functions (`supersede_assertion()`, `update_node_properties()`), not client SQL.

## Views

All views use `security_invoker = true` (PostgreSQL 15+), which means RLS policies are evaluated using the calling session's permissions, not the view owner's. This is required for security — without it, views would bypass RLS when owned by a superuser.

| View | Purpose |
|---|---|
| `current_assertions` | Non-superseded assertions only |
| `node_context` | Full node context with edges and assertions |
| `nodes_secure` | Nodes with field-level redaction applied |
