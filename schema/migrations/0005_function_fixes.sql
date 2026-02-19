-- Function fixes: agent_node_summary inbound edges, node_context performance,
-- create_opportunity event, merge_nodes event, matview refresh, bulk link,
-- CDC PK handling, link_record consistency

-- ============================================================================
-- 1. AGENT_NODE_SUMMARY — Add inbound relationships
-- ============================================================================
-- The original only showed outbound edges (source_id = p_node_id). If a person
-- is employed via org --employs--> person, querying from the person's side
-- returned nothing. Now includes both outbound and inbound sections.

CREATE OR REPLACE FUNCTION agent_node_summary(
    p_node_id uuid,
    p_max_items int DEFAULT 10
) RETURNS jsonb AS $$
SELECT jsonb_build_object(
    'node', (SELECT row_to_json(n) FROM nodes n WHERE n.id = p_node_id),

    'top_relationships', (
        SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
        FROM (
            SELECT
                e.edge_type,
                'outbound' AS direction,
                e.properties,
                e.weight,
                nt.label AS related_label,
                nt.node_type AS related_type,
                nt.id AS related_id
            FROM edges e
            JOIN nodes nt ON nt.id = e.target_id
            WHERE e.source_id = p_node_id
              AND e.archived_at IS NULL
            UNION ALL
            SELECT
                e.edge_type,
                'inbound' AS direction,
                e.properties,
                e.weight,
                ns.label AS related_label,
                ns.node_type AS related_type,
                ns.id AS related_id
            FROM edges e
            JOIN nodes ns ON ns.id = e.source_id
            WHERE e.target_id = p_node_id
              AND e.archived_at IS NULL
            ORDER BY weight DESC NULLS LAST
            LIMIT p_max_items
        ) r
    ),

    'current_facts', (
        SELECT coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb)
        FROM (
            SELECT
                a.assertion_type,
                a.assertion_key,
                a.claim,
                a.confidence,
                a.asserted_at
            FROM current_assertions a
            WHERE a.subject_node_id = p_node_id
            ORDER BY a.confidence DESC NULLS LAST, a.asserted_at DESC
            LIMIT p_max_items
        ) a
    ),

    'recent_activity', (
        SELECT coalesce(jsonb_agg(to_jsonb(ev)), '[]'::jsonb)
        FROM (
            SELECT
                e.event_type,
                e.summary,
                e.occurred_at,
                ep.role
            FROM events e
            JOIN event_participants ep ON ep.event_id = e.id
            WHERE ep.node_id = p_node_id
            ORDER BY e.occurred_at DESC
            LIMIT p_max_items
        ) ev
    )
);
$$ LANGUAGE sql STABLE;


-- ============================================================================
-- 2. NODE_CONTEXT — Rewrite to eliminate Cartesian product
-- ============================================================================
-- The original used three LEFT JOINs (outbound × inbound × assertions)
-- producing explosive intermediate rows before DISTINCT. Rewritten with
-- correlated subqueries so each dimension is aggregated independently.

CREATE OR REPLACE VIEW node_context
WITH (security_invoker = true) AS
SELECT
    n.id AS node_id,
    n.node_type,
    n.label,
    n.properties,
    (
        SELECT coalesce(json_agg(jsonb_build_object(
            'edge_id', eo.id,
            'edge_type', eo.edge_type,
            'target_id', eo.target_id,
            'properties', eo.properties
        )), '[]'::json)
        FROM edges eo
        WHERE eo.source_id = n.id AND eo.archived_at IS NULL
    ) AS outbound_edges,
    (
        SELECT coalesce(json_agg(jsonb_build_object(
            'edge_id', ei.id,
            'edge_type', ei.edge_type,
            'source_id', ei.source_id,
            'properties', ei.properties
        )), '[]'::json)
        FROM edges ei
        WHERE ei.target_id = n.id AND ei.archived_at IS NULL
    ) AS inbound_edges,
    (
        SELECT coalesce(json_agg(jsonb_build_object(
            'assertion_id', a.id,
            'assertion_type', a.assertion_type,
            'assertion_key', a.assertion_key,
            'claim', a.claim,
            'asserted_at', a.asserted_at,
            'confidence', a.confidence
        )), '[]'::json)
        FROM current_assertions a
        WHERE a.subject_node_id = n.id
    ) AS current_assertions
