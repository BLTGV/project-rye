-- Starting state for the manager-expectation replay scenario.
-- Fixture, not skill output: it seeds the graph the two agents under test
-- will read. Run once against a throwaway database after Rye is installed.
--
-- Builds: Bob Ferris and John Reyes as people, a reports_to edge from John to
-- Bob in effect since 2025-01-06, and a sales-operations area owned by Bob.
-- No grants, no assertions, no events. The relationship step decides.
--
-- All names are invented.

SET search_path = rye, public, pg_catalog;

DO $$
DECLARE
    v_bob  uuid;
    v_john uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'eval:manager-expectation', true);

    SELECT id INTO v_bob
    FROM nodes
    WHERE external_source = 'eval.manager_expectation'
      AND external_id = 'person:bob-ferris';

    IF v_bob IS NULL THEN
        INSERT INTO nodes (node_type, label, external_source, external_id, properties)
        VALUES (
            'person',
            'Bob Ferris',
            'eval.manager_expectation',
            'person:bob-ferris',
            jsonb_build_object('title', 'Regional Sales Manager')
        )
        RETURNING id INTO v_bob;
    END IF;

    SELECT id INTO v_john
    FROM nodes
    WHERE external_source = 'eval.manager_expectation'
      AND external_id = 'person:john-reyes';

    IF v_john IS NULL THEN
        INSERT INTO nodes (node_type, label, external_source, external_id, properties)
        VALUES (
            'person',
            'John Reyes',
            'eval.manager_expectation',
            'person:john-reyes',
            jsonb_build_object('title', 'Account Executive')
        )
        RETURNING id INTO v_john;
    END IF;

    -- reports_to runs from the report to the manager, per
    -- contracts/plugin-manifest.md. Open-ended: the line is still in effect.
    IF NOT EXISTS (
        SELECT 1 FROM edges
        WHERE edge_type = 'reports_to'
          AND source_id = v_john
          AND target_id = v_bob
          AND archived_at IS NULL
    ) THEN
        INSERT INTO edges (edge_type, source_id, target_id, effective_from, effective_to)
        VALUES ('reports_to', v_john, v_bob, timestamptz '2025-01-06 00:00:00+00', NULL);
    END IF;

    INSERT INTO knowledge_domains (domain_key, label, purpose, owner_node_id)
    VALUES (
        'sales-operations',
        'Sales Operations',
        'How the regional sales team works: who covers what, and what is expected of them.',
        v_bob
    )
    ON CONFLICT (domain_key) DO UPDATE
        SET owner_node_id = EXCLUDED.owner_node_id,
            archived_at = NULL,
            updated_at = now();
END;
$$;
