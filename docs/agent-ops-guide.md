# Rye Agent Operations Guide

## Start a session

All objects live in `rye`.

```sql
SET search_path = rye, public, pg_catalog;
SET LOCAL "app.current_user_id" = 'user:alice';
SET LOCAL "app.current_teams" = 'engineering,sales';
SET LOCAL "app.current_role" = 'team_member';
```

Supabase calls use a fresh connection. Put equivalent `set_config()` calls in
the same request as the query.

Call `rye_catalog()` first. Use `agent_node_summary(node_id, max_items)` for
bounded context. Read current knowledge from `current_valid_assertions` or
`current_assertions_weighted`, never from a bare `superseded_at IS NULL`
filter.

## Events

Always create events through `record_event()`. It creates participants
atomically and avoids the event RLS visibility cycle.

```sql
SELECT record_event(
    p_event_type := 'meeting',
    p_summary := 'Quarterly review with Acme',
    p_properties := '{"location":"zoom"}',
    p_participant_ids := ARRAY['<node_uuid>']::uuid[],
    p_participant_roles := ARRAY['customer']
);
```

Do not insert into `events` and `event_participants` separately.

## Assertions

`record_assertion()` is the normal write path. Evidence is a `jsonb[]`; each
item contains `kind` and either `event_id` or `source_assertion_id`. A
`witness_node_id` is optional.

```sql
SELECT record_assertion(
    p_assertion_type := 'task_status',
    p_claim := '{"status":"in_progress"}',
    p_subject_node_id := '<task_uuid>',
    p_assertion_key := 'default',
    p_status := 'accepted',
    p_basis := 'reported',
    p_evidence := ARRAY[
      jsonb_build_object(
        'kind', 'source',
        'event_id', '<event_uuid>',
        'witness_node_id', '<person_uuid>'
      )
    ]
);
```

Evidence is required for helper-created assertions unless `basis = 'assumed'`.
Use `assumed` only for configuration or an explicit operator assumption.

To represent uncertainty, write one or more `candidate` rows on the same
tuple. Review them through `review_queue` or `competing_candidates`.

```sql
SELECT accept_assertion(
    p_assertion_id := '<candidate_uuid>',
    p_reason := 'Confirmed by owner',
    p_actor := 'user:alice'
);

SELECT reject_candidate(
    p_assertion_id := '<other_candidate_uuid>',
    p_reason := 'Superseded source document',
    p_actor := 'user:alice'
);
```

An inferred candidate cannot displace accepted observed, reported, assumed, or
unknown knowledge. Do not update assertion content or lifecycle columns
directly. Public `supersede_assertion()` only replaces the same subject, type,
and key.

Use `schedule_assertion_change()` for future-effective replacements.
Operational views continue returning the current assertion until the cutover.

Use `record_distillation()` for a digest. It requires source assertions,
writes derivation evidence, propagates classification, stores a watermark, and
records a distillation event. It rejects mixed-access source sets.

Use `resolve_knowledge_gap()` to close an accepted `knowledge_gap` with an
answer assertion. It creates a resolved version on the gap's own tuple.

## Classification and evidence

Assertions have their own `classification`. Derivations inherit the maximum
source classification. A derivation is rejected if no one access population
can see all sources.

`assertion_evidence` is append-only. A row is visible only when the caller can
see both the target assertion and the referenced event or source assertion.
Corroboration from a repeated witness is retained for audit but marked
`attrs.independent = false`.

Nodes with non-empty `attrs.teams` must also set `attrs.classification`.
Digest narrative artifacts inherit the digest assertion classification.

## Other safe writes

- Use `link_record()` to connect a domain row to a graph node.
- Use `track_table()` to capture linked domain-row changes.
- Use `update_node_properties()` only when the node itself is the system of
  record. Update the domain table otherwise.
- Use `record_artifact()` for artifacts and optional content-hash deduplication.
- Use `log_agent_query()` to audit agent reads.
- Use the tabular intake skill for CSV/XLSX staging and duplicate-run checks.

## Review and operational views

All views are security invokers.

| View | Purpose |
|---|---|
| `current_valid_assertions` | Accepted, current, effective-now assertions |
| `current_assertions_weighted` | Current assertions plus effective confidence |
| `review_queue` | Live candidate rows grouped by tuple |
| `competing_candidates` | Tuples with more than one live candidate |
| `stale_digests` | Digests invalidated by newer knowledge or displaced sources |
| `open_gaps` | Accepted unresolved knowledge gaps |
| `assertion_support` | Visible evidence bundle in both directions |
| `node_context` | Node, relationships, and current accepted assertions |
| `nodes_secure` | Nodes with field-level redaction |
