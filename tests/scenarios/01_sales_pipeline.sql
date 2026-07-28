-- Scenario 1: Sales Pipeline with Competitive Intelligence
-- Tests multi-role access to deals, financial terms, negotiation stance,
-- and aggregate queries that return different results per role.

SET search_path = rye, public, pg_catalog;

BEGIN;

-- ============================================================
-- TEST 1a: team_member (sales-east) sees only their team's deals
-- ============================================================
SET LOCAL "app.current_user_id" = 'user:alice';
SET LOCAL "app.current_teams"   = 'sales-east';
SET LOCAL "app.current_role"    = 'team_member';

DO $$
DECLARE
    v_count int;
    v_total numeric;
    v_neg_count int;
    v_neg_total numeric;
BEGIN
    -- Should see 4 enterprise opps (sales-east) + pipelines/public nodes, NOT west/smb opps
    SELECT count(*) INTO v_count
    FROM nodes
    WHERE node_type = 'opportunity';

    IF v_count <> 4 THEN
        RAISE EXCEPTION 'S1-1a: team_member(sales-east) should see 4 opportunities, got %', v_count;
    END IF;

    -- Sum of deal values visible: 500K + 1.2M + 300K + 800K = 2.8M
    SELECT coalesce(sum((ca.claim->>'amount')::numeric), 0) INTO v_total
    FROM current_assertions ca
    JOIN nodes n ON n.id = ca.subject_node_id
    WHERE n.node_type = 'opportunity'
      AND ca.assertion_type = 'deal_value';

    IF v_total <> 2800000 THEN
        RAISE EXCEPTION 'S1-1a: team_member(sales-east) deal_value sum should be 2800000, got %', v_total;
    END IF;

    -- Negotiation stage count: opp1 + opp4 = 2
    SELECT count(*) INTO v_neg_count
    FROM current_assertions ca
    JOIN nodes n ON n.id = ca.subject_node_id
    WHERE n.node_type = 'opportunity'
      AND ca.assertion_type = 'deal_stage'
      AND ca.claim->>'stage' = 'negotiation';

    IF v_neg_count <> 2 THEN
        RAISE EXCEPTION 'S1-1a: team_member(sales-east) should see 2 negotiation deals, got %', v_neg_count;
    END IF;

    -- financial_terms: team_member cannot see them (assertion-type gated)
    SELECT count(*) INTO v_count
    FROM current_assertions ca
    WHERE ca.assertion_type = 'financial_terms';

    IF v_count <> 0 THEN
        RAISE EXCEPTION 'S1-1a: team_member should NOT see financial_terms, got % rows', v_count;
    END IF;

    -- negotiation_stance: team_member cannot see them
    SELECT count(*) INTO v_count
    FROM current_assertions ca
    WHERE ca.assertion_type = 'negotiation_stance';

    IF v_count <> 0 THEN
        RAISE EXCEPTION 'S1-1a: team_member should NOT see negotiation_stance, got % rows', v_count;
    END IF;
END;
$$;

-- ============================================================
-- TEST 1b: team_lead (sales-east) same node access, sees confidential fields
-- ============================================================
SET LOCAL "app.current_role" = 'team_lead';

DO $$
DECLARE
    v_count int;
    v_margin text;
BEGIN
    -- Same 4 opps visible
    SELECT count(*) INTO v_count
    FROM nodes WHERE node_type = 'opportunity';

    IF v_count <> 4 THEN
        RAISE EXCEPTION 'S1-1b: team_lead(sales-east) should see 4 opportunities, got %', v_count;
    END IF;

    -- Still cannot see financial_terms (requires deal_manager/finance/admin)
    SELECT count(*) INTO v_count
    FROM current_assertions WHERE assertion_type = 'financial_terms';

    IF v_count <> 0 THEN
        RAISE EXCEPTION 'S1-1b: team_lead should NOT see financial_terms, got % rows', v_count;
    END IF;

    -- Can see confidential fields via nodes_secure (margin is confidential, team_lead sees it)
    SELECT properties->>'margin' INTO v_margin
    FROM nodes_secure
    WHERE id = 'a0000001-0005-0001-0001-000000000001';

    IF v_margin IS NULL THEN
        RAISE EXCEPTION 'S1-1b: team_lead should see confidential field margin via nodes_secure';
    END IF;
