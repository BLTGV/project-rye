-- Test: update_node_properties() — agent-safe node property updates

SET search_path = rye, public, pg_catalog;

DO $$
DECLARE
    v_node_id    uuid;
    v_event_id   uuid;
    v_props      jsonb;
    v_label      text;
    v_evt        record;
    v_updated    int;
BEGIN
    -- ===================================================================
    -- Setup: create a test node as a regular user first, then switch roles
    -- ===================================================================
    PERFORM set_config('app.current_user_id', 'user:test-admin', true);
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_teams', 'engineering', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Jane Doe', '{"email": "jane@old.com", "phone": "555-1234"}')
    RETURNING id INTO v_node_id;

    -- ===================================================================
    -- Test 1: Agent updates properties via update_node_properties()
    -- ===================================================================
    PERFORM set_config('app.current_user_id', 'agent:crm-bot', true);
    PERFORM set_config('app.current_role', 'agent:crm-bot', true);
    PERFORM set_config('app.current_teams', '', true);

    v_event_id := update_node_properties(
        p_node_id    := v_node_id,
        p_properties := '{"email": "jane@new.com", "title": "VP Engineering"}',
        p_summary    := 'Updated email from conversation'
    );

    IF v_event_id IS NULL THEN
        RAISE EXCEPTION 'FAIL: update_node_properties() returned NULL event_id';
    END IF;

    -- Verify the properties were merged
    SELECT properties, label INTO v_props, v_label FROM nodes WHERE id = v_node_id;

    IF v_props->>'email' <> 'jane@new.com' THEN
        RAISE EXCEPTION 'FAIL: email not updated, got %', v_props->>'email';
    END IF;
    IF v_props->>'phone' <> '555-1234' THEN
        RAISE EXCEPTION 'FAIL: existing phone was lost, got %', v_props->>'phone';
    END IF;
    IF v_props->>'title' <> 'VP Engineering' THEN
        RAISE EXCEPTION 'FAIL: new title not added, got %', v_props->>'title';
    END IF;
    IF v_label <> 'Jane Doe' THEN
        RAISE EXCEPTION 'FAIL: label changed unexpectedly, got %', v_label;
    END IF;

    RAISE NOTICE 'PASS: Agent can update properties via update_node_properties()';

    -- ===================================================================
    -- Test 2: Agent direct UPDATE still blocked by RLS
    -- ===================================================================
    BEGIN
        UPDATE nodes SET properties = '{"hacked": true}' WHERE id = v_node_id;
        GET DIAGNOSTICS v_updated = ROW_COUNT;
        IF v_updated > 0 THEN
            RAISE EXCEPTION 'FAIL: Agent direct UPDATE succeeded (expected 0 rows)';
        END IF;
        RAISE NOTICE 'PASS: Agent direct UPDATE on nodes silently blocked (0 rows)';
    END;

    -- ===================================================================
    -- Test 3: Event recorded with correct changed_fields diff
    -- ===================================================================
    SELECT event_type, summary, properties
      INTO v_evt
      FROM events
     WHERE id = v_event_id;

    IF v_evt.event_type <> 'node_properties_updated' THEN
        RAISE EXCEPTION 'FAIL: event type is %, expected node_properties_updated', v_evt.event_type;
    END IF;
    IF v_evt.summary <> 'Updated email from conversation' THEN
        RAISE EXCEPTION 'FAIL: event summary mismatch: %', v_evt.summary;
    END IF;

    -- Check that changed_fields has before/after
    IF v_evt.properties->'changed_fields'->'properties_before' IS NULL THEN
        RAISE EXCEPTION 'FAIL: changed_fields missing properties_before';
    END IF;
    IF v_evt.properties->'changed_fields'->'properties_after' IS NULL THEN
        RAISE EXCEPTION 'FAIL: changed_fields missing properties_after';
    END IF;
    IF v_evt.properties->'changed_fields'->>'properties_before' NOT LIKE '%jane@old.com%' THEN
        RAISE EXCEPTION 'FAIL: properties_before does not contain old email';
    END IF;
    IF v_evt.properties->'changed_fields'->>'properties_after' NOT LIKE '%jane@new.com%' THEN
        RAISE EXCEPTION 'FAIL: properties_after does not contain new email';
    END IF;

    -- Check event participant
    IF NOT EXISTS (
        SELECT 1 FROM event_participants
        WHERE event_id = v_event_id AND node_id = v_node_id AND role = 'subject'
    ) THEN
        RAISE EXCEPTION 'FAIL: node not recorded as event participant';
    END IF;

    RAISE NOTICE 'PASS: Event recorded with correct changed_fields diff';

    -- ===================================================================
    -- Test 4: Label update captured in event
    -- ===================================================================
    v_event_id := update_node_properties(
        p_node_id    := v_node_id,
        p_properties := '{}',
        p_label      := 'Jane Smith',
        p_summary    := 'Name change after marriage'
    );

    SELECT label INTO v_label FROM nodes WHERE id = v_node_id;
    IF v_label <> 'Jane Smith' THEN
        RAISE EXCEPTION 'FAIL: label not updated, got %', v_label;
    END IF;

    SELECT properties INTO v_props FROM events WHERE id = v_event_id;
    IF v_props->'changed_fields'->>'label_before' <> 'Jane Doe' THEN
        RAISE EXCEPTION 'FAIL: label_before mismatch: %', v_props->'changed_fields'->>'label_before';
    END IF;
    IF v_props->'changed_fields'->>'label_after' <> 'Jane Smith' THEN
        RAISE EXCEPTION 'FAIL: label_after mismatch: %', v_props->'changed_fields'->>'label_after';
    END IF;

    RAISE NOTICE 'PASS: Label update captured in event';

    -- ===================================================================
    -- Test 5: Archived node raises exception
    -- ===================================================================
    DECLARE
        v_archived_id uuid;
        v_caught boolean := false;
    BEGIN
        -- Create and archive a node (switch to admin for archiving)
        PERFORM set_config('app.current_role', 'admin', true);
        PERFORM set_config('app.current_user_id', 'user:test-admin', true);

        INSERT INTO nodes (node_type, label, properties, archived_at)
        VALUES ('person', 'Archived Person', '{}', now())
        RETURNING id INTO v_archived_id;

        -- Switch back to agent
        PERFORM set_config('app.current_role', 'agent:crm-bot', true);
        PERFORM set_config('app.current_user_id', 'agent:crm-bot', true);

        BEGIN
            PERFORM update_node_properties(
                p_node_id    := v_archived_id,
                p_properties := '{"should": "fail"}'
            );
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM LIKE '%archived%' THEN
                v_caught := true;
            ELSE
                RAISE EXCEPTION 'FAIL: Got unexpected error: %', SQLERRM;
            END IF;
        END;

        IF NOT v_caught THEN
            RAISE EXCEPTION 'FAIL: Archived node update did not raise exception';
        END IF;
        RAISE NOTICE 'PASS: Archived node raises exception';
    END;

    -- ===================================================================
    -- Test 6: Operator (non-agent) role can also use the function
    -- ===================================================================
    PERFORM set_config('app.current_user_id', 'user:operator', true);
    PERFORM set_config('app.current_role', 'team_member', true);
    PERFORM set_config('app.current_teams', 'engineering', true);

    v_event_id := update_node_properties(
        p_node_id    := v_node_id,
        p_properties := '{"department": "Engineering"}',
        p_summary    := 'Operator update'
    );

    IF v_event_id IS NULL THEN
        RAISE EXCEPTION 'FAIL: Operator could not use update_node_properties()';
    END IF;

    SELECT properties INTO v_props FROM nodes WHERE id = v_node_id;
    IF v_props->>'department' <> 'Engineering' THEN
        RAISE EXCEPTION 'FAIL: Operator update did not merge properties';
    END IF;

    RAISE NOTICE 'PASS: Operator role can use update_node_properties()';

    RAISE NOTICE 'All update_node_properties tests passed';
END;
$$;
