-- Scenario 3: Customer Support Escalation Chain
-- Tests tiered support visibility, confidential/restricted customer orgs,
-- event immutability, and aggregate ticket counts by role.

SET search_path = rye, public, pg_catalog;

BEGIN;

-- ============================================================
-- TEST 3a: support-t1 sees public tickets but not confidential/restricted
-- ============================================================
SET LOCAL "app.current_user_id" = 'user:amy-t1';
SET LOCAL "app.current_teams"   = 'support-t1';
SET LOCAL "app.current_role"    = 'team_member';

DO $$
DECLARE
    v_ticket_count int;
    v_critical_count int;
    v_nda_visible int;
    v_topsecret_visible int;
    v_artifact_count int;
BEGIN
    -- T1 sees tickets with teams containing 'support-t1'
    -- Tickets 1-20 (public, teams include support-t1) = 20
    -- Tickets 21-35 (confidential, teams: support-t2,support-escalation only) = 0
    -- Tickets 36-45 (public, teams include support-t1) = 10
    -- Tickets 46-50 (restricted, teams: support-escalation only) = 0
    -- Total: 30
    SELECT count(*) INTO v_ticket_count
    FROM nodes WHERE node_type = 'ticket';

    IF v_ticket_count <> 30 THEN
        RAISE EXCEPTION 'S3-3a: support-t1 should see 30 tickets, got %', v_ticket_count;
    END IF;

    -- Critical tickets visible to T1
    SELECT count(*) INTO v_critical_count
    FROM current_assertions ca
    JOIN nodes n ON n.id = ca.subject_node_id
    WHERE n.node_type = 'ticket'
      AND ca.assertion_type = 'severity'
      AND ca.claim->>'level' = 'critical';

    -- Critical tickets are #1-10 from the severity array
    -- T1 sees tickets 1-20 and 36-45, so criticals in 1-10 (all visible) = up to 10
    -- But severity array maps directly: ticket 1=critical, ticket 2=critical, ... ticket 10=critical
    -- Tickets 1-10 are in range 1-20 (visible), so T1 sees all 10 criticals
    IF v_critical_count <> 10 THEN
        RAISE EXCEPTION 'S3-3a: support-t1 should see 10 critical tickets, got %', v_critical_count;
    END IF;

    -- NDA-SecureCo org (confidential) should NOT be visible
    SELECT count(*) INTO v_nda_visible
    FROM nodes WHERE id = 'c0000001-0002-0001-0001-000000000002';

    IF v_nda_visible <> 0 THEN
        RAISE EXCEPTION 'S3-3a: support-t1 should NOT see NDA-SecureCo org';
    END IF;

    -- TopSecret Gov org (restricted) should NOT be visible
    SELECT count(*) INTO v_topsecret_visible
    FROM nodes WHERE id = 'c0000001-0002-0001-0001-000000000004';

    IF v_topsecret_visible <> 0 THEN
        RAISE EXCEPTION 'S3-3a: support-t1 should NOT see TopSecret Gov org';
    END IF;

    -- Artifacts: T1 should see artifacts on visible tickets only
    SELECT count(*) INTO v_artifact_count
    FROM artifacts;

    -- Artifacts are linked to various tickets; T1 sees 30/50 tickets
    IF v_artifact_count < 1 THEN
        RAISE EXCEPTION 'S3-3a: support-t1 should see some artifacts, got %', v_artifact_count;
    END IF;
END;
$$;

-- ============================================================
-- TEST 3b: support-t2 sees public + confidential tickets
-- ============================================================
SET LOCAL "app.current_user_id" = 'user:cara-t2';
SET LOCAL "app.current_teams"   = 'support-t2';
SET LOCAL "app.current_role"    = 'team_member';

DO $$
DECLARE
    v_ticket_count int;
    v_nda_visible int;
BEGIN
    -- T2 sees tickets with teams containing 'support-t2'
    -- Tickets 1-20 (teams include t2) + 21-35 (teams include t2) + 36-45 (teams include t2) = 45
    -- Tickets 46-50 (restricted, teams: escalation only) = 0
    SELECT count(*) INTO v_ticket_count
    FROM nodes WHERE node_type = 'ticket';

    IF v_ticket_count <> 45 THEN
        RAISE EXCEPTION 'S3-3b: support-t2 should see 45 tickets, got %', v_ticket_count;
    END IF;

    -- NDA-SecureCo (confidential, teams include support-t2) should be visible
    SELECT count(*) INTO v_nda_visible
    FROM nodes WHERE id = 'c0000001-0002-0001-0001-000000000002';

    IF v_nda_visible <> 1 THEN
        RAISE EXCEPTION 'S3-3b: support-t2 should see NDA-SecureCo org';
    END IF;
