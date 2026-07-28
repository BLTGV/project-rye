# Rye — Functions Reference

## Utility Functions, Deduplication, and Query Patterns

All functions include a `SET search_path` clause in their definition for schema isolation. Internal functions use `SET search_path = rye, pg_catalog`. Cross-schema functions (CDC, profiles) use `SET search_path = rye, pg_catalog, public`. `SECURITY DEFINER` functions exclude `public` from the path. See `design/model/deployment.md` for details.

---

## 1. Assertion Immutability Guard

Assertions are append-only. Content, basis, subject, key, and effective start
are immutable. Gated helpers may narrow `effective_to`, transition a candidate
to accepted, propagate classification, or set supersession metadata.

---

## 2. Assertion Supersession

Supersedes an existing accepted assertion and creates a replacement in one
transaction. The replacement must use the same subject, type, and key.

```sql
SELECT supersede_assertion(
    p_old_assertion_id := '<assertion_uuid>',
    p_new_assertion_type := 'task_status',
    p_new_subject_node_id := '<task_uuid>',
    p_new_subject_edge_id := NULL,
    p_new_claim := '{"status":"done"}',
    p_new_assertion_key := 'default',
    p_new_basis := 'reported',
    p_new_evidence := ARRAY[
      jsonb_build_object('kind', 'source', 'event_id', '<event_uuid>'::uuid)
    ]
);
```

---

## 3. Human-Readable Code Generation

Generates codes in the format `{PREFIX}-{YYMM}-{SEQ}` (e.g., `OPP-2403-0042`). Uses a counter table with `INSERT ... ON CONFLICT DO UPDATE` for concurrency safety — no race conditions, no global sequence contention.

```sql
CREATE FUNCTION generate_crm_code(p_prefix text) RETURNS text AS $$
DECLARE
    v_yymm text;
    v_seq int;
BEGIN
    v_yymm := to_char(now(), 'YYMM');

    INSERT INTO crm_code_counters (prefix, year_month, next_val)
    VALUES (p_prefix, v_yymm, 2)
    ON CONFLICT (prefix, year_month)
    DO UPDATE SET next_val = crm_code_counters.next_val + 1
    RETURNING next_val - 1 INTO v_seq;

    RETURN p_prefix || '-' || v_yymm || '-' || lpad(v_seq::text, 4, '0');
END;
$$ LANGUAGE plpgsql;
```

Counters reset per prefix per month. `OPP-2403-0042` is the 42nd opportunity created in March 2024.

---

## 4. Node Merge (Deduplication)

Merges a duplicate node into a canonical node by redirecting all edges, assertions, event participations, and artifacts. Records a `node_merge` event before redirecting participations so both nodes are valid participants in the audit trail.

When the duplicate has active assertions that conflict with the canonical node's assertions (same type and key), the duplicate's assertions are superseded in favor of the canonical's. Non-conflicting assertions are copied to the canonical node.

```sql
CREATE FUNCTION merge_nodes(
    p_duplicate_id uuid,
    p_canonical_id uuid,
    p_merged_by text DEFAULT 'system'
) RETURNS void AS $$
```

Steps:
1. Validates both nodes exist and duplicate is not archived.
2. Records the merge in `node_merges`.
3. Records a `node_merge` event with both nodes as participants (`canonical` and `duplicate` roles).
4. Redirects edges, assertions (with conflict resolution), event participations, artifacts, and source mappings.
5. Merges properties (canonical wins on conflicts).
6. Archives the duplicate.

---

## 5. Fuzzy Candidate Detection

For cross-source deduplication where external IDs don't match, use trigram similarity:

```sql
-- Find candidate duplicate people
SELECT
    a.id AS node_a, a.label AS label_a,
    b.id AS node_b, b.label AS label_b,
    similarity(a.label, b.label) AS name_sim
FROM nodes a
JOIN nodes b ON a.id < b.id
WHERE a.node_type = 'person' AND b.node_type = 'person'
  AND a.label % b.label
  AND similarity(a.label, b.label) > 0.4
  AND a.archived_at IS NULL AND b.archived_at IS NULL;
```

