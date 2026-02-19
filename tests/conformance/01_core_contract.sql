-- EX-01: Unknown node/edge types should work without migrations.

SET search_path = rye, public, pg_catalog;

DO $$
DECLARE
  v_a uuid;
  v_b uuid;
  v_edge uuid;
BEGIN
  INSERT INTO nodes (node_type, label, properties)
  VALUES ('custom_entity', 'Custom A', '{"test": true}')
  RETURNING id INTO v_a;

  INSERT INTO nodes (node_type, label, properties)
  VALUES ('custom_entity', 'Custom B', '{"test": true}')
  RETURNING id INTO v_b;

  INSERT INTO edges (edge_type, source_id, target_id, properties)
  VALUES ('custom_relation', v_a, v_b, '{"reason": "conformance"}')
  RETURNING id INTO v_edge;

  IF v_edge IS NULL THEN
    RAISE EXCEPTION 'Expected custom edge insert to succeed';
  END IF;

  -- Cleanup
  DELETE FROM edges WHERE id = v_edge;
  DELETE FROM nodes WHERE id IN (v_a, v_b);
END;
$$;
