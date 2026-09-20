-- Who may write.
--
-- Contract:  contracts/sql-surface.md, "Who may write".
-- Decision:  docs/decisions/0009-who-may-write.md.
-- Work item: work/009-who-may-write.md.
--
-- The ten in-database obligations from section E of the decision, in order.
-- Every case runs under a role RLS applies to: scripts/conformance.sh runs SQL
-- suites under RYE_TEST_ROLE when the connection is a superuser, and under
-- ./scripts/test-nonsuperuser-owner.sh they run as an owner that is NOSUPERUSER
-- NOBYPASSRLS. Invented names only: Wren, Tobin, Marsh, Ilsa.
--
-- Refusals are not uniform, so each case checks the right one. A refused INSERT
-- raises 42501. A refused UPDATE or DELETE raises nothing and affects zero
-- rows, so ROW_COUNT is checked and the row is re-read. A refused UPDATE that
-- passes USING and fails WITH CHECK does raise, so the two re-typing cases
-- accept either and assert the row is unchanged. The two helpers that look a
-- row up before they lock refuse with their own sentence.
--
-- `SET app.current_role = ...` is a syntax error because current_role is a
-- reserved word, so every case uses set_config() and asserts the read-back.

SET search_path = rye, public, pg_catalog;

BEGIN;

CREATE TEMP TABLE wmw_fixture (k text PRIMARY KEY, v text);

-- --------------------------------------------------------------------------
-- Obligation 1. Refuse to pass vacuously.
--
-- A superuser, or a role with BYPASSRLS, ignores row-level security even when
-- it is forced, and with row_security off every refusal below would be a
-- refusal for the wrong reason. Under test-nonsuperuser-owner.sh there is no
-- rye_conformance role and the suite runs as rye_owner with no SET ROLE, so the
-- guard to assert is rolsuper = false AND rolbypassrls = false.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_role   text;
    v_node   uuid;
    v_probe  uuid;
    v_seen   integer;
    v_super  boolean;
    v_bypass boolean;