FROM nodes n
WHERE n.archived_at IS NULL;


-- ============================================================================
-- 3. CREATE_OPPORTUNITY — Add creation event
-- ============================================================================
-- create_task() records task_created but create_opportunity() did not.
-- Now records an opportunity_created event for audit trail consistency.

CREATE OR REPLACE FUNCTION create_opportunity(
    p_name text,
    p_pipeline_code text,
    p_assigned_to_id uuid,
    p_properties jsonb DEFAULT '{}',
    p_teams text[] DEFAULT '{}'
) RETURNS uuid AS $$
DECLARE
    v_opp_id uuid;
    v_code text;
    v_pipeline_id uuid;
    v_default_stage text;
BEGIN
    v_code := generate_crm_code('OPP');

    SELECT id, properties->>'default_stage'
    INTO v_pipeline_id, v_default_stage
    FROM nodes
    WHERE node_type = 'pipeline'
      AND properties->>'code' = p_pipeline_code
      AND archived_at IS NULL
    LIMIT 1;

    IF v_pipeline_id IS NULL THEN
        RAISE EXCEPTION 'Pipeline with code % not found', p_pipeline_code;
    END IF;

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES (
        'opportunity',
        p_name,
        p_properties || jsonb_build_object('name', p_name, 'code', v_code),
        jsonb_build_object('teams', to_jsonb(p_teams))
        || CASE WHEN array_length(p_teams, 1) > 0
                THEN jsonb_build_object('classification', 'internal')
                ELSE '{}'::jsonb
           END,
        v_code,
        'internal'
    )
    RETURNING id INTO v_opp_id;

    INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
    VALUES (
        'deal_stage',
        'default',
        v_opp_id,
        jsonb_build_object('stage', v_default_stage, 'pipeline', p_pipeline_code),
        1.0
    );

    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES (
        'pipeline_member',
        v_opp_id,
        v_pipeline_id,
        jsonb_build_object('entered_at', now())
    );

    IF p_assigned_to_id IS NOT NULL THEN
        INSERT INTO edges (edge_type, source_id, target_id, properties, effective_from)
        VALUES ('assigned_to', v_opp_id, p_assigned_to_id, '{"role": "owner"}', now());
    END IF;

    -- Record creation event (parallel to create_task's task_created)
    PERFORM record_event(
        p_event_type        := 'opportunity_created',
        p_summary           := format('Created %s: %s', v_code, p_name),
        p_properties        := jsonb_build_object(
            'opp_code', v_code,
            'pipeline', p_pipeline_code,
            'initial_stage', v_default_stage
        ),
        p_participant_ids   := ARRAY[v_opp_id],
        p_participant_roles := ARRAY['subject']
    );

    RETURN v_opp_id;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 4. MERGE_NODES — Add audit event
-- ============================================================================
-- merge_nodes() tracked merges in node_merges but not in the event log.
-- Now records a node_merge event so agents see merges in timelines.

CREATE OR REPLACE FUNCTION merge_nodes(
    p_duplicate_id uuid,
    p_canonical_id uuid,
    p_merged_by text DEFAULT 'system'
) RETURNS void AS $$
DECLARE
    v_dupe nodes;
    v_canon nodes;
    v_assertion assertions;
    v_replacement_id uuid;
BEGIN
    IF p_duplicate_id = p_canonical_id THEN
        RAISE EXCEPTION 'duplicate_id and canonical_id must be different';
    END IF;

    SELECT * INTO v_dupe FROM nodes WHERE id = p_duplicate_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Duplicate node % not found', p_duplicate_id;
    END IF;

    SELECT * INTO v_canon FROM nodes WHERE id = p_canonical_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Canonical node % not found', p_canonical_id;
    END IF;

    IF v_dupe.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'Duplicate node % is already archived', p_duplicate_id;
    END IF;

    INSERT INTO node_merges (duplicate_id, canonical_id, merged_by)
    VALUES (p_duplicate_id, p_canonical_id, p_merged_by);

    -- Record merge event BEFORE redirecting participations,
    -- so both nodes are still valid participants
    PERFORM record_event(
        p_event_type        := 'node_merge',
        p_summary           := format('Merged "%s" into "%s"', v_dupe.label, v_canon.label),
        p_properties        := jsonb_build_object(
            'duplicate_id', p_duplicate_id,
            'canonical_id', p_canonical_id,
            'duplicate_label', v_dupe.label,
            'canonical_label', v_canon.label,
            'duplicate_type', v_dupe.node_type,
            'merged_by', p_merged_by
        ),
        p_participant_ids   := ARRAY[p_canonical_id, p_duplicate_id],
        p_participant_roles := ARRAY['canonical', 'duplicate'],
        p_actor             := p_merged_by
    );

    UPDATE edges
    SET source_id = p_canonical_id
    WHERE source_id = p_duplicate_id
      AND target_id <> p_canonical_id;

    UPDATE edges
    SET target_id = p_canonical_id
    WHERE target_id = p_duplicate_id
      AND source_id <> p_canonical_id;

    UPDATE edges
    SET archived_at = now()
    WHERE source_id = p_canonical_id
      AND target_id = p_canonical_id
      AND archived_at IS NULL;

    FOR v_assertion IN
        SELECT *
        FROM assertions
        WHERE subject_node_id = p_duplicate_id
          AND superseded_at IS NULL
    LOOP
        SELECT id
        INTO v_replacement_id
        FROM assertions
        WHERE subject_node_id = p_canonical_id
          AND assertion_type = v_assertion.assertion_type
          AND assertion_key = v_assertion.assertion_key
          AND superseded_at IS NULL
        LIMIT 1;

        IF v_replacement_id IS NULL THEN
            INSERT INTO assertions (
                assertion_type,
                assertion_key,
                subject_node_id,
                subject_edge_id,
                claim,
                effective_at,
                source_event_id,
                confidence,
                attrs
            ) VALUES (
                v_assertion.assertion_type,
                v_assertion.assertion_key,
                p_canonical_id,
                v_assertion.subject_edge_id,
                v_assertion.claim,
                v_assertion.effective_at,
                v_assertion.source_event_id,
                v_assertion.confidence,
                v_assertion.attrs
            )
            RETURNING id INTO v_replacement_id;
        END IF;

        PERFORM mark_assertion_superseded(v_assertion.id, v_replacement_id);
    END LOOP;

    UPDATE event_participants
    SET node_id = p_canonical_id
    WHERE node_id = p_duplicate_id
      AND NOT EXISTS (
          SELECT 1
          FROM event_participants ep2
          WHERE ep2.event_id = event_participants.event_id
            AND ep2.node_id = p_canonical_id
            AND ep2.role = event_participants.role
      );

    DELETE FROM event_participants
    WHERE node_id = p_duplicate_id;

    UPDATE artifacts
    SET source_node_id = p_canonical_id
    WHERE source_node_id = p_duplicate_id;

    UPDATE artifacts
    SET related_node_ids = array_replace(related_node_ids, p_duplicate_id, p_canonical_id)
    WHERE p_duplicate_id = ANY(related_node_ids);

    DELETE FROM node_source_map nsm_dup
    WHERE nsm_dup.node_id = p_duplicate_id
      AND EXISTS (
          SELECT 1
          FROM node_source_map nsm_can
          WHERE nsm_can.node_id = p_canonical_id
            AND nsm_can.source_schema = nsm_dup.source_schema
            AND nsm_can.source_table = nsm_dup.source_table
      );

    UPDATE node_source_map
    SET node_id = p_canonical_id
    WHERE node_id = p_duplicate_id;

    UPDATE nodes
    SET properties = (SELECT properties FROM nodes WHERE id = p_duplicate_id) || properties,
        updated_at = now()
    WHERE id = p_canonical_id;

    UPDATE nodes
    SET archived_at = now(),
        updated_at = now()
    WHERE id = p_duplicate_id;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 5. REFRESH_MATERIALIZED_VIEWS
-- ============================================================================
-- Convenience function to refresh all profile materialized views.
-- Uses CONCURRENTLY when the unique index exists (allows reads during refresh).

CREATE OR REPLACE FUNCTION refresh_materialized_views() RETURNS void AS $$
BEGIN
    -- Only refresh views that exist (profiles may not be installed)
    IF EXISTS (SELECT 1 FROM pg_matviews WHERE matviewname = 'opportunities_active') THEN
        REFRESH MATERIALIZED VIEW CONCURRENTLY opportunities_active;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_matviews WHERE matviewname = 'contacts_directory') THEN
        REFRESH MATERIALIZED VIEW CONCURRENTLY contacts_directory;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_matviews WHERE matviewname = 'task_board') THEN
        REFRESH MATERIALIZED VIEW CONCURRENTLY task_board;
    END IF;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 6. LINK_RECORDS_BATCH — Bulk domain table import
