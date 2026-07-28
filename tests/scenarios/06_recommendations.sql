-- Additional Recommendation Tests
-- R1: Temporal boundary testing
-- R3: Cross-scenario entity sharing
-- R4: Negative aggregate tests
-- R5: Assertion-type gating boundary tests
-- R6: Agent write-path exhaustive test
-- R7: Field redaction in aggregates
-- (R2: Concurrent supersession is tested in a separate shell script)

SET search_path = rye, public, pg_catalog;

BEGIN;

-- ============================================================
-- R1: Temporal Boundary Testing
-- Time-scoped edge queries return different results based on date
-- ============================================================
SET LOCAL "app.current_user_id" = 'user:admin-1';
SET LOCAL "app.current_teams"   = '';
SET LOCAL "app.current_role"    = 'admin';

DO $$
DECLARE
    v_current_owner text;
    v_historical_owner text;
    v_historical_count int;
BEGIN
    -- Current assignment: Alice (via effective_from=now(), no effective_to)
    SELECT n.label INTO v_current_owner
    FROM edges e
    JOIN nodes n ON n.id = e.target_id
    WHERE e.source_id = 'a0000001-0005-0001-0001-000000000001'
      AND e.edge_type = 'assigned_to'
      AND e.properties->>'role' = 'owner'
      AND e.effective_to IS NULL
      AND e.archived_at IS NULL
    ORDER BY e.effective_from DESC
    LIMIT 1;

    IF v_current_owner IS NULL THEN
        RAISE EXCEPTION 'R1: should have a current owner for opp 1';
    END IF;

    -- Historical assignment: Bob was owner 90 to 30 days ago
    SELECT n.label INTO v_historical_owner
    FROM edges e
    JOIN nodes n ON n.id = e.target_id
    WHERE e.source_id = 'a0000001-0005-0001-0001-000000000001'
      AND e.edge_type = 'assigned_to'
      AND e.properties->>'role' = 'owner'
      AND e.effective_from <= (now() - interval '45 days')
      AND (e.effective_to IS NULL OR e.effective_to >= (now() - interval '45 days'))
    ORDER BY e.effective_from DESC
    LIMIT 1;

    IF v_historical_owner IS NULL THEN
        RAISE EXCEPTION 'R1: should find a historical owner 45 days ago';
    END IF;

    -- The current and historical owners should be different people
    IF v_current_owner = v_historical_owner THEN
        RAISE EXCEPTION 'R1: current owner (%) should differ from historical owner (%)',
            v_current_owner, v_historical_owner;
    END IF;

    -- Count expired edges: at least 1 (the historical assignment)
    SELECT count(*) INTO v_historical_count
    FROM edges
    WHERE effective_to IS NOT NULL AND effective_to < now();

    IF v_historical_count < 1 THEN
        RAISE EXCEPTION 'R1: should have at least 1 expired edge, got %', v_historical_count;
    END IF;
END;
$$;

-- ============================================================
-- R3: Cross-Scenario Entity Sharing
-- Maya Cross appears in both CRM (Scenario 1) and Support (Scenario 3)
-- Access in one domain must not leak into another
-- ============================================================

-- Sales-east sees Maya via CRM primary_contact edge
SET LOCAL "app.current_user_id" = 'user:alice';
SET LOCAL "app.current_teams"   = 'sales-east';
SET LOCAL "app.current_role"    = 'team_member';

DO $$
DECLARE
    v_maya_visible int;
    v_maya_support_edge int;
BEGIN
    -- Maya (public, no classification) should be visible to anyone
    SELECT count(*) INTO v_maya_visible
    FROM nodes WHERE id = 'a0000001-0003-0001-0001-000000000005';

    IF v_maya_visible <> 1 THEN
        RAISE EXCEPTION 'R3: sales-east should see Maya Cross';
    END IF;

    -- But the support ticket edge (regarding) links Maya to a support ticket.
    -- Sales-east can see Maya, and can see ticket 1 (support-t1 team, but ticket
    -- has public classification), so the edge may be visible.
    -- The key test: seeing Maya in CRM doesn't give sales-east access to
    -- support-t2/escalation-only tickets.
    SELECT count(*) INTO v_maya_support_edge
    FROM edges e
    WHERE e.edge_type = 'regarding'
      AND e.target_id = 'a0000001-0003-0001-0001-000000000005'
      AND e.source_id::text LIKE 'c0000001-0004%';

    -- This edge connects ticket 1 (visible to all via support-t1 team) to Maya (public).
    -- Both endpoints visible, so edge is visible. That's fine - it's a public ticket.
    -- The important thing is that CONFIDENTIAL tickets are NOT visible.
    IF v_maya_support_edge > 1 THEN
        RAISE EXCEPTION 'R3: sales-east should see at most 1 support edge for Maya, got %', v_maya_support_edge;
    END IF;
