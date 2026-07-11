-- Materialized read model refresh policy, state, dirty tracking, and gaps.

SET search_path = rye, public, pg_catalog;

BEGIN;

DO $$
DECLARE
    v_registered integer;
    v_result jsonb;
    v_before_count bigint;
    v_after_count bigint;
    v_status text;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM sync_read_model_registry();

    SELECT count(*) INTO v_registered
    FROM read_model_freshness
    WHERE view_name IN ('opportunities_active', 'contacts_directory', 'task_board');
    IF v_registered <> 3 THEN
        RAISE EXCEPTION 'Expected three registered profile read models, got %', v_registered;
    END IF;

    PERFORM refresh_materialized_views();
    IF EXISTS (
        SELECT 1 FROM read_model_freshness
        WHERE enabled = true AND freshness_status <> 'fresh'
    ) THEN
        RAISE EXCEPTION 'Full refresh did not mark every enabled read model fresh';
    END IF;

    SELECT refresh_count INTO v_before_count
    FROM read_model_freshness
    WHERE view_name = 'opportunities_active';

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('freshness_probe', 'Freshness Probe', '{"suite":"read_model_freshness"}'::jsonb);

    IF NOT EXISTS (
        SELECT 1 FROM read_model_freshness_gaps
        WHERE view_name = 'opportunities_active'
          AND freshness_status = 'dirty'
          AND refresh_reason = 'nodes_changed'
    ) THEN
        RAISE EXCEPTION 'Core write did not create a queryable dirty read-model gap';
    END IF;

    v_result := ensure_read_model_fresh('rye', 'opportunities_active');
    SELECT freshness_status, refresh_count
    INTO v_status, v_after_count
    FROM read_model_freshness
    WHERE view_name = 'opportunities_active';

    IF v_result->>'status' <> 'fresh'
       OR (v_result->>'refreshed')::boolean IS NOT TRUE
       OR v_status <> 'fresh'
       OR v_after_count <> v_before_count + 1
    THEN
        RAISE EXCEPTION 'On-read refresh did not repair freshness: %, %, % -> %',
            v_result, v_status, v_before_count, v_after_count;
    END IF;

    PERFORM configure_read_model_refresh(
        'rye',
        'contacts_directory',
        'manual',
        interval '1 hour',
        true,
        '{"owner":"conformance"}'::jsonb
    );

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('freshness_probe', 'Second Freshness Probe', '{"suite":"read_model_freshness"}'::jsonb);

    v_result := ensure_read_model_fresh('rye', 'contacts_directory');
    IF v_result->>'status' <> 'dirty'
       OR (v_result->>'refreshed')::boolean IS NOT FALSE
    THEN
        RAISE EXCEPTION 'Manual policy refreshed on read: %', v_result;
    END IF;

    PERFORM refresh_due_materialized_views();
    SELECT freshness_status INTO v_status
    FROM read_model_freshness
    WHERE view_name = 'contacts_directory';
    IF v_status <> 'dirty' THEN
        RAISE EXCEPTION 'Scheduled/due refresh unexpectedly refreshed manual model: %', v_status;
    END IF;

    v_result := refresh_read_model('rye', 'contacts_directory', true);
    IF v_result->>'status' <> 'fresh'
       OR (v_result->>'refreshed')::boolean IS NOT TRUE
    THEN
        RAISE EXCEPTION 'Explicit manual refresh failed: %', v_result;
    END IF;
END;
$$;

ROLLBACK;
