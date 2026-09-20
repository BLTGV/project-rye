-- Source-map row identity: node_source_map is keyed by the source row, and a
-- merge re-points every mapping instead of deleting the ones that collide.
--
-- Supersedes pull request 6 (branch fix/node-source-map-row-identity), which
-- was written against a main that predates migrations 0020 to 0030.
-- Work item: work/012-source-map-row-identity.md.
--
-- The defect. node_source_map's primary key was
-- (node_id, source_schema, source_table): one mapping per source table per
-- node. So when a duplicate and its canonical both mapped rows of the same
-- table -- the ordinary dedup case -- merge_nodes() could not re-point the
-- duplicate's mapping and DELETEd it instead. The source row that pointed at
-- the duplicate lost its graph identity with no error and no signal, and the
-- next link_record() for that row missed both lookup paths (the mapping was
-- gone, and the external_id fallback filters archived nodes while a merge
-- archives the duplicate). It inserted a fresh, empty node: the merged
-- duplicate came back without its edges, assertions, or history. Chained
-- merges strip the mappings of every non-final source row.
--
-- design/model/deployment.md already described the map as keyed by
-- (source_schema, source_table, source_id). This makes the schema match.
--
-- Four changes:
--   1. The primary key becomes (source_schema, source_table, source_id) by
--      promoting idx_nsm_source_unique, which 0005 already created and which
--      has enforced that exact key ever since. No data can collide on the
--      promotion, on any instance that has applied 0005 -- which is every
--      instance, because migrate.sh applies files in order.
--   2. merge_nodes() re-points the duplicate's mappings; nothing is deleted.
--      Carried forward from its live definition in 0026, which is where every
--      refusal-before-the-lock lives, with the source-map block as the only
--      edit. The three node_source_map policies and
--      trg_node_source_map_gate_may_write from 0026 are untouched.
--   3. link_record()'s upsert conflicts on the new key. Carried forward from
--      its live definition in 0018, with the ON CONFLICT target as the only
--      edit. The old DO UPDATE SET source_id = ... could re-point a node's
--      mapping onto a different source row; the new one refreshes synced_at
--      and nothing else, because a conflict now means the mapping already
--      names the row we resolved.
--   4. rye_restore_merged_source_maps() puts back the mappings past merges
--      dropped, and says what it could not put back. The migration runs it
--      once. It is re-runnable and it is a no-op on an instance with nothing
--      to repair, which is every instance installed from 0031 onward.
--
-- Deploy note: promoting the index takes an ACCESS EXCLUSIVE lock on
-- node_source_map. It is brief -- no table rewrite, no index build -- but it
-- waits behind open transactions that touch the table.
--
-- scripts/migrate.sh runs each migration in its own psql session, and since
-- 0026 a session that sets no role writes nothing. This file sets its own
-- role before the repair call at the end.

SET search_path = rye, pg_catalog, public;

SELECT set_config('app.current_role', 'admin', false);

-- ============================================================================
-- 1. THE KEY IS THE SOURCE ROW
-- ============================================================================
-- idx_nsm_source_unique (0005) is promoted to the primary key: Postgres
-- renames the index to the constraint name, so the unique guarantee is
-- continuous and no second index is built. The reverse lookup the old primary
-- key served -- "which rows does this node map?" -- moves to a plain index on
-- node_id. idx_nsm_source (0001) duplicates the new primary key and goes.
--
-- The DO block is defensive about an instance that somehow lacks the unique
-- index: it builds it first, which fails loudly on genuinely duplicated source
-- rows rather than quietly dropping one. Nothing is deleted here, ever.

DO $$
DECLARE
    v_pk   text;
    v_kind text;
