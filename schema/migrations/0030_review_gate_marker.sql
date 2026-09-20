-- A demoted write says so.
--
-- Work item: work/011-loose-ends.md (asked for independently by two verifiers
--            and the agent-kit builder).
-- Contract:  contracts/sql-surface.md, "Review policy holds on every route".
-- Decision:  docs/decisions/0010-review-policy-holds-on-every-route.md.
--
-- 0027 gave supersede_assertion() a marker and a NOTICE when the review policy
-- turns a replacement into a candidate, and resolve_knowledge_gap() followed
-- it. record_assertion() and record_distillation() demote in exactly the same
-- circumstances and say nothing: the id comes back, the row is a candidate,
-- and a caller that does not re-read the row believes it recorded a fact. A
-- new claim is the commonest write there is, so the commonest demotion was the
-- silent one.
--
-- This migration carries record_assertion() and record_distillation() forward
-- from 0027 verbatim and changes one branch in each: the review-policy
-- demotion now writes attrs.review_gate in the shape supersede_assertion()
-- writes, and raises the same NOTICE. Signatures, search_path, and every other
-- line are unchanged.
--
-- THE SHAPE. The five keys are supersede_assertion()'s, so a client has one
-- thing to look for on every route: pending, requested_status, review_policy,
-- scope_node_id, incumbent_assertion_id. The last is null here, because
-- neither helper ends an incumbent when it demotes -- supersede_assertion()
-- names the row it did not supersede, and these two have none to name.
-- scope_node_id is the scope the helper resolved and reports elsewhere, which
-- is the witness-resolved one; the policy in review_policy is the stricter of
-- the two resolutions, exactly as 0027 computes it.
--
-- THE SETTLE GATE IS UNTOUCHED. record_assertion() demotes for the settle gate
-- first and writes attrs.settle_gate there. The review branch runs after it
-- and tests the post-settle status, so a write that both gates would demote
-- carries attrs.settle_gate and nothing else, and raises no NOTICE -- which is
-- the behaviour 0023 wrote and tests/conformance/30_configuration_gate.sql
-- pins, unchanged, to the key. A configuration write waiting for an admin is
-- waiting for an admin, not for a settler.
--
-- READERS. attrs is passed through whole by review_queue, competing_candidates,
-- node_context, and agent_node_summary, so a new key is additive for all of
-- them. Nothing in the schema or in admin/ filters on the absence of a key.

SET search_path = rye, pg_catalog, public;

