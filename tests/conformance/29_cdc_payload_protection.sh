#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required for CDC payload protection tests}"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<'SQL'
SET search_path = rye, public, pg_catalog;
BEGIN;

DO $$
DECLARE
    v_node_id uuid;
    v_event_id uuid;
    v_legacy_event_id uuid;
    v_payload jsonb;
    v_admin_legacy_gap_count integer;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:cdc-protection', true);

    CREATE TABLE public._rye_cdc_protected (
        id integer PRIMARY KEY,
        display_name text NOT NULL,
        secret_value text NOT NULL
    );

    INSERT INTO public._rye_cdc_protected (id, display_name, secret_value)
    VALUES (1, 'Visible Name', 'first-secret');

    INSERT INTO field_classifications (node_type, field_path, classification, min_role)
    VALUES ('cdc_account', 'properties.secret_value', 'confidential', 'manager')
    ON CONFLICT (node_type, field_path)
    DO UPDATE SET classification = EXCLUDED.classification, min_role = EXCLUDED.min_role;

    v_node_id := link_record(
        'public',
        '_rye_cdc_protected',
        '1',
        'cdc_account',
        'Visible Name',
        '{"display_name":"Visible Name"}'::jsonb
    );
    PERFORM track_table('public', '_rye_cdc_protected');

    UPDATE public._rye_cdc_protected
    SET display_name = 'Visible Name Updated',
        secret_value = 'second-secret'
    WHERE id = 1;

    SELECT event_row.id, event_row.properties
    INTO v_event_id, v_payload
    FROM events event_row
    JOIN event_participants participant ON participant.event_id = event_row.id
    WHERE participant.node_id = v_node_id
      AND event_row.event_type = 'domain_change'
    ORDER BY event_row.occurred_at DESC
    LIMIT 1;

    IF v_payload->>'cdc_payload_version' <> '2'
       OR v_payload->'new'->>'display_name' <> 'Visible Name Updated'
       OR (v_payload->'new'->'secret_value'->>'redacted')::boolean IS NOT TRUE
       OR v_payload->'new'->'secret_value'->>'classification' <> 'confidential'
       OR length(v_payload->'new'->'secret_value'->>'sha256') <> 64
       OR v_payload::text LIKE '%first-secret%'
       OR v_payload::text LIKE '%second-secret%'
    THEN
        RAISE EXCEPTION 'CDC v2 payload retained or misrepresented classified values: %', v_payload;
    END IF;

    v_legacy_event_id := record_event(
        p_event_type        := 'domain_change',
        p_summary           := 'Legacy CDC event retained for read-boundary test',
        p_properties        := '{
          "schema":"public",
          "table":"_rye_cdc_protected",
          "operation":"update",
          "record_id":"1",
          "old":{"secret_value":"legacy-secret"},
          "new":{"secret_value":"legacy-secret-2"}
        }'::jsonb,
        p_participant_ids   := ARRAY[v_node_id],
        p_participant_roles := ARRAY['subject'],
        p_actor             := 'system:cdc'
    );

    SELECT count(*) INTO v_admin_legacy_gap_count
    FROM cdc_protection_gaps
    WHERE event_id = v_legacy_event_id;
    IF v_admin_legacy_gap_count <> 1 THEN
        RAISE EXCEPTION 'Legacy CDC payload was not surfaced as an administrative gap';
    END IF;

    SELECT properties INTO v_payload
    FROM events_safe
    WHERE id = v_event_id;
    IF v_payload::text LIKE '%second-secret%'
       OR (v_payload->'new'->'secret_value'->>'redacted')::boolean IS NOT TRUE
    THEN
        RAISE EXCEPTION 'Safe event view exposed classified CDC values: %', v_payload;
    END IF;

    SELECT properties INTO v_payload
    FROM events_safe
    WHERE id = v_legacy_event_id;
    IF v_payload::text LIKE '%legacy-secret%'
       OR (v_payload->>'legacy_payload_redacted')::boolean IS NOT TRUE
    THEN
        RAISE EXCEPTION 'Safe event view did not redact legacy CDC rows: %', v_payload;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies policy_row
        WHERE policy_row.schemaname = 'rye'
          AND policy_row.tablename = 'events'
          AND policy_row.policyname = 'event_read_policy'
          AND policy_row.qual LIKE '%cdc_payload_version%'
    ) THEN
        RAISE EXCEPTION 'Raw event RLS policy does not fail closed for legacy CDC payloads';
    END IF;
END;
$$;

ROLLBACK;
SQL

echo "CDC payload protection test passed"
