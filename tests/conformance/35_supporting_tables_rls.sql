-- The last two supporting tables with no row-level security.
--
-- Contract:  contracts/sql-surface.md, "Who may write"; AGENTS.md's promise
--            that RLS is enabled and forced on all core and supporting tables.
-- Work item: work/011-loose-ends.md, from the work/009 Verifier's finding.
-- Migration: schema/migrations/0029_supporting_tables_rls.sql.
--
-- The two reproductions, first, asserted by effect rather than by error text:
-- a `viewer` rewinding a code counter so the next create_task() collides on
-- idx_nodes_external_unique, and a `viewer` deleting a counter so the series
-- restarts; then a read-only session forging and erasing merge history.
--
-- Negative control: without 0029 this suite fails at the first case, because
-- the rewind succeeds.
--
-- Invented names only: Wren, Tobin.

SET search_path = rye, public, pg_catalog;

BEGIN;

-- --------------------------------------------------------------------------
-- Anti-vacuity, as in tests/conformance/34_gated_type_alias.sql.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_bypass boolean;
    v_node   uuid;
    v_probe  uuid;
    v_role   text;
    v_seen   integer;
    v_super  boolean;
BEGIN
    SELECT rolsuper, rolbypassrls INTO v_super, v_bypass
    FROM pg_roles WHERE rolname = current_user;
    IF coalesce(v_super, false) OR coalesce(v_bypass, false) THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: % is rolsuper=% rolbypassrls=% and is not bound by RLS. Run this suite as scripts/conformance.sh and scripts/test-nonsuperuser-owner.sh do.',
            current_user, v_super, v_bypass;
    END IF;
    IF current_setting('row_security', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'Refusing to pass vacuously: row_security is %',
            current_setting('row_security', true);
    END IF;

    FOREACH v_role IN ARRAY ARRAY['agent:t', 'viewer', 'team_member', '', 'admin'] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION
                'Refusing to pass vacuously: app.current_role did not read back as "%", it reads "%"',
                v_role, current_setting('app.current_role', true);
        END IF;
    END LOOP;

    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:supporting-rls', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Wren', '{"suite":"supporting_rls"}')
    RETURNING id INTO v_node;
    v_probe := record_assertion(
        'compensation', '{"value":"rls probe"}', v_node,
        p_assertion_key := 'supporting_rls:probe', p_basis := 'assumed'
    );

    PERFORM set_config('app.current_role', 'viewer', true);
    SELECT count(*) INTO v_seen FROM assertions WHERE id = v_probe;
    IF v_seen <> 0 THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: a viewer can read a read-gated assertion type, so RLS is not in force';
    END IF;
    PERFORM set_config('app.current_role', 'admin', true);
END
$$;

