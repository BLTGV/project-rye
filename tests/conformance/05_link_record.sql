-- FN-08: link_record() should create node + source map, and be idempotent on re-call.

SET search_path = rye, public, pg_catalog;

DO $$
DECLARE
  v_node_id uuid;
  v_node_id_2 uuid;
  v_source_count int;
  v_label text;
  v_plan text;
BEGIN
  -- First call: creates node and source map entry
  v_node_id := link_record(
    p_source_schema := 'test_schema',
    p_source_table  := 'test_customers',
    p_source_id     := '999',
    p_node_type     := 'org',
    p_label         := 'Link Test Corp',
    p_properties    := '{"plan": "starter"}'
  );

  IF v_node_id IS NULL THEN
    RAISE EXCEPTION 'link_record() returned NULL on first call';
  END IF;

  -- Verify node exists with correct external_id/source
  IF NOT EXISTS (
    SELECT 1 FROM nodes
    WHERE id = v_node_id
      AND external_id = '999'
      AND external_source = 'test_schema.test_customers'
      AND node_type = 'org'
  ) THEN
    RAISE EXCEPTION 'Node not created with expected external_id/source';
  END IF;

  -- Verify node_source_map entry
  SELECT count(*) INTO v_source_count
  FROM node_source_map
  WHERE node_id = v_node_id
    AND source_schema = 'test_schema'
    AND source_table = 'test_customers'
    AND source_id = '999';

  IF v_source_count <> 1 THEN
    RAISE EXCEPTION 'Expected 1 source map entry, got %', v_source_count;
  END IF;

  -- Second call: idempotent, returns same node, merges properties
  v_node_id_2 := link_record(
    p_source_schema := 'test_schema',
    p_source_table  := 'test_customers',
    p_source_id     := '999',
    p_node_type     := 'org',
    p_label         := 'Link Test Corp Updated',
    p_properties    := '{"plan": "growth", "mrr": 299}'
  );

  IF v_node_id_2 <> v_node_id THEN
    RAISE EXCEPTION 'Idempotent call returned different node ID: % vs %', v_node_id, v_node_id_2;
  END IF;

  -- Verify properties were merged and label updated
  SELECT label, properties->>'plan' INTO v_label, v_plan
  FROM nodes WHERE id = v_node_id;

  IF v_label <> 'Link Test Corp Updated' THEN
    RAISE EXCEPTION 'Expected updated label, got %', v_label;
  END IF;

  IF v_plan <> 'growth' THEN
    RAISE EXCEPTION 'Expected merged plan=growth, got %', v_plan;
  END IF;

END;
$$;
