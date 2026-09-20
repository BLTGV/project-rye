-- A merge never costs a source row its graph identity.
--
-- Contract:  contracts/sql-surface.md, "Who may write" and "merge_nodes() is
--            for people"; AGENTS.md's overlay promise -- the graph points at
--            domain rows through node_source_map.
-- Work item: work/012-source-map-row-identity.md, superseding pull request 6.
-- Migration: schema/migrations/0031_source_map_row_identity.sql.
--
-- The defect this suite pins down: node_source_map was keyed
-- (node_id, source_schema, source_table), one mapping per source table per
-- node, so when a duplicate and its canonical both mapped rows of the same
-- table -- the ordinary dedup case -- merge_nodes() DELETEd the duplicate's
-- mapping instead of re-pointing it. The source row lost its graph identity
-- silently, and the next link_record() for it minted a fresh, empty node: the
-- merged duplicate came back with none of its edges, assertions, or history.
--
-- Negative control: without 0031 this suite fails at its first assertion,
-- because the primary key still names node_id.
--
-- What each block proves:
--   1. The key is the source row, and the 0026 write rules on the table are
--      all still there.
--   2. A merge re-points every mapping and deletes none; link_record() on the
--      merged source row returns the canonical node and creates nothing.
--   3. Change capture still resolves the node for a tracked row, before and
--      after a merge, on a real tracked table.
--   4. Everything 0026 added to merge_nodes() still holds on the definition
--      0031 carried forward, refusal by refusal, before any lock.
--   5. rye_restore_merged_source_maps() puts back what past merges dropped,
--      and each collision class does what its comment says.
--
-- Invented names only: Wren, Tobin, Marsh, Pell, Quill.

SET search_path = rye, public, pg_catalog;

BEGIN;

-- --------------------------------------------------------------------------
-- Anti-vacuity, as in tests/conformance/35_supporting_tables_rls.sql.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_bypass boolean;
    v_node   uuid;
    v_probe  uuid;
    v_role   text;
    v_seen   integer;
    v_super  boolean;
BEGIN
    SELECT rolsuper, rolbypassrls INTO v_super, v_bypass
    FROM pg_roles WHERE rolname = current_user;
    IF coalesce(v_super, false) OR coalesce(v_bypass, false) THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: % is rolsuper=% rolbypassrls=% and is not bound by RLS. Run this suite as scripts/conformance.sh and scripts/test-nonsuperuser-owner.sh do.',
            current_user, v_super, v_bypass;
    END IF;
    IF current_setting('row_security', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'Refusing to pass vacuously: row_security is %',
            current_setting('row_security', true);
    END IF;

    FOREACH v_role IN ARRAY ARRAY['agent:t', 'viewer', 'team_member', 'system:cdc', '', 'admin'] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION
                'Refusing to pass vacuously: app.current_role did not read back as "%", it reads "%"',
                v_role, current_setting('app.current_role', true);
        END IF;
    END LOOP;

    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:source-map-merge', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Wren', '{"suite":"source_map_merge"}')
    RETURNING id INTO v_node;
    v_probe := record_assertion(
        'compensation', '{"value":"rls probe"}', v_node,
        p_assertion_key := 'source_map_merge:probe', p_basis := 'assumed'
    );

    PERFORM set_config('app.current_role', 'viewer', true);
    SELECT count(*) INTO v_seen FROM assertions WHERE id = v_probe;
    IF v_seen <> 0 THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: a viewer can read a read-gated assertion type, so RLS is not in force';
    END IF;
    PERFORM set_config('app.current_role', 'admin', true);
END
$$;

