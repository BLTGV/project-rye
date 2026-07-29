-- Knowledge mechanisms v2: labeled outcomes, source reputation, predictions,
-- calibration, and induction.

SET search_path = rye, pg_catalog, public;

-- --------------------------------------------------------------------------
-- Helper-controlled outcome labels
-- --------------------------------------------------------------------------

DROP POLICY IF EXISTS assertion_update_policy ON assertions;
CREATE POLICY assertion_update_policy ON assertions
    FOR UPDATE
    USING (
        (current_setting('app.write_path', true) = 'supersede_assertion'
         AND id::text = current_setting('app.supersede_assertion_id', true))
        OR (current_setting('app.write_path', true) = 'assertion_effective_window'
            AND id::text = current_setting('app.effective_window_assertion_id', true))
        OR (current_setting('app.write_path', true) = 'accept_assertion'
            AND id::text = current_setting('app.accept_assertion_id', true))
        OR (current_setting('app.write_path', true) = 'assertion_classification'
            AND id::text = current_setting('app.classification_assertion_id', true))
        OR (current_setting('app.write_path', true) = 'assertion_outcome'
            AND id::text = current_setting('app.outcome_assertion_id', true))
    )
    WITH CHECK (
        (current_setting('app.write_path', true) = 'supersede_assertion'
         AND id::text = current_setting('app.supersede_assertion_id', true))
        OR (current_setting('app.write_path', true) = 'assertion_effective_window'
            AND id::text = current_setting('app.effective_window_assertion_id', true))
        OR (current_setting('app.write_path', true) = 'accept_assertion'
            AND id::text = current_setting('app.accept_assertion_id', true))
        OR (current_setting('app.write_path', true) = 'assertion_classification'
            AND id::text = current_setting('app.classification_assertion_id', true))
        OR (current_setting('app.write_path', true) = 'assertion_outcome'
            AND id::text = current_setting('app.outcome_assertion_id', true))
    );

CREATE OR REPLACE FUNCTION assertions_immutable_guard() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_path text := current_setting('app.write_path', true);
BEGIN
    IF NEW.claim IS DISTINCT FROM OLD.claim
       OR NEW.assertion_type IS DISTINCT FROM OLD.assertion_type
       OR NEW.assertion_key IS DISTINCT FROM OLD.assertion_key
       OR NEW.subject_node_id IS DISTINCT FROM OLD.subject_node_id
       OR NEW.subject_edge_id IS DISTINCT FROM OLD.subject_edge_id
       OR NEW.asserted_at IS DISTINCT FROM OLD.asserted_at
       OR NEW.basis IS DISTINCT FROM OLD.basis
       OR NEW.confidence IS DISTINCT FROM OLD.confidence
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR (
           NEW.attrs IS DISTINCT FROM OLD.attrs
           AND NOT (
               v_path = 'assertion_outcome'
               AND NEW.id::text = current_setting('app.outcome_assertion_id', true)
           )
       )
    THEN
        RAISE EXCEPTION 'Assertion content is immutable';
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status
       AND NOT (
           OLD.status = 'candidate'
           AND NEW.status = 'accepted'
           AND v_path = 'accept_assertion'
           AND NEW.id::text = current_setting('app.accept_assertion_id', true)
       )
    THEN
        RAISE EXCEPTION 'Assertion status may transition only candidate to accepted via accept_assertion()';
    END IF;

    IF NEW.classification IS DISTINCT FROM OLD.classification
       AND NOT (
           v_path = 'assertion_classification'
           AND NEW.id::text = current_setting('app.classification_assertion_id', true)
       )
    THEN
        RAISE EXCEPTION 'Assertion classification is immutable outside evidence propagation';
    END IF;

    IF NEW.effective_at IS DISTINCT FROM OLD.effective_at THEN
        RAISE EXCEPTION 'Assertion effective_at is immutable';
    END IF;

    IF NEW.effective_to IS DISTINCT FROM OLD.effective_to THEN
        IF v_path <> 'assertion_effective_window'
           OR NEW.id::text <> current_setting('app.effective_window_assertion_id', true)
           OR NEW.effective_to IS NULL
           OR (OLD.effective_at IS NOT NULL AND NEW.effective_to <= OLD.effective_at)
           OR (OLD.effective_to IS NOT NULL AND NEW.effective_to > OLD.effective_to)
        THEN
            RAISE EXCEPTION 'Only helper-controlled narrowing of effective_to is allowed';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION mark_assertion_outcome(
    p_assertion_id uuid,
    p_outcome text,
    p_details jsonb DEFAULT '{}'::jsonb
) RETURNS void
SECURITY DEFINER
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_outcome text := lower(nullif(trim(p_outcome), ''));
BEGIN
    IF v_outcome NOT IN (
        'correct', 'incorrect', 'unsupported', 'duplicate', 'stale',
        'displaced', 'corrected', 'unresolvable'
    ) THEN
        RAISE EXCEPTION 'Unsupported assertion outcome: %', p_outcome;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM assertions WHERE id = p_assertion_id) THEN
        RAISE EXCEPTION 'Assertion % not found', p_assertion_id;
    END IF;

    PERFORM set_config('app.write_path', 'assertion_outcome', true);
    PERFORM set_config('app.outcome_assertion_id', p_assertion_id::text, true);
    UPDATE assertions
    SET attrs = attrs
        || coalesce(p_details, '{}'::jsonb)
        || jsonb_build_object('outcome', v_outcome, 'outcome_at', now())
    WHERE id = p_assertion_id;
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.outcome_assertion_id', '', true);
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.outcome_assertion_id', '', true);
    RAISE;
