-- Token-bound SQL access and temporal node-domain membership.

SET search_path = rye, public, pg_catalog;

BEGIN;

DO $$
DECLARE
    v_domain_a uuid;
    v_domain_b uuid;
    v_node_a uuid;
    v_node_mixed uuid;
    v_event uuid;
    v_membership uuid;
    v_agent uuid;
    v_token text;
    v_search jsonb;
    v_summary jsonb;
    v_candidate uuid;
    v_observation uuid;
    v_unknown_candidate uuid;
    v_overlap_denied boolean := false;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:agent-runtime-boundary', true);

    v_domain_a := ensure_knowledge_domain(
        'runtime-domain-a',
        'Runtime Domain A',
        'Primary runtime security domain.'
    );
    v_domain_b := ensure_knowledge_domain(
        'runtime-domain-b',
        'Runtime Domain B',
        'Foreign runtime security domain.'
    );

    INSERT INTO field_classifications (node_type, field_path, classification, min_role)
    VALUES ('runtime_account', 'properties.secret_note', 'confidential', 'manager')
    ON CONFLICT (node_type, field_path)
    DO UPDATE SET classification = EXCLUDED.classification, min_role = EXCLUDED.min_role;

    INSERT INTO nodes (node_type, label, properties)
    VALUES (
        'runtime_account',
        'Visible Runtime Account',
        '{"public_note":"visible","secret_note":"must be redacted"}'::jsonb
    )
    RETURNING id INTO v_node_a;

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('runtime_account', 'Mixed Runtime Account', '{"public_note":"mixed"}'::jsonb)
    RETURNING id INTO v_node_mixed;

    v_event := record_event(
        p_event_type        := 'runtime_membership_confirmed',
        p_summary           := 'Runtime test memberships confirmed',
        p_properties        := '{"suite":"agent_runtime_boundary"}'::jsonb,
        p_participant_ids   := ARRAY[v_node_a, v_node_mixed],
        p_participant_roles := ARRAY['subject', 'subject'],
        p_actor             := 'test:agent-runtime-boundary'
    );

    v_membership := assign_node_domain_membership(
        v_node_a,
        'runtime-domain-a',
        v_event
    );
    PERFORM assign_node_domain_membership(v_node_mixed, 'runtime-domain-a', v_event);
    PERFORM assign_node_domain_membership(v_node_mixed, 'runtime-domain-b', v_event);

    BEGIN
        PERFORM assign_node_domain_membership(
            v_node_a,
            'runtime-domain-a',
            v_event,
            NULL,
            now() - interval '1 minute'
        );
    EXCEPTION WHEN exclusion_violation OR unique_violation THEN
        v_overlap_denied := true;
    END;

    IF NOT v_overlap_denied THEN
        RAISE EXCEPTION 'Overlapping node-domain membership was not rejected';
    END IF;

    PERFORM record_assertion(
        p_assertion_type  := 'runtime_status',
        p_assertion_key   := 'default',
        p_subject_node_id := v_node_a,
        p_claim           := '{"status":"active"}'::jsonb,
        p_source_event_id := v_event,
        p_confidence      := 0.95
    );
    PERFORM record_assertion(
        p_assertion_type  := 'financial_terms',
        p_assertion_key   := 'default',
        p_subject_node_id := v_node_a,
        p_claim           := '{"amount":1000000}'::jsonb,
        p_source_event_id := v_event,
        p_confidence      := 0.95
    );

    v_agent := create_agent_identity(
        'runtime-boundary-agent',
        'Runtime Boundary Agent',
        'conformance'
    );
    PERFORM grant_agent_capability('runtime-boundary-agent', 'rye.context.read', 'runtime-domain-a');
    PERFORM grant_agent_capability('runtime-boundary-agent', 'rye.candidate.create', 'runtime-domain-a');
    PERFORM grant_agent_capability('runtime-boundary-agent', 'rye.observation.create', 'runtime-domain-a');
    v_token := issue_agent_token('runtime-boundary-agent', 'runtime boundary token');

    IF agent_can_read_node(v_agent, v_node_a, now(), NULL) IS NOT TRUE THEN
        RAISE EXCEPTION 'Agent should read node with complete domain coverage';
    END IF;
    IF agent_can_read_node(v_agent, v_node_mixed, now(), NULL) THEN
        RAISE EXCEPTION 'Agent should not read a node with an ungranted second domain';
    END IF;

    v_search := agent_search_nodes_with_token(
        v_token,
        'Runtime Account',
        ARRAY['runtime-domain-a'],
        NULL,
        20
    );
    IF v_search::text NOT LIKE '%Visible Runtime Account%'
       OR v_search::text LIKE '%Mixed Runtime Account%'
       OR v_search::text LIKE '%must be redacted%'
    THEN
        RAISE EXCEPTION 'Scoped token search returned wrong or unredacted nodes: %', v_search;
    END IF;

    v_summary := agent_node_summary_with_token(v_token, v_node_a, NULL, 10);
    IF v_summary::text NOT LIKE '%runtime_status%'
       OR v_summary::text LIKE '%financial_terms%'
       OR v_summary::text LIKE '%must be redacted%'
    THEN
        RAISE EXCEPTION 'Scoped token summary mixed restricted or redacted knowledge: %', v_summary;
    END IF;

    v_candidate := agent_create_candidate_with_token(
        v_token,
        '{
          "candidate_kind":"fact",
          "statement":"Runtime candidate belongs to domain A.",
          "domain_keys":["runtime-domain-a"],
          "source_scope":"runtime:test",
          "evidence_refs":[{"source":"test","id":"candidate-1"}],
          "confidence":0.8
        }'::jsonb,
        'runtime-candidate-1'
    );
    v_observation := agent_submit_observation_with_token(
        v_token,
        '{
          "statement":"Runtime observation belongs to domain A.",
          "domain_keys":["runtime-domain-a"],
          "source_scope":"runtime:test",
          "evidence_refs":[{"source":"test","id":"observation-1"}]
        }'::jsonb
    );

    IF NOT EXISTS (
        SELECT 1
        FROM node_domain_memberships membership
        WHERE membership.node_id IN (v_candidate, v_observation)
          AND membership.domain_id = v_domain_a
          AND membership.source_event_id IS NOT NULL
        GROUP BY membership.domain_id
        HAVING count(DISTINCT membership.node_id) = 2
    ) THEN
        RAISE EXCEPTION 'Candidate and observation writes did not create sourced domain memberships';
    END IF;

    v_unknown_candidate := create_knowledge_candidate(
        p_candidate_kind := 'fact',
        p_statement := 'Unknown runtime domain candidate.',
        p_target_payload := '{"domain_keys":["runtime-domain-missing"]}'::jsonb,
        p_created_by := 'test:agent-runtime-boundary'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM node_domain_membership_gaps gap
        WHERE gap.node_id = v_unknown_candidate
          AND gap.gap_type = 'unknown_candidate_domain'
    ) THEN
        RAISE EXCEPTION 'Unknown candidate domain was not surfaced as a queryable gap';
    END IF;

    IF NOT end_node_domain_membership(v_membership, now() + interval '1 second') THEN
        RAISE EXCEPTION 'Expected active membership to close through helper';
    END IF;
END;
$$;

ROLLBACK;