-- ============================================================================
-- Processes multiple link_record calls in a single function call.
-- Accepts parallel arrays for each parameter.

CREATE OR REPLACE FUNCTION link_records_batch(
    p_source_schema text,
    p_source_table text,
    p_source_ids text[],
    p_node_type text,
    p_labels text[],
    p_properties jsonb[] DEFAULT NULL,
    p_source_id_type text DEFAULT 'int'
) RETURNS uuid[] AS $$
DECLARE
    v_count int;
    v_result uuid[] := '{}';
    v_node_id uuid;
    v_props jsonb;
    i int;
BEGIN
    v_count := coalesce(array_length(p_source_ids, 1), 0);

    IF coalesce(array_length(p_labels, 1), 0) <> v_count THEN
        RAISE EXCEPTION 'source_ids and labels must have the same length';
    END IF;

    IF p_properties IS NOT NULL AND coalesce(array_length(p_properties, 1), 0) <> v_count THEN
        RAISE EXCEPTION 'properties array must match source_ids length when provided';
    END IF;

    FOR i IN 1..v_count LOOP
        v_props := CASE
            WHEN p_properties IS NOT NULL THEN coalesce(p_properties[i], '{}'::jsonb)
            ELSE '{}'::jsonb
        END;

        v_node_id := link_record(
            p_source_schema  := p_source_schema,
            p_source_table   := p_source_table,
            p_source_id      := p_source_ids[i],
            p_node_type      := p_node_type,
            p_label          := p_labels[i],
            p_properties     := v_props,
            p_source_id_type := p_source_id_type
        );

        v_result := v_result || v_node_id;
    END LOOP;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 7. CDC — Handle non-id primary keys