-- --------------------------------------------------------------------------
-- 1. The key is the source row, and 0026's rules on the table are intact.
--
-- This block is the negative control: on a tree without 0031 the primary key
-- still names node_id and the first assertion fails.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_cols    text;
    v_failed  boolean;
    v_node_a  uuid;
    v_node_b  uuid;
    v_n       integer;
    v_state   text;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:source-map-merge', true);
    PERFORM set_config('app.current_teams', '', true);

    SELECT string_agg(a.attname, ',' ORDER BY k.ord)
    INTO v_cols
    FROM pg_constraint c
    JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.conrelid = 'node_source_map'::regclass AND c.contype = 'p';

    IF v_cols IS DISTINCT FROM 'source_schema,source_table,source_id' THEN
        RAISE EXCEPTION
            'node_source_map must be keyed by the source row, its primary key is (%)', v_cols;
    END IF;

    -- The reverse lookup the old primary key served has its own index.
    IF NOT EXISTS (
        SELECT 1 FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        WHERE i.indrelid = 'node_source_map'::regclass AND c.relname = 'idx_nsm_node'
    ) THEN
        RAISE EXCEPTION 'idx_nsm_node is missing: node_id has no index of its own';
    END IF;

    -- 0026 is untouched: three write policies with the conjunct, and the gate
    -- trigger that binds a SECURITY DEFINER helper where the policy does not.
    SELECT count(*) INTO v_n
    FROM pg_policies p
    WHERE p.schemaname = 'rye' AND p.tablename = 'node_source_map'
      AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE')
      AND (coalesce(p.qual, '') || coalesce(p.with_check, '')) LIKE '%rye_role_may_write%';
    IF v_n <> 3 THEN
        RAISE EXCEPTION
            'node_source_map has % write policies carrying rye_role_may_write, expected 3', v_n;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t
        WHERE t.tgrelid = 'node_source_map'::regclass
          AND t.tgname = 'trg_node_source_map_gate_may_write'
          AND NOT t.tgisinternal
          AND t.tgtype & 1 = 1 AND t.tgtype & 2 = 2 AND t.tgtype & 28 = 28
    ) THEN
        RAISE EXCEPTION 'trg_node_source_map_gate_may_write is missing or is the wrong shape';
    END IF;

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Pell', '{"suite":"source_map_merge"}') RETURNING id INTO v_node_a;
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Quill', '{"suite":"source_map_merge"}') RETURNING id INTO v_node_b;

    -- One node may hold several rows of one source table. That multiplicity
    -- is the point of the key change; the old key forbade it.
    INSERT INTO node_source_map (node_id, source_schema, source_table, source_id)
    VALUES (v_node_a, 'b012', 'key', '1'), (v_node_a, 'b012', 'key', '2');

    SELECT count(*) INTO v_n FROM node_source_map
    WHERE node_id = v_node_a AND source_schema = 'b012' AND source_table = 'key';
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'One node should hold 2 rows of one source table, it holds %', v_n;
    END IF;

    -- And one source row still names exactly one node.
    v_failed := false;
    BEGIN
        INSERT INTO node_source_map (node_id, source_schema, source_table, source_id)
        VALUES (v_node_b, 'b012', 'key', '1');
    EXCEPTION WHEN OTHERS THEN v_failed := true; v_state := SQLSTATE; END;
    IF NOT v_failed OR v_state <> '23505' THEN
        RAISE EXCEPTION
            'A source row was mapped to a second node (failed=%, sqlstate=%)', v_failed, v_state;
    END IF;
END
$$;

