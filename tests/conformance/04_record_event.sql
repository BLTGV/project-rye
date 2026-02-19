-- FN-07: record_event() should create event + participants atomically and return UUID.

DO $$
DECLARE
  v_node_a uuid;
  v_node_b uuid;
  v_event_id uuid;
  v_participant_count int;
  v_event_type text;
  v_summary text;
  v_error boolean := false;
BEGIN
  INSERT INTO nodes (node_type, label, properties)
  VALUES ('person', 'RecordEvent Test A', '{"suite": "conformance"}')
  RETURNING id INTO v_node_a;

  INSERT INTO nodes (node_type, label, properties)
  VALUES ('org', 'RecordEvent Test B', '{"suite": "conformance"}')
  RETURNING id INTO v_node_b;

  -- Create event with participants
  v_event_id := record_event(
    p_event_type        := 'meeting',
    p_summary           := 'Conformance test meeting',
    p_properties        := '{"location": "test"}',
    p_participant_ids   := ARRAY[v_node_a, v_node_b],
    p_participant_roles := ARRAY['organizer', 'attendee'],
    p_actor             := 'test:conformance'
  );

  IF v_event_id IS NULL THEN
    RAISE EXCEPTION 'record_event() returned NULL';
  END IF;

  -- Verify event exists
  SELECT event_type, summary INTO v_event_type, v_summary
  FROM events WHERE id = v_event_id;

  IF v_event_type <> 'meeting' THEN
    RAISE EXCEPTION 'Expected event_type=meeting, got %', v_event_type;
  END IF;

  -- Verify participants
  SELECT count(*) INTO v_participant_count
  FROM event_participants WHERE event_id = v_event_id;

  IF v_participant_count <> 2 THEN
    RAISE EXCEPTION 'Expected 2 participants, got %', v_participant_count;
  END IF;

  -- Verify mismatched array lengths raise error
  BEGIN
    PERFORM record_event(
      p_event_type        := 'test',
      p_summary           := 'Should fail',
      p_participant_ids   := ARRAY[v_node_a],
      p_participant_roles := ARRAY['a', 'b']
    );
  EXCEPTION WHEN OTHERS THEN
    v_error := true;
  END;

  IF NOT v_error THEN
    RAISE EXCEPTION 'Expected error for mismatched participant array lengths';
  END IF;

END;
$$;