END;
$$ LANGUAGE plpgsql;

REVOKE ALL ON FUNCTION mark_assertion_outcome(uuid, text, jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION agent_can_promote_in_scope(p_scope_id uuid)
RETURNS boolean
SECURITY DEFINER
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_agent_id uuid;
    v_external_scope text;
    v_identity text := current_setting('app.current_user_id', true);
    v_role text := current_setting('app.current_role', true);
BEGIN
    SELECT id INTO v_agent_id
    FROM agent_identities
    WHERE active = true
      AND (
          id::text = v_identity
          OR agent_key = rye_slugify_key(v_identity)
          OR agent_key = rye_slugify_key(regexp_replace(coalesce(v_role, ''), '^agent:', ''))
      )
    ORDER BY CASE WHEN id::text = v_identity THEN 0 ELSE 1 END
    LIMIT 1;

    IF v_agent_id IS NULL THEN
        RETURN false;
    END IF;

    SELECT external_id INTO v_external_scope FROM nodes WHERE id = p_scope_id;
    RETURN has_agent_capability(v_agent_id, 'rye.authoritative.promote', '{}', p_scope_id::text)
        OR (v_external_scope IS NOT NULL
            AND has_agent_capability(v_agent_id, 'rye.authoritative.promote', '{}', v_external_scope));
END;
$$ LANGUAGE plpgsql STABLE;

DROP FUNCTION accept_assertion(uuid, jsonb[], text, text);

CREATE FUNCTION accept_assertion(
    p_assertion_id uuid,
    p_evidence jsonb[] DEFAULT NULL,
    p_reason text DEFAULT NULL,
    p_actor text DEFAULT NULL,
    p_scope_node_id uuid DEFAULT NULL,
    p_supersedes_as text DEFAULT 'update'
) RETURNS uuid
SECURITY DEFINER
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_candidate assertions;
    v_event_id uuid;
    v_incumbent assertions;
    v_participant_ids uuid[];
    v_participant_roles text[];
    v_policy text;
    v_resolved_scope uuid;
    v_supersedes_as text := lower(coalesce(nullif(trim(p_supersedes_as), ''), 'update'));
    v_witness uuid;
BEGIN
    IF v_supersedes_as NOT IN ('correction', 'update') THEN
        RAISE EXCEPTION 'supersedes_as must be correction or update';
    END IF;

    PERFORM set_config('app.write_path', 'accept_assertion', true);
    PERFORM set_config('app.accept_assertion_id', p_assertion_id::text, true);

    SELECT * INTO v_candidate
    FROM assertions
    WHERE id = p_assertion_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Candidate assertion % not found', p_assertion_id;
    END IF;
    IF v_candidate.status <> 'candidate' OR v_candidate.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION 'Assertion % is not a live candidate', p_assertion_id;
    END IF;

    SELECT ae.witness_node_id INTO v_witness
    FROM assertion_evidence ae
    WHERE ae.assertion_id = p_assertion_id
      AND ae.kind IN ('source', 'corroboration')
      AND ae.witness_node_id IS NOT NULL
    ORDER BY CASE ae.kind WHEN 'source' THEN 0 ELSE 1 END, ae.recorded_at, ae.id
    LIMIT 1;

    v_resolved_scope := governing_scope(
        v_candidate.subject_node_id,
        v_candidate.subject_edge_id,
        v_candidate.assertion_type,
        v_witness
    );
    IF p_scope_node_id IS NOT NULL
       AND v_resolved_scope IS NOT NULL
       AND p_scope_node_id <> v_resolved_scope
    THEN
        RAISE EXCEPTION 'Explicit scope % does not match governing scope %', p_scope_node_id, v_resolved_scope;
    END IF;
    v_resolved_scope := coalesce(v_resolved_scope, p_scope_node_id);
    v_policy := scope_review_policy(v_resolved_scope);

    IF lower(coalesce(current_setting('app.current_role', true), '')) LIKE 'agent:%'
       AND (
           v_policy IN ('candidates_only', 'strict')
           OR v_candidate.assertion_type = 'pattern_claim'
       )
       AND NOT agent_can_promote_in_scope(v_resolved_scope)
    THEN
        RAISE EXCEPTION 'Agent acceptance requires rye.authoritative.promote capability for scope %', v_resolved_scope;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        v_candidate.subject_ref || ':' || v_candidate.assertion_type || ':' || v_candidate.assertion_key, 0
    ));

    SELECT * INTO v_incumbent
    FROM current_valid_assertions
    WHERE subject_ref = v_candidate.subject_ref
      AND assertion_type = v_candidate.assertion_type
      AND assertion_key = v_candidate.assertion_key
    LIMIT 1;

    IF FOUND
       AND v_candidate.basis = 'inferred'
       AND v_incumbent.basis <> 'inferred'
    THEN
        RAISE EXCEPTION
            'Inferred candidate % cannot displace % accepted assertion %',
            p_assertion_id, v_incumbent.basis, v_incumbent.id;
    END IF;

    IF FOUND THEN
        PERFORM mark_assertion_superseded(v_incumbent.id, p_assertion_id);
        IF v_supersedes_as = 'correction' THEN
            PERFORM mark_assertion_outcome(
                v_incumbent.id,
                'corrected',
                jsonb_build_object('corrected_by', p_assertion_id)
            );
        END IF;
    END IF;

    -- Other live candidates remain candidates, but receive a labeled outcome
    -- so reputation can distinguish adjudication from ordinary supersession.
    PERFORM mark_assertion_outcome(
        loser.id,
        'displaced',
        jsonb_build_object('displaced_by', p_assertion_id)
    )
    FROM assertions loser
    WHERE loser.subject_ref = v_candidate.subject_ref
      AND loser.assertion_type = v_candidate.assertion_type
      AND loser.assertion_key = v_candidate.assertion_key
      AND loser.status = 'candidate'
      AND loser.superseded_at IS NULL
      AND loser.id <> p_assertion_id;

    PERFORM append_assertion_evidence(p_assertion_id, p_evidence);

    PERFORM set_config('app.write_path', 'accept_assertion', true);
    PERFORM set_config('app.accept_assertion_id', p_assertion_id::text, true);
    UPDATE assertions SET status = 'accepted' WHERE id = p_assertion_id;
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.accept_assertion_id', '', true);

    IF v_candidate.subject_node_id IS NOT NULL THEN
        v_participant_ids := ARRAY[v_candidate.subject_node_id];
        v_participant_roles := ARRAY['subject'];
    ELSE
        SELECT ARRAY[source_id, target_id], ARRAY['edge_source', 'edge_target']
        INTO v_participant_ids, v_participant_roles
        FROM edges WHERE id = v_candidate.subject_edge_id;
    END IF;

    v_event_id := record_event(
        p_event_type := 'assertion_accepted',
        p_summary := format('Accepted candidate assertion %s/%s', v_candidate.assertion_type, v_candidate.assertion_key),
        p_properties := jsonb_build_object(
            'assertion_id', p_assertion_id,
            'displaced_assertion_id', v_incumbent.id,
            'reason', p_reason,
            'supersedes_as', v_supersedes_as,
            'scope_node_id', v_resolved_scope
        ),
        p_participant_ids := coalesce(v_participant_ids, '{}'::uuid[]),
        p_participant_roles := coalesce(v_participant_roles, '{}'::text[]),
        p_actor := p_actor
    );

    RETURN p_assertion_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.accept_assertion_id', '', true);
    RAISE;
