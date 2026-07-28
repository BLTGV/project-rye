-- Preserve future-safe temporal semantics for scope policies.
--
-- Earlier onboarding helpers accepted source-policy effective dates but stored
-- them only in the claim body. This overload lets callers pass the effective
-- date into record_assertion so current/future/historical queries stay aligned.

SET search_path = rye, pg_catalog, public;

DROP FUNCTION IF EXISTS record_scope_policy(uuid, text, jsonb, text, text);

CREATE OR REPLACE FUNCTION record_scope_policy(
    p_scope_id uuid,
    p_policy_type text,
    p_claim jsonb,
    p_assertion_key text DEFAULT 'default',
    p_actor text DEFAULT NULL,
    p_effective_at timestamptz DEFAULT NULL,
    p_effective_to timestamptz DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_id uuid;
    v_event_id uuid;
    v_policy_type text;
BEGIN
    v_policy_type := nullif(trim(p_policy_type), '');

    IF v_policy_type IS NULL THEN
        RAISE EXCEPTION 'policy_type is required';
    END IF;

    IF p_claim IS NULL THEN
        RAISE EXCEPTION 'claim is required';
    END IF;

    IF p_effective_at IS NOT NULL
       AND p_effective_to IS NOT NULL
       AND p_effective_to <= p_effective_at
    THEN
        RAISE EXCEPTION 'effective_to must be after effective_at';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = p_scope_id
          AND node_type = 'onboarding_scope'
          AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Onboarding scope % not found', p_scope_id;
    END IF;

    v_event_id := record_event(
        p_event_type        := 'scope_policy_recorded',
        p_summary           := format('Scope policy recorded: %s', v_policy_type),
        p_properties        := jsonb_build_object(
            'scope_id', p_scope_id,
            'policy_type', v_policy_type,
            'assertion_key', coalesce(nullif(trim(p_assertion_key), ''), 'default'),
            'effective_at', p_effective_at,
            'effective_to', p_effective_to
        ),
        p_participant_ids   := ARRAY[p_scope_id],
        p_participant_roles := ARRAY['scope'],
        p_actor             := p_actor
    );

    v_assertion_id := record_assertion(
        p_assertion_type  := v_policy_type,
        p_assertion_key   := p_assertion_key,
        p_subject_node_id := p_scope_id,
        p_claim           := p_claim,
        p_effective_at    := p_effective_at,
        p_effective_to    := p_effective_to,
        p_evidence         := ARRAY[jsonb_build_object('kind', 'source', 'event_id', v_event_id)],
        p_basis            := 'reported',
        p_confidence      := 1.0,
        p_attrs           := jsonb_build_object('policy_event_id', v_event_id)
    );

    RETURN v_assertion_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_source_of_truth_policy(
    p_scope_id uuid,
    p_status_domain text,
    p_authoritative_source text,
    p_effective_at timestamptz DEFAULT NULL,
    p_review_gate text DEFAULT NULL,
    p_evidence_allowed text[] DEFAULT '{}'::text[],
    p_supersedes text DEFAULT NULL,
    p_notes text DEFAULT NULL,
    p_actor text DEFAULT NULL,
    p_assertion_key text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_id uuid;
    v_domain text;
    v_key text;
    v_source text;
BEGIN
    v_domain := nullif(trim(p_status_domain), '');
    v_source := nullif(trim(p_authoritative_source), '');

    IF v_domain IS NULL THEN
        RAISE EXCEPTION 'status_domain is required';
    END IF;

    IF v_source IS NULL THEN
        RAISE EXCEPTION 'authoritative_source is required';
    END IF;

    v_key := coalesce(rye_slugify_key(p_assertion_key), rye_slugify_key(v_domain));
    IF v_key IS NULL THEN
        RAISE EXCEPTION 'assertion key could not be derived from status_domain';
    END IF;

    v_assertion_id := record_scope_policy(
        p_scope_id      := p_scope_id,
        p_policy_type   := 'source_of_truth_policy',
        p_assertion_key := v_key,
        p_claim         := jsonb_build_object(
            'status_domain', v_domain,
            'authoritative_source', v_source,
            'effective_at', p_effective_at,
            'review_gate', p_review_gate,
            'evidence_allowed', to_jsonb(coalesce(p_evidence_allowed, '{}'::text[])),
            'supersedes', nullif(trim(coalesce(p_supersedes, '')), ''),
            'notes', p_notes
        ),
        p_actor         := p_actor,
        p_effective_at  := p_effective_at
    );

    RETURN v_assertion_id;
END;
$$ LANGUAGE plpgsql;