-- ============================================================================
-- The original capture_domain_change() used OLD.id::text / NEW.id::text,
-- failing on tables without an "id" column. The new version looks up the
-- source_id from node_source_map using dynamic column access, or falls
-- back to the table's actual primary key column.

CREATE OR REPLACE FUNCTION capture_domain_change() RETURNS trigger AS $$
DECLARE
    v_node_id uuid;
    v_change_type text;
    v_old_data jsonb;
    v_new_data jsonb;
    v_record_id text;
    v_pk_col text;
BEGIN
    -- Determine the record identifier:
    -- 1. Try the 'id' column (most common)
    -- 2. Fall back to looking up from node_source_map via primary key
    v_old_data := CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END;
    v_new_data := CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END;

    -- Use the row data to find the record_id from the appropriate column
    IF TG_OP = 'DELETE' THEN
        -- For DELETE, try 'id' field from OLD row
        v_record_id := v_old_data->>'id';
        IF v_record_id IS NULL THEN
            -- Look up the PK column from pg_index
            SELECT a.attname INTO v_pk_col
            FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME)::regclass
              AND i.indisprimary
            LIMIT 1;

            IF v_pk_col IS NOT NULL THEN
                v_record_id := v_old_data->>v_pk_col;
            END IF;
        END IF;
    ELSE
        v_record_id := v_new_data->>'id';
        IF v_record_id IS NULL THEN
            SELECT a.attname INTO v_pk_col
            FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME)::regclass
              AND i.indisprimary
            LIMIT 1;

            IF v_pk_col IS NOT NULL THEN
                v_record_id := v_new_data->>v_pk_col;
            END IF;
        END IF;
    END IF;

    IF v_record_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    SELECT node_id INTO v_node_id
    FROM node_source_map
    WHERE source_schema = TG_TABLE_SCHEMA
      AND source_table = TG_TABLE_NAME
      AND source_id = v_record_id;

    -- No graph node mapped; skip silently
    IF v_node_id IS NULL THEN RETURN COALESCE(NEW, OLD); END IF;

    v_change_type := lower(TG_OP);

    PERFORM record_event(
        p_event_type        := 'domain_change',
        p_summary           := format('%s.%s %s (record %s)', TG_TABLE_SCHEMA, TG_TABLE_NAME, v_change_type, v_record_id),
        p_properties        := jsonb_build_object(
            'schema', TG_TABLE_SCHEMA,
            'table', TG_TABLE_NAME,
            'operation', v_change_type,
            'record_id', v_record_id,
            'old', v_old_data,
            'new', v_new_data,
            'changed_fields', CASE
                WHEN TG_OP = 'UPDATE' THEN (
                    SELECT jsonb_object_agg(key, jsonb_build_object('old', v_old_data->key, 'new', value))
                    FROM jsonb_each(v_new_data)
                    WHERE v_old_data->key IS DISTINCT FROM v_new_data->key
                )
                ELSE NULL
            END
        ),
        p_participant_ids   := ARRAY[v_node_id],
        p_participant_roles := ARRAY['subject'],
        p_actor             := 'system:cdc'
    );

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 8. LINK_RECORD — Ensure dual storage consistency
-- ============================================================================
-- The node_source_map upsert uses ON CONFLICT on (node_id, source_schema,
-- source_table) but link_record looks up by external_id/external_source.
-- Add a unique index on node_source_map(source_schema, source_table, source_id)
-- to prevent orphaned mappings, and add a cross-check to link_record.