BEGIN
    SELECT conname INTO v_pk
    FROM pg_constraint
    WHERE conrelid = 'node_source_map'::regclass AND contype = 'p';

    -- Already keyed by the source row (a re-run): nothing to do.
    IF v_pk IS NOT NULL AND (
        SELECT string_agg(a.attname, ',' ORDER BY k.ord)
        FROM pg_constraint c
        JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
        WHERE c.conname = v_pk AND c.conrelid = 'node_source_map'::regclass
    ) = 'source_schema,source_table,source_id' THEN
        RAISE NOTICE '0031: node_source_map is already keyed by the source row';
        RETURN;
    END IF;

    -- The schema is whatever search_path resolves node_source_map in, so a
    -- non-default RYE_SCHEMA keeps working.
    SELECT CASE WHEN i.indisunique THEN 'unique' ELSE 'plain' END INTO v_kind
    FROM pg_class c
    JOIN pg_index i ON i.indexrelid = c.oid
    WHERE c.relname = 'idx_nsm_source_unique'
      AND c.relnamespace = (
          SELECT relnamespace FROM pg_class WHERE oid = 'node_source_map'::regclass
      );

    IF v_kind IS DISTINCT FROM 'unique' THEN
        IF v_kind IS NOT NULL THEN
            EXECUTE 'DROP INDEX idx_nsm_source_unique';
        END IF;
        EXECUTE 'CREATE UNIQUE INDEX idx_nsm_source_unique'
             || ' ON node_source_map (source_schema, source_table, source_id)';
    END IF;

    IF v_pk IS NOT NULL THEN
        EXECUTE format('ALTER TABLE node_source_map DROP CONSTRAINT %I', v_pk);
    END IF;

    ALTER TABLE node_source_map
        ADD CONSTRAINT node_source_map_pkey
        PRIMARY KEY USING INDEX idx_nsm_source_unique;
END;
$$;

DROP INDEX IF EXISTS idx_nsm_source;

CREATE INDEX IF NOT EXISTS idx_nsm_node ON node_source_map (node_id);

COMMENT ON TABLE node_source_map IS
    'Maps a source row to the graph node that stands for it. Keyed by (source_schema, source_table, source_id): one source row names one node, and one node may hold many source rows -- which is what a merge leaves behind. capture_domain_change() and link_record() both look a row up by that key.';

-- ============================================================================
-- 2. MERGE_NODES -- RE-POINT EVERY MAPPING, DELETE NONE
-- ============================================================================
-- Carried forward verbatim from the live definition in
-- schema/migrations/0026_who_may_write.sql. Every refusal still comes before
-- the first FOR UPDATE: a role that may not write, an agent-shaped role,
-- system:cdc, and a non-admin merging a node the governance structure touches.
-- The one edit is the source-map block near the end.

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
    v_role text := coalesce(current_setting('app.current_role', true), '');
