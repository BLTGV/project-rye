-- FN-28: merge_nodes() must preserve every source row's graph identity.
--
-- Two rows of the SAME source table linked as two nodes, then merged: both
-- mappings must survive on the canonical node, and link_record() on the
-- duplicate's source row must resolve to the canonical node instead of
-- minting a fresh one. Before 0020 the colliding mapping was deleted and the
-- merged duplicate resurrected on the next lazy link.
--
-- Wrapped in a rolled-back transaction so the suite stays idempotent on a
-- reused database (merge_nodes refuses already-archived duplicates).

SET search_path = rye, public, pg_catalog;

BEGIN;

DO $$
DECLARE
  v_canon uuid;
  v_dup uuid;
  v_resolved uuid;
  v_map_count int;
  v_node_count int;
BEGIN
  v_canon := link_record('test_schema', 'test_merge_customers', '1', 'person', 'Pat Original');
  v_dup   := link_record('test_schema', 'test_merge_customers', '2', 'person', 'Pat Duplicate');

  IF v_canon = v_dup THEN
    RAISE EXCEPTION 'FN-28 setup: distinct source rows should link to distinct nodes';
  END IF;

  PERFORM merge_nodes(v_dup, v_canon, 'conformance-test');

  -- Both source rows now map to the canonical node.
  SELECT count(*) INTO v_map_count
  FROM node_source_map
  WHERE node_id = v_canon
    AND source_schema = 'test_schema'
    AND source_table = 'test_merge_customers'
    AND source_id IN ('1', '2');

  IF v_map_count <> 2 THEN
    RAISE EXCEPTION 'Canonical node should carry both source mappings, got %', v_map_count;
  END IF;

  IF EXISTS (SELECT 1 FROM node_source_map WHERE node_id = v_dup) THEN
    RAISE EXCEPTION 'Duplicate node should carry no source mappings after merge';
  END IF;

  -- Re-linking the duplicate's source row resolves to the canonical node.
  v_resolved := link_record('test_schema', 'test_merge_customers', '2', 'person', 'Pat Duplicate');

  IF v_resolved <> v_canon THEN
    RAISE EXCEPTION 'link_record resurrected the merged duplicate: got %, expected %', v_resolved, v_canon;
  END IF;

  -- No fresh node was minted for the merged source rows.
  SELECT count(*) INTO v_node_count
  FROM nodes
  WHERE external_source = 'test_schema.test_merge_customers'
    AND archived_at IS NULL;

  IF v_node_count <> 1 THEN
    RAISE EXCEPTION 'Expected exactly 1 active node for the merged source rows, got %', v_node_count;
  END IF;
END;
$$;

ROLLBACK;
