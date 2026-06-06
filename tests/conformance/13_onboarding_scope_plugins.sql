-- Onboarding scopes, plugin metadata, expected contexts, and context gaps.

SET search_path = rye, public, pg_catalog;

BEGIN;

DO $$
DECLARE
    v_activation_failed boolean := false;
    v_activation_event uuid;
    v_candidate uuid;
    v_context_gap uuid;
    v_plugin_edge uuid;
    v_revision_event uuid;
    v_scope uuid;
    v_source_item uuid;
    v_validation jsonb;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:onboarding', true);

    v_scope := create_onboarding_scope(
        p_scope_key := 'conformance:onboarding-scope',
        p_label     := 'Conformance Onboarding Scope',
        p_purpose   := 'Validate onboarding scope and plugin conventions.',
        p_boundary  := '{"in_scope": ["conformance"], "out_of_scope": ["business_ops"]}',
        p_owner     := 'test:onboarding'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = v_scope
          AND node_type = 'onboarding_scope'
          AND external_source = 'rye_onboarding_scope'
          AND external_id = 'conformance:onboarding-scope'
    ) THEN
        RAISE EXCEPTION 'Expected create_onboarding_scope() to create onboarding_scope node';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM current_valid_assertions
        WHERE subject_node_id = v_scope
          AND assertion_type = 'scope_status'
          AND claim->>'status' = 'proposed'
    ) THEN
        RAISE EXCEPTION 'Expected onboarding scope to start as proposed';
    END IF;

    BEGIN
        PERFORM activate_onboarding_scope(v_scope, 'test:onboarding');
    EXCEPTION WHEN OTHERS THEN
        v_activation_failed := true;
    END;

    IF NOT v_activation_failed THEN
        RAISE EXCEPTION 'Expected activation to fail before retention/evidence policy and plugin binding';
    END IF;

    PERFORM record_scope_policy(
        p_scope_id     := v_scope,
        p_policy_type  := 'retention_policy',
        p_claim        := '{"default_retention_class": "review_window", "low_signal": "collapsed"}',
        p_actor        := 'test:onboarding'
    );

    PERFORM record_scope_policy(
        p_scope_id     := v_scope,
        p_policy_type  := 'expected_contexts',
        p_claim        := '{"contexts": ["conformance_context"]}',
        p_actor        := 'test:onboarding'
    );

    PERFORM record_scope_policy(
        p_scope_id     := v_scope,
        p_policy_type  := 'holding_context',
        p_claim        := '{"context_id": "needs_context", "label": "Needs Context"}',
        p_actor        := 'test:onboarding'
    );

    PERFORM record_scope_policy(
        p_scope_id     := v_scope,
        p_policy_type  := 'unexpected_context_policy',
        p_claim        := '{"action": "create_context_gap_candidate"}',
        p_actor        := 'test:onboarding'
    );

    PERFORM record_scope_policy(
        p_scope_id     := v_scope,
        p_policy_type  := 'blocked_contexts',
        p_claim        := '{"contexts": ["employment_relationship_from_channel_membership"]}',
        p_actor        := 'test:onboarding'
    );

    PERFORM record_scope_policy(
        p_scope_id     := v_scope,
        p_policy_type  := 'allowed_node_types',
        p_claim        := '{"types": ["source_item", "knowledge_candidate", "task", "review_context"]}',
        p_actor        := 'test:onboarding'
    );

    PERFORM record_scope_policy(
        p_scope_id     := v_scope,
        p_policy_type  := 'allowed_edge_types',
        p_claim        := '{"types": ["reviewed_under", "supported_by", "promoted_to", "scope_has_context_gap"]}',
        p_actor        := 'test:onboarding'
    );

    v_plugin_edge := enable_plugin_for_scope(
        p_scope_id  := v_scope,
        p_plugin_id := 'rye-org',
        p_label     := 'Organization Model',
        p_manifest  := '{"version": "0.1.0", "node_types": ["person", "system", "department"]}',
        p_actor     := 'test:onboarding'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM edges e
        JOIN nodes p ON p.id = e.target_id
        WHERE e.id = v_plugin_edge
          AND e.edge_type = 'scope_enables_plugin'
          AND e.source_id = v_scope
          AND p.node_type = 'plugin'
          AND p.external_id = 'rye-org'
    ) THEN
        RAISE EXCEPTION 'Expected enable_plugin_for_scope() to create scope_enables_plugin edge';
    END IF;

    v_activation_event := activate_onboarding_scope(v_scope, 'test:onboarding');

    IF NOT EXISTS (
        SELECT 1
        FROM events
        WHERE id = v_activation_event
          AND event_type = 'onboarding_completed'
    ) THEN
        RAISE EXCEPTION 'Expected activate_onboarding_scope() to record onboarding_completed event';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM current_valid_assertions
        WHERE subject_node_id = v_scope
          AND assertion_type = 'scope_status'
          AND claim->>'status' = 'active'
    ) THEN
        RAISE EXCEPTION 'Expected scope_status active after activation';
    END IF;

    v_validation := validate_candidate_against_scope(v_scope, 'node', 'task');

    IF coalesce((v_validation->>'valid')::boolean, false) IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Expected task node type to validate against scope, got %', v_validation;
    END IF;

    v_validation := validate_candidate_against_scope(v_scope, 'node', 'opportunity');

    IF coalesce((v_validation->>'valid')::boolean, false) IS DISTINCT FROM false
       OR v_validation->>'reason' <> 'type_not_enabled_for_scope'
    THEN
        RAISE EXCEPTION 'Expected opportunity node type to be blocked by scope, got %', v_validation;
    END IF;

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('source_item', 'Unexpected Slack thread', '{"source_value": "evidence"}')
    RETURNING id INTO v_source_item;

    v_context_gap := create_context_gap_candidate(
        p_scope_id       := v_scope,
        p_source_item_id := v_source_item,
        p_reason         := 'possible_new_context',
        p_statement      := 'Unexpected Slack thread may represent a new context.',
        p_actor          := 'test:onboarding'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = v_context_gap
          AND node_type = 'knowledge_candidate'
          AND properties->>'candidate_kind' = 'context_gap'
    ) THEN
        RAISE EXCEPTION 'Expected context gap candidate to be created';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM edges e
        JOIN nodes rc ON rc.id = e.target_id
        WHERE e.source_id = v_source_item
          AND e.edge_type = 'reviewed_under'
          AND rc.node_type = 'review_context'
          AND rc.external_id = 'needs_context'
    ) THEN
        RAISE EXCEPTION 'Expected unmatched source item to route to holding context';
    END IF;

    v_candidate := create_knowledge_candidate(
        p_candidate_kind  := 'plugin_change',
        p_statement       := 'Scope may need another plugin after repeated context gaps.',
        p_target_payload  := '{"scope_id": "conformance:onboarding-scope"}',
        p_source_node_ids := ARRAY[v_source_item],
        p_confidence      := 0.8
    );

    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = v_candidate
          AND properties->>'candidate_kind' = 'plugin_change'
    ) THEN
        RAISE EXCEPTION 'Expected extended candidate kind plugin_change to be supported';
    END IF;

    v_revision_event := propose_scope_revision_from_context_gap(
        p_scope_id := v_scope,
        p_reason   := 'repeated_context_gap',
        p_actor    := 'test:onboarding'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM events
        WHERE id = v_revision_event
          AND event_type = 'scope_revision_proposed'
    ) THEN
        RAISE EXCEPTION 'Expected scope_revision_proposed event from context gap';
    END IF;
END
$$;

ROLLBACK;
