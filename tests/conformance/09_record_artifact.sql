-- Test: record_artifact() function (Gap 2 fix)

DO $$
DECLARE
    v_node_id uuid;
    v_event_id uuid;
    v_artifact_id uuid;
    v_artifact_id_2 uuid;
    v_artifact_id_3 uuid;
    v_content_hash text;
    v_artifact_type text;
BEGIN
    -- Setup: create a source node and event
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('document', 'Test Document', '{"suite": "conformance"}')
    RETURNING id INTO v_node_id;

    v_event_id := record_event(
        p_event_type     := 'document_parse',
        p_summary        := 'Parsed test document',
        p_participant_ids := ARRAY[v_node_id],
        p_participant_roles := ARRAY['subject'],
        p_actor          := 'agent:parser'
    );

    -- Test 1: Basic artifact creation
    v_artifact_id := record_artifact(
        p_artifact_type    := 'document_parse',
        p_content          := '{"title": "Q4 Report", "pages": 12}',
        p_source_event_id  := v_event_id,
        p_source_node_id   := v_node_id,
        p_related_node_ids := ARRAY[v_node_id],
        p_location         := '{"page": 1, "section": "header"}'
    );

    IF v_artifact_id IS NULL THEN
        RAISE EXCEPTION 'FAIL: record_artifact() returned NULL';
    END IF;

    SELECT artifact_type INTO v_artifact_type
    FROM artifacts WHERE id = v_artifact_id;

    IF v_artifact_type <> 'document_parse' THEN
        RAISE EXCEPTION 'FAIL: artifact type mismatch, got %', v_artifact_type;
    END IF;
    RAISE NOTICE 'PASS: record_artifact() creates artifact';

    -- Test 2: Content hash dedup — first call creates
    v_artifact_id_2 := record_artifact(
        p_artifact_type := 'document_parse',
        p_content       := '{"title": "Same Doc"}',
        p_content_hash  := 'sha256:test-hash-001'
    );

    SELECT attrs->>'content_hash' INTO v_content_hash
    FROM artifacts WHERE id = v_artifact_id_2;

    IF v_content_hash <> 'sha256:test-hash-001' THEN
        RAISE EXCEPTION 'FAIL: content_hash not stored in attrs, got %', v_content_hash;
    END IF;
    RAISE NOTICE 'PASS: content_hash stored in attrs';

    -- Test 3: Content hash dedup — second call returns existing
    v_artifact_id_3 := record_artifact(
        p_artifact_type := 'document_parse',
        p_content       := '{"title": "Different Content"}',
        p_content_hash  := 'sha256:test-hash-001'
    );

    IF v_artifact_id_3 <> v_artifact_id_2 THEN
        RAISE EXCEPTION 'FAIL: dedup failed — got new id % instead of existing %', v_artifact_id_3, v_artifact_id_2;
    END IF;
    RAISE NOTICE 'PASS: content_hash dedup returns existing artifact';

    -- Test 4: Different type with same hash creates new artifact
    v_artifact_id_3 := record_artifact(
        p_artifact_type := 'table_extract',
        p_content       := '{"headers": ["col1"]}',
        p_content_hash  := 'sha256:test-hash-001'
    );

    IF v_artifact_id_3 = v_artifact_id_2 THEN
        RAISE EXCEPTION 'FAIL: different artifact_type with same hash should create new artifact';
    END IF;
    RAISE NOTICE 'PASS: different type with same hash creates new artifact';

    -- Test 5: No content_hash means no dedup (always creates)
    v_artifact_id_2 := record_artifact(
        p_artifact_type := 'document_parse',
        p_content       := '{"title": "No Hash 1"}'
    );
    v_artifact_id_3 := record_artifact(
        p_artifact_type := 'document_parse',
        p_content       := '{"title": "No Hash 2"}'
    );

    IF v_artifact_id_2 = v_artifact_id_3 THEN
        RAISE EXCEPTION 'FAIL: no-hash calls should create separate artifacts';
    END IF;
    RAISE NOTICE 'PASS: no content_hash always creates new artifact';

    RAISE NOTICE 'All record_artifact tests passed';
END;
$$;
