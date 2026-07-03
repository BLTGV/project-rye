-- Agent-guided onboarding should persist changing business knowledge, not just
-- logs. This test constructs three realistic neutral scenarios and verifies
-- source-of-truth policy, process-improvement cycles, convention registration,
-- and candidate gates.

SET search_path = rye, public, pg_catalog;

BEGIN;

DO $$
DECLARE
    v_candidate_count int;
    v_convention_count int;
    v_improvement_count int;
    v_plugin_binding_count int;
    v_referral_scope uuid;
    v_referral_source uuid;
    v_scope_count int;
    v_truth_policy_count int;
    v_manufacturing_scope uuid;
    v_manufacturing_source uuid;
    v_permit_scope uuid;
    v_permit_source uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:onboarding-scenarios', true);
    PERFORM set_config('app.current_teams', 'system', true);

    -- Scenario 1: healthcare operations, referral intake quality.
    v_referral_scope := create_onboarding_scope(
        p_scope_key := 'conformance:scenario:referral-intake-quality',
        p_label     := 'Referral Intake Quality',
        p_purpose   := 'Reduce referral rework and preserve changing source-of-truth and process-constraint knowledge.',
        p_boundary  := jsonb_build_object(
            'in_scope', jsonb_build_array('referral intake quality', 'source-of-truth policy', 'process constraints'),
            'out_of_scope', jsonb_build_array('billing', 'clinical treatment', 'patient medical facts')
        ),
        p_owner     := 'fictional:operations-lead'
    );
    PERFORM record_scope_policy(v_referral_scope, 'expected_contexts', '{"contexts": ["Referral Intake Quality"]}', 'default', 'test:onboarding-scenarios');
    PERFORM record_scope_policy(v_referral_scope, 'retention_policy', '{"preserve": ["owner sitreps", "process constraints", "evidence anchors"], "collapse": ["routine API success logs", "Slack acknowledgements"]}', 'default', 'test:onboarding-scenarios');
    PERFORM record_scope_policy(v_referral_scope, 'accepted_knowledge_policy', '{"accepted_after_review": ["source-of-truth policy", "process metrics"], "candidate_only": ["patient/referral-specific status"]}', 'default', 'test:onboarding-scenarios');
    PERFORM record_source_of_truth_policy(v_referral_scope, 'eligibility_check_status', 'VerifyNow API', '2026-06-10'::timestamptz, 'owner review required before authority', ARRAY['owner sitrep', 'reviewed API observation'], 'temporary spreadsheet', 'VerifyNow replaced spreadsheet status after go-live.', 'test:onboarding-scenarios');
    PERFORM record_source_of_truth_policy(v_referral_scope, 'referral_workflow_status', 'RefDesk DB', NULL, 'workflow status must be checked in RefDesk DB', ARRAY['RefDesk DB row', 'owner source-of-truth statement'], NULL, 'VerifyNow is not workflow status authority.', 'test:onboarding-scenarios');
    PERFORM record_improvement_cycle(
        v_referral_scope,
        'Clean referrals ready for scheduling within two business days.',
        'Prior authorization packet review capacity',
        ARRAY['Create a standard packet checklist', 'Route incomplete packets back before review'],
        ARRAY['Intake coordinators prepare packets to checklist before requesting review'],
        ARRAY['Cross-train two coordinators if backlog remains above 10 packets for three days'],
        'Inspect provider clarification loops once packet review drops below 4 average hours.',
        jsonb_build_array(
            jsonb_build_object('metric', 'eligibility_delay_avg_hours', 'before', 8, 'after', 1),
            jsonb_build_object('metric', 'packet_review_avg_hours', 'current', 14)
        ),
        'Provider clarification loops',
        'test:onboarding-scenarios'
    );
    PERFORM register_scope_convention(v_referral_scope, 'process_constraint', 'Current limiting factor in a business process.', ARRAY['constraint', 'bottleneck'], 'Use for reviewed process bottlenecks with metrics.', 'Do not use for raw log lines.', 'accepted', 'rye-org', 'test:onboarding-scenarios');
    PERFORM register_scope_convention(v_referral_scope, 'source_of_truth_policy', 'Reviewed authority for a status domain.', ARRAY['system of record', 'truth policy'], 'Use after owner/source review.', 'Do not infer from connector names.', 'accepted', 'rye-source-context', 'test:onboarding-scenarios');
    PERFORM register_scope_convention(v_referral_scope, 'improvement_cycle', 'Identify/Exploit/Subordinate/Elevate/Repeat process loop.', ARRAY['BPI cycle'], 'Use for reviewed process improvement loops.', 'Do not use for generic meeting notes.', 'proposed', 'rye-org', 'test:onboarding-scenarios');
    PERFORM enable_plugin_for_scope(v_referral_scope, 'rye-source-context', 'Source Context', '{}', 'test:onboarding-scenarios');
    PERFORM enable_plugin_for_scope(v_referral_scope, 'rye-org', 'Organization Model', '{}', 'test:onboarding-scenarios');
    PERFORM activate_onboarding_scope(v_referral_scope, 'test:onboarding-scenarios');
    INSERT INTO nodes (node_type, label, properties)
    VALUES (
        'source_item',
        'Referral scenario owner sitrep and API excerpt',
        '{"source_kind": "declared_knowledge_plus_log_excerpt", "retrieval_channel": "direct_agent_interview_and_application_log_replay", "source_value": "evidence", "body_summary": "VerifyNow owns eligibility status after 2026-06-10; packet review is current constraint."}'
    )
    RETURNING id INTO v_referral_source;
    PERFORM create_knowledge_candidate(
        'fact',
        'Referral TEST-102 eligibility is verified according to one log excerpt; keep candidate until human review.',
        '{"status_domain": "eligibility_check_status", "domain_fact_kind": "referral_status"}',
        ARRAY[v_referral_scope],
        'scenario-referral:TEST-102',
        'test:onboarding-scenarios',
        ARRAY[v_referral_source],
        '{}',
        0.70
    );

    -- Scenario 2: manufacturing quote-to-production handoff.
    v_manufacturing_scope := create_onboarding_scope(
        p_scope_key := 'conformance:scenario:quote-handoff-quality',
        p_label     := 'Quote Handoff Quality',
        p_purpose   := 'Preserve changing knowledge about custom manufacturing quote readiness and production handoff quality.',
        p_boundary  := jsonb_build_object(
            'in_scope', jsonb_build_array('quote readiness', 'engineering review constraints', 'handoff source-of-truth'),
            'out_of_scope', jsonb_build_array('payroll', 'vendor contract negotiation', 'customer-specific pricing facts without review')
        ),
        p_owner     := 'fictional:plant-manager'
    );
    PERFORM record_scope_policy(v_manufacturing_scope, 'expected_contexts', '{"contexts": ["Quote Handoff Quality"]}', 'default', 'test:onboarding-scenarios');
    PERFORM record_scope_policy(v_manufacturing_scope, 'retention_policy', '{"preserve": ["owner review", "ERP export summary", "quality defect summaries"], "collapse": ["machine heartbeat logs", "routine chat acknowledgements"]}', 'default', 'test:onboarding-scenarios');
    PERFORM record_scope_policy(v_manufacturing_scope, 'accepted_knowledge_policy', '{"accepted_after_review": ["source-of-truth policy", "defect trend metrics", "constraint changes"], "candidate_only": ["customer/order-specific commitments"]}', 'default', 'test:onboarding-scenarios');
    PERFORM record_source_of_truth_policy(v_manufacturing_scope, 'quote_status', 'QuoteFlow ERP', '2026-07-01'::timestamptz, 'plant manager review required', ARRAY['ERP export', 'owner sitrep'], 'shared quote spreadsheet', 'ERP became quote-status authority after the July cutover.', 'test:onboarding-scenarios');
    PERFORM record_source_of_truth_policy(v_manufacturing_scope, 'production_routing_status', 'CAMBoard', NULL, 'production routing checked in CAMBoard', ARRAY['CAMBoard route', 'reviewed production handoff'], NULL, 'QuoteFlow does not own routing readiness.', 'test:onboarding-scenarios');
    PERFORM record_improvement_cycle(
        v_manufacturing_scope,
        'Accepted custom quotes should enter production with complete manufacturability review and fixture plan.',
        'Engineering manufacturability review backlog',
        ARRAY['Create fixture-risk checklist', 'Reserve daily review block for high-risk quotes'],
        ARRAY['Sales waits for review before promising production dates'],
        ARRAY['Add a second programmer reviewer if backlog exceeds 15 quotes for two days'],
        'Inspect fixture procurement delay once engineering review averages below 6 hours.',
        jsonb_build_array(
            jsonb_build_object('metric', 'review_backlog_count', 'current', 18),
            jsonb_build_object('metric', 'defect_rework_rate_percent', 'current', 11)
        ),
        'Fixture procurement delay',
        'test:onboarding-scenarios'
    );
    PERFORM register_scope_convention(v_manufacturing_scope, 'process_constraint', 'Current limiting factor in quote handoff.', ARRAY['constraint', 'backlog'], 'Use for reviewed quote-to-production bottlenecks.', 'Do not use for one-off rush orders.', 'accepted', 'rye-org', 'test:onboarding-scenarios');
    PERFORM register_scope_convention(v_manufacturing_scope, 'source_of_truth_policy', 'Status authority by quote/handoff domain.', ARRAY['system of record'], 'Use after cutover review.', 'Do not infer from spreadsheet names.', 'accepted', 'rye-source-context', 'test:onboarding-scenarios');
    PERFORM register_scope_convention(v_manufacturing_scope, 'improvement_cycle', 'BPI cycle for quote handoff.', ARRAY['constraint loop'], 'Use for reviewed handoff improvements.', 'Do not use for raw quality logs alone.', 'proposed', 'rye-org', 'test:onboarding-scenarios');
    PERFORM enable_plugin_for_scope(v_manufacturing_scope, 'rye-source-context', 'Source Context', '{}', 'test:onboarding-scenarios');
    PERFORM enable_plugin_for_scope(v_manufacturing_scope, 'rye-org', 'Organization Model', '{}', 'test:onboarding-scenarios');
    PERFORM activate_onboarding_scope(v_manufacturing_scope, 'test:onboarding-scenarios');
    INSERT INTO nodes (node_type, label, properties)
    VALUES (
        'source_item',
        'Manufacturing quote handoff review packet',
        '{"source_kind": "owner_review_plus_erp_export", "retrieval_channel": "direct_agent_interview_and_filesystem_csv_export", "source_value": "evidence", "body_summary": "QuoteFlow owns quote status; manufacturability review backlog is current constraint."}'
    )
    RETURNING id INTO v_manufacturing_source;
    PERFORM create_knowledge_candidate(
        'fact',
        'Order TEST-Q771 is ready for production according to the ERP export; keep candidate until order-level review.',
        '{"status_domain": "quote_status", "domain_fact_kind": "order_status"}',
        ARRAY[v_manufacturing_scope],
        'scenario-manufacturing:TEST-Q771',
        'test:onboarding-scenarios',
        ARRAY[v_manufacturing_source],
        '{}',
        0.68
    );

    -- Scenario 3: municipal permit review cycle.
    v_permit_scope := create_onboarding_scope(
        p_scope_key := 'conformance:scenario:permit-review-cycle',
        p_label     := 'Permit Review Cycle',
        p_purpose   := 'Preserve changing knowledge about permit review throughput, source authority, and review constraints.',
        p_boundary  := jsonb_build_object(
            'in_scope', jsonb_build_array('permit review status policy', 'zoning evidence', 'review bottlenecks'),
            'out_of_scope', jsonb_build_array('legal advice', 'resident identity details', 'fee collection')
        ),
        p_owner     := 'fictional:permit-office-lead'
    );
    PERFORM record_scope_policy(v_permit_scope, 'expected_contexts', '{"contexts": ["Permit Review Cycle"]}', 'default', 'test:onboarding-scenarios');
    PERFORM record_scope_policy(v_permit_scope, 'retention_policy', '{"preserve": ["official review decisions", "GIS evidence anchors", "mailing batch summaries"], "collapse": ["routine email acknowledgements", "scanner OCR chatter"]}', 'default', 'test:onboarding-scenarios');
    PERFORM record_scope_policy(v_permit_scope, 'accepted_knowledge_policy', '{"accepted_after_review": ["source-of-truth policy", "queue metrics", "constraint changes"], "candidate_only": ["permit-specific approval status", "resident identity facts"]}', 'default', 'test:onboarding-scenarios');
    PERFORM record_source_of_truth_policy(v_permit_scope, 'permit_review_status', 'PermitCore DB', NULL, 'permit office lead review required', ARRAY['PermitCore row', 'review board minutes'], NULL, 'Email attachments are evidence, not final status authority.', 'test:onboarding-scenarios');
    PERFORM record_source_of_truth_policy(v_permit_scope, 'zoning_map_classification', 'CivicGIS layer', '2026-05-15'::timestamptz, 'GIS layer version must be cited', ARRAY['GIS layer id', 'parcel map anchor'], 'PDF map screenshots', 'GIS layer superseded screenshots for zoning classification.', 'test:onboarding-scenarios');
    PERFORM record_improvement_cycle(
        v_permit_scope,
        'Complete standard permit review within ten business days while preserving audit evidence.',
        'Neighbor notice mailing queue',
        ARRAY['Batch notices twice daily', 'Reject incomplete notice packets before clerk review'],
        ARRAY['Zoning reviewers attach GIS anchors before notices are queued'],
        ARRAY['Add temp clerk capacity if notice queue exceeds 40 permits for two days'],
        'Inspect board-hearing scheduling once notice queue falls below 8 business hours.',
        jsonb_build_array(
            jsonb_build_object('metric', 'zoning_check_avg_days', 'before', 5, 'after', 1),
            jsonb_build_object('metric', 'notice_queue_count', 'current', 46)
        ),
        'Board-hearing scheduling',
        'test:onboarding-scenarios'
    );
    PERFORM register_scope_convention(v_permit_scope, 'process_constraint', 'Current limiting factor in permit review.', ARRAY['constraint', 'queue'], 'Use for reviewed permit-review bottlenecks.', 'Do not use for one resident complaint.', 'accepted', 'rye-org', 'test:onboarding-scenarios');
    PERFORM register_scope_convention(v_permit_scope, 'source_of_truth_policy', 'Authority by permit status or evidence domain.', ARRAY['authoritative source'], 'Use when source authority is reviewed.', 'Do not infer from email subject lines.', 'accepted', 'rye-source-context', 'test:onboarding-scenarios');
    PERFORM register_scope_convention(v_permit_scope, 'improvement_cycle', 'Constraint-based permit-review improvement.', ARRAY['BPI loop'], 'Use for reviewed queue improvement plans.', 'Do not use for raw scan/OCR logs.', 'proposed', 'rye-org', 'test:onboarding-scenarios');
    PERFORM enable_plugin_for_scope(v_permit_scope, 'rye-source-context', 'Source Context', '{}', 'test:onboarding-scenarios');
    PERFORM enable_plugin_for_scope(v_permit_scope, 'rye-org', 'Organization Model', '{}', 'test:onboarding-scenarios');
    PERFORM activate_onboarding_scope(v_permit_scope, 'test:onboarding-scenarios');
    INSERT INTO nodes (node_type, label, properties)
    VALUES (
        'source_item',
        'Permit review policy and GIS evidence packet',
        '{"source_kind": "policy_review_plus_gis_export", "retrieval_channel": "direct_agent_interview_and_file_export", "source_value": "evidence", "body_summary": "PermitCore owns permit status; CivicGIS owns zoning map classification; notice mailing is current constraint."}'
    )
    RETURNING id INTO v_permit_source;
    PERFORM create_knowledge_candidate(
        'fact',
        'Permit TEST-P445 is approved according to one email attachment; keep candidate until PermitCore review.',
        '{"status_domain": "permit_review_status", "domain_fact_kind": "permit_status"}',
        ARRAY[v_permit_scope],
        'scenario-permit:TEST-P445',
        'test:onboarding-scenarios',
        ARRAY[v_permit_source],
        '{}',
        0.62
    );

    SELECT count(*)
    INTO v_scope_count
    FROM nodes n
    JOIN current_valid_assertions status
      ON status.subject_node_id = n.id
     AND status.assertion_type = 'scope_status'
     AND status.claim->>'status' = 'active'
    WHERE n.node_type = 'onboarding_scope'
      AND n.external_id LIKE 'conformance:scenario:%';

    IF v_scope_count <> 3 THEN
        RAISE EXCEPTION 'Expected 3 active scenario scopes, got %', v_scope_count;
    END IF;

    SELECT count(*)
    INTO v_truth_policy_count
    FROM nodes n
    JOIN assertions a ON a.subject_node_id = n.id
    WHERE n.node_type = 'onboarding_scope'
      AND n.external_id LIKE 'conformance:scenario:%'
      AND a.assertion_type = 'source_of_truth_policy'
      AND a.superseded_at IS NULL;

    IF v_truth_policy_count <> 6 THEN
        RAISE EXCEPTION 'Expected 6 source_of_truth_policy assertions, got %', v_truth_policy_count;
    END IF;

    SELECT count(*)
    INTO v_improvement_count
    FROM nodes n
    JOIN current_valid_assertions a ON a.subject_node_id = n.id
    WHERE n.node_type = 'onboarding_scope'
      AND n.external_id LIKE 'conformance:scenario:%'
      AND a.assertion_type = 'improvement_cycle'
      AND a.claim ? 'Identify'
      AND a.claim ? 'Exploit'
      AND a.claim ? 'Subordinate'
      AND a.claim ? 'Elevate'
      AND a.claim ? 'Repeat'
      AND jsonb_array_length(a.claim->'metrics') >= 2;

    IF v_improvement_count <> 3 THEN
        RAISE EXCEPTION 'Expected 3 complete improvement_cycle assertions, got %', v_improvement_count;
    END IF;

    SELECT count(*)
    INTO v_convention_count
    FROM nodes n
    JOIN current_valid_assertions a ON a.subject_node_id = n.id
    WHERE n.node_type = 'onboarding_scope'
      AND n.external_id LIKE 'conformance:scenario:%'
      AND a.assertion_type = 'convention_registry'
      AND a.claim ? 'label'
      AND a.claim ? 'aliases'
      AND a.claim ? 'use_when'
      AND a.claim ? 'avoid_when'
      AND a.claim ? 'status';

    IF v_convention_count <> 9 THEN
        RAISE EXCEPTION 'Expected 9 registered conventions, got %', v_convention_count;
    END IF;

    SELECT count(*)
    INTO v_plugin_binding_count
    FROM nodes n
    JOIN current_valid_assertions a ON a.subject_node_id = n.id
    WHERE n.node_type = 'onboarding_scope'
      AND n.external_id LIKE 'conformance:scenario:%'
      AND a.assertion_type = 'plugin_policy_binding'
      AND a.assertion_key IN ('rye-source-context', 'rye-org');

    IF v_plugin_binding_count <> 6 THEN
        RAISE EXCEPTION 'Expected 6 source/org plugin bindings, got %', v_plugin_binding_count;
    END IF;

    SELECT count(*)
    INTO v_candidate_count
    FROM nodes n
    JOIN current_valid_assertions st
      ON st.subject_node_id = n.id
     AND st.assertion_type = 'candidate_status'
     AND st.claim->>'status' = 'proposed'
    WHERE n.node_type = 'knowledge_candidate'
      AND n.properties->>'created_by' = 'test:onboarding-scenarios'
      AND n.properties->>'candidate_kind' = 'fact'
      AND n.properties->'target_payload' ? 'domain_fact_kind';

    IF v_candidate_count <> 3 THEN
        RAISE EXCEPTION 'Expected 3 domain fact candidates, got %', v_candidate_count;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM current_valid_assertions
        WHERE assertion_type IN ('referral_status', 'order_status', 'permit_status')
    ) THEN
        RAISE EXCEPTION 'Domain status facts should remain candidates during setup';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(compile_scope_policy(v_referral_scope)->'assertions') a(assertion)
        WHERE assertion->>'assertion_type' = 'convention_registry'
          AND assertion->'claim'->>'label' = 'source_of_truth_policy'
    ) THEN
        RAISE EXCEPTION 'Compiled scope policy should include registered source_of_truth_policy convention';
    END IF;
END
$$;

ROLLBACK;