CREATE UNIQUE INDEX IF NOT EXISTS idx_nsm_source_unique
    ON node_source_map (source_schema, source_table, source_id);

CREATE OR REPLACE FUNCTION link_record(
    p_source_schema text,
    p_source_table text,
    p_source_id text,
    p_node_type text,
    p_label text,
    p_properties jsonb DEFAULT '{}',
    p_source_id_type text DEFAULT 'int'
) RETURNS uuid AS $$
DECLARE
    v_node_id uuid;
    v_ext_source text;
BEGIN
    v_ext_source := p_source_schema || '.' || p_source_table;

    -- Check node_source_map first (canonical lookup path).
    -- This catches cases where the source map was created manually
    -- without setting external_id on the node.
    SELECT node_id INTO v_node_id
    FROM node_source_map
    WHERE source_schema = p_source_schema
      AND source_table = p_source_table
      AND source_id = p_source_id;

    -- Fall back to external_id/source on nodes table
    IF v_node_id IS NULL THEN
        SELECT id INTO v_node_id
        FROM nodes
        WHERE external_id = p_source_id
          AND external_source = v_ext_source
          AND archived_at IS NULL;
    END IF;

    IF v_node_id IS NOT NULL THEN
        -- Update properties on existing node
        UPDATE nodes
        SET properties = properties || p_properties,
            label = coalesce(p_label, label)
        WHERE id = v_node_id;
    ELSE
        INSERT INTO nodes (node_type, label, external_id, external_source, properties)
        VALUES (p_node_type, p_label, p_source_id, v_ext_source, p_properties)
        RETURNING id INTO v_node_id;
    END IF;

    -- Upsert source map
    INSERT INTO node_source_map (node_id, source_schema, source_table, source_id, source_id_type)
    VALUES (v_node_id, p_source_schema, p_source_table, p_source_id, p_source_id_type)
    ON CONFLICT (node_id, source_schema, source_table) DO UPDATE
        SET source_id = p_source_id, synced_at = now();

    RETURN v_node_id;
END;
$$ LANGUAGE plpgsql;
