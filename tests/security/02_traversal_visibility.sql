-- Visibility contract D1 (design/proposals/rls-visibility-contract.md):
-- traversal prunes silently. A path through a node the caller cannot see is
-- indistinguishable from a path that does not exist, and no completeness
-- signal is emitted.

SET search_path = rye, public, pg_catalog;
BEGIN;

DO $$
DECLARE
    v_a uuid;
    v_b uuid;
    v_c uuid;
    v_bypasses_rls boolean;
    v_nb jsonb;
    v_rows int;
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
    RAISE NOTICE 'PASS: traversal emits no completeness signal';

    -- Sanity: with the team, the chain is walkable end to end.
    SELECT count(*) INTO v_rows FROM find_paths(v_a, v_c, p_max_depth := 2);
    IF v_rows < 1 THEN
        RAISE EXCEPTION 'cleared caller could not walk the restricted chain';
    END IF;
    RAISE NOTICE 'PASS: cleared caller walks the full chain';

    -- ------------------------------------------------------------------
    -- Drop the team and step down to a role with no access_grants — the
    -- seeded 'admin' role holds a standing grant to confidential nodes,
    -- which would defeat the fixture. Superusers bypass RLS entirely, so
    -- the pruning assertions only mean something under the non-superuser
    -- harness role (conformance.sh sets one up when the connection is
    -- superuser).
    -- ------------------------------------------------------------------
    PERFORM set_config('app.current_teams', '', true);
    PERFORM set_config('app.current_role', 'traversal_uncleared', true);

    SELECT rolsuper INTO v_bypasses_rls FROM pg_roles WHERE rolname = current_user;
    IF v_bypasses_rls THEN
        RAISE NOTICE 'SKIP: % bypasses RLS; run under RYE_TEST_ROLE for pruning coverage', current_user;
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM nodes WHERE id = v_b) THEN
        RAISE EXCEPTION 'fixture invalid: restricted node is still visible';
    END IF;

    SELECT count(*) INTO v_rows FROM find_paths(v_a, v_c, p_max_depth := 2);
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'traversal returned a path through an invisible node';
    END IF;
    RAISE NOTICE 'PASS: paths through invisible nodes are pruned';

    SELECT count(*) INTO v_rows FROM find_paths(v_a, p_max_depth := 3);
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'open-ended traversal exposed % hops past an invisible node', v_rows;
    END IF;
    RAISE NOTICE 'PASS: open-ended traversal stops at the visibility boundary';

    -- The neighborhood budget flag must not double as an RLS signal: the
    -- pruned node is absent and truncated stays false.
    v_nb := neighborhood(v_a, p_max_depth := 3, p_max_nodes := 50);
    IF v_nb::text LIKE '%Vis Restricted Hop%' OR v_nb::text LIKE '%Vis Public End%' THEN
        RAISE EXCEPTION 'neighborhood leaked a node past the visibility boundary';
    END IF;
    IF (v_nb->>'truncated')::boolean IS NOT FALSE THEN
        RAISE EXCEPTION 'truncated flag reported RLS pruning; it is a budget signal only';
    END IF;
    IF (v_nb->>'node_count')::int <> 1 THEN
        RAISE EXCEPTION 'neighborhood should hold only the visible root (got %)', v_nb->>'node_count';
    END IF;
    RAISE NOTICE 'PASS: neighborhood prunes silently and truncated stays a budget signal';

    -- find_nodes prunes the same way.
    SELECT count(*) INTO v_rows FROM find_nodes('Vis Restricted Hop');
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'find_nodes returned an invisible node';
    END IF;
    RAISE NOTICE 'PASS: find_nodes prunes invisible nodes';
END
$$;

ROLLBACK;