END;
$$;

-- ============================================================
-- R4: Negative Aggregate Tests
-- SUM, COUNT, AVG return different values for different roles
-- ============================================================
DO $$
DECLARE
    v_east_sum numeric;
    v_admin_sum numeric;
    v_east_count int;
    v_admin_count int;
    v_east_avg numeric;
    v_admin_avg numeric;
BEGIN
    -- Sales-east aggregates
    SET LOCAL "app.current_user_id" = 'user:alice';
    SET LOCAL "app.current_teams" = 'sales-east';
    SET LOCAL "app.current_role" = 'team_member';

    SELECT coalesce(sum((ca.claim->>'amount')::numeric), 0),
           count(*),
           coalesce(avg((ca.claim->>'amount')::numeric), 0)
    INTO v_east_sum, v_east_count, v_east_avg
    FROM current_assertions ca
    JOIN nodes n ON n.id = ca.subject_node_id
    WHERE n.node_type = 'opportunity'
      AND ca.assertion_type = 'deal_value';

    -- Admin aggregates
    SET LOCAL "app.current_user_id" = 'user:admin-1';
    SET LOCAL "app.current_teams" = '';
    SET LOCAL "app.current_role" = 'admin';

    SELECT coalesce(sum((ca.claim->>'amount')::numeric), 0),
           count(*),
           coalesce(avg((ca.claim->>'amount')::numeric), 0)
    INTO v_admin_sum, v_admin_count, v_admin_avg
    FROM current_assertions ca
    JOIN nodes n ON n.id = ca.subject_node_id
    WHERE n.node_type = 'opportunity'
      AND ca.assertion_type = 'deal_value';

    -- All three aggregate values MUST differ
    IF v_east_sum = v_admin_sum THEN
        RAISE EXCEPTION 'R4: SUM should differ between east(%) and admin(%)', v_east_sum, v_admin_sum;
    END IF;

    IF v_east_count = v_admin_count THEN
        RAISE EXCEPTION 'R4: COUNT should differ between east(%) and admin(%)', v_east_count, v_admin_count;
    END IF;

    IF v_east_avg = v_admin_avg THEN
        RAISE EXCEPTION 'R4: AVG should differ between east(%) and admin(%)', v_east_avg, v_admin_avg;
    END IF;
END;
$$;

-- ============================================================
-- R5: Assertion-Type Gating Boundary Tests
-- Test exact role boundaries for each gated assertion type
-- ============================================================
DO $$
DECLARE
    v_count int;
