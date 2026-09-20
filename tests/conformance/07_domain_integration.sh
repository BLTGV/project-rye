#!/usr/bin/env bash
# FN-10: track_table() + capture_domain_change() should produce domain_change events
# for linked rows on INSERT/UPDATE/DELETE.
#
# Also obligations 13 and 14 of docs/decisions/0009-who-may-write.md: a tracked
# domain table keeps producing its CDC event when the application's session sets
# no Rye role, which is the normal overlay deployment, and the caller's role is
# restored on every exit path including a failing one.
#
# This test runs as the DATABASE_URL user (not the test role) because it needs
# CREATE TABLE and CREATE TRIGGER privileges. It runs under both owner types:
# scripts/conformance.sh runs the .sh suites as the connection's own user, and
# ./scripts/test-nonsuperuser-owner.sh points that at a NOSUPERUSER NOBYPASSRLS
# owner.
set -euo pipefail

DB_URL="${DATABASE_URL:?DATABASE_URL required}"

result="$(psql "$DB_URL" -v ON_ERROR_STOP=1 -Atq <<'SQL'
SET search_path = rye, public, pg_catalog;

-- The setup below writes the graph directly -- it clears stale nodes and events
-- from earlier runs and calls link_record() -- so it is an operator act and
-- says so. The domain writes further down deliberately run with no Rye role,
-- as viewer, and as agent:t, because that is what an application that does not
-- know Rye exists looks like. -Atq still prints the set_config row, so discard
-- it.
SELECT set_config('app.current_role', 'admin', false) \g /dev/null

DO $$
DECLARE
  v_node_id uuid;
  v_event_count int;
  v_change_type text;
  v_changed_fields jsonb;
  v_stale_node_ids uuid[];
  v_stale_event_ids uuid[];
  v_role text;
  v_sid text;
  v_probe_id int;
  v_role_node uuid;
  v_chosen uuid;
  v_rows int;
  v_ev events;
  v_seen text;
  v_failed boolean;