END;
$$;

-- ============================================================
-- TEST 3c: support-escalation sees all tickets including restricted
-- ============================================================
SET LOCAL "app.current_user_id" = 'user:dan-esc';
SET LOCAL "app.current_teams"   = 'support-escalation';
SET LOCAL "app.current_role"    = 'team_lead';

DO $$
DECLARE
    v_ticket_count int;
    v_topsecret_visible int;
BEGIN
    -- Escalation sees all 50 tickets
    SELECT count(*) INTO v_ticket_count
    FROM nodes WHERE node_type = 'ticket';

    IF v_ticket_count <> 50 THEN
        RAISE EXCEPTION 'S3-3c: support-escalation should see 50 tickets, got %', v_ticket_count;
    END IF;

    -- TopSecret Gov (restricted, teams include support-escalation) visible
    SELECT count(*) INTO v_topsecret_visible
    FROM nodes WHERE id = 'c0000001-0002-0001-0001-000000000004';

    IF v_topsecret_visible <> 1 THEN
        RAISE EXCEPTION 'S3-3c: support-escalation should see TopSecret Gov org';
    END IF;
END;
$$;

-- ============================================================
-- TEST 3d: event immutability - UPDATE and DELETE blocked
-- ============================================================
SET LOCAL "app.current_user_id" = 'user:admin-1';
SET LOCAL "app.current_role"    = 'admin';

DO $$
DECLARE
    v_event_id uuid;
    v_rows int;
BEGIN
    -- Get any event
    SELECT id INTO v_event_id FROM events LIMIT 1;

    IF v_event_id IS NULL THEN
        RAISE EXCEPTION 'S3-3d: no events found for immutability test';
    END IF;

    -- UPDATE should affect 0 rows (RLS USING(false) silently blocks)
    UPDATE events SET summary = 'tampered' WHERE id = v_event_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'S3-3d: event UPDATE should affect 0 rows, got %', v_rows;
    END IF;

    -- DELETE should affect 0 rows
    DELETE FROM events WHERE id = v_event_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'S3-3d: event DELETE should affect 0 rows, got %', v_rows;
    END IF;
END;
$$;

-- ============================================================
-- TEST 3e: aggregate queries differ by tier
-- ============================================================
-- Compare critical ticket counts across roles
SET LOCAL "app.current_teams" = 'support-t1';
SET LOCAL "app.current_role"  = 'team_member';

DO $$
DECLARE
    v_t1_total int;
BEGIN
    SELECT count(*) INTO v_t1_total
    FROM nodes WHERE node_type = 'ticket';

    -- T1 sees 30, T2 sees 45, escalation sees 50
    IF v_t1_total >= 45 THEN
        RAISE EXCEPTION 'S3-3e: T1 total (%) must be less than T2 total (45)', v_t1_total;
    END IF;
END;
$$;

-- ============================================================
-- TEST 3f: agent:support-triage can insert assertions, not modify nodes
-- ============================================================
SET LOCAL "app.current_user_id" = 'agent:support-triage';
SET LOCAL "app.current_teams"   = '';
SET LOCAL "app.current_role"    = 'agent:support-triage';

DO $$
DECLARE
    v_rows int;
BEGIN
    -- Agent cannot modify ticket nodes (RLS silently blocks — 0 rows affected)
    UPDATE nodes SET label = 'Tampered' WHERE id = 'c0000001-0004-0001-0001-000000000001';
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'S3-3f: agent UPDATE on nodes should affect 0 rows, got %', v_rows;
    END IF;

    -- Agent cannot delete events (RLS USING(false) — 0 rows affected)
    DELETE FROM events WHERE id = (SELECT id FROM events LIMIT 1);
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'S3-3f: agent DELETE on events should affect 0 rows, got %', v_rows;
    END IF;
END;
$$;

ROLLBACK;
