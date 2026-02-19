-- Scenario 2: Cross-Functional Product Launch
-- Tests PM profile access: engineering vs marketing vs admin visibility,
-- cross-team blocker edges, and aggregate story point / status queries.

BEGIN;

-- ============================================================
-- TEST 2a: team_member (engineering) sees only engineering tasks
-- ============================================================
SET LOCAL "app.current_user_id" = 'user:eng-alice';
SET LOCAL "app.current_teams"   = 'engineering';
SET LOCAL "app.current_role"    = 'team_member';

DO $$
DECLARE
    v_task_count int;
    v_in_progress_points numeric;
    v_blocker_count int;
    v_event_count int;
BEGIN
    -- Engineering has tasks 1-12 (12 tasks)
    SELECT count(*) INTO v_task_count
    FROM nodes WHERE node_type = 'task';

    IF v_task_count <> 12 THEN
        RAISE EXCEPTION 'S2-2a: engineering team_member should see 12 tasks, got %', v_task_count;
    END IF;

    -- Sum story points for in_progress tasks visible to engineering
    -- Tasks 15-22 are in_progress, but only 15-18 have teams containing 'engineering' (none)
    -- Actually tasks 15-18 are design(15-16) + design(17-18). Let me re-check.
    -- Task teams: 1-12=engineering, 13-18=design, 19-24=marketing, 25-30=qa
    -- in_progress: tasks 15-22 -> design(15-18), marketing(19-22)
    -- Engineering member sees none of the in_progress tasks!
    -- Engineering statuses: 1-8=done, 9-12=in_review
    SELECT coalesce(sum((ca.claim->>'points')::numeric), 0) INTO v_in_progress_points
    FROM current_assertions ca
    JOIN nodes n ON n.id = ca.subject_node_id
    JOIN current_assertions st ON st.subject_node_id = n.id AND st.assertion_type = 'task_status'
    WHERE n.node_type = 'task'
      AND ca.assertion_type = 'estimate'
      AND st.claim->>'status' = 'in_progress';

    -- Engineering sees 0 in_progress points (their tasks are done/in_review)
    IF v_in_progress_points <> 0 THEN
        RAISE EXCEPTION 'S2-2a: engineering should see 0 in_progress story points, got %', v_in_progress_points;
    END IF;

    -- Cross-team blockers: eng can only see blocker edges where both nodes are visible
    -- blocks: task1(eng)->task17(design), task15(design)->task19(mktg), task13(design)->task25(qa)
    -- Engineering sees task1 but not task17, so the eng->design blocker edge is NOT visible
    SELECT count(*) INTO v_blocker_count
    FROM edges WHERE edge_type = 'blocks';

    IF v_blocker_count <> 0 THEN
        RAISE EXCEPTION 'S2-2a: engineering should see 0 cross-team blocker edges, got %', v_blocker_count;
    END IF;

    -- Events: engineering should see events linked to engineering tasks only
    SELECT count(*) INTO v_event_count
    FROM events;

    -- Events are visible if at least one participant is visible
    -- Engineering sees tasks 1-12, so events linked to those are visible
    IF v_event_count < 1 THEN
        RAISE EXCEPTION 'S2-2a: engineering should see some events, got %', v_event_count;
    END IF;
END;
$$;

-- ============================================================
-- TEST 2b: team_member (marketing) sees different tasks/aggregates
-- ============================================================
SET LOCAL "app.current_user_id" = 'user:mktg-dave';
SET LOCAL "app.current_teams"   = 'marketing';
SET LOCAL "app.current_role"    = 'team_member';

DO $$
DECLARE
    v_task_count int;
    v_in_progress_points numeric;
