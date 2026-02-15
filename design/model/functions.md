# Rye — Functions Reference

## Utility Functions, Deduplication, and Query Patterns

---

## 1. Assertion Immutability Guard

Assertions are append-only. Only the `superseded_at` and `superseded_by` columns may be updated (by the supersession function). All other columns are immutable after insert.

```sql
CREATE FUNCTION assertions_immutable_guard() RETURNS trigger AS $$
BEGIN
    IF NEW.claim IS DISTINCT FROM OLD.claim
       OR NEW.assertion_type IS DISTINCT FROM OLD.assertion_type
       OR NEW.subject_node_id IS DISTINCT FROM OLD.subject_node_id
       OR NEW.subject_edge_id IS DISTINCT FROM OLD.subject_edge_id
       OR NEW.asserted_at IS DISTINCT FROM OLD.asserted_at
       OR NEW.effective_at IS DISTINCT FROM OLD.effective_at
       OR NEW.source_event_id IS DISTINCT FROM OLD.source_event_id
       OR NEW.confidence IS DISTINCT FROM OLD.confidence
    THEN
        RAISE EXCEPTION 'Assertion content is immutable. Only superseded_at and superseded_by may be updated.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_assertions_immutable
    BEFORE UPDATE ON assertions
    FOR EACH ROW
    EXECUTE FUNCTION assertions_immutable_guard();
```

---

## 2. Assertion Supersession

Supersedes an existing assertion and creates a replacement in a single transaction.

```sql
CREATE FUNCTION supersede_assertion(
    p_old_assertion_id uuid,
    p_new_assertion_type text,
    p_new_subject_node_id uuid,
    p_new_subject_edge_id uuid,
    p_new_claim jsonb,
    p_new_effective_at timestamptz DEFAULT NULL,
    p_new_source_event_id uuid DEFAULT NULL,
    p_new_confidence numeric DEFAULT NULL
) RETURNS uuid AS $$
DECLARE
    v_new_id uuid;
BEGIN
    -- Create the new assertion
    INSERT INTO assertions (
        assertion_type, subject_node_id, subject_edge_id,
        claim, effective_at, source_event_id, confidence
    ) VALUES (
        p_new_assertion_type, p_new_subject_node_id, p_new_subject_edge_id,
        p_new_claim, p_new_effective_at, p_new_source_event_id, p_new_confidence
    ) RETURNING id INTO v_new_id;

    -- Supersede the old assertion (only touches superseded_at/by, passes immutability guard)
    UPDATE assertions
    SET superseded_at = now(),
        superseded_by = v_new_id
    WHERE id = p_old_assertion_id
      AND superseded_at IS NULL;  -- idempotency guard

    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;
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

Merges a duplicate node into a canonical node by redirecting all edges, assertions, event participations, and artifacts.

```sql
CREATE FUNCTION merge_nodes(
    p_duplicate_id uuid,
    p_canonical_id uuid,
    p_merged_by text DEFAULT 'system'
) RETURNS void AS $$
BEGIN
    -- Record the merge
    INSERT INTO node_merges (duplicate_id, canonical_id, merged_by)
    VALUES (p_duplicate_id, p_canonical_id, p_merged_by);

    -- Redirect edges (skip if it would create a self-loop)
    UPDATE edges SET source_id = p_canonical_id
    WHERE source_id = p_duplicate_id AND target_id != p_canonical_id;
    UPDATE edges SET target_id = p_canonical_id
    WHERE target_id = p_duplicate_id AND source_id != p_canonical_id;

    -- Archive edges that became self-loops
    UPDATE edges SET archived_at = now()
    WHERE source_id = p_canonical_id AND target_id = p_canonical_id
      AND archived_at IS NULL;

    -- Redirect assertions
    UPDATE assertions SET subject_node_id = p_canonical_id
    WHERE subject_node_id = p_duplicate_id;

    -- Redirect event participations (skip duplicates)
    UPDATE event_participants SET node_id = p_canonical_id
    WHERE node_id = p_duplicate_id
      AND NOT EXISTS (
          SELECT 1 FROM event_participants ep2
          WHERE ep2.event_id = event_participants.event_id
            AND ep2.node_id = p_canonical_id
            AND ep2.role = event_participants.role
      );
    -- Delete remaining duplicate participations
    DELETE FROM event_participants
    WHERE node_id = p_duplicate_id;

    -- Redirect artifact references
    UPDATE artifacts SET source_node_id = p_canonical_id
    WHERE source_node_id = p_duplicate_id;
    UPDATE artifacts
    SET related_node_ids = array_replace(related_node_ids, p_duplicate_id, p_canonical_id)
    WHERE p_duplicate_id = ANY(related_node_ids);

    -- Transfer source mappings (delete conflicts first, then remap)
    DELETE FROM node_source_map nsm_dup
    WHERE nsm_dup.node_id = p_duplicate_id
      AND EXISTS (
          SELECT 1 FROM node_source_map nsm_can
          WHERE nsm_can.node_id = p_canonical_id
            AND nsm_can.source_schema = nsm_dup.source_schema
            AND nsm_can.source_table = nsm_dup.source_table
      );
    UPDATE node_source_map SET node_id = p_canonical_id
    WHERE node_id = p_duplicate_id;

    -- Merge properties (canonical wins on conflicts)
    UPDATE nodes
    SET properties = (SELECT properties FROM nodes WHERE id = p_duplicate_id) || properties,
        updated_at = now()
    WHERE id = p_canonical_id;

    -- Archive the duplicate
    UPDATE nodes SET archived_at = now(), updated_at = now()
    WHERE id = p_duplicate_id;
END;
$$ LANGUAGE plpgsql;
```

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

## 7. Common Query Patterns

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
CREATE FUNCTION agent_node_summary(p_node_id uuid, p_max_items int DEFAULT 10)
RETURNS jsonb AS $$
SELECT jsonb_build_object(
    'node', (SELECT row_to_json(n) FROM nodes n WHERE n.id = p_node_id),

    'top_relationships', (
        SELECT json_agg(r) FROM (
            SELECT e.edge_type, e.properties, e.weight, nt.label AS target_label, nt.node_type AS target_type
            FROM edges e
            JOIN nodes nt ON nt.id = e.target_id
            WHERE e.source_id = p_node_id AND e.archived_at IS NULL
            ORDER BY e.weight DESC NULLS LAST, e.created_at DESC
            LIMIT p_max_items
        ) r
    ),

    'current_facts', (
        SELECT json_agg(a) FROM (
            SELECT a.assertion_type, a.claim, a.confidence, a.asserted_at
            FROM current_assertions a
            WHERE a.subject_node_id = p_node_id
            ORDER BY a.confidence DESC NULLS LAST, a.asserted_at DESC
            LIMIT p_max_items
        ) a
    ),

    'recent_activity', (
        SELECT json_agg(ev) FROM (
            SELECT e.event_type, e.summary, e.occurred_at, ep.role
            FROM events e
            JOIN event_participants ep ON ep.event_id = e.id
            WHERE ep.node_id = p_node_id
            ORDER BY e.occurred_at DESC
            LIMIT p_max_items
        ) ev
    )
);
$$ LANGUAGE sql STABLE;
```
