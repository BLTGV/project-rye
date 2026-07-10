-- Plugin metadata should be loaded during a clean install from plugins/*/rye-plugin.json.

SET search_path = rye, public, pg_catalog;

BEGIN;

DO $$
DECLARE
    v_contributes_count int;
    v_manifest_count int;
    v_missing text[];
    v_plugin_count int;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:plugin-metadata', true);

    SELECT count(*)
    INTO v_plugin_count
    FROM nodes
    WHERE archived_at IS NULL
      AND node_type = 'plugin'
      AND external_source = 'rye_plugin';

    IF v_plugin_count < 9 THEN
        RAISE EXCEPTION 'Expected at least 9 synced Rye plugin nodes, got %', v_plugin_count;
    END IF;

    SELECT array_agg(expected_id ORDER BY expected_id)
    INTO v_missing
    FROM (
        SELECT unnest(ARRAY[
            'rye-change-tracking',
            'rye-crm',
            'rye-declared-knowledge',
            'rye-evidence-anchor',
            'rye-logging',
            'rye-org',
            'rye-project-management',
            'rye-source-context',
            'rye-tabular-intake'
        ]) AS expected_id
    ) expected
    WHERE NOT EXISTS (
        SELECT 1
        FROM nodes p
        WHERE p.archived_at IS NULL
          AND p.node_type = 'plugin'
          AND p.external_source = 'rye_plugin'
          AND p.external_id = expected.expected_id
          AND p.properties ? 'manifest'
          AND p.properties ? 'contributes'
    );

    IF array_length(v_missing, 1) IS NOT NULL THEN
        RAISE EXCEPTION 'Missing synced plugin metadata for: %', array_to_string(v_missing, ', ');
    END IF;

    SELECT count(DISTINCT p.id)
    INTO v_manifest_count
    FROM current_valid_assertions a
    JOIN nodes p ON p.id = a.subject_node_id
    WHERE p.archived_at IS NULL
      AND p.node_type = 'plugin'
      AND p.external_source = 'rye_plugin'
      AND a.assertion_type = 'plugin_manifest';

    SELECT count(DISTINCT p.id)
    INTO v_contributes_count
    FROM current_valid_assertions a
    JOIN nodes p ON p.id = a.subject_node_id
    WHERE p.archived_at IS NULL
      AND p.node_type = 'plugin'
      AND p.external_source = 'rye_plugin'
      AND a.assertion_type = 'plugin_contributes';

    IF v_manifest_count < v_plugin_count THEN
        RAISE EXCEPTION 'Expected plugin_manifest assertion for each plugin (%), got %', v_plugin_count, v_manifest_count;
    END IF;

    IF v_contributes_count < v_plugin_count THEN
        RAISE EXCEPTION 'Expected plugin_contributes assertion for each plugin (%), got %', v_plugin_count, v_contributes_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM nodes p
        WHERE p.archived_at IS NULL
          AND p.external_source = 'rye_plugin'
          AND p.external_id = 'rye-source-context'
          AND p.properties->'contributes'->'node_types' ? 'source_account'
          AND p.properties->'contributes'->'node_types' ? 'source_identity'
          AND p.properties->'contributes'->'edge_types' ? 'retrieved_via'
          AND p.properties->'contributes'->'edge_types' ? 'identity_of'
          AND p.properties->'contributes'->'assertion_types' ? 'source_context_confirmation'
          AND p.properties->'contributes'->'assertion_types' ? 'source_identity_confirmation'
          AND p.properties->'contributes'->'assertion_types' ? 'source_of_truth_policy'
          AND p.properties->'contributes'->'event_types' ? 'source_context_intake_completed'
          AND p.properties->'contributes'->'event_types' ? 'source_identity_confirmed'
          AND p.properties->'contributes'->'artifact_types' ? 'source_item_raw'
    ) THEN
        RAISE EXCEPTION 'Expected rye-source-context contributed type metadata to be synced';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM nodes p
        WHERE p.archived_at IS NULL
          AND p.external_source = 'rye_plugin'
          AND p.external_id = 'rye-org'
          AND p.properties->'contributes'->'node_types' ? 'person'
          AND p.properties->'contributes'->'node_types' ? 'system'
          AND p.properties->'contributes'->'node_types' ? 'department'
          AND p.properties->'contributes'->'edge_types' ? 'holds_role'
          AND p.properties->'contributes'->'assertion_types' ? 'process_constraint'
          AND p.properties->'contributes'->'assertion_types' ? 'improvement_cycle'
          AND p.properties->'contributes'->'assertion_types' ? 'convention_registry'
          AND p.properties->'contributes'->'assertion_types' ? 'process_definition'
          AND p.properties->'contributes'->'assertion_types' ? 'process_transition_policy'
          AND p.properties->'contributes'->'event_types' ? 'process_transition_evaluated'
          AND p.properties->'contributes'->'event_types' ? 'process_exception_approved'
          AND p.properties->'onboarding'->'never_infer_defaults' ? 'Do not infer employment, department membership, responsibility, or policy ownership from source membership alone.'
    ) THEN
        RAISE EXCEPTION 'Expected rye-org organization metadata and never-infer defaults to be synced';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM nodes p
        WHERE p.archived_at IS NULL
          AND p.external_source = 'rye_plugin'
          AND p.external_id = 'rye-declared-knowledge'
          AND p.properties->'contributes'->'node_types' ? 'declared_knowledge_series'
          AND p.properties->'contributes'->'node_types' ? 'declared_statement'
          AND p.properties->'contributes'->'edge_types' ? 'statement_proposes_candidate'
          AND p.properties->'contributes'->'assertion_types' ? 'declared_statement_status'
          AND p.properties->'contributes'->'event_types' ? 'declared_statement_promoted'
    ) THEN
        RAISE EXCEPTION 'Expected rye-declared-knowledge metadata to be synced';
    END IF;
END
$$;

ROLLBACK;