CREATE OR REPLACE FUNCTION record_assertion(
    p_assertion_type text,
    p_claim jsonb,
    p_subject_node_id uuid DEFAULT NULL,
    p_subject_edge_id uuid DEFAULT NULL,
    p_assertion_key text DEFAULT 'default',
    p_effective_at timestamptz DEFAULT NULL,
    p_effective_to timestamptz DEFAULT NULL,
    p_confidence numeric DEFAULT NULL,
    p_status text DEFAULT 'accepted',
    p_basis text DEFAULT 'unknown',
    p_evidence jsonb[] DEFAULT NULL,
    p_classification text DEFAULT NULL,
    p_attrs jsonb DEFAULT '{}'::jsonb,
    p_scope_node_id uuid DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_type text;
    v_attrs jsonb := coalesce(p_attrs, '{}'::jsonb);
    v_existing assertions;
    v_governing_scope uuid;
    v_settle_roles text[];
    v_key text := coalesce(nullif(trim(p_assertion_key), ''), 'default');
    v_new_effective_to timestamptz := p_effective_to;
    v_new_id uuid := gen_random_uuid();
    v_next_future_at timestamptz;
    v_policy text;
    v_resolved_scope uuid;
    v_status text := lower(coalesce(nullif(trim(p_status), ''), 'accepted'));
    v_basis text := lower(coalesce(nullif(trim(p_basis), ''), 'unknown'));
    v_subject_ref text;
    v_witness uuid;
BEGIN
    IF (p_subject_node_id IS NULL) = (p_subject_edge_id IS NULL) THEN
        RAISE EXCEPTION 'Exactly one of subject_node_id or subject_edge_id is required';
    END IF;
    IF nullif(trim(p_assertion_type), '') IS NULL THEN
        RAISE EXCEPTION 'assertion_type is required';
    END IF;
    v_assertion_type := canonical_type_in_scope('assertion_type', p_assertion_type, p_scope_node_id);
    IF p_claim IS NULL THEN
        RAISE EXCEPTION 'claim is required';
    END IF;
    IF v_status NOT IN ('candidate', 'accepted') THEN
        RAISE EXCEPTION 'Unsupported assertion status: %', p_status;
    END IF;
    IF v_basis NOT IN ('observed', 'reported', 'inferred', 'assumed', 'unknown') THEN
        RAISE EXCEPTION 'Unsupported assertion basis: %', p_basis;
    END IF;
    IF v_assertion_type = 'pattern_claim' AND v_status = 'accepted' THEN
        RAISE EXCEPTION 'pattern_claim assertions must be recorded as candidates and promoted with accept_assertion()';
    END IF;
    IF v_basis <> 'assumed'
       AND cardinality(coalesce(p_evidence, '{}'::jsonb[])) = 0
    THEN
        RAISE EXCEPTION 'Non-assumed assertions require evidence';
    END IF;
    IF p_effective_at IS NOT NULL
       AND p_effective_to IS NOT NULL
       AND p_effective_to <= p_effective_at
    THEN
        RAISE EXCEPTION 'effective_to must be after effective_at';
    END IF;

    SELECT nullif(evidence->>'witness_node_id', '')::uuid
    INTO v_witness
    FROM unnest(coalesce(p_evidence, '{}'::jsonb[])) WITH ORDINALITY item(evidence, ordinality)
    WHERE evidence->>'kind' IN ('source', 'corroboration')
      AND nullif(evidence->>'witness_node_id', '') IS NOT NULL
    ORDER BY ordinality
    LIMIT 1;

    v_governing_scope := governing_scope(
        p_subject_node_id,
        p_subject_edge_id,
        v_assertion_type,
        v_witness
    );
    v_resolved_scope := v_governing_scope;
    IF p_scope_node_id IS NOT NULL
       AND v_resolved_scope IS NOT NULL
       AND p_scope_node_id <> v_resolved_scope
    THEN
        RAISE EXCEPTION 'Explicit scope % does not match governing scope %', p_scope_node_id, v_resolved_scope;
    END IF;
    v_resolved_scope := coalesce(v_resolved_scope, p_scope_node_id);
    v_assertion_type := canonical_type_in_scope(
        'assertion_type', v_assertion_type, v_resolved_scope
    );
    IF v_assertion_type = 'pattern_claim' AND v_status = 'accepted' THEN
        RAISE EXCEPTION 'pattern_claim assertions must be recorded as candidates and promoted with accept_assertion()';
    END IF;
    -- 0027: the policy is the stricter of the two resolutions, because the
    -- insert guard resolves without a witness and its answer can fall through
    -- to a stricter DEFAULT_SCOPE. The scope id above is unchanged. When
    -- nothing governs the subject, an explicit p_scope_node_id still supplies
    -- the policy exactly as before.
    IF v_governing_scope IS NULL THEN
        v_policy := scope_review_policy(v_resolved_scope);
    ELSE
        v_policy := effective_review_policy(
            p_subject_node_id, p_subject_edge_id, v_assertion_type, v_witness
        );
    END IF;

    -- Configuration writes need an admin. A gated type is Rye's own
    -- configuration, and only the roles named in the assertion_type_access
    -- `settle` row may make it accepted. Demote rather than refuse, so
    -- nothing the person said is lost: the write lands as a candidate an
    -- admin can accept from review_queue, marked so the caller can see why.
    --
    -- This runs before the review policy demotion and before the block that
    -- supersedes the incumbent. Demoting after supersession would leave the
    -- key with no accepted value at all, which is how a non-admin would erase
    -- an alias by proposing one. It is independent of the review policy: it
    -- applies under open, candidates_only, strict, and with no policy at all,
    -- so the requested status, not the post-policy status, is what is tested.
    v_settle_roles := assertion_settle_roles(v_assertion_type);
    IF v_status = 'accepted'
       AND v_settle_roles IS NOT NULL
       AND NOT (
           coalesce(nullif(current_setting('app.current_role', true), ''), '')
           = ANY(v_settle_roles)
       )
    THEN
        v_status := 'candidate';
        v_attrs := v_attrs || jsonb_build_object(
            'settle_gate', jsonb_build_object(
                'pending', true,
                'requested_status', 'accepted',
                'assertion_type', v_assertion_type,
                'allowed_roles', to_jsonb(v_settle_roles)
            )
        );
    END IF;

    -- 0030: the review-policy demotion says so, in supersede_assertion()'s
    -- shape. It runs after the settle-gate demotion and tests the status that
    -- demotion left, so a configuration write that both would demote keeps
    -- attrs.settle_gate alone.
    IF v_status = 'accepted'
       AND (v_policy = 'strict' OR (v_policy = 'candidates_only' AND v_basis <> 'observed'))
    THEN
        v_status := 'candidate';
        v_attrs := v_attrs || jsonb_build_object(
            'review_gate', jsonb_build_object(
                'pending', true,
                'requested_status', 'accepted',
                'review_policy', v_policy,
                'scope_node_id', v_resolved_scope,
                'incumbent_assertion_id', NULL
            )
        );
        RAISE NOTICE
            'Review policy % on scope %: assertion % is waiting in review_queue. It was recorded as a candidate and is not the current value. A settler accepts it with accept_assertion().',
            v_policy, coalesce(v_resolved_scope::text, 'none'), v_new_id;
    END IF;

    v_subject_ref := coalesce('n:' || p_subject_node_id::text, 'e:' || p_subject_edge_id::text);

    IF v_status = 'accepted' THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(
            v_subject_ref || ':' || v_assertion_type || ':' || v_key, 0
        ));

        IF p_effective_at IS NOT NULL AND p_effective_at > now() THEN
            SELECT * INTO v_existing
            FROM assertions
            WHERE subject_ref = v_subject_ref
              AND assertion_type = v_assertion_type
              AND assertion_key = v_key
              AND status = 'accepted'
              AND superseded_at IS NULL
              AND effective_at IS NOT DISTINCT FROM p_effective_at
            LIMIT 1;

            IF FOUND
               AND v_existing.claim = p_claim
               AND v_existing.basis = v_basis
               AND v_existing.confidence IS NOT DISTINCT FROM p_confidence
            THEN
                PERFORM append_assertion_evidence(v_existing.id, p_evidence);
                RETURN v_existing.id;
            ELSIF FOUND THEN
                PERFORM mark_assertion_superseded(v_existing.id, v_new_id);
            END IF;

            SELECT min(effective_at) INTO v_next_future_at
            FROM assertions
            WHERE subject_ref = v_subject_ref
              AND assertion_type = v_assertion_type
              AND assertion_key = v_key
              AND status = 'accepted'
              AND superseded_at IS NULL
              AND effective_at > p_effective_at;

            IF v_next_future_at IS NOT NULL
               AND (v_new_effective_to IS NULL OR v_new_effective_to > v_next_future_at)
            THEN
                v_new_effective_to := v_next_future_at;
            END IF;

            SELECT * INTO v_existing
            FROM assertions
            WHERE subject_ref = v_subject_ref
              AND assertion_type = v_assertion_type
              AND assertion_key = v_key
              AND status = 'accepted'
              AND superseded_at IS NULL
              AND (effective_at IS NULL OR effective_at < p_effective_at)
              AND (effective_to IS NULL OR effective_to > p_effective_at)
            ORDER BY effective_at DESC NULLS LAST, asserted_at DESC
            LIMIT 1;

            IF FOUND AND (v_existing.effective_to IS NULL OR v_existing.effective_to > p_effective_at) THEN
                PERFORM set_config('app.write_path', 'assertion_effective_window', true);
                PERFORM set_config('app.effective_window_assertion_id', v_existing.id::text, true);
                UPDATE assertions SET effective_to = p_effective_at WHERE id = v_existing.id;
                PERFORM set_config('app.write_path', '', true);
                PERFORM set_config('app.effective_window_assertion_id', '', true);
            END IF;
        ELSIF p_effective_to IS NULL OR p_effective_to > now() THEN
            SELECT * INTO v_existing
            FROM assertions
            WHERE subject_ref = v_subject_ref
              AND assertion_type = v_assertion_type
              AND assertion_key = v_key
              AND status = 'accepted'
              AND superseded_at IS NULL
              AND (effective_at IS NULL OR effective_at <= now())
              AND (effective_to IS NULL OR effective_to > now())
            ORDER BY effective_at DESC NULLS LAST, asserted_at DESC
            LIMIT 1;

            IF FOUND
               AND v_existing.claim = p_claim
               AND v_existing.basis = v_basis
               AND v_existing.confidence IS NOT DISTINCT FROM p_confidence
            THEN
                PERFORM append_assertion_evidence(v_existing.id, p_evidence);
                RETURN v_existing.id;
            END IF;
            IF FOUND THEN
                PERFORM mark_assertion_superseded(v_existing.id, v_new_id);
            END IF;
        END IF;
    END IF;

    INSERT INTO assertions (
        id, assertion_type, assertion_key, status, basis, classification,
        subject_node_id, subject_edge_id, claim, effective_at, effective_to,
        confidence, attrs
    ) VALUES (
        v_new_id, v_assertion_type, v_key, v_status, v_basis, p_classification,
        p_subject_node_id, p_subject_edge_id, p_claim, p_effective_at,
        v_new_effective_to, p_confidence, v_attrs
    );

    PERFORM append_assertion_evidence(v_new_id, p_evidence);
    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_distillation(
    p_subject_node_id uuid,
    p_subject_edge_id uuid,
    p_assertion_key text,
    p_claim jsonb,
    p_source_assertion_ids uuid[],
    p_source_event_ids uuid[],
    p_status text DEFAULT 'accepted',
    p_agent text DEFAULT NULL,
    p_scope_node_id uuid DEFAULT NULL,
    p_confidence numeric DEFAULT NULL,
    p_attrs jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_catalog jsonb;
    v_event_id uuid;
    v_evidence jsonb[] := '{}'::jsonb[];
    v_id uuid;
    v_incumbent assertions;
    v_key text := coalesce(nullif(trim(p_assertion_key), ''), 'default');
    v_new_id uuid := gen_random_uuid();
    v_node_type text;
    v_governing_scope uuid;
    v_participant_ids uuid[];
    v_participant_roles text[];
    v_policy text;
    v_resolved_scope uuid;
    v_review_gate jsonb := '{}'::jsonb;
    v_status text := lower(coalesce(nullif(trim(p_status), ''), 'accepted'));
    v_subject_ref text;
    v_watermark timestamptz;
    v_witness uuid;
BEGIN
    IF (p_subject_node_id IS NULL) = (p_subject_edge_id IS NULL) THEN
        RAISE EXCEPTION 'Exactly one distillation subject is required';
    END IF;
    IF cardinality(coalesce(p_source_assertion_ids, '{}'::uuid[])) = 0 THEN
        RAISE EXCEPTION 'record_distillation requires at least one source assertion';
    END IF;
    IF v_status NOT IN ('candidate', 'accepted') THEN
        RAISE EXCEPTION 'Unsupported distillation status: %', p_status;
    END IF;

    SELECT max(asserted_at) INTO v_watermark
    FROM assertions WHERE id = ANY(p_source_assertion_ids);
    IF v_watermark IS NULL
       OR (SELECT count(*) FROM assertions WHERE id = ANY(p_source_assertion_ids))
          <> cardinality(p_source_assertion_ids)
    THEN
        RAISE EXCEPTION 'Every distillation source assertion must exist and be visible';
    END IF;

    SELECT ae.witness_node_id INTO v_witness
    FROM assertion_evidence ae
    WHERE ae.assertion_id = ANY(p_source_assertion_ids)
      AND ae.kind IN ('source', 'corroboration')
      AND ae.witness_node_id IS NOT NULL
    ORDER BY array_position(p_source_assertion_ids, ae.assertion_id), ae.recorded_at, ae.id
    LIMIT 1;

    v_governing_scope := governing_scope(p_subject_node_id, p_subject_edge_id, 'digest', v_witness);
    v_resolved_scope := v_governing_scope;
    IF p_scope_node_id IS NOT NULL
       AND v_resolved_scope IS NOT NULL
       AND p_scope_node_id <> v_resolved_scope
    THEN
        RAISE EXCEPTION 'Explicit scope % does not match governing scope %', p_scope_node_id, v_resolved_scope;
    END IF;
    v_resolved_scope := coalesce(v_resolved_scope, p_scope_node_id);
    -- 0027: the stricter of the two resolutions, for the same reason
    -- record_assertion() takes it. The scope id above is unchanged, so the
    -- digest facet catalogue and the event still name the witness-resolved
    -- scope.
    IF v_governing_scope IS NULL THEN
        v_policy := scope_review_policy(v_resolved_scope);
    ELSE
        v_policy := effective_review_policy(
            p_subject_node_id, p_subject_edge_id, 'digest', v_witness
        );
    END IF;
    -- 0030: the same marker and the same NOTICE as record_assertion() and
    -- supersede_assertion(). A digest nobody is told is waiting is a digest
    -- a caller reads as the current summary.
    IF v_status = 'accepted' AND v_policy IN ('candidates_only', 'strict') THEN
        v_status := 'candidate';
        v_review_gate := jsonb_build_object(
            'review_gate', jsonb_build_object(
                'pending', true,
                'requested_status', 'accepted',
                'review_policy', v_policy,
                'scope_node_id', v_resolved_scope,
                'incumbent_assertion_id', NULL
            )
        );
        RAISE NOTICE
            'Review policy % on scope %: assertion % is waiting in review_queue. It was recorded as a candidate and is not the current value. A settler accepts it with accept_assertion().',
            v_policy, coalesce(v_resolved_scope::text, 'none'), v_new_id;
    END IF;

    IF p_subject_node_id IS NOT NULL THEN
        SELECT node_type INTO v_node_type FROM nodes WHERE id = p_subject_node_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Distillation subject node % not found', p_subject_node_id;
        END IF;
        v_catalog := registry_value('digest_facets:' || v_node_type, v_resolved_scope);
        IF v_catalog IS NOT NULL
           AND NOT ((jsonb_typeof(v_catalog) = 'array' AND v_catalog ? v_key)
                    OR (jsonb_typeof(v_catalog) = 'object' AND v_catalog ? v_key))
        THEN
            RAISE EXCEPTION 'Digest facet % is not registered for node type %', v_key, v_node_type;
        END IF;
        v_participant_ids := ARRAY[p_subject_node_id];
        v_participant_roles := ARRAY['subject'];
    ELSE
        SELECT ARRAY[source_id, target_id], ARRAY['edge_source', 'edge_target']
        INTO v_participant_ids, v_participant_roles
        FROM edges WHERE id = p_subject_edge_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Distillation subject edge % not found', p_subject_edge_id;
        END IF;
    END IF;

    PERFORM derived_assertion_classification(p_source_assertion_ids);
    v_subject_ref := coalesce('n:' || p_subject_node_id::text, 'e:' || p_subject_edge_id::text);
    PERFORM pg_advisory_xact_lock(hashtextextended(v_subject_ref || ':digest:' || v_key, 0));

    v_event_id := record_event(
        p_event_type := 'distillation',
        p_summary := format('Distilled %s source assertions into digest %s', cardinality(p_source_assertion_ids), v_key),
        p_properties := jsonb_build_object(
            'digest_assertion_id', v_new_id,
            'subject_edge_id', p_subject_edge_id,
            'source_assertion_ids', to_jsonb(p_source_assertion_ids),
            'source_event_ids', to_jsonb(coalesce(p_source_event_ids, '{}'::uuid[])),
            'watermark', v_watermark,
            'scope_node_id', v_resolved_scope
        ),
        p_participant_ids := v_participant_ids,
        p_participant_roles := v_participant_roles,
        p_actor := p_agent
    );

    v_evidence := array_append(v_evidence, jsonb_build_object(
        'kind', 'source', 'event_id', v_event_id,
        'attrs', jsonb_build_object('role', 'distillation_record')
    ));
    FOREACH v_id IN ARRAY p_source_assertion_ids LOOP
        v_evidence := array_append(v_evidence, jsonb_build_object(
            'kind', 'derivation', 'source_assertion_id', v_id
        ));
    END LOOP;
    FOREACH v_id IN ARRAY coalesce(p_source_event_ids, '{}'::uuid[]) LOOP
        v_evidence := array_append(v_evidence, jsonb_build_object('kind', 'source', 'event_id', v_id));
    END LOOP;

    IF v_status = 'accepted' THEN
        SELECT * INTO v_incumbent
        FROM current_valid_assertions
        WHERE subject_ref = v_subject_ref
          AND assertion_type = 'digest'
          AND assertion_key = v_key
        LIMIT 1;
        IF FOUND THEN
            PERFORM mark_assertion_superseded(v_incumbent.id, v_new_id);
        END IF;
    END IF;

    INSERT INTO assertions (
        id, assertion_type, assertion_key, status, basis,
        subject_node_id, subject_edge_id, claim, confidence, attrs
    ) VALUES (
        v_new_id, 'digest', v_key, v_status, 'inferred',
        p_subject_node_id, p_subject_edge_id, p_claim, p_confidence,
        coalesce(p_attrs, '{}'::jsonb) || jsonb_build_object(
            'watermark', v_watermark,
            'distillation_event_id', v_event_id,
            'agent', p_agent
        ) || v_review_gate
    );
    PERFORM append_assertion_evidence(v_new_id, v_evidence);
    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION record_assertion(text,jsonb,uuid,uuid,text,timestamptz,timestamptz,numeric,text,text,jsonb[],text,jsonb,uuid) IS
    'Record an assertion. Where the review policy demotes the write, the row lands as a candidate carrying attrs.review_gate {pending, requested_status, review_policy, scope_node_id, incumbent_assertion_id} and a NOTICE names the policy and the scope. Where the settle gate demotes it first, the row carries attrs.settle_gate alone, as it always did.';

COMMENT ON FUNCTION record_distillation(uuid,uuid,text,jsonb,uuid[],uuid[],text,text,uuid,numeric,jsonb) IS
    'Write an inferred digest with derivation evidence. Where the review policy demotes the write, the digest lands as a candidate carrying attrs.review_gate in the same shape record_assertion() and supersede_assertion() write, and a NOTICE names the policy and the scope.';
