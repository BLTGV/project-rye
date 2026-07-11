-- Policy, state, dirty tracking, and deterministic refresh for materialized read models.

SET search_path = rye, pg_catalog, public;

CREATE TABLE IF NOT EXISTS read_model_refresh_policies (
    view_schema    text NOT NULL,
    view_name      text NOT NULL,
    refresh_mode   text NOT NULL DEFAULT 'on_read'
                   CHECK (refresh_mode IN ('manual', 'scheduled', 'on_read')),
    max_staleness  interval NOT NULL DEFAULT interval '5 minutes'
                   CHECK (max_staleness > interval '0 seconds'),
    enabled        boolean NOT NULL DEFAULT true,
    properties     jsonb NOT NULL DEFAULT '{}',
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (view_schema, view_name)
);

CREATE TABLE IF NOT EXISTS read_model_refresh_state (
    view_schema          text NOT NULL,
    view_name            text NOT NULL,
    last_started_at      timestamptz,
    last_completed_at    timestamptz,
    last_failed_at       timestamptz,
    last_error           text,
    last_duration_ms     bigint,
    approximate_row_count bigint,
    refresh_requested_at timestamptz NOT NULL DEFAULT now(),
    refresh_reason       text NOT NULL DEFAULT 'registered',
    refresh_count        bigint NOT NULL DEFAULT 0,
    updated_at           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (view_schema, view_name),
    FOREIGN KEY (view_schema, view_name)
      REFERENCES read_model_refresh_policies(view_schema, view_name)
      ON DELETE CASCADE
);

ALTER TABLE read_model_refresh_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE read_model_refresh_policies FORCE ROW LEVEL SECURITY;
ALTER TABLE read_model_refresh_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE read_model_refresh_state FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS read_model_policies_admin ON read_model_refresh_policies;
CREATE POLICY read_model_policies_admin ON read_model_refresh_policies
    FOR ALL
    USING (current_setting('app.current_role', true) = 'admin')
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS read_model_state_admin ON read_model_refresh_state;
CREATE POLICY read_model_state_admin ON read_model_refresh_state
    FOR ALL
    USING (current_setting('app.current_role', true) = 'admin')
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

CREATE OR REPLACE FUNCTION sync_read_model_registry(
    p_default_mode text DEFAULT 'on_read',
    p_default_max_staleness interval DEFAULT interval '5 minutes'
) RETURNS integer
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_previous_role text;
    v_inserted integer;
