-- Generic future-effective assertion scheduling.

SET search_path = rye, pg_catalog, public;

CREATE OR REPLACE FUNCTION schedule_assertion_change(
    p_subject_node_id uuid,
    p_subject_edge_id uuid,
    p_assertion_type text,
    p_assertion_key text,
    p_claim jsonb,
    p_effective_at timestamptz,
    p_reason text DEFAULT NULL,
    p_actor text DEFAULT NULL,
    p_basis text DEFAULT 'reported',
    p_confidence numeric DEFAULT NULL,
    p_evidence jsonb[] DEFAULT NULL,
    p_attrs jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_event_id uuid;
    v_participant_ids uuid[] := '{}'::uuid[];
    v_participant_roles text[] := '{}'::text[];
    v_scheduled_id uuid;
BEGIN
    IF p_effective_at IS NULL OR p_effective_at <= now() THEN
        RAISE EXCEPTION 'Scheduled assertion effective_at must be in the future';
    END IF;
    IF (p_subject_node_id IS NULL) = (p_subject_edge_id IS NULL) THEN
        RAISE EXCEPTION 'Exactly one assertion subject is required';
    END IF;

    IF p_subject_node_id IS NOT NULL THEN
        v_participant_ids := ARRAY[p_subject_node_id];
        v_participant_roles := ARRAY['subject'];
    ELSE
        SELECT ARRAY[source_id, target_id], ARRAY['edge_source', 'edge_target']
        INTO v_participant_ids, v_participant_roles
        FROM edges
        WHERE id = p_subject_edge_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Subject edge % not found', p_subject_edge_id;
        END IF;
    END IF;

    v_event_id := record_event(
        p_event_type := 'assertion_change_scheduled',
        p_summary := format(
            'Scheduled %s/%s for %s',
            p_assertion_type,
            coalesce(nullif(trim(p_assertion_key), ''), 'default'),
            p_effective_at
        ),
        p_properties := jsonb_build_object(
            'subject_node_id', p_subject_node_id,
            'subject_edge_id', p_subject_edge_id,
            'assertion_type', p_assertion_type,
            'assertion_key', coalesce(nullif(trim(p_assertion_key), ''), 'default'),
            'claim', p_claim,
            'effective_at', p_effective_at,
            'reason', p_reason
        ),
        p_participant_ids := v_participant_ids,
        p_participant_roles := v_participant_roles,
        p_actor := p_actor,
        p_occurred_at := now()
    );

    v_scheduled_id := record_assertion(
        p_assertion_type := p_assertion_type,
        p_assertion_key := p_assertion_key,
        p_subject_node_id := p_subject_node_id,
        p_subject_edge_id := p_subject_edge_id,
        p_claim := p_claim,
        p_effective_at := p_effective_at,
        p_confidence := p_confidence,
        p_status := 'accepted',
        p_basis := p_basis,
        p_evidence := ARRAY[
            jsonb_build_object('kind', 'source', 'event_id', v_event_id)
        ] || coalesce(p_evidence, '{}'::jsonb[]),
        p_attrs := coalesce(p_attrs, '{}'::jsonb)
            || jsonb_build_object(
                'scheduled', true,
                'schedule_event_id', v_event_id,
                'reason', p_reason
            )
    );

    RETURN v_scheduled_id;
END;
$$ LANGUAGE plpgsql;
