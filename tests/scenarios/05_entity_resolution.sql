-- Scenario 5: Entity Resolution and Audit Trail
-- Tests merge_nodes(), node_merges tracking, assertion supersession chains,
-- and agent audit logging via log_agent_query().

SET search_path = rye, public, pg_catalog;

BEGIN;

SET LOCAL "app.current_user_id" = 'user:admin-merge';
SET LOCAL "app.current_teams"   = '';
SET LOCAL "app.current_role"    = 'admin';

-- ============================================================
-- TEST 5a: Pre-merge state verification
-- ============================================================
DO $$
DECLARE
    v_john_edges int;
    v_jsmith_edges int;
    v_john_assertions int;
    v_jsmith_assertions int;
BEGIN
    -- Both John Smith copies exist and are not archived
    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = 'e0000001-0001-0001-0001-000000000001' AND archived_at IS NULL) THEN
        RAISE EXCEPTION 'S5-5a: John Smith (canonical) should exist and not be archived';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = 'e0000001-0001-0001-0001-000000000002' AND archived_at IS NULL) THEN
        RAISE EXCEPTION 'S5-5a: J. Smith (duplicate) should exist and not be archived';
    END IF;

    -- Each has edges
    SELECT count(*) INTO v_john_edges
    FROM edges WHERE source_id = 'e0000001-0001-0001-0001-000000000001' OR target_id = 'e0000001-0001-0001-0001-000000000001';
    SELECT count(*) INTO v_jsmith_edges
    FROM edges WHERE source_id = 'e0000001-0001-0001-0001-000000000002' OR target_id = 'e0000001-0001-0001-0001-000000000002';

    IF v_john_edges < 1 THEN RAISE EXCEPTION 'S5-5a: John Smith should have edges'; END IF;
    IF v_jsmith_edges < 1 THEN RAISE EXCEPTION 'S5-5a: J. Smith should have edges'; END IF;

    -- Each has assertions
    SELECT count(*) INTO v_john_assertions
    FROM current_assertions WHERE subject_node_id = 'e0000001-0001-0001-0001-000000000001';
    SELECT count(*) INTO v_jsmith_assertions
    FROM current_assertions WHERE subject_node_id = 'e0000001-0001-0001-0001-000000000002';

    IF v_john_assertions < 1 THEN RAISE EXCEPTION 'S5-5a: John Smith should have assertions'; END IF;
    IF v_jsmith_assertions < 1 THEN RAISE EXCEPTION 'S5-5a: J. Smith should have assertions'; END IF;
END;
$$;

-- ============================================================
-- TEST 5b: Execute merge (pair 1: J. Smith -> John Smith)
-- ============================================================
SELECT merge_nodes(
    'e0000001-0001-0001-0001-000000000002',  -- duplicate (J. Smith)
    'e0000001-0001-0001-0001-000000000001',  -- canonical (John Smith)
    'test-suite'
);

DO $$
DECLARE
    v_archived_at timestamptz;
    v_merge_count int;
    v_canonical_edges int;
    v_canonical_assertions int;
    v_dup_active_assertions int;
BEGIN
    -- Duplicate should be archived
    SELECT archived_at INTO v_archived_at
    FROM nodes WHERE id = 'e0000001-0001-0001-0001-000000000002';

    IF v_archived_at IS NULL THEN
        RAISE EXCEPTION 'S5-5b: duplicate should be archived after merge';
    END IF;

    -- node_merges should record the merge
    SELECT count(*) INTO v_merge_count
    FROM node_merges
    WHERE duplicate_id = 'e0000001-0001-0001-0001-000000000002'
      AND canonical_id = 'e0000001-0001-0001-0001-000000000001';

    IF v_merge_count <> 1 THEN
        RAISE EXCEPTION 'S5-5b: node_merges should have 1 record, got %', v_merge_count;
    END IF;

    -- Canonical should have all edges redirected to it
    SELECT count(*) INTO v_canonical_edges
    FROM edges
    WHERE (source_id = 'e0000001-0001-0001-0001-000000000001'
           OR target_id = 'e0000001-0001-0001-0001-000000000001')
      AND archived_at IS NULL;

    IF v_canonical_edges < 2 THEN
        RAISE EXCEPTION 'S5-5b: canonical should have at least 2 edges after merge, got %', v_canonical_edges;
    END IF;

    -- Canonical should have active assertions from both copies
    SELECT count(*) INTO v_canonical_assertions
    FROM current_assertions
    WHERE subject_node_id = 'e0000001-0001-0001-0001-000000000001';

    IF v_canonical_assertions < 2 THEN
        RAISE EXCEPTION 'S5-5b: canonical should have at least 2 active assertions, got %', v_canonical_assertions;
    END IF;

    -- Duplicate should have NO active assertions (all superseded)
    SELECT count(*) INTO v_dup_active_assertions
    FROM current_assertions
    WHERE subject_node_id = 'e0000001-0001-0001-0001-000000000002';

    IF v_dup_active_assertions <> 0 THEN
        RAISE EXCEPTION 'S5-5b: duplicate should have 0 active assertions, got %', v_dup_active_assertions;
    END IF;
END;
$$;

-- ============================================================
-- TEST 5c: Execute merge (pair 2: M. Garcia -> Maria Garcia)
-- ============================================================
SELECT merge_nodes(
    'e0000001-0001-0001-0001-000000000004',  -- duplicate (M. Garcia)
    'e0000001-0001-0001-0001-000000000003',  -- canonical (Maria Garcia)
    'test-suite'
);

DO $$
DECLARE
    v_merge_count int;
    v_events_on_canonical int;