-- --------------------------------------------------------------------------
-- 2. A merge keeps every source row's identity.
--
-- Two rows of the SAME source table, linked as two nodes, then merged. Before
-- 0031 the second mapping was deleted and the next link_record() minted a
-- fresh node.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_canon    uuid;
    v_dup      uuid;
    v_resolved uuid;
    v_maps     integer;
    v_live     integer;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    v_canon := link_record('b012', 'core', '1', 'person', 'Wren Original');
    v_dup   := link_record('b012', 'core', '2', 'person', 'Wren Duplicate');
    IF v_canon = v_dup THEN
        RAISE EXCEPTION 'Premise broken: distinct source rows linked to one node';
    END IF;

    PERFORM merge_nodes(v_dup, v_canon, 'test:source-map-merge');

    SELECT count(*) INTO v_maps FROM node_source_map
    WHERE node_id = v_canon AND source_schema = 'b012' AND source_table = 'core'
      AND source_id IN ('1', '2');
    IF v_maps <> 2 THEN
        RAISE EXCEPTION
            'The canonical node should carry both source mappings, it carries %', v_maps;
    END IF;

    IF EXISTS (SELECT 1 FROM node_source_map WHERE node_id = v_dup) THEN
        RAISE EXCEPTION 'The duplicate still carries a source mapping after the merge';
    END IF;

    -- Nothing was deleted: both rows of the table are still mapped.
    SELECT count(*) INTO v_maps FROM node_source_map
    WHERE source_schema = 'b012' AND source_table = 'core';
    IF v_maps <> 2 THEN
        RAISE EXCEPTION 'The source table has % mappings, expected 2', v_maps;
    END IF;

    -- The merged source row resolves to the canonical node, and nothing new
    -- is created. This is the resurrection the old key caused.
    v_resolved := link_record('b012', 'core', '2', 'person', 'Wren Duplicate');
    IF v_resolved <> v_canon THEN
        RAISE EXCEPTION
            'link_record resurrected the merged duplicate: got %, expected %', v_resolved, v_canon;
    END IF;

    SELECT count(*) INTO v_live FROM nodes
    WHERE external_source = 'b012.core' AND archived_at IS NULL;
    IF v_live <> 1 THEN
        RAISE EXCEPTION
            'Expected exactly 1 live node for the merged source rows, got %', v_live;
    END IF;

    IF (SELECT archived_at FROM nodes WHERE id = v_dup) IS NULL THEN
        RAISE EXCEPTION 'The duplicate was not archived';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM node_merges
        WHERE duplicate_id = v_dup AND canonical_id = v_canon
    ) THEN
        RAISE EXCEPTION 'The merge left no record in node_merges';
    END IF;
END
$$;

-- --------------------------------------------------------------------------
-- 3. Change capture still resolves the node, before and after a merge.
--
-- capture_domain_change() looks a tracked row up by
-- (source_schema, source_table, source_id), which is exactly the new key. The
-- tracked table is a temporary one, because this suite runs as a test role
-- with no CREATE on public; tests/conformance/07_domain_integration.sh covers
-- the ordinary case on a real table.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_schema text;
    v_canon  uuid;
    v_dup    uuid;
    v_before integer;
    v_after  integer;
    v_dup_ev integer;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    CREATE TEMP TABLE b012_tracked (id int PRIMARY KEY, note text) ON COMMIT DROP;
    SELECT nspname INTO v_schema FROM pg_namespace WHERE oid = pg_my_temp_schema();
    IF v_schema IS NULL THEN
        RAISE EXCEPTION 'Premise broken: no temporary schema for the tracked table';
    END IF;

    INSERT INTO b012_tracked (id, note) VALUES (1, 'canonical row'), (2, 'duplicate row');

    v_canon := link_record(v_schema, 'b012_tracked', '1', 'person', 'Tobin Canonical');
    v_dup   := link_record(v_schema, 'b012_tracked', '2', 'person', 'Tobin Duplicate');

    PERFORM track_table(v_schema, 'b012_tracked');

    -- Before the merge: a change on row 2 attaches to the duplicate's node.
    UPDATE b012_tracked SET note = 'before the merge' WHERE id = 2;
    SELECT count(*) INTO v_before
    FROM events e JOIN event_participants ep ON ep.event_id = e.id
    WHERE ep.node_id = v_dup AND e.event_type = 'domain_change';
    IF v_before <> 1 THEN
        RAISE EXCEPTION
            'Change capture did not resolve the tracked row before the merge (% events)', v_before;
    END IF;

    PERFORM merge_nodes(v_dup, v_canon, 'test:source-map-merge');

    -- After the merge: the same row's next change attaches to the canonical
    -- node, because its mapping was re-pointed rather than deleted.
    SELECT count(*) INTO v_before
    FROM events e JOIN event_participants ep ON ep.event_id = e.id
    WHERE ep.node_id = v_canon AND e.event_type = 'domain_change';

    UPDATE b012_tracked SET note = 'after the merge' WHERE id = 2;

    SELECT count(*) INTO v_after
    FROM events e JOIN event_participants ep ON ep.event_id = e.id
    WHERE ep.node_id = v_canon AND e.event_type = 'domain_change';
    IF v_after <> v_before + 1 THEN
        RAISE EXCEPTION
            'A merged row''s later domain write recorded % new events on the canonical node, expected 1',
            v_after - v_before;
    END IF;

    SELECT count(*) INTO v_dup_ev
    FROM event_participants WHERE node_id = v_dup;
    IF v_dup_ev <> 0 THEN
        RAISE EXCEPTION
            'The archived duplicate still holds % event participations', v_dup_ev;
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    EXECUTE format('DROP TRIGGER rye_cdc_b012_tracked ON %I.b012_tracked', v_schema);
END
$$;

