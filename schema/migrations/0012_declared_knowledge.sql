-- Declared knowledge: accountable recurring statements from interviews,
-- sitreps, reviews, forms, or declared reports.
--
-- This keeps the implementation on Rye primitives: nodes, edges, events,
-- artifacts, assertions, and knowledge candidates.

SET search_path = rye, pg_catalog, public;

CREATE INDEX IF NOT EXISTS idx_nodes_declared_series_active
    ON nodes (external_source, external_id)
    WHERE node_type = 'declared_knowledge_series' AND archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_nodes_declared_instance_active
    ON nodes (external_source, external_id)
    WHERE node_type = 'declared_knowledge_instance' AND archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_edges_declared_series_instance_active
    ON edges (source_id, edge_type, target_id)
    WHERE edge_type = 'series_has_instance' AND archived_at IS NULL;

CREATE OR REPLACE FUNCTION rye_append_participant(
    p_ids uuid[],
    p_roles text[],
    p_node_id uuid,
    p_role text
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
BEGIN
    IF p_node_id IS NULL THEN
        RETURN jsonb_build_object('ids', coalesce(p_ids, '{}'::uuid[]), 'roles', coalesce(p_roles, '{}'::text[]));
    END IF;

    RETURN jsonb_build_object(
        'ids', array_append(coalesce(p_ids, '{}'::uuid[]), p_node_id),
        'roles', array_append(coalesce(p_roles, '{}'::text[]), p_role)
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION create_declared_knowledge_series(
    p_series_key text,
    p_label text,
    p_purpose text,
    p_profile text DEFAULT 'sitrep',
    p_cadence jsonb DEFAULT '{}'::jsonb,
    p_scope_id uuid DEFAULT NULL,
    p_owner_node_id uuid DEFAULT NULL,
    p_actor text DEFAULT NULL,
    p_properties jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_actor text;
    v_event_id uuid;
    v_participants jsonb;
    v_roles text[] := ARRAY[]::text[];
    v_series_id uuid;
    v_series_key text;
    v_participant_ids uuid[] := ARRAY[]::uuid[];
BEGIN
    v_series_key := nullif(trim(p_series_key), '');
    v_actor := coalesce(p_actor, current_setting('app.current_user_id', true));

    IF v_series_key IS NULL THEN
        RAISE EXCEPTION 'series_key is required';
    END IF;

    IF nullif(trim(p_label), '') IS NULL THEN
        RAISE EXCEPTION 'label is required';
    END IF;

    IF nullif(trim(p_purpose), '') IS NULL THEN
        RAISE EXCEPTION 'purpose is required';
    END IF;

    IF p_scope_id IS NOT NULL
       AND NOT EXISTS (
           SELECT 1
           FROM nodes
           WHERE id = p_scope_id
             AND node_type = 'onboarding_scope'
             AND archived_at IS NULL
       )
    THEN
        RAISE EXCEPTION 'Onboarding scope % not found', p_scope_id;
    END IF;

    IF p_owner_node_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM nodes WHERE id = p_owner_node_id AND archived_at IS NULL)
    THEN
        RAISE EXCEPTION 'Owner node % not found', p_owner_node_id;
    END IF;

    INSERT INTO nodes (node_type, label, external_source, external_id, properties, attrs)
    VALUES (
        'declared_knowledge_series',
        p_label,
        'rye_declared_knowledge_series',
        v_series_key,
        coalesce(p_properties, '{}'::jsonb) || jsonb_build_object(
            'series_key', v_series_key,
            'purpose', p_purpose,
            'profile', coalesce(nullif(trim(p_profile), ''), 'sitrep'),
            'cadence', coalesce(p_cadence, '{}'::jsonb),
            'scope_id', p_scope_id,
            'owner_node_id', p_owner_node_id,
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
    RETURNING id INTO v_series_id;

    IF p_scope_id IS NOT NULL THEN
        INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
        SELECT
            'scope_uses_declared_series',
            p_scope_id,
            v_series_id,
            jsonb_build_object('series_key', v_series_key, 'created_by', v_actor),
            jsonb_build_object('series_key', v_series_key)
        WHERE NOT EXISTS (
            SELECT 1
            FROM edges
            WHERE edge_type = 'scope_uses_declared_series'
              AND source_id = p_scope_id
              AND target_id = v_series_id
              AND archived_at IS NULL
        );
    END IF;

    IF p_owner_node_id IS NOT NULL THEN
        INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
        SELECT
            'declared_series_owned_by',
            v_series_id,
            p_owner_node_id,
            jsonb_build_object('series_key', v_series_key, 'created_by', v_actor),
            jsonb_build_object('series_key', v_series_key)
        WHERE NOT EXISTS (
            SELECT 1
            FROM edges
            WHERE edge_type = 'declared_series_owned_by'
              AND source_id = v_series_id
              AND target_id = p_owner_node_id
              AND archived_at IS NULL
        );
    END IF;

    v_participant_ids := ARRAY[v_series_id];
    v_roles := ARRAY['declared_knowledge_series'];
    v_participants := rye_append_participant(v_participant_ids, v_roles, p_scope_id, 'scope');
    v_participant_ids := ARRAY(SELECT jsonb_array_elements_text(v_participants->'ids')::uuid);
    v_roles := ARRAY(SELECT jsonb_array_elements_text(v_participants->'roles'));
    v_participants := rye_append_participant(v_participant_ids, v_roles, p_owner_node_id, 'owner');
    v_participant_ids := ARRAY(SELECT jsonb_array_elements_text(v_participants->'ids')::uuid);
    v_roles := ARRAY(SELECT jsonb_array_elements_text(v_participants->'roles'));

    v_event_id := record_event(
        p_event_type        := 'declared_knowledge_series_created',
        p_summary           := format('Declared knowledge series created: %s', left(p_label, 120)),
        p_properties        := jsonb_build_object(
            'series_id', v_series_id,
            'series_key', v_series_key,
            'purpose', p_purpose,
            'profile', coalesce(nullif(trim(p_profile), ''), 'sitrep'),
            'cadence', coalesce(p_cadence, '{}'::jsonb),
            'scope_id', p_scope_id,
            'owner_node_id', p_owner_node_id
        ),
        p_participant_ids   := v_participant_ids,
        p_participant_roles := v_roles,
        p_actor             := v_actor
    );

    PERFORM record_assertion(
        p_assertion_type  := 'declared_series_purpose',
        p_assertion_key   := 'default',
        p_subject_node_id := v_series_id,
        p_claim           := jsonb_build_object('purpose', p_purpose),
        p_source_event_id := v_event_id,
        p_confidence      := 1.0,
        p_mode            := 'current',
        p_attrs           := jsonb_build_object('declared_series_event_id', v_event_id)
    );

    PERFORM record_assertion(
        p_assertion_type  := 'declared_series_profile',
        p_assertion_key   := 'default',
        p_subject_node_id := v_series_id,
        p_claim           := jsonb_build_object('profile', coalesce(nullif(trim(p_profile), ''), 'sitrep')),
        p_source_event_id := v_event_id,
        p_confidence      := 1.0,
        p_mode            := 'current',
        p_attrs           := jsonb_build_object('declared_series_event_id', v_event_id)
    );

    PERFORM record_assertion(
        p_assertion_type  := 'declared_series_cadence',
        p_assertion_key   := 'default',
        p_subject_node_id := v_series_id,
        p_claim           := coalesce(p_cadence, '{}'::jsonb),
        p_source_event_id := v_event_id,
        p_confidence      := 1.0,
        p_mode            := 'current',
        p_attrs           := jsonb_build_object('declared_series_event_id', v_event_id)
    );

    RETURN v_series_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_declared_knowledge_instance(
    p_series_id uuid,
    p_title text DEFAULT NULL,
    p_summary text DEFAULT NULL,
    p_instance_key text DEFAULT NULL,
    p_declarer_node_id uuid DEFAULT NULL,
    p_source_item_id uuid DEFAULT NULL,
    p_retrieval_channel_id uuid DEFAULT NULL,
    p_artifact_id uuid DEFAULT NULL,
    p_occurred_at timestamptz DEFAULT now(),
    p_actor text DEFAULT NULL,
    p_properties jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_actor text;
    v_event_id uuid;
    v_instance_id uuid;
    v_instance_key text;
    v_label text;
    v_participants jsonb;
    v_roles text[] := ARRAY[]::text[];
    v_series nodes;
    v_participant_ids uuid[] := ARRAY[]::uuid[];
BEGIN
    v_actor := coalesce(p_actor, current_setting('app.current_user_id', true));

    SELECT *
    INTO v_series
    FROM nodes
    WHERE id = p_series_id
      AND node_type = 'declared_knowledge_series'
      AND archived_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Declared knowledge series % not found', p_series_id;
    END IF;

    IF p_declarer_node_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM nodes WHERE id = p_declarer_node_id AND archived_at IS NULL)
    THEN
        RAISE EXCEPTION 'Declarer node % not found', p_declarer_node_id;
    END IF;

    IF p_source_item_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM nodes WHERE id = p_source_item_id AND archived_at IS NULL)
    THEN
        RAISE EXCEPTION 'Source item node % not found', p_source_item_id;
    END IF;

    IF p_retrieval_channel_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM nodes WHERE id = p_retrieval_channel_id AND archived_at IS NULL)
    THEN
        RAISE EXCEPTION 'Retrieval channel node % not found', p_retrieval_channel_id;
    END IF;

    IF p_artifact_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM artifacts WHERE id = p_artifact_id)
    THEN
        RAISE EXCEPTION 'Artifact % not found', p_artifact_id;
    END IF;

    v_instance_key := nullif(trim(p_instance_key), '');
    v_label := coalesce(nullif(trim(p_title), ''), format('%s - %s', v_series.label, to_char(coalesce(p_occurred_at, now()), 'YYYY-MM-DD HH24:MI')));

    IF v_instance_key IS NOT NULL THEN
        INSERT INTO nodes (node_type, label, external_source, external_id, properties, attrs)
        VALUES (
            'declared_knowledge_instance',
            v_label,
            'rye_declared_knowledge_instance',
            v_instance_key,
            coalesce(p_properties, '{}'::jsonb) || jsonb_build_object(
                'series_id', p_series_id,
                'series_key', v_series.external_id,
                'title', v_label,
                'summary', p_summary,
                'declarer_node_id', p_declarer_node_id,
                'source_item_id', p_source_item_id,
                'retrieval_channel_id', p_retrieval_channel_id,
                'artifact_id', p_artifact_id,
                'occurred_at', coalesce(p_occurred_at, now()),
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
        RETURNING id INTO v_instance_id;
    ELSE
        INSERT INTO nodes (node_type, label, properties, attrs)
        VALUES (
            'declared_knowledge_instance',
            v_label,
            coalesce(p_properties, '{}'::jsonb) || jsonb_build_object(
                'series_id', p_series_id,
                'series_key', v_series.external_id,
                'title', v_label,
                'summary', p_summary,
                'declarer_node_id', p_declarer_node_id,
                'source_item_id', p_source_item_id,
                'retrieval_channel_id', p_retrieval_channel_id,
                'artifact_id', p_artifact_id,
                'occurred_at', coalesce(p_occurred_at, now()),
                'created_by', v_actor
            ),
            jsonb_build_object('created_by', v_actor)
        )
        RETURNING id INTO v_instance_id;
    END IF;

    INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
    SELECT
        'series_has_instance',
        p_series_id,
        v_instance_id,
        jsonb_build_object('created_by', v_actor),
        jsonb_build_object('series_id', p_series_id)
    WHERE NOT EXISTS (
        SELECT 1
        FROM edges
        WHERE edge_type = 'series_has_instance'
          AND source_id = p_series_id
          AND target_id = v_instance_id
          AND archived_at IS NULL
    );

    IF p_declarer_node_id IS NOT NULL THEN
        INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
        SELECT 'declared_by', v_instance_id, p_declarer_node_id, jsonb_build_object('created_by', v_actor), '{}'::jsonb
        WHERE NOT EXISTS (
            SELECT 1 FROM edges
            WHERE edge_type = 'declared_by'
              AND source_id = v_instance_id
              AND target_id = p_declarer_node_id
              AND archived_at IS NULL
        );
    END IF;

    IF p_source_item_id IS NOT NULL THEN
        INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
        SELECT 'declared_from_source_item', v_instance_id, p_source_item_id, jsonb_build_object('created_by', v_actor), '{}'::jsonb
        WHERE NOT EXISTS (
            SELECT 1 FROM edges
            WHERE edge_type = 'declared_from_source_item'
              AND source_id = v_instance_id
              AND target_id = p_source_item_id
              AND archived_at IS NULL
        );
    END IF;

    IF p_retrieval_channel_id IS NOT NULL THEN
        INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
        SELECT 'retrieved_via', v_instance_id, p_retrieval_channel_id, jsonb_build_object('created_by', v_actor), '{}'::jsonb
        WHERE NOT EXISTS (
            SELECT 1 FROM edges
            WHERE edge_type = 'retrieved_via'
              AND source_id = v_instance_id
              AND target_id = p_retrieval_channel_id
              AND archived_at IS NULL
        );
    END IF;

    v_participant_ids := ARRAY[v_instance_id, p_series_id];
    v_roles := ARRAY['declared_knowledge_instance', 'declared_knowledge_series'];
    v_participants := rye_append_participant(v_participant_ids, v_roles, p_declarer_node_id, 'declarer');
    v_participant_ids := ARRAY(SELECT jsonb_array_elements_text(v_participants->'ids')::uuid);
    v_roles := ARRAY(SELECT jsonb_array_elements_text(v_participants->'roles'));
    v_participants := rye_append_participant(v_participant_ids, v_roles, p_source_item_id, 'source_item');
    v_participant_ids := ARRAY(SELECT jsonb_array_elements_text(v_participants->'ids')::uuid);
    v_roles := ARRAY(SELECT jsonb_array_elements_text(v_participants->'roles'));

    v_event_id := record_event(
        p_event_type        := 'declared_knowledge_received',
        p_summary           := format('Declared knowledge received: %s', left(v_label, 120)),
        p_properties        := jsonb_build_object(
            'series_id', p_series_id,
            'instance_id', v_instance_id,
            'summary', p_summary,
            'declarer_node_id', p_declarer_node_id,
            'source_item_id', p_source_item_id,
            'retrieval_channel_id', p_retrieval_channel_id,
            'artifact_id', p_artifact_id
        ),
        p_participant_ids   := v_participant_ids,
        p_participant_roles := v_roles,
        p_actor             := v_actor,
        p_occurred_at       := coalesce(p_occurred_at, now())
    );

    PERFORM record_assertion(
        p_assertion_type  := 'declared_instance_status',
        p_assertion_key   := 'default',
        p_subject_node_id := v_instance_id,
        p_claim           := jsonb_build_object('status', 'received'),
        p_source_event_id := v_event_id,
        p_confidence      := 1.0,
        p_mode            := 'current',
        p_attrs           := jsonb_build_object('declared_instance_event_id', v_event_id, 'series_id', p_series_id)
    );

    RETURN v_instance_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_declared_statement(
    p_instance_id uuid,
    p_statement text,
    p_statement_type text DEFAULT 'current_fact',
    p_target_payload jsonb DEFAULT '{}'::jsonb,
    p_confidence numeric DEFAULT NULL,
    p_review_required boolean DEFAULT true,
    p_candidate_kind text DEFAULT 'fact',
    p_subject_node_id uuid DEFAULT NULL,
    p_subject_edge_id uuid DEFAULT NULL,
    p_assertion_type text DEFAULT NULL,
    p_assertion_key text DEFAULT 'default',
    p_claim jsonb DEFAULT NULL,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_actor text;
    v_candidate_id uuid;
    v_candidate_kind text;
    v_event_id uuid;
    v_instance nodes;
    v_participants jsonb;
    v_roles text[] := ARRAY[]::text[];
    v_statement_id uuid;
    v_statement_type text;
    v_participant_ids uuid[] := ARRAY[]::uuid[];
BEGIN
    v_actor := coalesce(p_actor, current_setting('app.current_user_id', true));
    v_statement_type := coalesce(nullif(trim(p_statement_type), ''), 'current_fact');
    v_candidate_kind := lower(coalesce(nullif(trim(p_candidate_kind), ''), 'fact'));

    IF NOT (v_candidate_kind = ANY(ARRAY[
        'fact',
        'task',
        'edge',
        'decision',
        'procedure',
        'preference',
        'risk',
        'context_gap',
        'policy_change',
        'scope_change',
        'plugin_change',
        'dispute'
    ])) THEN
        v_candidate_kind := 'fact';
    END IF;

    IF nullif(trim(p_statement), '') IS NULL THEN
        RAISE EXCEPTION 'statement is required';
    END IF;

    IF p_confidence IS NOT NULL AND (p_confidence < 0 OR p_confidence > 1) THEN
        RAISE EXCEPTION 'confidence must be between 0 and 1';
    END IF;

    SELECT *
    INTO v_instance
    FROM nodes
    WHERE id = p_instance_id
      AND node_type = 'declared_knowledge_instance'
      AND archived_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Declared knowledge instance % not found', p_instance_id;
    END IF;

    IF p_subject_node_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM nodes WHERE id = p_subject_node_id AND archived_at IS NULL)
    THEN
        RAISE EXCEPTION 'Subject node % not found', p_subject_node_id;
    END IF;

    IF p_subject_edge_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM edges WHERE id = p_subject_edge_id AND archived_at IS NULL)
    THEN
        RAISE EXCEPTION 'Subject edge % not found', p_subject_edge_id;
    END IF;

    INSERT INTO nodes (node_type, label, properties, attrs)
    VALUES (
        'declared_statement',
        left(p_statement, 160),
        jsonb_build_object(
            'instance_id', p_instance_id,
            'series_id', v_instance.properties->>'series_id',
            'statement', p_statement,
            'statement_type', v_statement_type,
            'target_payload', coalesce(p_target_payload, '{}'::jsonb),
            'review_required', coalesce(p_review_required, true),
            'candidate_kind', v_candidate_kind,
            'subject_node_id', p_subject_node_id,
            'subject_edge_id', p_subject_edge_id,
            'assertion_type', nullif(trim(coalesce(p_assertion_type, '')), ''),
            'assertion_key', coalesce(nullif(trim(p_assertion_key), ''), 'default'),
            'claim', p_claim,
            'confidence', p_confidence,
            'created_by', v_actor
        ),
        jsonb_build_object('created_by', v_actor)
    )
    RETURNING id INTO v_statement_id;

    INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
    VALUES (
        'instance_has_statement',
        p_instance_id,
        v_statement_id,
        jsonb_build_object('statement_type', v_statement_type, 'created_by', v_actor),
        jsonb_build_object('instance_id', p_instance_id)
    );

    IF p_subject_node_id IS NOT NULL THEN
        INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
        VALUES (
            'statement_about_node',
            v_statement_id,
            p_subject_node_id,
            jsonb_build_object('statement_type', v_statement_type, 'created_by', v_actor),
            jsonb_build_object('instance_id', p_instance_id)
        );
    END IF;

    v_participant_ids := ARRAY[v_statement_id, p_instance_id];
    v_roles := ARRAY['declared_statement', 'declared_knowledge_instance'];
    v_participants := rye_append_participant(v_participant_ids, v_roles, p_subject_node_id, 'subject_node');
    v_participant_ids := ARRAY(SELECT jsonb_array_elements_text(v_participants->'ids')::uuid);
    v_roles := ARRAY(SELECT jsonb_array_elements_text(v_participants->'roles'));

    v_event_id := record_event(
        p_event_type        := 'declared_statement_recorded',
        p_summary           := format('Declared statement recorded: %s', left(p_statement, 120)),
        p_properties        := jsonb_build_object(
            'instance_id', p_instance_id,
            'statement_id', v_statement_id,
            'statement', p_statement,
            'statement_type', v_statement_type,
            'target_payload', coalesce(p_target_payload, '{}'::jsonb),
            'subject_node_id', p_subject_node_id,
            'subject_edge_id', p_subject_edge_id,
            'assertion_type', nullif(trim(coalesce(p_assertion_type, '')), ''),
            'assertion_key', coalesce(nullif(trim(p_assertion_key), ''), 'default'),
            'claim', p_claim
        ),
        p_participant_ids   := v_participant_ids,
        p_participant_roles := v_roles,
        p_actor             := v_actor
    );

    PERFORM record_assertion(
        p_assertion_type  := 'declared_statement_status',
        p_assertion_key   := 'default',
        p_subject_node_id := v_statement_id,
        p_claim           := jsonb_build_object(
            'status', CASE WHEN coalesce(p_review_required, true) THEN 'needs_review' ELSE 'captured' END,
            'review_required', coalesce(p_review_required, true)
        ),
        p_source_event_id := v_event_id,
        p_confidence      := 1.0,
        p_mode            := 'current',
        p_attrs           := jsonb_build_object('declared_statement_event_id', v_event_id, 'instance_id', p_instance_id)
    );

    IF coalesce(p_review_required, true) THEN
        v_candidate_id := create_knowledge_candidate(
            p_candidate_kind        := v_candidate_kind,
            p_statement             := p_statement,
            p_target_payload        := jsonb_build_object(
                'declared_statement_id', v_statement_id,
                'declared_instance_id', p_instance_id,
                'statement_type', v_statement_type,
                'target_payload', coalesce(p_target_payload, '{}'::jsonb),
                'subject_node_id', p_subject_node_id,
                'subject_edge_id', p_subject_edge_id,
                'assertion_type', nullif(trim(coalesce(p_assertion_type, '')), ''),
                'assertion_key', coalesce(nullif(trim(p_assertion_key), ''), 'default'),
                'claim', p_claim
            ),
            p_source_node_ids       := ARRAY[p_instance_id, v_statement_id],
            p_confidence            := p_confidence,
            p_created_by            := v_actor
        );

        INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
        VALUES (
            'statement_proposes_candidate',
            v_statement_id,
            v_candidate_id,
            jsonb_build_object('candidate_kind', v_candidate_kind, 'created_by', v_actor),
            jsonb_build_object('instance_id', p_instance_id)
        );
    END IF;

    RETURN v_statement_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_declared_node(
    p_statement_id uuid,
    p_node_type text,
    p_label text,
    p_properties jsonb DEFAULT '{}'::jsonb,
    p_external_source text DEFAULT NULL,
    p_external_id text DEFAULT NULL,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_actor text;
    v_event_id uuid;
    v_node_id uuid;
    v_statement nodes;
BEGIN
    v_actor := coalesce(p_actor, current_setting('app.current_user_id', true));

    SELECT *
    INTO v_statement
    FROM nodes
    WHERE id = p_statement_id
      AND node_type = 'declared_statement'
      AND archived_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Declared statement % not found', p_statement_id;
    END IF;

    IF nullif(trim(p_node_type), '') IS NULL THEN
        RAISE EXCEPTION 'node_type is required';
    END IF;

    IF nullif(trim(p_label), '') IS NULL THEN
        RAISE EXCEPTION 'label is required';
    END IF;

    INSERT INTO nodes (node_type, label, external_source, external_id, properties, attrs)
    VALUES (
        p_node_type,
        p_label,
        CASE WHEN nullif(trim(coalesce(p_external_id, '')), '') IS NULL THEN NULL ELSE coalesce(nullif(trim(p_external_source), ''), 'rye_declared_knowledge') END,
        nullif(trim(coalesce(p_external_id, '')), ''),
        coalesce(p_properties, '{}'::jsonb) || jsonb_build_object(
            'declared_statement_id', p_statement_id,
            'declared_instance_id', v_statement.properties->>'instance_id',
            'created_by', v_actor
        ),
        jsonb_build_object('created_by', v_actor, 'declared_statement_id', p_statement_id)
    )
    ON CONFLICT (external_source, external_id)
        WHERE external_id IS NOT NULL AND archived_at IS NULL
    DO UPDATE
        SET label = EXCLUDED.label,
            properties = nodes.properties || EXCLUDED.properties,
            updated_at = now()
    RETURNING id INTO v_node_id;

    INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
    SELECT
        'statement_created_node',
        p_statement_id,
        v_node_id,
        jsonb_build_object('created_by', v_actor),
        jsonb_build_object('declared_statement_id', p_statement_id)
    WHERE NOT EXISTS (
        SELECT 1
        FROM edges
        WHERE edge_type = 'statement_created_node'
          AND source_id = p_statement_id
          AND target_id = v_node_id
          AND archived_at IS NULL
    );

    v_event_id := record_event(
        p_event_type        := 'declared_node_created',
        p_summary           := format('Declared statement created node: %s', left(p_label, 120)),
        p_properties        := jsonb_build_object(
            'statement_id', p_statement_id,
            'node_id', v_node_id,
            'node_type', p_node_type
        ),
        p_participant_ids   := ARRAY[p_statement_id, v_node_id],
        p_participant_roles := ARRAY['declared_statement', 'created_node'],
        p_actor             := v_actor
    );

    RETURN v_node_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_declared_edge(
    p_statement_id uuid,
    p_edge_type text,
    p_source_node_id uuid,
    p_target_node_id uuid,
    p_properties jsonb DEFAULT '{}'::jsonb,
    p_effective_from timestamptz DEFAULT NULL,
    p_effective_to timestamptz DEFAULT NULL,
    p_weight numeric DEFAULT 1.0,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_actor text;
    v_edge_id uuid;
    v_event_id uuid;
    v_statement nodes;
BEGIN
    v_actor := coalesce(p_actor, current_setting('app.current_user_id', true));

    SELECT *
    INTO v_statement
    FROM nodes
    WHERE id = p_statement_id
      AND node_type = 'declared_statement'
      AND archived_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Declared statement % not found', p_statement_id;
    END IF;

    IF nullif(trim(p_edge_type), '') IS NULL THEN
        RAISE EXCEPTION 'edge_type is required';
    END IF;

    IF p_effective_from IS NOT NULL
       AND p_effective_to IS NOT NULL
       AND p_effective_to <= p_effective_from
    THEN
        RAISE EXCEPTION 'effective_to must be after effective_from';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = p_source_node_id AND archived_at IS NULL) THEN
        RAISE EXCEPTION 'Source node % not found', p_source_node_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = p_target_node_id AND archived_at IS NULL) THEN
        RAISE EXCEPTION 'Target node % not found', p_target_node_id;
    END IF;

    SELECT id
    INTO v_edge_id
    FROM edges
    WHERE edge_type = p_edge_type
      AND source_id = p_source_node_id
      AND target_id = p_target_node_id
      AND archived_at IS NULL
    LIMIT 1;

    IF v_edge_id IS NULL THEN
        INSERT INTO edges (
            edge_type,
            source_id,
            target_id,
            properties,
            effective_from,
            effective_to,
            weight,
            attrs
        ) VALUES (
            p_edge_type,
            p_source_node_id,
            p_target_node_id,
            coalesce(p_properties, '{}'::jsonb) || jsonb_build_object(
                'declared_statement_id', p_statement_id,
                'declared_instance_id', v_statement.properties->>'instance_id',
                'created_by', v_actor
            ),
            p_effective_from,
            p_effective_to,
            p_weight,
            jsonb_build_object('created_by', v_actor, 'declared_statement_id', p_statement_id)
        )
        RETURNING id INTO v_edge_id;
    END IF;

    INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
    SELECT
        'statement_created_edge_source',
        p_statement_id,
        p_source_node_id,
        jsonb_build_object('created_edge_id', v_edge_id, 'created_by', v_actor),
        jsonb_build_object('created_edge_id', v_edge_id)
    WHERE NOT EXISTS (
        SELECT 1
        FROM edges
        WHERE edge_type = 'statement_created_edge_source'
          AND source_id = p_statement_id
          AND target_id = p_source_node_id
          AND properties->>'created_edge_id' = v_edge_id::text
          AND archived_at IS NULL
    );

    INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
    SELECT
        'statement_created_edge_target',
        p_statement_id,
        p_target_node_id,
        jsonb_build_object('created_edge_id', v_edge_id, 'created_by', v_actor),
        jsonb_build_object('created_edge_id', v_edge_id)
    WHERE NOT EXISTS (
        SELECT 1
        FROM edges
        WHERE edge_type = 'statement_created_edge_target'
          AND source_id = p_statement_id
          AND target_id = p_target_node_id
          AND properties->>'created_edge_id' = v_edge_id::text
          AND archived_at IS NULL
    );

    v_event_id := record_event(
        p_event_type        := 'declared_edge_created',
        p_summary           := format('Declared statement created edge: %s', p_edge_type),
        p_properties        := jsonb_build_object(
            'statement_id', p_statement_id,
            'edge_id', v_edge_id,
            'edge_type', p_edge_type,
            'source_node_id', p_source_node_id,
            'target_node_id', p_target_node_id
        ),
        p_participant_ids   := ARRAY[p_statement_id, p_source_node_id, p_target_node_id],
        p_participant_roles := ARRAY['declared_statement', 'edge_source', 'edge_target'],
        p_actor             := v_actor
    );

    RETURN v_edge_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION promote_declared_statement_to_assertion(
    p_statement_id uuid,
    p_assertion_type text,
    p_claim jsonb,
    p_subject_node_id uuid DEFAULT NULL,
    p_subject_edge_id uuid DEFAULT NULL,
    p_assertion_key text DEFAULT 'default',
    p_mode text DEFAULT 'current',
    p_effective_at timestamptz DEFAULT NULL,
    p_effective_to timestamptz DEFAULT NULL,
    p_confidence numeric DEFAULT NULL,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_actor text;
    v_assertion_id uuid;
    v_candidate_id uuid;
    v_event_id uuid;
    v_instance_id uuid;
    v_statement nodes;
    v_subject_edge_id uuid;
    v_subject_node_id uuid;
BEGIN
    v_actor := coalesce(p_actor, current_setting('app.current_user_id', true));

    SELECT *
    INTO v_statement
    FROM nodes
    WHERE id = p_statement_id
      AND node_type = 'declared_statement'
      AND archived_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Declared statement % not found', p_statement_id;
    END IF;

    IF nullif(trim(p_assertion_type), '') IS NULL THEN
        RAISE EXCEPTION 'assertion_type is required';
    END IF;

    IF p_claim IS NULL THEN
        RAISE EXCEPTION 'claim is required';
    END IF;

    v_subject_node_id := coalesce(p_subject_node_id, nullif(v_statement.properties->>'subject_node_id', '')::uuid);
    v_subject_edge_id := coalesce(p_subject_edge_id, nullif(v_statement.properties->>'subject_edge_id', '')::uuid);
    v_instance_id := nullif(v_statement.properties->>'instance_id', '')::uuid;

    IF (v_subject_node_id IS NULL) = (v_subject_edge_id IS NULL) THEN
        RAISE EXCEPTION 'Exactly one subject node or subject edge is required';
    END IF;

    IF v_subject_node_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM nodes WHERE id = v_subject_node_id AND archived_at IS NULL)
    THEN
        RAISE EXCEPTION 'Subject node % not found', v_subject_node_id;
    END IF;

    IF v_subject_edge_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM edges WHERE id = v_subject_edge_id AND archived_at IS NULL)
    THEN
        RAISE EXCEPTION 'Subject edge % not found', v_subject_edge_id;
    END IF;

    v_event_id := record_event(
        p_event_type        := 'declared_statement_promoted',
        p_summary           := format('Declared statement promoted to assertion: %s', p_assertion_type),
        p_properties        := jsonb_build_object(
            'statement_id', p_statement_id,
            'instance_id', v_instance_id,
            'assertion_type', p_assertion_type,
            'assertion_key', coalesce(nullif(trim(p_assertion_key), ''), 'default'),
            'subject_node_id', v_subject_node_id,
            'subject_edge_id', v_subject_edge_id,
            'claim', p_claim
        ),
        p_participant_ids   := CASE
            WHEN v_subject_node_id IS NOT NULL THEN ARRAY[p_statement_id, v_subject_node_id]
            ELSE ARRAY[p_statement_id]
        END,
        p_participant_roles := CASE
            WHEN v_subject_node_id IS NOT NULL THEN ARRAY['declared_statement', 'subject_node']
            ELSE ARRAY['declared_statement']
        END,
        p_actor             := v_actor
    );

    v_assertion_id := record_assertion(
        p_assertion_type    := p_assertion_type,
        p_assertion_key     := p_assertion_key,
        p_subject_node_id   := v_subject_node_id,
        p_subject_edge_id   := v_subject_edge_id,
        p_claim             := p_claim,
        p_effective_at      := p_effective_at,
        p_effective_to      := p_effective_to,
        p_source_event_id   := v_event_id,
        p_confidence        := coalesce(p_confidence, (v_statement.properties->>'confidence')::numeric),
        p_mode              := p_mode,
        p_attrs             := jsonb_build_object(
            'declared_statement_id', p_statement_id,
            'declared_instance_id', v_instance_id,
            'promotion_event_id', v_event_id
        )
    );

    PERFORM record_assertion(
        p_assertion_type  := 'declared_statement_status',
        p_assertion_key   := 'default',
        p_subject_node_id := p_statement_id,
        p_claim           := jsonb_build_object(
            'status', 'promoted',
            'assertion_id', v_assertion_id,
            'assertion_type', p_assertion_type,
            'assertion_key', coalesce(nullif(trim(p_assertion_key), ''), 'default')
        ),
        p_source_event_id := v_event_id,
        p_confidence      := 1.0,
        p_mode            := 'current',
        p_attrs           := jsonb_build_object('declared_statement_event_id', v_event_id, 'instance_id', v_instance_id)
    );

    SELECT e.target_id
    INTO v_candidate_id
    FROM edges e
    JOIN nodes c ON c.id = e.target_id
    WHERE e.source_id = p_statement_id
      AND e.edge_type = 'statement_proposes_candidate'
      AND e.archived_at IS NULL
      AND c.node_type = 'knowledge_candidate'
      AND c.archived_at IS NULL
    ORDER BY e.created_at
    LIMIT 1;

    IF v_candidate_id IS NOT NULL THEN
        PERFORM set_candidate_status(v_candidate_id, 'accepted', 'Declared statement promoted to assertion', v_actor);
    END IF;

    RETURN v_assertion_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION declared_knowledge_summary(
    p_series_id uuid DEFAULT NULL
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
    SELECT jsonb_build_object(
        'series', coalesce(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'series_id', s.id,
                        'label', s.label,
                        'series_key', s.external_id,
                        'profile', s.properties->>'profile',
                        'purpose', s.properties->>'purpose',
                        'instances', (
                            SELECT count(*)
                            FROM edges e
                            JOIN nodes i ON i.id = e.target_id
                            WHERE e.source_id = s.id
                              AND e.edge_type = 'series_has_instance'
                              AND e.archived_at IS NULL
                              AND i.archived_at IS NULL
                        ),
                        'statements', (
                            SELECT count(*)
                            FROM edges ei
                            JOIN nodes i ON i.id = ei.target_id
                            JOIN edges es ON es.source_id = i.id
                            JOIN nodes st ON st.id = es.target_id
                            WHERE ei.source_id = s.id
                              AND ei.edge_type = 'series_has_instance'
                              AND ei.archived_at IS NULL
                              AND es.edge_type = 'instance_has_statement'
                              AND es.archived_at IS NULL
                              AND i.archived_at IS NULL
                              AND st.archived_at IS NULL
                        ),
                        'pending_statements', (
                            SELECT count(*)
                            FROM edges ei
                            JOIN nodes i ON i.id = ei.target_id
                            JOIN edges es ON es.source_id = i.id
                            JOIN nodes st ON st.id = es.target_id
                            JOIN current_valid_assertions a ON a.subject_node_id = st.id
                            WHERE ei.source_id = s.id
                              AND ei.edge_type = 'series_has_instance'
                              AND ei.archived_at IS NULL
                              AND es.edge_type = 'instance_has_statement'
                              AND es.archived_at IS NULL
                              AND a.assertion_type = 'declared_statement_status'
                              AND a.claim->>'status' = 'needs_review'
                              AND i.archived_at IS NULL
                              AND st.archived_at IS NULL
                        )
                    )
                    ORDER BY s.label
                )
                FROM nodes s
                WHERE s.node_type = 'declared_knowledge_series'
                  AND s.archived_at IS NULL
                  AND (p_series_id IS NULL OR s.id = p_series_id)
            ),
            '[]'::jsonb
        ),
        'totals', jsonb_build_object(
            'series', (
                SELECT count(*)
                FROM nodes s
                WHERE s.node_type = 'declared_knowledge_series'
                  AND s.archived_at IS NULL
                  AND (p_series_id IS NULL OR s.id = p_series_id)
            ),
            'instances', (
                SELECT count(*)
                FROM nodes i
                WHERE i.node_type = 'declared_knowledge_instance'
                  AND i.archived_at IS NULL
                  AND (
                      p_series_id IS NULL
                      OR EXISTS (
                          SELECT 1
                          FROM edges e
                          WHERE e.source_id = p_series_id
                            AND e.target_id = i.id
                            AND e.edge_type = 'series_has_instance'
                            AND e.archived_at IS NULL
                      )
                  )
            ),
            'statements', (
                SELECT count(*)
                FROM nodes st
                WHERE st.node_type = 'declared_statement'
                  AND st.archived_at IS NULL
                  AND (
                      p_series_id IS NULL
                      OR EXISTS (
                          SELECT 1
                          FROM edges ei
                          JOIN edges es ON es.source_id = ei.target_id
                          WHERE ei.source_id = p_series_id
                            AND ei.edge_type = 'series_has_instance'
                            AND ei.archived_at IS NULL
                            AND es.edge_type = 'instance_has_statement'
                            AND es.target_id = st.id
                            AND es.archived_at IS NULL
                      )
                  )
            )
        )
    );
$$ LANGUAGE sql STABLE;
