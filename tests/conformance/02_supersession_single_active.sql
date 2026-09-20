-- FN-02: Supersession should preserve history and keep one active row per key.

SET search_path = rye, public, pg_catalog;

-- This file writes core tables, and scripts/conformance.sh runs each SQL file
-- in its own psql session, so an unset app.current_role is an unset role for
-- the whole file. Since migration 0026 only a role the role list says may
-- write may write; this flow is an operator setting the instance up.
SELECT set_config('app.current_role', 'admin', false) \g /dev/null

DO $$
DECLARE
  v_node uuid;
  v_old uuid;
  v_new uuid;
  v_active_count int;
BEGIN
  INSERT INTO nodes (node_type, label, properties)
  VALUES ('project', 'Supersession Test', '{"suite": "conformance"}')
  RETURNING id INTO v_node;

  INSERT INTO assertions (
    assertion_type,
    assertion_key,
    subject_node_id,
    claim,
    confidence,
    basis
  ) VALUES (
    'project_status',
    'default',
    v_node,
    '{"status": "active", "health": "on_track"}',
    1.0,
    'assumed'
  )
  RETURNING id INTO v_old;

  v_new := supersede_assertion(
    p_old_assertion_id := v_old,
    p_new_assertion_type := 'project_status',
    p_new_subject_node_id := v_node,
    p_new_subject_edge_id := NULL,
    p_new_claim := '{"status": "active", "health": "at_risk"}',
    p_new_assertion_key := 'default',
    p_new_confidence := 0.9
  );

  SELECT count(*) INTO v_active_count
  FROM current_assertions
  WHERE subject_node_id = v_node
    AND assertion_type = 'project_status'
    AND assertion_key = 'default';

  IF v_active_count <> 1 THEN
    RAISE EXCEPTION 'Expected 1 active assertion, got %', v_active_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM assertions
    WHERE id = v_old
      AND superseded_by = v_new
      AND superseded_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Expected old assertion to be superseded by the new assertion';
  END IF;

END;
$$;
