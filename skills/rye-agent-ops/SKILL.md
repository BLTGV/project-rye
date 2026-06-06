---
name: rye-agent-ops
description: Operate Rye data safely for LLM agents. Use when implementing or executing agent read/write flows, connecting domain tables, selecting assertion keys, enforcing provenance, and applying agent-safe SQL patterns for context retrieval and auditable writes.
---

# Rye Agent Ops

## Session Setup (Required)

Before any query, set the session context. On stateless connections (Supabase MCP, serverless, transaction-mode poolers), this must be done in **every call**:

```sql
SELECT set_config('app.current_role', 'admin', false);
SELECT set_config('app.current_user_id', 'user-123', false);
SELECT set_config('app.current_teams', 'engineering', false);
```

Without this, RLS will block access. Use `set_config()` (not `SET` syntax) for portability.

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

## Knowledge Candidates and Promotion

Use the candidate workflow when source material has plausible facts, tasks,
decisions, risks, procedures, preferences, or semantic edges but the knowledge
has not been accepted yet.

1. Create proposed candidates with `create_knowledge_candidate(...)`.
2. Link candidates to source evidence with `supported_by` and to import/run
   context with `derived_from` using the helper function parameters.
3. Keep candidate status as `proposed` or `needs_review` until a user or trusted
   reviewer accepts, rejects, marks duplicate, or asks for promotion.
4. Promote accepted candidates only through:
   - `promote_candidate_to_assertion(...)`
   - `promote_candidate_to_task(...)`
   - `promote_candidate_to_edge(...)`
5. Store candidate provenance in promoted assertion/edge/task attrs. The helper
   functions already preserve candidate and source refs.
6. If source accounts or containers are still `needs_confirmation`, do not rely
   on their default context to promote knowledge. Use only item-level evidence
   and explicit reviewer decisions.

Candidate statuses are:

- `proposed`
- `accepted`
- `rejected`
- `needs_review`
- `duplicate`
- `superseded`

Do not bulk-promote a candidate queue just because a parser generated it. A bulk
promotion must have an explicit approval decision, target shape, and provenance
policy.

## Provenance

- Log agent queries with `log_agent_query(agent_id, query, summary, node_ids)`.
- Attach `source_event_id` to assertions when the fact came from an event.

## Safety

- Keep reads scoped and ranked.
- Avoid dumping full history to the model by default.
- Gate high-risk actions behind explicit user confirmation.
