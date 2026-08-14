-- Source-map row identity: key node_source_map by source row, repoint on merge.
--
-- The PK was (node_id, source_schema, source_table): one mapping per source
-- table per node. merge_nodes() therefore could not repoint the duplicate's
-- mapping when the canonical node already mapped the same table — it DELETEd
-- the row, silently severing that source row's graph identity. The next
-- link_record() for that source row missed both lookup paths (map row gone;
-- the external_id fallback filters archived nodes, and merge_nodes archives
-- the duplicate) and minted a fresh node — resurrecting the just-merged
-- duplicate with none of its history. design/model/deployment.md already
-- describes the map as keyed by (source_schema, source_table, source_id);
-- this migration makes the schema match.
--
-- Changes:
--   1. PK becomes (source_schema, source_table, source_id) by promoting
--      idx_nsm_source_unique (added in 0005), so a canonical node can carry
--      every merged source row's mapping. No data cleanup is needed: the
--      unique index already enforced the new key.
--   2. merge_nodes() repoints the duplicate's mappings instead of deleting
--      colliding ones.
--   3. link_record()'s upsert conflicts on the new key.
--   4. Mappings lost to past merges are backfilled from node_merges plus the
--      archived duplicate's external_id/external_source.

SET search_path = rye, pg_catalog, public;

-- ============================================================================
-- 1. PRIMARY KEY SWAP
-- ============================================================================
-- Promote idx_nsm_source_unique to the PK (Postgres renames the index to the
-- constraint name). Keep a plain index on node_id for reverse lookups, which
-- the old PK used to serve; idx_nsm_source (0001) is redundant with the new
-- PK and is dropped.

DO $$
DECLARE
    v_pk text;
BEGIN
    SELECT conname INTO v_pk
    FROM pg_constraint
    WHERE conrelid = 'node_source_map'::regclass AND contype = 'p';

    IF v_pk IS NOT NULL THEN
        EXECUTE format('ALTER TABLE node_source_map DROP CONSTRAINT %I', v_pk);
    END IF;
END;
$$;

ALTER TABLE node_source_map
    ADD CONSTRAINT node_source_map_pkey
    PRIMARY KEY USING INDEX idx_nsm_source_unique;

DROP INDEX IF EXISTS idx_nsm_source;

CREATE INDEX IF NOT EXISTS idx_nsm_node ON node_source_map (node_id);

-- ============================================================================
-- 2. MERGE_NODES — repoint source mappings instead of deleting
-- ============================================================================
-- Identical to the 0005 definition (v2 assertion lifecycle: status/basis/
-- classification carry-over, derivation evidence on the replacement) except
-- the source-map section: the DELETE of colliding duplicate mappings is gone;
-- all of the duplicate's mappings are repointed to the canonical node.

CREATE OR REPLACE FUNCTION merge_nodes(
    p_duplicate_id uuid,
    p_canonical_id uuid,
    p_merged_by text DEFAULT 'system'
) RETURNS void
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_dupe nodes;
    v_canon nodes;
    v_assertion assertions;
    v_replacement_id uuid;
