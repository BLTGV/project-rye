-- FN-09: rye_catalog() should return JSONB with expected top-level keys and accurate totals.

DO $$
DECLARE
  v_catalog jsonb;
  v_node_count bigint;
  v_catalog_node_count bigint;
BEGIN
  v_catalog := rye_catalog();

  IF v_catalog IS NULL THEN
    RAISE EXCEPTION 'rye_catalog() returned NULL';
  END IF;

  -- Verify required top-level keys exist
  IF NOT (v_catalog ? 'node_types') THEN
    RAISE EXCEPTION 'Missing key: node_types';
  END IF;

  IF NOT (v_catalog ? 'edge_types') THEN
    RAISE EXCEPTION 'Missing key: edge_types';
  END IF;

  IF NOT (v_catalog ? 'assertion_types') THEN
    RAISE EXCEPTION 'Missing key: assertion_types';
  END IF;

  IF NOT (v_catalog ? 'event_types') THEN
    RAISE EXCEPTION 'Missing key: event_types';
  END IF;

  IF NOT (v_catalog ? 'tracked_tables') THEN
    RAISE EXCEPTION 'Missing key: tracked_tables';
  END IF;

  IF NOT (v_catalog ? 'totals') THEN
    RAISE EXCEPTION 'Missing key: totals';
  END IF;

  -- Verify totals.nodes matches actual count
  SELECT count(*) INTO v_node_count FROM nodes WHERE archived_at IS NULL;
  v_catalog_node_count := (v_catalog->'totals'->>'nodes')::bigint;

  IF v_catalog_node_count <> v_node_count THEN
    RAISE EXCEPTION 'Catalog nodes total (%) does not match actual count (%)',
      v_catalog_node_count, v_node_count;
  END IF;

  -- Verify node_types is an object with counts
  IF jsonb_typeof(v_catalog->'node_types') <> 'object' THEN
    RAISE EXCEPTION 'node_types should be an object, got %', jsonb_typeof(v_catalog->'node_types');
  END IF;

  -- Verify tracked_tables is an array
  IF jsonb_typeof(v_catalog->'tracked_tables') <> 'array' THEN
    RAISE EXCEPTION 'tracked_tables should be an array, got %', jsonb_typeof(v_catalog->'tracked_tables');
  END IF;

END;
$$;
