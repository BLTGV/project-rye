-- Generic future-effective assertion scheduling and thin profile wrappers.

SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false);
SELECT set_config('app.current_user_id', 'conformance:future-scheduling', false);
SELECT set_config('app.current_teams', '', false);

DO $$
DECLARE
    v_future timestamptz := now() + interval '30 days';
    v_node uuid;
    v_scheduled uuid;
BEGIN
    INSERT INTO nodes (node_type, label, external_id, external_source, properties)
    VALUES (
        'task',
        'Generic Future Task',
        gen_random_uuid()::text,
        'conformance:v2',
        '{"suite":"conformance","code":"TSK-GENERIC-FUTURE"}'
    )
    RETURNING id INTO v_node;

    PERFORM record_assertion(
        p_assertion_type := 'task_status',
        p_assertion_key := 'default',
        p_subject_node_id := v_node,
        p_claim := '{"status":"backlog"}',
        p_basis := 'assumed'
    );

    v_scheduled := schedule_assertion_change(
        p_subject_node_id := v_node,
        p_subject_edge_id := NULL,
        p_assertion_type := 'task_status',
        p_assertion_key := 'default',
        p_claim := '{"status":"ready_for_review"}',
        p_effective_at := v_future,
        p_reason := 'Conformance future transition',
        p_actor := 'conformance:future-scheduling',
        p_basis := 'reported',
        p_confidence := 1.0
    );

    IF NOT EXISTS (
        SELECT 1 FROM assertions
        WHERE id = v_scheduled
          AND effective_at = v_future
          AND attrs->>'scheduled' = 'true'
    ) THEN
        RAISE EXCEPTION 'Generic scheduler did not create a future assertion';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM current_valid_assertions
        WHERE subject_node_id = v_node
          AND assertion_type = 'task_status'
          AND claim->>'status' = 'backlog'
    ) THEN
        RAISE EXCEPTION 'Future schedule displaced current truth early';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM assertions_as_of(v_future + interval '1 second')
        WHERE id = v_scheduled
    ) THEN
        RAISE EXCEPTION 'Future scheduled assertion missing from as-of read';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM assertions
        WHERE subject_node_id = v_node
          AND assertion_type = 'task_status'
          AND claim->>'status' = 'backlog'
          AND effective_to = v_future
    ) THEN
        RAISE EXCEPTION 'Generic scheduler did not close the current effective window';
    END IF;

    -- The retained profile helper is a thin wrapper over the generic helper.
    v_scheduled := schedule_task_status_change(
        p_task_id := v_node,
        p_status := 'done',
        p_effective_at := v_future + interval '10 days',
        p_reason := 'Thin-wrapper check',
        p_actor := 'conformance:future-scheduling'
    );
    IF NOT EXISTS (
        SELECT 1 FROM assertions
        WHERE id = v_scheduled
          AND assertion_type = 'task_status'
          AND claim->>'status' = 'done'
          AND attrs->>'scheduled' = 'true'
    ) THEN
        RAISE EXCEPTION 'Profile scheduling wrapper did not delegate to generic scheduler';
    END IF;
END;
$$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_matviews
        WHERE schemaname = 'rye'
          AND matviewname IN ('opportunities_active', 'task_board')
          AND definition NOT ILIKE '%current_valid_assertions%'
    ) THEN
        RAISE EXCEPTION 'Profile materialized views must use current_valid_assertions';
    END IF;
END;
$$;