BEGIN
    -- team_member: NO financial_terms
    SET LOCAL "app.current_role" = 'team_member';
    SET LOCAL "app.current_teams" = 'sales-east';
    SELECT count(*) INTO v_count FROM current_assertions WHERE assertion_type = 'financial_terms';
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'R5: team_member should see 0 financial_terms, got %', v_count;
    END IF;

    -- team_lead: NO financial_terms
    SET LOCAL "app.current_role" = 'team_lead';
    SELECT count(*) INTO v_count FROM current_assertions WHERE assertion_type = 'financial_terms';
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'R5: team_lead should see 0 financial_terms, got %', v_count;
    END IF;

    -- deal_manager: YES financial_terms
    SET LOCAL "app.current_role" = 'deal_manager';
    SELECT count(*) INTO v_count FROM current_assertions WHERE assertion_type = 'financial_terms';
    IF v_count < 1 THEN
        RAISE EXCEPTION 'R5: deal_manager should see financial_terms, got %', v_count;
    END IF;

    -- finance: YES financial_terms
    SET LOCAL "app.current_role" = 'finance';
    SET LOCAL "app.current_teams" = 'finance';
    SELECT count(*) INTO v_count FROM current_assertions WHERE assertion_type = 'financial_terms';
    IF v_count < 1 THEN
        RAISE EXCEPTION 'R5: finance should see financial_terms, got %', v_count;
    END IF;

    -- team_member: NO negotiation_stance
    SET LOCAL "app.current_role" = 'team_member';
    SET LOCAL "app.current_teams" = 'sales-east';
    SELECT count(*) INTO v_count FROM current_assertions WHERE assertion_type = 'negotiation_stance';
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'R5: team_member should see 0 negotiation_stance, got %', v_count;
    END IF;

    -- deal_manager: YES negotiation_stance
    SET LOCAL "app.current_role" = 'deal_manager';
    SELECT count(*) INTO v_count FROM current_assertions WHERE assertion_type = 'negotiation_stance';
    IF v_count < 1 THEN
        RAISE EXCEPTION 'R5: deal_manager should see negotiation_stance, got %', v_count;
    END IF;

    -- finance: NO negotiation_stance
    SET LOCAL "app.current_role" = 'finance';
    SET LOCAL "app.current_teams" = 'finance';
    SELECT count(*) INTO v_count FROM current_assertions WHERE assertion_type = 'negotiation_stance';
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'R5: finance should see 0 negotiation_stance, got %', v_count;
    END IF;

    -- team_member: NO compensation
    SET LOCAL "app.current_role" = 'team_member';
    SET LOCAL "app.current_teams" = 'ma-team';
    SELECT count(*) INTO v_count FROM current_assertions WHERE assertion_type = 'compensation';
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'R5: team_member should see 0 compensation, got %', v_count;
    END IF;

    -- hr_admin: YES compensation
    SET LOCAL "app.current_role" = 'hr_admin';
    SELECT count(*) INTO v_count FROM current_assertions WHERE assertion_type = 'compensation';
    IF v_count >= 1 THEN
        -- Good, hr_admin can see compensation
        NULL;
    ELSE
        RAISE EXCEPTION 'R5: hr_admin should see compensation, got %', v_count;
    END IF;

    -- deal_manager: NO compensation
    SET LOCAL "app.current_role" = 'deal_manager';
    SELECT count(*) INTO v_count FROM current_assertions WHERE assertion_type = 'compensation';
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'R5: deal_manager should see 0 compensation, got %', v_count;
    END IF;
END;
$$;

-- ============================================================
-- R6: Agent Write-Path Exhaustive Test
-- Comprehensive agent capability verification
-- ============================================================
SET LOCAL "app.current_user_id" = 'agent:test-agent';
SET LOCAL "app.current_teams"   = '';
SET LOCAL "app.current_role"    = 'agent:test-agent';

DO $$
DECLARE
    v_blocked boolean;
    v_assertion_id uuid;
    v_new_id uuid;
    v_rows int;