-- --------------------------------------------------------------------------
-- 4. Everything 0026 added to merge_nodes() still holds.
--
-- The definition 0031 carries forward is 0026's, with the source-map block as
-- its only edit, so every refusal still comes before the first FOR UPDATE.
-- Asserted by message, because the message is what proves the order: reaching
-- the lock under a role RLS filters gives "Duplicate node % not found"
-- instead.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_canon   uuid;
    v_dup     uuid;
    v_scope   uuid;
    v_plain_a uuid;
    v_plain_b uuid;
    v_role    text;
    v_failed  boolean;
    v_state   text;
    v_msg     text;
    v_want    text;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Marsh Canonical', '{"suite":"source_map_merge"}') RETURNING id INTO v_canon;
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Marsh Duplicate', '{"suite":"source_map_merge"}') RETURNING id INTO v_dup;

    FOREACH v_role IN ARRAY ARRAY['viewer', '', 'agent:t', 'system:cdc'] LOOP
        v_want := CASE
            WHEN v_role IN ('viewer', '') THEN '%may only read%'
            WHEN v_role = 'agent:t'       THEN '%not available to an agent%'
            ELSE '%not available to system:cdc%'
        END;

        PERFORM set_config('app.current_role', v_role, true);
        v_failed := false;
        BEGIN
            PERFORM merge_nodes(v_dup, v_canon, 'test:source-map-merge');
        EXCEPTION WHEN OTHERS THEN
            v_failed := true; v_state := SQLSTATE; v_msg := SQLERRM;
        END;
        IF NOT v_failed OR v_state <> '42501' OR v_msg NOT LIKE v_want THEN
            RAISE EXCEPTION
                'Role "%" was not refused the merge as 0026 requires (failed=%, sqlstate=%, message=%)',
                v_role, v_failed, v_state, v_msg;
        END IF;

        PERFORM set_config('app.current_role', 'admin', true);
        IF (SELECT archived_at FROM nodes WHERE id = v_dup) IS NOT NULL THEN
            RAISE EXCEPTION 'Role "%" archived the duplicate anyway', v_role;
        END IF;
        IF EXISTS (SELECT 1 FROM node_merges WHERE duplicate_id = v_dup) THEN
            RAISE EXCEPTION 'Role "%" recorded a merge anyway', v_role;
        END IF;
    END LOOP;

    -- A non-admin may not merge a node the governance structure touches.
    INSERT INTO nodes (node_type, label, attrs, properties)
    VALUES ('onboarding_scope', 'Source map suite scope', '{}',
            '{"suite":"source_map_merge"}')
    RETURNING id INTO v_scope;
    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES ('scope_governs_subject', v_scope, v_dup, '{"suite":"source_map_merge"}');

    PERFORM set_config('app.current_role', 'team_member', true);
    v_failed := false;
    BEGIN
        PERFORM merge_nodes(v_dup, v_canon, 'test:source-map-merge');
    EXCEPTION WHEN OTHERS THEN
        v_failed := true; v_state := SQLSTATE; v_msg := SQLERRM;
    END;
    IF NOT v_failed OR v_state <> '42501' OR v_msg NOT LIKE '%requires a Rye admin%' THEN
        RAISE EXCEPTION
            'A team_member merged a governed node (failed=%, sqlstate=%, message=%)',
            v_failed, v_state, v_msg;
    END IF;

    -- Anti-vacuity: a team_member still merges an ordinary pair, and the
    -- source mappings still travel.
    PERFORM set_config('app.current_role', 'admin', true);
    v_plain_a := link_record('b012', 'plain', '1', 'person', 'Marsh Plain A');
    v_plain_b := link_record('b012', 'plain', '2', 'person', 'Marsh Plain B');

    PERFORM set_config('app.current_role', 'team_member', true);
    PERFORM merge_nodes(v_plain_b, v_plain_a, 'test:source-map-merge');

    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT count(*) FROM node_source_map
        WHERE node_id = v_plain_a AND source_schema = 'b012' AND source_table = 'plain') <> 2 THEN
        RAISE EXCEPTION 'A team_member merge did not carry both source mappings';
    END IF;
