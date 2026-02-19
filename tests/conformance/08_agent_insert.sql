-- Test: Agents can INSERT nodes, edges, and artifacts (Gap 1 fix)
-- Agents should be able to create data but not update or delete it.

DO $$
DECLARE
    v_node_a uuid;
    v_node_b uuid;
    v_edge_id uuid;
    v_artifact_id uuid;
    v_updated int;
    v_error boolean := false;
BEGIN
    -- Set up as agent role
    PERFORM set_config('app.current_user_id', 'agent:test-bot', true);
    PERFORM set_config('app.current_role', 'agent:test-bot', true);
    PERFORM set_config('app.current_teams', '', true);

    -- Agent should be able to INSERT nodes
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Agent Created Person', '{"source": "agent_test"}')
    RETURNING id INTO v_node_a;

    IF v_node_a IS NULL THEN
        RAISE EXCEPTION 'FAIL: Agent could not INSERT node';
    END IF;
    RAISE NOTICE 'PASS: Agent can INSERT nodes';

    -- Agent should be able to INSERT a second node
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('org', 'Agent Created Org', '{"source": "agent_test"}')
    RETURNING id INTO v_node_b;

    -- Agent should be able to INSERT edges
    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES ('employs', v_node_b, v_node_a, '{"source": "agent_test"}')
    RETURNING id INTO v_edge_id;

    IF v_edge_id IS NULL THEN
        RAISE EXCEPTION 'FAIL: Agent could not INSERT edge';
    END IF;
    RAISE NOTICE 'PASS: Agent can INSERT edges';

    -- Agent should be able to INSERT artifacts
    INSERT INTO artifacts (artifact_type, content, source_node_id)
    VALUES ('document_parse', '{"text": "extracted content"}', v_node_a)
    RETURNING id INTO v_artifact_id;

    IF v_artifact_id IS NULL THEN
        RAISE EXCEPTION 'FAIL: Agent could not INSERT artifact';
    END IF;
    RAISE NOTICE 'PASS: Agent can INSERT artifacts';

    -- Agent should NOT be able to UPDATE nodes
    BEGIN
        UPDATE nodes SET label = 'Modified' WHERE id = v_node_a;
        GET DIAGNOSTICS v_updated = ROW_COUNT;
        IF v_updated > 0 THEN
            RAISE EXCEPTION 'FAIL: Agent was able to UPDATE node (expected 0 rows)';
        END IF;
        RAISE NOTICE 'PASS: Agent UPDATE on nodes silently blocked (0 rows)';
    END;

    -- Agent should NOT be able to DELETE nodes
    BEGIN
        DELETE FROM nodes WHERE id = v_node_a;
        GET DIAGNOSTICS v_updated = ROW_COUNT;
        IF v_updated > 0 THEN
            RAISE EXCEPTION 'FAIL: Agent was able to DELETE node (expected 0 rows)';
        END IF;
        RAISE NOTICE 'PASS: Agent DELETE on nodes silently blocked (0 rows)';
    END;

    -- Agent should NOT be able to UPDATE edges
    BEGIN
        UPDATE edges SET properties = '{"modified": true}' WHERE id = v_edge_id;
        GET DIAGNOSTICS v_updated = ROW_COUNT;
        IF v_updated > 0 THEN
            RAISE EXCEPTION 'FAIL: Agent was able to UPDATE edge (expected 0 rows)';
        END IF;
        RAISE NOTICE 'PASS: Agent UPDATE on edges silently blocked (0 rows)';
    END;

    -- Agent should NOT be able to UPDATE artifacts
    BEGIN
        UPDATE artifacts SET content = '{"modified": true}' WHERE id = v_artifact_id;
        GET DIAGNOSTICS v_updated = ROW_COUNT;
        IF v_updated > 0 THEN
            RAISE EXCEPTION 'FAIL: Agent was able to UPDATE artifact (expected 0 rows)';
        END IF;
        RAISE NOTICE 'PASS: Agent UPDATE on artifacts silently blocked (0 rows)';
    END;

    -- Agent can use link_record() (it inserts nodes internally)
    DECLARE
        v_linked uuid;
    BEGIN
        v_linked := link_record(
            p_source_schema := 'test',
            p_source_table  := 'agent_items',
            p_source_id     := 'agent-001',
            p_node_type     := 'document',
            p_label         := 'Agent Linked Document',
            p_properties    := '{"agent": true}'
        );
        IF v_linked IS NULL THEN
            RAISE EXCEPTION 'FAIL: Agent could not use link_record()';
        END IF;
        RAISE NOTICE 'PASS: Agent can use link_record()';
    END;

    RAISE NOTICE 'All agent INSERT tests passed';
END;
$$;