BEGIN
    SELECT rolsuper, rolbypassrls INTO v_super, v_bypass
    FROM pg_roles WHERE rolname = current_user;
    IF coalesce(v_super, false) THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: % is a superuser and bypasses RLS. Run this suite under a non-superuser role, as scripts/conformance.sh does.',
            current_user;
    END IF;
    IF coalesce(v_bypass, false) THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: % has BYPASSRLS, so every policy below is inert.',
            current_user;
    END IF;
    IF current_setting('row_security', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'Refusing to pass vacuously: row_security is %',
            current_setting('row_security', true);
    END IF;

    -- Every role this suite uses must read back from the setting it was set
    -- with, or a case could silently run as the previous role.
    FOREACH v_role IN ARRAY ARRAY['admin', 'team_member', 'viewer', 'agent:t', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION
                'Refusing to pass vacuously: app.current_role did not read back as "%", it reads "%"',
                v_role, current_setting('app.current_role', true);
        END IF;
    END LOOP;

    -- And the rule this suite is about must be the rule the instance holds.
    PERFORM set_config('app.current_role', 'viewer', true);
    IF rye_role_may_write() THEN
        RAISE EXCEPTION 'Refusing to pass vacuously: rye_role_may_write() is true for a viewer';
    END IF;
    PERFORM set_config('app.current_role', '', true);
    IF rye_role_may_write() THEN
        RAISE EXCEPTION 'Refusing to pass vacuously: rye_role_may_write() is true for an unset role';
    END IF;
    PERFORM set_config('app.current_role', 'team_member', true);
    IF NOT rye_role_may_write() THEN
        RAISE EXCEPTION 'Refusing to pass vacuously: rye_role_may_write() is false for a team_member';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM role_classification_access
        WHERE role_name = 'viewer' AND may_write = false
    ) THEN
        RAISE EXCEPTION 'Refusing to pass vacuously: the viewer row is not seeded may_write false';
    END IF;

    -- Behavioural proof that RLS filters for this connection at all.
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:who-may-write', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Ilsa', '{"suite":"who_may_write"}')
    RETURNING id INTO v_node;

    v_probe := record_assertion(
        'compensation', '{"value":"rls probe"}', v_node,
        p_assertion_key := 'who_may_write:rls_probe', p_basis := 'assumed'
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
-- Fixtures, as admin. Nothing here is classified and nothing carries teams, so
-- every row below is visible to a viewer and to an unset role -- which is what
-- makes obligations 3 and 5 mean anything.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_wren      uuid;
    v_tobin     uuid;
    v_marsh     uuid;
    v_edge      uuid;
    v_plain     uuid;
    v_event     uuid;
    v_ep        uuid;
    v_assert    uuid;
    v_artifact  uuid;
    v_scope     uuid;
    v_scope_two uuid;
    v_gov_edge  uuid;
    v_subject   uuid;
    v_dupe      uuid;
    v_canon     uuid;
    v_gov_dupe  uuid;
    v_gov_canon uuid;
    v_gov_dupe2 uuid;
    v_gov_can2  uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:who-may-write', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Wren', '{"suite":"who_may_write"}') RETURNING id INTO v_wren;
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Tobin', '{"suite":"who_may_write"}') RETURNING id INTO v_tobin;
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('org', 'Marsh Supply', '{"suite":"who_may_write"}') RETURNING id INTO v_marsh;

    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES ('knows', v_wren, v_tobin, '{"suite":"who_may_write"}') RETURNING id INTO v_edge;
    -- A second ordinary edge, kept for the "re-type it into a governance edge"
    -- probe so the first one stays untouched for the archive probes.
    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES ('knows', v_tobin, v_marsh, '{"suite":"who_may_write"}') RETURNING id INTO v_plain;

    v_event := record_event(
        p_event_type        := 'wmw_meeting',
        p_summary           := 'Who may write fixture event',
        p_properties        := '{"suite":"who_may_write"}',
        p_participant_ids   := ARRAY[v_wren, v_tobin],
        p_participant_roles := ARRAY['subject', 'subject']
    );
    SELECT id INTO v_ep FROM event_participants
    WHERE event_id = v_event AND node_id = v_tobin LIMIT 1;

    v_assert := record_assertion(
        'wmw_probe', '{"value":"fixture"}', v_wren,
        p_assertion_key := 'who_may_write:fixture',
        p_status := 'accepted', p_basis := 'assumed'
    );

    v_artifact := record_artifact(
        p_artifact_type  := 'wmw_note',
        p_content        := '{"suite":"who_may_write"}',
        p_source_node_id := v_wren
    );

    -- The governance structure: a strict scope that governs one subject.
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('onboarding_scope', 'Who may write strict scope', '{"suite":"who_may_write"}')
    RETURNING id INTO v_scope;
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('onboarding_scope', 'Who may write second scope', '{"suite":"who_may_write"}')
    RETURNING id INTO v_scope_two;

    PERFORM record_assertion('review_policy', '{"review_policy":"strict"}', v_scope,
                             p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_scope,
                             p_basis := 'assumed');

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('project', 'Who may write governed subject', '{"suite":"who_may_write"}')
    RETURNING id INTO v_subject;

    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES ('scope_governs_subject', v_scope, v_subject, '{"suite":"who_may_write"}')
    RETURNING id INTO v_gov_edge;

    IF scope_review_policy(governing_scope(v_subject, NULL, 'wmw_probe', NULL)) <> 'strict' THEN
        RAISE EXCEPTION
            'Premise broken: the fixture subject is not governed by a strict scope, it is %',
            scope_review_policy(governing_scope(v_subject, NULL, 'wmw_probe', NULL));
    END IF;

    -- Merge fixtures: two ordinary pairs, and two pairs whose duplicate a live
    -- governance edge touches.
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Wren duplicate', '{"suite":"who_may_write"}') RETURNING id INTO v_dupe;
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Wren canonical', '{"suite":"who_may_write"}') RETURNING id INTO v_canon;
    PERFORM record_assertion(
        'wmw_probe', '{"value":"carried"}', v_dupe,
        p_assertion_key := 'who_may_write:merge_carry',
        p_status := 'accepted', p_basis := 'assumed'
    );

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('project', 'Governed duplicate', '{"suite":"who_may_write"}') RETURNING id INTO v_gov_dupe;
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('project', 'Governed canonical', '{"suite":"who_may_write"}') RETURNING id INTO v_gov_canon;
    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES ('scope_governs_subject', v_scope, v_gov_dupe, '{"suite":"who_may_write"}');

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('project', 'Governed duplicate two', '{"suite":"who_may_write"}') RETURNING id INTO v_gov_dupe2;
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('project', 'Governed canonical two', '{"suite":"who_may_write"}') RETURNING id INTO v_gov_can2;
    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES ('scope_governs_subject', v_scope, v_gov_dupe2, '{"suite":"who_may_write"}');

    INSERT INTO wmw_fixture (k, v) VALUES
        ('wren', v_wren::text), ('tobin', v_tobin::text), ('marsh', v_marsh::text),
        ('edge', v_edge::text), ('plain_edge', v_plain::text),
        ('event', v_event::text), ('ep', v_ep::text),
        ('assertion', v_assert::text), ('artifact', v_artifact::text),
        ('scope', v_scope::text), ('scope_two', v_scope_two::text),
        ('gov_edge', v_gov_edge::text), ('subject', v_subject::text),
        ('dupe', v_dupe::text), ('canon', v_canon::text),
        ('gov_dupe', v_gov_dupe::text), ('gov_canon', v_gov_canon::text),
        ('gov_dupe2', v_gov_dupe2::text), ('gov_canon2', v_gov_can2::text);
END
$$;

