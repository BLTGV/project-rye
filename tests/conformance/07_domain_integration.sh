#!/usr/bin/env bash
# FN-10: track_table() + capture_domain_change() should produce domain_change events
# for linked rows on INSERT/UPDATE/DELETE.
#
# This test runs as the DATABASE_URL user (not the test role) because it needs
# CREATE TABLE and CREATE TRIGGER privileges.
set -euo pipefail

DB_URL="${DATABASE_URL:?DATABASE_URL required}"

result="$(psql "$DB_URL" -v ON_ERROR_STOP=1 -Atq <<'SQL'
DO $$
DECLARE
  v_node_id uuid;
  v_event_count int;
  v_change_type text;
  v_changed_fields jsonb;
BEGIN
  -- Create a domain table
  CREATE TABLE IF NOT EXISTS _rye_test_products (
    id serial PRIMARY KEY,
    name text NOT NULL,
    price numeric NOT NULL
  );

  TRUNCATE _rye_test_products CASCADE;

  -- Insert a product row
  INSERT INTO _rye_test_products (id, name, price) VALUES (1, 'Widget', 49.99);

  -- Link it to the graph
  v_node_id := link_record(
    p_source_schema := 'public',
    p_source_table  := '_rye_test_products',
    p_source_id     := '1',
    p_node_type     := 'product',
    p_label         := 'Widget',
    p_properties    := '{"price": 49.99}'
  );

  -- Attach CDC trigger
  PERFORM track_table('public', '_rye_test_products');

  -- Count domain_change events before
  SELECT count(*) INTO v_event_count
  FROM events e
  JOIN event_participants ep ON ep.event_id = e.id
  WHERE ep.node_id = v_node_id AND e.event_type = 'domain_change';

  IF v_event_count <> 0 THEN
    RAISE EXCEPTION 'Expected 0 domain_change events before update, got %', v_event_count;
  END IF;

  -- Update the price (should fire CDC trigger)
  UPDATE _rye_test_products SET price = 59.99 WHERE id = 1;

  -- Verify domain_change event was created
  SELECT count(*) INTO v_event_count
  FROM events e
  JOIN event_participants ep ON ep.event_id = e.id
  WHERE ep.node_id = v_node_id AND e.event_type = 'domain_change';

  IF v_event_count <> 1 THEN
    RAISE EXCEPTION 'Expected 1 domain_change event after update, got %', v_event_count;
  END IF;

  -- Verify changed_fields contains price diff
  SELECT e.properties->'changed_fields' INTO v_changed_fields
  FROM events e
  JOIN event_participants ep ON ep.event_id = e.id
  WHERE ep.node_id = v_node_id AND e.event_type = 'domain_change'
  ORDER BY e.occurred_at DESC LIMIT 1;

  IF v_changed_fields IS NULL OR NOT (v_changed_fields ? 'price') THEN
    RAISE EXCEPTION 'Expected changed_fields to contain price, got %', v_changed_fields;
  END IF;

  -- Delete the row (should fire CDC trigger)
  DELETE FROM _rye_test_products WHERE id = 1;

  SELECT count(*) INTO v_event_count
  FROM events e
  JOIN event_participants ep ON ep.event_id = e.id
  WHERE ep.node_id = v_node_id AND e.event_type = 'domain_change';

  IF v_event_count <> 2 THEN
    RAISE EXCEPTION 'Expected 2 domain_change events after delete, got %', v_event_count;
  END IF;

  -- Verify a delete event exists
  IF NOT EXISTS (
    SELECT 1
    FROM events e
    JOIN event_participants ep ON ep.event_id = e.id
    WHERE ep.node_id = v_node_id
      AND e.event_type = 'domain_change'
      AND e.properties->>'operation' = 'delete'
  ) THEN
    RAISE EXCEPTION 'Expected a domain_change event with operation=delete';
  END IF;

  -- Verify unlinked rows are silently skipped
  INSERT INTO _rye_test_products (id, name, price) VALUES (2, 'Gadget', 99.99);
  UPDATE _rye_test_products SET price = 109.99 WHERE id = 2;

  -- Should still be 2 events (unlinked row changes are ignored)
  SELECT count(*) INTO v_event_count
  FROM events e
  JOIN event_participants ep ON ep.event_id = e.id
  WHERE ep.node_id = v_node_id AND e.event_type = 'domain_change';

  IF v_event_count <> 2 THEN
    RAISE EXCEPTION 'Expected 2 domain_change events (unlinked rows should be skipped), got %', v_event_count;
  END IF;

  -- Cleanup
  DROP TRIGGER IF EXISTS rye_cdc__rye_test_products ON _rye_test_products;
  DROP TABLE _rye_test_products;

  RAISE NOTICE 'domain_integration test passed';
END;
$$;
SQL
)"

echo "Domain integration (track_table + CDC) test passed"
