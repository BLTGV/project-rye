-- Anchor create_opportunity's initial deal_stage assertion to a source event.
--
-- 0100_profile_crm.sql was fixed in place, but databases that already ran it
-- never re-apply the file, so they still have the provenance-less helper with
-- the old signature. Because the new p_source_event_id parameter is defaulted,
-- CREATE OR REPLACE alone would add an ambiguous overload next to the old
-- function; the old signature must be dropped first. Fresh installs get the
-- fixed helper from 0100 and both statements here are no-ops.

SET search_path = rye, pg_catalog, public;

DROP FUNCTION IF EXISTS create_opportunity(text, text, uuid, jsonb, text[]);

CREATE OR REPLACE FUNCTION create_opportunity(
    p_name text,
    p_pipeline_code text,
    p_assigned_to_id uuid,
    p_properties jsonb DEFAULT '{}',
    p_teams text[] DEFAULT '{}',
    p_source_event_id uuid DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog, public
AS $$
DECLARE
    v_opp_id uuid;
    v_code text;
    v_pipeline_id uuid;
    v_default_stage text;
    v_event_id uuid;
BEGIN
    v_code := generate_crm_code('OPP');

    SELECT id, properties->>'default_stage'
    INTO v_pipeline_id, v_default_stage
    FROM nodes
    WHERE node_type = 'pipeline'
      AND properties->>'code' = p_pipeline_code
      AND archived_at IS NULL
    LIMIT 1;

    IF v_pipeline_id IS NULL THEN
        RAISE EXCEPTION 'Pipeline with code % not found', p_pipeline_code;
    END IF;

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES (
        'opportunity',
        p_name,
        p_properties || jsonb_build_object('name', p_name, 'code', v_code),
        jsonb_build_object('teams', to_jsonb(p_teams))
        || CASE WHEN array_length(p_teams, 1) > 0
                THEN jsonb_build_object('classification', 'internal')
                ELSE '{}'::jsonb
           END,
        v_code,
        'internal'
    )
    RETURNING id INTO v_opp_id;

    -- Record creation event (parallel to create_task's task_created)
    v_event_id := record_event(
        p_event_type        := 'opportunity_created',
        p_summary           := format('Created %s: %s', v_code, p_name),
        p_properties        := jsonb_build_object(
            'opp_code', v_code,
            'pipeline', p_pipeline_code,
            'initial_stage', v_default_stage
        ),
        p_participant_ids   := ARRAY[v_opp_id],
        p_participant_roles := ARRAY['subject']
    );

    -- Initial stage assertion is anchored to the caller's source event when
    -- provided, otherwise to the creation event, so provenance is never NULL
    PERFORM record_assertion(
        p_assertion_type := 'deal_stage',
        p_assertion_key := 'default',
        p_subject_node_id := v_opp_id,
        p_claim := jsonb_build_object('stage', v_default_stage, 'pipeline', p_pipeline_code),
        p_evidence := ARRAY[jsonb_build_object('kind', 'source', 'event_id', coalesce(p_source_event_id, v_event_id))],
        p_basis := 'reported',
        p_confidence := 1.0
    );

    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES (
        'pipeline_member',
        v_opp_id,
        v_pipeline_id,
        jsonb_build_object('entered_at', now())
    );

    IF p_assigned_to_id IS NOT NULL THEN
        INSERT INTO edges (edge_type, source_id, target_id, properties, effective_from)
        VALUES ('assigned_to', v_opp_id, p_assigned_to_id, '{"role": "owner"}', now());
    END IF;

    RETURN v_opp_id;
END;
$$ LANGUAGE plpgsql;