END
$$;

-- --------------------------------------------------------------------------
-- 5. rye_restore_merged_source_maps(): what happens to each collision.
--
-- Four source rows, one per class the function distinguishes. Each is built
-- by reproducing the pre-0031 state exactly: merge, then delete the mapping
-- the old merge_nodes() would have deleted.
--
-- The counts are compared as deltas, because a conformance database carries
-- whatever earlier suites committed.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_base     jsonb;
    v_report   jsonb;
    v_canon    uuid;
    v_canon2   uuid;
    v_lost     uuid;
    v_occupied uuid;
    v_resurr   uuid;
    v_ghost    uuid;
    v_ambi_a   uuid;
    v_ambi_b   uuid;
    v_mapped   uuid;
    v_failed   boolean;
    v_state    text;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    -- A repair is for people: no other role may run it.
    PERFORM set_config('app.current_role', 'team_member', true);
    v_failed := false;
    BEGIN
        PERFORM rye_restore_merged_source_maps();
    EXCEPTION WHEN OTHERS THEN v_failed := true; v_state := SQLSTATE; END;
    IF NOT v_failed OR v_state <> '42501' THEN
        RAISE EXCEPTION
            'A team_member ran the source-map repair (failed=%, sqlstate=%)', v_failed, v_state;
    END IF;
    PERFORM set_config('app.current_role', 'admin', true);

    -- Drain anything earlier suites left, twice, so the baseline is stable
    -- and the second call proves the function is a no-op to re-run.
    PERFORM rye_restore_merged_source_maps();
    v_base := rye_restore_merged_source_maps();
    IF (v_base->>'restored')::bigint <> 0 THEN
        RAISE EXCEPTION
            'The repair is not idempotent: a second run restored % mappings',
            v_base->>'restored';
    END IF;

    v_canon  := link_record('b012', 'repair', '1', 'person', 'Wren Repair Canonical');
    v_canon2 := link_record('b012', 'repair', '8', 'person', 'Wren Repair Other');

    -- (a) restored: the mapping is gone and the source row is unclaimed.
    v_lost := link_record('b012', 'repair', '2', 'person', 'Wren Lost');
    PERFORM merge_nodes(v_lost, v_canon, 'test:source-map-merge');
    DELETE FROM node_source_map
    WHERE source_schema = 'b012' AND source_table = 'repair' AND source_id = '2';

    -- (b) occupied: the old bug's aftermath -- the source row was re-linked
    -- after the lossy merge and now names a resurrected node.
    v_occupied := link_record('b012', 'repair', '3', 'person', 'Wren Occupied');
    PERFORM merge_nodes(v_occupied, v_canon, 'test:source-map-merge');
    DELETE FROM node_source_map
    WHERE source_schema = 'b012' AND source_table = 'repair' AND source_id = '3';
    v_resurr := link_record('b012', 'repair', '3', 'person', 'Wren Resurrected');
    IF v_resurr = v_canon OR v_resurr = v_occupied THEN
        RAISE EXCEPTION
            'Premise broken: the lossy state did not resurrect a fresh node for source row 3';
    END IF;

    -- (c) ambiguous: two archived duplicates claim source row 7, merged into
    -- different canonicals.
    v_ambi_a := link_record('b012', 'repair', '7', 'person', 'Wren Ambiguous One');
    PERFORM merge_nodes(v_ambi_a, v_canon, 'test:source-map-merge');
    DELETE FROM node_source_map
    WHERE source_schema = 'b012' AND source_table = 'repair' AND source_id = '7';
    v_ambi_b := link_record('b012', 'repair', '7', 'person', 'Wren Ambiguous Two');
    PERFORM merge_nodes(v_ambi_b, v_canon2, 'test:source-map-merge');
    DELETE FROM node_source_map
    WHERE source_schema = 'b012' AND source_table = 'repair' AND source_id = '7';

    -- (d) unresolved: no surviving mapping names the (schema, table) pair, so
    -- external_source cannot be split back into one safely.
    v_ghost := link_record('b012ghost', 'rows', '9', 'person', 'Wren Ghost');
    PERFORM merge_nodes(v_ghost, v_canon, 'test:source-map-merge');
    DELETE FROM node_source_map
    WHERE source_schema = 'b012ghost' AND source_table = 'rows';

    v_report := rye_restore_merged_source_maps();

    IF (v_report->>'restored')::bigint - (v_base->>'restored')::bigint <> 1 THEN
        RAISE EXCEPTION 'The repair restored % mappings, expected 1: %',
            (v_report->>'restored')::bigint - (v_base->>'restored')::bigint, v_report;
    END IF;
    IF (v_report->>'occupied')::bigint - (v_base->>'occupied')::bigint <> 1 THEN
        RAISE EXCEPTION 'The repair reported % occupied source rows, expected 1: %',
            (v_report->>'occupied')::bigint - (v_base->>'occupied')::bigint, v_report;
    END IF;
    IF (v_report->>'ambiguous')::bigint - (v_base->>'ambiguous')::bigint <> 1 THEN
        RAISE EXCEPTION 'The repair reported % ambiguous source rows, expected 1: %',
            (v_report->>'ambiguous')::bigint - (v_base->>'ambiguous')::bigint, v_report;
    END IF;
    IF (v_report->>'unresolved')::bigint - (v_base->>'unresolved')::bigint <> 1 THEN
        RAISE EXCEPTION 'The repair reported % unresolved duplicates, expected 1: %',
            (v_report->>'unresolved')::bigint - (v_base->>'unresolved')::bigint, v_report;
    END IF;

    -- (a) the mapping is back, on the terminal canonical.
    SELECT node_id INTO v_mapped FROM node_source_map
    WHERE source_schema = 'b012' AND source_table = 'repair' AND source_id = '2';
    IF v_mapped IS DISTINCT FROM v_canon THEN
        RAISE EXCEPTION 'Source row 2 maps to % after the repair, expected %', v_mapped, v_canon;
    END IF;
    -- And link_record() on it no longer mints anything.
    IF link_record('b012', 'repair', '2', 'person', 'Wren Lost') <> v_canon THEN
        RAISE EXCEPTION 'The restored mapping did not stop the resurrection';
    END IF;

    -- (b) nothing was re-pointed silently; merge_nodes() is the remedy, and
    -- it now carries the mapping instead of deleting it.
    SELECT node_id INTO v_mapped FROM node_source_map
    WHERE source_schema = 'b012' AND source_table = 'repair' AND source_id = '3';
    IF v_mapped IS DISTINCT FROM v_resurr THEN
        RAISE EXCEPTION
            'The repair re-pointed an occupied source row: 3 maps to %, expected %', v_mapped, v_resurr;
    END IF;
    PERFORM merge_nodes(v_resurr, v_canon, 'test:source-map-merge');
    SELECT node_id INTO v_mapped FROM node_source_map
    WHERE source_schema = 'b012' AND source_table = 'repair' AND source_id = '3';
    IF v_mapped IS DISTINCT FROM v_canon THEN
        RAISE EXCEPTION
            'merge_nodes did not remedy the occupied source row: 3 maps to %, expected %',
            v_mapped, v_canon;
    END IF;

    -- (c) and (d) were left alone, and said so.
    IF EXISTS (
        SELECT 1 FROM node_source_map
        WHERE source_schema = 'b012' AND source_table = 'repair' AND source_id = '7'
    ) THEN
        RAISE EXCEPTION 'The repair guessed at an ambiguous source row';
    END IF;
    IF EXISTS (
        SELECT 1 FROM node_source_map WHERE source_schema = 'b012ghost'
    ) THEN
        RAISE EXCEPTION 'The repair guessed at an unresolved source row';
    END IF;

    -- Re-running settles: what it restored is already_mapped now, and nothing
    -- new is restored.
    v_report := rye_restore_merged_source_maps();
    IF (v_report->>'restored')::bigint <> 0 THEN
        RAISE EXCEPTION 'A second repair restored % mappings: %',
            v_report->>'restored', v_report;
    END IF;
