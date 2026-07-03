-- Rye PM profile

SET search_path = rye, pg_catalog, public;

CREATE OR REPLACE FUNCTION create_task(
    p_title text,
    p_description text DEFAULT NULL,
    p_project_id uuid DEFAULT NULL,
    p_assigned_to_id uuid DEFAULT NULL,
    p_properties jsonb DEFAULT '{}',
    p_teams text[] DEFAULT '{}',
    p_regarding_ids uuid[] DEFAULT '{}',
    p_regarding_roles text[] DEFAULT '{}',
    p_source_event_id uuid DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog, public
AS $$
DECLARE
    v_task_id uuid;
    v_code text;
    v_project_seq int;
    i int;
    v_regarding_count int;
    v_event_id uuid;
BEGIN
    v_code := generate_crm_code('TSK');

    IF p_project_id IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtext(p_project_id::text));

        SELECT coalesce(max((t.properties->>'project_seq')::int), 0) + 1
        INTO v_project_seq
        FROM edges c
        JOIN nodes t ON t.id = c.target_id AND t.node_type = 'task'
        WHERE c.source_id = p_project_id
          AND c.edge_type = 'contains'
          AND c.archived_at IS NULL;
    END IF;

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES (
        'task',
        p_title,
        p_properties || jsonb_build_object(
            'code', v_code,
            'title', p_title,
            'description', p_description
        ) || CASE
                WHEN v_project_seq IS NOT NULL THEN jsonb_build_object('project_seq', v_project_seq)
                ELSE '{}'::jsonb
             END,
        jsonb_build_object('teams', to_jsonb(p_teams))
        || CASE WHEN array_length(p_teams, 1) > 0
                THEN jsonb_build_object('classification', 'internal')
                ELSE '{}'::jsonb
           END,
        v_code,
        'internal'
    )
    RETURNING id INTO v_task_id;

    v_event_id := record_event(
        p_event_type        := 'task_created',
        p_summary           := format('Created %s: %s', v_code, p_title),
        p_properties        := jsonb_build_object('task_code', v_code, 'project_id', p_project_id),
        p_participant_ids   := ARRAY[v_task_id],
        p_participant_roles := ARRAY['subject']
    );

    -- Initial status assertion is anchored to the caller's source event when
    -- provided, otherwise to the creation event, so provenance is never NULL
    PERFORM record_assertion(
        p_assertion_type := 'task_status',
        p_assertion_key := 'default',
        p_subject_node_id := v_task_id,
        p_claim := '{"status": "backlog"}'::jsonb,
        p_source_event_id := coalesce(p_source_event_id, v_event_id),
        p_confidence := 1.0
    );

    IF p_project_id IS NOT NULL THEN
        INSERT INTO edges (edge_type, source_id, target_id, properties)
        VALUES ('contains', p_project_id, v_task_id, jsonb_build_object('added_at', now()));
    END IF;

    IF p_assigned_to_id IS NOT NULL THEN
        INSERT INTO edges (edge_type, source_id, target_id, properties, effective_from)
        VALUES ('assigned_to', v_task_id, p_assigned_to_id, '{"role": "owner"}', now());
    END IF;

    v_regarding_count := coalesce(array_length(p_regarding_ids, 1), 0);
    IF coalesce(array_length(p_regarding_roles, 1), 0) <> v_regarding_count THEN
        RAISE EXCEPTION 'regarding_ids and regarding_roles must have the same length';
    END IF;

    FOR i IN 1..v_regarding_count LOOP
        INSERT INTO edges (edge_type, source_id, target_id, properties)
        VALUES (
            'regarding',
            v_task_id,
            p_regarding_ids[i],
            jsonb_build_object('context', coalesce(p_regarding_roles[i], 'subject'))
        );
    END LOOP;

    RETURN v_task_id;
END;
$$ LANGUAGE plpgsql;

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