-- --------------------------------------------------------------------------
-- Obligations 2, 3, 4 and 5. A viewer and an unset role may read the fixture
-- and may not write any of the seven core tables, by raw SQL or through a
-- helper.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_role      text;
    v_wren      uuid := (SELECT v FROM wmw_fixture WHERE k = 'wren')::uuid;
    v_tobin     uuid := (SELECT v FROM wmw_fixture WHERE k = 'tobin')::uuid;
    v_edge      uuid := (SELECT v FROM wmw_fixture WHERE k = 'edge')::uuid;
    v_event     uuid := (SELECT v FROM wmw_fixture WHERE k = 'event')::uuid;
    v_ep        uuid := (SELECT v FROM wmw_fixture WHERE k = 'ep')::uuid;
    v_assert    uuid := (SELECT v FROM wmw_fixture WHERE k = 'assertion')::uuid;
    v_artifact  uuid := (SELECT v FROM wmw_fixture WHERE k = 'artifact')::uuid;
    v_dupe      uuid := (SELECT v FROM wmw_fixture WHERE k = 'dupe')::uuid;
    v_canon     uuid := (SELECT v FROM wmw_fixture WHERE k = 'canon')::uuid;
    v_failed    boolean;
    v_state     text;
    v_msg       text;
    v_rows      integer;
    v_before    integer;
    v_after     integer;
    v_seen      integer;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['viewer', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION 'Role did not read back as "%"', v_role;
        END IF;

        -- ------------------------------------------------------------------
        -- Obligation 5, taken first, because every refusal below is only
        -- meaningful if this role can see the row it fails to change.
        -- ------------------------------------------------------------------
        SELECT count(*) INTO v_seen FROM nodes WHERE properties->>'suite' = 'who_may_write';
        IF v_seen = 0 THEN
            RAISE EXCEPTION 'Role "%" cannot see the fixture nodes, so nothing below proves a refusal', v_role;
        END IF;
        SELECT count(*) INTO v_seen FROM edges WHERE id = v_edge;
        IF v_seen <> 1 THEN
            RAISE EXCEPTION 'Role "%" sees % fixture edges, expected 1', v_role, v_seen;
        END IF;
        SELECT count(*) INTO v_seen FROM events WHERE id = v_event;
        IF v_seen <> 1 THEN
            RAISE EXCEPTION 'Role "%" sees % fixture events, expected 1', v_role, v_seen;
        END IF;
        SELECT count(*) INTO v_seen FROM assertions WHERE id = v_assert;
        IF v_seen <> 1 THEN
            RAISE EXCEPTION 'Role "%" sees % fixture assertions, expected 1', v_role, v_seen;
        END IF;
        SELECT count(*) INTO v_seen FROM current_valid_assertions WHERE id = v_assert;
        IF v_seen <> 1 THEN
            RAISE EXCEPTION 'Role "%" sees % fixture rows in current_valid_assertions, expected 1', v_role, v_seen;
        END IF;
        SELECT count(*) INTO v_seen FROM node_context WHERE node_id = v_wren;
        IF v_seen <> 1 THEN
            RAISE EXCEPTION 'Role "%" sees % node_context rows for the fixture node, expected 1', v_role, v_seen;
        END IF;
        SELECT count(*) INTO v_seen FROM event_participants WHERE id = v_ep;
        IF v_seen <> 1 THEN
            RAISE EXCEPTION 'Role "%" sees % fixture event_participants, expected 1', v_role, v_seen;
        END IF;
        SELECT count(*) INTO v_seen FROM artifacts WHERE id = v_artifact;
        IF v_seen <> 1 THEN
            RAISE EXCEPTION 'Role "%" sees % fixture artifacts, expected 1', v_role, v_seen;
        END IF;

        -- ------------------------------------------------------------------
        -- Obligation 2. Every INSERT raises 42501 and lands nothing.
        -- ------------------------------------------------------------------
        SELECT count(*) INTO v_before FROM nodes;
        v_failed := false;
        BEGIN
            INSERT INTO nodes (node_type, label, properties)
            VALUES ('person', 'Refused node', '{"suite":"who_may_write_refused"}');
        EXCEPTION WHEN OTHERS THEN
            v_failed := true; v_state := SQLSTATE;
        END;
        IF NOT v_failed OR v_state <> '42501' THEN
            RAISE EXCEPTION 'Role "%" inserted a node (failed=%, sqlstate=%)', v_role, v_failed, v_state;
        END IF;
        SELECT count(*) INTO v_after FROM nodes;
        IF v_after <> v_before THEN
            RAISE EXCEPTION 'Role "%" changed the nodes row count from % to %', v_role, v_before, v_after;
        END IF;

        v_failed := false;
        BEGIN
            INSERT INTO edges (edge_type, source_id, target_id)
            VALUES ('refused_relation', v_wren, v_tobin);
        EXCEPTION WHEN OTHERS THEN
            v_failed := true; v_state := SQLSTATE;
        END;
        IF NOT v_failed OR v_state <> '42501' THEN
            RAISE EXCEPTION 'Role "%" inserted an edge (failed=%, sqlstate=%)', v_role, v_failed, v_state;
        END IF;

        v_failed := false;
        BEGIN
            INSERT INTO events (event_type, occurred_at, summary)
            VALUES ('refused_event', now(), 'Refused');
        EXCEPTION WHEN OTHERS THEN
            v_failed := true; v_state := SQLSTATE;
        END;
        IF NOT v_failed OR v_state <> '42501' THEN
            RAISE EXCEPTION 'Role "%" inserted an event (failed=%, sqlstate=%)', v_role, v_failed, v_state;
        END IF;

        v_failed := false;
        BEGIN
            INSERT INTO event_participants (event_id, node_id, role)
            VALUES (v_event, v_wren, 'refused');
        EXCEPTION WHEN OTHERS THEN
            v_failed := true; v_state := SQLSTATE;
        END;
        IF NOT v_failed OR v_state <> '42501' THEN
            RAISE EXCEPTION 'Role "%" inserted an event participant (failed=%, sqlstate=%)', v_role, v_failed, v_state;
        END IF;

        v_failed := false;
        BEGIN
            INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, status, basis)
            VALUES ('wmw_probe', 'who_may_write:refused', v_wren, '{"value":"refused"}', 'accepted', 'assumed');
        EXCEPTION WHEN OTHERS THEN
            v_failed := true; v_state := SQLSTATE;
        END;
        IF NOT v_failed OR v_state <> '42501' THEN
            RAISE EXCEPTION 'Role "%" inserted an assertion (failed=%, sqlstate=%)', v_role, v_failed, v_state;
        END IF;
        IF EXISTS (SELECT 1 FROM assertions WHERE assertion_key = 'who_may_write:refused') THEN
            RAISE EXCEPTION 'Role "%" left a refused assertion behind', v_role;
        END IF;

        -- A well-formed evidence row: the insert policy needs a visible
        -- assertion and a visible event, and both are in the fixture, so the
        -- only thing left to refuse it is the role.
        v_failed := false;
        BEGIN
            INSERT INTO assertion_evidence (assertion_id, kind, event_id)
            VALUES (v_assert, 'source', v_event);
        EXCEPTION WHEN OTHERS THEN
            v_failed := true; v_state := SQLSTATE;
        END;
        IF NOT v_failed OR v_state <> '42501' THEN
            RAISE EXCEPTION 'Role "%" inserted assertion evidence (failed=%, sqlstate=%)', v_role, v_failed, v_state;
        END IF;

        v_failed := false;
        BEGIN
            INSERT INTO artifacts (artifact_type, content, source_node_id)
            VALUES ('refused_artifact', '{"suite":"who_may_write_refused"}', v_wren);
        EXCEPTION WHEN OTHERS THEN
            v_failed := true; v_state := SQLSTATE;
        END;
        IF NOT v_failed OR v_state <> '42501' THEN
            RAISE EXCEPTION 'Role "%" inserted an artifact (failed=%, sqlstate=%)', v_role, v_failed, v_state;
        END IF;

        -- ------------------------------------------------------------------
        -- Obligation 3. Every UPDATE and DELETE affects zero rows -- RLS turns
        -- these into silence, not an error -- and the row is unchanged after.
        -- ------------------------------------------------------------------
        UPDATE nodes SET archived_at = now() WHERE id = v_wren;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" archived % node rows', v_role, v_rows;
        END IF;
        IF (SELECT archived_at FROM nodes WHERE id = v_wren) IS NOT NULL THEN
            RAISE EXCEPTION 'Role "%" archived the fixture node', v_role;
        END IF;

        UPDATE edges SET archived_at = now() WHERE id = v_edge;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" archived % edge rows', v_role, v_rows;
        END IF;
        IF (SELECT archived_at FROM edges WHERE id = v_edge) IS NOT NULL THEN
            RAISE EXCEPTION 'Role "%" archived the fixture edge', v_role;
        END IF;

        DELETE FROM edges WHERE id = v_edge;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" deleted % edge rows', v_role, v_rows;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM edges WHERE id = v_edge) THEN
            RAISE EXCEPTION 'Role "%" deleted the fixture edge', v_role;
        END IF;

        UPDATE event_participants SET role = 'hijacked' WHERE id = v_ep;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" updated % event_participants rows', v_role, v_rows;
        END IF;
        IF (SELECT role FROM event_participants WHERE id = v_ep) = 'hijacked' THEN
            RAISE EXCEPTION 'Role "%" changed the fixture participant role', v_role;
        END IF;

        DELETE FROM event_participants WHERE id = v_ep;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" deleted % event_participants rows', v_role, v_rows;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM event_participants WHERE id = v_ep) THEN
            RAISE EXCEPTION 'Role "%" deleted the fixture participant', v_role;
        END IF;

        UPDATE artifacts SET content = '{"hijacked":true}' WHERE id = v_artifact;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" updated % artifact rows', v_role, v_rows;
        END IF;
        IF (SELECT content->>'hijacked' FROM artifacts WHERE id = v_artifact) IS NOT NULL THEN
            RAISE EXCEPTION 'Role "%" rewrote the fixture artifact', v_role;
        END IF;

        DELETE FROM artifacts WHERE id = v_artifact;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" deleted % artifact rows', v_role, v_rows;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM artifacts WHERE id = v_artifact) THEN
            RAISE EXCEPTION 'Role "%" deleted the fixture artifact', v_role;
        END IF;

        -- The assertion UPDATE, with the helper's own session settings forged.
        -- Any caller can set them; the role conjunct is what refuses this.
        PERFORM set_config('app.write_path', 'accept_assertion', true);
        PERFORM set_config('app.accept_assertion_id', v_assert::text, true);
        UPDATE assertions SET status = 'candidate' WHERE id = v_assert;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        PERFORM set_config('app.write_path', '', true);
        PERFORM set_config('app.accept_assertion_id', '', true);
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" updated % assertion rows with a forged write path', v_role, v_rows;
        END IF;
        IF (SELECT status FROM assertions WHERE id = v_assert) <> 'accepted' THEN
            RAISE EXCEPTION 'Role "%" demoted the fixture assertion', v_role;
        END IF;

        -- ------------------------------------------------------------------
        -- Obligation 4. Each helper is refused, and by its effect.
        -- ------------------------------------------------------------------
        SELECT count(*) INTO v_before FROM events;
        v_failed := false;
        BEGIN
            PERFORM record_event(
                p_event_type      := 'wmw_refused',
                p_summary         := 'Refused',
                p_participant_ids := ARRAY[v_wren]
            );
        EXCEPTION WHEN OTHERS THEN
            v_failed := true; v_state := SQLSTATE;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" recorded an event through record_event()', v_role;
        END IF;
        SELECT count(*) INTO v_after FROM events;
        IF v_after <> v_before THEN
            RAISE EXCEPTION 'Role "%" left % new events behind', v_role, v_after - v_before;
        END IF;

        v_failed := false;
        BEGIN
            PERFORM record_assertion(
                'wmw_probe', '{"value":"refused"}', v_wren,
                p_assertion_key := 'who_may_write:helper_refused', p_basis := 'assumed'
            );
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" recorded an assertion through record_assertion()', v_role;
        END IF;
        IF EXISTS (SELECT 1 FROM assertions WHERE assertion_key = 'who_may_write:helper_refused') THEN
            RAISE EXCEPTION 'Role "%" left a helper-written assertion behind', v_role;
        END IF;

        SELECT count(*) INTO v_before FROM artifacts;
        v_failed := false;
        BEGIN
            PERFORM record_artifact(
                p_artifact_type  := 'wmw_refused',
                p_content        := '{"suite":"who_may_write_refused"}',
                p_source_node_id := v_wren
            );
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" recorded an artifact through record_artifact()', v_role;
        END IF;
        SELECT count(*) INTO v_after FROM artifacts;
        IF v_after <> v_before THEN
            RAISE EXCEPTION 'Role "%" left % new artifacts behind', v_role, v_after - v_before;
        END IF;

        v_failed := false;
        BEGIN
            PERFORM link_record(
                p_source_schema := 'wmw',
                p_source_table  := 'refused',
                p_source_id     := 'r1',
                p_node_type     := 'org',
                p_label         := 'Refused link'
            );
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" linked a record through link_record()', v_role;
        END IF;
        IF EXISTS (
            SELECT 1 FROM node_source_map
            WHERE source_schema = 'wmw' AND source_table = 'refused'
        ) THEN
            RAISE EXCEPTION 'Role "%" left a source mapping behind', v_role;
        END IF;

        -- update_node_properties() and merge_nodes() refuse with their own
        -- sentence rather than letting RLS report a visible node as missing.
        v_failed := false;
        BEGIN
            PERFORM update_node_properties(v_wren, '{"hijacked":true}');
        EXCEPTION WHEN OTHERS THEN
            v_failed := true; v_state := SQLSTATE; v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" updated node properties through the helper', v_role;
        END IF;
        IF v_state <> '42501' OR v_msg NOT LIKE '%may only read%' OR v_msg LIKE '%not found%' THEN
            RAISE EXCEPTION
                'Role "%" update_node_properties refused with sqlstate % and message "%"',
                v_role, v_state, v_msg;
        END IF;
        IF (SELECT properties->>'hijacked' FROM nodes WHERE id = v_wren) IS NOT NULL THEN
            RAISE EXCEPTION 'Role "%" changed the fixture node properties', v_role;
        END IF;

        v_failed := false;
        BEGIN
            PERFORM merge_nodes(v_dupe, v_canon);
        EXCEPTION WHEN OTHERS THEN
            v_failed := true; v_state := SQLSTATE; v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" merged two nodes', v_role;
        END IF;
        IF v_state <> '42501'
           OR v_msg NOT LIKE '%merge_nodes requires a role that may write%'
           OR v_msg NOT LIKE '%A Rye admin or a team member merges.%'
           OR v_msg LIKE '%not found%'
        THEN
            RAISE EXCEPTION
                'Role "%" merge_nodes refused with sqlstate % and message "%"',
                v_role, v_state, v_msg;
        END IF;
        IF (SELECT archived_at FROM nodes WHERE id = v_dupe) IS NOT NULL THEN
            RAISE EXCEPTION 'Role "%" archived the merge duplicate', v_role;
        END IF;
    END LOOP;

    PERFORM set_config('app.current_role', 'admin', true);