BEGIN
    IF p_duplicate_id = p_canonical_id THEN
        RAISE EXCEPTION 'duplicate_id and canonical_id must be different';
    END IF;

    SELECT * INTO v_dupe FROM nodes WHERE id = p_duplicate_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Duplicate node % not found', p_duplicate_id;
    END IF;

    SELECT * INTO v_canon FROM nodes WHERE id = p_canonical_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Canonical node % not found', p_canonical_id;
    END IF;

    IF v_dupe.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'Duplicate node % is already archived', p_duplicate_id;
    END IF;

    INSERT INTO node_merges (duplicate_id, canonical_id, merged_by)
    VALUES (p_duplicate_id, p_canonical_id, p_merged_by);

    -- Record merge event BEFORE redirecting participations,
    -- so both nodes are still valid participants
    PERFORM record_event(
        p_event_type        := 'node_merge',
        p_summary           := format('Merged "%s" into "%s"', v_dupe.label, v_canon.label),
        p_properties        := jsonb_build_object(
            'duplicate_id', p_duplicate_id,
            'canonical_id', p_canonical_id,
            'duplicate_label', v_dupe.label,
            'canonical_label', v_canon.label,
            'duplicate_type', v_dupe.node_type,
            'merged_by', p_merged_by
        ),
        p_participant_ids   := ARRAY[p_canonical_id, p_duplicate_id],
        p_participant_roles := ARRAY['canonical', 'duplicate'],
        p_actor             := p_merged_by
    );

    UPDATE edges
    SET source_id = p_canonical_id
    WHERE source_id = p_duplicate_id
      AND target_id <> p_canonical_id;

    UPDATE edges
    SET target_id = p_canonical_id
    WHERE target_id = p_duplicate_id
      AND source_id <> p_canonical_id;

    UPDATE edges
    SET archived_at = now()
    WHERE source_id = p_canonical_id
      AND target_id = p_canonical_id
      AND archived_at IS NULL;

    FOR v_assertion IN
        SELECT *
        FROM current_valid_assertions
        WHERE subject_node_id = p_duplicate_id
    LOOP
        SELECT id
        INTO v_replacement_id
        FROM current_valid_assertions
        WHERE subject_node_id = p_canonical_id
          AND assertion_type = v_assertion.assertion_type
          AND assertion_key = v_assertion.assertion_key
        LIMIT 1;

        IF v_replacement_id IS NULL THEN
            INSERT INTO assertions (
                assertion_type,
                assertion_key,
                subject_node_id,
                subject_edge_id,
                claim,
                effective_at,
                effective_to,
                status,
                basis,
                classification,
                confidence,
                attrs
            ) VALUES (
                v_assertion.assertion_type,
                v_assertion.assertion_key,
                p_canonical_id,
                v_assertion.subject_edge_id,
                v_assertion.claim,
                v_assertion.effective_at,
                v_assertion.effective_to,
                v_assertion.status,
                v_assertion.basis,
                v_assertion.classification,
                v_assertion.confidence,
                v_assertion.attrs
            )
            RETURNING id INTO v_replacement_id;

            PERFORM append_assertion_evidence(
                v_replacement_id,
                ARRAY[jsonb_build_object(
                    'kind', 'derivation',
                    'source_assertion_id', v_assertion.id
                )]
            );
        END IF;

        PERFORM mark_assertion_superseded(v_assertion.id, v_replacement_id);
    END LOOP;

    UPDATE event_participants
    SET node_id = p_canonical_id
    WHERE node_id = p_duplicate_id
      AND NOT EXISTS (
          SELECT 1
          FROM event_participants ep2
          WHERE ep2.event_id = event_participants.event_id
            AND ep2.node_id = p_canonical_id
            AND ep2.role = event_participants.role
      );

    DELETE FROM event_participants
    WHERE node_id = p_duplicate_id;

    UPDATE artifacts
    SET source_node_id = p_canonical_id
    WHERE source_node_id = p_duplicate_id;

    UPDATE artifacts
    SET related_node_ids = array_replace(related_node_ids, p_duplicate_id, p_canonical_id)
    WHERE p_duplicate_id = ANY(related_node_ids);

    -- Repoint every source mapping to the canonical node. The PK is
    -- (source_schema, source_table, source_id), so a source row maps to
    -- exactly one node and repointing node_id can never conflict; the
    -- canonical node carries one mapping per merged source row from here on.
    UPDATE node_source_map
    SET node_id = p_canonical_id
    WHERE node_id = p_duplicate_id;

    UPDATE nodes
    SET properties = (SELECT properties FROM nodes WHERE id = p_duplicate_id) || properties,
        updated_at = now()
    WHERE id = p_canonical_id;

    UPDATE nodes
    SET archived_at = now(),
        updated_at = now()
    WHERE id = p_duplicate_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 3. LINK_RECORD — upsert by source row
