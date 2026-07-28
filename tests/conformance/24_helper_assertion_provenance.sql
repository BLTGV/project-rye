-- Helper-created assertions must carry provenance.
-- create_task / create_opportunity anchor their initial status/stage
-- assertions to the creation event (or a caller-supplied source event),
-- so no helper path writes an assertion without source evidence.

SET search_path = rye, public, pg_catalog;

BEGIN;

DO $$
DECLARE
    v_owner uuid;
    v_pipeline uuid;
    v_opp uuid;
    v_task uuid;
    v_external_event uuid;
    v_source_event uuid;
    v_event_type text;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:helper-provenance', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Provenance Owner', '{"suite": "conformance"}')
    RETURNING id INTO v_owner;

    INSERT INTO nodes (node_type, label, properties)
    VALUES (
        'pipeline',
        'Provenance Pipeline',
        '{"suite": "conformance", "code": "PROV", "default_stage": "prospecting"}'
    )
    RETURNING id INTO v_pipeline;

    -- Default path: helpers generate a creation event and anchor to it
    v_opp := create_opportunity(
        p_name := 'Provenance Opportunity',
        p_pipeline_code := 'PROV',
        p_assigned_to_id := v_owner,
        p_properties := '{"suite": "conformance"}'
    );

    SELECT ae.event_id, e.event_type
    INTO v_source_event, v_event_type
    FROM assertions a
    JOIN assertion_evidence ae ON ae.assertion_id = a.id AND ae.kind = 'source'
    JOIN events e ON e.id = ae.event_id
    WHERE a.subject_node_id = v_opp
      AND a.assertion_type = 'deal_stage'
      AND a.assertion_key = 'default'
      AND a.superseded_at IS NULL;

    IF v_source_event IS NULL THEN
        RAISE EXCEPTION 'Expected create_opportunity initial deal_stage assertion to have source evidence';
    END IF;

    IF v_event_type <> 'opportunity_created' THEN
        RAISE EXCEPTION 'Expected initial deal_stage assertion anchored to opportunity_created event, got %', v_event_type;
    END IF;

    v_task := create_task(
        p_title := 'Provenance Task',
        p_assigned_to_id := v_owner
    );

    SELECT ae.event_id, e.event_type
    INTO v_source_event, v_event_type
    FROM assertions a
    JOIN assertion_evidence ae ON ae.assertion_id = a.id AND ae.kind = 'source'
    JOIN events e ON e.id = ae.event_id
    WHERE a.subject_node_id = v_task
      AND a.assertion_type = 'task_status'
      AND a.assertion_key = 'default'
      AND a.superseded_at IS NULL;

    IF v_source_event IS NULL THEN
        RAISE EXCEPTION 'Expected create_task initial task_status assertion to have source evidence';
    END IF;

    IF v_event_type <> 'task_created' THEN
        RAISE EXCEPTION 'Expected initial task_status assertion anchored to task_created event, got %', v_event_type;
    END IF;

    -- Explicit path: a caller-supplied source event wins over the creation event
    v_external_event := record_event(
        p_event_type := 'meeting',
        p_summary := 'Kickoff call that spawned the follow-up work',
        p_actor := 'test:helper-provenance'
    );

    v_task := create_task(
        p_title := 'Provenance Task From Meeting',
        p_source_event_id := v_external_event
    );

    IF NOT EXISTS (
        SELECT 1
        FROM assertions a
        JOIN assertion_evidence ae ON ae.assertion_id = a.id
        WHERE a.subject_node_id = v_task
          AND a.assertion_type = 'task_status'
          AND a.assertion_key = 'default'
          AND ae.event_id = v_external_event
    ) THEN
        RAISE EXCEPTION 'Expected caller-supplied source event on create_task initial assertion';
    END IF;

    v_opp := create_opportunity(
        p_name := 'Provenance Opportunity From Meeting',
        p_pipeline_code := 'PROV',
        p_assigned_to_id := NULL,
        p_source_event_id := v_external_event
    );

    IF NOT EXISTS (
        SELECT 1
        FROM assertions a
        JOIN assertion_evidence ae ON ae.assertion_id = a.id
        WHERE a.subject_node_id = v_opp
          AND a.assertion_type = 'deal_stage'
          AND a.assertion_key = 'default'
          AND ae.event_id = v_external_event
    ) THEN
        RAISE EXCEPTION 'Expected caller-supplied source event on create_opportunity initial assertion';
    END IF;
END;
$$;

ROLLBACK;
