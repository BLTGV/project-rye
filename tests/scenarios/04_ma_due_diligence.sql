-- Scenario 4: M&A Due Diligence (Maximum Security Sensitivity)
-- Tests restricted classification, explicit access_grants, compensation gating,
-- and the principle that unauthorized users see zero M&A data.

BEGIN;

-- ============================================================
-- TEST 4a: regular team_member sees ZERO M&A nodes
-- ============================================================
SET LOCAL "app.current_user_id" = 'user:regular-joe';
SET LOCAL "app.current_teams"   = 'engineering';
SET LOCAL "app.current_role"    = 'team_member';

DO $$
DECLARE
    v_target_count int;
    v_exec_count int;
    v_valuation_count int;
    v_event_count int;
BEGIN
    -- Restricted orgs invisible
    SELECT count(*) INTO v_target_count
    FROM nodes
    WHERE id IN (
        'd0000001-0001-0001-0001-000000000001',
        'd0000001-0001-0001-0001-000000000002',
        'd0000001-0001-0001-0001-000000000003'
    );

    IF v_target_count <> 0 THEN
        RAISE EXCEPTION 'S4-4a: regular user should see 0 M&A target orgs, got %', v_target_count;
    END IF;

    -- Restricted people invisible
    SELECT count(*) INTO v_exec_count
    FROM nodes
    WHERE id IN (
        'd0000001-0002-0001-0001-000000000001',
        'd0000001-0002-0001-0001-000000000002',
        'd0000001-0002-0001-0001-000000000003',
        'd0000001-0002-0001-0001-000000000004',
        'd0000001-0002-0001-0001-000000000005',
        'd0000001-0002-0001-0001-000000000006',
        'd0000001-0002-0001-0001-000000000007'
    );

    IF v_exec_count <> 0 THEN
        RAISE EXCEPTION 'S4-4a: regular user should see 0 M&A people, got %', v_exec_count;
    END IF;

    -- Valuations on those nodes: invisible because subject node is invisible
    SELECT count(*) INTO v_valuation_count
    FROM current_assertions WHERE assertion_type = 'valuation';

    IF v_valuation_count <> 0 THEN
        RAISE EXCEPTION 'S4-4a: regular user should see 0 valuations, got %', v_valuation_count;
    END IF;

    -- M&A events: invisible because participants are on restricted nodes
    SELECT count(*) INTO v_event_count
    FROM events e
    WHERE EXISTS (
        SELECT 1 FROM event_participants ep
        WHERE ep.event_id = e.id
          AND ep.node_id IN (
              'd0000001-0001-0001-0001-000000000001',
              'd0000001-0001-0001-0001-000000000002',
              'd0000001-0001-0001-0001-000000000003'
          )
    );

    IF v_event_count <> 0 THEN
        RAISE EXCEPTION 'S4-4a: regular user should see 0 M&A events, got %', v_event_count;
    END IF;
END;
$$;

-- ============================================================
-- TEST 4b: deal_manager with explicit grant sees targets + financial_terms
-- ============================================================
SET LOCAL "app.current_user_id" = 'user:ma-lead';
SET LOCAL "app.current_teams"   = 'ma-team';
SET LOCAL "app.current_role"    = 'deal_manager';

DO $$
DECLARE
    v_target_count int;
    v_val_sum numeric;
    v_ft_count int;
    v_ns_count int;
    v_comp_count int;
BEGIN
    -- deal_manager on ma-team with explicit grant sees restricted orgs
    SELECT count(*) INTO v_target_count
    FROM nodes
    WHERE id IN (
        'd0000001-0001-0001-0001-000000000001',
        'd0000001-0001-0001-0001-000000000002',
        'd0000001-0001-0001-0001-000000000003'
    );

    IF v_target_count <> 3 THEN
        RAISE EXCEPTION 'S4-4b: deal_manager should see 3 target orgs, got %', v_target_count;
    END IF;

    -- Sum of valuations: 120M + 250M + 85M = 455M
    SELECT coalesce(sum((ca.claim->>'amount')::numeric), 0) INTO v_val_sum
    FROM current_assertions ca
    WHERE ca.assertion_type = 'valuation'
      AND ca.subject_node_id IN (
          'd0000001-0001-0001-0001-000000000001',
          'd0000001-0001-0001-0001-000000000002',
          'd0000001-0001-0001-0001-000000000003'
      );

    IF v_val_sum <> 455000000 THEN
        RAISE EXCEPTION 'S4-4b: deal_manager valuation sum should be 455000000, got %', v_val_sum;
    END IF;

    -- deal_manager sees financial_terms (assertion gated for deal_manager)
    SELECT count(*) INTO v_ft_count
    FROM current_assertions
    WHERE assertion_type = 'financial_terms'
      AND subject_node_id IN (
          'd0000001-0001-0001-0001-000000000001',
          'd0000001-0001-0001-0001-000000000002'
      );

    IF v_ft_count <> 2 THEN
        RAISE EXCEPTION 'S4-4b: deal_manager should see 2 M&A financial_terms, got %', v_ft_count;
    END IF;

    -- deal_manager sees negotiation_stance
    SELECT count(*) INTO v_ns_count
    FROM current_assertions
    WHERE assertion_type = 'negotiation_stance'
      AND subject_node_id IN (
          'd0000001-0001-0001-0001-000000000001',
          'd0000001-0001-0001-0001-000000000002'
      );

    IF v_ns_count <> 2 THEN
        RAISE EXCEPTION 'S4-4b: deal_manager should see 2 M&A negotiation_stance, got %', v_ns_count;
    END IF;

    -- deal_manager does NOT see compensation (requires hr_admin or admin)
    SELECT count(*) INTO v_comp_count
    FROM current_assertions WHERE assertion_type = 'compensation';

    IF v_comp_count <> 0 THEN
        RAISE EXCEPTION 'S4-4b: deal_manager should NOT see compensation, got %', v_comp_count;
    END IF;
