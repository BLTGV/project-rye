# Rye Agent SQL Patterns

## Session setup

Every query that touches RLS-protected tables must first set the session context. On standard PostgreSQL connections this persists for the session. On **stateless connections** (Supabase MCP, serverless functions, connection poolers in transaction mode), set the context in **every call**:

```sql
SELECT set_config('app.current_role', 'admin', false);
SELECT set_config('app.current_user_id', 'user-123', false);
SELECT set_config('app.current_teams', 'engineering,product', false);
```

Without these, RLS will block access to all team-scoped and classified data.

Note: `SET app.current_role = 'admin'` works in `psql` but not through all APIs (e.g., Supabase MCP rejects the syntax). Always prefer `set_config()` for portability.

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

## Record or replace a singleton fact

Use `record_assertion(...)` for accepted singleton facts. It owns the lifecycle
rules for current, historical, candidate, and future-effective assertions.

```sql
SELECT record_assertion(
  p_assertion_type  := 'task_status',
  p_assertion_key   := 'default',
  p_subject_node_id := '<task_uuid>'::uuid,
  p_claim           := '{"status": "in_progress"}',
  p_confidence      := 0.9,
  p_status          := 'accepted',
  p_basis           := 'reported',
  p_evidence        := ARRAY[
    jsonb_build_object('kind', 'source', 'event_id', '<event_uuid>'::uuid)
  ]
);
```

If an already scheduled future assertion exists for the same subject/type/key,
`record_assertion(...)` closes the new current assertion at that future
effective date. That prevents an agent from accidentally overwriting a planned
cutover.

Use `supersede_assertion(...)` only when you are deliberately replacing a known
assertion by id and do not need the future-scheduling behavior.

Direct `UPDATE assertions ...` is intentionally blocked by policy.

### Uncertain or range-only values

Never fabricate a scalar the source did not state. If a human gave only a
range or approximation ("84 or maybe 86 grand"), leave the scalar field
(`amount_usd`, `quantity`, etc.) null — do not store a midpoint or best
guess a downstream consumer would read as fact. Record the range and the
uncertainty explicitly, lower the confidence, and name who can confirm:

```json
{
  "amount_usd": null,
  "range_usd": [84000, 86000],
  "exact": false,
  "note": "Owner recalled 84k or 86k; office manager has the exact figure"
}
```

Pair it with a confirmation task assigned to the named confirmer.

## Domain-scoped agent candidates

For external agents, prefer the secure API or secure MCP server. If you are
inside trusted SQL tooling, the equivalent helper is `agent_create_candidate`.
It centralizes capability checks, idempotency, metadata shape, and audit rows:

```sql
SELECT rye.agent_create_candidate(
  p_agent_id          := '<agent_uuid>'::uuid,
  p_candidate_kind    := 'decision',
  p_statement         := 'Review the Acme account health after the renewal call.',
  p_target_payload    := '{}'::jsonb,
  p_domain_keys       := ARRAY['account-updates'],
  p_source_scope      := 'slack:#sales',
  p_impact_scope      := 'account:acme',
  p_authority_basis   := 'account owner confirmed in channel',
  p_speech_act        := 'confirmed',
  p_current_or_future := 'current',
  p_evidence_refs     := '[{"source":"slack","channel":"#sales","ts":"..."}]'::jsonb,
  p_confidence        := 0.82,
  p_idempotency_key   := 'source-message-id:candidate-key'
);
```

If the agent lacks `rye.candidate.create` for every requested domain and scope,
the function raises `insufficient_privilege` and writes a denied audit row.
That is deliberate: the database is the last enforcement boundary for API, MCP,
CLI, UI, and plugin callers.

Use `agent_get_context_pack(...)` rather than broad graph reads when an agent is
working inside a channel or app context. It returns only domains the agent can
read and only subscribed channel context. Channel-local domains should not leak
to another channel unless that channel is explicitly subscribed to the shared
domain.

## Schedule future accepted knowledge

Generic future-effective assertion:

```sql
SELECT schedule_assertion_change(
  p_subject_node_id := '<scope_uuid>'::uuid,
  p_subject_edge_id := NULL,
  p_assertion_type  := 'source_of_truth_policy',
  p_assertion_key   := 'status_domain:battery_dispatch_control_state',
  p_claim           := '{"status_domain":"battery_dispatch_control_state","authoritative_source":"BatteryEMS-v2"}',
  p_effective_at    := '2026-10-15T00:00:00Z'::timestamptz,
  p_confidence      := 1.0,
  p_basis           := 'reported'
);
```

Before `2026-10-15`, current reads still show the old assertion:

```sql
SELECT assertion_type, assertion_key, claim, effective_at, effective_to
FROM rye.current_valid_assertions
WHERE subject_node_id = '<scope_uuid>'::uuid;
```

After the cutover date in an as-of read, Rye returns the scheduled future row:

```sql
SELECT assertion_type, assertion_key, claim, effective_at, effective_to
FROM rye.assertions_as_of('2026-10-16T00:00:00Z'::timestamptz)
WHERE subject_node_id = '<scope_uuid>'::uuid;
```

## Schedule future truth

```sql
SELECT schedule_assertion_change(
  p_subject_node_id := '<task_uuid>'::uuid,
  p_subject_edge_id := NULL,
  p_assertion_type  := 'task_status',
  p_assertion_key   := 'default',
  p_claim           := '{"status":"ready_for_review"}',
  p_effective_at    := '2026-07-15T00:00:00Z'::timestamptz,
  p_reason          := 'Review window opens',
  p_actor           := 'agent:pm-planner',
  p_basis           := 'reported'
);
```

Do not infer that the future state is true today.

## Multi-valued fact keying

```sql
SELECT record_assertion(
  p_assertion_type := 'ownership',
  p_assertion_key := 'owner:<owner_uuid>',
  p_subject_node_id := '<parcel_uuid>'::uuid,
  p_claim := '{"owner_node_id":"<owner_uuid>","fraction":"1/16"}',
  p_confidence := 0.95,
  p_basis := 'assumed'
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

## Update node properties

When the node is the system of record (no backing domain table), use `update_node_properties()`:

```sql
SELECT update_node_properties(
    p_node_id    := '<node_uuid>',
    p_properties := '{"email": "jane@new.com", "title": "VP Engineering"}',
    p_label      := 'Jane Smith',  -- optional
    p_summary    := 'Updated contact info from sales call'
);
```

Properties are merged — new keys overlay old, existing keys are preserved. Returns the UUID of a `node_properties_updated` audit event.

Direct `UPDATE nodes ...` is intentionally blocked by policy for agents. For nodes backed by a domain table, update the domain table instead (CDC propagates the change).

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