-- ============================================================================
-- Identical to the 0018 definition (canonical node vocabulary preserved)
-- except the ON CONFLICT target, which now matches the new PK. A conflict can
-- only occur when the mapping already points at the node the lookup just
-- resolved, so only synced_at is touched.

CREATE OR REPLACE FUNCTION link_record(
    p_source_schema text,
    p_source_table text,
    p_source_id text,
    p_node_type text,
    p_label text,
    p_properties jsonb DEFAULT '{}',
    p_source_id_type text DEFAULT 'int'
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_node_id uuid;
    v_ext_source text;
    v_node_type text := canonical_type('node_type', p_node_type);
BEGIN
    v_ext_source := p_source_schema || '.' || p_source_table;

    SELECT node_id INTO v_node_id
    FROM node_source_map
    WHERE source_schema = p_source_schema
      AND source_table = p_source_table
      AND source_id = p_source_id;

    IF v_node_id IS NULL THEN
        SELECT id INTO v_node_id
        FROM nodes
        WHERE external_id = p_source_id
          AND external_source = v_ext_source
          AND archived_at IS NULL;
    END IF;

    IF v_node_id IS NOT NULL THEN
        UPDATE nodes
        SET properties = properties || p_properties,
            label = coalesce(p_label, label)
        WHERE id = v_node_id;
    ELSE
        INSERT INTO nodes (node_type, label, external_id, external_source, properties)
        VALUES (v_node_type, p_label, p_source_id, v_ext_source, p_properties)
        RETURNING id INTO v_node_id;
    END IF;

    INSERT INTO node_source_map (node_id, source_schema, source_table, source_id, source_id_type)
    VALUES (v_node_id, p_source_schema, p_source_table, p_source_id, p_source_id_type)
    ON CONFLICT (source_schema, source_table, source_id) DO UPDATE
        SET synced_at = now();

    RETURN v_node_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 4. BACKFILL — restore mappings dropped by past merges
-- ============================================================================
-- Every pre-0020 merge that hit the same-table collision deleted the
-- duplicate's mapping. The archived duplicate node still carries the source
-- row's identity in external_id/external_source ('schema.table', built by
-- link_record), and node_merges records where it went. Re-create the mapping
-- onto the merge's final canonical node (following merge chains, since a
-- canonical node may itself have been merged later) wherever the source row
-- has no mapping today. source_id_type is copied from an existing mapping
-- for the same source table when one exists, else the column default.

WITH RECURSIVE latest_merge AS (
    SELECT DISTINCT ON (duplicate_id) duplicate_id, canonical_id
    FROM node_merges
    ORDER BY duplicate_id, merged_at DESC
),
chain AS (
    SELECT lm.duplicate_id, lm.canonical_id, 1 AS depth
    FROM latest_merge lm
    UNION ALL
    SELECT c.duplicate_id, lm.canonical_id, c.depth + 1
    FROM chain c
    JOIN latest_merge lm ON lm.duplicate_id = c.canonical_id
    WHERE c.depth < 32
),
final AS (
    SELECT DISTINCT ON (duplicate_id) duplicate_id, canonical_id
    FROM chain
    ORDER BY duplicate_id, depth DESC
)
INSERT INTO node_source_map (node_id, source_schema, source_table, source_id, source_id_type)
SELECT
    f.canonical_id,
    split_part(d.external_source, '.', 1),
    substr(d.external_source, strpos(d.external_source, '.') + 1),
    d.external_id,
    coalesce(
        (SELECT nsm.source_id_type
         FROM node_source_map nsm
         WHERE nsm.source_schema = split_part(d.external_source, '.', 1)
           AND nsm.source_table = substr(d.external_source, strpos(d.external_source, '.') + 1)
         LIMIT 1),
        'int'
    )
FROM final f
JOIN nodes d ON d.id = f.duplicate_id
WHERE d.archived_at IS NOT NULL
  AND d.external_id IS NOT NULL
  AND strpos(coalesce(d.external_source, ''), '.') > 0
ON CONFLICT (source_schema, source_table, source_id) DO NOTHING;