BEGIN
    -- Every refusal is evaluated before the first FOR UPDATE. Under an agent
    -- role on an owner RLS binds, the lock is filtered to zero rows and the
    -- old ordering reported "Duplicate node % not found" about a node the
    -- caller could see.
    IF NOT rye_role_may_write() THEN
        RAISE EXCEPTION
            'merge_nodes requires a role that may write; "%" may only read. A Rye admin or a team member merges.', v_role
            USING ERRCODE = '42501';
    END IF;

    IF rye_current_agent_key() IS NOT NULL THEN
        RAISE EXCEPTION
            'merge_nodes is not available to an agent ("%"). Record the duplicate and ask a person; a Rye admin or a team member merges.', v_role
            USING ERRCODE = '42501';
    END IF;

    IF v_role = 'system:cdc' THEN
        RAISE EXCEPTION
            'merge_nodes is not available to system:cdc, which only records domain changes. A Rye admin or a team member merges.'
            USING ERRCODE = '42501';
    END IF;

    IF p_duplicate_id = p_canonical_id THEN
        RAISE EXCEPTION 'duplicate_id and canonical_id must be different';
    END IF;

    -- A merge re-points the duplicate's edges and archives the duplicate. If
    -- either is part of the governance structure, only an admin may do it; a
    -- silent zero-row UPDATE would otherwise leave a governance edge pointing
    -- at an archived node.
    IF v_role <> 'admin' THEN
        IF EXISTS (
            SELECT 1 FROM nodes n
            WHERE n.id = p_duplicate_id AND n.node_type = 'onboarding_scope'
        ) OR EXISTS (
            SELECT 1 FROM edges e
            WHERE (e.source_id = p_duplicate_id OR e.target_id = p_duplicate_id)
              AND e.edge_type IN (
                  'scope_governs_subject', 'scope_governs_source', 'scope_enables_plugin'
              )
              AND e.archived_at IS NULL
              AND (e.effective_from IS NULL OR e.effective_from <= now())
              AND (e.effective_to IS NULL OR e.effective_to > now())
        ) THEN
            RAISE EXCEPTION
                'Merging a node a scope governs requires a Rye admin ("%" is not).', v_role
                USING ERRCODE = '42501';
        END IF;
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

    -- Every mapping the duplicate holds is re-pointed, and none is dropped.
    -- The key is (source_schema, source_table, source_id), which does not
    -- contain node_id, so re-pointing can never collide: a source row maps to
    -- exactly one node, and the canonical node carries one mapping per merged
    -- source row from here on. What used to stand here deleted the duplicate's
    -- mapping whenever the canonical already mapped a row of the same table --
    -- the ordinary dedup case -- and that source row lost its graph identity
    -- with no error, so the next link_record() for it minted a fresh node and
    -- the merged duplicate came back empty.
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
-- 3. LINK_RECORD -- UPSERT BY SOURCE ROW
-- ============================================================================
-- Carried forward verbatim from the live definition in
-- schema/migrations/0018_knowledge_governance_salience_gardening.sql, which
-- added the canonical_type() normalisation. The one edit is the ON CONFLICT
-- target.
--
-- The lookup already reads node_source_map by (source_schema, source_table,
-- source_id), so after a merge it returns the canonical node and creates
-- nothing -- the whole point of the key change. A conflict on the insert can
-- now only mean the mapping exists and names the node just resolved, so
-- synced_at is all there is to refresh. One shape changes: where RLS hides a
-- mapping and its node from the caller, the old target inserted a second
-- mapping for the same source row and tripped idx_nsm_source_unique; the new
-- one reaches DO UPDATE on a row the caller may not see and is refused by
-- nsm_update_policy. Both refuse. The message differs.

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

COMMENT ON FUNCTION link_record(text, text, text, text, text, jsonb, text) IS
    'Connect a domain table row to the graph, idempotently. Resolves the node from node_source_map by (source_schema, source_table, source_id) first, then by nodes.external_id/external_source, and inserts a node only when neither finds one. Upserts the mapping on the source row, so a row merged into a canonical node resolves to that canonical node and no fresh node is minted.';

-- ============================================================================
-- 4. PUT BACK WHAT PAST MERGES DROPPED
-- ============================================================================
-- Before this migration a merge deleted the duplicate's mapping whenever the
-- canonical already mapped a row of the same table. The evidence survives: the
-- archived duplicate still carries the source row identity in external_id and
-- external_source ('schema.table', as link_record() writes it), and
-- node_merges records where it went. This walks merge chains to the terminal
-- canonical and re-creates the mapping where the source row has none today.
--
-- Deliberate choices, each of which a caller can see in the report:
--
--   restored       a mapping was put back.
--   already_mapped the source row already maps to the terminal canonical.
--                  Every merge made from 0031 onward lands here, which is why
--                  the function is a no-op to re-run.
--   occupied       the source row maps to some other node. That is the
--                  resurrected duplicate the old bug minted on the next lazy
--                  link, and it may have accumulated its own history since, so
--                  nothing is re-pointed silently. The remedy is
--                  merge_nodes(mapped_node, canonical), which now re-points
--                  the mapping instead of deleting it.
--   ambiguous      two archived duplicates claim the same source row and were
--                  merged into different canonicals. Only a person knows which
--                  is right. Skipped.
--   unresolved     external_source matched no surviving (source_schema,
--                  source_table) pair, or matched several. Splitting at the
--                  first dot would misparse a schema name containing one, so
--                  the pair is recovered by matching pairs that still exist.
--                  Skipped.
--
-- A chain that does not terminate within 32 hops, or cycles, is skipped rather
-- than mapped onto an archived intermediate, and counted unresolved.
--
-- node_merges is treated as untrusted. Its insert policy (0029) asks only that
-- the role may write, so a row there may be forged: a merge that never
-- happened, a future date, a duplicate that is still live. A row is followed
-- only when its duplicate node is archived; where several rows name one
-- duplicate the earliest by merged_at then id wins, so a later forged row
-- cannot redirect a real merge; and a cycle stops the walk.
--
-- SECURITY INVOKER, and admin-only: it writes mappings on a caller's behalf
-- from evidence, which is a repair, not bookkeeping. Under an owner that RLS
-- binds, admin is also the role that reads the whole node_merges trail and
-- every archived node, so a narrower role would restore a subset and report
-- success.

