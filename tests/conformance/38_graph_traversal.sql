-- Graph traversal (migration 0032): entry-point search, typed multi-hop
-- paths, depth ceiling, temporal edges, cycle safety, neighborhood budgets,
-- and the promise that none of it writes. RLS pruning is covered separately
-- in tests/security/03_traversal_visibility.sql.
--
-- Contract:  contracts/sql-surface.md; design/proposals/rls-visibility-contract.md, D1.
-- Work item: work/013-graph-traversal.md (ports pull request 19).
-- Migration: schema/migrations/0032_graph_traversal.sql.
--
-- Negative control: without 0032 this suite fails on its first assertion,
-- because find_nodes, find_nodes_batch, find_paths, neighborhood, and
-- edge_semantics do not exist.
--
-- Invented names only.

SET search_path = rye, public, pg_catalog;

BEGIN;

-- --------------------------------------------------------------------------
-- Anti-vacuity, as in tests/conformance/34_gated_type_alias.sql and
-- tests/conformance/35_supporting_tables_rls.sql. A session that bypasses RLS
-- would make the viewer and role-less legs below prove nothing.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_bypass boolean;
    v_role   text;
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

    FOREACH v_role IN ARRAY ARRAY['viewer', '', 'admin'] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION
                'Refusing to pass vacuously: app.current_role did not read back as "%", it reads "%"',
                v_role, current_setting('app.current_role', true);
        END IF;
    END LOOP;
END
$$;

-- --------------------------------------------------------------------------
-- The catalog half of the read-only promise.
--
-- D1: traversal is never SECURITY DEFINER. Asserted against pg_proc, not a
-- grep, so it cannot be defeated by formatting.
--
-- Work item 013: "none writes, and the suite proves it". STABLE is the
-- catalog statement of that -- PostgreSQL refuses to execute an INSERT,
-- UPDATE, or DELETE inside a non-VOLATILE function -- and every function
-- carries its own search_path, which the area invariant requires.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_bad     text;
    v_missing text;
BEGIN
    SELECT string_agg(required.name, ', ' ORDER BY required.name)
    INTO v_missing
    FROM (VALUES ('find_nodes'), ('find_nodes_batch'), ('find_paths'),
                 ('neighborhood'), ('edge_semantics')) required(name)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'rye' AND p.proname = required.name
    );
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 0032 has not been applied: missing %', v_missing;
    END IF;

    SELECT string_agg(p.proname, ', ' ORDER BY p.proname)
    INTO v_bad
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'rye'
      AND p.proname IN ('find_nodes', 'find_nodes_batch', 'find_paths',
                        'neighborhood', 'edge_semantics')
      AND p.prosecdef;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'traversal functions must be SECURITY INVOKER, found definer: %', v_bad;
    END IF;
    RAISE NOTICE 'PASS: traversal functions are SECURITY INVOKER';

    SELECT string_agg(p.proname || '=' || p.provolatile::text, ', ' ORDER BY p.proname)
    INTO v_bad
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'rye'
      AND p.proname IN ('find_nodes', 'find_nodes_batch', 'find_paths',
                        'neighborhood', 'edge_semantics')
      AND p.provolatile = 'v';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'traversal functions must not be VOLATILE; a VOLATILE function may write: %', v_bad;
    END IF;
    RAISE NOTICE 'PASS: traversal functions are non-VOLATILE, so they cannot write';

    SELECT string_agg(p.proname, ', ' ORDER BY p.proname)
    INTO v_bad
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'rye'
      AND p.proname IN ('find_nodes', 'find_nodes_batch', 'find_paths',
                        'neighborhood', 'edge_semantics')
      AND NOT EXISTS (
          SELECT 1 FROM unnest(coalesce(p.proconfig, '{}'::text[])) c
          WHERE c LIKE 'search_path=%'
      );
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'traversal functions must declare their own search_path: %', v_bad;
    END IF;
    RAISE NOTICE 'PASS: traversal functions declare their own search_path';
END
$$;