END;
$$;

-- ============================================================
-- TEST 1c: deal_manager sees ALL deals + financial_terms + negotiation_stance
-- ============================================================
SET LOCAL "app.current_teams" = 'sales-east,sales-west,sales-smb';
SET LOCAL "app.current_role"  = 'deal_manager';

DO $$
DECLARE
    v_count int;
    v_total numeric;
    v_ft_count int;
    v_ns_count int;
BEGIN
    -- Should see all 12 opportunities
    SELECT count(*) INTO v_count
    FROM nodes WHERE node_type = 'opportunity';

    IF v_count <> 12 THEN
        RAISE EXCEPTION 'S1-1c: deal_manager should see 12 opportunities, got %', v_count;
    END IF;

    -- Total deal value: 500K+1.2M+300K+800K + 150K+2M+200K+450K + 25K+35K+15K+40K = 5,715,000
    SELECT coalesce(sum((ca.claim->>'amount')::numeric), 0) INTO v_total
    FROM current_assertions ca
    JOIN nodes n ON n.id = ca.subject_node_id
    WHERE n.node_type = 'opportunity'
      AND ca.assertion_type = 'deal_value';

    IF v_total <> 5715000 THEN
        RAISE EXCEPTION 'S1-1c: deal_manager total deal_value should be 5715000, got %', v_total;
    END IF;

    -- financial_terms: deal_manager sees S1 (4) + S4 M&A (2) = 6
    SELECT count(*) INTO v_ft_count
    FROM current_assertions WHERE assertion_type = 'financial_terms';

    IF v_ft_count <> 6 THEN
        RAISE EXCEPTION 'S1-1c: deal_manager should see 6 financial_terms (4 S1 + 2 S4), got %', v_ft_count;
    END IF;

    -- negotiation_stance: deal_manager sees S1 (2) + S4 M&A (2) = 4
    SELECT count(*) INTO v_ns_count
    FROM current_assertions WHERE assertion_type = 'negotiation_stance';

    IF v_ns_count <> 4 THEN
        RAISE EXCEPTION 'S1-1c: deal_manager should see 4 negotiation_stance (2 S1 + 2 S4), got %', v_ns_count;
    END IF;
END;
$$;

-- ============================================================
-- TEST 1d: finance with sales teams sees financial_terms but NOT negotiation_stance
-- ============================================================
SET LOCAL "app.current_teams" = 'finance,sales-east,sales-west,sales-smb';
SET LOCAL "app.current_role"  = 'finance';

DO $$
DECLARE
    v_ft_count int;
    v_ns_count int;
    v_opp_count int;
BEGIN
    -- Finance with sales teams can see opportunities
    SELECT count(*) INTO v_opp_count
    FROM nodes WHERE node_type = 'opportunity';

    IF v_opp_count <> 12 THEN
        RAISE EXCEPTION 'S1-1d: finance (with sales teams) should see 12 opportunities, got %', v_opp_count;
    END IF;

    -- finance role can see financial_terms (assertion policy allows it)
    SELECT count(*) INTO v_ft_count
    FROM current_assertions ca
    JOIN nodes n ON n.id = ca.subject_node_id
    WHERE ca.assertion_type = 'financial_terms'
      AND n.node_type = 'opportunity';

    IF v_ft_count <> 4 THEN
        RAISE EXCEPTION 'S1-1d: finance should see 4 financial_terms on opportunities, got %', v_ft_count;
    END IF;

    -- negotiation_stance: finance cannot see (requires deal_manager or admin)
    SELECT count(*) INTO v_ns_count
    FROM current_assertions WHERE assertion_type = 'negotiation_stance';

    IF v_ns_count <> 0 THEN
        RAISE EXCEPTION 'S1-1d: finance should NOT see negotiation_stance, got %', v_ns_count;
    END IF;
