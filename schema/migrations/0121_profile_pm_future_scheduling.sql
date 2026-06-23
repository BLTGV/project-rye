-- Future-safe project-management scheduling helpers.

SET search_path = rye, pg_catalog, public;

CREATE OR REPLACE FUNCTION advance_task_status(
    p_task_id uuid,
    p_new_status text,
    p_reason text DEFAULT NULL,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog, public
AS $$
DECLARE
    v_old_assertion_id uuid;
    v_old_status text;
    v_new_assertion_id uuid;
    v_event_id uuid;
    v_task_code text;
BEGIN
    SELECT id, claim->>'status'
    INTO v_old_assertion_id, v_old_status
    FROM current_valid_assertions
    WHERE subject_node_id = p_task_id
      AND assertion_type = 'task_status'
      AND assertion_key = 'default'
    LIMIT 1;

    SELECT properties->>'code'
    INTO v_task_code
    FROM nodes
    WHERE id = p_task_id;

    v_event_id := record_event(
        p_event_type        := 'status_change',
        p_summary           := format('%s: %s -> %s', v_task_code, coalesce(v_old_status, 'none'), p_new_status),
        p_properties        := jsonb_build_object(
            'entity_code', v_task_code,
            'from_status', v_old_status,
            'to_status', p_new_status,
            'reason', p_reason
        ),
        p_participant_ids   := ARRAY[p_task_id],
        p_participant_roles := ARRAY['subject'],
        p_actor             := p_actor
    );

    v_new_assertion_id := record_assertion(
        p_assertion_type := 'task_status',
        p_assertion_key := 'default',
        p_subject_node_id := p_task_id,
        p_claim := jsonb_build_object(
            'status', p_new_status,
            'moved_from', v_old_status,
            'reason', p_reason
        ),
        p_source_event_id := v_event_id,
        p_confidence := 1.0,
        p_mode := 'current',
        p_attrs := jsonb_build_object('source', 'rye-project-management', 'status_change', true)
    );

    RETURN v_new_assertion_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION schedule_task_status_change(
    p_task_id uuid,
    p_status text,
    p_effective_at timestamptz,
    p_reason text DEFAULT NULL,
    p_actor text DEFAULT NULL,
    p_plan_properties jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog, public
AS $$
DECLARE
    v_current_status text;
    v_event_id uuid;
    v_plan_key text;
    v_scheduled_assertion_id uuid;
    v_task_code text;
BEGIN
    IF p_effective_at <= now() THEN
        RAISE EXCEPTION 'scheduled task status effective_at must be in the future';
    END IF;

    SELECT properties->>'code'
    INTO v_task_code
    FROM nodes
    WHERE id = p_task_id
      AND node_type = 'task'
      AND archived_at IS NULL;

    IF v_task_code IS NULL THEN
        RAISE EXCEPTION 'Task % not found', p_task_id;
    END IF;

    SELECT claim->>'status'
    INTO v_current_status
    FROM current_valid_assertions
    WHERE subject_node_id = p_task_id
      AND assertion_type = 'task_status'
      AND assertion_key = 'default'
    LIMIT 1;

    v_event_id := record_event(
        p_event_type        := 'task_status_change_scheduled',
        p_summary           := format('%s: scheduled status change %s -> %s on %s', v_task_code, coalesce(v_current_status, 'none'), p_status, p_effective_at),
        p_properties        := jsonb_build_object(
            'entity_code', v_task_code,
            'from_status', v_current_status,
            'to_status', p_status,
            'effective_at', p_effective_at,
            'reason', p_reason,
            'plan_properties', coalesce(p_plan_properties, '{}'::jsonb)
        ),
        p_participant_ids   := ARRAY[p_task_id],
        p_participant_roles := ARRAY['subject'],
        p_actor             := p_actor
    );

    v_scheduled_assertion_id := record_assertion(
        p_assertion_type := 'task_status',
        p_assertion_key := 'default',
        p_subject_node_id := p_task_id,
        p_claim := jsonb_build_object(
            'status', p_status,
            'planned_from', v_current_status,
            'reason', p_reason
        ),
        p_effective_at := p_effective_at,
        p_source_event_id := v_event_id,
        p_confidence := 1.0,
        p_mode := 'current',
        p_attrs := jsonb_build_object('source', 'rye-project-management', 'scheduled_change', true)
    );

    v_plan_key := 'task_status_plan:' || to_char(p_effective_at AT TIME ZONE 'UTC', 'YYYYMMDDHH24MISS');

    PERFORM record_assertion(
        p_assertion_type := 'task_status_plan',
        p_assertion_key := v_plan_key,
        p_subject_node_id := p_task_id,
        p_claim := jsonb_build_object(
            'planned_status', p_status,
            'current_status_at_schedule', v_current_status,
            'effective_at', to_char(p_effective_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
            'status', 'scheduled',
            'scheduled_assertion_id', v_scheduled_assertion_id,
            'reason', p_reason,
            'properties', coalesce(p_plan_properties, '{}'::jsonb)
        ),
        p_source_event_id := v_event_id,
        p_confidence := 1.0,
        p_mode := 'current',
        p_attrs := jsonb_build_object('source', 'rye-project-management', 'plan', true)
    );

    RETURN v_scheduled_assertion_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION schedule_milestone_status_change(
    p_milestone_id uuid,
    p_status text,
    p_effective_at timestamptz,
    p_reason text DEFAULT NULL,
    p_actor text DEFAULT NULL,
    p_plan_properties jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog, public
AS $$
DECLARE
    v_current_status text;
    v_event_id uuid;
    v_milestone_code text;
    v_plan_key text;
    v_scheduled_assertion_id uuid;
BEGIN
    IF p_effective_at <= now() THEN
        RAISE EXCEPTION 'scheduled milestone status effective_at must be in the future';
    END IF;

    SELECT properties->>'code'
    INTO v_milestone_code
    FROM nodes
    WHERE id = p_milestone_id
      AND node_type = 'milestone'
      AND archived_at IS NULL;

    IF v_milestone_code IS NULL THEN
        RAISE EXCEPTION 'Milestone % not found', p_milestone_id;
    END IF;

    SELECT claim->>'status'
    INTO v_current_status
    FROM current_valid_assertions
    WHERE subject_node_id = p_milestone_id
      AND assertion_type = 'milestone_status'
      AND assertion_key = 'default'
    LIMIT 1;

    v_event_id := record_event(
        p_event_type        := 'milestone_status_change_scheduled',
        p_summary           := format('%s: scheduled milestone status %s -> %s on %s', v_milestone_code, coalesce(v_current_status, 'none'), p_status, p_effective_at),
        p_properties        := jsonb_build_object(
            'entity_code', v_milestone_code,
            'from_status', v_current_status,
            'to_status', p_status,
            'effective_at', p_effective_at,
            'reason', p_reason,
            'plan_properties', coalesce(p_plan_properties, '{}'::jsonb)
        ),
        p_participant_ids   := ARRAY[p_milestone_id],
        p_participant_roles := ARRAY['subject'],
        p_actor             := p_actor
    );

    v_scheduled_assertion_id := record_assertion(
        p_assertion_type := 'milestone_status',
        p_assertion_key := 'default',
        p_subject_node_id := p_milestone_id,
        p_claim := jsonb_build_object(
            'status', p_status,
            'planned_from', v_current_status,
            'reason', p_reason
        ),
        p_effective_at := p_effective_at,
        p_source_event_id := v_event_id,
        p_confidence := 1.0,
        p_mode := 'current',
        p_attrs := jsonb_build_object('source', 'rye-project-management', 'scheduled_change', true)
    );

    v_plan_key := 'milestone_status_plan:' || to_char(p_effective_at AT TIME ZONE 'UTC', 'YYYYMMDDHH24MISS');

    PERFORM record_assertion(
        p_assertion_type := 'milestone_status_plan',
        p_assertion_key := v_plan_key,
        p_subject_node_id := p_milestone_id,
        p_claim := jsonb_build_object(
            'planned_status', p_status,
            'current_status_at_schedule', v_current_status,
            'effective_at', to_char(p_effective_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
            'status', 'scheduled',
            'scheduled_assertion_id', v_scheduled_assertion_id,
            'reason', p_reason,
            'properties', coalesce(p_plan_properties, '{}'::jsonb)
        ),
        p_source_event_id := v_event_id,
        p_confidence := 1.0,
        p_mode := 'current',
        p_attrs := jsonb_build_object('source', 'rye-project-management', 'plan', true)
    );

    RETURN v_scheduled_assertion_id;
END;
$$ LANGUAGE plpgsql;

DROP MATERIALIZED VIEW IF EXISTS task_board;

CREATE MATERIALIZED VIEW task_board AS
SELECT
    t.id AS node_id,
    t.label AS title,
    t.properties->>'code' AS code,
    t.properties->>'task_type' AS task_type,
    t.properties->>'due_date' AS due_date,
    t.properties->>'priority' AS priority,
    t.attrs->'teams' AS teams,
    stg.claim->>'status' AS status,
    stg.asserted_at AS status_since,
    est.claim->>'hours' AS estimated_hours,
    est.claim->>'points' AS story_points,
    prg.claim->>'percent' AS progress_percent,
    owner.label AS owner_name,
    owner.id AS owner_id,
    reviewer.label AS reviewer_name,
    reviewer.id AS reviewer_id,
    proj.label AS project_name,
    proj.properties->>'code' AS project_code,
    sprint.label AS sprint_name,
    sprint.properties->>'code' AS sprint_code,
    parent.label AS parent_task,
    parent.properties->>'code' AS parent_code,
    (
        SELECT count(*)
        FROM edges sub
        WHERE sub.edge_type = 'subtask_of'
          AND sub.target_id = t.id
          AND sub.archived_at IS NULL
    ) AS subtask_count,
    (
        SELECT count(*)
        FROM edges blk
        WHERE blk.edge_type = 'blocks'
          AND blk.target_id = t.id
          AND blk.archived_at IS NULL
    ) AS blocker_count,
    t.created_at
FROM nodes t
LEFT JOIN current_valid_assertions stg
    ON stg.subject_node_id = t.id
   AND stg.assertion_type = 'task_status'
   AND stg.assertion_key = 'default'
LEFT JOIN current_valid_assertions est
    ON est.subject_node_id = t.id
   AND est.assertion_type = 'estimate'
LEFT JOIN current_valid_assertions prg
    ON prg.subject_node_id = t.id
   AND prg.assertion_type = 'progress'
LEFT JOIN LATERAL (
    SELECT n.id, n.label
    FROM edges e
    JOIN nodes n ON n.id = e.target_id
    WHERE e.source_id = t.id
      AND e.edge_type = 'assigned_to'
      AND e.properties->>'role' = 'owner'
      AND (e.effective_from IS NULL OR e.effective_from <= now())
      AND (e.effective_to IS NULL OR e.effective_to > now())
      AND e.archived_at IS NULL
    LIMIT 1
) owner ON true
LEFT JOIN LATERAL (
    SELECT n.id, n.label
    FROM edges e
    JOIN nodes n ON n.id = e.target_id
    WHERE e.source_id = t.id
      AND e.edge_type = 'assigned_to'
      AND e.properties->>'role' = 'reviewer'
      AND (e.effective_from IS NULL OR e.effective_from <= now())
      AND (e.effective_to IS NULL OR e.effective_to > now())
      AND e.archived_at IS NULL
    LIMIT 1
) reviewer ON true
LEFT JOIN LATERAL (
    SELECT n.id, n.label, n.properties
    FROM edges e
    JOIN nodes n ON n.id = e.source_id
    WHERE e.target_id = t.id
      AND e.edge_type = 'contains'
      AND n.node_type = 'project'
      AND e.archived_at IS NULL
    LIMIT 1
) proj ON true
LEFT JOIN LATERAL (
    SELECT n.id, n.label, n.properties
    FROM edges e
    JOIN nodes n ON n.id = e.target_id
    WHERE e.source_id = t.id
      AND e.edge_type = 'sprint_member'
      AND e.archived_at IS NULL
    LIMIT 1
) sprint ON true
LEFT JOIN LATERAL (
    SELECT n.id, n.label, n.properties
    FROM edges e
    JOIN nodes n ON n.id = e.target_id
    WHERE e.source_id = t.id
      AND e.edge_type = 'subtask_of'
      AND e.archived_at IS NULL
    LIMIT 1
) parent ON true
WHERE t.node_type = 'task'
  AND t.archived_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_tb_node    ON task_board (node_id);
CREATE INDEX IF NOT EXISTS idx_tb_code           ON task_board (code);
CREATE INDEX IF NOT EXISTS idx_tb_status         ON task_board (status);
CREATE INDEX IF NOT EXISTS idx_tb_owner          ON task_board (owner_id);
CREATE INDEX IF NOT EXISTS idx_tb_project        ON task_board (project_code);
CREATE INDEX IF NOT EXISTS idx_tb_sprint         ON task_board (sprint_code);
CREATE INDEX IF NOT EXISTS idx_tb_due            ON task_board (due_date);
