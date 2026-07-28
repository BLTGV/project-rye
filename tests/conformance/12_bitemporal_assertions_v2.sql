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
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('project', 'V2 Bitemporal Project', '{"suite":"core-model-v2"}')
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