BEGIN
    -- 1. Agent CAN insert ungated assertions
    INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence, basis) VALUES ('sentiment', 'agent-r6-test', 'a0000001-0003-0001-0001-000000000001',
            '{"sentiment":"agent-tested"}', 0.5, 'assumed')
    RETURNING id INTO v_assertion_id;

    IF v_assertion_id IS NULL THEN
        RAISE EXCEPTION 'R6: agent should be able to INSERT ungated assertions';
    END IF;

    -- 2. Agent CAN call supersede_assertion()
    v_new_id := supersede_assertion(
        p_old_assertion_id := v_assertion_id,
        p_new_assertion_type := 'sentiment',
        p_new_subject_node_id := 'a0000001-0003-0001-0001-000000000001',
        p_new_subject_edge_id := NULL,
        p_new_claim := '{"sentiment":"agent-updated"}',
        p_new_assertion_key := 'agent-r6-test',
        p_new_confidence := 0.6
    );

    IF v_new_id IS NULL THEN
        RAISE EXCEPTION 'R6: agent should be able to call supersede_assertion()';
    END IF;

    -- 3. Agent CANNOT do direct UPDATE on assertions (RLS silently blocks — 0 rows)
    UPDATE assertions SET superseded_at = now() WHERE id = v_new_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'R6: agent UPDATE on assertions should affect 0 rows, got %', v_rows;
    END IF;

    -- 4. Agent CAN INSERT nodes (agent-native design)
    DECLARE
        v_agent_node uuid;
    BEGIN
        INSERT INTO nodes (node_type, label, properties)
        VALUES ('test', 'Agent Node', '{}')
        RETURNING id INTO v_agent_node;

        IF v_agent_node IS NULL THEN
            RAISE EXCEPTION 'R6: agent should be able to INSERT nodes';
        END IF;

        -- But cannot UPDATE
        UPDATE nodes SET label = 'Modified' WHERE id = v_agent_node;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows > 0 THEN
            RAISE EXCEPTION 'R6: agent should NOT be able to UPDATE nodes';
        END IF;
    END;

    -- 5. Agent CAN INSERT edges
    DECLARE
        v_agent_edge uuid;
    BEGIN
        INSERT INTO edges (edge_type, source_id, target_id)
        VALUES ('test', 'a0000001-0003-0001-0001-000000000001', 'a0000001-0003-0001-0001-000000000002')
        RETURNING id INTO v_agent_edge;

        IF v_agent_edge IS NULL THEN
            RAISE EXCEPTION 'R6: agent should be able to INSERT edges';
        END IF;

        -- But cannot UPDATE
        UPDATE edges SET properties = '{"modified": true}' WHERE id = v_agent_edge;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows > 0 THEN
            RAISE EXCEPTION 'R6: agent should NOT be able to UPDATE edges';
        END IF;
    END;

    -- 6. Agent CAN INSERT artifacts
    DECLARE
        v_agent_artifact uuid;
    BEGIN
        INSERT INTO artifacts (artifact_type, content)
        VALUES ('test', '{"data":"agent-test"}')
        RETURNING id INTO v_agent_artifact;

        IF v_agent_artifact IS NULL THEN
            RAISE EXCEPTION 'R6: agent should be able to INSERT artifacts';
        END IF;

        -- But cannot UPDATE
        UPDATE artifacts SET content = '{"modified": true}' WHERE id = v_agent_artifact;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows > 0 THEN
            RAISE EXCEPTION 'R6: agent should NOT be able to UPDATE artifacts';
        END IF;
    END;

    -- 7. Agent CANNOT DELETE assertions (RLS silently blocks — 0 rows)
    DELETE FROM assertions WHERE id = v_new_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'R6: agent DELETE on assertions should affect 0 rows, got %', v_rows;
    END IF;

    -- 8. Agent CANNOT DELETE events (RLS silently blocks — 0 rows)
    DELETE FROM events WHERE id = (SELECT id FROM events LIMIT 1);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'R6: agent DELETE on events should affect 0 rows, got %', v_rows;
    END IF;

    -- 9. Agent CAN insert event_participants
    -- (already proven by log_agent_query, but let's verify directly)
    INSERT INTO event_participants (event_id, node_id, role)
    SELECT e.id, 'a0000001-0003-0001-0001-000000000001', 'agent-tested'
    FROM events e
    LIMIT 1
    ON CONFLICT DO NOTHING;

    -- If we get here without error, agent can insert event_participants
END;
$$;

-- ============================================================
-- R7: Field Redaction in Aggregates
-- nodes_secure should strip fields even in subqueries/CTEs
-- ============================================================
SET LOCAL "app.current_user_id" = 'user:regular';
SET LOCAL "app.current_teams"   = '';
SET LOCAL "app.current_role"    = 'team_member';

DO $$
DECLARE
    v_has_ssn boolean;
    v_has_salary boolean;
    v_admin_has_ssn boolean;
BEGIN
    -- team_member: SSN (restricted) should be stripped
    SELECT EXISTS(
        SELECT 1
        FROM nodes_secure
        WHERE node_type = 'person'
          AND properties->>'ssn' IS NOT NULL
    ) INTO v_has_ssn;

    IF v_has_ssn THEN
        RAISE EXCEPTION 'R7: team_member should NOT see SSN via nodes_secure';
    END IF;

    -- team_member: salary (restricted) should be stripped
    SELECT EXISTS(
        SELECT 1
        FROM nodes_secure
        WHERE node_type = 'person'
          AND properties->>'salary' IS NOT NULL
    ) INTO v_has_salary;

    IF v_has_salary THEN
        RAISE EXCEPTION 'R7: team_member should NOT see salary via nodes_secure';
    END IF;

    -- Verify admin CAN see SSN via nodes_secure
    SET LOCAL "app.current_role" = 'admin';
    SELECT EXISTS(
        SELECT 1
        FROM nodes_secure
        WHERE node_type = 'person'
          AND properties->>'ssn' IS NOT NULL
    ) INTO v_admin_has_ssn;

    IF NOT v_admin_has_ssn THEN
        RAISE EXCEPTION 'R7: admin should see SSN via nodes_secure';
    END IF;
END;
$$;

-- ============================================================
-- R7b: Field redaction in CTE aggregates
-- ============================================================
SET LOCAL "app.current_role" = 'team_member';
SET LOCAL "app.current_teams" = '';

DO $$
DECLARE
    v_salary_sum numeric;
BEGIN
    -- Attempt to SUM salary via nodes_secure CTE - should yield NULL/0
    WITH person_data AS (
        SELECT (properties->>'salary')::numeric AS salary
        FROM nodes_secure
        WHERE node_type = 'person'
    )
    SELECT coalesce(sum(salary), 0) INTO v_salary_sum FROM person_data;

    IF v_salary_sum <> 0 THEN
        RAISE EXCEPTION 'R7b: team_member salary sum via CTE should be 0, got %', v_salary_sum;
    END IF;
END;
$$;

-- ============================================================
-- R8: Assertion INSERT gating
-- team_member cannot INSERT financial_terms/compensation assertions
-- ============================================================
SET LOCAL "app.current_user_id" = 'user:alice';
SET LOCAL "app.current_teams"   = 'sales-east';
SET LOCAL "app.current_role"    = 'team_member';

DO $$
DECLARE
    v_blocked boolean;
BEGIN
    -- team_member cannot INSERT financial_terms
    v_blocked := false;
    BEGIN
        INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence, basis) VALUES ('financial_terms', 'test', 'a0000001-0005-0001-0001-000000000001',
                '{"payment_terms":"net-30"}', 0.8, 'assumed');
    EXCEPTION WHEN OTHERS THEN
        v_blocked := true;
    END;
    IF NOT v_blocked THEN
        RAISE EXCEPTION 'R8: team_member should NOT be able to INSERT financial_terms assertions';
    END IF;

    -- team_member cannot INSERT compensation
    v_blocked := false;
    BEGIN
        INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence, basis) VALUES ('compensation', 'test', 'a0000001-0003-0001-0001-000000000001',
                '{"salary":100000}', 0.8, 'assumed');
    EXCEPTION WHEN OTHERS THEN
        v_blocked := true;
    END;
    IF NOT v_blocked THEN
        RAISE EXCEPTION 'R8: team_member should NOT be able to INSERT compensation assertions';
    END IF;

    -- deal_manager CAN insert financial_terms but NOT compensation
    SET LOCAL "app.current_role" = 'deal_manager';

    INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence, basis) VALUES ('financial_terms', 'r8-test', 'a0000001-0005-0001-0001-000000000001',
            '{"payment_terms":"net-60"}', 0.9, 'assumed');

    v_blocked := false;
    BEGIN
        INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence, basis) VALUES ('compensation', 'r8-test', 'a0000001-0003-0001-0001-000000000001',
                '{"salary":200000}', 0.8, 'assumed');
    EXCEPTION WHEN OTHERS THEN
        v_blocked := true;
    END;
    IF NOT v_blocked THEN
        RAISE EXCEPTION 'R8: deal_manager should NOT be able to INSERT compensation assertions';
    END IF;
