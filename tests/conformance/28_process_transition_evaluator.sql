-- Governed process transition evaluation, enforcement, and compliance diagnostics.

SET search_path = rye, public, pg_catalog;

BEGIN;

DO $$
DECLARE
    v_domain uuid;
    v_process uuid;
    v_deal uuid;
    v_jordan uuid;
    v_maya uuid;
    v_salesperson_role uuid;
    v_manager_role uuid;
    v_reviewer_agent uuid;
    v_reviewer_token text;
    v_seed_event uuid;
    v_process_definition uuid;
    v_policy uuid;
    v_replacement_policy uuid;
    v_review_candidate uuid;
    v_missing_evidence_candidate uuid;
    v_allow_candidate uuid;
    v_stale_candidate uuid;
    v_review_result jsonb;
    v_missing_result jsonb;
    v_allow_result jsonb;
    v_replay_result jsonb;
    v_deny_result jsonb;
    v_raw_bypass_denied boolean := false;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:process-transition-evaluator', true);

    v_domain := ensure_knowledge_domain(
        'process-sales',
        'Process Sales',
        'Governed sales transition test domain.'
    );

    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('pipeline', 'Standard Sales', 'conformance', 'standard-sales')
    RETURNING id INTO v_process;

    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('opportunity', 'Aurora', 'conformance', 'aurora-process-test')
    RETURNING id INTO v_deal;

    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('person', 'Jordan', 'slack', 'jordan')
    RETURNING id INTO v_jordan;

    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('person', 'Maya', 'slack', 'maya')
    RETURNING id INTO v_maya;

    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('role', 'Salesperson', 'org', 'salesperson')
    RETURNING id INTO v_salesperson_role;

    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('role', 'Sales Manager', 'org', 'sales_manager')
    RETURNING id INTO v_manager_role;

    INSERT INTO edges (edge_type, source_id, target_id, effective_from)
    VALUES
      ('holds_role', v_jordan, v_salesperson_role, now() - interval '1 year'),
      ('holds_role', v_maya, v_manager_role, now() - interval '1 year');

    PERFORM grant_domain_authority(
        'process-sales',
        'role',
        'role:salesperson',
        ARRAY['deal_stage'],
        NULL,
        ARRAY['proposed']
    );
    PERFORM grant_domain_authority(
        'process-sales',
        'role',
        'role:sales_manager',
        ARRAY['deal_stage'],
        NULL,
        ARRAY['decided']
    );

    v_reviewer_agent := create_agent_identity(
        'process-reviewer-agent',
        'Process Reviewer Agent',
        'conformance'
    );
    PERFORM grant_agent_capability('process-reviewer-agent', 'rye.context.read', 'process-sales');
    PERFORM grant_agent_capability('process-reviewer-agent', 'rye.review.read', 'process-sales');
    PERFORM grant_agent_capability('process-reviewer-agent', 'rye.candidate.adjudicate', 'process-sales');
    PERFORM grant_agent_capability('process-reviewer-agent', 'rye.authoritative.promote', 'process-sales');
    v_reviewer_token := issue_agent_token('process-reviewer-agent', 'process evaluator conformance');

    v_seed_event := record_event(
        p_event_type        := 'process_policy_seeded',
        p_summary           := 'Governed sales process and current deal state seeded',
        p_participant_ids   := ARRAY[v_process, v_deal],
        p_participant_roles := ARRAY['process', 'subject'],
        p_actor             := 'test:process-transition-evaluator'
    );

    v_process_definition := record_assertion(
        p_assertion_type  := 'process_definition',
        p_assertion_key   := 'default',
        p_subject_node_id := v_process,
        p_claim           := '{
          "schema_type":"rye.process_definition.claim.v1",
          "schema_version":1,
          "process_key":"standard-sales",
          "state_assertion_type":"deal_stage",
          "states":["discovery","proposal","negotiation","closed_lost"],
          "initial_state":"discovery",
          "terminal_states":["closed_lost"]
        }'::jsonb,
        p_source_event_id := v_seed_event
    );

    v_policy := record_assertion(
        p_assertion_type  := 'process_transition_policy',
        p_assertion_key   := 'transition:proposal-to-closed-lost',
        p_subject_node_id := v_process,
        p_claim           := '{
          "schema_type":"rye.process_transition_policy.claim.v1",
          "schema_version":1,
          "process_key":"standard-sales",
          "transition_key":"proposal-to-closed-lost",
          "from_states":["proposal","negotiation"],
          "to_state":"closed_lost",
          "authority":{
            "may_propose":["role:salesperson"],
            "may_decide":["role:sales_manager"],
            "may_approve_exception":["role:sales_manager"],
            "may_reopen":["role:sales_manager"]
          },
          "required_evidence":["loss_reason"],
          "required_prior_steps":[],
          "exception_policy":"review",
          "impact":"high",
          "reversible":true
        }'::jsonb,
        p_source_event_id := v_seed_event
    );

    PERFORM record_assertion(
        p_assertion_type  := 'deal_stage',
        p_assertion_key   := 'default',
        p_subject_node_id := v_deal,
        p_claim           := '{"state":"proposal"}'::jsonb,
        p_source_event_id := v_seed_event
    );

    v_review_candidate := create_knowledge_candidate(
        p_candidate_kind := 'fact',
        p_statement := 'Jordan reports that Aurora is dead.',
        p_target_payload := jsonb_build_object(
            'domain_keys', jsonb_build_array('process-sales'),
            'process_node_id', v_process,
            'subject_node_id', v_deal,
            'process_key', 'standard-sales',
            'transition_key', 'proposal-to-closed-lost',
            'from_state', 'proposal',
            'to_state', 'closed_lost',
            'speech_act', 'proposed',
            'evidence', jsonb_build_object('loss_reason', 'No response')
        ),
        p_created_by := 'slack:jordan',
        p_confidence := 0.8
    );

    v_review_result := evaluate_process_transition(
        v_review_candidate,
        'slack:jordan',
        v_jordan,
        now(),
        true
    );

    IF v_review_result->>'decision' <> 'review'
       OR NOT (v_review_result->'reason_codes' ? 'decision_speech_act_required')
       OR NOT (v_review_result->'reason_codes' ? 'missing_decision_authority')
    THEN
        RAISE EXCEPTION 'Proposer should require review, got %', v_review_result;
    END IF;

    v_missing_evidence_candidate := create_knowledge_candidate(
        p_candidate_kind := 'fact',
        p_statement := 'Maya decides that Aurora is closed lost without a loss reason.',
        p_target_payload := jsonb_build_object(
            'domain_keys', jsonb_build_array('process-sales'),
            'process_node_id', v_process,
            'subject_node_id', v_deal,
            'process_key', 'standard-sales',
            'transition_key', 'proposal-to-closed-lost',
            'from_state', 'proposal',
            'to_state', 'closed_lost',
            'speech_act', 'decided'
        ),
        p_created_by := 'slack:maya',
        p_confidence := 0.9
    );

    v_missing_result := agent_evaluate_process_transition_with_token(
        v_reviewer_token,
        v_missing_evidence_candidate,
        'slack:maya',
        v_maya,
        now(),
        false
    );

    IF v_missing_result->>'decision' <> 'review'
       OR NOT (v_missing_result->'missing_evidence' ? 'loss_reason')
    THEN
        RAISE EXCEPTION 'Missing evidence should be reviewable, got %', v_missing_result;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM process_transition_compliance finding
        WHERE finding.decision_id = (v_missing_result->>'decision_id')::uuid
          AND finding.compliance_class = 'missing_evidence'
    ) THEN
        RAISE EXCEPTION 'Missing evidence was not distinguished from noncompliance';
    END IF;

    v_allow_candidate := create_knowledge_candidate(
        p_candidate_kind := 'fact',
        p_statement := 'Maya decides that Aurora is closed lost with a confirmed loss reason.',
        p_target_payload := jsonb_build_object(
            'domain_keys', jsonb_build_array('process-sales'),
            'process_node_id', v_process,
            'subject_node_id', v_deal,
            'process_key', 'standard-sales',
            'transition_key', 'proposal-to-closed-lost',
            'from_state', 'proposal',
            'to_state', 'closed_lost',
            'state_field', 'state',
            'speech_act', 'decided',
            'evidence', jsonb_build_object('loss_reason', 'Budget withdrawn'),
            'claim', jsonb_build_object('state', 'closed_lost', 'loss_reason', 'Budget withdrawn')
        ),
        p_created_by := 'slack:maya',
        p_confidence := 0.95
    );

    BEGIN
        PERFORM promote_candidate_to_assertion(
            v_allow_candidate,
            v_deal,
            'deal_stage',
            'default',
            '{"state":"closed_lost"}'::jsonb,
            NULL,
            NULL,
            0.95,
            'test:bypass'
        );
    EXCEPTION WHEN insufficient_privilege THEN
        v_raw_bypass_denied := true;
    END;

    IF NOT v_raw_bypass_denied THEN
        RAISE EXCEPTION 'Generic promotion bypassed governed process evaluation';
    END IF;

    v_allow_result := agent_evaluate_process_transition_with_token(
        v_reviewer_token,
        v_allow_candidate,
        'slack:maya',
        v_maya,
        now(),
        true
    );

    IF v_allow_result->>'decision' <> 'allow'
       OR (v_allow_result->>'applied')::boolean IS NOT TRUE
       OR v_allow_result->>'transition_policy_assertion_id' <> v_policy::text
    THEN
        RAISE EXCEPTION 'Authorized evidenced transition should apply, got %', v_allow_result;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM current_valid_assertions assertion_row
        WHERE assertion_row.subject_node_id = v_deal
          AND assertion_row.assertion_type = 'deal_stage'
          AND assertion_row.assertion_key = 'default'
          AND assertion_row.claim->>'state' = 'closed_lost'
          AND assertion_row.attrs->>'process_transition_decision_id' = v_allow_result->>'decision_id'
    ) THEN
        RAISE EXCEPTION 'Allowed transition did not create the accepted state with decision lineage';
    END IF;

    v_replay_result := evaluate_process_transition(
        v_allow_candidate,
        'slack:maya',
        v_maya,
        now(),
        true
    );
    IF v_replay_result->>'decision_id' <> v_allow_result->>'decision_id'
       OR (v_replay_result->>'idempotent_replay')::boolean IS NOT TRUE
    THEN
        RAISE EXCEPTION 'Applied decision was not idempotent: %', v_replay_result;
    END IF;

    v_stale_candidate := create_knowledge_candidate(
        p_candidate_kind := 'fact',
        p_statement := 'A stale proposal attempts another close from proposal.',
        p_target_payload := jsonb_build_object(
            'domain_keys', jsonb_build_array('process-sales'),
            'process_node_id', v_process,
            'subject_node_id', v_deal,
            'process_key', 'standard-sales',
            'transition_key', 'proposal-to-closed-lost',
            'from_state', 'proposal',
            'to_state', 'closed_lost',
            'speech_act', 'decided',
            'evidence', jsonb_build_object('loss_reason', 'Duplicate close')
        ),
        p_created_by := 'slack:maya'
    );

    v_deny_result := evaluate_process_transition(
        v_stale_candidate,
        'slack:maya',
        v_maya,
        now(),
        false
    );
    IF v_deny_result->>'decision' <> 'deny'
       OR NOT (v_deny_result->'reason_codes' ? 'current_state_mismatch')
    THEN
        RAISE EXCEPTION 'Stale from-state should be denied, got %', v_deny_result;
    END IF;

    v_replacement_policy := supersede_assertion(
        p_old_assertion_id := v_policy,
        p_new_assertion_type := 'process_transition_policy',
        p_new_subject_node_id := v_process,
        p_new_subject_edge_id := NULL,
        p_new_claim := '{
          "schema_type":"rye.process_transition_policy.claim.v1",
          "schema_version":1,
          "process_key":"standard-sales",
          "transition_key":"proposal-to-closed-lost",
          "from_states":["proposal","negotiation"],
          "to_state":"closed_lost",
          "authority":{
            "may_propose":["role:salesperson"],
            "may_decide":["role:sales_manager"],
            "may_approve_exception":["role:sales_manager"],
            "may_reopen":["role:sales_manager"]
          },
          "required_evidence":["loss_reason","competitor"],
          "required_prior_steps":[],
          "exception_policy":"review",
          "impact":"high",
          "reversible":true
        }'::jsonb,
        p_new_assertion_key := 'transition:proposal-to-closed-lost',
        p_new_source_event_id := v_seed_event,
        p_new_confidence := 1.0
    );

    IF v_replacement_policy IS NULL OR NOT EXISTS (
        SELECT 1
        FROM process_transition_decisions decision_row
        WHERE decision_row.id = (v_allow_result->>'decision_id')::uuid
          AND decision_row.transition_policy_assertion_id = v_policy
          AND decision_row.policy_snapshot->>'transition_policy_assertion_id' = v_policy::text
    ) THEN
        RAISE EXCEPTION 'Decision did not retain the policy version effective at evaluation time';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM process_transition_gaps gap
        WHERE gap.candidate_id = v_missing_evidence_candidate
          AND gap.gap_type = 'reviewable_process_transition'
    ) THEN
        RAISE EXCEPTION 'Reviewable transition was not exposed as a queryable gap';
    END IF;
END;
$$;

ROLLBACK;
