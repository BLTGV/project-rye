-- Core Model v2: bitemporal history and candidate exclusion.

SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false);
SELECT set_config('app.current_user_id', 'conformance:v2-bitemporal', false);
SELECT set_config('app.current_teams', '', false);

DO $$
DECLARE
    v_candidate uuid;
    v_late_known uuid;
    v_new uuid;
    v_node uuid;
    v_old uuid;
BEGIN
    INSERT INTO nodes (node_type, label, external_id, external_source, properties)
    VALUES ('project', 'V2 Bitemporal Project', gen_random_uuid()::text, 'conformance:v2', '{"suite":"core-model-v2"}')
    RETURNING id INTO v_node;

    INSERT INTO assertions (
        assertion_type,
        assertion_key,
        subject_node_id,
        claim,
        asserted_at,
        effective_at,
        effective_to,
        basis
    ) VALUES (
        'project_status',
        'default',
        v_node,
        '{"status":"planned"}',
        '2020-01-01 00:00:00+00',
        '2020-01-01 00:00:00+00',
        '2021-01-01 00:00:00+00',
        'assumed'
    )
    RETURNING id INTO v_old;

    v_new := supersede_assertion(
        p_old_assertion_id := v_old,
        p_new_assertion_type := 'project_status',
        p_new_subject_node_id := v_node,
        p_new_subject_edge_id := NULL,
        p_new_claim := '{"status":"cancelled"}',
        p_new_assertion_key := 'default',
        p_new_effective_at := '2020-01-01 00:00:00+00',
        p_new_effective_to := '2021-01-01 00:00:00+00',
        p_new_basis := 'assumed'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM assertions_as_of(
            '2020-06-01 00:00:00+00',
            '2020-06-01 00:00:00+00'
        )
        WHERE id = v_old
    ) THEN
        RAISE EXCEPTION 'Superseded assertion was not answerable for its past belief interval';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM assertions_as_of(
            '2020-06-01 00:00:00+00',
            '2019-12-31 00:00:00+00'
        )
        WHERE id = v_old
    ) THEN
        RAISE EXCEPTION 'assertions_as_of ignored asserted_at knowledge time';
    END IF;

    INSERT INTO assertions (
        assertion_type,
        assertion_key,
        subject_node_id,
        claim,
        asserted_at,
        effective_at,
        effective_to,
        basis
    ) VALUES (
        'budget',
        'default',
        v_node,
        '{"amount":1000}',
        '2020-08-01 00:00:00+00',
        '2020-01-01 00:00:00+00',
        '2021-01-01 00:00:00+00',
        'assumed'
    )
    RETURNING id INTO v_late_known;

    IF EXISTS (
        SELECT 1 FROM assertions_as_of(
            '2020-06-01 00:00:00+00',
            '2020-06-01 00:00:00+00'
        ) WHERE id = v_late_known
    ) THEN
        RAISE EXCEPTION 'Late-known assertion appeared before its knowledge time';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM assertions_as_of(
            '2020-06-01 00:00:00+00',
            '2020-09-01 00:00:00+00'
        ) WHERE id = v_late_known
    ) THEN
        RAISE EXCEPTION 'Late-known assertion missing after its knowledge time';
    END IF;

    v_candidate := record_assertion(
        p_assertion_type := 'budget',
        p_assertion_key := 'default',
        p_subject_node_id := v_node,
        p_claim := '{"amount":2000}',
        p_effective_at := '2020-01-01 00:00:00+00',
        p_effective_to := '2021-01-01 00:00:00+00',
        p_status := 'candidate',
        p_basis := 'assumed'
    );

    IF EXISTS (
        SELECT 1 FROM assertions_as_of(
            '2020-06-01 00:00:00+00',
            now()
        ) WHERE id = v_candidate
    ) THEN
        RAISE EXCEPTION 'Candidate appeared in assertions_as_of';
    END IF;
    IF EXISTS (
        SELECT 1 FROM current_valid_assertions
        WHERE id IN (v_old, v_new, v_late_known, v_candidate)
    ) THEN
        RAISE EXCEPTION 'Expired or candidate assertions appeared in current_valid_assertions';
    END IF;
END;
$$;

-- Backdated correction: superseded row remains answerable for effective
-- times its successor does not govern (regression from blind scenario eval).
DO $$
DECLARE
    v_node uuid;
    v_old uuid;
    v_new uuid;
    v_found int;
BEGIN
    INSERT INTO nodes (node_type, label, external_id, external_source)
    VALUES ('project', 'V2 Backdated Correction Subject', gen_random_uuid()::text, 'conformance:v2')
    RETURNING id INTO v_node;

    -- Old truth: no effective window, believed since ingestion.
    v_old := record_assertion(
        p_assertion_type := 'policy_threshold',
        p_assertion_key := 'default',
        p_subject_node_id := v_node,
        p_claim := '{"threshold": 10000}',
        p_basis := 'assumed'
    );

    -- Correction learned later: reality changed 2026-05-01.
    v_new := record_assertion(
        p_assertion_type := 'policy_threshold',
        p_assertion_key := 'default',
        p_subject_node_id := v_node,
        p_claim := '{"threshold": 5000}',
        p_basis := 'assumed',
        p_status := 'candidate',
        p_effective_at := '2026-05-01'
    );
    PERFORM accept_assertion(v_new, p_reason := 'backdated correction test');

    -- Current-effective query returns the new value...
    SELECT count(*) INTO v_found FROM assertions_as_of(now(), now()) a
    WHERE a.subject_node_id = v_node AND a.claim->>'threshold' = '5000';
    IF v_found <> 1 THEN
        RAISE EXCEPTION 'Backdated correction: current value wrong (got % rows)', v_found;
    END IF;

    -- ...and the pre-correction effective time returns the OLD value under
    -- current knowledge, even though the old row is superseded.
    SELECT count(*) INTO v_found FROM assertions_as_of('2026-04-15'::timestamptz, now()) a
    WHERE a.subject_node_id = v_node AND a.claim->>'threshold' = '10000';
    IF v_found <> 1 THEN
        RAISE EXCEPTION 'Backdated correction: historical value unqueryable (got % rows)', v_found;
    END IF;

    RAISE NOTICE 'PASS: backdated correction keeps history answerable';
END;
$$;