BEGIN
    IF p_default_mode NOT IN ('manual', 'scheduled', 'on_read') THEN
        RAISE EXCEPTION 'Unsupported read model refresh mode: %', p_default_mode;
    END IF;
    IF p_default_max_staleness <= interval '0 seconds' THEN
        RAISE EXCEPTION 'Read model max staleness must be positive';
    END IF;

    v_previous_role := current_setting('app.current_role', true);
    PERFORM set_config('app.current_role', 'admin', true);

    INSERT INTO read_model_refresh_policies (
        view_schema, view_name, refresh_mode, max_staleness
    )
    SELECT namespace.nspname, relation.relname, p_default_mode, p_default_max_staleness
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE relation.relkind = 'm'
      AND namespace.nspname = 'rye'
    ON CONFLICT (view_schema, view_name) DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    INSERT INTO read_model_refresh_state (view_schema, view_name)
    SELECT policy.view_schema, policy.view_name
    FROM read_model_refresh_policies policy
    WHERE policy.enabled = true
    ON CONFLICT (view_schema, view_name) DO NOTHING;

    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RETURN v_inserted;
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION configure_read_model_refresh(
    p_view_schema text,
    p_view_name text,
    p_refresh_mode text,
    p_max_staleness interval,
    p_enabled boolean DEFAULT true,
    p_properties jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_previous_role text;
BEGIN
    IF coalesce(current_setting('app.current_role', true), '') <> 'admin' THEN
        RAISE EXCEPTION 'Read model refresh configuration requires admin context'
            USING ERRCODE = '42501';
    END IF;
    IF p_refresh_mode NOT IN ('manual', 'scheduled', 'on_read') THEN
        RAISE EXCEPTION 'Unsupported read model refresh mode: %', p_refresh_mode;
    END IF;
    IF p_max_staleness <= interval '0 seconds' THEN
        RAISE EXCEPTION 'Read model max staleness must be positive';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM pg_class relation
        JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = p_view_schema
          AND relation.relname = p_view_name
          AND relation.relkind = 'm'
    ) THEN
        RAISE EXCEPTION 'Materialized view %.% not found', p_view_schema, p_view_name;
    END IF;

    INSERT INTO read_model_refresh_policies (
        view_schema, view_name, refresh_mode, max_staleness, enabled, properties, updated_at
    ) VALUES (
        p_view_schema,
        p_view_name,
        p_refresh_mode,
        p_max_staleness,
        coalesce(p_enabled, true),
        coalesce(p_properties, '{}'::jsonb),
        now()
    )
    ON CONFLICT (view_schema, view_name)
    DO UPDATE SET
        refresh_mode = EXCLUDED.refresh_mode,
        max_staleness = EXCLUDED.max_staleness,
        enabled = EXCLUDED.enabled,
        properties = read_model_refresh_policies.properties || EXCLUDED.properties,
        updated_at = now();

    INSERT INTO read_model_refresh_state (view_schema, view_name)
    VALUES (p_view_schema, p_view_name)
    ON CONFLICT (view_schema, view_name) DO NOTHING;

    RETURN jsonb_build_object(
        'view_schema', p_view_schema,
        'view_name', p_view_name,
        'refresh_mode', p_refresh_mode,
        'max_staleness', p_max_staleness,
        'enabled', p_enabled
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION mark_read_models_dirty()
RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_previous_role text;
BEGIN
    v_previous_role := current_setting('app.current_role', true);
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM sync_read_model_registry();

    UPDATE read_model_refresh_state state_row
    SET refresh_requested_at = clock_timestamp(),
        refresh_reason = coalesce(nullif(trim(TG_ARGV[0]), ''), TG_TABLE_NAME || '_' || lower(TG_OP)),
        updated_at = clock_timestamp()
    FROM read_model_refresh_policies policy
    WHERE policy.view_schema = state_row.view_schema
      AND policy.view_name = state_row.view_name
      AND policy.enabled = true;

    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_nodes_read_models_dirty ON nodes;
CREATE TRIGGER trg_nodes_read_models_dirty
    AFTER INSERT OR UPDATE ON nodes
    FOR EACH STATEMENT
    EXECUTE FUNCTION mark_read_models_dirty('nodes_changed');

DROP TRIGGER IF EXISTS trg_edges_read_models_dirty ON edges;
CREATE TRIGGER trg_edges_read_models_dirty
    AFTER INSERT OR UPDATE ON edges
    FOR EACH STATEMENT
    EXECUTE FUNCTION mark_read_models_dirty('edges_changed');

DROP TRIGGER IF EXISTS trg_assertions_read_models_dirty ON assertions;
CREATE TRIGGER trg_assertions_read_models_dirty
    AFTER INSERT OR UPDATE ON assertions
    FOR EACH STATEMENT
    EXECUTE FUNCTION mark_read_models_dirty('assertions_changed');

CREATE OR REPLACE VIEW read_model_freshness
WITH (security_invoker = true) AS
SELECT
    policy.view_schema,
    policy.view_name,
    policy.refresh_mode,
    policy.max_staleness,
    policy.enabled,
    state_row.last_started_at,
    state_row.last_completed_at,
    state_row.last_failed_at,
    state_row.last_error,
    state_row.last_duration_ms,
    state_row.approximate_row_count,
    state_row.refresh_requested_at,
    state_row.refresh_reason,
    state_row.refresh_count,
    CASE
        WHEN NOT policy.enabled THEN 'disabled'
        WHEN state_row.last_completed_at IS NULL THEN 'never_refreshed'
        WHEN state_row.refresh_requested_at > state_row.last_completed_at THEN 'dirty'
        WHEN now() - state_row.last_completed_at > policy.max_staleness THEN 'stale'
        ELSE 'fresh'
    END AS freshness_status,
    CASE
        WHEN state_row.last_completed_at IS NULL THEN NULL
        ELSE now() - state_row.last_completed_at
    END AS age
FROM read_model_refresh_policies policy
JOIN read_model_refresh_state state_row
  ON state_row.view_schema = policy.view_schema
 AND state_row.view_name = policy.view_name;

CREATE OR REPLACE VIEW read_model_freshness_gaps
WITH (security_invoker = true) AS
SELECT
    'read-model:' || freshness.view_schema || '.' || freshness.view_name AS gap_id,
    'read_model_' || freshness.freshness_status AS gap_type,
    CASE
        WHEN freshness.freshness_status IN ('never_refreshed', 'dirty') THEN 'high'
        ELSE 'medium'
    END AS severity,
    freshness.view_schema,
    freshness.view_name,
    freshness.freshness_status,
    freshness.age,
    freshness.max_staleness,
    freshness.refresh_reason,
    freshness.last_error
FROM read_model_freshness freshness
WHERE freshness.enabled = true
  AND freshness.freshness_status IN ('never_refreshed', 'dirty', 'stale');

CREATE OR REPLACE FUNCTION refresh_read_model(
    p_view_schema text,
    p_view_name text,
    p_force boolean DEFAULT false
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_started timestamptz := clock_timestamp();
    v_policy read_model_refresh_policies;
    v_state read_model_refresh_state;
    v_previous_role text;
    v_row_count bigint;
    v_result jsonb;
BEGIN
    v_previous_role := current_setting('app.current_role', true);
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM sync_read_model_registry();

    SELECT * INTO v_policy
    FROM read_model_refresh_policies
    WHERE view_schema = p_view_schema
      AND view_name = p_view_name;
    SELECT * INTO v_state
    FROM read_model_refresh_state
    WHERE view_schema = p_view_schema
      AND view_name = p_view_name;

    IF v_policy.view_name IS NULL OR NOT v_policy.enabled THEN
        RAISE EXCEPTION 'Enabled read model %.% not registered', p_view_schema, p_view_name;
    END IF;

    IF NOT coalesce(p_force, false)
       AND v_state.last_completed_at IS NOT NULL
       AND v_state.refresh_requested_at <= v_state.last_completed_at
       AND now() - v_state.last_completed_at <= v_policy.max_staleness
    THEN
        PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
        RETURN jsonb_build_object(
            'view_schema', p_view_schema,
            'view_name', p_view_name,
            'status', 'fresh',
            'refreshed', false,
            'last_completed_at', v_state.last_completed_at
        );
    END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended(p_view_schema || '.' || p_view_name, 0)) THEN
        PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
        RETURN jsonb_build_object(
            'view_schema', p_view_schema,
            'view_name', p_view_name,
            'status', 'refresh_in_progress',
            'refreshed', false
        );
    END IF;

    UPDATE read_model_refresh_state
    SET last_started_at = v_started,
        last_error = NULL,
        updated_at = v_started
    WHERE view_schema = p_view_schema
      AND view_name = p_view_name;

    BEGIN
        EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %I.%I', p_view_schema, p_view_name);
        SELECT greatest(relation.reltuples::bigint, 0)
        INTO v_row_count
        FROM pg_class relation
        JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = p_view_schema
          AND relation.relname = p_view_name
          AND relation.relkind = 'm';

        UPDATE read_model_refresh_state
        SET last_completed_at = clock_timestamp(),
            last_duration_ms = (extract(epoch FROM (clock_timestamp() - v_started)) * 1000)::bigint,
            approximate_row_count = v_row_count,
            last_error = NULL,
            refresh_count = refresh_count + 1,
            updated_at = clock_timestamp()
        WHERE view_schema = p_view_schema
          AND view_name = p_view_name;

        v_result := jsonb_build_object(
            'view_schema', p_view_schema,
            'view_name', p_view_name,
            'status', 'fresh',
            'refreshed', true,
            'approximate_row_count', v_row_count,
            'duration_ms', (extract(epoch FROM (clock_timestamp() - v_started)) * 1000)::bigint
        );
    EXCEPTION WHEN OTHERS THEN
        UPDATE read_model_refresh_state
        SET last_failed_at = clock_timestamp(),
            last_duration_ms = (extract(epoch FROM (clock_timestamp() - v_started)) * 1000)::bigint,
            last_error = left(SQLSTATE || ': ' || SQLERRM, 2000),
            updated_at = clock_timestamp()
        WHERE view_schema = p_view_schema
          AND view_name = p_view_name;

        v_result := jsonb_build_object(
            'view_schema', p_view_schema,
            'view_name', p_view_name,
            'status', 'failed',
            'refreshed', false,
            'error', left(SQLSTATE || ': ' || SQLERRM, 2000)
        );
    END;

    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RETURN v_result;
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ensure_read_model_fresh(
    p_view_schema text,
    p_view_name text
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_status text;
    v_mode text;
BEGIN
    PERFORM sync_read_model_registry();
    SELECT freshness_status, refresh_mode
    INTO v_status, v_mode
    FROM read_model_freshness
    WHERE view_schema = p_view_schema
      AND view_name = p_view_name;

    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Read model %.% is not registered', p_view_schema, p_view_name;
    END IF;

    IF v_status IN ('never_refreshed', 'dirty', 'stale') AND v_mode = 'on_read' THEN
        RETURN refresh_read_model(p_view_schema, p_view_name, false);
    END IF;

    RETURN jsonb_build_object(
        'view_schema', p_view_schema,
        'view_name', p_view_name,
        'status', v_status,
        'refreshed', false,
        'refresh_mode', v_mode
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION refresh_due_materialized_views()
RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_model record;
    v_results jsonb := '[]'::jsonb;
BEGIN
    PERFORM sync_read_model_registry();
    FOR v_model IN
        SELECT view_schema, view_name
        FROM read_model_freshness
        WHERE enabled = true
          AND refresh_mode IN ('scheduled', 'on_read')
          AND freshness_status IN ('never_refreshed', 'dirty', 'stale')
        ORDER BY view_schema, view_name
    LOOP
        v_results := v_results || jsonb_build_array(
            refresh_read_model(v_model.view_schema, v_model.view_name, false)
        );
    END LOOP;
    RETURN v_results;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION refresh_materialized_views() RETURNS void
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_model record;
    v_result jsonb;
BEGIN
    PERFORM sync_read_model_registry();
    FOR v_model IN
        SELECT view_schema, view_name
        FROM read_model_refresh_policies
        WHERE enabled = true
        ORDER BY view_schema, view_name
    LOOP
        v_result := refresh_read_model(v_model.view_schema, v_model.view_name, true);
        IF v_result->>'status' = 'failed' THEN
            RAISE WARNING 'Read model %.% refresh failed: %',
                v_model.view_schema, v_model.view_name, v_result->>'error';
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE ALL ON read_model_refresh_policies FROM PUBLIC;
REVOKE ALL ON read_model_refresh_state FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION sync_read_model_registry(text, interval) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION configure_read_model_refresh(text, text, text, interval, boolean, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION mark_read_models_dirty() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION refresh_read_model(text, text, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION ensure_read_model_fresh(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION refresh_due_materialized_views() FROM PUBLIC;
