-- Register profile materialized views after all profile migrations have run.

SET search_path = rye, pg_catalog;

DO $$
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM sync_read_model_registry();
END;
$$;