CREATE OR REPLACE FUNCTION add_comment(
    p_task_id uuid,
    p_body text,
    p_actor text DEFAULT NULL,
    p_reply_to_event_id uuid DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog, public
AS $$
DECLARE
    v_event_id uuid;
    v_task_code text;
    v_code_pattern text := '(?:OPP|TSK|PRJ|CON|MIL|SPR)-\\d{4}-\\d{4}';
    v_match text;
    v_mentioned_id uuid;
BEGIN
    SELECT properties->>'code' INTO v_task_code
    FROM nodes
    WHERE id = p_task_id;

    v_event_id := record_event(
        p_event_type        := 'comment',
        p_summary           := format('Comment on %s', v_task_code),
        p_properties        := jsonb_build_object('body', p_body, 'reply_to', p_reply_to_event_id),
        p_participant_ids   := ARRAY[p_task_id],
        p_participant_roles := ARRAY['subject'],
        p_actor             := p_actor
    );

    FOR v_match IN
        SELECT (regexp_matches(p_body, v_code_pattern, 'g'))[1]
    LOOP
        SELECT id INTO v_mentioned_id
        FROM nodes
        WHERE properties->>'code' = v_match
          AND archived_at IS NULL
        LIMIT 1;

        IF v_mentioned_id IS NOT NULL AND v_mentioned_id <> p_task_id THEN
            INSERT INTO event_participants (event_id, node_id, role)
            VALUES (v_event_id, v_mentioned_id, 'mentioned')
            ON CONFLICT (event_id, node_id, role) DO NOTHING;
        END IF;
    END LOOP;

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION log_time(
    p_task_id uuid,
    p_hours numeric,
    p_description text DEFAULT NULL,
    p_date date DEFAULT current_date,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog, public
AS $$
DECLARE
    v_task_code text;
BEGIN
    SELECT properties->>'code' INTO v_task_code
    FROM nodes
    WHERE id = p_task_id;

    RETURN record_event(
        p_event_type        := 'time_log',
        p_summary           := format('%s: %s hours', v_task_code, p_hours),
        p_properties        := jsonb_build_object('hours', p_hours, 'description', p_description, 'date', p_date),
        p_participant_ids   := ARRAY[p_task_id],
        p_participant_roles := ARRAY['subject'],
        p_actor             := p_actor,
        p_occurred_at       := p_date::timestamptz
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION instantiate_workflow(
    p_template_id uuid,
    p_project_id uuid,
    p_context jsonb,
    p_regarding_ids uuid[] DEFAULT '{}',
    p_teams text[] DEFAULT '{}'
) RETURNS uuid[]
SET search_path = rye, pg_catalog, public
AS $$
DECLARE
    v_steps jsonb;
    v_step jsonb;
    v_task_ids uuid[] := '{}';
    v_task_id uuid;
    v_title text;
    v_key text;
    v_value text;
    v_regarding_roles text[];
BEGIN
    SELECT properties->'steps' INTO v_steps
    FROM nodes
    WHERE id = p_template_id;

    IF p_regarding_ids IS NOT NULL AND array_length(p_regarding_ids, 1) > 0 THEN
        v_regarding_roles := array_fill('subject'::text, ARRAY[array_length(p_regarding_ids, 1)]);
    ELSE
        v_regarding_roles := '{}'::text[];
    END IF;

    FOR v_step IN
        SELECT value
        FROM jsonb_array_elements(v_steps)
        ORDER BY (value->>'order')::int
    LOOP
        v_title := v_step->>'title_template';

        FOR v_key, v_value IN
            SELECT * FROM jsonb_each_text(p_context)
        LOOP
            v_title := replace(v_title, '{' || v_key || '}', v_value);
        END LOOP;

        v_task_id := create_task(
            p_title := v_title,
            p_project_id := p_project_id,
            p_properties := jsonb_build_object(
                'task_type', v_step->>'task_type',
                'estimated_hours', (v_step->>'estimated_hours')::numeric,
                'workflow_step', (v_step->>'order')::int
            ),
            p_teams := p_teams,
            p_regarding_ids := p_regarding_ids,
            p_regarding_roles := v_regarding_roles
        );

        v_task_ids := v_task_ids || v_task_id;

        IF v_step->'depends_on' IS NOT NULL THEN
            INSERT INTO edges (edge_type, source_id, target_id, properties)
            SELECT
                'depends_on',
                v_task_id,
                v_task_ids[(dep_idx)::int],
                '{"dependency_type": "finish_to_start"}'::jsonb
            FROM jsonb_array_elements_text(v_step->'depends_on') AS dep_idx;
        END IF;
    END LOOP;

    RETURN v_task_ids;
END;
$$ LANGUAGE plpgsql;

CREATE MATERIALIZED VIEW IF NOT EXISTS task_board AS
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
