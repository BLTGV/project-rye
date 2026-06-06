-- Temporal assertions and knowledge-candidate promotion.

SET search_path = rye, public, pg_catalog;

BEGIN;

DO $$
DECLARE
    v_active_count int;
    v_candidate uuid;
    v_edge_id uuid;
    v_hist uuid;
    v_invalid_status_error boolean := false;
    v_next uuid;
    v_promoted uuid;
    v_source uuid;
    v_status text;
    v_subject uuid;
    v_task_candidate uuid;
    v_task_id uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:conformance', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('project', 'Temporal Assertion Subject', '{"suite": "conformance"}')
    RETURNING id INTO v_subject;

    v_hist := record_assertion(
        p_assertion_type  := 'project_phase',
        p_assertion_key   := 'default',
        p_subject_node_id := v_subject,
        p_claim           := '{"phase": "discovery"}',
        p_effective_at    := '2020-01-01 00:00:00+00',
        p_effective_to    := '2021-01-01 00:00:00+00',
        p_confidence      := 0.9,
        p_mode            := 'historical'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM assertions
        WHERE id = v_hist
          AND superseded_at IS NOT NULL
          AND effective_to = '2021-01-01 00:00:00+00'
    ) THEN
        RAISE EXCEPTION 'Expected historical assertion to be inserted as already superseded';
    END IF;

    PERFORM record_assertion(
        p_assertion_type  := 'project_phase',
        p_assertion_key   := 'default',
        p_subject_node_id := v_subject,
        p_claim           := '{"phase": "execution"}',
        p_effective_at    := '2021-01-01 00:00:00+00',
        p_confidence      := 0.95,
        p_mode            := 'current'
    );

    SELECT count(*) INTO v_active_count
    FROM current_assertions
    WHERE subject_node_id = v_subject
      AND assertion_type = 'project_phase'
      AND assertion_key = 'default';

    IF v_active_count <> 1 THEN
        RAISE EXCEPTION 'Expected one active current project_phase assertion, got %', v_active_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM assertions_as_of('2020-06-01 00:00:00+00')
        WHERE id = v_hist
    ) THEN
        RAISE EXCEPTION 'Expected historical assertion to appear in assertions_as_of()';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM current_valid_assertions
        WHERE id = v_hist
    ) THEN
        RAISE EXCEPTION 'Historical superseded assertion should not appear in current_valid_assertions';
    END IF;

    v_next := record_assertion(
        p_assertion_type  := 'project_phase',
        p_assertion_key   := 'default',
        p_subject_node_id := v_subject,
        p_claim           := '{"phase": "closeout"}',
        p_effective_at    := '2021-01-01 00:00:00+00',
        p_confidence      := 0.8,
        p_mode            := 'current'
    );

    SELECT count(*) INTO v_active_count
    FROM current_assertions
    WHERE subject_node_id = v_subject
      AND assertion_type = 'project_phase'
      AND assertion_key = 'default'
      AND id = v_next;

    IF v_active_count <> 1 THEN
        RAISE EXCEPTION 'Current assertion supersession did not leave exactly one active replacement';
    END IF;

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('source_item', 'Candidate Evidence Source', '{"suite": "conformance"}')
    RETURNING id INTO v_source;

    v_candidate := create_knowledge_candidate(
        p_candidate_kind   := 'fact',
        p_statement        := 'Temporal subject has accepted candidate knowledge.',
        p_target_payload   := '{"assertion_type": "operational_fact"}',
        p_normalized_key   := 'temporal-subject:accepted-candidate-knowledge',
        p_created_by       := 'test:conformance',
        p_source_node_ids  := ARRAY[v_source],
        p_confidence       := 0.77
    );

    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = v_candidate
          AND node_type = 'knowledge_candidate'
          AND properties->>'candidate_kind' = 'fact'
    ) THEN
        RAISE EXCEPTION 'Expected create_knowledge_candidate() to insert a knowledge_candidate node';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM edges
        WHERE source_id = v_candidate
          AND target_id = v_source
          AND edge_type = 'supported_by'
          AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Expected candidate to be linked to supporting source evidence';
    END IF;

    SELECT claim->>'status' INTO v_status
    FROM current_assertions
    WHERE subject_node_id = v_candidate
      AND assertion_type = 'candidate_status'
      AND assertion_key = 'default';

    IF v_status <> 'proposed' THEN
        RAISE EXCEPTION 'Expected new candidate status proposed, got %', v_status;
    END IF;

    PERFORM set_candidate_status(
        p_candidate_id := v_candidate,
        p_status       := 'needs_review',
        p_reason       := 'Conformance transition',
        p_actor        := 'test:reviewer'
    );

    SELECT claim->>'status' INTO v_status
    FROM current_assertions
    WHERE subject_node_id = v_candidate
      AND assertion_type = 'candidate_status'
      AND assertion_key = 'default';

    IF v_status <> 'needs_review' THEN
        RAISE EXCEPTION 'Expected candidate status needs_review, got %', v_status;
    END IF;

    BEGIN
        PERFORM set_candidate_status(v_candidate, 'not_a_status', 'Should fail', 'test:reviewer');
    EXCEPTION WHEN OTHERS THEN
        v_invalid_status_error := true;
    END;

    IF NOT v_invalid_status_error THEN
        RAISE EXCEPTION 'Expected invalid candidate status to fail';
    END IF;

    v_promoted := promote_candidate_to_assertion(
        p_candidate_id    := v_candidate,
        p_subject_node_id := v_subject,
        p_assertion_type  := 'operational_fact',
        p_assertion_key   := 'candidate_fact',
        p_claim           := '{"text": "Temporal subject has accepted candidate knowledge."}',
        p_effective_at    := '2024-01-01 00:00:00+00',
        p_confidence      := 0.77,
        p_actor           := 'test:reviewer'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM assertions
        WHERE id = v_promoted
          AND attrs->>'candidate_id' = v_candidate::text
          AND jsonb_array_length(attrs->'source_refs') = 1
    ) THEN
        RAISE EXCEPTION 'Promoted assertion did not preserve candidate provenance';
    END IF;

    SELECT claim->>'status' INTO v_status
    FROM current_assertions
    WHERE subject_node_id = v_candidate
      AND assertion_type = 'candidate_status'
      AND assertion_key = 'default';

    IF v_status <> 'accepted' THEN
        RAISE EXCEPTION 'Expected promoted candidate status accepted, got %', v_status;
    END IF;

    v_task_candidate := create_knowledge_candidate(
        p_candidate_kind  := 'task',
        p_statement       := 'Follow up on accepted candidate task.',
        p_created_by      := 'test:conformance',
        p_source_node_ids := ARRAY[v_source],
        p_confidence      := 0.6
    );

    v_task_id := promote_candidate_to_task(
        p_candidate_id := v_task_candidate,
        p_label        := 'Follow up on accepted candidate task.',
        p_properties   := '{"priority": "normal"}',
        p_actor        := 'test:reviewer'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = v_task_id
          AND node_type = 'task'
          AND properties->>'candidate_id' = v_task_candidate::text
    ) THEN
        RAISE EXCEPTION 'Expected task promotion to create a task node with candidate provenance';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM edges
        WHERE source_id = v_task_candidate
          AND target_id = v_task_id
          AND edge_type = 'promoted_to'
    ) THEN
        RAISE EXCEPTION 'Expected task promotion to create promoted_to edge';
    END IF;

    v_edge_id := promote_candidate_to_edge(
        p_candidate_id    := v_candidate,
        p_source_id       := v_source,
        p_target_id       := v_subject,
        p_edge_type       := 'relates_to',
        p_properties      := '{"basis": "conformance"}',
        p_effective_from  := '2024-01-01 00:00:00+00',
        p_effective_to    := '2025-01-01 00:00:00+00',
        p_actor           := 'test:reviewer'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM edges
        WHERE id = v_edge_id
          AND attrs->>'candidate_id' = v_candidate::text
          AND effective_to = '2025-01-01 00:00:00+00'
    ) THEN
        RAISE EXCEPTION 'Expected edge promotion to preserve temporal/provenance attributes';
    END IF;
END;
$$;

ROLLBACK;
