-- Knowledge mechanisms v2 §§4-6 and §7.6-9: labeled reputation,
-- prediction scoring/calibration, induction gates, and confidence caps.

SET search_path = rye, public, pg_catalog;
BEGIN;

DO $$
DECLARE
    v_actual uuid;
    v_baseline numeric;
    v_candidate uuid;
    v_cap_current uuid;
    v_cap_effective numeric;
    v_cap_witness uuid;
    v_competitor uuid;
    v_competitor_witness uuid;
    v_corrected uuid;
    v_derived uuid;
    v_event uuid;
    v_failed boolean;
    v_high_witness uuid;
    v_horizon timestamptz := now() - interval '2 days';
    v_incumbent uuid;
    v_low_current uuid;
    v_low_effective numeric;
    v_low_witness uuid;
    v_pattern uuid;
    v_pattern_node uuid;
    v_prediction_correct uuid;
    v_prediction_incorrect uuid;
    v_prediction_unresolved uuid;
    v_source uuid;
    v_subject uuid;
    v_subjects uuid[] := '{}'::uuid[];
    v_witness uuid;
    i int;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:outcomes-predictions-patterns', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label) VALUES
        ('person', 'High-sample witness'),
        ('person', 'Low-sample witness'),
        ('person', 'Capped witness'),
        ('person', 'Competitor witness'),
        ('person', 'Prediction witness'),
        ('thing', 'Outcome-label subject');
    SELECT id INTO v_high_witness FROM nodes WHERE label = 'High-sample witness' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_low_witness FROM nodes WHERE label = 'Low-sample witness' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_cap_witness FROM nodes WHERE label = 'Capped witness' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_competitor_witness FROM nodes WHERE label = 'Competitor witness' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_witness FROM nodes WHERE label = 'Prediction witness' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_subject FROM nodes WHERE label = 'Outcome-label subject' ORDER BY created_at DESC LIMIT 1;

    -- Accepting one candidate labels other live candidates displaced. A plain
    -- update supersession remains neutral.
    v_event := record_event('outcome_fixture', 'outcome fixture',
                            p_participant_ids := ARRAY[v_subject],
                            p_participant_roles := ARRAY['subject']);
    v_incumbent := record_assertion(
        'outcome_state', '{"state":"old"}', v_subject,
        p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object(
            'kind','source','event_id',v_event,'witness_node_id',v_high_witness
        )]
    );
    v_candidate := record_assertion(
        'outcome_state', '{"state":"winner"}', v_subject,
        p_status := 'candidate', p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object(
            'kind','source','event_id',v_event,'witness_node_id',v_competitor_witness
        )]
    );
    v_competitor := record_assertion(
        'outcome_state', '{"state":"loser"}', v_subject,
        p_status := 'candidate', p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object(
            'kind','source','event_id',v_event,'witness_node_id',v_competitor_witness
        )]
    );
    PERFORM accept_assertion(v_candidate, p_supersedes_as := 'update');
    IF (SELECT attrs->>'outcome' FROM assertions WHERE id = v_competitor) <> 'displaced'
       OR (SELECT attrs->>'displaced_by' FROM assertions WHERE id = v_competitor) <> v_candidate::text
    THEN
        RAISE EXCEPTION 'accept_assertion did not label competing loser displaced';
    END IF;
    IF (SELECT attrs ? 'outcome' FROM assertions WHERE id = v_incumbent) THEN
        RAISE EXCEPTION 'plain update supersession incorrectly labeled incumbent';
    END IF;

    -- Five witnessed claims establish a non-low sample. Plain supersession
    -- does not move correction_rate; labeled rejection and correction do.
    FOR i IN 1..5 LOOP
        INSERT INTO nodes (node_type, label)
        VALUES ('thing', 'Reliability subject ' || i) RETURNING id INTO v_subject;
        v_subjects := array_append(v_subjects, v_subject);
        v_event := record_event('reliability_fixture', 'reliability fixture ' || i,
                                p_participant_ids := ARRAY[v_subject],
                                p_participant_roles := ARRAY['subject']);
        PERFORM record_assertion(
            'reliability_fact', jsonb_build_object('value', i), v_subject,
            p_basis := 'reported',
            p_evidence := ARRAY[jsonb_build_object(
                'kind','source','event_id',v_event,'witness_node_id',v_high_witness
            )]
        );
    END LOOP;

    SELECT correction_rate INTO v_baseline
    FROM source_reliability WHERE witness_node_id = v_high_witness;
    IF v_baseline <> 0 OR (SELECT low_sample FROM source_reliability WHERE witness_node_id = v_high_witness) THEN
        RAISE EXCEPTION 'source_reliability baseline/low_sample is wrong';
    END IF;

    v_subject := v_subjects[1];
    v_event := record_event('reliability_fixture', 'plain supersession',
                            p_participant_ids := ARRAY[v_subject],
                            p_participant_roles := ARRAY['subject']);
    PERFORM record_assertion(
        'reliability_fact', '{"value":"updated"}', v_subject,
        p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object(
            'kind','source','event_id',v_event,'witness_node_id',v_high_witness
        )]
    );
    IF (SELECT correction_rate FROM source_reliability WHERE witness_node_id = v_high_witness) <> v_baseline THEN
        RAISE EXCEPTION 'plain supersession moved correction_rate';
    END IF;

    v_subject := v_subjects[2];
    v_candidate := record_assertion(
        'rejected_fact', '{"value":"bad"}', v_subject,
        p_status := 'candidate', p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object(
            'kind','source','event_id',v_event,'witness_node_id',v_high_witness
        )]
    );
    PERFORM reject_candidate(v_candidate, 'unsupported fixture', p_outcome := 'unsupported');
    IF (SELECT rejected_incorrect FROM source_reliability WHERE witness_node_id = v_high_witness) <> 1 THEN
        RAISE EXCEPTION 'labeled rejection did not affect source reliability';
    END IF;

    v_subject := v_subjects[3];
    SELECT id INTO v_incumbent
    FROM current_valid_assertions
    WHERE subject_node_id = v_subject AND assertion_type = 'reliability_fact';
    v_candidate := record_assertion(
        'reliability_fact', '{"value":"corrected"}', v_subject,
        p_status := 'candidate', p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object(
            'kind','source','event_id',v_event,'witness_node_id',v_competitor_witness
        )]
    );
    PERFORM accept_assertion(v_candidate, p_supersedes_as := 'correction');
    IF (SELECT attrs->>'outcome' FROM assertions WHERE id = v_incumbent) <> 'corrected'
       OR (SELECT corrections FROM source_reliability WHERE witness_node_id = v_high_witness) <> 1
    THEN
        RAISE EXCEPTION 'labeled correction did not affect source reliability';
    END IF;

    -- Low-sample witnesses are not discounted. Once >=5 claims exist, a
    -- correction rate above .5 can discount the prior by at most .5.
    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Low confidence current') RETURNING id INTO v_subject;
    v_event := record_event('confidence_fixture', 'low current',
                            p_participant_ids := ARRAY[v_subject], p_participant_roles := ARRAY['subject']);
    v_low_current := record_assertion(
        'confidence_low', '{"value":"current"}', v_subject,
        p_confidence := 0.8, p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object(
            'kind','source','event_id',v_event,'witness_node_id',v_low_witness
        )]
    );
    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Low confidence rejected') RETURNING id INTO v_subject;
    v_candidate := record_assertion(
        'confidence_low_rejected', '{"value":"bad"}', v_subject,
        p_status := 'candidate', p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object(
            'kind','source','event_id',v_event,'witness_node_id',v_low_witness
        )]
    );
    PERFORM reject_candidate(v_candidate, 'incorrect low sample', p_outcome := 'incorrect');
    SELECT effective_confidence(ROW(a.*)::assertions) INTO v_low_effective
    FROM assertions a WHERE a.id = v_low_current;
    IF abs(v_low_effective - 0.88) > 0.000001
       OR NOT (SELECT low_sample FROM source_reliability WHERE witness_node_id = v_low_witness)
    THEN
        RAISE EXCEPTION 'low-sample confidence discount should be skipped, got %', v_low_effective;
    END IF;

    FOR i IN 1..5 LOOP
        INSERT INTO nodes (node_type, label)
        VALUES ('thing', 'Capped rejected ' || i) RETURNING id INTO v_subject;
        v_event := record_event('confidence_fixture', 'capped rejected ' || i,
                                p_participant_ids := ARRAY[v_subject], p_participant_roles := ARRAY['subject']);
        v_candidate := record_assertion(
            'confidence_bad', jsonb_build_object('value', i), v_subject,
            p_assertion_key := i::text, p_status := 'candidate', p_basis := 'reported',
            p_evidence := ARRAY[jsonb_build_object(
                'kind','source','event_id',v_event,'witness_node_id',v_cap_witness
            )]
        );
        PERFORM reject_candidate(v_candidate, 'incorrect capped sample', p_outcome := 'incorrect');
    END LOOP;
    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Capped confidence current') RETURNING id INTO v_subject;
    v_event := record_event('confidence_fixture', 'capped current',
                            p_participant_ids := ARRAY[v_subject], p_participant_roles := ARRAY['subject']);
    v_cap_current := record_assertion(
        'confidence_cap', '{"value":"current"}', v_subject,
        p_confidence := 0.8, p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object(
            'kind','source','event_id',v_event,'witness_node_id',v_cap_witness
        )]
    );
    SELECT effective_confidence(ROW(a.*)::assertions) INTO v_cap_effective
    FROM assertions a WHERE a.id = v_cap_current;
    IF abs(v_cap_effective - 0.44) > 0.000001
       OR (SELECT low_sample FROM source_reliability WHERE witness_node_id = v_cap_witness)
    THEN
        RAISE EXCEPTION 'witness discount was not capped at .5, got %', v_cap_effective;
    END IF;

    -- Predictions use their own tuple and score the outcome as of horizon,
    -- including a correction asserted after that horizon.
    INSERT INTO nodes (node_type, label) VALUES ('opportunity', 'Correct prediction subject') RETURNING id INTO v_subject;
    v_prediction_correct := record_prediction(
        v_subject, NULL, 'conversion', 'pilot converts', 'deal_stage:default',
        '{"stage":"closed_won"}', 0.7, v_horizon, v_witness
    );
    v_event := record_event('deal_stage_changed', 'initial historical stage',
                            p_participant_ids := ARRAY[v_subject], p_participant_roles := ARRAY['subject']);
    v_actual := record_assertion(
        'deal_stage', '{"stage":"closed_lost"}', v_subject,
        p_effective_at := v_horizon - interval '1 day', p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object('kind','source','event_id',v_event)]
    );
    v_corrected := record_assertion(
        'deal_stage', '{"stage":"closed_won"}', v_subject,
        p_status := 'candidate', p_effective_at := v_horizon - interval '1 day',
        p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object('kind','source','event_id',v_event)]
    );
    PERFORM accept_assertion(v_corrected, p_supersedes_as := 'correction');
    IF EXISTS (
        SELECT 1 FROM assertions
        WHERE id = v_prediction_correct
          AND assertion_type = 'deal_stage'
    ) OR NOT EXISTS (
        SELECT 1 FROM current_valid_assertions
        WHERE subject_node_id = v_subject AND assertion_type = 'deal_stage'
    ) THEN
        RAISE EXCEPTION 'prediction occupied or displaced the predicted tuple';
    END IF;

    INSERT INTO nodes (node_type, label) VALUES ('opportunity', 'Incorrect prediction subject') RETURNING id INTO v_subject;
    v_prediction_incorrect := record_prediction(
        v_subject, NULL, 'conversion', 'pilot converts', 'deal_stage:default',
        '{"stage":"closed_won"}', 0.7, v_horizon, v_witness
    );
    v_event := record_event('deal_stage_changed', 'historical lost stage',
                            p_participant_ids := ARRAY[v_subject], p_participant_roles := ARRAY['subject']);
    PERFORM record_assertion(
        'deal_stage', '{"stage":"closed_lost"}', v_subject,
        p_effective_at := v_horizon - interval '1 day', p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object('kind','source','event_id',v_event)]
    );

    INSERT INTO nodes (node_type, label) VALUES ('opportunity', 'Unresolved prediction subject') RETURNING id INTO v_subject;
    v_prediction_unresolved := record_prediction(
        v_subject, NULL, 'conversion', 'pilot converts', 'deal_stage:default',
        '{"stage":"closed_won"}', 0.7, v_horizon, v_witness
    );

    PERFORM score_due_predictions();
    IF (SELECT attrs->>'outcome' FROM assertions WHERE id = v_prediction_correct) <> 'correct'
       OR (SELECT attrs->>'outcome' FROM assertions WHERE id = v_prediction_incorrect) <> 'incorrect'
       OR (SELECT attrs->>'outcome' FROM assertions WHERE id = v_prediction_unresolved) <> 'unresolvable'
    THEN
        RAISE EXCEPTION 'prediction scoring outcomes are wrong';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM calibration_report
        WHERE witness_node_id = v_witness
          AND probability_bucket = 0.7
          AND prediction_count = 2
          AND abs(brier_score - 0.29) < 0.000001
          AND abs(hit_rate - 0.5) < 0.000001
    ) THEN
        RAISE EXCEPTION 'calibration report brier/hit-rate fixture failed';
    END IF;

    -- Pattern claims are candidate-only and require three distinct supporting
    -- subjects. Counter-evidence is counted separately.
    v_subjects := '{}'::uuid[];
    FOR i IN 1..4 LOOP
        INSERT INTO nodes (node_type, label)
        VALUES ('case', 'Pattern source ' || i) RETURNING id INTO v_subject;
        v_subjects := array_append(v_subjects, v_subject);
        v_source := record_assertion(
            'case_result', jsonb_build_object('result', CASE WHEN i < 4 THEN 'success' ELSE 'failure' END),
            v_subject, p_basis := 'assumed'
        );
        v_subjects := array_append(v_subjects, v_source);
    END LOOP;

    v_failed := false;
    BEGIN
        PERFORM record_assertion(
            'pattern_claim', '{"statement":"must review"}', v_subject,
            p_status := 'accepted', p_basis := 'assumed'
        );
    EXCEPTION WHEN OTHERS THEN
        v_failed := SQLERRM LIKE 'pattern_claim assertions must be recorded as candidates%';
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'direct accepted pattern_claim write was not refused';
    END IF;

    v_failed := false;
    BEGIN
        PERFORM record_pattern(
            'Under-supported pattern', '{"statement":"too few"}',
            ARRAY[v_subjects[2], v_subjects[4]]
        );
    EXCEPTION WHEN OTHERS THEN
        v_failed := SQLERRM LIKE 'record_pattern requires derivation evidence from at least 3 distinct subjects%';
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'record_pattern accepted fewer than three distinct subjects';
    END IF;

    v_pattern := record_pattern(
        'Successful cases share review',
        '{"statement":"review predicts success"}',
        ARRAY[v_subjects[2], v_subjects[4], v_subjects[6]],
        p_contradicting_assertion_ids := ARRAY[v_subjects[8]],
        p_confidence := 0.4,
        p_actor := 'test:induction'
    );
    SELECT subject_node_id INTO v_pattern_node FROM assertions WHERE id = v_pattern;
    IF (SELECT status FROM assertions WHERE id = v_pattern) <> 'candidate'
       OR (SELECT node_type FROM nodes WHERE id = v_pattern_node) <> 'pattern'
       OR NOT EXISTS (
           SELECT 1 FROM pattern_support
           WHERE pattern_assertion_id = v_pattern
             AND support_count = 3
             AND contradiction_count = 1
             AND distinct_supporting_subjects = 3
       )
    THEN
        RAISE EXCEPTION 'record_pattern or pattern_support contract failed';
    END IF;

    PERFORM accept_assertion(v_pattern, p_reason := 'human-reviewed pattern');
    v_event := record_event('inference', 'derived from accepted pattern',
                            p_participant_ids := ARRAY[v_subjects[1]],
                            p_participant_roles := ARRAY['subject']);
    v_derived := record_assertion(
        'pattern_derived_result', '{"result":"expected"}', v_subjects[1],
        p_confidence := 0.9, p_basis := 'inferred',
        p_evidence := ARRAY[jsonb_build_object(
            'kind','derivation','source_assertion_id',v_pattern
        )]
    );
    IF (SELECT effective_confidence FROM current_assertions_weighted WHERE id = v_derived)
       > (SELECT effective_confidence FROM current_assertions_weighted WHERE id = v_pattern)
       OR abs((SELECT effective_confidence FROM current_assertions_weighted WHERE id = v_derived) - 0.4) > 0.000001
    THEN
        RAISE EXCEPTION 'one-hop pattern confidence cap was not applied';
    END IF;

    -- All mechanism views are security invokers. No tables were introduced.
    IF EXISTS (
        SELECT required.view_name
        FROM (VALUES
            ('node_salience'),
            ('type_vocabulary_report'),
            ('source_reliability'),
            ('calibration_report'),
            ('pattern_support'),
            ('review_queue'),
            ('stale_digests'),
            ('current_assertions_weighted')
        ) required(view_name)
        WHERE NOT EXISTS (
            SELECT 1
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'rye'
              AND c.relname = required.view_name
              AND 'security_invoker=true' = ANY(coalesce(c.reloptions, '{}'::text[]))
        )
    ) THEN
        RAISE EXCEPTION 'one or more knowledge-mechanism views are not security invokers';
    END IF;
