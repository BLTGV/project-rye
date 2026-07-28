---
name: rye-knowledge-reader
description: "Read Rye safely without writing. Use when an agent needs to understand what Rye currently knows, what was true as of a time, what tasks are open or done, what candidates still need review, or how accepted knowledge traces back to source evidence. This skill is read-only: SELECT queries only, no events, assertions, candidate status changes, promotions, inserts, updates, deletes, or audit writes."
---

# Rye Knowledge Reader

Use this skill when the task is to answer from Rye, summarize status, inspect
knowledge, build context, or explain provenance without changing the database.

## Hard Boundary

Read-only means no durable writes.

Do not call:

- `record_event`, `record_assertion`, `supersede_assertion`,
  `accept_assertion`, `reject_candidate`, `record_distillation`,
  `schedule_assertion_change`, `mark_assertion_superseded`
- `create_knowledge_candidate`, `set_candidate_status`,
  `promote_candidate_to_task`,
  `promote_candidate_to_edge`
- `link_record`, `track_table`, `update_node_properties`
- `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `ALTER`, `CREATE`, `DROP`
- `log_agent_query`; logging is a write

If the user asks for a change, stop using this skill and switch to the
appropriate write/promotion workflow after explicit approval.

## Session Setup

Rye uses RLS. Include session context in every DB call, especially through
stateless tools or transaction-mode pools.

Prefer a read-only transaction when the tool supports multi-statement SQL:

```sql
BEGIN READ ONLY;
SELECT set_config('app.current_role', 'admin', true);
SELECT set_config('app.current_user_id', 'rye-reader', true);
SELECT set_config('app.current_teams', 'system', true);

-- SELECT queries here

ROLLBACK;
```

For single-call tools, include the three `set_config()` statements and the read
query in one explicit read-only transaction. If a tool forces separate setup and
read calls on the same session, use `set_config(..., false)` for session scope;
do not use local `true` settings outside an explicit transaction because they
can reset before the read. Use `ROLLBACK`, not `COMMIT`, when wrapping reads.

## Read Path

1. **Orient**
   - `SELECT rye.rye_catalog();`
   - Identify relevant `node_type`, `assertion_type`, edge types, and counts.
   - If the Rye MCP server is available, prefer read-only tools such as
     `rye.catalog`, `rye.search_nodes`, `rye.node_summary`,
     `rye.source_inventory`, and `rye.pending_context_confirmations`.

2. **Find the subject**
   - Search `rye.nodes` by label, type, external id, or properties.
   - Prefer exact `id` or `external_source`/`external_id` matches once found.

3. **Read compact node context**
   - `SELECT rye.agent_node_summary('<node_id>'::uuid, 20);`
   - Use this for a first pass before broad custom queries.

4. **Read accepted current knowledge**
   - Use `rye.current_valid_assertions`.
   - Do not reconstruct current knowledge with a bare
     `superseded_at IS NULL` filter.
   - Treat accepted assertions, task nodes, and active graph edges as knowledge.

5. **Read history**
   - Use `rye.assertions_as_of('<timestamp>'::timestamptz)` for point-in-time
     assertions.
   - Use `effective_at` and `effective_to` for domain truth windows.
   - Use `superseded_at` for Rye belief replacement, not domain truth ending.
   - Future-effective assertions are accepted knowledge for a future as-of
     time, not current knowledge before their `effective_at`.

6. **Read action status**
   - Task nodes use `node_type = 'task'`.
   - Prefer current `task_status` assertions when present.
   - Fall back to `nodes.properties->>'status'` when no status assertion exists.

7. **Read candidate review state**
   - Assertion candidates are in `rye.review_queue`.
   - Structural candidate nodes use `node_type = 'knowledge_candidate'`.
   - Read their current `candidate_status` assertions.
   - Proposed and `needs_review` candidates are not accepted knowledge.
   - Accepted structural candidates should have a promoted task or edge.

8. **Read provenance**
   - Read assertion provenance from `rye.assertion_support`.
   - Promoted structural tasks/edges store candidate and source references.
   - Follow candidate edges:
     - `supported_by`: candidate -> source item
     - `derived_from`: candidate -> run/source/process
     - `promoted_to`: candidate -> promoted task/node
   - Source items may have artifacts and provider permalinks.

9. **Report with confidence**
   - Separate accepted knowledge from proposed candidates and raw evidence.
   - Name stale, superseded, rejected, or unconfirmed material explicitly.
   - Do not infer business meaning from source metadata alone.

## Query Patterns

Catalog:

```sql
SELECT rye.rye_catalog();
```

Search nodes:

```sql
SELECT id, node_type, label, external_source, external_id, created_at
FROM rye.nodes
WHERE archived_at IS NULL
  AND (
    label ILIKE '%' || $1 || '%'
    OR coalesce(external_id, '') ILIKE '%' || $1 || '%'
    OR properties::text ILIKE '%' || $1 || '%'
  )
