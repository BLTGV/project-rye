-- Anchor create_task's initial task_status assertion to a source event.
--
-- 0110_profile_pm.sql was fixed in place, but databases that already ran it
-- never re-apply the file, so they still have the provenance-less helper with
-- the old signature. Because the new p_source_event_id parameter is defaulted,
-- CREATE OR REPLACE alone would add an ambiguous overload next to the old
-- function; the old signature must be dropped first. Fresh installs get the
-- fixed helper from 0110 and both statements here are no-ops.

SET search_path = rye, pg_catalog, public;

DROP FUNCTION IF EXISTS create_task(text, text, uuid, uuid, jsonb, text[], uuid[], text[]);

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
        p_evidence := ARRAY[jsonb_build_object('kind', 'source', 'event_id', coalesce(p_source_event_id, v_event_id))],
        p_basis := 'reported',
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