END
$$;

-- Prediction misses are calibration, not unreliability: a witness whose only
-- adverse outcomes are missed forecasts keeps correction_rate = 0 (regression
-- for the folding defect found by blind scenario evaluation, issue #10).
DO $$
DECLARE
    v_witness uuid;
    v_subject uuid;
    v_event uuid;
    v_i int;
    v_pred uuid;
    v_rate numeric;
    v_pi int;
BEGIN
    INSERT INTO nodes (node_type, label) VALUES ('person', 'Calibrated Hedger')
    RETURNING id INTO v_witness;

    -- Five witnessed factual claims, none ever corrected (non-low sample).
    FOR v_i IN 1..5 LOOP
        INSERT INTO nodes (node_type, label)
        VALUES ('thing', 'Hedger subject ' || v_i) RETURNING id INTO v_subject;
        v_event := record_event('hedger_fixture', 'hedger fixture ' || v_i,
                                p_participant_ids := ARRAY[v_subject],
                                p_participant_roles := ARRAY['subject']);
        PERFORM record_assertion(
            'hedger_fact', jsonb_build_object('n', v_i), v_subject,
            p_assertion_key := 'default', p_basis := 'reported',
            p_evidence := ARRAY[jsonb_build_object(
                'kind','source','event_id',v_event,'witness_node_id',v_witness)]);
    END LOOP;

    -- One well-hedged prediction that resolves against its predicted value.
    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Hedger outcome subject')
    RETURNING id INTO v_subject;
    v_pred := record_prediction(
        p_subject_node_id := v_subject,
        p_subject_edge_id := NULL,
        p_assertion_key := 'hedged-call',
        p_question := 'does it happen',
        p_outcome_key := 'hedger_outcome:default',
        p_predicted_value := '{"happened": true}',
        p_probability := 0.4,
        p_horizon := clock_timestamp() - interval '1 hour',
        p_witness_node_id := v_witness);
    INSERT INTO assertions (assertion_type, assertion_key, subject_node_id,
                            claim, asserted_at, effective_at, basis)
    VALUES ('hedger_outcome', 'default', v_subject, '{"happened": false}',
            clock_timestamp() - interval '2 hours',
            clock_timestamp() - interval '2 hours', 'assumed');
    PERFORM score_due_predictions();

    SELECT correction_rate, predictions_incorrect INTO v_rate, v_pi
    FROM source_reliability WHERE witness_node_id = v_witness;
    IF v_pi <> 1 THEN
        RAISE EXCEPTION 'missed prediction not visible in predictions_incorrect (got %)', v_pi;
    END IF;
    IF v_rate <> 0 THEN
        RAISE EXCEPTION 'prediction miss leaked into correction_rate (got %)', v_rate;
    END IF;
    RAISE NOTICE 'PASS: prediction misses excluded from factual correction_rate';
END
$$;

ROLLBACK;
