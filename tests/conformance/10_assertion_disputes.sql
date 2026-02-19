-- Test: contest_assertion() and resolve_dispute() (Gap 3 fix)

DO $$
DECLARE
    v_node_id uuid;
    v_original_id uuid;
    v_contested_id uuid;
    v_final_id uuid;
    v_dispute_count int;
    v_active_count int;
    v_key text;
    v_claim jsonb;
    v_event_count int;
    v_error boolean := false;
BEGIN
    -- Setup: create a node with an assertion
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('parcel', 'Test Parcel 42-7-3', '{"suite": "conformance"}')
    RETURNING id INTO v_node_id;

    INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
    VALUES ('ownership', 'default', v_node_id, '{"fraction": 0.25, "owner": "Smith Family Trust"}', 1.0)
    RETURNING id INTO v_original_id;

    -- Test 1: contest_assertion creates a competing assertion
    v_contested_id := contest_assertion(
        p_existing_assertion_id := v_original_id,
        p_new_claim             := '{"fraction": 0.125, "owner": "Smith Family Trust", "basis": "county filing 2024-0892"}',
        p_source                := 'county_filing_2024_0892',
        p_confidence            := 0.7,
        p_reason                := 'County filing shows different fraction'
    );

    IF v_contested_id IS NULL THEN
        RAISE EXCEPTION 'FAIL: contest_assertion returned NULL';
    END IF;
    RAISE NOTICE 'PASS: contest_assertion() returns new assertion ID';

    -- Test 2: Both assertions are active (not superseded)
    SELECT count(*) INTO v_active_count
    FROM assertions
    WHERE subject_node_id = v_node_id
      AND assertion_type = 'ownership'
      AND superseded_at IS NULL;

    IF v_active_count <> 2 THEN
        RAISE EXCEPTION 'FAIL: expected 2 active assertions, got %', v_active_count;
    END IF;
    RAISE NOTICE 'PASS: Both original and contested assertions are active';

    -- Test 3: Contested assertion has the right key
    SELECT assertion_key INTO v_key
    FROM assertions WHERE id = v_contested_id;

    IF v_key <> 'contested:county_filing_2024_0892' THEN
        RAISE EXCEPTION 'FAIL: expected key "contested:county_filing_2024_0892", got "%"', v_key;
    END IF;
    RAISE NOTICE 'PASS: Contested assertion key is "contested:<source>"';

    -- Test 4: Contested assertion has dispute metadata in attrs
    SELECT attrs->'dispute'->>'contests' INTO v_key
    FROM assertions WHERE id = v_contested_id;

    IF v_key <> v_original_id::text THEN
        RAISE EXCEPTION 'FAIL: dispute.contests should reference original assertion';
    END IF;
    RAISE NOTICE 'PASS: Disputed assertion attrs contain dispute metadata';

    -- Test 5: A dispute_raised event was recorded
    SELECT count(*) INTO v_event_count
    FROM events
    WHERE event_type = 'dispute_raised'
      AND properties->>'existing_assertion_id' = v_original_id::text;

    IF v_event_count < 1 THEN
        RAISE EXCEPTION 'FAIL: no dispute_raised event found';
    END IF;
    RAISE NOTICE 'PASS: dispute_raised event recorded';

    -- Test 6: active_disputes view shows the conflict
    SELECT count(*) INTO v_dispute_count
    FROM active_disputes
    WHERE subject_node_id = v_node_id
      AND assertion_type = 'ownership';

    IF v_dispute_count <> 1 THEN
        RAISE EXCEPTION 'FAIL: active_disputes should show 1 row, got %', v_dispute_count;
    END IF;
    RAISE NOTICE 'PASS: active_disputes view shows the conflict';

    -- Test 7: Cannot contest a superseded assertion
    BEGIN
        -- First supersede an assertion
        PERFORM supersede_assertion(
            p_old_assertion_id    := v_original_id,
            p_new_assertion_type  := 'ownership',
            p_new_subject_node_id := v_node_id,
            p_new_subject_edge_id := NULL,
            p_new_claim           := '{"fraction": 0.25, "note": "reaffirmed"}',
            p_new_assertion_key   := 'default'
        );

        -- Try to contest the now-superseded original
        PERFORM contest_assertion(
            p_existing_assertion_id := v_original_id,
            p_new_claim             := '{"fraction": 0.5}',
            p_source                := 'other_source'
        );

        RAISE EXCEPTION 'FAIL: contest_assertion should reject superseded assertion';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%superseded%' THEN
            RAISE NOTICE 'PASS: contest_assertion rejects superseded assertion';
        ELSE
            RAISE EXCEPTION 'FAIL: unexpected error: %', SQLERRM;
        END IF;
    END;

    -- Reset: create fresh assertions for resolve_dispute test
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('parcel', 'Resolve Test Parcel', '{"suite": "conformance"}')
    RETURNING id INTO v_node_id;

    INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
    VALUES ('ownership', 'default', v_node_id, '{"fraction": 0.25}', 1.0)
    RETURNING id INTO v_original_id;

    v_contested_id := contest_assertion(
        p_existing_assertion_id := v_original_id,
        p_new_claim             := '{"fraction": 0.125}',
        p_source                := 'new_survey',
        p_confidence            := 0.8
    );

    -- Test 8: resolve_dispute picks the contested claim as winner
    v_final_id := resolve_dispute(
        p_winning_assertion_id := v_contested_id,
        p_reason               := 'Survey confirmed by engineer',
        p_actor                := 'user:alice'
    );

    IF v_final_id IS NULL THEN
        RAISE EXCEPTION 'FAIL: resolve_dispute returned NULL';
    END IF;
    RAISE NOTICE 'PASS: resolve_dispute() returns final assertion ID';

    -- Test 9: Only one active assertion remains
    SELECT count(*) INTO v_active_count
    FROM assertions
    WHERE subject_node_id = v_node_id
      AND assertion_type = 'ownership'
      AND superseded_at IS NULL;

    IF v_active_count <> 1 THEN
        RAISE EXCEPTION 'FAIL: expected 1 active assertion after resolve, got %', v_active_count;
    END IF;
    RAISE NOTICE 'PASS: Only one active assertion after resolve';

    -- Test 10: The surviving assertion has key='default' (promoted from contested:)
    SELECT assertion_key, claim INTO v_key, v_claim
    FROM assertions
    WHERE id = v_final_id;

    IF v_key <> 'default' THEN
        RAISE EXCEPTION 'FAIL: winning assertion should be promoted to key "default", got "%"', v_key;
    END IF;

    IF (v_claim->>'fraction')::numeric <> 0.125 THEN
        RAISE EXCEPTION 'FAIL: winning claim should have fraction 0.125, got %', v_claim->>'fraction';
    END IF;
    RAISE NOTICE 'PASS: Winner promoted to default key with correct claim';

    -- Test 11: dispute_resolved event recorded
    SELECT count(*) INTO v_event_count
    FROM events
    WHERE event_type = 'dispute_resolved'
      AND properties->>'winning_assertion_id' = v_final_id::text;

    IF v_event_count < 1 THEN
        RAISE EXCEPTION 'FAIL: no dispute_resolved event found';
    END IF;
    RAISE NOTICE 'PASS: dispute_resolved event recorded';

    -- Test 12: active_disputes no longer shows the resolved conflict
    SELECT count(*) INTO v_dispute_count
    FROM active_disputes
    WHERE subject_node_id = v_node_id
      AND assertion_type = 'ownership';

    IF v_dispute_count <> 0 THEN
        RAISE EXCEPTION 'FAIL: active_disputes should be empty after resolve, got %', v_dispute_count;
    END IF;
    RAISE NOTICE 'PASS: active_disputes empty after resolution';

    RAISE NOTICE 'All assertion dispute tests passed';
END;
$$;