END;
$$;

-- ============================================================
-- TEST 1e: admin sees everything
-- ============================================================
SET LOCAL "app.current_teams" = '';
SET LOCAL "app.current_role"  = 'admin';

DO $$
DECLARE
    v_opp_count int;
    v_ft_count int;
    v_ns_count int;
    v_total numeric;
BEGIN
    SELECT count(*) INTO v_opp_count FROM nodes WHERE node_type = 'opportunity';
    SELECT count(*) INTO v_ft_count FROM current_assertions WHERE assertion_type = 'financial_terms';
    SELECT count(*) INTO v_ns_count FROM current_assertions WHERE assertion_type = 'negotiation_stance';

    SELECT coalesce(sum((ca.claim->>'amount')::numeric), 0) INTO v_total
    FROM current_assertions ca
    JOIN nodes n ON n.id = ca.subject_node_id
    WHERE n.node_type = 'opportunity' AND ca.assertion_type = 'deal_value';

    IF v_opp_count <> 12 THEN
        RAISE EXCEPTION 'S1-1e: admin should see 12 opportunities, got %', v_opp_count;
    END IF;
    IF v_ft_count <> 6 THEN
        RAISE EXCEPTION 'S1-1e: admin should see 6 financial_terms (4 S1 + 2 S4), got %', v_ft_count;
    END IF;
    IF v_ns_count <> 4 THEN
        RAISE EXCEPTION 'S1-1e: admin should see 4 negotiation_stance (2 S1 + 2 S4), got %', v_ns_count;
    END IF;
    IF v_total <> 5715000 THEN
        RAISE EXCEPTION 'S1-1e: admin total deal_value should be 5715000, got %', v_total;
    END IF;
END;
$$;

-- ============================================================
-- TEST 1f: agent:crm-sync cannot insert nodes, can insert assertions
-- ============================================================
SET LOCAL "app.current_user_id" = 'agent:crm-sync';
SET LOCAL "app.current_teams"   = '';
SET LOCAL "app.current_role"    = 'agent:crm-sync';

DO $$
DECLARE
    v_agent_node uuid;
    v_updated int;
BEGIN
    -- Agent CAN insert nodes (agent-native design)
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('opportunity', 'Agent Opp', '{}')
    RETURNING id INTO v_agent_node;

    IF v_agent_node IS NULL THEN
        RAISE EXCEPTION 'S1-1f: agent:crm-sync should be able to INSERT nodes';
    END IF;

    -- Agent should NOT be able to UPDATE nodes
    UPDATE nodes SET label = 'Modified' WHERE id = v_agent_node;
    GET DIAGNOSTICS v_updated = ROW_COUNT;

    IF v_updated > 0 THEN
        RAISE EXCEPTION 'S1-1f: agent:crm-sync should NOT be able to UPDATE nodes';
    END IF;

    -- Agent should NOT be able to DELETE nodes
    DELETE FROM nodes WHERE id = v_agent_node;
    GET DIAGNOSTICS v_updated = ROW_COUNT;

    IF v_updated > 0 THEN
        RAISE EXCEPTION 'S1-1f: agent:crm-sync should NOT be able to DELETE nodes';
    END IF;
END;
$$;

DO $$
DECLARE
    v_count int;
BEGIN
    -- Agent can insert ungated assertions on visible nodes
    -- Public/null-classified nodes are visible to everyone
    INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence, basis) VALUES ('sentiment', 'agent-note', 'a0000001-0003-0001-0001-000000000001',
            '{"sentiment":"agent-detected-positive"}', 0.6, 'assumed');

    SELECT count(*) INTO v_count
    FROM assertions
    WHERE assertion_type = 'sentiment' AND assertion_key = 'agent-note'
      AND subject_node_id = 'a0000001-0003-0001-0001-000000000001';

    IF v_count <> 1 THEN
        RAISE EXCEPTION 'S1-1f: agent should be able to INSERT ungated assertions';
    END IF;
END;
$$;

ROLLBACK;