BEGIN
    -- Marketing has tasks 19-24 (6 tasks)
    SELECT count(*) INTO v_task_count
    FROM nodes WHERE node_type = 'task';

    IF v_task_count <> 6 THEN
        RAISE EXCEPTION 'S2-2b: marketing team_member should see 6 tasks, got %', v_task_count;
    END IF;

    -- Marketing in_progress tasks: 19-22 (4 tasks)
    -- Points: 1+(19%8)=4, 1+(20%8)=5, 1+(21%8)=6, 1+(22%8)=7 = 22
    SELECT coalesce(sum((ca.claim->>'points')::numeric), 0) INTO v_in_progress_points
    FROM current_assertions ca
    JOIN nodes n ON n.id = ca.subject_node_id
    JOIN current_assertions st ON st.subject_node_id = n.id AND st.assertion_type = 'task_status'
    WHERE n.node_type = 'task'
      AND ca.assertion_type = 'estimate'
      AND st.claim->>'status' = 'in_progress';

    IF v_in_progress_points <> 22 THEN
        RAISE EXCEPTION 'S2-2b: marketing in_progress points should be 22, got %', v_in_progress_points;
    END IF;
END;
$$;

-- ============================================================
-- TEST 2c: admin sees all 30 tasks and all blockers
-- ============================================================
SET LOCAL "app.current_user_id" = 'user:admin-1';
SET LOCAL "app.current_teams"   = '';
SET LOCAL "app.current_role"    = 'admin';

DO $$
DECLARE
    v_task_count int;
    v_blocker_count int;
    v_total_points numeric;
    v_done_count int;
BEGIN
    SELECT count(*) INTO v_task_count
    FROM nodes WHERE node_type = 'task';

    IF v_task_count <> 30 THEN
        RAISE EXCEPTION 'S2-2c: admin should see 30 tasks, got %', v_task_count;
    END IF;

    -- Admin sees all 3 cross-team blockers
    SELECT count(*) INTO v_blocker_count
    FROM edges WHERE edge_type = 'blocks';

    IF v_blocker_count <> 3 THEN
        RAISE EXCEPTION 'S2-2c: admin should see 3 blocker edges, got %', v_blocker_count;
    END IF;

    -- Total story points across all tasks
    SELECT coalesce(sum((ca.claim->>'points')::numeric), 0) INTO v_total_points
    FROM current_assertions ca
    JOIN nodes n ON n.id = ca.subject_node_id
    WHERE n.node_type = 'task'
      AND ca.assertion_type = 'estimate';

    IF v_total_points <> 135 THEN
        RAISE EXCEPTION 'S2-2c: admin total points should be 135, got %', v_total_points;
    END IF;

    -- Done tasks: first 8
    SELECT count(*) INTO v_done_count
    FROM current_assertions ca
    JOIN nodes n ON n.id = ca.subject_node_id
    WHERE n.node_type = 'task'
      AND ca.assertion_type = 'task_status'
      AND ca.claim->>'status' = 'done';

    IF v_done_count <> 8 THEN
        RAISE EXCEPTION 'S2-2c: admin should see 8 done tasks, got %', v_done_count;
    END IF;
END;
$$;

-- ============================================================
-- TEST 2d: agent:pm-bot can insert nodes and assertions, NOT update/delete
-- ============================================================
SET LOCAL "app.current_user_id" = 'agent:pm-bot';
SET LOCAL "app.current_teams"   = '';
SET LOCAL "app.current_role"    = 'agent:pm-bot';

DO $$
DECLARE
    v_agent_node uuid;
    v_updated int;
    v_count int;
BEGIN
    -- Agent CAN insert nodes (agent-native design)
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('task', 'Agent Task', '{}')
    RETURNING id INTO v_agent_node;

    IF v_agent_node IS NULL THEN
        RAISE EXCEPTION 'S2-2d: agent:pm-bot should be able to INSERT nodes';
    END IF;

    -- Agent should NOT be able to UPDATE nodes
    UPDATE nodes SET label = 'Modified' WHERE id = v_agent_node;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated > 0 THEN
        RAISE EXCEPTION 'S2-2d: agent:pm-bot should NOT be able to UPDATE nodes';
    END IF;

    -- Agent can insert assertions (on visible nodes)
    INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
    VALUES ('progress', 'agent-check', 'b0000001-0003-0001-0001-000000000001',
            '{"percent":"75"}', 0.7);

    SELECT count(*) INTO v_count
    FROM assertions
    WHERE assertion_type = 'progress' AND assertion_key = 'agent-check';

    IF v_count <> 1 THEN
        RAISE EXCEPTION 'S2-2d: agent should be able to INSERT assertions';
    END IF;
END;
$$;

ROLLBACK;