END
$$;

-- --------------------------------------------------------------------------
-- Obligations 6 and 7. Nobody but a Rye admin changes the rows that decide
-- which review policy governs a subject, and after every refusal the policy is
-- still what it was and an agent's write is still a candidate.
--
-- team_member is the case that proves the rule is not just the old
-- NOT LIKE 'agent:%' test.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_role     text;
    v_scope    uuid := (SELECT v FROM wmw_fixture WHERE k = 'scope')::uuid;
    v_gov_edge uuid := (SELECT v FROM wmw_fixture WHERE k = 'gov_edge')::uuid;
    v_plain    uuid := (SELECT v FROM wmw_fixture WHERE k = 'plain_edge')::uuid;
    v_subject  uuid := (SELECT v FROM wmw_fixture WHERE k = 'subject')::uuid;
    v_tobin    uuid := (SELECT v FROM wmw_fixture WHERE k = 'tobin')::uuid;
    v_marsh    uuid := (SELECT v FROM wmw_fixture WHERE k = 'marsh')::uuid;
    v_rows     integer;
    v_failed   boolean;
    v_state    text;
    v_probe    uuid;
    v_status   text;
    v_n        integer;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['agent:t', 'team_member', 'viewer', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION 'Role did not read back as "%"', v_role;
        END IF;

        -- The rows have to be visible, or every zero below is a zero for the
        -- wrong reason.
        SELECT count(*) INTO v_n FROM nodes WHERE id = v_scope;
        IF v_n <> 1 THEN
            RAISE EXCEPTION 'Role "%" cannot see the scope node', v_role;
        END IF;
        SELECT count(*) INTO v_n FROM edges WHERE id = v_gov_edge;
        IF v_n <> 1 THEN
            RAISE EXCEPTION 'Role "%" cannot see the governance edge', v_role;
        END IF;

        -- Archive the scope node. An agent needs the write-path gate open even
        -- to be considered, so forge it: the governance conjunct is what
        -- refuses, not the gate.
        PERFORM set_config('app.write_path', 'update_node_properties', true);
        UPDATE nodes SET archived_at = now() WHERE id = v_scope;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        PERFORM set_config('app.write_path', '', true);
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" archived % scope nodes', v_role, v_rows;
        END IF;

        DELETE FROM nodes WHERE id = v_scope;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" deleted % scope nodes', v_role, v_rows;
        END IF;

        -- Archive, end, delete and re-point the governance edge.
        UPDATE edges SET archived_at = now() WHERE id = v_gov_edge;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" archived % governance edges', v_role, v_rows;
        END IF;

        UPDATE edges SET effective_to = now() - interval '1 day' WHERE id = v_gov_edge;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" ended % governance edges', v_role, v_rows;
        END IF;

        DELETE FROM edges WHERE id = v_gov_edge;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" deleted % governance edges', v_role, v_rows;
        END IF;

        UPDATE edges SET source_id = v_tobin WHERE id = v_gov_edge;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" re-pointed % governance edge sources', v_role, v_rows;
        END IF;

        UPDATE edges SET target_id = v_tobin WHERE id = v_gov_edge;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" re-pointed % governance edge targets', v_role, v_rows;
        END IF;

        -- Demote a governance edge to an ordinary one, and promote an ordinary
        -- edge to a governance one. The first fails USING; the second passes
        -- USING for a writing role and fails WITH CHECK, which raises. Either
        -- refusal is correct, so what is asserted is the row.
        v_failed := false;
        BEGIN
            UPDATE edges SET edge_type = 'knows' WHERE id = v_gov_edge;
            GET DIAGNOSTICS v_rows = ROW_COUNT;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true; v_rows := 0;
        END;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" demoted % governance edges to ordinary ones', v_role, v_rows;
        END IF;
        IF (SELECT edge_type FROM edges WHERE id = v_gov_edge) <> 'scope_governs_subject' THEN
            RAISE EXCEPTION 'Role "%" changed the governance edge type', v_role;
        END IF;

        v_failed := false;
        BEGIN
            UPDATE edges SET edge_type = 'scope_governs_subject' WHERE id = v_plain;
            GET DIAGNOSTICS v_rows = ROW_COUNT;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true; v_rows := 0;
        END;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" promoted % ordinary edges to governance ones', v_role, v_rows;
        END IF;
        IF (SELECT edge_type FROM edges WHERE id = v_plain) <> 'knows' THEN
            RAISE EXCEPTION 'Role "%" re-typed the ordinary edge', v_role;
        END IF;

        -- Insert a new governance edge, and a new scope node.
        v_failed := false;
        BEGIN
            INSERT INTO edges (edge_type, source_id, target_id)
            VALUES ('scope_governs_subject', v_marsh, v_subject);
        EXCEPTION WHEN OTHERS THEN
            v_failed := true; v_state := SQLSTATE;
        END;
        IF NOT v_failed OR v_state <> '42501' THEN
            RAISE EXCEPTION
                'Role "%" inserted a governance edge (failed=%, sqlstate=%)', v_role, v_failed, v_state;
        END IF;

        v_failed := false;
        BEGIN
            INSERT INTO nodes (node_type, label)
            VALUES ('onboarding_scope', 'Rogue scope');
        EXCEPTION WHEN OTHERS THEN
            v_failed := true; v_state := SQLSTATE;
        END;
        IF NOT v_failed OR v_state <> '42501' THEN
            RAISE EXCEPTION
                'Role "%" inserted a scope node (failed=%, sqlstate=%)', v_role, v_failed, v_state;
        END IF;

        -- ------------------------------------------------------------------
        -- Obligation 7. The refusals mattered: the policy is unchanged, and an
        -- agent's write into that scope is still a candidate.
        -- ------------------------------------------------------------------
        PERFORM set_config('app.current_role', 'admin', true);
        IF scope_review_policy(governing_scope(v_subject, NULL, 'wmw_probe', NULL)) <> 'strict' THEN
            RAISE EXCEPTION
                'After role "%" attacked the structure the subject''s policy is %',
                v_role,
                scope_review_policy(governing_scope(v_subject, NULL, 'wmw_probe', NULL));
        END IF;

        PERFORM set_config('app.current_role', 'agent:t', true);
        v_probe := record_assertion(
            'wmw_probe', '{"value":"agent said"}', v_subject,
            p_assertion_key := 'who_may_write:after_' || coalesce(nullif(v_role, ''), 'unset'),
            p_status := 'accepted', p_basis := 'assumed'
        );
        SELECT status INTO v_status FROM assertions WHERE id = v_probe;
        IF v_status <> 'candidate' THEN
            RAISE EXCEPTION
                'After role "%" attacked the structure an agent write landed %, not candidate',
                v_role, v_status;
        END IF;
    END LOOP;

    PERFORM set_config('app.current_role', 'admin', true);
END
$$;

-- --------------------------------------------------------------------------
-- Obligation 8. scope_status is settle-gated to admin, like the other three
-- configuration types. A non-admin's "make this scope active" lands as a
-- suggestion, and an admin still activates a scope.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_role      text;
    v_scope_two uuid := (SELECT v FROM wmw_fixture WHERE k = 'scope_two')::uuid;
    v_subject   uuid := (SELECT v FROM wmw_fixture WHERE k = 'subject')::uuid;
    v_row       assertions;
    v_id        uuid;
    v_other     uuid;
    v_target    uuid;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM assertion_type_access
        WHERE assertion_type = 'scope_status' AND operation = 'settle'
          AND allowed_roles = ARRAY['admin']
    ) THEN
        RAISE EXCEPTION 'scope_status is not settle-gated to admin';
    END IF;

    FOREACH v_role IN ARRAY ARRAY['agent:t', 'team_member'] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_id := record_assertion(
            'scope_status', '{"status":"active"}', v_scope_two,
            p_assertion_key := 'who_may_write:status_' || v_role,
            p_status := 'accepted', p_basis := 'assumed'
        );
        SELECT * INTO v_row FROM assertions WHERE id = v_id;
        IF v_row.status <> 'candidate'
           OR (v_row.attrs->'settle_gate'->>'pending')::boolean IS DISTINCT FROM true
        THEN
            RAISE EXCEPTION
                'Role "%" activated a scope: status %, attrs %', v_role, v_row.status, v_row.attrs;
        END IF;

        PERFORM set_config('app.current_role', 'admin', true);
        IF scope_review_policy(governing_scope(v_subject, NULL, 'wmw_probe', NULL)) <> 'strict' THEN
            RAISE EXCEPTION
                'Role "%" changed the governing policy through scope_status', v_role;
        END IF;
    END LOOP;

    -- An admin still activates a scope, and it then governs what it covers.
    PERFORM set_config('app.current_role', 'admin', true);
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('project', 'Second scope subject', '{"suite":"who_may_write"}')
    RETURNING id INTO v_target;
    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('scope_governs_subject', v_scope_two, v_target);
    PERFORM record_assertion('review_policy', '{"review_policy":"candidates_only"}', v_scope_two,
                             p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_scope_two,
                             p_basis := 'assumed');

    v_other := governing_scope(v_target, NULL, 'wmw_probe', NULL);
    IF v_other IS DISTINCT FROM v_scope_two THEN
        RAISE EXCEPTION 'An admin could not activate a scope: governing_scope returned %', v_other;
    END IF;
    IF scope_review_policy(v_other) <> 'candidates_only' THEN
        RAISE EXCEPTION 'The admin-activated scope reads policy %', scope_review_policy(v_other);
    END IF;
