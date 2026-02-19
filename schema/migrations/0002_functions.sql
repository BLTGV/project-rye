-- Rye core functions and triggers

SET search_path = rye, pg_catalog, public;

CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_nodes_touch_updated_at ON nodes;
CREATE TRIGGER trg_nodes_touch_updated_at
    BEFORE UPDATE ON nodes
    FOR EACH ROW
    EXECUTE FUNCTION touch_updated_at();

CREATE OR REPLACE FUNCTION assertions_immutable_guard() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
BEGIN
    IF NEW.claim IS DISTINCT FROM OLD.claim
       OR NEW.assertion_type IS DISTINCT FROM OLD.assertion_type
       OR NEW.assertion_key IS DISTINCT FROM OLD.assertion_key
       OR NEW.subject_node_id IS DISTINCT FROM OLD.subject_node_id
       OR NEW.subject_edge_id IS DISTINCT FROM OLD.subject_edge_id
       OR NEW.asserted_at IS DISTINCT FROM OLD.asserted_at
       OR NEW.effective_at IS DISTINCT FROM OLD.effective_at
       OR NEW.source_event_id IS DISTINCT FROM OLD.source_event_id
       OR NEW.confidence IS DISTINCT FROM OLD.confidence
       OR NEW.attrs IS DISTINCT FROM OLD.attrs
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION
            'Assertion content is immutable. Only superseded_at and superseded_by may be updated.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_assertions_immutable ON assertions;
CREATE TRIGGER trg_assertions_immutable
    BEFORE UPDATE ON assertions
    FOR EACH ROW
    EXECUTE FUNCTION assertions_immutable_guard();