BEGIN
    -- Two merges total now
    SELECT count(*) INTO v_merge_count FROM node_merges;
    IF v_merge_count <> 2 THEN
        RAISE EXCEPTION 'S5-5c: should have 2 merge records, got %', v_merge_count;
    END IF;

    -- Events that were linked to M. Garcia should now be accessible via Maria Garcia
    SELECT count(*) INTO v_events_on_canonical
    FROM event_participants
    WHERE node_id = 'e0000001-0001-0001-0001-000000000003';

    IF v_events_on_canonical < 1 THEN
        RAISE EXCEPTION 'S5-5c: canonical Maria should have event participations after merge';
    END IF;
END;
$$;

-- ============================================================
-- TEST 5d: Unmerged pair 3 (Robert/Rob Chen) should still have separate data
-- ============================================================
DO $$
DECLARE
    v_robert_active int;
    v_rob_active int;
BEGIN
    SELECT count(*) INTO v_robert_active
    FROM current_assertions WHERE subject_node_id = 'e0000001-0001-0001-0001-000000000005';
    SELECT count(*) INTO v_rob_active
    FROM current_assertions WHERE subject_node_id = 'e0000001-0001-0001-0001-000000000006';

    IF v_robert_active < 1 THEN RAISE EXCEPTION 'S5-5d: Robert should still have assertions'; END IF;
    IF v_rob_active < 1 THEN RAISE EXCEPTION 'S5-5d: Rob should still have assertions'; END IF;

    -- Both should not be archived
    IF EXISTS (SELECT 1 FROM nodes WHERE id = 'e0000001-0001-0001-0001-000000000005' AND archived_at IS NOT NULL) THEN
        RAISE EXCEPTION 'S5-5d: Robert should NOT be archived';
    END IF;
    IF EXISTS (SELECT 1 FROM nodes WHERE id = 'e0000001-0001-0001-0001-000000000006' AND archived_at IS NOT NULL) THEN
        RAISE EXCEPTION 'S5-5d: Rob should NOT be archived';
    END IF;
END;
$$;

-- ============================================================
-- TEST 5e: Supersession chain traversal
-- ============================================================
DO $$
DECLARE
    v_chain_length int;
BEGIN
    -- After merge, the duplicate's assertion was superseded.
    -- Walk the chain: find assertions that have been superseded and follow superseded_by.
    -- John Smith's lead_score was original on canonical, plus J. Smith's was superseded -> canonical copy.
    -- The superseded assertion should have superseded_by pointing to the new one.
    SELECT count(*) INTO v_chain_length
    FROM assertions
    WHERE subject_node_id = 'e0000001-0001-0001-0001-000000000002'
      AND superseded_at IS NOT NULL
      AND superseded_by IS NOT NULL;

    IF v_chain_length < 1 THEN
        RAISE EXCEPTION 'S5-5e: should have at least 1 superseded assertion in chain, got %', v_chain_length;
    END IF;
END;
$$;

-- ============================================================
-- TEST 5f: current_assertions view only shows non-superseded
-- ============================================================
DO $$
DECLARE
    v_any_superseded int;
BEGIN
    SELECT count(*) INTO v_any_superseded
    FROM current_assertions
    WHERE superseded_at IS NOT NULL;

    IF v_any_superseded <> 0 THEN
        RAISE EXCEPTION 'S5-5f: current_assertions should never have superseded rows, got %', v_any_superseded;
    END IF;
END;
$$;

-- ============================================================
-- TEST 5g: Agent audit trail via log_agent_query()
-- ============================================================
DO $$
DECLARE
    v_audit_event_id uuid;
    v_event_count int;
BEGIN
    v_audit_event_id := log_agent_query(
        'test-agent',
        'SELECT * FROM nodes WHERE node_type = ''person''',
        'Found 10 person nodes',
        ARRAY['e0000001-0001-0001-0001-000000000001', 'e0000001-0001-0001-0001-000000000003']::uuid[]
    );

    IF v_audit_event_id IS NULL THEN
        RAISE EXCEPTION 'S5-5g: log_agent_query should return an event id';
    END IF;

    -- Verify the event is immutable
    SELECT count(*) INTO v_event_count
    FROM events
    WHERE id = v_audit_event_id
      AND event_type = 'agent_query'
      AND properties->>'agent_id' = 'test-agent';

    IF v_event_count <> 1 THEN
        RAISE EXCEPTION 'S5-5g: agent_query event should exist with correct properties';
    END IF;

    -- Verify participants were created
    SELECT count(*) INTO v_event_count
    FROM event_participants
    WHERE event_id = v_audit_event_id;

    IF v_event_count <> 2 THEN
        RAISE EXCEPTION 'S5-5g: agent_query should have 2 participants, got %', v_event_count;
    END IF;
END;
$$;

-- ============================================================
-- TEST 5h: node_source_map redirected after merge
-- ============================================================
DO $$
DECLARE
    v_canonical_sources int;
    v_dup_sources int;
BEGIN
    SELECT count(*) INTO v_canonical_sources
    FROM node_source_map
    WHERE node_id = 'e0000001-0001-0001-0001-000000000001';

    SELECT count(*) INTO v_dup_sources
    FROM node_source_map
    WHERE node_id = 'e0000001-0001-0001-0001-000000000002';

    -- Canonical should have both sources now
    IF v_canonical_sources < 2 THEN
        RAISE EXCEPTION 'S5-5h: canonical should have at least 2 source maps, got %', v_canonical_sources;
    END IF;

    -- Duplicate should have 0 source maps
    IF v_dup_sources <> 0 THEN
        RAISE EXCEPTION 'S5-5h: duplicate should have 0 source maps, got %', v_dup_sources;
    END IF;
END;
$$;

ROLLBACK;