BEGIN
  -- Remove graph state left by prior runs (including failed ones): the test
  -- node and its domain_change events survive the table drop at the end, and
  -- link_record would return that same node with a non-zero event count.
  SELECT array_agg(id) INTO v_stale_node_ids
  FROM (
    SELECT node_id AS id FROM node_source_map
    WHERE source_schema = 'public' AND source_table = '_rye_test_products'
    UNION
    SELECT id FROM nodes WHERE external_source = 'public._rye_test_products'
  ) stale;

  IF v_stale_node_ids IS NOT NULL THEN
    SELECT array_agg(DISTINCT event_id) INTO v_stale_event_ids
    FROM event_participants
    WHERE node_id = ANY(v_stale_node_ids);

    IF v_stale_event_ids IS NOT NULL THEN
      DELETE FROM event_participants WHERE event_id = ANY(v_stale_event_ids);
      DELETE FROM events WHERE id = ANY(v_stale_event_ids);
    END IF;

    DELETE FROM node_source_map WHERE node_id = ANY(v_stale_node_ids);
    DELETE FROM nodes WHERE id = ANY(v_stale_node_ids);
  END IF;

  -- Create a domain table in public schema
  CREATE TABLE IF NOT EXISTS public._rye_test_products (
    id serial PRIMARY KEY,
    name text NOT NULL,
    price numeric NOT NULL
  );

  TRUNCATE public._rye_test_products CASCADE;

  -- Insert a product row
  INSERT INTO public._rye_test_products (id, name, price) VALUES (1, 'Widget', 49.99);

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
  UPDATE public._rye_test_products SET price = 59.99 WHERE id = 1;

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
  DELETE FROM public._rye_test_products WHERE id = 1;

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
  INSERT INTO public._rye_test_products (id, name, price) VALUES (2, 'Gadget', 99.99);
  UPDATE public._rye_test_products SET price = 109.99 WHERE id = 2;

  -- Should still be 2 events (unlinked row changes are ignored)
  SELECT count(*) INTO v_event_count
  FROM events e
  JOIN event_participants ep ON ep.event_id = e.id
  WHERE ep.node_id = v_node_id AND e.event_type = 'domain_change';

  IF v_event_count <> 2 THEN
    RAISE EXCEPTION 'Expected 2 domain_change events (unlinked rows should be skipped), got %', v_event_count;
  END IF;

  -- ======================================================================
  -- Obligation 13. The CDC path keeps working for every session.
  --
  -- An application that does not know Rye exists writes its own tables in a
  -- session with no app.current_role. Since migration 0026 that session may
  -- not write the graph, and capture_domain_change() therefore records under
  -- the reserved system:cdc role. Nine cases: three roles, three operations.
  -- The count is asserted, not existence -- a trigger that fires twice is also
  -- a bug.
  -- ======================================================================
  v_probe_id := 10;
  FOREACH v_role IN ARRAY ARRAY['', 'viewer', 'agent:t'] LOOP
    v_probe_id := v_probe_id + 1;
    v_sid := v_probe_id::text;

    -- Map the node first, as an operator. The domain row does not exist yet:
    -- link_record() maps a source id, not a row, so the INSERT below is the
    -- first change the graph sees.
    PERFORM set_config('app.current_role', 'admin', true);
    v_role_node := link_record(
      p_source_schema := 'public',
      p_source_table  := '_rye_test_products',
      p_source_id     := v_sid,
      p_node_type     := 'product',
      p_label         := 'CDC probe ' || v_sid
    );

    PERFORM set_config('app.current_role', v_role, true);
    IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
      RAISE EXCEPTION 'Role did not read back as "%"', v_role;
    END IF;

    FOREACH v_change_type IN ARRAY ARRAY['insert', 'update', 'delete'] LOOP
      IF v_change_type = 'insert' THEN
        INSERT INTO public._rye_test_products (id, name, price)
        VALUES (v_probe_id, 'CDC probe', 1.00);
      ELSIF v_change_type = 'update' THEN
        UPDATE public._rye_test_products SET price = 2.00 WHERE id = v_probe_id;
      ELSE
        DELETE FROM public._rye_test_products WHERE id = v_probe_id;
      END IF;

      -- Obligation 14, taken at every step: the caller's role is restored.
      IF coalesce(current_setting('app.current_role', true), '') IS DISTINCT FROM v_role THEN
        RAISE EXCEPTION
          'After a % on a tracked table as "%", app.current_role reads "%"',
          v_change_type, v_role, current_setting('app.current_role', true);
      END IF;

      PERFORM set_config('app.current_role', 'admin', true);

      SELECT count(*) INTO v_event_count
      FROM events e
      JOIN event_participants ep ON ep.event_id = e.id
      WHERE ep.node_id = v_role_node
        AND e.event_type = 'domain_change'
        AND e.properties->>'operation' = v_change_type;

      IF v_event_count <> 1 THEN
        RAISE EXCEPTION
          'Role "%": expected exactly 1 domain_change event for %, got %',
          v_role, v_change_type, v_event_count;
      END IF;

      SELECT e.* INTO v_ev
      FROM events e
      JOIN event_participants ep ON ep.event_id = e.id
      WHERE ep.node_id = v_role_node
        AND e.event_type = 'domain_change'
        AND e.properties->>'operation' = v_change_type;

      IF v_ev.actor_system IS DISTINCT FROM 'system:cdc' THEN
        RAISE EXCEPTION
          'Role "%": the % event has actor_system %', v_role, v_change_type, v_ev.actor_system;
      END IF;
      IF v_ev.properties->>'session_role' IS DISTINCT FROM nullif(v_role, '') THEN
        RAISE EXCEPTION
          'Role "%": the % event recorded session_role %',
          v_role, v_change_type, coalesce(v_ev.properties->>'session_role', '<null>');
      END IF;

      PERFORM set_config('app.current_role', v_role, true);
    END LOOP;

    PERFORM set_config('app.current_role', 'admin', true);
  END LOOP;

  -- ======================================================================
  -- Obligation 14. The role is restored even when the CDC insert raises.
  --
  -- The failure is forced with a temporary guard on rye.events, because the
  -- obvious route -- deleting the mapped node out from under the mapping --
  -- is blocked by node_source_map's foreign key.
  -- ======================================================================
  PERFORM set_config('app.current_role', 'admin', true);
  v_role_node := link_record(
    p_source_schema := 'public',
    p_source_table  := '_rye_test_products',
    p_source_id     := '20',
    p_node_type     := 'product',
    p_label         := 'CDC failure probe'
  );

  CREATE OR REPLACE FUNCTION public._rye_test_cdc_boom() RETURNS trigger
  LANGUAGE plpgsql AS $boom$
  BEGIN
    IF NEW.properties->>'record_id' = '20' THEN
      RAISE EXCEPTION 'forced CDC failure';
    END IF;
    RETURN NEW;
  END;
  $boom$;

  CREATE TRIGGER zzz_rye_test_cdc_boom
    BEFORE INSERT ON rye.events
    FOR EACH ROW EXECUTE FUNCTION public._rye_test_cdc_boom();

  FOREACH v_role IN ARRAY ARRAY['', 'viewer', 'agent:t'] LOOP
    PERFORM set_config('app.current_role', v_role, true);
    v_failed := false;
    BEGIN
      INSERT INTO public._rye_test_products (id, name, price)
      VALUES (20, 'Boom', 1.00);
    EXCEPTION WHEN OTHERS THEN
      v_failed := true;
    END;
    IF NOT v_failed THEN
      RAISE EXCEPTION 'The forced CDC failure did not fire for role "%"', v_role;
    END IF;
    v_seen := coalesce(current_setting('app.current_role', true), '');
    IF v_seen IS DISTINCT FROM v_role THEN
      RAISE EXCEPTION
        'After a failed CDC insert as "%", app.current_role reads "%"', v_role, v_seen;
    END IF;
  END LOOP;

  PERFORM set_config('app.current_role', 'admin', true);
  DROP TRIGGER zzz_rye_test_cdc_boom ON rye.events;
  DROP FUNCTION public._rye_test_cdc_boom();

  -- ======================================================================
  -- Obligation 16, the CDC half. A mapping decides which node a tracked
  -- table's changes attach to, so a session that may not write must not be
  -- able to create one or re-point one. This is the file with a real tracked
  -- table, so it is where "and therefore no event attaches" is asserted;
  -- tests/conformance/32_who_may_write.sql asserts the raw mapping writes.
  -- ======================================================================
  PERFORM set_config('app.current_role', 'admin', true);
  INSERT INTO nodes (node_type, label, properties)
  VALUES ('product', 'Node the non-writer picked', '{"suite":"who_may_write"}')
  RETURNING id INTO v_chosen;

  v_role_node := link_record(
    p_source_schema := 'public',
    p_source_table  := '_rye_test_products',
    p_source_id     := '501',
    p_node_type     := 'product',
    p_label         := 'Operator mapping 501'
  );

  v_probe_id := 603;
  FOREACH v_role IN ARRAY ARRAY['viewer', ''] LOOP
    v_probe_id := v_probe_id + 1;
    PERFORM set_config('app.current_role', v_role, true);

    -- Map a source id of its choosing onto a node of its choosing.
    v_failed := false;
    BEGIN
      INSERT INTO node_source_map (node_id, source_schema, source_table, source_id)
      VALUES (v_chosen, 'public', '_rye_test_products', v_probe_id::text);
    EXCEPTION WHEN OTHERS THEN v_failed := true; END;
    IF NOT v_failed THEN
      RAISE EXCEPTION 'Role "%" inserted a source mapping for a tracked table', v_role;
    END IF;

    -- The domain write still succeeds -- Rye never gets in the way of the
    -- system of record -- but the row is unmapped, so nothing attaches.
    INSERT INTO public._rye_test_products (id, name, price)
    VALUES (v_probe_id, 'the non-writer chose this node and this text', 1.00);

    -- Re-point the operator's mapping on 501.
    v_rows := 0;
    BEGIN
      UPDATE node_source_map SET node_id = v_chosen
      WHERE source_schema = 'public' AND source_table = '_rye_test_products'
        AND source_id = '501';
      GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN v_rows := 0; END;
    IF v_rows <> 0 THEN
      RAISE EXCEPTION 'Role "%" re-pointed % mappings on a tracked table', v_role, v_rows;
    END IF;

    -- And a real change on 501 still attaches to the operator's node.
    UPDATE public._rye_test_products SET price = price + 1 WHERE id = 1;

    PERFORM set_config('app.current_role', 'admin', true);

    SELECT count(*) INTO v_event_count
    FROM events e
    JOIN event_participants ep ON ep.event_id = e.id
    WHERE ep.node_id = v_chosen;
    IF v_event_count <> 0 THEN
      RAISE EXCEPTION
        'Role "%" attached % events to the node it picked', v_role, v_event_count;
    END IF;

    SELECT count(*) INTO v_event_count
    FROM node_source_map
    WHERE source_schema = 'public' AND source_table = '_rye_test_products'
      AND source_id = '501' AND node_id = v_role_node;
    IF v_event_count <> 1 THEN
      RAISE EXCEPTION 'Role "%" changed the operator mapping on 501', v_role;
    END IF;
  END LOOP;

  PERFORM set_config('app.current_role', 'admin', true);

  -- Cleanup
  DROP TRIGGER IF EXISTS rye_cdc__rye_test_products ON public._rye_test_products;
  DROP TABLE public._rye_test_products;

  RAISE NOTICE 'domain_integration test passed';
END;
$$;
SQL
)"

echo "Domain integration (track_table + CDC) test passed"