END;
$$;

-- ============================================================
-- R9: Agent edge/artifact UPDATE/DELETE restrictions
-- ============================================================
SET LOCAL "app.current_user_id" = 'agent:test-agent';
SET LOCAL "app.current_teams"   = '';
SET LOCAL "app.current_role"    = 'agent:test-agent';

DO $$
DECLARE
    v_rows int;
    v_blocked boolean;
BEGIN
    -- Agent cannot UPDATE edges (RLS silently blocks)
    UPDATE edges SET properties = '{"tampered":true}' WHERE id = (SELECT id FROM edges LIMIT 1);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'R9: agent UPDATE on edges should affect 0 rows, got %', v_rows;
    END IF;

    -- Agent cannot DELETE edges (RLS silently blocks)
    DELETE FROM edges WHERE id = (SELECT id FROM edges LIMIT 1);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'R9: agent DELETE on edges should affect 0 rows, got %', v_rows;
    END IF;

    -- Agent cannot DELETE nodes
    DELETE FROM nodes WHERE id = (SELECT id FROM nodes LIMIT 1);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'R9: agent DELETE on nodes should affect 0 rows, got %', v_rows;
    END IF;

    -- Agent cannot UPDATE artifacts (RLS silently blocks)
    UPDATE artifacts SET content = '{"tampered":true}' WHERE id = (SELECT id FROM artifacts LIMIT 1);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'R9: agent UPDATE on artifacts should affect 0 rows, got %', v_rows;
    END IF;

    -- Agent cannot DELETE artifacts (RLS silently blocks)
    DELETE FROM artifacts WHERE id = (SELECT id FROM artifacts LIMIT 1);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'R9: agent DELETE on artifacts should affect 0 rows, got %', v_rows;
    END IF;

    -- Agent cannot UPDATE event_participants (RLS silently blocks)
    UPDATE event_participants SET role = 'tampered' WHERE id = (SELECT id FROM event_participants LIMIT 1);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'R9: agent UPDATE on event_participants should affect 0 rows, got %', v_rows;
    END IF;

    -- Agent cannot DELETE event_participants (RLS silently blocks)
    DELETE FROM event_participants WHERE id = (SELECT id FROM event_participants LIMIT 1);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'R9: agent DELETE on event_participants should affect 0 rows, got %', v_rows;
    END IF;