-- --------------------------------------------------------------------------
-- crm_code_counters: the counter moves only forward, and only for a role
-- that may write.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_after    int;
    v_before   int;
    v_code     text;
    v_failed   boolean;
    v_msg      text;
    v_opp      uuid;
    v_owner    uuid;
    v_pipeline uuid;
    v_role     text;
    v_rows     integer;
    v_seq      int;
    v_task     uuid;
    v_yymm     text := to_char(now(), 'YYMM');
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:supporting-rls', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Tobin', '{"suite":"supporting_rls"}')
    RETURNING id INTO v_owner;
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('pipeline', 'Supporting RLS pipeline',
            '{"suite":"supporting_rls","code":"SRP","default_stage":"prospecting"}')
    RETURNING id INTO v_pipeline;

    -- A counter has to exist for the attacks to have something to move.
    v_task := create_task(p_title := 'Supporting RLS task one', p_assigned_to_id := v_owner);
    SELECT next_val INTO v_before
    FROM crm_code_counters WHERE prefix = 'TSK' AND year_month = v_yymm;
    IF v_before IS NULL THEN
        RAISE EXCEPTION 'Premise broken: create_task() did not leave a TSK counter';
    END IF;

    -- ==================================================================
    -- Reproduction 1. The rewind, as a viewer and as an unset role.
    -- ==================================================================
    FOREACH v_role IN ARRAY ARRAY['viewer', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_failed := false;
        v_rows := -1;
        BEGIN
            UPDATE crm_code_counters SET next_val = next_val - 1
            WHERE prefix = 'TSK' AND year_month = v_yymm;
            GET DIAGNOSTICS v_rows = ROW_COUNT;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed AND v_rows <> 0 THEN
            RAISE EXCEPTION
                'Role "%" rewound the TSK counter (% rows); the next create_task() would collide',
                v_role, v_rows;
        END IF;

        -- And the delete, which restarts the series at 0001.
        v_failed := false;
        v_rows := -1;
        BEGIN
            DELETE FROM crm_code_counters WHERE prefix = 'TSK' AND year_month = v_yymm;
            GET DIAGNOSTICS v_rows = ROW_COUNT;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed AND v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" deleted % code counters', v_role, v_rows;
        END IF;
    END LOOP;

    PERFORM set_config('app.current_role', 'admin', true);
    SELECT next_val INTO v_after
    FROM crm_code_counters WHERE prefix = 'TSK' AND year_month = v_yymm;
    IF v_after IS DISTINCT FROM v_before THEN
        RAISE EXCEPTION 'The TSK counter moved from % to % under read-only sessions',
            v_before, v_after;
    END IF;

    -- ==================================================================
    -- The helpers still issue the next code, which is what the counter is
    -- for. A writing role, not only an admin.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'team_member', true);
    v_task := create_task(p_title := 'Supporting RLS task two', p_assigned_to_id := v_owner);
    IF (SELECT external_id FROM nodes WHERE id = v_task)
       IS DISTINCT FROM 'TSK-' || v_yymm || '-' || lpad(v_before::text, 4, '0')
    THEN
        RAISE EXCEPTION
            'create_task() issued % instead of the next TSK code after %',
            (SELECT external_id FROM nodes WHERE id = v_task), v_before;
    END IF;

    v_opp := create_opportunity(
        p_name := 'Supporting RLS opportunity', p_pipeline_code := 'SRP',
        p_assigned_to_id := v_owner, p_properties := '{"suite":"supporting_rls"}'
    );
    IF (SELECT external_id FROM nodes WHERE id = v_opp) NOT LIKE 'OPP-' || v_yymm || '-%' THEN
        RAISE EXCEPTION 'create_opportunity() issued %',
            (SELECT external_id FROM nodes WHERE id = v_opp);
    END IF;

    -- Codes stay unique across the attempts, which is the damage the
    -- reproduction caused.
    IF (SELECT count(DISTINCT external_id) FROM nodes
        WHERE external_source = 'internal' AND external_id LIKE 'TSK-%')
       <> (SELECT count(*) FROM nodes
           WHERE external_source = 'internal' AND external_id LIKE 'TSK-%')
    THEN
        RAISE EXCEPTION 'Two nodes carry the same TSK code';
    END IF;

    -- ==================================================================
    -- A writing role may not move a counter by hand either: not backwards,
    -- not forwards by more than the one code generate_crm_code() draws, and
    -- not by deleting it. team_member and agent:t, both of which may write.
    -- ==================================================================
    SELECT next_val INTO v_before
    FROM crm_code_counters WHERE prefix = 'TSK' AND year_month = v_yymm;

    FOREACH v_role IN ARRAY ARRAY['team_member', 'agent:t'] LOOP
        PERFORM set_config('app.current_role', v_role, true);

        v_failed := false;
        BEGIN
            UPDATE crm_code_counters SET next_val = next_val - 1
            WHERE prefix = 'TSK' AND year_month = v_yymm;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" rewound a counter by hand', v_role;
        END IF;
        IF v_msg NOT LIKE '%moves forward one code at a time%' THEN
            RAISE EXCEPTION 'Role "%" rewind failed for the wrong reason: %', v_role, v_msg;
        END IF;

        v_failed := false;
        BEGIN
            UPDATE crm_code_counters SET next_val = next_val + 500
            WHERE prefix = 'TSK' AND year_month = v_yymm;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" jumped a counter forward by hand', v_role;
        END IF;

        v_failed := false;
        BEGIN
            UPDATE crm_code_counters SET prefix = 'HIJ'
            WHERE prefix = 'TSK' AND year_month = v_yymm;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" renamed a counter', v_role;
        END IF;

        v_failed := false;
        v_rows := -1;
        BEGIN
            DELETE FROM crm_code_counters WHERE prefix = 'TSK' AND year_month = v_yymm;
            GET DIAGNOSTICS v_rows = ROW_COUNT;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed AND v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" deleted % counters', v_role, v_rows;
        END IF;
    END LOOP;

    -- Not even an admin deletes one: a restarted series re-issues codes that
    -- already name a node.
    PERFORM set_config('app.current_role', 'admin', true);
    v_failed := false;
    v_rows := -1;
    BEGIN
        DELETE FROM crm_code_counters WHERE prefix = 'TSK' AND year_month = v_yymm;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        v_msg := SQLERRM;
    END;
    IF NOT v_failed AND v_rows <> 0 THEN
        RAISE EXCEPTION 'An admin deleted % code counters', v_rows;
    END IF;

    SELECT next_val INTO v_after
    FROM crm_code_counters WHERE prefix = 'TSK' AND year_month = v_yymm;
    IF v_after IS DISTINCT FROM v_before THEN
        RAISE EXCEPTION 'The counter moved from % to % under the by-hand attempts',
            v_before, v_after;
    END IF;

    -- And a role that may not write cannot start a new series either.
    PERFORM set_config('app.current_role', 'viewer', true);
    v_failed := false;
    BEGIN
        INSERT INTO crm_code_counters (prefix, year_month, next_val)
        VALUES ('VWR', v_yymm, 500);
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        v_msg := SQLERRM;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'A viewer created a code counter';
    END IF;

    -- The counter is readable, because generate_crm_code() reads it back and
    -- because it says nothing about the world.
    PERFORM set_config('app.current_role', 'viewer', true);
    SELECT next_val INTO v_seq
    FROM crm_code_counters WHERE prefix = 'TSK' AND year_month = v_yymm;
    IF v_seq IS NULL THEN
        RAISE EXCEPTION 'A viewer cannot read the counter it is not allowed to move';
    END IF;

    -- Drawing a code is a write: a role that may not write is refused, and
    -- the refusal names what to do.
    FOREACH v_role IN ARRAY ARRAY['viewer', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_failed := false;
        BEGIN
            v_code := generate_crm_code('TSK');
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" drew the code % without being able to write', v_role, v_code;
        END IF;
    END LOOP;

    PERFORM set_config('app.current_role', 'admin', true);
END
$$;

-- --------------------------------------------------------------------------
-- node_merges: written by a merge, never forged, never erased.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_canonical uuid;
    v_dupe      uuid;
    v_failed    boolean;
    v_msg       text;
    v_real      uuid;
    v_role      text;
    v_rows      integer;
    v_total     integer;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:supporting-rls', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Tobin canonical', '{"suite":"supporting_rls"}')
    RETURNING id INTO v_canonical;
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Tobin duplicate', '{"suite":"supporting_rls"}')
    RETURNING id INTO v_dupe;

    PERFORM merge_nodes(v_dupe, v_canonical, 'test:supporting-rls');
    SELECT id INTO v_real
    FROM node_merges
    WHERE duplicate_id = v_dupe AND canonical_id = v_canonical;
    IF v_real IS NULL THEN
        RAISE EXCEPTION 'merge_nodes() as admin did not record a merge';
    END IF;

    -- A team_member merges too, and its record lands.
    PERFORM set_config('app.current_role', 'team_member', true);
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Tobin second duplicate', '{"suite":"supporting_rls"}')
    RETURNING id INTO v_dupe;
    PERFORM merge_nodes(v_dupe, v_canonical, 'test:supporting-rls');
    IF NOT EXISTS (
        SELECT 1 FROM node_merges
        WHERE duplicate_id = v_dupe AND canonical_id = v_canonical
    ) THEN
        RAISE EXCEPTION 'merge_nodes() as team_member did not record a merge';
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    SELECT count(*) INTO v_total FROM node_merges;

    -- ==================================================================
    -- Reproduction 2. A read-only session forges a merge and erases real
    -- ones.
    -- ==================================================================
    FOREACH v_role IN ARRAY ARRAY['viewer', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_failed := false;
        BEGIN
            INSERT INTO node_merges (duplicate_id, canonical_id, merged_by)
            VALUES (v_canonical, v_canonical, 'forged');
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" forged a merge record', v_role;
        END IF;
    END LOOP;

    -- Nobody updates or deletes one, including the roles that may write and
    -- including an admin: it is history.
    FOREACH v_role IN ARRAY ARRAY['viewer', '', 'agent:t', 'team_member', 'admin'] LOOP
        PERFORM set_config('app.current_role', v_role, true);

        v_failed := false;
        v_rows := -1;
        BEGIN
            DELETE FROM node_merges WHERE id = v_real;
            GET DIAGNOSTICS v_rows = ROW_COUNT;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed AND v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" deleted % merge records', v_role, v_rows;
        END IF;

        v_failed := false;
        v_rows := -1;
        BEGIN
            UPDATE node_merges SET merged_by = 'rewritten' WHERE id = v_real;
            GET DIAGNOSTICS v_rows = ROW_COUNT;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed AND v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" rewrote % merge records', v_role, v_rows;
        END IF;
    END LOOP;

    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT count(*) FROM node_merges) <> v_total THEN
        RAISE EXCEPTION 'The merge trail is % rows, was %',
            (SELECT count(*) FROM node_merges), v_total;
    END IF;
    IF (SELECT merged_by FROM node_merges WHERE id = v_real) <> 'test:supporting-rls' THEN
        RAISE EXCEPTION 'The merge record was rewritten to %',
            (SELECT merged_by FROM node_merges WHERE id = v_real);
    END IF;

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
END
$$;

ROLLBACK;