---

## 6. Domain-Specific Normalizers

The graph supports domain-specific normalization functions. These are optional utilities — add them as your domain requires.

```sql
-- Example: Tax Map Parcel normalizer for land domains
-- Standardizes "045-0002-0031", "45/2/31", "45-2-31" → "45-2-31"
CREATE FUNCTION normalize_tmp(raw text) RETURNS text AS $$
    SELECT array_to_string(
        ARRAY(
            SELECT CASE
                WHEN ltrim(part, '0') = '' THEN '0'
                ELSE ltrim(part, '0')
            END
            FROM unnest(regexp_split_to_array(raw, '[-/.\s]+')) AS part
            WHERE part != ''
        ), '-'
    );
$$ LANGUAGE sql IMMUTABLE;
```

---

## 7. Event Recording

All event creation should use `record_event()`. This function pre-generates the event UUID and inserts both the event and its participants atomically, avoiding an RLS interaction where `INSERT ... RETURNING id` on the events table fails because the `event_read_policy` requires participants to exist before the event is visible.

```sql
CREATE FUNCTION record_event(
    p_event_type text,
    p_summary text,
    p_properties jsonb DEFAULT '{}',
    p_participant_ids uuid[] DEFAULT '{}',
    p_participant_roles text[] DEFAULT '{}',
    p_actor text DEFAULT NULL,
    p_occurred_at timestamptz DEFAULT now()
) RETURNS uuid;
```

Usage:

```sql
SELECT record_event(
    p_event_type     := 'meeting',
    p_summary        := 'Quarterly review with Acme',
    p_properties     := '{"location": "zoom"}',
    p_participant_ids := ARRAY['<node_uuid_1>', '<node_uuid_2>']::uuid[],
    p_participant_roles := ARRAY['organizer', 'attendee'],
    p_actor          := 'user:alice'
);
```

Do NOT insert into `events` and `event_participants` separately.

---

## 8. Domain Table Integration

### link_record — Connect a domain table row to the graph

Creates a graph node and maps it back to the source table via `node_source_map`. Each distinct `source_id` creates a new node. Calling again with the same `(schema, table, source_id)` updates the existing node's properties instead of creating a duplicate.

Lookup order: checks `node_source_map` first (canonical path), then falls back to `external_id`/`external_source` on the nodes table. This handles cases where the source map was created manually without setting `external_id`.

A unique index on `node_source_map(source_schema, source_table, source_id)` prevents orphaned or duplicate mappings.

```sql
CREATE FUNCTION link_record(
    p_source_schema text,
    p_source_table text,
    p_source_id text,
    p_node_type text,
    p_label text,
    p_properties jsonb DEFAULT '{}',
    p_source_id_type text DEFAULT 'int'
) RETURNS uuid;
```

Usage:

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

### link_records_batch — Bulk domain table import

Processes multiple `link_record()` calls in a single function call. Accepts parallel arrays for source IDs, labels, and optionally properties.

```sql
CREATE FUNCTION link_records_batch(
    p_source_schema text,
    p_source_table text,
    p_source_ids text[],
    p_node_type text,
    p_labels text[],
    p_properties jsonb[] DEFAULT NULL,
    p_source_id_type text DEFAULT 'int'
) RETURNS uuid[];
```

Usage:

```sql
SELECT link_records_batch(
    p_source_schema := 'public',
    p_source_table  := 'customers',
    p_source_ids    := ARRAY['1', '2', '3'],
    p_node_type     := 'org',
    p_labels        := ARRAY['Acme', 'Globex', 'Initech'],
    p_properties    := ARRAY[
        '{"plan": "growth"}'::jsonb,
        '{"plan": "starter"}'::jsonb,
        '{"plan": "enterprise"}'::jsonb
    ]
);
```

### track_table — Attach CDC triggers for change tracking

Attaches a trigger to a domain table that records INSERT/UPDATE/DELETE as `domain_change` events for any row that has a linked graph node. Uses `record_event()` internally.

