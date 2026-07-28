-- Core Model v2: candidate lifecycle, operational invisibility, and tuple gates.

SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false);
SELECT set_config('app.current_user_id', 'conformance:v2-lifecycle', false);
SELECT set_config('app.current_teams', '', false);

DO $$
DECLARE
    v_candidate_one uuid;
    v_candidate_two uuid;
    v_incumbent uuid;
    v_inferred uuid;
    v_node uuid;
    v_source uuid;
    v_summary jsonb;
    v_updated int;
BEGIN
    INSERT INTO nodes (
        node_type, label, external_id, external_source, properties
    ) VALUES (
        'opportunity',
        'V2 Lifecycle Opportunity',
        gen_random_uuid()::text,
        'conformance:v2',
        '{"code":"V2-LIFECYCLE","name":"V2 Lifecycle Opportunity"}'
    )
    RETURNING id INTO v_node;

    v_incumbent := record_assertion(
        p_assertion_type := 'deal_stage',
        p_assertion_key := 'default',
        p_subject_node_id := v_node,
        p_claim := '{"stage":"qualification","pipeline":"default"}',
        p_basis := 'assumed'
    );

    v_candidate_one := record_assertion(
        p_assertion_type := 'deal_stage',
        p_assertion_key := 'default',
        p_subject_node_id := v_node,
        p_claim := '{"stage":"proposal","pipeline":"default"}',
        p_status := 'candidate',
        p_basis := 'assumed'
    );
    v_candidate_two := record_assertion(
        p_assertion_type := 'deal_stage',
        p_assertion_key := 'default',
        p_subject_node_id := v_node,
        p_claim := '{"stage":"negotiation","pipeline":"default"}',
        p_status := 'candidate',
        p_basis := 'assumed'
    );

    IF (SELECT count(*) FROM current_valid_assertions WHERE id IN (v_candidate_one, v_candidate_two)) <> 0 THEN
        RAISE EXCEPTION 'Candidates leaked into current_valid_assertions';
    END IF;

    v_summary := agent_node_summary(v_node, 10);
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_summary->'current_facts') fact
        WHERE fact->'claim'->>'stage' IN ('proposal', 'negotiation')
    ) THEN
        RAISE EXCEPTION 'Candidates leaked into agent_node_summary';
    END IF;

    IF (SELECT candidate_count FROM review_queue
        WHERE subject_node_id = v_node AND assertion_type = 'deal_stage') <> 2
    THEN
        RAISE EXCEPTION 'review_queue did not group both tuple candidates';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM competing_candidates
        WHERE subject_node_id = v_node
          AND assertion_type = 'deal_stage'
          AND candidate_count = 2
    ) THEN
        RAISE EXCEPTION 'competing_candidates did not expose the dispute';
    END IF;

    UPDATE assertions SET status = 'accepted' WHERE id = v_candidate_one;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated <> 0 THEN
        RAISE EXCEPTION 'Direct candidate-to-accepted transition was not blocked';
    END IF;

    PERFORM accept_assertion(
        v_candidate_one,
        NULL,
        'Conformance winner',
        'conformance:v2-lifecycle'
    );

    IF NOT EXISTS (
        SELECT 1 FROM assertions
        WHERE id = v_incumbent
          AND superseded_by = v_candidate_one
          AND superseded_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'accept_assertion did not supersede incumbent';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM assertions
        WHERE id = v_candidate_two
          AND status = 'candidate'
          AND superseded_at IS NULL
    ) THEN
        RAISE EXCEPTION 'accept_assertion changed the losing candidate';
    END IF;

    PERFORM reject_candidate(
        v_candidate_two,
        'Insufficient support',
        'conformance:v2-lifecycle'
    );
    IF NOT EXISTS (
        SELECT 1 FROM events
        WHERE event_type = 'candidate_rejected'
          AND properties->>'assertion_id' = v_candidate_two::text
          AND properties->>'reason' = 'Insufficient support'
    ) THEN
        RAISE EXCEPTION 'reject_candidate did not retain the reason';
    END IF;

    -- Direct basis mutation and reverse status changes are blocked.
    UPDATE assertions SET basis = 'observed' WHERE id = v_candidate_one;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated <> 0 THEN
        RAISE EXCEPTION 'Direct basis mutation was not blocked';
    END IF;
    UPDATE assertions SET status = 'candidate' WHERE id = v_candidate_one;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated <> 0 THEN
        RAISE EXCEPTION 'Direct accepted-to-candidate status transition was not blocked';
    END IF;

    -- Inferred candidates cannot displace a non-inferred accepted holder.
    v_source := record_assertion(
        p_assertion_type := 'distillation_input',
        p_assertion_key := 'inferred-gate',
        p_subject_node_id := v_node,
        p_claim := '{"value":"source"}',
        p_basis := 'assumed'
    );
    PERFORM record_assertion(
        p_assertion_type := 'risk_level',
        p_assertion_key := 'default',
        p_subject_node_id := v_node,
        p_claim := '{"risk":"low"}',
        p_basis := 'assumed'
    );
    v_inferred := record_assertion(
        p_assertion_type := 'risk_level',
        p_assertion_key := 'default',
        p_subject_node_id := v_node,
        p_claim := '{"risk":"high"}',
        p_status := 'candidate',
        p_basis := 'inferred',
        p_evidence := ARRAY[
            jsonb_build_object('kind', 'derivation', 'source_assertion_id', v_source)
        ]
    );

    BEGIN
        PERFORM accept_assertion(v_inferred, NULL, 'Should fail', 'conformance:v2-lifecycle');
        RAISE EXCEPTION 'Expected inferred displacement refusal';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'Inferred candidate % cannot displace%' THEN
            RAISE;
        END IF;
    END;

    BEGIN
        PERFORM supersede_assertion(
            p_old_assertion_id := v_candidate_one,
            p_new_assertion_type := 'different_type',
            p_new_subject_node_id := v_node,
            p_new_subject_edge_id := NULL,
            p_new_claim := '{"bad":true}',
            p_new_assertion_key := 'default'
        );
        RAISE EXCEPTION 'Expected cross-tuple supersession refusal';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'Cross-tuple supersession is not allowed%' THEN
            RAISE;
        END IF;
    END;
END;
$$;

DO $$
BEGIN
    PERFORM record_assertion(
        p_assertion_type := 'deal_stage',
        p_assertion_key := 'default',
        p_subject_node_id := (
            SELECT id FROM nodes
            WHERE properties->>'code' = 'V2-LIFECYCLE'
            ORDER BY created_at DESC
            LIMIT 1
        ),
        p_claim := '{"stage":"candidate_only","pipeline":"default"}',
        p_status := 'candidate',
        p_basis := 'assumed'
    );
END;
$$;

SELECT refresh_materialized_views();

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM opportunities_active
        WHERE code = 'V2-LIFECYCLE'
          AND stage IN ('negotiation', 'candidate_only')
    ) THEN
        RAISE EXCEPTION 'Live candidate leaked into CRM materialized view';
    END IF;
END;
$$;