END;
$$;

-- ============================================================
-- R10: access_grant revocation (active=false)
-- ============================================================
-- Create the grant as admin (RLS requires admin/manager to insert grants)
SET LOCAL "app.current_user_id" = 'user:admin-setup';
SET LOCAL "app.current_teams"   = '';
SET LOCAL "app.current_role"    = 'admin';

DO $$
DECLARE
    v_grant_id uuid;
BEGIN
    INSERT INTO access_grants (grantee, grant_type, resource_type, access_level, scope, active)
    VALUES ('user:revocation-test', 'user', 'node', 'read', '{"classification":"restricted"}', true)
    RETURNING id INTO v_grant_id;

    -- Store grant id for the next block via a temp table
    CREATE TEMP TABLE IF NOT EXISTS _r10_state (grant_id uuid);
    DELETE FROM _r10_state;
    INSERT INTO _r10_state VALUES (v_grant_id);
END;
$$;

-- Now switch to the test user to verify visibility
SET LOCAL "app.current_user_id" = 'user:revocation-test';
SET LOCAL "app.current_teams"   = '';
SET LOCAL "app.current_role"    = 'team_member';

DO $$
DECLARE
    v_grant_id uuid;
    v_visible_before int;
    v_visible_after int;
BEGIN
    SELECT grant_id INTO v_grant_id FROM _r10_state;

    -- User should now see restricted M&A nodes
    SELECT count(*) INTO v_visible_before
    FROM nodes WHERE attrs->>'classification' = 'restricted';

    IF v_visible_before < 1 THEN
        RAISE EXCEPTION 'R10: user with active grant should see restricted nodes, got %', v_visible_before;
    END IF;

    -- Revoke the grant (switch to admin briefly)
    PERFORM set_config('app.current_role', 'admin', true);
    UPDATE access_grants SET active = false WHERE id = v_grant_id;
    PERFORM set_config('app.current_role', 'team_member', true);

    -- User should no longer see restricted nodes
    SELECT count(*) INTO v_visible_after
    FROM nodes WHERE attrs->>'classification' = 'restricted';

    IF v_visible_after <> 0 THEN
        RAISE EXCEPTION 'R10: user with revoked grant should see 0 restricted nodes, got %', v_visible_after;
    END IF;

    DROP TABLE IF EXISTS _r10_state;
END;
$$;

ROLLBACK;