CREATE OR REPLACE FUNCTION rye_restore_merged_source_maps()
RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_role   text := coalesce(current_setting('app.current_role', true), '');
    v_report jsonb;
BEGIN
    IF v_role <> 'admin' THEN
        RAISE EXCEPTION
            'rye_restore_merged_source_maps repairs source mappings a past merge dropped and requires a Rye admin ("%" is not).', v_role
            USING ERRCODE = '42501';
    END IF;

    WITH RECURSIVE
    -- node_merges is not trusted evidence. Its insert policy asks only that
    -- the role may write, so a row there may name a merge that never
    -- happened, be dated in the future, or point at a node that is still
    -- live. Three rules follow, the same ones the reader in 0033 applies:
    --
    --   * a row counts only when its duplicate node is actually archived,
    --     which is the state a real merge leaves;
    --   * where several rows name one duplicate, the earliest by merged_at
    --     then id wins, so a later forged row cannot redirect a real merge;
    --   * a cycle terminates the walk and the duplicate is reported
    --     unresolved rather than mapped onto a guess.
    merge_edge AS (
        SELECT DISTINCT ON (m.duplicate_id) m.duplicate_id, m.canonical_id
        FROM node_merges m
        JOIN nodes d ON d.id = m.duplicate_id
        WHERE d.archived_at IS NOT NULL
        ORDER BY m.duplicate_id, m.merged_at, m.id
    ),
    chain AS (
        SELECT e.duplicate_id, e.canonical_id, 1 AS depth,
               ARRAY[e.duplicate_id, e.canonical_id] AS seen,
               false AS cycled
        FROM merge_edge e
        UNION ALL
        SELECT c.duplicate_id, e.canonical_id, c.depth + 1,
               c.seen || e.canonical_id,
               e.canonical_id = ANY(c.seen)
        FROM chain c
        JOIN merge_edge e ON e.duplicate_id = c.canonical_id
        WHERE c.depth < 32 AND NOT c.cycled
    ),
    deepest AS (
        SELECT DISTINCT ON (duplicate_id) duplicate_id, canonical_id, cycled
        FROM chain
        ORDER BY duplicate_id, depth DESC
    ),
    -- A chain that cycled, or whose last canonical is itself a duplicate --
    -- the depth cap -- has no terminal node. Mapping onto what it reached
    -- would name an archived intermediate or a forgery.
    terminal AS (
        SELECT d.duplicate_id, d.canonical_id
        FROM deepest d
        WHERE NOT d.cycled
          AND NOT EXISTS (
              SELECT 1 FROM merge_edge e WHERE e.duplicate_id = d.canonical_id
          )
    ),
    broken AS (
        SELECT d.duplicate_id
        FROM deepest d
        JOIN nodes n ON n.id = d.duplicate_id
        WHERE (d.cycled OR EXISTS (
                  SELECT 1 FROM merge_edge e WHERE e.duplicate_id = d.canonical_id
              ))
          AND n.archived_at IS NOT NULL
          AND n.external_id IS NOT NULL
          AND strpos(coalesce(n.external_source, ''), '.') > 0
    ),
    lost AS (
        SELECT t.canonical_id, n.id AS duplicate_id,
               n.external_source, n.external_id
        FROM terminal t
        JOIN nodes n ON n.id = t.duplicate_id
        WHERE n.archived_at IS NOT NULL
          AND n.external_id IS NOT NULL
          AND strpos(coalesce(n.external_source, ''), '.') > 0
    ),
    known_pairs AS (
        SELECT source_schema, source_table,
               source_schema || '.' || source_table AS ext,
               min(source_id_type) AS source_id_type
        FROM node_source_map
        GROUP BY source_schema, source_table
    ),
    candidate AS (
        SELECT l.canonical_id, l.duplicate_id,
               l.external_id AS source_id,
               kp.source_schema, kp.source_table,
               coalesce(kp.source_id_type, 'int') AS source_id_type,
               count(kp.ext) OVER (PARTITION BY l.duplicate_id) AS pair_matches
        FROM lost l
        LEFT JOIN known_pairs kp ON kp.ext = l.external_source
    ),
    unresolved AS (
        SELECT DISTINCT duplicate_id
        FROM candidate
        WHERE source_schema IS NULL OR pair_matches <> 1
        UNION
        SELECT duplicate_id FROM broken
    ),
    grouped AS (
        SELECT source_schema, source_table, source_id,
               count(DISTINCT canonical_id) AS canon_count,
               min(canonical_id::text) AS canonical_id,
               min(source_id_type) AS source_id_type
        FROM candidate
        WHERE source_schema IS NOT NULL AND pair_matches = 1
        GROUP BY source_schema, source_table, source_id
    ),
    settled AS (
        SELECT g.*, m.node_id AS mapped_node
        FROM grouped g
        LEFT JOIN node_source_map m
               ON m.source_schema = g.source_schema
              AND m.source_table  = g.source_table
              AND m.source_id     = g.source_id
        WHERE g.canon_count = 1
    ),
    restored AS (
        INSERT INTO node_source_map
            (node_id, source_schema, source_table, source_id, source_id_type)
        SELECT s.canonical_id::uuid, s.source_schema, s.source_table,
               s.source_id, s.source_id_type
        FROM settled s
        WHERE s.mapped_node IS NULL
        ON CONFLICT (source_schema, source_table, source_id) DO NOTHING
        RETURNING 1
    )
    SELECT jsonb_build_object(
        'restored',       (SELECT count(*) FROM restored),
        'already_mapped', (SELECT count(*) FROM settled
                            WHERE mapped_node IS NOT NULL
                              AND mapped_node::text = canonical_id),
        'occupied',       (SELECT count(*) FROM settled
                            WHERE mapped_node IS NOT NULL
                              AND mapped_node::text <> canonical_id),
        'ambiguous',      (SELECT count(*) FROM grouped WHERE canon_count > 1),
        'unresolved',     (SELECT count(*) FROM unresolved)
    )
    INTO v_report;

    RETURN v_report;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION rye_restore_merged_source_maps() IS
    'Re-create source mappings that a pre-0031 merge deleted, from node_merges plus the archived duplicate''s external_id/external_source. node_merges is untrusted: a row is followed only when its duplicate node is archived, the earliest row per duplicate wins, and a cycle stops the walk. Admin only, SECURITY INVOKER, re-runnable, and a no-op once every mapping is correct. Returns counts: restored, already_mapped, occupied (the source row maps to another node -- remedy with merge_nodes on it), ambiguous (two duplicates claim the row, merged to different canonicals), unresolved (external_source matched no surviving source table, or several).';

DO $$
DECLARE
    v_report jsonb;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    v_report := rye_restore_merged_source_maps();
    RAISE NOTICE '0031 source-map repair: %', v_report;
    IF (v_report->>'occupied')::bigint > 0
       OR (v_report->>'ambiguous')::bigint > 0
       OR (v_report->>'unresolved')::bigint > 0 THEN
        RAISE NOTICE '0031: some source rows were left alone; see the comment on rye_restore_merged_source_maps() for what each count means and what to do.';
    END IF;
END;
$$;

-- The role set at the top of this file is session-wide, because migrate.sh
-- gives each migration its own psql session and closes it. An operator who
-- pipes every migration into one session instead would carry admin into the
-- next file, so the file puts it back.
SELECT set_config('app.current_role', '', false);