-- --------------------------------------------------------------------------
-- Behaviour.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_after   bigint[];
    v_as_of   timestamptz;
    v_before  bigint[];
    v_cand    uuid;
    v_causal  int;
    v_depth   int;
    v_ext     uuid;
    v_hidden  int;
    v_n1      uuid;
    v_n2      uuid;
    v_n3      uuid;
    v_n4      uuid;
    v_n5      uuid;
    v_nb      jsonb;
    v_reason  text;
    v_role    text;
    v_rows    int;
    v_score   numeric;
    v_sup     uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:graph-traversal', true);
    PERFORM set_config('app.current_teams', '', true);

    -- ------------------------------------------------------------------
    -- Fixture: a causal chain, one associative branch, and a cycle back.
    -- No classification anywhere, so nothing here can pass vacuously by
    -- being invisible to the roles exercised below.
    -- ------------------------------------------------------------------
    INSERT INTO nodes (node_type, label, external_id, external_source, properties) VALUES
        ('thing', 'Trav Warehouse',  'TRAV-EXT-1', 'traversal_suite', '{}'),
        ('thing', 'Trav Supplier',   NULL, NULL, '{}'),
        ('thing', 'Trav Release',    NULL, NULL, '{}'),
        ('thing', 'Trav Conversion', NULL, NULL, '{}'),
        ('thing', 'Trav Sidebar',    NULL, NULL, '{"trav_marker":"qqzzxx-traversal"}');

    SELECT id INTO v_n1 FROM nodes WHERE label = 'Trav Warehouse'  ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_n2 FROM nodes WHERE label = 'Trav Supplier'   ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_n3 FROM nodes WHERE label = 'Trav Release'    ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_n4 FROM nodes WHERE label = 'Trav Conversion' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_n5 FROM nodes WHERE label = 'Trav Sidebar'    ORDER BY created_at DESC LIMIT 1;

    INSERT INTO edges (edge_type, source_id, target_id) VALUES
        ('blocks',    v_n1, v_n2),
        ('blocks',    v_n2, v_n3),
        ('blocks',    v_n3, v_n4),
        ('regarding', v_n1, v_n5),
        ('blocks',    v_n4, v_n1);   -- closes a cycle

    -- ------------------------------------------------------------------
    -- Depth ceiling: registry max_path_depth is 3, so a request for 9
    -- clamps rather than expanding.
    -- ------------------------------------------------------------------
    SELECT max(depth) INTO v_depth
    FROM find_paths(v_n1, p_max_depth := 9);

    IF v_depth IS DISTINCT FROM 3 THEN
        RAISE EXCEPTION 'depth ceiling not enforced (max depth returned %)', v_depth;
    END IF;
    RAISE NOTICE 'PASS: max_path_depth clamps an over-large request';

    -- A smaller request is honored.
    SELECT max(depth) INTO v_depth FROM find_paths(v_n1, p_max_depth := 1);
    IF v_depth IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'explicit smaller depth not honored (got %)', v_depth;
    END IF;
    RAISE NOTICE 'PASS: caller may request less depth than the ceiling';

    -- ------------------------------------------------------------------
    -- Cycle safety: the walk terminates and no path revisits a node.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_rows
    FROM find_paths(v_n1, p_max_depth := 3) p
    WHERE cardinality(p.node_path) <> cardinality(ARRAY(SELECT DISTINCT unnest(p.node_path)));

    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'cycle guard failed: % paths revisit a node', v_rows;
    END IF;
    RAISE NOTICE 'PASS: cycles terminate and paths never revisit a node';

    -- ------------------------------------------------------------------
    -- Target filtering: a 3-hop causal chain resolves end to end.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_rows FROM find_paths(v_n1, v_n4, p_max_depth := 3);
    IF v_rows < 1 THEN
        RAISE EXCEPTION 'three-hop path from warehouse to conversion not found';
    END IF;
    RAISE NOTICE 'PASS: multi-hop path resolves to an explicit target';

    -- ------------------------------------------------------------------
    -- Semantics: causal filtering excludes the associative branch, and an
    -- unregistered edge type is treated as associative.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_causal
    FROM find_paths(v_n1, v_n5, p_max_depth := 3, p_semantics := ARRAY['causal']);
    IF v_causal <> 0 THEN
        RAISE EXCEPTION 'associative edge leaked into a causal-only traversal';
    END IF;

    SELECT count(*) INTO v_rows
    FROM find_paths(v_n1, v_n5, p_max_depth := 3, p_semantics := ARRAY['associative']);
    IF v_rows < 1 THEN
        RAISE EXCEPTION 'associative traversal did not find the regarding edge';
    END IF;
    RAISE NOTICE 'PASS: causal traversal excludes associative edges';

    IF edge_semantics('blocks') <> 'causal' THEN
        RAISE EXCEPTION
            'the core edge vocabulary did not land: blocks resolves to %, not causal',
            edge_semantics('blocks');
    END IF;
    IF edge_semantics('trav_never_registered') <> 'associative' THEN
        RAISE EXCEPTION 'unregistered edge type must default to associative';
    END IF;
    RAISE NOTICE 'PASS: registered edge types resolve and unregistered ones default to associative';

    -- ------------------------------------------------------------------
    -- Temporal edges: an expired edge drops out at now() and reappears
    -- for an as_of inside its window.
    -- ------------------------------------------------------------------
    v_as_of := now() - interval '2 days';

    UPDATE edges
    SET effective_to = now() - interval '1 day'
    WHERE source_id = v_n1 AND target_id = v_n2 AND edge_type = 'blocks';

    SELECT count(*) INTO v_rows FROM find_paths(v_n1, v_n2, p_max_depth := 1);
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'expired edge still traversed at now()';
    END IF;

    SELECT count(*) INTO v_rows
    FROM find_paths(v_n1, v_n2, p_max_depth := 1, p_as_of := v_as_of);
    IF v_rows < 1 THEN
        RAISE EXCEPTION 'expired edge not traversed for an as_of inside its window';
    END IF;
    RAISE NOTICE 'PASS: traversal respects edge effective windows and as_of';

    UPDATE edges
    SET effective_to = NULL
    WHERE source_id = v_n1 AND target_id = v_n2 AND edge_type = 'blocks';

    -- ------------------------------------------------------------------
    -- Direction: 'out' follows edge direction, 'in' reverses it.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_rows
    FROM find_paths(v_n2, v_n1, p_max_depth := 1, p_direction := 'out');
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'outbound traversal walked an edge backwards';
    END IF;

    SELECT count(*) INTO v_rows
    FROM find_paths(v_n2, v_n1, p_max_depth := 1, p_direction := 'in');
    IF v_rows < 1 THEN
        RAISE EXCEPTION 'inbound traversal did not reverse the edge';
    END IF;
    RAISE NOTICE 'PASS: p_direction controls edge orientation';

    -- ------------------------------------------------------------------
    -- find_nodes: exact external identity outranks fuzzy label matching.
    -- ------------------------------------------------------------------
    SELECT f.node_id, f.score, f.match_reason
    INTO v_ext, v_score, v_reason
    FROM find_nodes('TRAV-EXT-1') f
    LIMIT 1;

    IF v_ext IS DISTINCT FROM v_n1 OR v_reason <> 'external_id' OR v_score <> 1.00 THEN
        RAISE EXCEPTION 'external_id match did not rank first (id %, reason %, score %)',
            v_ext, v_reason, v_score;
    END IF;
    RAISE NOTICE 'PASS: exact external identity ranks above fuzzy matches';

    SELECT count(*) INTO v_rows FROM find_nodes('Trav Warehouse');
    IF v_rows < 1 THEN
        RAISE EXCEPTION 'exact label lookup returned nothing';
    END IF;

    SELECT count(*) INTO v_rows FROM find_nodes('Trav Warehouse', ARRAY['person']);
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'node_type filter ignored';
    END IF;
    RAISE NOTICE 'PASS: find_nodes honors the node_type filter';

    -- Property values are never searched: field_classifications redacts
    -- individual property paths, so a hit would confirm the contents of a
    -- field the caller may not be allowed to read.
    SELECT count(*) INTO v_hidden FROM find_nodes('qqzzxx-traversal');
    IF v_hidden <> 0 THEN
        RAISE EXCEPTION 'find_nodes matched a property value; redaction can be inferred';
    END IF;
    RAISE NOTICE 'PASS: find_nodes does not search property values';

    -- ------------------------------------------------------------------
    -- Batch search: an agent's reformulations in one round trip, each
    -- attributed to the query that produced it.
    -- ------------------------------------------------------------------
    SELECT count(DISTINCT b.query) INTO v_rows
    FROM find_nodes_batch(ARRAY['Trav Warehouse', 'Trav Conversion'], NULL, 5) b;
    IF v_rows <> 2 THEN
        RAISE EXCEPTION 'batch search did not attribute results to both queries (got %)', v_rows;
    END IF;

    SELECT count(*) INTO v_rows
    FROM find_nodes_batch(ARRAY['Trav Warehouse'], NULL, 5) b
    WHERE b.query <> 'Trav Warehouse';
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'batch search mislabeled the originating query';
    END IF;
    RAISE NOTICE 'PASS: batch search attributes results per query';

    -- Blank and duplicate entries are dropped, not treated as wildcards.
    SELECT count(DISTINCT b.query) INTO v_rows
    FROM find_nodes_batch(ARRAY['Trav Warehouse', '  ', 'Trav Warehouse'], NULL, 5) b;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'batch search did not normalize blank/duplicate queries (got %)', v_rows;
    END IF;
    RAISE NOTICE 'PASS: batch search drops blank and duplicate queries';

    -- The limit is per query, not across the batch.
    SELECT count(*) INTO v_rows
    FROM find_nodes_batch(ARRAY['Trav', 'Vis'], NULL, 1) b;
    IF v_rows > 2 THEN
        RAISE EXCEPTION 'per-query limit leaked across the batch (got % rows)', v_rows;
    END IF;
    RAISE NOTICE 'PASS: batch limit applies per query';

    -- Single-query form agrees with the batch form.
    SELECT count(*) INTO v_rows
    FROM find_nodes('Trav Warehouse') f
    FULL JOIN find_nodes_batch(ARRAY['Trav Warehouse'], NULL, 20) b
      ON b.node_id = f.node_id
    WHERE f.node_id IS NULL OR b.node_id IS NULL;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'find_nodes disagrees with find_nodes_batch';
    END IF;
    RAISE NOTICE 'PASS: find_nodes matches its batch form';

    -- ------------------------------------------------------------------
    -- The threshold is a per-call argument, not fixed policy: the agent
    -- owns semantic matching and needs the dial.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_rows FROM find_nodes('Trav Warehosue', p_threshold := 0.35);
    IF v_rows < 1 THEN
        RAISE EXCEPTION 'transposed label not found at a permissive threshold';
    END IF;

    SELECT count(*) INTO v_rows FROM find_nodes('Trav Warehosue', p_threshold := 0.95);
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'per-call threshold was ignored (% rows at 0.95)', v_rows;
    END IF;
    RAISE NOTICE 'PASS: per-call threshold overrides the registry default';

    -- Empty input is not a wildcard.
    SELECT count(*) INTO v_rows FROM find_nodes('   ');
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'blank query behaved as a wildcard';
    END IF;
    RAISE NOTICE 'PASS: blank query returns nothing';

    -- ------------------------------------------------------------------
    -- neighborhood: budget, truncation flag, and attached knowledge.
    -- ------------------------------------------------------------------
    PERFORM record_assertion(
        p_assertion_type := 'trav_state',
        p_claim := '{"state":"degraded"}',
        p_subject_node_id := v_n2,
        p_basis := 'assumed'
    );

    v_nb := neighborhood(v_n1, p_max_depth := 3, p_max_nodes := 2);
    IF (v_nb->>'truncated')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'neighborhood did not report hitting its node budget';
    END IF;
    IF (v_nb->>'node_count')::int <> 2 THEN
        RAISE EXCEPTION 'neighborhood exceeded its node budget (got %)', v_nb->>'node_count';
    END IF;
    RAISE NOTICE 'PASS: neighborhood enforces and reports its node budget';

    v_nb := neighborhood(v_n2, p_max_depth := 0, p_max_nodes := 50);
    IF (v_nb->>'truncated')::boolean IS NOT FALSE THEN
        RAISE EXCEPTION 'neighborhood reported truncation inside its budget';
    END IF;
    IF NOT (v_nb->'nodes'->0->'assertions'->0->>'assertion_type' = 'trav_state') THEN
        RAISE EXCEPTION 'neighborhood did not attach current accepted assertions';
    END IF;
    RAISE NOTICE 'PASS: neighborhood attaches current accepted knowledge';

    -- ------------------------------------------------------------------
    -- Candidates, demotions, rejections, and supersessions.
    --
    -- neighborhood() reads current_valid_assertions, which is
    -- `status = 'accepted' AND superseded_at IS NULL` plus the effective
    -- window. After 0027 and 0030 a review policy can demote a write to
    -- `candidate`, and reject_candidate() leaves `candidate` with
    -- superseded_at set, so all four shapes have to stay out.
    -- ------------------------------------------------------------------
    PERFORM record_assertion(
        p_assertion_type := 'trav_candidate_state',
        p_claim := '{"state":"proposed"}',
        p_subject_node_id := v_n2,
        p_status := 'candidate',
        p_basis := 'assumed'
    );

    v_nb := neighborhood(v_n2, p_max_depth := 0, p_max_nodes := 50);
    IF v_nb::text LIKE '%trav_candidate_state%' THEN
        RAISE EXCEPTION 'candidate assertion leaked into neighborhood output';
    END IF;
    RAISE NOTICE 'PASS: neighborhood excludes candidate assertions';

    -- A rejected candidate keeps status 'candidate' and gains superseded_at.
    v_cand := record_assertion(
        p_assertion_type := 'trav_rejected_state',
        p_claim := '{"state":"withdrawn"}',
        p_subject_node_id := v_n2,
        p_status := 'candidate',
        p_basis := 'assumed'
    );
    PERFORM reject_candidate(v_cand, 'traversal suite: not supported', 'test:graph-traversal');

    SELECT count(*) INTO v_rows
    FROM assertions
    WHERE id = v_cand AND status = 'candidate' AND superseded_at IS NOT NULL;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION
            'fixture invalid: a rejected candidate should be status candidate with superseded_at set';
    END IF;

    v_nb := neighborhood(v_n2, p_max_depth := 0, p_max_nodes := 50);
    IF v_nb::text LIKE '%trav_rejected_state%' THEN
        RAISE EXCEPTION 'rejected candidate leaked into neighborhood output';
    END IF;
    RAISE NOTICE 'PASS: neighborhood excludes rejected candidates';

    -- A superseded incumbent is gone and its replacement is present. Two
    -- record_assertion() calls on one key leave the first superseded.
    PERFORM record_assertion(
        p_assertion_type := 'trav_history',
        p_claim := '{"stage":"first"}',
        p_subject_node_id := v_n2,
        p_assertion_key := 'trav_history:stage',
        p_basis := 'assumed'
    );
    v_sup := record_assertion(
        p_assertion_type := 'trav_history',
        p_claim := '{"stage":"second"}',
        p_subject_node_id := v_n2,
        p_assertion_key := 'trav_history:stage',
        p_basis := 'assumed'
    );

    SELECT count(*) INTO v_rows
    FROM assertions
    WHERE subject_node_id = v_n2
      AND assertion_type = 'trav_history'
      AND status = 'accepted'
      AND superseded_at IS NULL;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION
            'fixture invalid: expected exactly one live trav_history row, found %', v_rows;
    END IF;

    v_nb := neighborhood(v_n2, p_max_depth := 0, p_max_nodes := 50);
    IF v_nb::text LIKE '%"stage": "first"%' OR v_nb::text LIKE '%"stage":"first"%' THEN
        RAISE EXCEPTION 'superseded assertion leaked into neighborhood output';
    END IF;
    IF v_nb::text NOT LIKE '%second%' THEN
        RAISE EXCEPTION 'neighborhood did not carry the surviving assertion';
    END IF;
    RAISE NOTICE 'PASS: neighborhood carries the live row and drops the superseded one';

    -- ------------------------------------------------------------------
    -- The read-only promise, measured rather than declared, and measured
    -- for the two session shapes migration 0026 made read-only: a viewer,
    -- and a session that sets no role at all. If any of these functions
    -- wrote, the write gate would raise 42501 for those two and the row
    -- counts would move for admin.
    -- ------------------------------------------------------------------
    SELECT ARRAY[
        (SELECT count(*) FROM nodes),
        (SELECT count(*) FROM edges),
        (SELECT count(*) FROM events),
        (SELECT count(*) FROM event_participants),
        (SELECT count(*) FROM assertions),
        (SELECT count(*) FROM assertion_evidence),
        (SELECT count(*) FROM artifacts),
        (SELECT count(*) FROM node_source_map),
        (SELECT count(*) FROM node_merges)
    ] INTO v_before;

    FOREACH v_role IN ARRAY ARRAY['admin', 'viewer', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);

        PERFORM count(*) FROM find_nodes('Trav Warehouse');
        PERFORM count(*) FROM find_nodes_batch(ARRAY['Trav Warehouse', 'Trav Supplier'], NULL, 5);
        PERFORM count(*) FROM find_paths(v_n1, p_max_depth := 3);
        PERFORM count(*) FROM find_paths(v_n1, v_n4, p_max_depth := 3, p_semantics := ARRAY['causal']);
        PERFORM neighborhood(v_n1, p_max_depth := 2, p_max_nodes := 50);
        PERFORM edge_semantics('blocks');

        -- and they answer, rather than erroring, for every one of them.
        SELECT count(*) INTO v_rows FROM find_nodes('Trav Warehouse');
        IF v_rows < 1 THEN
            RAISE EXCEPTION
                'find_nodes returned nothing for role "%" though the fixture is unclassified', v_role;
        END IF;

        SELECT count(*) INTO v_rows FROM find_paths(v_n1, v_n4, p_max_depth := 3);
        IF v_rows < 1 THEN
            RAISE EXCEPTION
                'find_paths returned nothing for role "%" though the fixture is unclassified', v_role;
        END IF;

        v_nb := neighborhood(v_n1, p_max_depth := 2, p_max_nodes := 50);
        IF (v_nb->>'node_count')::int < 2 THEN
            RAISE EXCEPTION
                'neighborhood returned % nodes for role "%" though the fixture is unclassified',
                v_nb->>'node_count', v_role;
        END IF;

        IF edge_semantics('blocks') <> 'causal' THEN
            RAISE EXCEPTION 'edge_semantics did not resolve for role "%"', v_role;
        END IF;
    END LOOP;

    PERFORM set_config('app.current_role', 'admin', true);

    SELECT ARRAY[
        (SELECT count(*) FROM nodes),
        (SELECT count(*) FROM edges),
        (SELECT count(*) FROM events),
        (SELECT count(*) FROM event_participants),
        (SELECT count(*) FROM assertions),
        (SELECT count(*) FROM assertion_evidence),
        (SELECT count(*) FROM artifacts),
        (SELECT count(*) FROM node_source_map),
        (SELECT count(*) FROM node_merges)
    ] INTO v_after;

    IF v_after IS DISTINCT FROM v_before THEN
        RAISE EXCEPTION
            'a traversal call wrote: core table counts moved from % to %', v_before, v_after;
    END IF;
    RAISE NOTICE 'PASS: traversal and search write nothing, including no agent_query event';
    RAISE NOTICE 'PASS: traversal and search answer for a viewer and for a session with no role';
END
$$;

ROLLBACK;