END;
$$ LANGUAGE plpgsql;

DROP FUNCTION reject_candidate(uuid, text, text);

CREATE FUNCTION reject_candidate(
    p_assertion_id uuid,
    p_reason text,
    p_actor text DEFAULT NULL,
    p_outcome text DEFAULT NULL
) RETURNS void
SECURITY DEFINER
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_candidate assertions;
    v_outcome text := lower(nullif(trim(coalesce(p_outcome, '')), ''));
    v_participant_ids uuid[];
    v_participant_roles text[];
BEGIN
    IF nullif(trim(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'Candidate rejection reason is required';
    END IF;
    IF v_outcome IS NOT NULL AND v_outcome NOT IN ('incorrect', 'unsupported', 'duplicate', 'stale') THEN
        RAISE EXCEPTION 'Unsupported candidate rejection outcome: %', p_outcome;
    END IF;

    SELECT * INTO v_candidate FROM assertions WHERE id = p_assertion_id;
    IF NOT FOUND OR v_candidate.status <> 'candidate' OR v_candidate.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION 'Assertion % is not a live candidate', p_assertion_id;
    END IF;

    IF v_outcome IS NOT NULL THEN
        PERFORM mark_assertion_outcome(p_assertion_id, v_outcome, jsonb_build_object('outcome_reason', p_reason));
    END IF;
    PERFORM mark_assertion_superseded(p_assertion_id, NULL);

    IF v_candidate.subject_node_id IS NOT NULL THEN
        v_participant_ids := ARRAY[v_candidate.subject_node_id];
        v_participant_roles := ARRAY['subject'];
    ELSE
        SELECT ARRAY[source_id, target_id], ARRAY['edge_source', 'edge_target']
        INTO v_participant_ids, v_participant_roles
        FROM edges WHERE id = v_candidate.subject_edge_id;
    END IF;

    PERFORM record_event(
        p_event_type := 'candidate_rejected',
        p_summary := format('Rejected candidate assertion %s/%s', v_candidate.assertion_type, v_candidate.assertion_key),
        p_properties := jsonb_build_object(
            'assertion_id', p_assertion_id,
            'reason', p_reason,
            'outcome', v_outcome
        ),
        p_participant_ids := coalesce(v_participant_ids, '{}'::uuid[]),
        p_participant_roles := coalesce(v_participant_roles, '{}'::text[]),
        p_actor := p_actor
    );
END;
$$ LANGUAGE plpgsql;

-- --------------------------------------------------------------------------
-- Predictions and calibration
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION record_prediction(
    p_subject_node_id uuid,
    p_subject_edge_id uuid,
    p_assertion_key text,
    p_question text,
    p_outcome_key text,
    p_predicted_value jsonb,
    p_probability numeric,
    p_horizon timestamptz,
    p_witness_node_id uuid,
    p_actor text DEFAULT NULL,
    p_scope_node_id uuid DEFAULT NULL,
    p_attrs jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_id uuid;
    v_event_id uuid;
    v_participant_ids uuid[];
    v_participant_roles text[];
BEGIN
    IF (p_subject_node_id IS NULL) = (p_subject_edge_id IS NULL) THEN
        RAISE EXCEPTION 'Exactly one prediction subject is required';
    END IF;
    IF nullif(trim(p_assertion_key), '') IS NULL THEN
        RAISE EXCEPTION 'prediction assertion_key is required';
    END IF;
    IF nullif(trim(p_question), '') IS NULL THEN
        RAISE EXCEPTION 'prediction question is required';
    END IF;
    IF nullif(trim(p_outcome_key), '') IS NULL
       OR strpos(p_outcome_key, ':') <= 1
       OR strpos(p_outcome_key, ':') = length(p_outcome_key)
    THEN
        RAISE EXCEPTION 'outcome_key must be assertion_type:assertion_key';
    END IF;
    IF p_predicted_value IS NULL OR jsonb_typeof(p_predicted_value) <> 'object' THEN
        RAISE EXCEPTION 'predicted_value must be a JSON object';
    END IF;
    IF p_probability IS NULL OR p_probability < 0 OR p_probability > 1 THEN
        RAISE EXCEPTION 'probability must be between 0 and 1';
    END IF;
    IF p_horizon IS NULL THEN
        RAISE EXCEPTION 'prediction horizon is required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = p_witness_node_id AND archived_at IS NULL) THEN
        RAISE EXCEPTION 'Prediction witness node % not found', p_witness_node_id;
    END IF;

    IF p_subject_node_id IS NOT NULL THEN
        v_participant_ids := ARRAY[p_subject_node_id, p_witness_node_id];
        v_participant_roles := ARRAY['subject', 'witness'];
    ELSE
        SELECT ARRAY[source_id, target_id, p_witness_node_id], ARRAY['edge_source', 'edge_target', 'witness']
        INTO v_participant_ids, v_participant_roles
        FROM edges WHERE id = p_subject_edge_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Prediction subject edge % not found', p_subject_edge_id;
        END IF;
    END IF;

    v_event_id := record_event(
        p_event_type := 'prediction_recorded',
        p_summary := left('Prediction recorded: ' || p_question, 240),
        p_properties := jsonb_build_object(
            'question', p_question,
            'outcome_key', p_outcome_key,
            'predicted_value', p_predicted_value,
            'probability', p_probability,
            'horizon', p_horizon,
            'witness_node_id', p_witness_node_id
        ),
        p_participant_ids := v_participant_ids,
        p_participant_roles := v_participant_roles,
        p_actor := p_actor
    );

    v_assertion_id := record_assertion(
        p_assertion_type := 'prediction',
        p_assertion_key := p_assertion_key,
        p_subject_node_id := p_subject_node_id,
        p_subject_edge_id := p_subject_edge_id,
        p_claim := jsonb_build_object(
            'question', p_question,
            'outcome_key', p_outcome_key,
            'predicted_value', p_predicted_value,
            'probability', p_probability,
            'horizon', p_horizon
        ),
        p_status := 'accepted',
        p_basis := 'inferred',
        p_evidence := ARRAY[jsonb_build_object(
            'kind', 'source',
            'event_id', v_event_id,
            'witness_node_id', p_witness_node_id
        )],
        p_attrs := coalesce(p_attrs, '{}'::jsonb) || jsonb_build_object('prediction_event_id', v_event_id),
        p_scope_node_id := p_scope_node_id
    );
    RETURN v_assertion_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION score_due_predictions()
RETURNS int
SECURITY DEFINER
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_actual assertions;
    v_count int := 0;
    v_event_id uuid;
    v_outcome text;
    v_prediction assertions;
    v_prediction_type text;
    v_prediction_key text;
    v_probability numeric;
BEGIN
    FOR v_prediction IN
        SELECT a.*
        FROM assertions a
        WHERE a.assertion_type = 'prediction'
          AND a.status = 'accepted'
          AND a.superseded_at IS NULL
          AND (a.effective_at IS NULL OR a.effective_at <= now())
          AND (a.effective_to IS NULL OR a.effective_to > now())
          AND NOT (a.attrs ? 'outcome')
          AND (a.claim->>'horizon')::timestamptz <= now()
        ORDER BY (a.claim->>'horizon')::timestamptz, a.id
        FOR UPDATE OF a
    LOOP
        v_prediction_type := split_part(v_prediction.claim->>'outcome_key', ':', 1);
        v_prediction_key := substr(
            v_prediction.claim->>'outcome_key',
            strpos(v_prediction.claim->>'outcome_key', ':') + 1
        );
        v_probability := (v_prediction.claim->>'probability')::numeric;

        SELECT outcome.* INTO v_actual
        FROM assertions_as_of((v_prediction.claim->>'horizon')::timestamptz, now()) outcome
        WHERE outcome.subject_ref = v_prediction.subject_ref
          AND outcome.assertion_type = canonical_type('assertion_type', v_prediction_type)
          AND outcome.assertion_key = v_prediction_key
        ORDER BY outcome.asserted_at DESC, outcome.effective_at DESC NULLS LAST, outcome.id
        LIMIT 1;

        IF NOT FOUND THEN
            v_outcome := 'unresolvable';
        ELSIF v_actual.claim @> (v_prediction.claim->'predicted_value') THEN
            v_outcome := 'correct';
        ELSE
            v_outcome := 'incorrect';
        END IF;

        v_event_id := record_event(
            p_event_type := 'prediction_scored',
            p_summary := format('Prediction %s scored %s', v_prediction.id, v_outcome),
            p_properties := jsonb_build_object(
                'prediction_assertion_id', v_prediction.id,
                'outcome', v_outcome,
                'outcome_assertion_id', v_actual.id,
                'probability', v_probability,
                'brier_score', CASE
                    WHEN v_outcome = 'unresolvable' THEN NULL
                    ELSE power(v_probability - CASE WHEN v_outcome = 'correct' THEN 1 ELSE 0 END, 2)
                END,
                'horizon', v_prediction.claim->>'horizon'
            ),
            p_participant_ids := CASE
                WHEN v_prediction.subject_node_id IS NOT NULL THEN ARRAY[v_prediction.subject_node_id]
                ELSE '{}'::uuid[]
            END,
            p_participant_roles := CASE
                WHEN v_prediction.subject_node_id IS NOT NULL THEN ARRAY['subject']
                ELSE '{}'::text[]
            END,
            p_actor := 'system:prediction-scorer'
        );

        PERFORM mark_assertion_outcome(
            v_prediction.id,
            v_outcome,
            jsonb_build_object(
                'prediction_scored_event_id', v_event_id,
                'outcome_assertion_id', v_actual.id,
                'brier_score', CASE
                    WHEN v_outcome = 'unresolvable' THEN NULL
                    ELSE power(v_probability - CASE WHEN v_outcome = 'correct' THEN 1 ELSE 0 END, 2)
                END
            )
        );
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW calibration_report
WITH (security_invoker = true) AS
SELECT
    ae.witness_node_id,
    floor((a.claim->>'probability')::numeric * 10) / 10 AS probability_bucket,
    count(DISTINCT a.id) AS prediction_count,
    avg((a.attrs->>'brier_score')::numeric) AS brier_score,
    avg(CASE WHEN a.attrs->>'outcome' = 'correct' THEN 1::numeric ELSE 0::numeric END) AS hit_rate
FROM assertions a
JOIN assertion_evidence ae
  ON ae.assertion_id = a.id
 AND ae.kind = 'source'
 AND ae.witness_node_id IS NOT NULL
WHERE a.assertion_type = 'prediction'
  AND a.attrs->>'outcome' IN ('correct', 'incorrect')
GROUP BY ae.witness_node_id, floor((a.claim->>'probability')::numeric * 10) / 10;

-- --------------------------------------------------------------------------
-- Source reliability and confidence
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW source_reliability
WITH (security_invoker = true) AS
WITH witnessed AS (
    SELECT DISTINCT ae.witness_node_id, a.id AS assertion_id
    FROM assertion_evidence ae
    JOIN assertions a ON a.id = ae.assertion_id
    WHERE ae.kind IN ('source', 'corroboration')
      AND ae.witness_node_id IS NOT NULL
), claim_outcomes AS (
    SELECT
        witnessed.witness_node_id,
        a.id AS assertion_id,
        a.assertion_type,
        a.attrs->>'outcome' AS outcome,
        nullif(a.attrs->>'outcome_at', '')::timestamptz AS outcome_at,
        CASE
            WHEN a.assertion_type = 'prediction'
             AND a.attrs->>'outcome' IN ('correct', 'incorrect')
            THEN (a.attrs->>'brier_score')::numeric
        END AS prediction_brier
    FROM witnessed
    JOIN assertions a ON a.id = witnessed.assertion_id
), aggregate AS (
    SELECT
        witness_node_id,
        count(*) AS claims_witnessed,
        count(*) FILTER (WHERE outcome = 'corrected') AS corrections,
        count(*) FILTER (
            WHERE assertion_type <> 'prediction'
              AND outcome IN ('incorrect', 'unsupported')
        ) AS rejected_incorrect,
        count(*) FILTER (WHERE outcome = 'displaced') AS displaced,
        count(*) FILTER (
            WHERE assertion_type = 'prediction'
              AND outcome IN ('correct', 'incorrect')
        ) AS predictions_scored,
        count(*) FILTER (
            WHERE assertion_type = 'prediction'
              AND outcome = 'incorrect'
        ) AS predictions_incorrect,
        avg(prediction_brier) AS prediction_brier,
        max(outcome_at) AS last_outcome_at
    FROM claim_outcomes
    GROUP BY witness_node_id
)
SELECT
    witness_node_id,
    claims_witnessed,
    corrections,
    rejected_incorrect,
    displaced,
    (corrections + rejected_incorrect + predictions_incorrect)::numeric
        / NULLIF(claims_witnessed, 0) AS correction_rate,
    last_outcome_at,
    claims_witnessed < 5 AS low_sample,
    predictions_scored,
    prediction_brier
FROM aggregate;

CREATE OR REPLACE FUNCTION base_effective_confidence(a assertions)
RETURNS numeric
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_age_seconds numeric;
    v_base numeric;
    v_competitors int;
    v_correction_rate numeric;
    v_discount numeric;
    v_half_life interval;
    v_half_life_json jsonb;
    v_independent int;
    v_lift numeric;
    v_low_sample boolean;
    v_newest_support timestamptz;
    v_result numeric;
    v_witness uuid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM current_valid_assertions c WHERE c.id = a.id) THEN
        RETURN NULL;
    END IF;

    v_base := coalesce(
        a.confidence,
        (registry_value('basis_prior:' || a.basis, NULL) #>> '{}')::numeric,
        0.50
    );

    SELECT witness_node_id INTO v_witness
    FROM assertion_evidence
    WHERE assertion_id = a.id
      AND kind = 'source'
      AND witness_node_id IS NOT NULL
    ORDER BY recorded_at, id
    LIMIT 1;

    IF v_witness IS NOT NULL THEN
        SELECT correction_rate, low_sample
        INTO v_correction_rate, v_low_sample
        FROM source_reliability
        WHERE witness_node_id = v_witness;
        IF coalesce(v_low_sample, true) = false THEN
            v_base := v_base * (1 - least(coalesce(v_correction_rate, 0), 0.5));
        END IF;
    END IF;

    SELECT count(DISTINCT witness_node_id) INTO v_independent
    FROM assertion_evidence
    WHERE assertion_id = a.id
      AND kind IN ('source', 'corroboration')
      AND witness_node_id IS NOT NULL;
    v_lift := 1 + 0.1 * least(v_independent, 3);

    SELECT max(recorded_at) INTO v_newest_support
    FROM assertion_evidence
    WHERE assertion_id = a.id
      AND kind = 'corroboration'
      AND coalesce((attrs->>'independent')::boolean, false);

    v_half_life_json := registry_value(
        'half_life:' || canonical_type('assertion_type', a.assertion_type), NULL
    );
    IF v_half_life_json IS NOT NULL AND jsonb_typeof(v_half_life_json) <> 'null' THEN
        v_half_life := (v_half_life_json #>> '{}')::interval;
    END IF;

    SELECT count(*) INTO v_competitors
    FROM assertions candidate
    WHERE candidate.subject_ref = a.subject_ref
      AND canonical_type('assertion_type', candidate.assertion_type)
          = canonical_type('assertion_type', a.assertion_type)
      AND candidate.assertion_key = a.assertion_key
      AND candidate.status = 'candidate'
      AND candidate.superseded_at IS NULL;
    v_discount := greatest(0.5, power(0.8::numeric, v_competitors));

    IF v_half_life IS NULL THEN
        v_result := v_base * v_lift * v_discount;
    ELSE
        v_age_seconds := greatest(
            extract(epoch FROM (now() - greatest(a.asserted_at, coalesce(v_newest_support, a.asserted_at)))),
            0
        );
        v_result := v_base
            * v_lift
            * power(2::numeric, -(v_age_seconds / extract(epoch FROM v_half_life)))
            * v_discount;
    END IF;

    RETURN least(1::numeric, greatest(0::numeric, v_result));
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION effective_confidence(a assertions)
RETURNS numeric
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_pattern_cap numeric;
    v_result numeric;
BEGIN
    v_result := base_effective_confidence(a);
    IF v_result IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT min(base_effective_confidence(ROW(pattern.*)::assertions))
    INTO v_pattern_cap
    FROM assertion_evidence ae
    JOIN current_valid_assertions pattern ON pattern.id = ae.source_assertion_id
    JOIN nodes pattern_node ON pattern_node.id = pattern.subject_node_id
    WHERE ae.assertion_id = a.id
      AND ae.kind = 'derivation'
      AND pattern.assertion_type = 'pattern_claim'
      AND pattern_node.node_type = 'pattern';

    IF v_pattern_cap IS NOT NULL THEN
        v_result := least(v_result, v_pattern_cap);
    END IF;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE VIEW current_assertions_weighted
WITH (security_invoker = true) AS
SELECT a.*, effective_confidence(ROW(a.*)::assertions) AS effective_confidence
FROM current_valid_assertions a;

-- --------------------------------------------------------------------------
-- Induction
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION record_pattern(
    p_label text,
    p_claim jsonb,
    p_source_assertion_ids uuid[],
    p_assertion_key text DEFAULT 'default',
    p_contradicting_assertion_ids uuid[] DEFAULT '{}'::uuid[],
    p_source_event_ids uuid[] DEFAULT '{}'::uuid[],
    p_witness_node_id uuid DEFAULT NULL,
    p_confidence numeric DEFAULT NULL,
    p_actor text DEFAULT NULL,
    p_scope_node_id uuid DEFAULT NULL,
    p_attrs jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_id uuid;
    v_distinct_subjects int;
    v_evidence jsonb[] := '{}'::jsonb[];
    v_event_id uuid;
    v_id uuid;
    v_pattern_node_id uuid;
BEGIN
    IF nullif(trim(p_label), '') IS NULL THEN
        RAISE EXCEPTION 'pattern label is required';
    END IF;
    IF p_claim IS NULL THEN
        RAISE EXCEPTION 'pattern claim is required';
    END IF;

    SELECT count(DISTINCT subject_ref) INTO v_distinct_subjects
    FROM current_valid_assertions
    WHERE id = ANY(coalesce(p_source_assertion_ids, '{}'::uuid[]));
    IF v_distinct_subjects < 3 THEN
        RAISE EXCEPTION 'record_pattern requires derivation evidence from at least 3 distinct subjects';
    END IF;
    IF (SELECT count(*) FROM current_valid_assertions WHERE id = ANY(p_source_assertion_ids))
       <> cardinality(p_source_assertion_ids)
    THEN
        RAISE EXCEPTION 'Every pattern source assertion must be accepted, current, and visible';
    END IF;
    IF EXISTS (
        SELECT 1 FROM unnest(coalesce(p_contradicting_assertion_ids, '{}'::uuid[])) id
        WHERE NOT EXISTS (SELECT 1 FROM current_valid_assertions a WHERE a.id = id)
    ) THEN
        RAISE EXCEPTION 'Every contradicting pattern assertion must be accepted, current, and visible';
    END IF;
    IF EXISTS (
        SELECT 1 FROM unnest(coalesce(p_source_event_ids, '{}'::uuid[])) id
        WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.id = id)
    ) THEN
        RAISE EXCEPTION 'Every pattern source event must exist and be visible';
    END IF;

    INSERT INTO nodes (node_type, label, properties, attrs)
    VALUES (
        canonical_type('node_type', 'pattern'),
        p_label,
        jsonb_build_object('pattern_key', coalesce(nullif(trim(p_assertion_key), ''), 'default')),
        coalesce(p_attrs, '{}'::jsonb) || jsonb_build_object('created_by', p_actor)
    )
    RETURNING id INTO v_pattern_node_id;

    v_event_id := record_event(
        p_event_type := 'pattern_recorded',
        p_summary := left('Pattern proposed: ' || p_label, 240),
        p_properties := jsonb_build_object(
            'pattern_node_id', v_pattern_node_id,
            'source_assertion_ids', to_jsonb(p_source_assertion_ids),
            'contradicting_assertion_ids', to_jsonb(coalesce(p_contradicting_assertion_ids, '{}'::uuid[]))
        ),
        p_participant_ids := CASE
            WHEN p_witness_node_id IS NULL THEN ARRAY[v_pattern_node_id]
            ELSE ARRAY[v_pattern_node_id, p_witness_node_id]
        END,
        p_participant_roles := CASE
            WHEN p_witness_node_id IS NULL THEN ARRAY['pattern']
            ELSE ARRAY['pattern', 'witness']
        END,
        p_actor := p_actor
    );

    v_evidence := array_append(v_evidence, jsonb_build_object(
        'kind', 'source',
        'event_id', v_event_id,
        'witness_node_id', p_witness_node_id,
        'attrs', jsonb_build_object('role', 'pattern_record')
    ));
    FOREACH v_id IN ARRAY p_source_assertion_ids LOOP
        v_evidence := array_append(v_evidence, jsonb_build_object(
            'kind', 'derivation',
            'source_assertion_id', v_id,
            'attrs', jsonb_build_object('contradicts', false)
        ));
    END LOOP;
    FOREACH v_id IN ARRAY coalesce(p_contradicting_assertion_ids, '{}'::uuid[]) LOOP
        v_evidence := array_append(v_evidence, jsonb_build_object(
            'kind', 'derivation',
            'source_assertion_id', v_id,
            'attrs', jsonb_build_object('contradicts', true)
        ));
    END LOOP;
    FOREACH v_id IN ARRAY coalesce(p_source_event_ids, '{}'::uuid[]) LOOP
        v_evidence := array_append(v_evidence, jsonb_build_object(
            'kind', 'source', 'event_id', v_id
        ));
    END LOOP;

    v_assertion_id := record_assertion(
        p_assertion_type := 'pattern_claim',
        p_assertion_key := p_assertion_key,
        p_subject_node_id := v_pattern_node_id,
        p_claim := p_claim,
        p_status := 'candidate',
        p_basis := 'inferred',
        p_evidence := v_evidence,
        p_confidence := p_confidence,
        p_attrs := jsonb_build_object(
            'pattern_event_id', v_event_id,
            'created_by', p_actor
        ),
        p_scope_node_id := p_scope_node_id
    );
    RETURN v_assertion_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW pattern_support
WITH (security_invoker = true) AS
SELECT
    pattern.id AS pattern_assertion_id,
    pattern.subject_node_id AS pattern_node_id,
    count(*) FILTER (
        WHERE ae.kind = 'derivation'
          AND NOT coalesce((ae.attrs->>'contradicts')::boolean, false)
    ) AS support_count,
    count(*) FILTER (
        WHERE ae.kind = 'derivation'
          AND coalesce((ae.attrs->>'contradicts')::boolean, false)
    ) AS contradiction_count,
    count(DISTINCT source.subject_ref) FILTER (
        WHERE ae.kind = 'derivation'
          AND NOT coalesce((ae.attrs->>'contradicts')::boolean, false)
    ) AS distinct_supporting_subjects
FROM assertions pattern
JOIN nodes pattern_node
  ON pattern_node.id = pattern.subject_node_id
 AND pattern_node.node_type = 'pattern'
LEFT JOIN assertion_evidence ae ON ae.assertion_id = pattern.id
LEFT JOIN assertions source ON source.id = ae.source_assertion_id
WHERE pattern.assertion_type = 'pattern_claim'
GROUP BY pattern.id, pattern.subject_node_id;

COMMENT ON VIEW pattern_support IS
    'One-row pattern evidence summary. Confidence propagation through accepted patterns is capped for one derivation hop only.';