```sql
CREATE FUNCTION track_table(
    p_schema text,
    p_table text,
    p_trigger_name text DEFAULT NULL
) RETURNS void;
```

Usage:

```sql
SELECT track_table('public', 'customers');
```

Changes to linked rows produce `domain_change` events with full before/after diff in the `changed_fields` property.

### capture_domain_change — CDC trigger function

The trigger function called by `track_table()`. Not called directly — it runs automatically on INSERT/UPDATE/DELETE. Only fires for rows that have a linked node in `node_source_map`. Unlinked rows are silently skipped.

Supports tables with any primary key column — tries `id` first, then falls back to the table's actual PK column via `pg_index` catalog lookup.

---

## 9. Instance Introspection

Returns a summary of everything in the Rye instance — node types, edge types, assertion types, event types, tracked tables, and totals.

```sql
CREATE FUNCTION rye_catalog() RETURNS jsonb;
```

Usage:

```sql
SELECT rye_catalog();
```

An agent's first call to orient itself in a new instance.

### Portable catalogs and agent context

Migration `0011_portability_catalog.sql` adds query helpers for CLI and agent
discovery:

```sql
CREATE FUNCTION rye_plugin_catalog() RETURNS jsonb;
CREATE FUNCTION rye_skill_catalog() RETURNS jsonb;
CREATE FUNCTION rye_capability_catalog() RETURNS jsonb;
CREATE FUNCTION rye_source_inventory() RETURNS jsonb;
CREATE FUNCTION rye_pending_context_confirmations() RETURNS jsonb;
CREATE FUNCTION rye_agent_context(p_scope_id uuid DEFAULT NULL) RETURNS jsonb;
```

Usage:

```sql
SELECT rye_agent_context();
SELECT rye_capability_catalog();
```

These functions expose synced plugin manifests, Rye skill manifests,
capabilities, source inventory, pending context confirmations, active scopes,
and selected scope policy as portable JSON.

---

## 10. Agent Query Logging

Logs an agent's read operation for audit purposes. Delegates to `record_event()` internally.

```sql
CREATE FUNCTION log_agent_query(
    p_agent_id text,
    p_query_text text,
    p_result_summary text,
    p_nodes_referenced uuid[]
) RETURNS uuid;
```

---

## 11. Artifact Recording

Creates an artifact with optional content-hash deduplication. Parallel to `record_event()` for events and `link_record()` for nodes.

```sql
CREATE FUNCTION record_artifact(
    p_artifact_type text,
    p_content jsonb,
    p_source_event_id uuid DEFAULT NULL,
    p_source_node_id uuid DEFAULT NULL,
    p_related_node_ids uuid[] DEFAULT '{}',
    p_location jsonb DEFAULT NULL,
    p_content_hash text DEFAULT NULL
) RETURNS uuid;
```

Usage:

```sql
-- Store a parsed document extract
SELECT record_artifact(
    p_artifact_type    := 'document_parse',
    p_content          := '{"title": "Q4 Report", "sections": [...]}',
    p_source_event_id  := '<parse_event_uuid>',
    p_source_node_id   := '<document_node_uuid>',
    p_related_node_ids := ARRAY['<mentioned_person_uuid>']::uuid[],
    p_content_hash     := 'sha256:abc123...'
);
```

If `p_content_hash` is provided and a matching artifact of the same type already exists, returns the existing artifact's ID without inserting a duplicate. The hash is stored in `attrs->>'content_hash'`.

---

## 12. Candidate Review

Write uncertain claims as assertion rows with `status = 'candidate'` and the
normal subject, type, and key. Review `review_queue`; use
`competing_candidates` for tuples with multiple candidates.

Call `accept_assertion()` for the selected claim. It supersedes an accepted
incumbent on the same tuple. Call `reject_candidate()` with a reason for claims
ruled out.

---

## 13. Materialized View Refresh

Refreshes all profile materialized views that exist in the database. Uses `CONCURRENTLY` to allow reads during refresh.

