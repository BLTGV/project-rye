-- Knowledge mechanisms v2 §§1-3 and §7.1-5: governance, policy, salience,
-- canonical vocabulary, and default-behavior guards.

SET search_path = rye, public, pg_catalog;
BEGIN;

DO $$
DECLARE
    v_agent uuid;
    v_assertion uuid;
    v_core uuid;
    v_direct_scope uuid;
    v_edge uuid;
    v_event uuid;
    v_inherited_scope uuid;
    v_node_alias_old uuid;
    v_node_alias_new uuid;
    v_open_scope uuid;
    v_other_scope uuid;
    v_parent uuid;
    v_source_scope uuid;
    v_step uuid;
    v_strict_scope uuid;
    v_subject uuid;
    v_target uuid;
    v_type_scope uuid;
    v_witness uuid;
    v_failed boolean;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:knowledge-governance', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label) VALUES
        ('onboarding_scope', 'Direct scope'),
        ('onboarding_scope', 'Inherited scope'),
        ('onboarding_scope', 'Type scope'),
        ('onboarding_scope', 'Other type scope'),
        ('onboarding_scope', 'Source scope'),
        ('onboarding_scope', 'Strict scope'),
        ('onboarding_scope', 'Open default scope');

    SELECT id INTO v_direct_scope FROM nodes WHERE label = 'Direct scope' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_inherited_scope FROM nodes WHERE label = 'Inherited scope' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_type_scope FROM nodes WHERE label = 'Type scope' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_other_scope FROM nodes WHERE label = 'Other type scope' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_source_scope FROM nodes WHERE label = 'Source scope' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_strict_scope FROM nodes WHERE label = 'Strict scope' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_open_scope FROM nodes WHERE label = 'Open default scope' ORDER BY created_at DESC LIMIT 1;

    -- Configure scopes before coverage exists, then mark all active.
    PERFORM record_assertion('review_policy', '{"review_policy":"candidates_only"}', v_direct_scope,
                             p_basis := 'assumed');
    PERFORM record_assertion('review_policy', '{"review_policy":"strict"}', v_strict_scope,
                             p_basis := 'assumed');
    PERFORM record_assertion('review_policy', '{"review_policy":"open"}', v_open_scope,
                             p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_direct_scope, p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_inherited_scope, p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_type_scope, p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_other_scope, p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_source_scope, p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_strict_scope, p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_open_scope, p_basis := 'assumed');

    INSERT INTO nodes (node_type, label) VALUES
        ('project', 'Governed project'),
        ('task', 'Governed step'),
        ('person', 'Governance witness'),
        ('thing', 'Type-governed subject'),
        ('thing', 'Edge target');
    SELECT id INTO v_parent FROM nodes WHERE label = 'Governed project' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_step FROM nodes WHERE label = 'Governed step' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_witness FROM nodes WHERE label = 'Governance witness' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_subject FROM nodes WHERE label = 'Type-governed subject' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_target FROM nodes WHERE label = 'Edge target' ORDER BY created_at DESC LIMIT 1;

    INSERT INTO edges (edge_type, source_id, target_id) VALUES
        ('scope_governs_subject', v_direct_scope, v_parent),
        ('has_step', v_parent, v_step),
        ('scope_governs_source', v_source_scope, v_witness);

    IF governing_scope(v_parent, NULL, 'project_status', NULL) <> v_direct_scope THEN
        RAISE EXCEPTION 'governing_scope missed direct subject coverage';
    END IF;
    IF governing_scope(v_step, NULL, 'task_status', NULL) <> v_direct_scope THEN
        RAISE EXCEPTION 'governing_scope missed inherited has_step coverage';
    END IF;
    IF governing_scope(v_subject, NULL, 'source_only', v_witness) <> v_source_scope THEN
        RAISE EXCEPTION 'governing_scope missed witness source coverage';
    END IF;

    -- Edge subjects resolve their source endpoint before their target endpoint.
    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('related_to', v_parent, v_target) RETURNING id INTO v_edge;
    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('scope_governs_subject', v_inherited_scope, v_target);
    IF governing_scope(NULL, v_edge, 'edge_fact', NULL) <> v_direct_scope THEN
        RAISE EXCEPTION 'edge governing scope did not prefer source endpoint';
    END IF;

    -- Subject coverage wins over both type and source coverage.
    PERFORM record_assertion(
        'registry_entry', '{"value":true}', v_type_scope,
        p_assertion_key := 'governed_type:project_status', p_basis := 'assumed'
    );
    IF governing_scope(v_parent, NULL, 'project_status', v_witness) <> v_direct_scope THEN
        RAISE EXCEPTION 'governing_scope precedence did not prefer subject coverage';
    END IF;

    -- Type coverage is used when subject coverage is absent.
    PERFORM record_assertion(
        'registry_entry', '{"value":true}', v_type_scope,
        p_assertion_key := 'governed_type:type_only', p_basis := 'assumed'
    );
    IF governing_scope(v_subject, NULL, 'type_only', NULL) <> v_type_scope THEN
        RAISE EXCEPTION 'governing_scope missed type coverage';
    END IF;

    -- Two active type claims are an error, not a UUID tie-break.
    PERFORM record_assertion(
        'registry_entry', '{"value":true}', v_other_scope,
        p_assertion_key := 'governed_type:type_only', p_basis := 'assumed'
    );
    v_failed := false;
    BEGIN
        PERFORM governing_scope(v_subject, NULL, 'type_only', NULL);
    EXCEPTION WHEN OTHERS THEN
        v_failed := SQLERRM LIKE 'Ambiguous governing scope%';
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'ambiguous type governance did not raise';
    END IF;

    -- Deactivate the second type scope so later policy checks are unambiguous.
    PERFORM record_assertion('scope_status', '{"status":"inactive"}', v_other_scope, p_basis := 'assumed');

    -- Explicit scope mismatch must fail when a durable governing scope exists.
    v_failed := false;
    BEGIN
        PERFORM record_assertion(
            'project_status', '{"status":"green"}', v_parent,
            p_basis := 'assumed', p_scope_node_id := v_open_scope
        );
    EXCEPTION WHEN OTHERS THEN
        v_failed := SQLERRM LIKE 'Explicit scope % does not match governing scope%';
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'explicit/resolved scope mismatch did not raise';
    END IF;

    -- candidates_only forces non-observed writes but leaves observed writes accepted.
    v_event := record_event('governance_fixture', 'reported policy fixture',
                            p_participant_ids := ARRAY[v_parent],
                            p_participant_roles := ARRAY['subject']);
    v_assertion := record_assertion(
        'policy_test', '{"value":1}', v_parent,
        p_assertion_key := 'reported', p_status := 'accepted', p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object('kind','source','event_id',v_event)]
    );
    IF (SELECT status FROM assertions WHERE id = v_assertion) <> 'candidate' THEN
        RAISE EXCEPTION 'candidates_only did not force reported write to candidate';
    END IF;

    v_assertion := record_assertion(
        'policy_test', '{"value":2}', v_parent,
        p_assertion_key := 'observed', p_status := 'accepted', p_basis := 'observed',
        p_evidence := ARRAY[jsonb_build_object('kind','source','event_id',v_event)]
    );
    IF (SELECT status FROM assertions WHERE id = v_assertion) <> 'accepted' THEN
        RAISE EXCEPTION 'candidates_only changed observed write behavior';
    END IF;

    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('scope_governs_subject', v_strict_scope, v_subject);
    v_assertion := record_assertion(
        'strict_test', '{"value":1}', v_subject,
        p_status := 'accepted', p_basis := 'observed',
        p_evidence := ARRAY[jsonb_build_object('kind','source','event_id',v_event)]
    );
    IF (SELECT status FROM assertions WHERE id = v_assertion) <> 'candidate' THEN
        RAISE EXCEPTION 'strict did not force observed write to candidate';
    END IF;

    -- No governing scope and open policy preserve accepted behavior.
    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Ungoverned behavior guard') RETURNING id INTO v_target;
    v_assertion := record_assertion('unguarded_test', '{"value":1}', v_target, p_basis := 'assumed');
    IF (SELECT status FROM assertions WHERE id = v_assertion) <> 'accepted' THEN
        RAISE EXCEPTION 'absent governance changed accepted write behavior';
    END IF;

    -- Agent acceptance is gated; a scoped capability permits it.
    v_assertion := record_assertion(
        'policy_test', '{"value":3}', v_parent,
        p_assertion_key := 'agent_accept', p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object('kind','source','event_id',v_event)]
    );
    v_agent := create_agent_identity('governance_agent', 'Governance agent', 'test');
    PERFORM set_config('app.current_role', 'agent:test', true);
    PERFORM set_config('app.current_user_id', 'governance_agent', true);
    v_failed := false;
    BEGIN
        PERFORM accept_assertion(v_assertion);
    EXCEPTION WHEN OTHERS THEN
        v_failed := SQLERRM LIKE 'Agent acceptance requires rye.authoritative.promote%';
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'agent acceptance without capability did not fail';
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:knowledge-governance', true);
    PERFORM grant_agent_capability(
        'governance_agent', 'rye.authoritative.promote',
        p_scope_ref := v_direct_scope::text
    );
    PERFORM set_config('app.current_role', 'agent:test', true);
    PERFORM set_config('app.current_user_id', 'governance_agent', true);
    PERFORM accept_assertion(v_assertion);
    IF (SELECT status FROM assertions WHERE id = v_assertion) <> 'accepted' THEN
        RAISE EXCEPTION 'capability-granted agent acceptance failed';
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:knowledge-governance', true);
    v_assertion := record_assertion(
        'policy_test', '{"value":4}', v_parent,
        p_assertion_key := 'human_accept', p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object('kind','source','event_id',v_event)]
    );
    PERFORM accept_assertion(v_assertion);
    IF (SELECT status FROM assertions WHERE id = v_assertion) <> 'accepted' THEN
        RAISE EXCEPTION 'non-agent human acceptance failed';
    END IF;

    -- node_salience includes only agent_query events.
    PERFORM log_agent_query('salience-a', 'question', 'summary', ARRAY[v_target]);
    PERFORM record_event('not_agent_query', 'must not count',
                         p_participant_ids := ARRAY[v_target],
                         p_participant_roles := ARRAY['subject']);
    IF NOT EXISTS (
        SELECT 1 FROM node_salience
        WHERE node_id = v_target AND query_count = 1 AND distinct_agents = 1
          AND salience_score > 0
    ) THEN
        RAISE EXCEPTION 'node_salience counted non-agent-query events or missed agent query';
    END IF;
    IF pg_get_viewdef('rye.stale_digests'::regclass, true)
       ILIKE '%where%salience.salience_score%'
    THEN
        RAISE EXCEPTION 'salience appears in stale_digests membership predicate';
    END IF;

    -- Alias chains normalize new writes while preserving existing rows.
    SELECT id INTO v_core
    FROM nodes
    WHERE external_source = 'rye_registry' AND external_id = 'core' AND archived_at IS NULL;

    INSERT INTO nodes (node_type, label) VALUES ('gardn_node', 'Pre-alias node')
    RETURNING id INTO v_node_alias_old;
    v_assertion := record_assertion('gardn_type', '{"value":"old"}', v_target, p_basis := 'assumed');

    PERFORM record_assertion(
        'registry_entry', '{"value":"garden_type"}', v_core,
        p_assertion_key := 'type_alias:assertion_type:gardn_type', p_basis := 'assumed'
    );
    PERFORM record_assertion(
        'registry_entry', '{"value":"garden_type_v2"}', v_core,
        p_assertion_key := 'type_alias:assertion_type:garden_type', p_basis := 'assumed'
    );
    PERFORM record_assertion(
        'registry_entry', '{"value":"garden_node"}', v_core,
        p_assertion_key := 'type_alias:node_type:gardn_node', p_basis := 'assumed'
    );

    IF canonical_type('assertion_type', 'gardn_type') <> 'garden_type_v2' THEN
        RAISE EXCEPTION 'canonical_type did not resolve full alias chain';
    END IF;
    IF (SELECT assertion_type FROM assertions WHERE id = v_assertion) <> 'gardn_type' THEN
        RAISE EXCEPTION 'alias registry rewrote an existing assertion row';
    END IF;
    v_assertion := record_assertion('gardn_type', '{"value":"new"}', v_subject,
                                    p_assertion_key := 'alias_write', p_basis := 'assumed');
    IF (SELECT assertion_type FROM assertions WHERE id = v_assertion) <> 'garden_type_v2' THEN
        RAISE EXCEPTION 'record_assertion did not normalize new alias write';
    END IF;

    INSERT INTO nodes (node_type, label) VALUES ('gardn_node', 'Post-alias node')
    RETURNING id INTO v_node_alias_new;
    IF (SELECT node_type FROM nodes WHERE id = v_node_alias_old) <> 'gardn_node'
       OR (SELECT node_type FROM nodes WHERE id = v_node_alias_new) <> 'garden_node'
    THEN
        RAISE EXCEPTION 'node type alias did not preserve old and normalize new writes';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM type_vocabulary_report
        WHERE kind = 'assertion_type' AND type_value = 'gardn_type'
          AND canonical_value = 'garden_type_v2'
    ) THEN
        RAISE EXCEPTION 'type_vocabulary_report missed canonical alias';
    END IF;

    PERFORM record_assertion(
        'registry_entry', '{"value":"cycle_b"}', v_core,
        p_assertion_key := 'type_alias:edge_type:cycle_a', p_basis := 'assumed'
    );
    PERFORM record_assertion(
        'registry_entry', '{"value":"cycle_a"}', v_core,
        p_assertion_key := 'type_alias:edge_type:cycle_b', p_basis := 'assumed'
    );
    v_failed := false;
    BEGIN
        PERFORM canonical_type('edge_type', 'cycle_a');
    EXCEPTION WHEN OTHERS THEN
        v_failed := SQLERRM LIKE 'Type alias cycle detected%';
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'canonical_type alias cycle did not raise';
    END IF;

    -- Default scope is the final fallback and open remains behavior-neutral.
    PERFORM record_assertion(
        'registry_entry', jsonb_build_object('value', v_open_scope::text), v_core,
        p_assertion_key := 'DEFAULT_SCOPE', p_basis := 'assumed'
    );
    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Default-scope subject') RETURNING id INTO v_target;
    IF governing_scope(v_target, NULL, 'no_other_coverage', NULL) <> v_open_scope THEN
        RAISE EXCEPTION 'governing_scope missed DEFAULT_SCOPE fallback';
    END IF;
END
$$;

ROLLBACK;
