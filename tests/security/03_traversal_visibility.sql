-- Visibility contract D1 (design/proposals/rls-visibility-contract.md):
-- traversal prunes silently. A path through a node the caller cannot see is
-- indistinguishable from a path that does not exist, and no completeness
-- signal is emitted.
--
-- Contract:  contracts/sql-surface.md; design/proposals/rls-visibility-contract.md.
-- Work item: work/013-graph-traversal.md (ports pull request 19).
-- Migration: schema/migrations/0032_graph_traversal.sql.
--
-- Runs under both database owner types. scripts/conformance.sh runs it as
-- the non-superuser rye_conformance role when the connection is a superuser;
-- scripts/test-nonsuperuser-owner.sh runs it as rye_owner, which is
-- NOSUPERUSER NOBYPASSRLS, with no SET ROLE. It refuses to run in any other
-- shape rather than skipping, because a skip here is a pass that proves
-- nothing.
--
-- Negative control: without 0032 this suite fails at the first assertion,
-- because the traversal functions do not exist.
--
-- Invented names only.

SET search_path = rye, public, pg_catalog;

BEGIN;

-- --------------------------------------------------------------------------
-- Anti-vacuity, as in tests/conformance/35_supporting_tables_rls.sql.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_bypass  boolean;
    v_missing text;
    v_role    text;
    v_super   boolean;
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

    FOREACH v_role IN ARRAY ARRAY['traversal_uncleared', 'viewer', '', 'admin'] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION
                'Refusing to pass vacuously: app.current_role did not read back as "%", it reads "%"',
                v_role, current_setting('app.current_role', true);
        END IF;
    END LOOP;

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
END
$$;