END
$$;

-- --------------------------------------------------------------------------
-- Obligation 9. merge_nodes() is for people, and it says so before it locks.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_dupe       uuid := (SELECT v FROM wmw_fixture WHERE k = 'dupe')::uuid;
    v_canon      uuid := (SELECT v FROM wmw_fixture WHERE k = 'canon')::uuid;
    v_gov_dupe   uuid := (SELECT v FROM wmw_fixture WHERE k = 'gov_dupe')::uuid;
    v_gov_canon  uuid := (SELECT v FROM wmw_fixture WHERE k = 'gov_canon')::uuid;
    v_gov_dupe2  uuid := (SELECT v FROM wmw_fixture WHERE k = 'gov_dupe2')::uuid;
    v_gov_canon2 uuid := (SELECT v FROM wmw_fixture WHERE k = 'gov_canon2')::uuid;
    v_wren       uuid := (SELECT v FROM wmw_fixture WHERE k = 'wren')::uuid;
    v_tobin      uuid := (SELECT v FROM wmw_fixture WHERE k = 'tobin')::uuid;
    v_failed     boolean;
    v_state      text;
    v_msg        text;
BEGIN
    -- An agent is refused by name, not by a missing row. Under an owner RLS
    -- binds this is exactly the case that used to say "Duplicate node % not
    -- found" about a node the caller could see.
    PERFORM set_config('app.current_role', 'agent:t', true);
    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = v_dupe) THEN
        RAISE EXCEPTION 'The merge duplicate is invisible to an agent, so the message below proves nothing';
    END IF;
    v_failed := false;
    BEGIN
        PERFORM merge_nodes(v_dupe, v_canon);
    EXCEPTION WHEN OTHERS THEN
        v_failed := true; v_state := SQLSTATE; v_msg := SQLERRM;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'An agent merged two nodes';
    END IF;
    IF v_state <> '42501'
       OR v_msg NOT LIKE '%merge_nodes is not available to an agent%'
       OR v_msg NOT LIKE '%Record the duplicate and ask a person%'
       OR v_msg LIKE '%not found%'
    THEN
        RAISE EXCEPTION 'An agent''s merge refusal was sqlstate % message "%"', v_state, v_msg;
    END IF;

    -- A viewer gets the read-only sentence. (The same case runs inside the
    -- viewer/unset loop above; it is repeated here so obligation 9 is complete
    -- on its own.)
    PERFORM set_config('app.current_role', 'viewer', true);
    v_failed := false;
    BEGIN
        PERFORM merge_nodes(v_dupe, v_canon);
    EXCEPTION WHEN OTHERS THEN
        v_failed := true; v_state := SQLSTATE; v_msg := SQLERRM;
    END;
    IF NOT v_failed
       OR v_state <> '42501'
       OR v_msg NOT LIKE '%may only read%'
       OR v_msg LIKE '%not found%'
    THEN
        RAISE EXCEPTION 'A viewer''s merge refusal was sqlstate % message "%"', v_state, v_msg;
    END IF;

    -- A team_member may merge two ordinary nodes, and the duplicate's fact
    -- stands on the canonical node afterwards.
    PERFORM set_config('app.current_role', 'team_member', true);
    PERFORM merge_nodes(v_dupe, v_canon, 'test:who-may-write');
    IF (SELECT archived_at FROM nodes WHERE id = v_dupe) IS NULL THEN
        RAISE EXCEPTION 'A team_member''s merge left the duplicate active';
    END IF;
    PERFORM set_config('app.current_role', 'admin', true);
    IF NOT EXISTS (
        SELECT 1 FROM current_valid_assertions
        WHERE subject_node_id = v_canon
          AND assertion_key = 'who_may_write:merge_carry'
    ) THEN
        RAISE EXCEPTION 'A team_member''s merge did not carry the duplicate''s fact to the canonical node';
    END IF;

    -- A team_member may not merge a node a live governance edge touches,
    -- because the merge would have to re-point that edge.
    PERFORM set_config('app.current_role', 'team_member', true);
    v_failed := false;
    BEGIN
        PERFORM merge_nodes(v_gov_dupe, v_gov_canon, 'test:who-may-write');
    EXCEPTION WHEN OTHERS THEN
        v_failed := true; v_state := SQLSTATE; v_msg := SQLERRM;
    END;
    IF NOT v_failed
       OR v_state <> '42501'
       OR v_msg NOT LIKE '%Merging a node a scope governs requires a Rye admin%'
       OR v_msg LIKE '%not found%'
    THEN
        RAISE EXCEPTION
            'A team_member''s governed merge refusal was sqlstate % message "%"', v_state, v_msg;
    END IF;
    IF (SELECT archived_at FROM nodes WHERE id = v_gov_dupe) IS NOT NULL THEN
        RAISE EXCEPTION 'A team_member''s refused merge still archived the duplicate';
    END IF;

    -- An admin may, on the second governed pair.
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM merge_nodes(v_gov_dupe2, v_gov_canon2, 'test:who-may-write');
    IF (SELECT archived_at FROM nodes WHERE id = v_gov_dupe2) IS NULL THEN
        RAISE EXCEPTION 'An admin''s merge of a governed node left the duplicate active';
    END IF;

    -- And an admin still merges two ordinary nodes.
    PERFORM merge_nodes(v_tobin, v_wren, 'test:who-may-write');
    IF (SELECT archived_at FROM nodes WHERE id = v_tobin) IS NULL THEN
        RAISE EXCEPTION 'An admin''s merge of two ordinary nodes left the duplicate active';
    END IF;
