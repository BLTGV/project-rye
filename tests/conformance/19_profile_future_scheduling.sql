-- CRM and PM future scheduling helpers.

SET search_path = rye, public, pg_catalog;

BEGIN;

DO $$
DECLARE
    v_count int;
    v_current text;
    v_future timestamptz := now() + interval '30 days';
    v_future_later timestamptz := now() + interval '45 days';
    v_milestone uuid;
    v_opp uuid;
    v_owner uuid;
    v_pipeline uuid;
    v_project uuid;
    v_scheduled uuid;
    v_task uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:profile-future-scheduling', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Future Scheduling Owner', '{"suite": "conformance"}')
    RETURNING id INTO v_owner;

    INSERT INTO nodes (node_type, label, properties)
    VALUES (
        'pipeline',
        'Future Scheduling Pipeline',
        '{"suite": "conformance", "code": "FUT", "default_stage": "prospecting"}'
    )
    RETURNING id INTO v_pipeline;

    v_opp := create_opportunity(
        p_name := 'Future Scheduled Opportunity',
        p_pipeline_code := 'FUT',
        p_assigned_to_id := v_owner,
        p_properties := '{"suite": "conformance"}'
    );

    v_scheduled := schedule_deal_stage_change(
        p_opp_id := v_opp,
        p_stage := 'proposal',
        p_effective_at := v_future,
        p_reason := 'Proposal package target',
        p_actor := 'test:profile-future-scheduling',
        p_plan_properties := '{"milestone": "proposal package"}'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM assertions
        WHERE id = v_scheduled
          AND assertion_type = 'deal_stage'
          AND attrs->>'scheduled_future' = 'true'
    ) THEN
        RAISE EXCEPTION 'Expected scheduled deal_stage assertion to be marked scheduled_future';
    END IF;

    SELECT claim->>'stage' INTO v_current
    FROM current_valid_assertions
    WHERE subject_node_id = v_opp
      AND assertion_type = 'deal_stage'
      AND assertion_key = 'default';

    IF v_current <> 'prospecting' THEN
        RAISE EXCEPTION 'Expected current CRM stage prospecting before future date, got %', v_current;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM current_valid_assertions
        WHERE subject_node_id = v_opp
          AND assertion_type = 'deal_stage_plan'
          AND claim->>'planned_stage' = 'proposal'
          AND claim->>'status' = 'scheduled'
    ) THEN
        RAISE EXCEPTION 'Expected current-visible deal_stage_plan assertion';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM assertions_as_of(v_future + interval '1 day')
        WHERE subject_node_id = v_opp
          AND assertion_type = 'deal_stage'
          AND assertion_key = 'default'
          AND claim->>'stage' = 'proposal'
    ) THEN
        RAISE EXCEPTION 'Expected future CRM as-of read to show scheduled proposal stage';
    END IF;

    PERFORM advance_deal_stage(v_opp, 'discovery', 'Pre-cutover qualification work', 'test:profile-future-scheduling');

    SELECT claim->>'stage' INTO v_current
    FROM current_valid_assertions
    WHERE subject_node_id = v_opp
      AND assertion_type = 'deal_stage'
      AND assertion_key = 'default';

    IF v_current <> 'discovery' THEN
        RAISE EXCEPTION 'Expected immediate CRM stage discovery after advance, got %', v_current;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM current_valid_assertions
        WHERE subject_node_id = v_opp
          AND assertion_type = 'deal_stage'
          AND assertion_key = 'default'
          AND claim->>'stage' = 'discovery'
          AND effective_to = v_future
    ) THEN
        RAISE EXCEPTION 'Expected immediate CRM stage to close at scheduled future date';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM assertions_as_of(v_future + interval '1 day')
        WHERE subject_node_id = v_opp
          AND assertion_type = 'deal_stage'
          AND assertion_key = 'default'
          AND claim->>'stage' = 'proposal'
    ) THEN
        RAISE EXCEPTION 'Expected scheduled CRM stage to survive pre-cutover advance';
    END IF;

    SELECT count(*) INTO v_count
    FROM assertions_as_of(v_future + interval '1 day')
    WHERE subject_node_id = v_opp
      AND assertion_type = 'deal_stage'
      AND assertion_key = 'default';

    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Expected exactly one future CRM stage as-of row, got %', v_count;
    END IF;

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('project', 'Future Scheduling Project', '{"suite": "conformance", "code": "PRJ-FUT"}')
    RETURNING id INTO v_project;

    v_task := create_task(
        p_title := 'Future Scheduled Task',
        p_project_id := v_project,
        p_assigned_to_id := v_owner,
        p_properties := '{"suite": "conformance"}'
    );

    v_scheduled := schedule_task_status_change(
        p_task_id := v_task,
        p_status := 'ready_for_review',
        p_effective_at := v_future,
        p_reason := 'Review window opens',
        p_actor := 'test:profile-future-scheduling'
    );

    SELECT claim->>'status' INTO v_current
    FROM current_valid_assertions
    WHERE subject_node_id = v_task
      AND assertion_type = 'task_status'
      AND assertion_key = 'default';

    IF v_current <> 'backlog' THEN
        RAISE EXCEPTION 'Expected current task status backlog before future date, got %', v_current;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM current_valid_assertions
        WHERE subject_node_id = v_task
          AND assertion_type = 'task_status_plan'
          AND claim->>'planned_status' = 'ready_for_review'
    ) THEN
        RAISE EXCEPTION 'Expected current-visible task_status_plan assertion';
    END IF;

    PERFORM advance_task_status(v_task, 'in_progress', 'Started implementation', 'test:profile-future-scheduling');

    IF NOT EXISTS (
        SELECT 1
        FROM current_valid_assertions
        WHERE subject_node_id = v_task
          AND assertion_type = 'task_status'
          AND assertion_key = 'default'
          AND claim->>'status' = 'in_progress'
          AND effective_to = v_future
    ) THEN
        RAISE EXCEPTION 'Expected immediate task status to close at scheduled future date';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM assertions_as_of(v_future + interval '1 day')
        WHERE subject_node_id = v_task
          AND assertion_type = 'task_status'
          AND assertion_key = 'default'
          AND claim->>'status' = 'ready_for_review'
    ) THEN
        RAISE EXCEPTION 'Expected scheduled task status to survive pre-cutover advance';
    END IF;

    SELECT count(*) INTO v_count
    FROM assertions_as_of(v_future + interval '1 day')
    WHERE subject_node_id = v_task
      AND assertion_type = 'task_status'
      AND assertion_key = 'default';

    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Expected exactly one future task status as-of row, got %', v_count;
    END IF;

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('milestone', 'Future Scheduled Milestone', '{"suite": "conformance", "code": "MIL-FUT", "target_date": "2099-01-01"}')
    RETURNING id INTO v_milestone;

    PERFORM record_assertion(
        p_assertion_type := 'milestone_status',
        p_assertion_key := 'default',
        p_subject_node_id := v_milestone,
        p_claim := '{"status": "planned"}',
        p_confidence := 1.0,
        p_mode := 'current'
    );

    v_scheduled := schedule_milestone_status_change(
        p_milestone_id := v_milestone,
        p_status := 'launch_ready',
        p_effective_at := v_future_later,
        p_reason := 'Launch readiness target',
        p_actor := 'test:profile-future-scheduling'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM current_valid_assertions
        WHERE subject_node_id = v_milestone
          AND assertion_type = 'milestone_status'
          AND assertion_key = 'default'
          AND claim->>'status' = 'planned'
    ) THEN
        RAISE EXCEPTION 'Expected current milestone status planned before future date';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM current_valid_assertions
        WHERE subject_node_id = v_milestone
          AND assertion_type = 'milestone_status_plan'
          AND claim->>'planned_status' = 'launch_ready'
    ) THEN
        RAISE EXCEPTION 'Expected current-visible milestone_status_plan assertion';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM assertions_as_of(v_future_later + interval '1 day')
        WHERE subject_node_id = v_milestone
          AND assertion_type = 'milestone_status'
          AND assertion_key = 'default'
          AND claim->>'status' = 'launch_ready'
    ) THEN
        RAISE EXCEPTION 'Expected future milestone as-of read to show launch_ready';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_matviews
        WHERE schemaname = 'rye'
          AND matviewname IN ('opportunities_active', 'contacts_directory', 'task_board')
          AND definition ILIKE '%current_valid_assertions%'
    ) THEN
        RAISE EXCEPTION 'Expected profile materialized views to use current_valid_assertions';
    END IF;
END;
$$;

ROLLBACK;
