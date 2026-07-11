-- Capture-time CDC redaction and fail-closed reads for legacy full-row events.

SET search_path = rye, pg_catalog, public;

CREATE OR REPLACE FUNCTION protect_cdc_row(
    p_row jsonb,
    p_node_type text
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_result jsonb := p_row;
    v_field record;
    v_key text;
    v_value jsonb;
BEGIN
    IF p_row IS NULL THEN
        RETURN NULL;
    END IF;

    FOR v_field IN
        SELECT field_path, classification
        FROM field_classifications
        WHERE node_type = p_node_type
          AND classification <> 'public'
    LOOP
        v_key := split_part(v_field.field_path, '.', 2);
        IF v_key = '' THEN
            v_key := v_field.field_path;
        END IF;

        IF v_result ? v_key THEN
            v_value := v_result->v_key;
            v_result := jsonb_set(
                v_result,
                ARRAY[v_key],
                jsonb_build_object(
                    'redacted', true,
                    'classification', v_field.classification,
                    'sha256', encode(public.digest(coalesce(v_value, 'null'::jsonb)::text, 'sha256'), 'hex')
                ),
                false
            );
        END IF;
    END LOOP;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION safe_event_properties(
    p_event_type text,
    p_properties jsonb
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
    SELECT CASE
        WHEN p_event_type = 'domain_change'
         AND coalesce(p_properties->>'cdc_payload_version', '1') <> '2'
        THEN jsonb_strip_nulls(jsonb_build_object(
            'schema', p_properties->>'schema',
            'table', p_properties->>'table',
            'operation', p_properties->>'operation',
            'record_id', p_properties->>'record_id',
            'cdc_payload_version', 1,
            'legacy_payload_redacted', true,
            'migration_status', 'admin_only_until_retention_or_reingestion'
        ))
        ELSE coalesce(p_properties, '{}'::jsonb)
    END;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION capture_domain_change() RETURNS trigger
SET search_path = rye, pg_catalog, public
AS $$
DECLARE
    v_node_id uuid;
    v_node_type text;
    v_change_type text;
    v_old_data jsonb;
    v_new_data jsonb;
    v_old_protected jsonb;
    v_new_protected jsonb;
    v_record_id text;
    v_pk_col text;
BEGIN
    v_old_data := CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END;
    v_new_data := CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END;

    IF TG_OP = 'DELETE' THEN
        v_record_id := v_old_data->>'id';
        IF v_record_id IS NULL THEN
            SELECT attribute.attname INTO v_pk_col
            FROM pg_index index_row
            JOIN pg_attribute attribute
              ON attribute.attrelid = index_row.indrelid
             AND attribute.attnum = ANY(index_row.indkey)
            WHERE index_row.indrelid = (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME)::regclass
              AND index_row.indisprimary
            LIMIT 1;
            IF v_pk_col IS NOT NULL THEN
                v_record_id := v_old_data->>v_pk_col;
            END IF;
        END IF;
    ELSE
        v_record_id := v_new_data->>'id';
        IF v_record_id IS NULL THEN
            SELECT attribute.attname INTO v_pk_col
            FROM pg_index index_row
            JOIN pg_attribute attribute
              ON attribute.attrelid = index_row.indrelid
             AND attribute.attnum = ANY(index_row.indkey)
            WHERE index_row.indrelid = (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME)::regclass
              AND index_row.indisprimary
            LIMIT 1;
            IF v_pk_col IS NOT NULL THEN
                v_record_id := v_new_data->>v_pk_col;
            END IF;
        END IF;
    END IF;

    IF v_record_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    SELECT source_map.node_id, node_row.node_type
    INTO v_node_id, v_node_type
    FROM node_source_map source_map
    JOIN nodes node_row ON node_row.id = source_map.node_id
    WHERE source_map.source_schema = TG_TABLE_SCHEMA
      AND source_map.source_table = TG_TABLE_NAME
      AND source_map.source_id = v_record_id;

    IF v_node_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    v_change_type := lower(TG_OP);
    v_old_protected := protect_cdc_row(v_old_data, v_node_type);
    v_new_protected := protect_cdc_row(v_new_data, v_node_type);

    PERFORM record_event(
        p_event_type        := 'domain_change',
        p_summary           := format(
            '%s.%s %s (record %s)',
            TG_TABLE_SCHEMA,
            TG_TABLE_NAME,
            v_change_type,
            v_record_id
        ),
        p_properties        := jsonb_build_object(
            'schema', TG_TABLE_SCHEMA,
            'table', TG_TABLE_NAME,
            'operation', v_change_type,
            'record_id', v_record_id,
            'cdc_payload_version', 2,
            'redaction_mode', 'non_public_value_hash',
            'old', v_old_protected,
            'new', v_new_protected,
            'changed_fields', CASE
                WHEN TG_OP = 'UPDATE' THEN (
                    SELECT jsonb_object_agg(
                        key,
                        jsonb_build_object('old', v_old_protected->key, 'new', value)
                    )
                    FROM jsonb_each(v_new_protected)
                    WHERE v_old_protected->key IS DISTINCT FROM v_new_protected->key
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

-- Legacy domain_change events may contain full source rows. They remain
-- immutable, but only admin context may read them from the raw event table.
DROP POLICY IF EXISTS event_read_policy ON events;
CREATE POLICY event_read_policy ON events
    FOR SELECT
    USING (
        (
            EXISTS (
                SELECT 1
                FROM event_participants participant
                WHERE participant.event_id = events.id
            )
            OR current_setting('app.current_role', true) = 'admin'
        )
        AND (
            event_type <> 'domain_change'
            OR properties->>'cdc_payload_version' = '2'
            OR current_setting('app.current_role', true) = 'admin'
        )
    );

CREATE OR REPLACE VIEW events_safe
WITH (security_invoker = true) AS
SELECT
    event_row.id,
    event_row.event_type,
    event_row.occurred_at,
    event_row.recorded_at,
    event_row.summary,
    event_row.actor_system,
    safe_event_properties(event_row.event_type, event_row.properties) AS properties,
    event_row.created_at
FROM events event_row;

CREATE OR REPLACE VIEW cdc_protection_gaps
WITH (security_invoker = true) AS
SELECT
    'legacy-cdc-event:' || event_row.id::text AS gap_id,
    'legacy_full_payload'::text AS gap_type,
    'high'::text AS severity,
    event_row.id AS event_id,
    event_row.occurred_at,
    event_row.properties->>'schema' AS source_schema,
    event_row.properties->>'table' AS source_table,
    event_row.properties->>'record_id' AS source_id,
    'Immutable legacy CDC payload is admin-only until retention expiry or protected reingestion.'::text AS reason
FROM events event_row
WHERE event_row.event_type = 'domain_change'
  AND coalesce(event_row.properties->>'cdc_payload_version', '1') <> '2';

REVOKE EXECUTE ON FUNCTION protect_cdc_row(jsonb, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION capture_domain_change() FROM PUBLIC;
