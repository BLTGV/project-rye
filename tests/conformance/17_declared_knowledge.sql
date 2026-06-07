-- Declared knowledge plugin helpers.

SET search_path = rye, public, pg_catalog;

BEGIN;

DO $$
DECLARE
    v_assertion uuid;
    v_candidate uuid;
    v_customer uuid;
    v_customer_statement uuid;
    v_declarer uuid;
    v_edge uuid;
    v_instance uuid;
    v_plugin jsonb;
    v_project uuid;
    v_series uuid;
    v_source_item uuid;
    v_statement uuid;
    v_summary jsonb;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:declared-knowledge', true);

    IF NOT EXISTS (
        SELECT 1
        FROM nodes p
        WHERE p.node_type = 'plugin'
          AND p.external_source = 'rye_plugin'
          AND p.external_id = 'rye-declared-knowledge'
          AND p.archived_at IS NULL
          AND p.properties->'contributes'->'node_types' ? 'declared_knowledge_series'
          AND p.properties->'contributes'->'event_types' ? 'declared_knowledge_received'
    ) THEN
        RAISE EXCEPTION 'Expected rye-declared-knowledge plugin metadata to be synced';
    END IF;

    v_plugin := rye_capability_catalog();
    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_plugin->'capabilities') AS c(capability)
        WHERE capability->>'source_kind' = 'plugin'
          AND capability->>'source_id' = 'rye-declared-knowledge'
          AND capability->>'id' = 'capture-declared-knowledge'
          AND capability->'requires'->'db_functions' ? 'record_declared_statement'
    ) THEN
        RAISE EXCEPTION 'Expected declared knowledge capability metadata';
    END IF;

    INSERT INTO nodes (node_type, label, external_source, external_id, properties)
    VALUES ('person', 'Casey Owner', 'test', 'person:casey-owner', '{"role": "owner"}')
    RETURNING id INTO v_declarer;

    INSERT INTO nodes (node_type, label, external_source, external_id, properties)
    VALUES ('source_item', 'Owner interview transcript', 'test', 'source:owner-interview-2026-06-07', '{"source": "agent_conversation"}')
    RETURNING id INTO v_source_item;

    SELECT id INTO v_source_item
    FROM nodes
    WHERE external_source = 'test'
      AND external_id = 'source:owner-interview-2026-06-07';

    v_series := create_declared_knowledge_series(
        p_series_key    := 'owner-weekly-sitrep',
        p_label         := 'Owner Weekly Sitrep',
        p_purpose       := 'Recurring owner-declared organizational facts.',
        p_profile       := 'weekly_sitrep',
        p_cadence       := '{"frequency": "weekly"}',
        p_owner_node_id := v_declarer,
        p_actor         := 'test:declared-knowledge'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM current_valid_assertions
        WHERE subject_node_id = v_series
          AND assertion_type = 'declared_series_profile'
          AND claim->>'profile' = 'weekly_sitrep'
    ) THEN
        RAISE EXCEPTION 'Expected declared series profile assertion';
    END IF;

    v_instance := record_declared_knowledge_instance(
        p_series_id        := v_series,
        p_title            := 'Owner Weekly Sitrep - 2026-06-07',
        p_summary          := 'Owner declared current customers, projects, and systems.',
        p_instance_key     := 'owner-weekly-sitrep:2026-06-07',
        p_declarer_node_id := v_declarer,
        p_source_item_id   := v_source_item,
        p_actor            := 'test:declared-knowledge'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM edges
        WHERE edge_type = 'declared_by'
          AND source_id = v_instance
          AND target_id = v_declarer
          AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Expected declared instance to link to declarer';
    END IF;

    v_customer_statement := record_declared_statement(
        p_instance_id      := v_instance,
        p_statement        := 'Example Client is a current customer.',
        p_statement_type   := 'current_fact',
        p_candidate_kind   := 'fact',
        p_assertion_type   := 'customer_status',
        p_assertion_key    := 'default',
        p_claim            := '{"status": "current_customer"}',
        p_confidence       := 0.95,
        p_actor            := 'test:declared-knowledge'
    );

    SELECT e.target_id
    INTO v_candidate
    FROM edges e
    WHERE e.source_id = v_customer_statement
      AND e.edge_type = 'statement_proposes_candidate'
      AND e.archived_at IS NULL;

    IF v_candidate IS NULL THEN
        RAISE EXCEPTION 'Expected declared statement to create a knowledge candidate';
    END IF;

    v_customer := create_declared_node(
        p_statement_id    := v_customer_statement,
        p_node_type       := 'customer',
        p_label           := 'Example Client',
        p_properties      := '{"declared_status": "current_customer"}',
        p_external_source := 'declared:owner-weekly-sitrep',
        p_external_id     := 'customer:example-client',
        p_actor           := 'test:declared-knowledge'
    );

    v_assertion := promote_declared_statement_to_assertion(
        p_statement_id    := v_customer_statement,
        p_assertion_type  := 'customer_status',
        p_assertion_key   := 'default',
        p_subject_node_id := v_customer,
        p_claim           := '{"status": "current_customer"}',
        p_confidence      := 0.95,
        p_actor           := 'test:declared-knowledge'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM current_valid_assertions
        WHERE id = v_assertion
          AND subject_node_id = v_customer
          AND assertion_type = 'customer_status'
          AND claim->>'status' = 'current_customer'
          AND attrs->>'declared_statement_id' = v_customer_statement::text
    ) THEN
        RAISE EXCEPTION 'Expected promoted assertion to be current and linked to declared statement';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM current_valid_assertions
        WHERE subject_node_id = v_candidate
          AND assertion_type = 'candidate_status'
          AND claim->>'status' = 'accepted'
    ) THEN
        RAISE EXCEPTION 'Expected promoted statement candidate to be accepted';
    END IF;

    v_statement := record_declared_statement(
        p_instance_id    := v_instance,
        p_statement      := 'Example Project is an active project for Example Client.',
        p_statement_type := 'current_fact',
        p_candidate_kind := 'edge',
        p_confidence     := 0.9,
        p_actor          := 'test:declared-knowledge'
    );

    v_project := create_declared_node(
        p_statement_id    := v_statement,
        p_node_type       := 'project',
        p_label           := 'Example Project',
        p_external_source := 'declared:owner-weekly-sitrep',
        p_external_id     := 'project:example-project',
        p_actor           := 'test:declared-knowledge'
    );

    v_edge := create_declared_edge(
        p_statement_id   := v_statement,
        p_edge_type      := 'project_for_customer',
        p_source_node_id := v_project,
        p_target_node_id := v_customer,
        p_properties     := '{"declared_relationship": true}',
        p_actor          := 'test:declared-knowledge'
    );

    v_assertion := promote_declared_statement_to_assertion(
        p_statement_id    := v_statement,
        p_assertion_type  := 'project_status',
        p_assertion_key   := 'default',
        p_subject_edge_id := v_edge,
        p_claim           := '{"status": "active"}',
        p_confidence      := 0.9,
        p_actor           := 'test:declared-knowledge'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM current_valid_assertions
        WHERE id = v_assertion
          AND subject_edge_id = v_edge
          AND assertion_type = 'project_status'
          AND claim->>'status' = 'active'
    ) THEN
        RAISE EXCEPTION 'Expected declared edge assertion to be promoted';
    END IF;

    v_summary := declared_knowledge_summary(v_series);
    IF (v_summary->'totals'->>'series')::int <> 1
       OR (v_summary->'totals'->>'instances')::int <> 1
       OR (v_summary->'totals'->>'statements')::int <> 2
    THEN
        RAISE EXCEPTION 'Unexpected declared knowledge summary: %', v_summary;
    END IF;
END
$$;

ROLLBACK;