END
$$;

-- --------------------------------------------------------------------------
-- Obligation 10. An admin is not exempt from the row rules. 0026 added a role
-- model; it did not open a bypass.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_marsh  uuid := (SELECT v FROM wmw_fixture WHERE k = 'marsh')::uuid;
    v_id     uuid;
    v_failed boolean := false;
    v_msg    text;
    v_row    assertions;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    v_id := record_assertion(
        'wmw_probe', '{"value":"admin incumbent"}', v_marsh,
        p_assertion_key := 'who_may_write:admin_incumbent',
        p_status := 'accepted', p_basis := 'assumed'
    );
    IF (SELECT status FROM assertions WHERE id = v_id) <> 'accepted' THEN
        RAISE EXCEPTION 'An admin could not record an accepted assertion';
    END IF;

    BEGIN
        PERFORM set_config('app.write_path', 'supersede_assertion', true);
        PERFORM set_config('app.supersede_assertion_id', v_id::text, true);
        UPDATE assertions SET superseded_at = now() WHERE id = v_id;
    EXCEPTION WHEN OTHERS THEN
        v_failed := true; v_msg := SQLERRM;
    END;
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.supersede_assertion_id', '', true);

    IF NOT v_failed THEN
        RAISE EXCEPTION 'An admin ended an accepted assertion with a raw UPDATE';
    END IF;
    IF v_msg NOT LIKE '%cannot be ended with nothing replacing it%' THEN
        RAISE EXCEPTION 'The admin''s raw UPDATE failed for the wrong reason: %', v_msg;
    END IF;

    SELECT * INTO v_row FROM assertions WHERE id = v_id;
    IF v_row.status <> 'accepted' OR v_row.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION
            'The admin''s raw UPDATE left status %, superseded_at %', v_row.status, v_row.superseded_at;
    END IF;
END
$$;

DO $$
BEGIN
    RAISE NOTICE 'Who may write: all obligations passed';
END
$$;

ROLLBACK;
