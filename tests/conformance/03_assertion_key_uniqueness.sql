-- FN-02 extension: enforce uniqueness per (subject, type, key) while allowing multiple keys.

SET search_path = rye, public, pg_catalog;

DO $$
DECLARE
  v_node uuid;
  v_dup_error boolean := false;
BEGIN
  INSERT INTO nodes (node_type, label, properties)
  VALUES ('parcel', 'Assertion Key Test', '{"suite": "conformance"}')
  RETURNING id INTO v_node;

  INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
  VALUES ('ownership', 'owner:a', v_node, '{"owner": "a", "fraction": "1/2"}', 1.0);

  -- Different key should be allowed.
  INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
  VALUES ('ownership', 'owner:b', v_node, '{"owner": "b", "fraction": "1/2"}', 1.0);

  BEGIN
    -- Same key/type/subject and still active should fail.
    INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
    VALUES ('ownership', 'owner:a', v_node, '{"owner": "a", "fraction": "1/4"}', 0.5);
  EXCEPTION WHEN unique_violation THEN
    v_dup_error := true;
  END;

  IF NOT v_dup_error THEN
    RAISE EXCEPTION 'Expected unique violation for duplicate active assertion key';
  END IF;

END;
$$;