```sql
CREATE FUNCTION refresh_materialized_views() RETURNS void;
```

Usage:

```sql
SELECT refresh_materialized_views();
```

Only refreshes views that are installed — checks `pg_matviews` before each refresh. Safe to call regardless of which profiles are active.

---

## 14. Node Property Updates

Agents (`agent:*` roles) cannot directly UPDATE nodes (blocked by `node_update_policy`). When the node IS the system of record (no backing domain table), use `update_node_properties()` for controlled, audited property updates.

The function sets a write-path session flag (`app.write_path = 'update_node_properties'`) that temporarily opens the policy gate, then clears it immediately after the update. RLS still applies to the SELECT — agents can only update nodes they can read.

```sql
CREATE FUNCTION update_node_properties(
    p_node_id    uuid,
    p_properties jsonb,
    p_label      text DEFAULT NULL,
    p_summary    text DEFAULT NULL
) RETURNS uuid;
```

Usage:

```sql
-- Agent discovered a new email during conversation
SELECT update_node_properties(
    p_node_id    := '<contact_node_uuid>',
    p_properties := '{"email": "jane@newdomain.com", "title": "VP Engineering"}',
    p_summary    := 'Updated contact info from sales call'
);
```

Behavior:
- **Properties** are merged via `||` (new keys overlay old, existing keys preserved).
- **Label** is updated only if `p_label` is provided and different from the current label.
- **Archived nodes** raise an exception.
- Returns the UUID of the `node_properties_updated` audit event, which includes `changed_fields` with `properties_before`, `properties_after`, `properties_added`, and optionally `label_before`/`label_after`.

Non-agent roles can also use this function — they already have direct UPDATE access, but the function provides consistent audit logging.

---

## 15. Common Query Patterns

### Point-in-time reconstruction

What did we believe about a node as of a specific date?

```sql
SELECT * FROM assertions
WHERE subject_node_id = '<node_uuid>'
  AND asserted_at <= '2024-03-15T00:00:00Z'
  AND (superseded_at IS NULL OR superseded_at > '2024-03-15T00:00:00Z')
ORDER BY assertion_type, asserted_at DESC;
```

### Contradiction detection

Find assertions that were superseded, along with what replaced them:

```sql
SELECT
    old_a.assertion_type,
    old_a.claim AS old_claim,
    old_a.asserted_at AS old_asserted_at,
    new_a.claim AS new_claim,
    new_a.asserted_at AS new_asserted_at,
    n.label AS subject_label
FROM assertions old_a
JOIN assertions new_a ON new_a.id = old_a.superseded_by
JOIN nodes n ON n.id = old_a.subject_node_id
WHERE old_a.superseded_at IS NOT NULL
ORDER BY old_a.superseded_at DESC;
```

### Graph traversal (N hops)

```sql
WITH RECURSIVE graph AS (
    SELECT
        target_id AS node_id,
        1 AS depth,
        ARRAY[source_id, target_id] AS path,
        edge_type
    FROM edges
    WHERE source_id = '<start_node_uuid>' AND archived_at IS NULL

    UNION ALL

    SELECT
        e.target_id,
        g.depth + 1,
        g.path || e.target_id,
        e.edge_type
    FROM graph g
    JOIN edges e ON e.source_id = g.node_id AND e.archived_at IS NULL
    WHERE g.depth < 3
      AND NOT e.target_id = ANY(g.path)
)
SELECT DISTINCT n.*, g.depth, g.path
FROM graph g
JOIN nodes n ON n.id = g.node_id AND n.archived_at IS NULL
ORDER BY g.depth, n.node_type;
```

### Agent-optimized summary

Returns a compact context for a node, ranked and limited for agent consumption:

```sql
SELECT agent_node_summary('<node_uuid>', 15);
```

Returns a JSONB object with `node`, `top_relationships`, `current_facts`, and `recent_activity` arrays, each limited to `p_max_items` entries. Relationships include both outbound and inbound edges with a `direction` field (`'outbound'` or `'inbound'`).