END
$$;

-- --------------------------------------------------------------------------
-- 6. node_merges is untrusted evidence.
--
-- Its insert policy (0029) asks only that the role may write, so any writing
-- session can plant a row for a merge that never happened. The repair walks
-- that table to decide where a lost mapping belongs, so it follows a row only
-- when the duplicate node is actually archived, and takes the earliest row per
-- duplicate rather than the latest.
--
-- The forged rows are planted as an ordinary writing role, which is what main
-- still allows. work/014 adds an insert guard in migration 0033; if the guard
-- is present the plant is refused, and this block says so and stops rather
-- than asserting about a row that does not exist.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_canon    uuid;
    v_decoy    uuid;
    v_lost     uuid;
    v_live     uuid;
    v_mapped   uuid;
    v_alive    boolean;
    v_guarded  boolean := false;
    v_report   jsonb;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    v_canon := link_record('b012', 'forge', '1', 'person', 'Marsh Forge Canonical');
    v_decoy := link_record('b012', 'forge', '9', 'person', 'Marsh Forge Decoy');

    -- One real merge, then its mapping is lost the way the old key lost it.
    v_lost := link_record('b012', 'forge', '2', 'person', 'Marsh Forge Lost');
    PERFORM merge_nodes(v_lost, v_canon, 'test:source-map-merge');
    DELETE FROM node_source_map
    WHERE source_schema = 'b012' AND source_table = 'forge' AND source_id = '2';

    -- The forgery: the canonical node is alive and was never merged, but a
    -- row says it was. Following it would put the lost mapping on the decoy.
    BEGIN
        INSERT INTO node_merges (duplicate_id, canonical_id, merged_by)
        VALUES (v_canon, v_decoy, 'forged');
    EXCEPTION WHEN OTHERS THEN
        v_guarded := true;
    END;

    IF v_guarded THEN
        RAISE NOTICE
            'node_merges now refuses a forged row; the repair''s own untrusted-evidence rules are unchanged and untested here';
        RETURN;
    END IF;

    -- A second forged row on a real duplicate, dated later, pointing
    -- elsewhere: the earliest row per duplicate has to win.
    INSERT INTO node_merges (duplicate_id, canonical_id, merged_at, merged_by)
    VALUES (v_lost, v_decoy, now() + interval '1 day', 'forged');

    v_report := rye_restore_merged_source_maps();

    SELECT node_id INTO v_mapped FROM node_source_map
    WHERE source_schema = 'b012' AND source_table = 'forge' AND source_id = '2';

    IF v_mapped IS NULL THEN
        RAISE EXCEPTION 'The repair did not restore the real merge''s mapping: %', v_report;
    END IF;
    IF v_mapped = v_decoy THEN
        RAISE EXCEPTION
            'A forged node_merges row redirected the repair: source row 2 maps to the decoy %', v_decoy;
    END IF;
    IF v_mapped IS DISTINCT FROM v_canon THEN
        RAISE EXCEPTION
            'Source row 2 maps to % after the repair, expected the real canonical %',
            v_mapped, v_canon;
    END IF;

    -- The forged row named a node that is still live, so nothing about it
    -- moved: it is not archived and it keeps its own mapping.
    SELECT archived_at IS NULL INTO v_alive FROM nodes WHERE id = v_canon;
    IF NOT v_alive THEN
        RAISE EXCEPTION 'The forged row archived a live node';
    END IF;
    SELECT node_id INTO v_live FROM node_source_map
    WHERE source_schema = 'b012' AND source_table = 'forge' AND source_id = '1';
    IF v_live IS DISTINCT FROM v_canon THEN
        RAISE EXCEPTION
            'A forged row re-pointed a live node''s own mapping: 1 maps to %', v_live;
    END IF;

    RAISE NOTICE
        'Forged node_merges rows ignored: source row 2 restored to the real canonical, report %',
        v_report;
END
$$;

DO $$
BEGIN
    RAISE NOTICE 'Source-map row identity: every obligation passed';
END
$$;

SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

ROLLBACK;
