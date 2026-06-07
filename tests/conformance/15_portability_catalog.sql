-- Portable plugin, skill, capability, source, and agent-context catalogs.

SET search_path = rye, public, pg_catalog;

BEGIN;

DO $$
DECLARE
    v_context jsonb;
    v_missing text[];
    v_scope_one uuid;
    v_scope_two uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:portability', true);
    PERFORM set_config('app.current_teams', 'system', true);

    SELECT array_agg(expected_id ORDER BY expected_id)
    INTO v_missing
    FROM (
        SELECT unnest(ARRAY[
            'rye-agent-ops',
            'rye-domain-onboarding',
            'rye-import-inspector',
            'rye-installer',
            'rye-knowledge-reader',
            'rye-onboarding',
            'rye-pattern-library',
            'rye-source-context-intake',
            'rye-tabular-intake'
        ]) AS expected_id
    ) expected
    WHERE NOT EXISTS (
        SELECT 1
        FROM nodes s
        WHERE s.archived_at IS NULL
          AND s.node_type = 'skill'
          AND s.external_source = 'rye_skill'
          AND s.external_id = expected.expected_id
          AND s.properties ? 'manifest'
          AND s.properties ? 'install'
          AND s.properties ? 'capabilities'
    );

    IF array_length(v_missing, 1) IS NOT NULL THEN
        RAISE EXCEPTION 'Missing synced skill metadata for: %', array_to_string(v_missing, ', ');
    END IF;

    IF (
        SELECT count(DISTINCT s.id)
        FROM current_valid_assertions a
        JOIN nodes s ON s.id = a.subject_node_id
        WHERE s.archived_at IS NULL
          AND s.node_type = 'skill'
          AND s.external_source = 'rye_skill'
          AND a.assertion_type = 'skill_manifest'
    ) < 9 THEN
        RAISE EXCEPTION 'Expected current skill_manifest assertions for all Rye skills';
    END IF;

    IF (
        SELECT count(DISTINCT s.id)
        FROM current_valid_assertions a
        JOIN nodes s ON s.id = a.subject_node_id
        WHERE s.archived_at IS NULL
          AND s.node_type = 'skill'
          AND s.external_source = 'rye_skill'
          AND a.assertion_type = 'skill_capabilities'
    ) < 9 THEN
        RAISE EXCEPTION 'Expected current skill_capabilities assertions for all Rye skills';
    END IF;

    IF (rye_plugin_catalog()->'totals'->>'plugins')::int < 9 THEN
        RAISE EXCEPTION 'Expected rye_plugin_catalog() to include installed plugins';
    END IF;

    IF (rye_skill_catalog()->'totals'->>'skills')::int < 9 THEN
        RAISE EXCEPTION 'Expected rye_skill_catalog() to include installed skills';
    END IF;

    IF (rye_capability_catalog()->'totals'->>'capabilities')::int < 18 THEN
        RAISE EXCEPTION 'Expected rye_capability_catalog() to include plugin and skill capabilities';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(rye_capability_catalog()->'capabilities') AS c(capability)
        WHERE capability->>'source_kind' = 'skill'
          AND capability->>'source_id' = 'rye-knowledge-reader'
          AND capability->>'id' = 'read-rye-knowledge'
          AND (capability->>'read_only')::boolean = true
          AND capability->'requires'->'db_functions' ? 'rye_agent_context'
    ) THEN
        RAISE EXCEPTION 'Expected rye-knowledge-reader read capability metadata';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(rye_capability_catalog()->'capabilities') AS c(capability)
        WHERE capability->>'source_kind' = 'plugin'
          AND capability->>'source_id' = 'rye-source-context'
          AND capability->>'id' = 'manage-source-context'
          AND capability->'entrypoints' @> '[{"type": "db_function", "name": "rye_source_inventory"}]'::jsonb
    ) THEN
        RAISE EXCEPTION 'Expected rye-source-context DB entrypoint capability metadata';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(rye_capability_catalog()->'capabilities') AS c(capability)
        WHERE capability->>'source_kind' = 'plugin'
          AND capability->>'source_id' = 'rye-declared-knowledge'
          AND capability->>'id' = 'capture-declared-knowledge'
          AND capability->'requires'->'db_functions' ? 'record_declared_statement'
    ) THEN
        RAISE EXCEPTION 'Expected rye-declared-knowledge capability metadata';
    END IF;

    IF rye_source_inventory() <> '[]'::jsonb THEN
        RAISE EXCEPTION 'Expected fresh source inventory to be empty, got %', rye_source_inventory();
    END IF;

    IF rye_pending_context_confirmations() <> '[]'::jsonb THEN
        RAISE EXCEPTION 'Expected fresh pending context confirmations to be empty, got %', rye_pending_context_confirmations();
    END IF;

    v_context := rye_agent_context();
    IF v_context->'scope_selection'->>'mode' <> 'none'
       OR v_context->'scope_selection'->>'selected_scope_found' <> 'false'
       OR v_context->'scope_policy' <> 'null'::jsonb
    THEN
        RAISE EXCEPTION 'Expected no selected scope before active scopes, got %', v_context->'scope_selection';
    END IF;

    v_scope_one := create_onboarding_scope(
        p_scope_key := 'conformance:portable-one',
        p_label     := 'Portable Scope One',
        p_purpose   := 'Validate single active scope agent context.',
        p_boundary  := '{"in_scope": ["portability"], "out_of_scope": []}',
        p_owner     := 'test:portability'
    );
    PERFORM record_scope_policy(v_scope_one, 'retention_policy', '{"default_retention_class": "review_window"}', 'default', 'test:portability');
    PERFORM enable_plugin_for_scope(
        v_scope_one,
        'rye-source-context',
        'Source Context',
        coalesce((SELECT properties->'manifest' FROM nodes WHERE node_type = 'plugin' AND external_source = 'rye_plugin' AND external_id = 'rye-source-context' AND archived_at IS NULL LIMIT 1), '{}'::jsonb),
        'test:portability'
    );
    PERFORM activate_onboarding_scope(v_scope_one, 'test:portability');

    v_context := rye_agent_context();
    IF v_context->'scope_selection'->>'mode' <> 'single_active'
       OR v_context->'scope_selection'->>'selected_scope_found' <> 'true'
       OR v_context->'scope_selection'->>'selected_scope_id' <> v_scope_one::text
       OR v_context->'scope_policy' IS NULL
    THEN
        RAISE EXCEPTION 'Expected single active scope agent context, got %', v_context->'scope_selection';
    END IF;

    v_context := rye_agent_context(v_scope_one);
    IF v_context->'scope_selection'->>'mode' <> 'explicit'
       OR v_context->'scope_selection'->>'selected_scope_found' <> 'true'
       OR v_context->'scope_selection'->>'selected_scope_id' <> v_scope_one::text
    THEN
        RAISE EXCEPTION 'Expected explicit scope agent context, got %', v_context->'scope_selection';
    END IF;

    v_scope_two := create_onboarding_scope(
        p_scope_key := 'conformance:portable-two',
        p_label     := 'Portable Scope Two',
        p_purpose   := 'Validate multiple active scope agent context.',
        p_boundary  := '{"in_scope": ["portability"], "out_of_scope": []}',
        p_owner     := 'test:portability'
    );
    PERFORM record_scope_policy(v_scope_two, 'retention_policy', '{"default_retention_class": "review_window"}', 'default', 'test:portability');
    PERFORM enable_plugin_for_scope(
        v_scope_two,
        'rye-source-context',
        'Source Context',
        coalesce((SELECT properties->'manifest' FROM nodes WHERE node_type = 'plugin' AND external_source = 'rye_plugin' AND external_id = 'rye-source-context' AND archived_at IS NULL LIMIT 1), '{}'::jsonb),
        'test:portability'
    );
    PERFORM activate_onboarding_scope(v_scope_two, 'test:portability');

    v_context := rye_agent_context();
    IF v_context->'scope_selection'->>'mode' <> 'multiple_active'
       OR v_context->'scope_selection'->>'selected_scope_found' <> 'false'
       OR jsonb_array_length(v_context->'active_scopes') <> 2
    THEN
        RAISE EXCEPTION 'Expected multiple active scope agent context, got %', v_context->'scope_selection';
    END IF;
END
$$;

ROLLBACK;
