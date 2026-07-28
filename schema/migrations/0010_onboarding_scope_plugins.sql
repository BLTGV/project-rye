-- Onboarding scopes, plugin metadata, expected contexts, and context gaps.
--
-- This migration keeps onboarding as conventions on the existing Rye graph:
-- nodes, edges, assertions, and events. It does not add new core tables.

SET search_path = rye, pg_catalog, public;

CREATE INDEX IF NOT EXISTS idx_nodes_onboarding_scope_active
    ON nodes (external_source, external_id)
    WHERE node_type = 'onboarding_scope' AND archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_nodes_plugin_active
    ON nodes (external_source, external_id)
    WHERE node_type = 'plugin' AND archived_at IS NULL;

CREATE OR REPLACE FUNCTION create_knowledge_candidate(
    p_candidate_kind text,
    p_statement text,
    p_target_payload jsonb DEFAULT '{}'::jsonb,
    p_review_context_ids uuid[] DEFAULT '{}'::uuid[],
    p_normalized_key text DEFAULT NULL,
    p_created_by text DEFAULT NULL,
    p_source_node_ids uuid[] DEFAULT '{}'::uuid[],
    p_derived_from_node_ids uuid[] DEFAULT '{}'::uuid[],
    p_confidence numeric DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_candidate_id uuid;
    v_created_by text;
    v_event_id uuid;
    v_kind text;
    v_statement text;
BEGIN
    v_kind := lower(coalesce(nullif(trim(p_candidate_kind), ''), ''));
    v_statement := nullif(trim(p_statement), '');
    v_created_by := coalesce(p_created_by, current_setting('app.current_user_id', true));

    IF NOT (v_kind = ANY(ARRAY[
        'task',
        'edge',
        'decision',
        'procedure',
        'preference',
        'risk',
        'context_gap',
        'policy_change',
        'scope_change',
        'plugin_change'
    ])) THEN
        RAISE EXCEPTION 'Unsupported candidate kind: %', p_candidate_kind;
    END IF;

    IF v_statement IS NULL THEN
        RAISE EXCEPTION 'Candidate statement is required';
    END IF;

    IF p_confidence IS NOT NULL AND (p_confidence < 0 OR p_confidence > 1) THEN
        RAISE EXCEPTION 'confidence must be between 0 and 1';
    END IF;

    INSERT INTO nodes (node_type, label, properties, attrs)
    VALUES (
        'knowledge_candidate',
        left(v_statement, 160),
        jsonb_build_object(
            'candidate_kind', v_kind,
            'statement', v_statement,
            'target_payload', coalesce(p_target_payload, '{}'::jsonb),
            'review_context_ids', to_jsonb(coalesce(p_review_context_ids, '{}'::uuid[])),
            'normalized_key', p_normalized_key,
            'created_by', v_created_by,
            'confidence', p_confidence
        ),
        jsonb_build_object('created_by', v_created_by)
    )
    RETURNING id INTO v_candidate_id;

    INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
    SELECT
        'supported_by',
        v_candidate_id,
        source_node_id,
        jsonb_build_object('created_by', v_created_by),
        jsonb_build_object('candidate_id', v_candidate_id)
    FROM (
        SELECT DISTINCT unnest(coalesce(p_source_node_ids, '{}'::uuid[])) AS source_node_id
    ) source_nodes
    WHERE source_node_id IS NOT NULL;

    INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
    SELECT
        'derived_from',
        v_candidate_id,
        derived_node_id,
        jsonb_build_object('created_by', v_created_by),
        jsonb_build_object('candidate_id', v_candidate_id)
    FROM (
        SELECT DISTINCT unnest(coalesce(p_derived_from_node_ids, '{}'::uuid[])) AS derived_node_id
    ) derived_nodes
    WHERE derived_node_id IS NOT NULL;

    v_event_id := record_event(
        p_event_type        := 'knowledge_candidate_created',
        p_summary           := format('Knowledge candidate proposed: %s', left(v_statement, 120)),
        p_properties        := jsonb_build_object(
            'candidate_id', v_candidate_id,
            'candidate_kind', v_kind,
            'statement', v_statement,
            'target_payload', coalesce(p_target_payload, '{}'::jsonb),
            'review_context_ids', to_jsonb(coalesce(p_review_context_ids, '{}'::uuid[])),
            'normalized_key', p_normalized_key,
            'source_node_ids', to_jsonb(coalesce(p_source_node_ids, '{}'::uuid[])),
            'derived_from_node_ids', to_jsonb(coalesce(p_derived_from_node_ids, '{}'::uuid[]))
        ),
        p_participant_ids   := ARRAY[v_candidate_id],
        p_participant_roles := ARRAY['candidate'],
        p_actor             := v_created_by
    );

    PERFORM set_candidate_status(
        p_candidate_id := v_candidate_id,
        p_status       := 'proposed',
        p_reason       := 'Candidate created',
        p_actor        := v_created_by
    );

    RETURN v_candidate_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_onboarding_scope(
    p_scope_key text,
    p_label text,
    p_purpose text,
    p_boundary jsonb DEFAULT '{}'::jsonb,
    p_owner text DEFAULT NULL,
    p_created_by text DEFAULT NULL,
    p_properties jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_actor text;
    v_event_id uuid;
    v_scope_id uuid;
    v_scope_key text;
BEGIN
    v_scope_key := nullif(trim(p_scope_key), '');
    v_actor := coalesce(p_created_by, current_setting('app.current_user_id', true));

    IF v_scope_key IS NULL THEN
        RAISE EXCEPTION 'scope_key is required';
    END IF;

    IF nullif(trim(p_label), '') IS NULL THEN
        RAISE EXCEPTION 'label is required';
    END IF;

    IF nullif(trim(p_purpose), '') IS NULL THEN
        RAISE EXCEPTION 'purpose is required';
    END IF;

    INSERT INTO nodes (node_type, label, external_id, external_source, properties, attrs)
    VALUES (
        'onboarding_scope',
        p_label,
        v_scope_key,
        'rye_onboarding_scope',
        coalesce(p_properties, '{}'::jsonb) || jsonb_build_object(
            'scope_key', v_scope_key,
            'created_by', v_actor
        ),
        jsonb_build_object('created_by', v_actor)
    )
    ON CONFLICT (external_source, external_id)
        WHERE external_id IS NOT NULL AND archived_at IS NULL
    DO UPDATE
        SET label = EXCLUDED.label,
            properties = nodes.properties || EXCLUDED.properties,
            updated_at = now()
    RETURNING id INTO v_scope_id;

    v_event_id := record_event(
        p_event_type        := 'onboarding_started',
        p_summary           := format('Onboarding scope proposed: %s', left(p_label, 120)),
        p_properties        := jsonb_build_object(
            'scope_id', v_scope_id,
            'scope_key', v_scope_key,
            'purpose', p_purpose,
            'boundary', coalesce(p_boundary, '{}'::jsonb)
        ),
        p_participant_ids   := ARRAY[v_scope_id],
        p_participant_roles := ARRAY['scope'],
        p_actor             := v_actor
    );

    PERFORM record_assertion(
        p_assertion_type  := 'scope_status',
        p_assertion_key   := 'default',
        p_subject_node_id := v_scope_id,
        p_claim           := jsonb_build_object('status', 'proposed'),
        p_evidence         := ARRAY[jsonb_build_object('kind', 'source', 'event_id', v_event_id)],
        p_basis            := 'reported',
        p_confidence      := 1.0,
        p_attrs           := jsonb_build_object('onboarding_event_id', v_event_id)
    );

    PERFORM record_assertion(
        p_assertion_type  := 'scope_purpose',
        p_assertion_key   := 'default',
        p_subject_node_id := v_scope_id,
        p_claim           := jsonb_build_object('purpose', p_purpose),
        p_evidence         := ARRAY[jsonb_build_object('kind', 'source', 'event_id', v_event_id)],
        p_basis            := 'reported',
        p_confidence      := 1.0,
        p_attrs           := jsonb_build_object('onboarding_event_id', v_event_id)
    );

    PERFORM record_assertion(
        p_assertion_type  := 'scope_boundary',
        p_assertion_key   := 'default',
        p_subject_node_id := v_scope_id,
        p_claim           := coalesce(p_boundary, '{}'::jsonb),
        p_evidence         := ARRAY[jsonb_build_object('kind', 'source', 'event_id', v_event_id)],
        p_basis            := 'reported',
        p_confidence      := 1.0,
        p_attrs           := jsonb_build_object('onboarding_event_id', v_event_id)
    );

    IF nullif(trim(coalesce(p_owner, '')), '') IS NOT NULL THEN
        PERFORM record_assertion(
            p_assertion_type  := 'scope_owner',
            p_assertion_key   := 'default',
            p_subject_node_id := v_scope_id,
            p_claim           := jsonb_build_object('owner', p_owner),
            p_evidence         := ARRAY[jsonb_build_object('kind', 'source', 'event_id', v_event_id)],
        p_basis            := 'reported',
            p_confidence      := 1.0,
            p_attrs           := jsonb_build_object('onboarding_event_id', v_event_id)
        );
    END IF;

    RETURN v_scope_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_scope_policy(
    p_scope_id uuid,
    p_policy_type text,
    p_claim jsonb,
    p_assertion_key text DEFAULT 'default',
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_id uuid;
    v_event_id uuid;
    v_policy_type text;
BEGIN
    v_policy_type := nullif(trim(p_policy_type), '');

    IF v_policy_type IS NULL THEN
        RAISE EXCEPTION 'policy_type is required';
    END IF;

    IF p_claim IS NULL THEN
        RAISE EXCEPTION 'claim is required';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = p_scope_id
          AND node_type = 'onboarding_scope'
          AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Onboarding scope % not found', p_scope_id;
    END IF;

    v_event_id := record_event(
        p_event_type        := 'scope_policy_recorded',
        p_summary           := format('Scope policy recorded: %s', v_policy_type),
        p_properties        := jsonb_build_object(
            'scope_id', p_scope_id,
            'policy_type', v_policy_type,
            'assertion_key', coalesce(nullif(trim(p_assertion_key), ''), 'default')
        ),
        p_participant_ids   := ARRAY[p_scope_id],
        p_participant_roles := ARRAY['scope'],
        p_actor             := p_actor
    );

    v_assertion_id := record_assertion(
        p_assertion_type  := v_policy_type,
        p_assertion_key   := p_assertion_key,
        p_subject_node_id := p_scope_id,
        p_claim           := p_claim,
        p_evidence         := ARRAY[jsonb_build_object('kind', 'source', 'event_id', v_event_id)],
        p_basis            := 'reported',
        p_confidence      := 1.0,
        p_attrs           := jsonb_build_object('policy_event_id', v_event_id)
    );

    RETURN v_assertion_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION enable_plugin_for_scope(
    p_scope_id uuid,
    p_plugin_id text,
    p_label text DEFAULT NULL,
    p_manifest jsonb DEFAULT '{}'::jsonb,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_actor text;
    v_edge_id uuid;
    v_event_id uuid;
    v_label text;
    v_plugin_id text;
    v_plugin_node_id uuid;
BEGIN
    v_plugin_id := nullif(trim(p_plugin_id), '');
    v_actor := coalesce(p_actor, current_setting('app.current_user_id', true));

    IF v_plugin_id IS NULL THEN
        RAISE EXCEPTION 'plugin_id is required';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = p_scope_id
          AND node_type = 'onboarding_scope'
          AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Onboarding scope % not found', p_scope_id;
    END IF;

    v_label := coalesce(nullif(trim(p_label), ''), v_plugin_id);

    INSERT INTO nodes (node_type, label, external_id, external_source, properties, attrs)
    VALUES (
        'plugin',
        v_label,
        v_plugin_id,
        'rye_plugin',
        jsonb_build_object(
            'plugin_id', v_plugin_id,
            'manifest', coalesce(p_manifest, '{}'::jsonb)
        ),
        jsonb_build_object('created_by', v_actor)
    )
    ON CONFLICT (external_source, external_id)
        WHERE external_id IS NOT NULL AND archived_at IS NULL
    DO UPDATE
        SET label = EXCLUDED.label,
            properties = nodes.properties || EXCLUDED.properties,
            updated_at = now()
    RETURNING id INTO v_plugin_node_id;

    SELECT id INTO v_edge_id
    FROM edges
    WHERE edge_type = 'scope_enables_plugin'
      AND source_id = p_scope_id
      AND target_id = v_plugin_node_id
      AND archived_at IS NULL
    LIMIT 1;

    IF v_edge_id IS NULL THEN
        INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
        VALUES (
            'scope_enables_plugin',
            p_scope_id,
            v_plugin_node_id,
            jsonb_build_object('plugin_id', v_plugin_id, 'enabled_by', v_actor),
            jsonb_build_object('plugin_id', v_plugin_id)
        )
        RETURNING id INTO v_edge_id;
    END IF;

    v_event_id := record_event(
        p_event_type        := 'plugin_policy_bound',
        p_summary           := format('Plugin enabled for scope: %s', v_plugin_id),
        p_properties        := jsonb_build_object(
            'scope_id', p_scope_id,
            'plugin_id', v_plugin_id,
            'plugin_node_id', v_plugin_node_id,
            'edge_id', v_edge_id
        ),
        p_participant_ids   := ARRAY[p_scope_id, v_plugin_node_id],
        p_participant_roles := ARRAY['scope', 'plugin'],
        p_actor             := v_actor
    );

    PERFORM record_assertion(
        p_assertion_type  := 'plugin_policy_binding',
        p_assertion_key   := v_plugin_id,
        p_subject_node_id := p_scope_id,
        p_claim           := jsonb_build_object(
            'plugin_id', v_plugin_id,
            'plugin_node_id', v_plugin_node_id,
            'enabled', true,
            'manifest', coalesce(p_manifest, '{}'::jsonb)
        ),
        p_evidence         := ARRAY[jsonb_build_object('kind', 'source', 'event_id', v_event_id)],
        p_basis            := 'reported',
        p_confidence      := 1.0,
        p_attrs           := jsonb_build_object('plugin_event_id', v_event_id)
    );

    RETURN v_edge_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION compile_scope_policy(
    p_scope_id uuid
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = p_scope_id
          AND node_type = 'onboarding_scope'
          AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Onboarding scope % not found', p_scope_id;
    END IF;

    RETURN jsonb_build_object(
        'scope_id', p_scope_id,
        'scope', (
            SELECT to_jsonb(n)
            FROM nodes n
            WHERE n.id = p_scope_id
        ),
        'assertions', (
            SELECT coalesce(
                jsonb_agg(
                    jsonb_build_object(
                        'assertion_id', a.id,
                        'assertion_type', a.assertion_type,
                        'assertion_key', a.assertion_key,
                        'claim', a.claim,
                        'confidence', a.confidence,
                        'asserted_at', a.asserted_at
                    )
                    ORDER BY a.assertion_type, a.assertion_key
                ),
                '[]'::jsonb
            )
            FROM current_valid_assertions a
            WHERE a.subject_node_id = p_scope_id
        ),
        'enabled_plugins', (
            SELECT coalesce(
                jsonb_agg(
                    jsonb_build_object(
                        'plugin_node_id', p.id,
                        'plugin_id', p.external_id,
                        'label', p.label,
                        'manifest', p.properties->'manifest'
                    )
                    ORDER BY p.external_id
                ),
                '[]'::jsonb
            )
            FROM edges e
            JOIN nodes p ON p.id = e.target_id
            WHERE e.source_id = p_scope_id
              AND e.edge_type = 'scope_enables_plugin'
              AND e.archived_at IS NULL
              AND p.archived_at IS NULL
        )
    );
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION activate_onboarding_scope(
    p_scope_id uuid,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_event_id uuid;
    v_missing text[] := ARRAY[]::text[];
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = p_scope_id
          AND node_type = 'onboarding_scope'
          AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Onboarding scope % not found', p_scope_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM current_valid_assertions
        WHERE subject_node_id = p_scope_id AND assertion_type = 'scope_purpose'
    ) THEN
        v_missing := array_append(v_missing, 'scope_purpose');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM current_valid_assertions
        WHERE subject_node_id = p_scope_id
          AND assertion_type IN ('retention_policy', 'evidence_policy')
    ) THEN
        v_missing := array_append(v_missing, 'retention_policy_or_evidence_policy');
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM edges
        WHERE source_id = p_scope_id
          AND edge_type = 'scope_enables_plugin'
          AND archived_at IS NULL
    ) THEN
        v_missing := array_append(v_missing, 'scope_enables_plugin');
    END IF;

    IF array_length(v_missing, 1) IS NOT NULL THEN
        RAISE EXCEPTION 'Cannot activate onboarding scope %. Missing: %',
            p_scope_id,
            array_to_string(v_missing, ', ');
    END IF;

    v_event_id := record_event(
        p_event_type        := 'onboarding_completed',
        p_summary           := 'Onboarding scope activated',
        p_properties        := jsonb_build_object(
            'scope_id', p_scope_id,
            'compiled_policy', compile_scope_policy(p_scope_id)
        ),
        p_participant_ids   := ARRAY[p_scope_id],
        p_participant_roles := ARRAY['scope'],
        p_actor             := p_actor
    );

    PERFORM record_assertion(
        p_assertion_type  := 'scope_status',
        p_assertion_key   := 'default',
        p_subject_node_id := p_scope_id,
        p_claim           := jsonb_build_object('status', 'active'),
        p_evidence         := ARRAY[jsonb_build_object('kind', 'source', 'event_id', v_event_id)],
        p_basis            := 'reported',
        p_confidence      := 1.0,
        p_attrs           := jsonb_build_object('activation_event_id', v_event_id)
    );

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION validate_candidate_against_scope(
    p_scope_id uuid,
    p_target_kind text,
    p_target_type text
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_type text;
    v_target_kind text;
    v_target_type text;
    v_types jsonb;
BEGIN
    v_target_kind := lower(coalesce(nullif(trim(p_target_kind), ''), ''));
    v_target_type := nullif(trim(p_target_type), '');

    IF v_target_type IS NULL THEN
        RAISE EXCEPTION 'target_type is required';
    END IF;

    v_assertion_type := CASE v_target_kind
        WHEN 'node' THEN 'allowed_node_types'
        WHEN 'edge' THEN 'allowed_edge_types'
        WHEN 'assertion' THEN 'allowed_assertion_types'
        WHEN 'event' THEN 'allowed_event_types'
        WHEN 'artifact' THEN 'allowed_artifact_types'
        ELSE NULL
    END;

    IF v_assertion_type IS NULL THEN
        RAISE EXCEPTION 'Unsupported target_kind: %', p_target_kind;
    END IF;

    SELECT coalesce(a.claim->'types', '[]'::jsonb)
    INTO v_types
    FROM current_valid_assertions a
    WHERE a.subject_node_id = p_scope_id
      AND a.assertion_type = v_assertion_type
      AND a.assertion_key = 'default'
    LIMIT 1;

    IF v_types IS NULL THEN
        RETURN jsonb_build_object(
            'valid', false,
            'reason', 'missing_scope_type_policy',
            'scope_id', p_scope_id,
            'target_kind', v_target_kind,
            'target_type', v_target_type,
            'required_assertion_type', v_assertion_type
        );
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(v_types) AS t(type_value)
        WHERE t.type_value = v_target_type
    ) THEN
        RETURN jsonb_build_object(
            'valid', true,
            'reason', 'type_enabled',
            'scope_id', p_scope_id,
            'target_kind', v_target_kind,
            'target_type', v_target_type
        );
    END IF;

    RETURN jsonb_build_object(
        'valid', false,
        'reason', 'type_not_enabled_for_scope',
        'scope_id', p_scope_id,
        'target_kind', v_target_kind,
        'target_type', v_target_type,
        'enabled_types', v_types
    );
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION create_context_gap_candidate(
    p_scope_id uuid,
    p_source_item_id uuid,
    p_reason text,
    p_statement text DEFAULT NULL,
    p_suggested_action text DEFAULT 'review_context_or_scope',
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_candidate_id uuid;
    v_context_id uuid;
    v_context_key text := 'needs_context';
    v_context_label text := 'Needs Context';
    v_holding_claim jsonb;
    v_reason text;
    v_statement text;
BEGIN
    v_reason := coalesce(nullif(trim(p_reason), ''), 'unmatched_expected_context');

    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = p_scope_id
          AND node_type = 'onboarding_scope'
          AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Onboarding scope % not found', p_scope_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = p_source_item_id
          AND node_type = 'source_item'
          AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Source item % not found', p_source_item_id;
    END IF;

    SELECT claim INTO v_holding_claim
    FROM current_valid_assertions
    WHERE subject_node_id = p_scope_id
      AND assertion_type = 'holding_context'
      AND assertion_key = 'default'
    LIMIT 1;

    v_context_key := coalesce(v_holding_claim->>'context_id', v_context_key);
    v_context_label := coalesce(v_holding_claim->>'label', v_context_label);

    INSERT INTO nodes (node_type, label, external_id, external_source, properties)
    VALUES (
        'review_context',
        v_context_label,
        v_context_key,
        'rye_onboarding_holding_context',
        jsonb_build_object('context_id', v_context_key, 'purpose', 'Hold source items needing context review.')
    )
    ON CONFLICT (external_source, external_id)
        WHERE external_id IS NOT NULL AND archived_at IS NULL
    DO UPDATE
        SET label = EXCLUDED.label,
            properties = nodes.properties || EXCLUDED.properties,
            updated_at = now()
    RETURNING id INTO v_context_id;

    INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
    SELECT
        'reviewed_under',
        p_source_item_id,
        v_context_id,
        jsonb_build_object(
            'reason_type', 'context_gap',
            'context_gap_reason', v_reason,
            'scope_id', p_scope_id
        ),
        jsonb_build_object('scope_id', p_scope_id)
    WHERE NOT EXISTS (
        SELECT 1
        FROM edges
        WHERE edge_type = 'reviewed_under'
          AND source_id = p_source_item_id
          AND target_id = v_context_id
          AND archived_at IS NULL
          AND properties->>'reason_type' = 'context_gap'
          AND properties->>'context_gap_reason' = v_reason
          AND properties->>'scope_id' = p_scope_id::text
    );

    v_statement := coalesce(
        nullif(trim(p_statement), ''),
        format('Source item %s does not match expected contexts for onboarding scope %s.', p_source_item_id, p_scope_id)
    );

    v_candidate_id := create_knowledge_candidate(
        p_candidate_kind  := 'context_gap',
        p_statement       := v_statement,
        p_target_payload  := jsonb_build_object(
            'scope_id', p_scope_id,
            'source_item_id', p_source_item_id,
            'reason', v_reason,
            'suggested_action', p_suggested_action,
            'holding_context_id', v_context_id
        ),
        p_normalized_key  := 'context-gap:' || p_scope_id::text || ':' || p_source_item_id::text || ':' || v_reason,
        p_created_by      := p_actor,
        p_source_node_ids := ARRAY[p_source_item_id],
        p_confidence      := 1.0
    );

    INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
    VALUES (
        'scope_has_context_gap',
        p_scope_id,
        v_candidate_id,
        jsonb_build_object('reason', v_reason, 'source_item_id', p_source_item_id),
        jsonb_build_object('scope_id', p_scope_id)
    );

    RETURN v_candidate_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION propose_scope_revision_from_context_gap(
    p_scope_id uuid,
    p_reason text,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_event_id uuid;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = p_scope_id
          AND node_type = 'onboarding_scope'
          AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Onboarding scope % not found', p_scope_id;
    END IF;

    v_event_id := record_event(
        p_event_type        := 'scope_revision_proposed',
        p_summary           := 'Scope revision proposed from context gap',
        p_properties        := jsonb_build_object(
            'scope_id', p_scope_id,
            'reason', coalesce(nullif(trim(p_reason), ''), 'repeated_context_gap')
        ),
        p_participant_ids   := ARRAY[p_scope_id],
        p_participant_roles := ARRAY['scope'],
        p_actor             := p_actor
    );

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;