END;
$$;

-- ============================================================
-- TEST 4c: hr_admin with explicit grant sees compensation, NOT negotiation_stance
-- ============================================================
SET LOCAL "app.current_user_id" = 'user:hr-1';
SET LOCAL "app.current_teams"   = 'ma-team';
SET LOCAL "app.current_role"    = 'hr_admin';

DO $$
DECLARE
    v_comp_count int;
    v_ns_count int;
BEGIN
    -- hr_admin sees compensation
    SELECT count(*) INTO v_comp_count
    FROM current_assertions WHERE assertion_type = 'compensation';

    IF v_comp_count <> 3 THEN
        RAISE EXCEPTION 'S4-4c: hr_admin should see exactly 3 compensation assertions, got %', v_comp_count;
    END IF;

    -- hr_admin does NOT see negotiation_stance (requires deal_manager or admin)
    SELECT count(*) INTO v_ns_count
    FROM current_assertions WHERE assertion_type = 'negotiation_stance';

    IF v_ns_count <> 0 THEN
        RAISE EXCEPTION 'S4-4c: hr_admin should NOT see negotiation_stance, got %', v_ns_count;
    END IF;
END;
$$;

-- ============================================================
-- TEST 4d: admin sees everything
-- ============================================================
SET LOCAL "app.current_user_id" = 'user:admin-1';
SET LOCAL "app.current_teams"   = '';
SET LOCAL "app.current_role"    = 'admin';

DO $$
DECLARE
    v_target_count int;
    v_comp_count int;
    v_ns_count int;
    v_ft_count int;
    v_val_count int;
    v_ssn text;
BEGIN
    SELECT count(*) INTO v_target_count
    FROM nodes
    WHERE id IN (
        'd0000001-0001-0001-0001-000000000001',
        'd0000001-0001-0001-0001-000000000002',
        'd0000001-0001-0001-0001-000000000003'
    );

    IF v_target_count <> 3 THEN
        RAISE EXCEPTION 'S4-4d: admin should see 3 targets, got %', v_target_count;
    END IF;

    SELECT count(*) INTO v_comp_count FROM current_assertions WHERE assertion_type = 'compensation';
    SELECT count(*) INTO v_ns_count FROM current_assertions WHERE assertion_type = 'negotiation_stance';
    SELECT count(*) INTO v_ft_count FROM current_assertions WHERE assertion_type = 'financial_terms';
    SELECT count(*) INTO v_val_count FROM current_assertions WHERE assertion_type = 'valuation';

    IF v_comp_count < 3 THEN
        RAISE EXCEPTION 'S4-4d: admin should see all compensation, got %', v_comp_count;
    END IF;

    -- Admin sees restricted fields via nodes_secure
    SELECT properties->>'ssn' INTO v_ssn
    FROM nodes_secure
    WHERE id = 'd0000001-0002-0001-0001-000000000001';

    IF v_ssn IS NULL THEN
        RAISE EXCEPTION 'S4-4d: admin should see restricted field ssn via nodes_secure';
    END IF;
END;
$$;

-- ============================================================
-- TEST 4e: COUNT(*) on nodes differs for different roles
-- ============================================================
DO $$
DECLARE
    v_admin_org_count int;
    v_regular_org_count int;
BEGIN
    -- Admin org count (includes restricted M&A targets)
    SET LOCAL "app.current_role" = 'admin';
    SELECT count(*) INTO v_admin_org_count
    FROM nodes WHERE node_type = 'org';

    -- Regular user org count
    SET LOCAL "app.current_user_id" = 'user:regular-joe';
    SET LOCAL "app.current_teams" = 'engineering';
    SET LOCAL "app.current_role" = 'team_member';
    SELECT count(*) INTO v_regular_org_count
    FROM nodes WHERE node_type = 'org';

    -- Admin should see MORE orgs than regular user (3 M&A targets are restricted)
    IF v_admin_org_count <= v_regular_org_count THEN
        RAISE EXCEPTION 'S4-4e: admin org count (%) should exceed regular user count (%)',
            v_admin_org_count, v_regular_org_count;
    END IF;
END;
$$;

ROLLBACK;
