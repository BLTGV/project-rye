-- Atomic, explainable evaluation and application of governed process transitions.

SET search_path = rye, pg_catalog, public;

CREATE TABLE IF NOT EXISTS process_transition_decisions (
    id                              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    candidate_id                    uuid NOT NULL REFERENCES nodes(id),
    subject_node_id                 uuid REFERENCES nodes(id),
    process_node_id                 uuid REFERENCES nodes(id),
    actor_node_id                   uuid REFERENCES nodes(id),
    actor_ref                       text NOT NULL,
    evaluated_for                   timestamptz NOT NULL,
    decision                        text NOT NULL CHECK (decision IN ('allow', 'review', 'deny')),
    reason_codes                    text[] NOT NULL DEFAULT '{}',
    process_definition_assertion_id uuid REFERENCES assertions(id),
    transition_policy_assertion_id  uuid REFERENCES assertions(id),
    matched_authority_ids           uuid[] NOT NULL DEFAULT '{}',
    state_assertion_type            text,
    prior_state                     text,
    proposed_state                  text,
    transition_key                  text,
    impact                          text,
    reversible                      boolean,
    missing_evidence                text[] NOT NULL DEFAULT '{}',
    missing_prior_steps             text[] NOT NULL DEFAULT '{}',
    source_event_id                 uuid NOT NULL REFERENCES events(id),
    applied_assertion_id            uuid REFERENCES assertions(id),
    policy_snapshot                 jsonb NOT NULL DEFAULT '{}',
    request_snapshot                jsonb NOT NULL DEFAULT '{}',
    created_at                      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_process_transition_decisions_candidate
    ON process_transition_decisions (candidate_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_process_transition_decisions_subject_time
    ON process_transition_decisions (subject_node_id, evaluated_for DESC);

ALTER TABLE process_transition_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE process_transition_decisions FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS process_transition_decisions_admin_read ON process_transition_decisions;
CREATE POLICY process_transition_decisions_admin_read ON process_transition_decisions
    FOR SELECT
    USING (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS process_transition_decisions_admin_insert ON process_transition_decisions;
CREATE POLICY process_transition_decisions_admin_insert ON process_transition_decisions
    FOR INSERT
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS process_transition_decisions_no_update ON process_transition_decisions;
CREATE POLICY process_transition_decisions_no_update ON process_transition_decisions
    FOR UPDATE
    USING (false);

DROP POLICY IF EXISTS process_transition_decisions_no_delete ON process_transition_decisions;
CREATE POLICY process_transition_decisions_no_delete ON process_transition_decisions
    FOR DELETE
    USING (false);

CREATE OR REPLACE FUNCTION process_actor_authority_matches(
    p_authority_kind text,
    p_authority_ref text,
    p_actor_ref text,
    p_actor_node_id uuid,
    p_as_of timestamptz
) RETURNS boolean
SET search_path = rye, pg_catalog
AS $$
    SELECT
        p_authority_ref = p_actor_ref
        OR (
            p_actor_node_id IS NOT NULL
            AND p_authority_kind IN ('person', 'source', 'system')
            AND p_authority_ref = ANY(ARRAY[
                p_actor_node_id::text,
                'node:' || p_actor_node_id::text,
                coalesce((SELECT external_id FROM nodes WHERE id = p_actor_node_id), ''),
                coalesce((SELECT external_source || ':' || external_id FROM nodes WHERE id = p_actor_node_id), '')
            ])
        )
        OR (
            p_actor_node_id IS NOT NULL
            AND p_authority_kind IN ('role', 'team')
            AND EXISTS (
                SELECT 1
                FROM edges role_edge
                JOIN nodes role_node ON role_node.id = role_edge.target_id
                WHERE role_edge.source_id = p_actor_node_id
                  AND role_edge.edge_type IN ('holds_role', 'member_of')
                  AND role_edge.archived_at IS NULL
                  AND role_node.archived_at IS NULL
                  AND (role_edge.effective_from IS NULL OR role_edge.effective_from <= p_as_of)
                  AND (role_edge.effective_to IS NULL OR role_edge.effective_to > p_as_of)
                  AND p_authority_ref = ANY(ARRAY[
                      role_node.id::text,
                      'node:' || role_node.id::text,
                      coalesce(role_node.external_id, ''),
                      p_authority_kind || ':' || coalesce(role_node.external_id, rye_slugify_key(role_node.label)),
                      p_authority_kind || ':' || rye_slugify_key(role_node.label)
                  ])
            )
        );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION process_evidence_has_key(
    p_target_payload jsonb,
    p_evidence_key text
) RETURNS boolean
SET search_path = rye, pg_catalog
AS $$
    SELECT
        (
            jsonb_typeof(coalesce(p_target_payload->'evidence', '{}'::jsonb)) = 'object'
            AND coalesce(p_target_payload->'evidence', '{}'::jsonb) ? p_evidence_key
            AND coalesce(
                nullif(trim(coalesce(p_target_payload->'evidence'->>p_evidence_key, '')), ''),
                CASE
                    WHEN p_target_payload->'evidence'->p_evidence_key IN ('true'::jsonb, '1'::jsonb)
                        THEN 'present'
                    ELSE NULL
                END
            ) IS NOT NULL
        )
        OR EXISTS (
            SELECT 1
            FROM jsonb_array_elements(
                CASE
                    WHEN jsonb_typeof(p_target_payload->'evidence_refs') = 'array'
                        THEN p_target_payload->'evidence_refs'
                    ELSE '[]'::jsonb
                END
            ) evidence_ref
            WHERE evidence_ref->>'key' = p_evidence_key
               OR evidence_ref->>'type' = p_evidence_key
               OR evidence_ref->>'evidence_type' = p_evidence_key
        );
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION apply_allowed_process_transition(
    p_decision_id uuid,
    p_candidate_id uuid,
    p_subject_node_id uuid,
    p_state_assertion_type text,
    p_to_state text,
    p_claim jsonb,
    p_effective_at timestamptz,
    p_confidence numeric,
    p_actor text
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_candidate nodes;
    v_event_id uuid;
    v_assertion_id uuid;
    v_source_refs jsonb;
BEGIN
    SELECT * INTO v_candidate
    FROM nodes
    WHERE id = p_candidate_id
      AND node_type = 'knowledge_candidate'
      AND archived_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Knowledge candidate % not found', p_candidate_id;
    END IF;

    v_source_refs := knowledge_candidate_source_refs(p_candidate_id);
    v_event_id := record_event(
        p_event_type        := 'knowledge_candidate_promoted',
        p_summary           := format(
            'Governed process transition promoted: %s',
            left(coalesce(v_candidate.label, p_candidate_id::text), 120)
        ),
        p_properties        := jsonb_build_object(
            'candidate_id', p_candidate_id,
            'target_type', 'assertion',
            'subject_node_id', p_subject_node_id,
            'assertion_type', p_state_assertion_type,
            'assertion_key', 'default',
            'process_transition_decision_id', p_decision_id,
            'source_refs', v_source_refs
        ),
        p_participant_ids   := ARRAY[p_candidate_id, p_subject_node_id],
        p_participant_roles := ARRAY['candidate', 'subject'],
        p_actor             := p_actor
    );

    v_assertion_id := record_assertion(
        p_assertion_type  := p_state_assertion_type,
        p_claim           := coalesce(p_claim, jsonb_build_object('state', p_to_state)),
        p_subject_node_id := p_subject_node_id,
        p_assertion_key   := 'default',
        p_effective_at    := p_effective_at,
        p_source_event_id := v_event_id,
        p_confidence      := p_confidence,
        p_mode            := 'current',
        p_attrs           := jsonb_build_object(
            'candidate_id', p_candidate_id,
            'source_refs', v_source_refs,
            'promotion_event_id', v_event_id,
            'process_transition_decision_id', p_decision_id,
            'promoted_by', p_actor
        )
    );

    PERFORM set_candidate_status(
        p_candidate_id := p_candidate_id,
        p_status       := 'accepted',
        p_reason       := 'Allowed by process transition decision ' || p_decision_id::text,
        p_actor        := p_actor
    );

    RETURN v_assertion_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION evaluate_process_transition(
    p_candidate_id uuid,
    p_actor_ref text,
    p_actor_node_id uuid DEFAULT NULL,
    p_as_of timestamptz DEFAULT now(),
    p_apply boolean DEFAULT false
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_candidate nodes;
    v_target jsonb;
    v_candidate_status text;
    v_subject_id uuid;
    v_process_id uuid;
    v_process_key text;
    v_transition_key text;
    v_to_state text;
    v_requested_from_state text;
    v_current_state text;
    v_state_assertion_type text;
    v_speech_act text;
    v_process_definition assertions;
    v_transition_policy assertions;
    v_domain_keys text[] := '{}';
    v_missing_evidence text[] := '{}';
    v_missing_prior_steps text[] := '{}';
    v_reason_codes text[] := '{}';
    v_authority_ids uuid[] := '{}';
    v_authority_domain_count integer := 0;
    v_required_domain_count integer := 0;
    v_decision text;
    v_decision_id uuid := gen_random_uuid();
    v_event_id uuid;
    v_assertion_id uuid;
    v_claim jsonb;
    v_state_field text;
    v_policy_snapshot jsonb := '{}';
    v_previous_role text;
    v_result jsonb;
    v_participant_ids uuid[];
    v_participant_roles text[];
BEGIN
    IF nullif(trim(coalesce(p_actor_ref, '')), '') IS NULL THEN
        RAISE EXCEPTION 'actor_ref is required' USING ERRCODE = '22023';
    END IF;

    v_previous_role := current_setting('app.current_role', true);
    PERFORM set_config('app.current_role', 'admin', true);

    SELECT candidate_row.*
    INTO v_candidate
    FROM nodes candidate_row
    WHERE candidate_row.id = p_candidate_id
      AND candidate_row.node_type = 'knowledge_candidate'
      AND candidate_row.archived_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Knowledge candidate % not found', p_candidate_id;
    END IF;

    SELECT coalesce(status_assertion.claim->>'status', 'proposed')
    INTO v_candidate_status
    FROM (SELECT 1) singleton
    LEFT JOIN current_valid_assertions status_assertion
      ON status_assertion.subject_node_id = p_candidate_id
     AND status_assertion.assertion_type = 'candidate_status'
     AND status_assertion.assertion_key = 'default';

    IF v_candidate_status = 'accepted' THEN
        SELECT jsonb_build_object(
            'decision_id', decision_row.id,
            'decision', decision_row.decision,
            'reason_codes', to_jsonb(decision_row.reason_codes),
            'candidate_id', decision_row.candidate_id,
            'subject_node_id', decision_row.subject_node_id,
            'process_node_id', decision_row.process_node_id,
            'evaluated_for', decision_row.evaluated_for,
            'prior_state', decision_row.prior_state,
            'proposed_state', decision_row.proposed_state,
            'impact', decision_row.impact,
            'reversible', decision_row.reversible,
            'missing_evidence', to_jsonb(decision_row.missing_evidence),
            'missing_prior_steps', to_jsonb(decision_row.missing_prior_steps),
            'process_definition_assertion_id', decision_row.process_definition_assertion_id,
            'transition_policy_assertion_id', decision_row.transition_policy_assertion_id,
            'applied', decision_row.applied_assertion_id IS NOT NULL,
            'applied_assertion_id', decision_row.applied_assertion_id,
            'idempotent_replay', true
        )
        INTO v_result
        FROM process_transition_decisions decision_row
        WHERE decision_row.candidate_id = p_candidate_id
          AND decision_row.decision = 'allow'
          AND decision_row.applied_assertion_id IS NOT NULL
        ORDER BY decision_row.created_at DESC
        LIMIT 1;

        IF v_result IS NOT NULL THEN
            PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
            RETURN v_result;
        END IF;
    END IF;

    IF v_candidate_status NOT IN ('proposed', 'needs_review') THEN
        RAISE EXCEPTION 'Candidate % is not open for process evaluation (status %)',
            p_candidate_id, v_candidate_status USING ERRCODE = '55000';
    END IF;

    v_target := coalesce(v_candidate.properties->'target_payload', '{}'::jsonb);

    BEGIN
        v_subject_id := nullif(v_target->>'subject_node_id', '')::uuid;
        v_process_id := nullif(v_target->>'process_node_id', '')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'Process candidate subject_node_id and process_node_id must be UUIDs'
            USING ERRCODE = '22023';
    END;

    v_process_key := nullif(trim(coalesce(v_target->>'process_key', '')), '');
    v_transition_key := nullif(trim(coalesce(v_target->>'transition_key', '')), '');
    v_to_state := nullif(trim(coalesce(v_target->>'to_state', '')), '');
    v_requested_from_state := nullif(trim(coalesce(v_target->>'from_state', '')), '');
    v_speech_act := lower(coalesce(nullif(trim(v_target->>'speech_act'), ''), 'reported'));

    v_domain_keys := ARRAY(
        SELECT DISTINCT rye_slugify_key(value)
        FROM jsonb_array_elements_text(
            CASE
                WHEN jsonb_typeof(v_target->'domain_keys') = 'array'
                    THEN v_target->'domain_keys'
                ELSE '[]'::jsonb
            END
        ) requested(value)
        WHERE rye_slugify_key(value) IS NOT NULL
        ORDER BY rye_slugify_key(value)
    );

    IF v_subject_id IS NULL THEN
        v_reason_codes := array_append(v_reason_codes, 'missing_subject');
    ELSIF NOT EXISTS (SELECT 1 FROM nodes WHERE id = v_subject_id AND archived_at IS NULL) THEN
        v_reason_codes := array_append(v_reason_codes, 'unknown_subject');
        v_subject_id := NULL;
    END IF;

    IF v_process_id IS NULL THEN
        v_reason_codes := array_append(v_reason_codes, 'missing_process');
    ELSIF NOT EXISTS (SELECT 1 FROM nodes WHERE id = v_process_id AND archived_at IS NULL) THEN
        v_reason_codes := array_append(v_reason_codes, 'unknown_process');
        v_process_id := NULL;
    END IF;

    IF p_actor_node_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM nodes WHERE id = p_actor_node_id AND archived_at IS NULL)
    THEN
        RAISE EXCEPTION 'Actor node % not found', p_actor_node_id USING ERRCODE = '22023';
    END IF;

    IF v_to_state IS NULL THEN
        v_reason_codes := array_append(v_reason_codes, 'missing_proposed_state');
    END IF;

    IF cardinality(v_domain_keys) = 0 THEN
        v_reason_codes := array_append(v_reason_codes, 'missing_domain');
    ELSIF EXISTS (
        SELECT 1
        FROM unnest(v_domain_keys) requested(domain_key)
        WHERE NOT EXISTS (
            SELECT 1 FROM knowledge_domains domain_row
            WHERE domain_row.domain_key = requested.domain_key
              AND domain_row.archived_at IS NULL
        )
    ) THEN
        v_reason_codes := array_append(v_reason_codes, 'unknown_domain');
    END IF;

    IF v_process_id IS NOT NULL THEN
        SELECT assertion_row.*
        INTO v_process_definition
        FROM assertions assertion_row
        WHERE assertion_row.subject_node_id = v_process_id
          AND assertion_row.assertion_type = 'process_definition'
          AND assertion_row.assertion_key = 'default'
          AND coalesce(assertion_row.attrs->>'record_mode', 'current') = 'current'
          AND assertion_row.asserted_at <= coalesce(p_as_of, now())
          AND (assertion_row.effective_at IS NULL OR assertion_row.effective_at <= coalesce(p_as_of, now()))
          AND (assertion_row.effective_to IS NULL OR assertion_row.effective_to > coalesce(p_as_of, now()))
          AND (assertion_row.superseded_at IS NULL OR assertion_row.superseded_at > coalesce(p_as_of, now()))
          AND (v_process_key IS NULL OR assertion_row.claim->>'process_key' = v_process_key)
        ORDER BY assertion_row.effective_at DESC NULLS LAST, assertion_row.asserted_at DESC
        LIMIT 1;
    END IF;

    IF v_process_definition.id IS NULL THEN
        v_reason_codes := array_append(v_reason_codes, 'missing_process_definition');
    ELSE
        v_process_key := coalesce(v_process_key, v_process_definition.claim->>'process_key');
        v_state_assertion_type := nullif(v_process_definition.claim->>'state_assertion_type', '');
        IF v_to_state IS NOT NULL
           AND NOT coalesce(v_process_definition.claim->'states', '[]'::jsonb) ? v_to_state
        THEN
            v_reason_codes := array_append(v_reason_codes, 'proposed_state_not_in_process');
        END IF;
    END IF;

    IF v_subject_id IS NOT NULL AND v_state_assertion_type IS NOT NULL THEN
        SELECT coalesce(
            assertion_row.claim->>'state',
            assertion_row.claim->>'stage',
            assertion_row.claim->>'status',
            assertion_row.claim->>'value'
        )
        INTO v_current_state
        FROM assertions assertion_row
        WHERE assertion_row.subject_node_id = v_subject_id
          AND assertion_row.assertion_type = v_state_assertion_type
          AND assertion_row.assertion_key = 'default'
          AND coalesce(assertion_row.attrs->>'record_mode', 'current') = 'current'
          AND assertion_row.asserted_at <= coalesce(p_as_of, now())
          AND (assertion_row.effective_at IS NULL OR assertion_row.effective_at <= coalesce(p_as_of, now()))
          AND (assertion_row.effective_to IS NULL OR assertion_row.effective_to > coalesce(p_as_of, now()))
          AND (assertion_row.superseded_at IS NULL OR assertion_row.superseded_at > coalesce(p_as_of, now()))
        ORDER BY assertion_row.effective_at DESC NULLS LAST, assertion_row.asserted_at DESC
        LIMIT 1;
    END IF;

    IF v_state_assertion_type IS NOT NULL AND v_current_state IS NULL THEN
        v_reason_codes := array_append(v_reason_codes, 'missing_current_state');
    ELSIF v_requested_from_state IS NOT NULL
       AND v_current_state IS DISTINCT FROM v_requested_from_state
    THEN
        v_reason_codes := array_append(v_reason_codes, 'current_state_mismatch');
    END IF;

    IF v_process_id IS NOT NULL AND v_to_state IS NOT NULL THEN
        SELECT assertion_row.*
        INTO v_transition_policy
        FROM assertions assertion_row
        WHERE assertion_row.subject_node_id = v_process_id
          AND assertion_row.assertion_type = 'process_transition_policy'
          AND coalesce(assertion_row.attrs->>'record_mode', 'current') = 'current'
          AND assertion_row.asserted_at <= coalesce(p_as_of, now())
          AND (assertion_row.effective_at IS NULL OR assertion_row.effective_at <= coalesce(p_as_of, now()))
          AND (assertion_row.effective_to IS NULL OR assertion_row.effective_to > coalesce(p_as_of, now()))
          AND (assertion_row.superseded_at IS NULL OR assertion_row.superseded_at > coalesce(p_as_of, now()))
          AND assertion_row.claim->>'process_key' = v_process_key
          AND assertion_row.claim->>'to_state' = v_to_state
          AND (v_transition_key IS NULL OR assertion_row.claim->>'transition_key' = v_transition_key)
          AND (
              v_current_state IS NULL
              OR coalesce(assertion_row.claim->'from_states', '[]'::jsonb) ? v_current_state
          )
        ORDER BY assertion_row.effective_at DESC NULLS LAST, assertion_row.asserted_at DESC
        LIMIT 1;
    END IF;

    IF v_transition_policy.id IS NULL THEN
        v_reason_codes := array_append(v_reason_codes, 'missing_transition_policy');
    ELSE
        v_transition_key := v_transition_policy.claim->>'transition_key';

        v_missing_evidence := ARRAY(
            SELECT required_key
            FROM jsonb_array_elements_text(
                coalesce(v_transition_policy.claim->'required_evidence', '[]'::jsonb)
            ) required(required_key)
            WHERE NOT process_evidence_has_key(v_target, required_key)
            ORDER BY required_key
        );

        v_missing_prior_steps := ARRAY(
            SELECT required_step
            FROM jsonb_array_elements_text(
                coalesce(v_transition_policy.claim->'required_prior_steps', '[]'::jsonb)
            ) required(required_step)
            WHERE NOT coalesce(v_target->'completed_steps', '[]'::jsonb) ? required_step
            ORDER BY required_step
        );

        IF cardinality(v_missing_evidence) > 0 THEN
            v_reason_codes := array_append(v_reason_codes, 'missing_evidence');
        END IF;
        IF cardinality(v_missing_prior_steps) > 0 THEN
            v_reason_codes := array_append(v_reason_codes, 'missing_prior_steps');
        END IF;
    END IF;

    IF v_speech_act NOT IN ('approved', 'decided') THEN
        v_reason_codes := array_append(v_reason_codes, 'decision_speech_act_required');
    END IF;

    v_required_domain_count := cardinality(v_domain_keys);
    IF v_required_domain_count > 0
       AND v_transition_policy.id IS NOT NULL
       AND v_speech_act IN ('approved', 'decided')
    THEN
        SELECT
            coalesce(array_agg(authority_match.id ORDER BY authority_match.id), '{}'::uuid[]),
            count(DISTINCT authority_match.domain_id)::integer
        INTO v_authority_ids, v_authority_domain_count
        FROM (
            SELECT authority_row.id, authority_row.domain_id
            FROM domain_authorities authority_row
            JOIN knowledge_domains domain_row ON domain_row.id = authority_row.domain_id
            WHERE domain_row.domain_key = ANY(v_domain_keys)
              AND authority_row.active = true
              AND authority_row.effective_at <= coalesce(p_as_of, now())
              AND (authority_row.effective_to IS NULL OR authority_row.effective_to > coalesce(p_as_of, now()))
              AND (authority_row.scope_ref IS NULL OR authority_row.scope_ref = v_target->>'source_scope')
              AND (
                  cardinality(authority_row.claim_types) = 0
                  OR v_state_assertion_type = ANY(authority_row.claim_types)
                  OR 'process_transition' = ANY(authority_row.claim_types)
              )
              AND v_speech_act = ANY(authority_row.speech_acts)
              AND process_actor_authority_matches(
                  authority_row.authority_kind,
                  authority_row.authority_ref,
                  p_actor_ref,
                  p_actor_node_id,
                  coalesce(p_as_of, now())
              )
              AND coalesce(
                  v_transition_policy.claim->'authority'->'may_decide',
                  '[]'::jsonb
              ) ? authority_row.authority_ref
        ) authority_match;
    END IF;

    IF v_required_domain_count > 0
       AND v_authority_domain_count < v_required_domain_count
    THEN
        v_reason_codes := array_append(v_reason_codes, 'missing_decision_authority');
    END IF;

    v_reason_codes := ARRAY(
        SELECT DISTINCT reason
        FROM unnest(v_reason_codes) reason
        ORDER BY reason
    );

    IF 'current_state_mismatch' = ANY(v_reason_codes)
       OR 'proposed_state_not_in_process' = ANY(v_reason_codes)
       OR (
           v_transition_policy.id IS NOT NULL
           AND coalesce(v_transition_policy.claim->>'exception_policy', 'review') = 'never'
           AND (
               'missing_evidence' = ANY(v_reason_codes)
               OR 'missing_prior_steps' = ANY(v_reason_codes)
           )
       )
    THEN
        v_decision := 'deny';
    ELSIF cardinality(v_reason_codes) > 0 THEN
        v_decision := 'review';
    ELSE
        v_decision := 'allow';
    END IF;

    v_policy_snapshot := jsonb_strip_nulls(jsonb_build_object(
        'process_definition_assertion_id', v_process_definition.id,
        'process_definition_claim', v_process_definition.claim,
        'transition_policy_assertion_id', v_transition_policy.id,
        'transition_policy_claim', v_transition_policy.claim,
        'matched_authority_ids', to_jsonb(v_authority_ids),
        'evaluated_for', coalesce(p_as_of, now())
    ));

    v_participant_ids := ARRAY[p_candidate_id];
    v_participant_roles := ARRAY['candidate'];
    IF v_subject_id IS NOT NULL THEN
        v_participant_ids := array_append(v_participant_ids, v_subject_id);
        v_participant_roles := array_append(v_participant_roles, 'subject');
    END IF;
    IF v_process_id IS NOT NULL THEN
        v_participant_ids := array_append(v_participant_ids, v_process_id);
        v_participant_roles := array_append(v_participant_roles, 'process');
    END IF;
    IF p_actor_node_id IS NOT NULL THEN
        v_participant_ids := array_append(v_participant_ids, p_actor_node_id);
        v_participant_roles := array_append(v_participant_roles, 'actor');
    END IF;

    v_event_id := record_event(
        p_event_type        := 'process_transition_evaluated',
        p_summary           := format(
            'Process transition %s: %s to %s',
            v_decision,
            coalesce(v_current_state, '<unknown>'),
            coalesce(v_to_state, '<missing>')
        ),
        p_properties        := jsonb_build_object(
            'decision_id', v_decision_id,
            'candidate_id', p_candidate_id,
            'prior_state', v_current_state,
            'proposed_state', v_to_state,
            'decision', v_decision,
            'reason_codes', to_jsonb(v_reason_codes),
            'missing_evidence', to_jsonb(v_missing_evidence),
            'missing_prior_steps', to_jsonb(v_missing_prior_steps),
            'policy_snapshot', v_policy_snapshot
        ),
        p_participant_ids   := v_participant_ids,
        p_participant_roles := v_participant_roles,
        p_actor             := p_actor_ref
    );

    IF p_apply AND v_decision = 'allow' THEN
        v_state_field := coalesce(nullif(v_target->>'state_field', ''), 'state');
        v_claim := CASE
            WHEN jsonb_typeof(v_target->'claim') = 'object'
                 AND v_target->'claim' <> '{}'::jsonb
                THEN v_target->'claim'
            ELSE jsonb_build_object(v_state_field, v_to_state)
        END;

        v_assertion_id := apply_allowed_process_transition(
            p_decision_id         := v_decision_id,
            p_candidate_id        := p_candidate_id,
            p_subject_node_id     := v_subject_id,
            p_state_assertion_type := v_state_assertion_type,
            p_to_state            := v_to_state,
            p_claim               := v_claim,
            p_effective_at        := coalesce(p_as_of, now()),
            p_confidence          := nullif(v_candidate.properties->>'confidence', '')::numeric,
            p_actor               := p_actor_ref
        );
    ELSIF p_apply AND v_decision = 'review' THEN
        PERFORM set_candidate_status(
            p_candidate_id,
            'needs_review',
            'Process transition requires review: ' || array_to_string(v_reason_codes, ', '),
            p_actor_ref
        );
    ELSIF p_apply AND v_decision = 'deny' THEN
        PERFORM set_candidate_status(
            p_candidate_id,
            'rejected',
            'Process transition denied: ' || array_to_string(v_reason_codes, ', '),
            p_actor_ref
        );
    END IF;

    INSERT INTO process_transition_decisions (
        id,
        candidate_id,
        subject_node_id,
        process_node_id,
        actor_node_id,
        actor_ref,
        evaluated_for,
        decision,
        reason_codes,
        process_definition_assertion_id,
        transition_policy_assertion_id,
        matched_authority_ids,
        state_assertion_type,
        prior_state,
        proposed_state,
        transition_key,
        impact,
        reversible,
        missing_evidence,
        missing_prior_steps,
        source_event_id,
        applied_assertion_id,
        policy_snapshot,
        request_snapshot
    ) VALUES (
        v_decision_id,
        p_candidate_id,
        v_subject_id,
        v_process_id,
        p_actor_node_id,
        p_actor_ref,
        coalesce(p_as_of, now()),
        v_decision,
        v_reason_codes,
        v_process_definition.id,
        v_transition_policy.id,
        v_authority_ids,
        v_state_assertion_type,
        v_current_state,
        v_to_state,
        v_transition_key,
        v_transition_policy.claim->>'impact',
        (v_transition_policy.claim->>'reversible')::boolean,
        v_missing_evidence,
        v_missing_prior_steps,
        v_event_id,
        v_assertion_id,
        v_policy_snapshot,
        jsonb_build_object(
            'actor_ref', p_actor_ref,
            'actor_node_id', p_actor_node_id,
            'target_payload', v_target,
            'apply_requested', coalesce(p_apply, false)
        )
    );

    v_result := jsonb_build_object(
        'decision_id', v_decision_id,
        'decision', v_decision,
        'reason_codes', to_jsonb(v_reason_codes),
        'candidate_id', p_candidate_id,
        'subject_node_id', v_subject_id,
        'process_node_id', v_process_id,
        'process_definition_assertion_id', v_process_definition.id,
        'transition_policy_assertion_id', v_transition_policy.id,
        'matched_authority_ids', to_jsonb(v_authority_ids),
        'evaluated_for', coalesce(p_as_of, now()),
        'prior_state', v_current_state,
        'proposed_state', v_to_state,
        'impact', v_transition_policy.claim->>'impact',
        'reversible', (v_transition_policy.claim->>'reversible')::boolean,
        'missing_evidence', to_jsonb(v_missing_evidence),
        'missing_prior_steps', to_jsonb(v_missing_prior_steps),
        'evaluation_event_id', v_event_id,
        'applied', v_assertion_id IS NOT NULL,
        'applied_assertion_id', v_assertion_id
    );

    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RETURN v_result;
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Process-marked candidates must not bypass the evaluator through the legacy
-- generic assertion promotion function.
CREATE OR REPLACE FUNCTION promote_candidate_to_assertion(
    p_candidate_id uuid,
    p_subject_node_id uuid,
    p_assertion_type text,
    p_assertion_key text,
    p_claim jsonb,
    p_effective_at timestamptz DEFAULT NULL,
    p_effective_to timestamptz DEFAULT NULL,
    p_confidence numeric DEFAULT NULL,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_id uuid;
    v_candidate nodes;
    v_event_id uuid;
    v_source_refs jsonb;
BEGIN
    SELECT * INTO v_candidate
    FROM nodes
    WHERE id = p_candidate_id
      AND node_type = 'knowledge_candidate'
      AND archived_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Knowledge candidate % not found', p_candidate_id;
    END IF;

    IF nullif(v_candidate.properties->'target_payload'->>'process_node_id', '') IS NOT NULL
       OR nullif(v_candidate.properties->'target_payload'->>'transition_key', '') IS NOT NULL
    THEN
        RAISE EXCEPTION 'Governed process candidates must use evaluate_process_transition(..., p_apply => true)'
            USING ERRCODE = '42501';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = p_subject_node_id AND archived_at IS NULL) THEN
        RAISE EXCEPTION 'Subject node % not found', p_subject_node_id;
    END IF;

    v_source_refs := knowledge_candidate_source_refs(p_candidate_id);
    v_event_id := record_event(
        p_event_type        := 'knowledge_candidate_promoted',
        p_summary           := format(
            'Knowledge candidate promoted to assertion: %s',
            left(coalesce(v_candidate.label, p_candidate_id::text), 120)
        ),
        p_properties        := jsonb_build_object(
            'candidate_id', p_candidate_id,
            'target_type', 'assertion',
            'subject_node_id', p_subject_node_id,
            'assertion_type', p_assertion_type,
            'assertion_key', p_assertion_key,
            'source_refs', v_source_refs
        ),
        p_participant_ids   := ARRAY[p_candidate_id, p_subject_node_id],
        p_participant_roles := ARRAY['candidate', 'subject'],
        p_actor             := p_actor
    );

    v_assertion_id := record_assertion(
        p_assertion_type  := p_assertion_type,
        p_claim           := p_claim,
        p_subject_node_id := p_subject_node_id,
        p_assertion_key   := p_assertion_key,
        p_effective_at    := p_effective_at,
        p_effective_to    := p_effective_to,
        p_source_event_id := v_event_id,
        p_confidence      := p_confidence,
        p_mode            := 'current',
        p_attrs           := jsonb_build_object(
            'candidate_id', p_candidate_id,
            'source_refs', v_source_refs,
            'promotion_event_id', v_event_id,
            'promoted_by', coalesce(p_actor, current_setting('app.current_user_id', true))
        )
    );

    PERFORM set_candidate_status(
        p_candidate_id := p_candidate_id,
        p_status       := 'accepted',
        p_reason       := 'Promoted to assertion ' || v_assertion_id::text,
        p_actor        := p_actor
    );

    RETURN v_assertion_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW process_transition_compliance
WITH (security_invoker = true) AS
SELECT
    decision_row.id AS decision_id,
    decision_row.candidate_id,
    decision_row.subject_node_id,
    decision_row.process_node_id,
    decision_row.evaluated_for,
    decision_row.prior_state,
    decision_row.proposed_state,
    decision_row.decision,
    CASE
        WHEN decision_row.decision = 'allow' THEN 'compliant'
        WHEN cardinality(decision_row.missing_evidence) > 0
          OR cardinality(decision_row.missing_prior_steps) > 0
            THEN 'missing_evidence'
        WHEN decision_row.decision = 'deny' THEN 'noncompliant'
        ELSE 'requires_review'
    END AS compliance_class,
    decision_row.reason_codes,
    decision_row.missing_evidence,
    decision_row.missing_prior_steps,
    decision_row.process_definition_assertion_id,
    decision_row.transition_policy_assertion_id,
    decision_row.source_event_id,
    decision_row.applied_assertion_id
FROM process_transition_decisions decision_row;

CREATE OR REPLACE VIEW process_transition_gaps
WITH (security_invoker = true) AS
SELECT
    'process-candidate:' || candidate.id::text AS gap_id,
    CASE
        WHEN decision_row.id IS NULL THEN 'unevaluated_process_candidate'
        ELSE 'reviewable_process_transition'
    END AS gap_type,
    CASE WHEN decision_row.id IS NULL THEN 'high' ELSE 'medium' END AS severity,
    candidate.id AS candidate_id,
    candidate.label,
    decision_row.id AS decision_id,
    decision_row.reason_codes,
    decision_row.missing_evidence,
    decision_row.missing_prior_steps,
    coalesce(decision_row.created_at, candidate.created_at) AS detected_at
FROM nodes candidate
LEFT JOIN LATERAL (
    SELECT decision.*
    FROM process_transition_decisions decision
    WHERE decision.candidate_id = candidate.id
    ORDER BY decision.created_at DESC
    LIMIT 1
) decision_row ON true
LEFT JOIN current_valid_assertions status_assertion
  ON status_assertion.subject_node_id = candidate.id
 AND status_assertion.assertion_type = 'candidate_status'
 AND status_assertion.assertion_key = 'default'
WHERE candidate.node_type = 'knowledge_candidate'
  AND candidate.archived_at IS NULL
  AND (
      nullif(candidate.properties->'target_payload'->>'process_node_id', '') IS NOT NULL
      OR nullif(candidate.properties->'target_payload'->>'transition_key', '') IS NOT NULL
  )
  AND coalesce(status_assertion.claim->>'status', 'proposed') IN ('proposed', 'needs_review')
  AND (decision_row.id IS NULL OR decision_row.decision = 'review');

REVOKE ALL ON process_transition_decisions FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION process_actor_authority_matches(text, text, text, uuid, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION process_evidence_has_key(jsonb, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION apply_allowed_process_transition(uuid, uuid, uuid, text, text, jsonb, timestamptz, numeric, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION evaluate_process_transition(uuid, text, uuid, timestamptz, boolean) FROM PUBLIC;