CREATE OR REPLACE FUNCTION mark_assertion_superseded(
    p_old_assertion_id uuid,
    p_new_assertion_id uuid
) RETURNS void
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_updated int;
BEGIN
    PERFORM set_config('app.write_path', 'supersede_assertion', true);
    PERFORM set_config('app.supersede_assertion_id', p_old_assertion_id::text, true);

    UPDATE assertions
    SET superseded_at = now(),
        superseded_by = p_new_assertion_id
    WHERE id = p_old_assertion_id
      AND superseded_at IS NULL;

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.supersede_assertion_id', '', true);

    IF v_updated <> 1 THEN
        RAISE EXCEPTION 'Failed to supersede assertion %, expected one active row', p_old_assertion_id;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION supersede_assertion(
    p_old_assertion_id uuid,
    p_new_assertion_type text,
    p_new_subject_node_id uuid,
    p_new_subject_edge_id uuid,
    p_new_claim jsonb,
    p_new_assertion_key text DEFAULT NULL,
    p_new_effective_at timestamptz DEFAULT NULL,
    p_new_source_event_id uuid DEFAULT NULL,
    p_new_confidence numeric DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_old assertions;
    v_new_id uuid;
    v_assertion_type text;
    v_assertion_key text;
    v_subject_node_id uuid;
    v_subject_edge_id uuid;
BEGIN
    PERFORM set_config('app.write_path', 'supersede_assertion', true);
    PERFORM set_config('app.supersede_assertion_id', p_old_assertion_id::text, true);

    SELECT *
    INTO v_old
    FROM assertions
    WHERE id = p_old_assertion_id
    FOR UPDATE;

    IF NOT FOUND THEN
        PERFORM set_config('app.write_path', '', true);
        PERFORM set_config('app.supersede_assertion_id', '', true);
        RAISE EXCEPTION 'Assertion % not found', p_old_assertion_id;
    END IF;

    IF v_old.superseded_at IS NOT NULL THEN
        PERFORM set_config('app.write_path', '', true);
        PERFORM set_config('app.supersede_assertion_id', '', true);
        RAISE EXCEPTION 'Assertion % is already superseded by %', p_old_assertion_id, v_old.superseded_by;
    END IF;

    v_assertion_type := coalesce(p_new_assertion_type, v_old.assertion_type);
    v_assertion_key := coalesce(nullif(trim(p_new_assertion_key), ''), v_old.assertion_key);
    v_subject_node_id := coalesce(p_new_subject_node_id, v_old.subject_node_id);
    v_subject_edge_id := coalesce(p_new_subject_edge_id, v_old.subject_edge_id);
    v_new_id := gen_random_uuid();

    PERFORM mark_assertion_superseded(p_old_assertion_id, v_new_id);

    INSERT INTO assertions (
        id,
        assertion_type,
        assertion_key,
        subject_node_id,
        subject_edge_id,
        claim,
        effective_at,
        source_event_id,
        confidence
    ) VALUES (
        v_new_id,
        v_assertion_type,
        v_assertion_key,
        v_subject_node_id,
        v_subject_edge_id,
        p_new_claim,
        coalesce(p_new_effective_at, v_old.effective_at),
        p_new_source_event_id,
        p_new_confidence
    );

    RETURN v_new_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.supersede_assertion_id', '', true);
    RAISE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION generate_crm_code(p_prefix text) RETURNS text
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_yymm text;
    v_seq int;
BEGIN
    v_yymm := to_char(now(), 'YYMM');

    INSERT INTO crm_code_counters (prefix, year_month, next_val)
    VALUES (p_prefix, v_yymm, 2)
    ON CONFLICT (prefix, year_month)
    DO UPDATE SET next_val = crm_code_counters.next_val + 1
    RETURNING next_val - 1 INTO v_seq;

    RETURN p_prefix || '-' || v_yymm || '-' || lpad(v_seq::text, 4, '0');
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION merge_nodes(
    p_duplicate_id uuid,
    p_canonical_id uuid,
    p_merged_by text DEFAULT 'system'
) RETURNS void
SET search_path = rye, pg_catalog
AS $$
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

CREATE OR REPLACE FUNCTION normalize_tmp(raw text) RETURNS text
SET search_path = rye, pg_catalog
AS $$
    SELECT array_to_string(
        ARRAY(
            SELECT CASE
                WHEN ltrim(part, '0') = '' THEN '0'
                ELSE ltrim(part, '0')
            END
            FROM unnest(regexp_split_to_array(raw, '[-/.[[:space:]]]+')) AS part
            WHERE part <> ''
        ),
        '-'
    );
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION agent_node_summary(
    p_node_id uuid,
    p_max_items int DEFAULT 10
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
SELECT jsonb_build_object(
    'node', (SELECT row_to_json(n) FROM nodes n WHERE n.id = p_node_id),

    'top_relationships', (
        SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
        FROM (
            SELECT
                e.edge_type,
                e.properties,
                e.weight,
                nt.label AS target_label,
                nt.node_type AS target_type
            FROM edges e
            JOIN nodes nt ON nt.id = e.target_id
            WHERE e.source_id = p_node_id
              AND e.archived_at IS NULL
            ORDER BY e.weight DESC NULLS LAST, e.created_at DESC
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

CREATE OR REPLACE FUNCTION record_event(
    p_event_type text,
    p_summary text,
    p_properties jsonb DEFAULT '{}',
    p_participant_ids uuid[] DEFAULT '{}',
    p_participant_roles text[] DEFAULT '{}',
    p_actor text DEFAULT NULL,
    p_occurred_at timestamptz DEFAULT now()
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_event_id uuid;
    v_count int;
    i int;
BEGIN
    v_count := coalesce(array_length(p_participant_ids, 1), 0);

    IF coalesce(array_length(p_participant_roles, 1), 0) <> v_count THEN
        RAISE EXCEPTION 'participant_ids and participant_roles must have the same length';
    END IF;

    v_event_id := gen_random_uuid();

    INSERT INTO events (id, event_type, occurred_at, summary, properties, actor_system)
    VALUES (
        v_event_id,
        p_event_type,
        p_occurred_at,
        p_summary,
        p_properties,
        coalesce(p_actor, current_setting('app.current_user_id', true))
    );

    FOR i IN 1..v_count LOOP
        INSERT INTO event_participants (event_id, node_id, role)
        VALUES (v_event_id, p_participant_ids[i], p_participant_roles[i])
        ON CONFLICT (event_id, node_id, role) DO NOTHING;
    END LOOP;

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- Domain integration: link_record, capture_domain_change, track_table, rye_catalog
-- ============================================================

CREATE OR REPLACE FUNCTION link_record(
    p_source_schema text,
    p_source_table text,
    p_source_id text,
    p_node_type text,
    p_label text,
    p_properties jsonb DEFAULT '{}',
    p_source_id_type text DEFAULT 'int'
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_node_id uuid;
    v_ext_source text;
BEGIN
    v_ext_source := p_source_schema || '.' || p_source_table;

    -- Find existing node by external_id/source
    SELECT id INTO v_node_id
    FROM nodes
    WHERE external_id = p_source_id
      AND external_source = v_ext_source
      AND archived_at IS NULL;

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

CREATE OR REPLACE FUNCTION capture_domain_change() RETURNS trigger
SET search_path = rye, pg_catalog, public
AS $$
DECLARE
    v_node_id uuid;
    v_change_type text;
    v_old_data jsonb;
    v_new_data jsonb;
    v_record_id text;
BEGIN
    v_record_id := CASE TG_OP WHEN 'DELETE' THEN OLD.id::text ELSE NEW.id::text END;

    SELECT node_id INTO v_node_id
    FROM node_source_map
    WHERE source_schema = TG_TABLE_SCHEMA
      AND source_table = TG_TABLE_NAME
      AND source_id = v_record_id;

    -- No graph node mapped; skip silently
    IF v_node_id IS NULL THEN RETURN COALESCE(NEW, OLD); END IF;

    v_change_type := lower(TG_OP);
    v_old_data := CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END;
    v_new_data := CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END;

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

CREATE OR REPLACE FUNCTION track_table(
    p_schema text,
    p_table text,
    p_trigger_name text DEFAULT NULL
) RETURNS void
SET search_path = rye, pg_catalog, public
AS $$
DECLARE
    v_trigger text;
    v_qualified text;
BEGIN
    v_trigger := coalesce(p_trigger_name, 'rye_cdc_' || p_table);
    v_qualified := quote_ident(p_schema) || '.' || quote_ident(p_table);

    EXECUTE format(
        'DROP TRIGGER IF EXISTS %I ON %s',
        v_trigger, v_qualified
    );
    EXECUTE format(
        'CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION rye.capture_domain_change()',
        v_trigger, v_qualified
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION rye_catalog() RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
SELECT jsonb_build_object(
    'node_types', (
        SELECT coalesce(jsonb_object_agg(node_type, cnt), '{}'::jsonb)
        FROM (SELECT node_type, count(*) AS cnt FROM nodes WHERE archived_at IS NULL GROUP BY node_type ORDER BY cnt DESC) t
    ),
    'edge_types', (
        SELECT coalesce(jsonb_object_agg(edge_type, cnt), '{}'::jsonb)
        FROM (SELECT edge_type, count(*) AS cnt FROM edges WHERE archived_at IS NULL GROUP BY edge_type ORDER BY cnt DESC) t
    ),
    'assertion_types', (
        SELECT coalesce(jsonb_object_agg(assertion_type, cnt), '{}'::jsonb)
        FROM (SELECT assertion_type, count(*) AS cnt FROM current_assertions GROUP BY assertion_type ORDER BY cnt DESC) t
    ),
    'event_types', (
        SELECT coalesce(jsonb_object_agg(event_type, cnt), '{}'::jsonb)
        FROM (SELECT event_type, count(*) AS cnt FROM events GROUP BY event_type ORDER BY cnt DESC) t
    ),
    'tracked_tables', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
            'schema', source_schema,
            'table', source_table,
            'linked_nodes', cnt
        )), '[]'::jsonb)
        FROM (SELECT source_schema, source_table, count(*) AS cnt FROM node_source_map GROUP BY source_schema, source_table ORDER BY source_schema, source_table) t
    ),
    'totals', jsonb_build_object(
        'nodes', (SELECT count(*) FROM nodes WHERE archived_at IS NULL),
        'edges', (SELECT count(*) FROM edges WHERE archived_at IS NULL),
        'assertions', (SELECT count(*) FROM current_assertions),
        'events', (SELECT count(*) FROM events)
    )
);
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION log_agent_query(
    p_agent_id text,
    p_query_text text,
    p_result_summary text,
    p_nodes_referenced uuid[]
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_roles text[];
BEGIN
    v_roles := array_fill('queried'::text, ARRAY[coalesce(array_length(p_nodes_referenced, 1), 0)]);

    RETURN record_event(
        p_event_type        := 'agent_query',
        p_summary           := p_result_summary,
        p_properties        := jsonb_build_object('query', p_query_text, 'agent_id', p_agent_id),
        p_participant_ids   := p_nodes_referenced,
        p_participant_roles := v_roles,
        p_actor             := 'agent:' || p_agent_id
    );
END;
$$ LANGUAGE plpgsql;