-- --------------------------------------------------------------------------
-- Pruning.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_a      uuid;
    v_b      uuid;
    v_c      uuid;
    v_nb     jsonb;
    v_role   text;
    v_rows   int;
    v_signal text;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:traversal-visibility', true);
    PERFORM set_config('app.current_teams', 'locked', true);

    INSERT INTO nodes (node_type, label, attrs) VALUES
        ('thing', 'Vis Public Start', '{"classification":"public"}'),
        ('thing', 'Vis Restricted Hop',
                  '{"classification":"confidential","teams":["locked"]}'),
        ('thing', 'Vis Public End',   '{"classification":"public"}');

    SELECT id INTO v_a FROM nodes WHERE label = 'Vis Public Start'   ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_b FROM nodes WHERE label = 'Vis Restricted Hop' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_c FROM nodes WHERE label = 'Vis Public End'     ORDER BY created_at DESC LIMIT 1;

    INSERT INTO edges (edge_type, source_id, target_id) VALUES
        ('blocks', v_a, v_b),
        ('blocks', v_b, v_c);

    -- ------------------------------------------------------------------
    -- No completeness signal exists on the traversal surface. This holds
    -- regardless of role, so it is checked before the RLS guard.
    -- ------------------------------------------------------------------
    SELECT string_agg(name, ', ')
    INTO v_signal
    FROM unnest(
        (SELECT p.proargnames
         FROM pg_proc p
         JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'rye' AND p.proname = 'find_paths'
         LIMIT 1)
    ) AS name
    WHERE name IN ('partial', 'blocked', 'blocked_hops', 'pruned', 'complete');

    IF v_signal IS NOT NULL THEN
        RAISE EXCEPTION 'find_paths exposes a completeness signal without a capability gate: %', v_signal;
    END IF;

    -- neighborhood returns jsonb, so its keys are the surface to check.
    SELECT string_agg(k, ', ')
    INTO v_signal
    FROM jsonb_object_keys(neighborhood(v_a, p_max_depth := 1, p_max_nodes := 50)) k
    WHERE k IN ('partial', 'blocked', 'blocked_hops', 'pruned', 'complete');

    IF v_signal IS NOT NULL THEN
        RAISE EXCEPTION 'neighborhood exposes a completeness signal without a capability gate: %', v_signal;
    END IF;
    RAISE NOTICE 'PASS: traversal emits no completeness signal';

    -- Sanity: with the team, the chain is walkable end to end. Without this
    -- the pruning assertions below would pass on an empty fixture.
    SELECT count(*) INTO v_rows FROM find_paths(v_a, v_c, p_max_depth := 2);
    IF v_rows < 1 THEN
        RAISE EXCEPTION 'cleared caller could not walk the restricted chain';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = v_b) THEN
        RAISE EXCEPTION 'fixture invalid: the restricted node is not visible to the cleared caller';
    END IF;
    RAISE NOTICE 'PASS: cleared caller walks the full chain';

    -- ------------------------------------------------------------------
    -- Drop the team and step down, once per read-only session shape:
    --
    --   traversal_uncleared  an ordinary named role with no access_grants
    --                        (the seeded 'admin' role can hold a standing
    --                        grant to confidential nodes, which would
    --                        defeat the fixture)
    --   viewer               the seeded read-only role (0026)
    --   ''                   a session that sets no role at all
    --
    -- All three must see the same thing: the visible start node, and no
    -- trace of what lies beyond the boundary.
    -- ------------------------------------------------------------------
    PERFORM set_config('app.current_teams', '', true);

    FOREACH v_role IN ARRAY ARRAY['traversal_uncleared', 'viewer', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);

        IF EXISTS (SELECT 1 FROM nodes WHERE id = v_b) THEN
            RAISE EXCEPTION
                'fixture invalid: restricted node is still visible to role "%"', v_role;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = v_a) THEN
            RAISE EXCEPTION
                'fixture invalid: the public start node is not visible to role "%", so pruning proves nothing',
                v_role;
        END IF;

        SELECT count(*) INTO v_rows FROM find_paths(v_a, v_c, p_max_depth := 2);
        IF v_rows <> 0 THEN
            RAISE EXCEPTION
                'traversal returned a path through an invisible node for role "%"', v_role;
        END IF;

        SELECT count(*) INTO v_rows FROM find_paths(v_a, p_max_depth := 3);
        IF v_rows <> 0 THEN
            RAISE EXCEPTION
                'open-ended traversal exposed % hops past an invisible node for role "%"',
                v_rows, v_role;
        END IF;

        -- 'any' direction cannot reach around the boundary either.
        SELECT count(*) INTO v_rows
        FROM find_paths(v_c, p_max_depth := 3, p_direction := 'any');
        IF v_rows <> 0 THEN
            RAISE EXCEPTION
                'undirected traversal walked past the visibility boundary for role "%"', v_role;
        END IF;

        -- The neighborhood budget flag must not double as an RLS signal: the
        -- pruned node is absent and truncated stays false.
        v_nb := neighborhood(v_a, p_max_depth := 3, p_max_nodes := 50);
        IF v_nb::text LIKE '%Vis Restricted Hop%' OR v_nb::text LIKE '%Vis Public End%' THEN
            RAISE EXCEPTION
                'neighborhood leaked a node past the visibility boundary for role "%"', v_role;
        END IF;
        IF (v_nb->>'truncated')::boolean IS NOT FALSE THEN
            RAISE EXCEPTION
                'truncated flag reported RLS pruning for role "%"; it is a budget signal only', v_role;
        END IF;
        IF (v_nb->>'node_count')::int <> 1 THEN
            RAISE EXCEPTION
                'neighborhood should hold only the visible root for role "%" (got %)',
                v_role, v_nb->>'node_count';
        END IF;
        IF jsonb_array_length(v_nb->'edges') <> 0 THEN
            RAISE EXCEPTION
                'neighborhood returned an edge with an invisible endpoint for role "%"', v_role;
        END IF;

        -- find_nodes and its batch form prune the same way, and the label of
        -- the hidden node never appears in either.
        SELECT count(*) INTO v_rows FROM find_nodes('Vis Restricted Hop');
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'find_nodes returned an invisible node for role "%"', v_role;
        END IF;

        -- 'Vis Public End' is public and visible on its own; only the
        -- restricted hop must be absent, whatever the phrasing.
        SELECT count(*) INTO v_rows
        FROM find_nodes_batch(ARRAY['Vis Restricted Hop', 'Vis Public End', 'Vis'], NULL, 20) b
        WHERE b.node_id = v_b;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'find_nodes_batch returned an invisible node for role "%"', v_role;
        END IF;

        SELECT count(*) INTO v_rows FROM find_nodes('Vis Public Start');
        IF v_rows < 1 THEN
            RAISE EXCEPTION
                'find_nodes lost the visible node for role "%", so the pruning above proves nothing',
                v_role;
        END IF;
    END LOOP;

    RAISE NOTICE 'PASS: paths through invisible nodes are pruned for every read-only session shape';
    RAISE NOTICE 'PASS: neighborhood prunes silently and truncated stays a budget signal';
    RAISE NOTICE 'PASS: find_nodes and find_nodes_batch prune invisible nodes';

    PERFORM set_config('app.current_role', 'admin', true);
END
$$;

ROLLBACK;