ORDER BY updated_at DESC
LIMIT 25;
```

Current accepted assertions for a node:

```sql
SELECT assertion_type, assertion_key, claim, confidence, effective_at,
       effective_to, attrs
FROM rye.current_valid_assertions
WHERE subject_node_id = '<node_id>'::uuid
ORDER BY assertion_type, assertion_key;
```

As-of assertions for a node:

```sql
SELECT assertion_type, assertion_key, claim, confidence, effective_at,
       effective_to, asserted_at
FROM rye.assertions_as_of('<as_of_iso>'::timestamptz)
WHERE subject_node_id = '<node_id>'::uuid
ORDER BY assertion_type, assertion_key;
```

Current plans for a node:

```sql
SELECT assertion_type, assertion_key, claim, effective_at, attrs
FROM rye.current_valid_assertions
WHERE subject_node_id = '<node_id>'::uuid
  AND assertion_type IN ('deal_stage_plan', 'task_status_plan', 'milestone_status_plan')
ORDER BY assertion_type, assertion_key;
```

Scheduled future rows:

```sql
SELECT assertion_type, assertion_key, claim, effective_at, attrs
FROM rye.assertions
WHERE subject_node_id = '<node_id>'::uuid
  AND superseded_at IS NULL
  AND attrs->>'scheduled_future' = 'true'
ORDER BY effective_at;
```

Open tasks:

```sql
SELECT n.id, n.label,
       coalesce(ts.claim->>'status', n.properties->>'status', 'open') AS status,
       n.properties, n.attrs
FROM rye.nodes n
LEFT JOIN rye.current_valid_assertions ts
  ON ts.subject_node_id = n.id
 AND ts.assertion_type = 'task_status'
 AND ts.assertion_key = 'default'
WHERE n.node_type = 'task'
  AND n.archived_at IS NULL
  AND coalesce(ts.claim->>'status', n.properties->>'status', 'open')
      NOT IN ('done', 'closed', 'cancelled')
ORDER BY n.created_at DESC;
```

Assertion review queue:

```sql
SELECT subject_ref, assertion_type, assertion_key, candidate_count, candidates
FROM rye.review_queue
ORDER BY candidate_count DESC, assertion_type, assertion_key;
```

Evidence for an assertion:

```sql
SELECT *
FROM rye.assertion_support
WHERE assertion_id = '<assertion_id>'::uuid;
```

## Answer Shape

When reporting from Rye, use this separation:

- **Accepted knowledge**: current valid assertions, active graph edges, task
  nodes, and accepted promoted records.
- **Current action status**: open, done, blocked, or unknown tasks.
- **Pending review**: proposed or needs-review candidates.
- **Evidence/provenance**: source items, artifacts, Slack permalinks, import
  runs, and candidate links.
- **History**: as-of or superseded assertions, labeled with the exact time basis.

If the answer depends on a source container whose confirmation status is still
`needs_confirmation`, say so and avoid applying its default context.
