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

-- --------------------------------------------------------------------------
-- Fixtures for obligations 11 and 12, as admin. Everything here hangs off one
-- ungoverned subject, so the review policy is `open` and the admin half of
-- each pair is expected to succeed outright. That premise is asserted, not
-- assumed.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_sub    uuid;
    v_cand_a uuid;
    v_cand_r uuid;
    v_acc_o  uuid;
    v_gap    uuid;
    v_answer uuid;
    v_kcand  uuid;
    v_agent  uuid;
    v_pred   uuid;
    v_acc_s  uuid;
    v_acc_f  uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:who-may-write', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Definer probe subject', '{"suite":"who_may_write"}')
    RETURNING id INTO v_sub;

    IF scope_review_policy(governing_scope(v_sub, NULL, 'wmw_probe', NULL)) <> 'open' THEN
        RAISE EXCEPTION
            'Premise broken: the definer-probe subject is governed by %, so the admin half of each pair below would not be a clean success',
            scope_review_policy(governing_scope(v_sub, NULL, 'wmw_probe', NULL));
    END IF;

    v_cand_a := record_assertion('wmw_probe', '{"value":"accept me"}', v_sub,
        p_assertion_key := 'def:accept', p_status := 'candidate', p_basis := 'assumed');
    v_cand_r := record_assertion('wmw_probe', '{"value":"reject me"}', v_sub,
        p_assertion_key := 'def:reject', p_status := 'candidate', p_basis := 'assumed');
    v_acc_o := record_assertion('wmw_probe', '{"value":"label me"}', v_sub,
        p_assertion_key := 'def:outcome', p_status := 'accepted', p_basis := 'assumed');
    v_acc_s := record_assertion('wmw_probe', '{"value":"supersede me"}', v_sub,
        p_assertion_key := 'def:supersede', p_status := 'accepted', p_basis := 'assumed');
    v_acc_f := record_assertion('wmw_probe', '{"value":"forge against me"}', v_sub,
        p_assertion_key := 'def:forge', p_status := 'accepted', p_basis := 'assumed');

    v_answer := record_assertion('wmw_probe', '{"value":"the answer"}', v_sub,
        p_assertion_key := 'def:answer', p_status := 'accepted', p_basis := 'assumed');
    v_gap := record_assertion('knowledge_gap', '{"question":"what?","status":"open"}', v_sub,
        p_assertion_key := 'def:gap', p_status := 'accepted', p_basis := 'assumed');

    v_kcand := create_knowledge_candidate(
        p_candidate_kind := 'decision',
        p_statement      := 'Who may write knowledge candidate',
        p_created_by     := 'test:who-may-write');

    v_agent := create_agent_identity('wmw_definer_agent', 'Who May Write Definer Agent', 'conformance');
    PERFORM grant_agent_capability('wmw_definer_agent', 'rye.observation.create');
    PERFORM grant_agent_capability('wmw_definer_agent', 'rye.candidate.create');

    v_pred := record_prediction(
        p_subject_node_id := v_sub,
        p_subject_edge_id := NULL,
        p_assertion_key   := 'def:prediction',
        p_question        := 'Will the gate hold?',
        p_outcome_key     := 'wmw_probe:def:outcome',
        p_predicted_value := '{"value":"label me"}',
        p_probability     := 0.8,
        p_horizon         := now() - interval '1 day',
        p_witness_node_id := v_sub,
        p_actor           := 'test:who-may-write');

    INSERT INTO wmw_fixture (k, v) VALUES
        ('def_sub', v_sub::text),
        ('def_cand_accept', v_cand_a::text),
        ('def_cand_reject', v_cand_r::text),
        ('def_acc_outcome', v_acc_o::text),
        ('def_acc_supersede', v_acc_s::text),
        ('def_acc_forge', v_acc_f::text),
        ('def_gap', v_gap::text),
        ('def_answer', v_answer::text),
        ('def_kcand', v_kcand::text),
        ('def_agent', v_agent::text),
        ('def_prediction', v_pred::text);
END
$$;

-- --------------------------------------------------------------------------
-- Obligation 11. Every SECURITY DEFINER writer is refused for `viewer` and for
-- an unset role, under both owner types.
--
-- This is the case the first verification missed. A `SECURITY DEFINER` helper
-- owned by a superuser runs with RLS switched off for itself, so the policy
-- conjunct never fires and a `viewer` accepted a candidate, closed one, and
-- rewrote `attrs`. The gate is therefore a trigger, and the assertion here is
-- the effect on the row rather than any error text: on an owner RLS binds the
-- write is filtered away silently, and on a superuser owner the trigger raises.
--
-- The covered list is checked against `pg_proc` below rather than trusted, so
-- a definer writer added later fails this suite instead of slipping through.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_covered text[] := ARRAY[
        'accept_assertion',
        'agent_create_candidate',
        'agent_submit_observation',
        'mark_assertion_outcome',
        'promote_candidate_node_to_assertion',
        'reject_candidate',
        'resolve_knowledge_gap',
        'score_due_predictions'
    ];
    v_derived text[];
    v_missing text[];
BEGIN
    SELECT array_agg(DISTINCT p.proname ORDER BY p.proname)
    INTO v_derived
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'rye'
      AND p.prosecdef
      AND (
          -- writes a core table itself
          p.prosrc ~* '(insert\s+into|update\s+|delete\s+from)\s*(rye\.)?(nodes|edges|events|event_participants|assertions|assertion_evidence|artifacts)\M'
          -- or reaches one through a helper that does
          OR p.prosrc ~* '(record_event|record_assertion|record_artifact|mark_assertion_superseded|mark_assertion_outcome|accept_assertion|reject_candidate|append_assertion_evidence|create_knowledge_candidate|link_record|record_distillation)\s*\('
      );

    SELECT array_agg(d) INTO v_missing
    FROM unnest(v_derived) d
    WHERE NOT (d = ANY(v_covered));

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION
            'SECURITY DEFINER writers this suite does not cover: %. Add a case for each.',
            array_to_string(v_missing, ', ');
    END IF;
    IF coalesce(array_length(v_derived, 1), 0) = 0 THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: the pg_proc derivation found no SECURITY DEFINER writers at all';
    END IF;
END
$$;

DO $$
DECLARE
    v_role     text;
    v_sub      uuid := (SELECT v FROM wmw_fixture WHERE k = 'def_sub')::uuid;
    v_cand_a   uuid := (SELECT v FROM wmw_fixture WHERE k = 'def_cand_accept')::uuid;
    v_cand_r   uuid := (SELECT v FROM wmw_fixture WHERE k = 'def_cand_reject')::uuid;
    v_acc_o    uuid := (SELECT v FROM wmw_fixture WHERE k = 'def_acc_outcome')::uuid;
    v_gap      uuid := (SELECT v FROM wmw_fixture WHERE k = 'def_gap')::uuid;
    v_answer   uuid := (SELECT v FROM wmw_fixture WHERE k = 'def_answer')::uuid;
    v_kcand    uuid := (SELECT v FROM wmw_fixture WHERE k = 'def_kcand')::uuid;
    v_agent    uuid := (SELECT v FROM wmw_fixture WHERE k = 'def_agent')::uuid;
    v_pred     uuid := (SELECT v FROM wmw_fixture WHERE k = 'def_prediction')::uuid;
    v_n        integer;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['viewer', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION 'Role did not read back as "%"', v_role;
        END IF;

        BEGIN PERFORM accept_assertion(v_cand_a); EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN PERFORM reject_candidate(v_cand_r, 'who may write probe'); EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN PERFORM mark_assertion_outcome(v_acc_o, 'correct', '{}'::jsonb); EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN PERFORM resolve_knowledge_gap(v_gap, v_answer, 'test:who-may-write'); EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN
            PERFORM promote_candidate_node_to_assertion(
                p_candidate_id    := v_kcand,
                p_subject_node_id := v_sub,
                p_assertion_type  := 'wmw_probe',
                p_assertion_key   := 'def:promoted',
                p_claim           := '{"value":"promoted"}');
        EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN
            PERFORM agent_submit_observation(
                p_agent_id  := v_agent,
                p_statement := 'who may write observation');
        EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN
            PERFORM agent_create_candidate(
                p_agent_id       := v_agent,
                p_candidate_kind := 'decision',
                p_statement      := 'who may write candidate');
        EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN PERFORM score_due_predictions(); EXCEPTION WHEN OTHERS THEN NULL; END;

        -- Nothing moved. Checked as admin, so an invisible row cannot look
        -- like an unchanged one.
        PERFORM set_config('app.current_role', 'admin', true);

        IF (SELECT status FROM assertions WHERE id = v_cand_a) <> 'candidate' THEN
            RAISE EXCEPTION 'Role "%" accepted a candidate through accept_assertion()', v_role;
        END IF;
        IF (SELECT status FROM assertions WHERE id = v_cand_r) <> 'candidate'
           OR (SELECT superseded_at FROM assertions WHERE id = v_cand_r) IS NOT NULL THEN
            RAISE EXCEPTION 'Role "%" closed a candidate through reject_candidate()', v_role;
        END IF;
        IF (SELECT attrs ? 'outcome' FROM assertions WHERE id = v_acc_o) THEN
            RAISE EXCEPTION 'Role "%" labelled an outcome through mark_assertion_outcome()', v_role;
        END IF;
        IF (SELECT superseded_at FROM assertions WHERE id = v_gap) IS NOT NULL THEN
            RAISE EXCEPTION 'Role "%" closed a gap through resolve_knowledge_gap()', v_role;
        END IF;
        IF (SELECT archived_at FROM nodes WHERE id = v_kcand) IS NOT NULL THEN
            RAISE EXCEPTION 'Role "%" promoted a candidate node', v_role;
        END IF;
        SELECT count(*) INTO v_n FROM nodes
        WHERE properties->>'statement' = 'who may write observation';
        IF v_n <> 0 THEN
            RAISE EXCEPTION 'Role "%" left % observation nodes behind', v_role, v_n;
        END IF;
        SELECT count(*) INTO v_n FROM nodes
        WHERE node_type = 'knowledge_candidate'
          AND properties->>'statement' = 'who may write candidate';
        IF v_n <> 0 THEN
            RAISE EXCEPTION 'Role "%" left % agent candidate nodes behind', v_role, v_n;
        END IF;
        IF (SELECT attrs ? 'outcome' FROM assertions WHERE id = v_pred) THEN
            RAISE EXCEPTION 'Role "%" scored a prediction through score_due_predictions()', v_role;
        END IF;
    END LOOP;

    -- Anti-vacuity: the same calls, the same fixture, the same run, as admin.
    -- If any of these fails, the refusals above proved nothing.
    PERFORM set_config('app.current_role', 'admin', true);

    PERFORM accept_assertion(v_cand_a);
    IF (SELECT status FROM assertions WHERE id = v_cand_a) <> 'accepted' THEN
        RAISE EXCEPTION 'An admin could not accept the candidate';
    END IF;

    PERFORM reject_candidate(v_cand_r, 'who may write probe');
    IF (SELECT superseded_at FROM assertions WHERE id = v_cand_r) IS NULL THEN
        RAISE EXCEPTION 'An admin could not reject the candidate';
    END IF;

    PERFORM mark_assertion_outcome(v_acc_o, 'correct', '{}'::jsonb);
    IF NOT (SELECT attrs ? 'outcome' FROM assertions WHERE id = v_acc_o) THEN
        RAISE EXCEPTION 'An admin could not label an outcome';
    END IF;

    PERFORM resolve_knowledge_gap(v_gap, v_answer, 'test:who-may-write');
    IF (SELECT superseded_at FROM assertions WHERE id = v_gap) IS NULL THEN
        RAISE EXCEPTION 'An admin could not resolve the knowledge gap';
    END IF;

    PERFORM promote_candidate_node_to_assertion(
        p_candidate_id    := v_kcand,
        p_subject_node_id := v_sub,
        p_assertion_type  := 'wmw_probe',
        p_assertion_key   := 'def:promoted',
        p_claim           := '{"value":"promoted"}');
    IF (SELECT archived_at FROM nodes WHERE id = v_kcand) IS NULL THEN
        RAISE EXCEPTION 'An admin could not promote the candidate node';
    END IF;

    PERFORM agent_submit_observation(
        p_agent_id  := v_agent,
        p_statement := 'who may write observation');
    SELECT count(*) INTO v_n FROM nodes
    WHERE properties->>'statement' = 'who may write observation';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'An admin''s agent_submit_observation left % nodes, expected 1', v_n;
    END IF;

    PERFORM agent_create_candidate(
        p_agent_id       := v_agent,
        p_candidate_kind := 'decision',
        p_statement      := 'who may write candidate');
    SELECT count(*) INTO v_n FROM nodes
    WHERE node_type = 'knowledge_candidate'
      AND properties->>'statement' = 'who may write candidate';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'An admin''s agent_create_candidate left % nodes, expected 1', v_n;
    END IF;

    PERFORM score_due_predictions();
    IF NOT (SELECT attrs ? 'outcome' FROM assertions WHERE id = v_pred) THEN
        RAISE EXCEPTION 'An admin could not score the due prediction';
    END IF;
END
$$;

-- --------------------------------------------------------------------------
-- Obligation 12. The coverage tests 30 and 31 used to get from `viewer` and an
-- unset role, which can no longer write at all, as refusals asserted by effect.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_role    text;
    v_path    text;
    v_sub     uuid := (SELECT v FROM wmw_fixture WHERE k = 'def_sub')::uuid;
    v_acc_s   uuid := (SELECT v FROM wmw_fixture WHERE k = 'def_acc_supersede')::uuid;
    v_acc_f   uuid := (SELECT v FROM wmw_fixture WHERE k = 'def_acc_forge')::uuid;
    v_scope   uuid := (SELECT v FROM wmw_fixture WHERE k = 'scope')::uuid;
    v_before  assertions;
    v_after   assertions;
    v_n       integer;
    v_new     uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    SELECT * INTO v_before FROM assertions WHERE id = v_acc_f;

    FOREACH v_role IN ARRAY ARRAY['viewer', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION 'Role did not read back as "%"', v_role;
        END IF;

        BEGIN
            PERFORM supersede_assertion(
                v_acc_s, 'wmw_probe', v_sub, NULL, '{"value":"hijacked"}',
                p_new_assertion_key := 'def:supersede', p_new_basis := 'assumed');
        EXCEPTION WHEN OTHERS THEN NULL; END;

        BEGIN
            PERFORM schedule_assertion_change(
                p_subject_node_id := v_sub,
                p_subject_edge_id := NULL,
                p_assertion_type  := 'wmw_probe',
                p_assertion_key   := 'def:scheduled',
                p_claim           := '{"value":"later"}',
                p_effective_at    := now() + interval '1 day',
                p_basis           := 'assumed');
        EXCEPTION WHEN OTHERS THEN NULL; END;

        BEGIN
            PERFORM record_scope_policy(
                p_scope_id    := v_scope,
                p_policy_type := 'review_policy',
                p_claim       := '{"review_policy":"open"}');
        EXCEPTION WHEN OTHERS THEN NULL; END;

        -- The five forged write paths, each with its matching id setting. The
        -- update policy trusts them because any caller can set them; the role
        -- rule does not.
        FOREACH v_path IN ARRAY ARRAY[
            'accept_assertion', 'supersede_assertion', 'assertion_effective_window',
            'assertion_classification', 'assertion_outcome'
        ] LOOP
            BEGIN
                PERFORM set_config('app.write_path', v_path, true);
                PERFORM set_config('app.accept_assertion_id', v_acc_f::text, true);
                PERFORM set_config('app.supersede_assertion_id', v_acc_f::text, true);
                PERFORM set_config('app.effective_window_assertion_id', v_acc_f::text, true);
                PERFORM set_config('app.classification_assertion_id', v_acc_f::text, true);
                PERFORM set_config('app.outcome_assertion_id', v_acc_f::text, true);
                UPDATE assertions
                   SET status = 'candidate',
                       effective_to = now() + interval '1 day',
                       attrs = attrs || '{"forged":true}'::jsonb
                 WHERE id = v_acc_f;
            EXCEPTION WHEN OTHERS THEN NULL; END;
            PERFORM set_config('app.write_path', '', true);
        END LOOP;

        PERFORM set_config('app.current_role', 'admin', true);

        SELECT * INTO v_after FROM assertions WHERE id = v_acc_s;
        IF v_after.status <> 'accepted' OR v_after.superseded_at IS NOT NULL THEN
            RAISE EXCEPTION
                'Role "%" superseded the incumbent: status %, superseded_at %',
                v_role, v_after.status, v_after.superseded_at;
        END IF;

        SELECT count(*) INTO v_n FROM assertions WHERE assertion_key = 'def:scheduled';
        IF v_n <> 0 THEN
            RAISE EXCEPTION 'Role "%" left % scheduled assertions behind', v_role, v_n;
        END IF;

        IF scope_review_policy(v_scope) <> 'strict' THEN
            RAISE EXCEPTION
                'Role "%" relaxed the strict scope to % through record_scope_policy()',
                v_role, scope_review_policy(v_scope);
        END IF;

        SELECT * INTO v_after FROM assertions WHERE id = v_acc_f;
        IF v_after.status IS DISTINCT FROM v_before.status
           OR v_after.effective_to IS DISTINCT FROM v_before.effective_to
           OR v_after.attrs IS DISTINCT FROM v_before.attrs
           OR v_after.superseded_at IS DISTINCT FROM v_before.superseded_at
        THEN
            RAISE EXCEPTION
                'Role "%" changed the forge target: status % attrs %',
                v_role, v_after.status, v_after.attrs;
        END IF;
    END LOOP;

    -- Anti-vacuity: an admin still supersedes the same incumbent.
    PERFORM set_config('app.current_role', 'admin', true);
    v_new := supersede_assertion(
        v_acc_s, 'wmw_probe', v_sub, NULL, '{"value":"replaced by an admin"}',
        p_new_assertion_key := 'def:supersede', p_new_basis := 'assumed');
    IF v_new IS NULL THEN
        RAISE EXCEPTION 'An admin could not supersede the incumbent';
    END IF;
    IF (SELECT superseded_at FROM assertions WHERE id = v_acc_s) IS NULL THEN
        RAISE EXCEPTION 'An admin''s supersession left the incumbent standing';
    END IF;
END
$$;

-- --------------------------------------------------------------------------
-- Obligation 15. `system:cdc` can do strictly less than any other writing role.
-- It is the role capture_domain_change() swaps in around its record_event()
-- call, so it may insert an event and a participant, and nothing else anywhere.
-- A caller who sets it by hand therefore gains less than by setting
-- team_member, which any caller with a raw connection can already do.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_marsh    uuid := (SELECT v FROM wmw_fixture WHERE k = 'marsh')::uuid;
    v_scope    uuid := (SELECT v FROM wmw_fixture WHERE k = 'scope')::uuid;
    v_gov_edge uuid := (SELECT v FROM wmw_fixture WHERE k = 'gov_edge')::uuid;
    v_subject  uuid := (SELECT v FROM wmw_fixture WHERE k = 'subject')::uuid;
    v_assert   uuid := (SELECT v FROM wmw_fixture WHERE k = 'assertion')::uuid;
    v_artifact uuid := (SELECT v FROM wmw_fixture WHERE k = 'artifact')::uuid;
    v_event    uuid;
    v_ep       uuid;
    v_failed   boolean;
    v_state    text;
    v_msg      text;
    v_rows     integer;
BEGIN
    PERFORM set_config('app.current_role', 'system:cdc', true);
    IF current_setting('app.current_role', true) IS DISTINCT FROM 'system:cdc' THEN
        RAISE EXCEPTION 'Role did not read back as system:cdc';
    END IF;
    IF NOT rye_role_may_write() THEN
        RAISE EXCEPTION 'Refusing to pass vacuously: system:cdc is not in the role list as a writer';
    END IF;

    -- What it may do: one event and one participant.
    v_event := gen_random_uuid();
    INSERT INTO events (id, event_type, occurred_at, summary, properties, actor_system)
    VALUES (v_event, 'domain_change', now(), 'system:cdc probe',
            '{"suite":"who_may_write"}', 'system:cdc');
    INSERT INTO event_participants (event_id, node_id, role)
    VALUES (v_event, v_marsh, 'subject')
    RETURNING id INTO v_ep;

    -- And nothing else, anywhere.
    v_failed := false;
    BEGIN
        INSERT INTO nodes (node_type, label) VALUES ('person', 'cdc node');
    EXCEPTION WHEN OTHERS THEN v_failed := true; v_state := SQLSTATE; END;
    IF NOT v_failed OR v_state <> '42501' THEN
        RAISE EXCEPTION 'system:cdc inserted a node (failed=%, sqlstate=%)', v_failed, v_state;
    END IF;

    v_failed := false;
    BEGIN
        INSERT INTO edges (edge_type, source_id, target_id)
        VALUES ('knows', v_marsh, v_subject);
    EXCEPTION WHEN OTHERS THEN v_failed := true; v_state := SQLSTATE; END;
    IF NOT v_failed OR v_state <> '42501' THEN
        RAISE EXCEPTION 'system:cdc inserted an edge (failed=%, sqlstate=%)', v_failed, v_state;
    END IF;

    v_failed := false;
    BEGIN
        INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, status, basis)
        VALUES ('wmw_probe', 'cdc:refused', v_marsh, '{"value":"no"}', 'accepted', 'assumed');
    EXCEPTION WHEN OTHERS THEN v_failed := true; v_state := SQLSTATE; END;
    IF NOT v_failed OR v_state <> '42501' THEN
        RAISE EXCEPTION 'system:cdc inserted an assertion (failed=%, sqlstate=%)', v_failed, v_state;
    END IF;

    v_failed := false;
    BEGIN
        INSERT INTO assertion_evidence (assertion_id, kind, event_id)
        VALUES (v_assert, 'source', v_event);
    EXCEPTION WHEN OTHERS THEN v_failed := true; v_state := SQLSTATE; END;
    IF NOT v_failed OR v_state <> '42501' THEN
        RAISE EXCEPTION 'system:cdc inserted assertion evidence (failed=%, sqlstate=%)', v_failed, v_state;
    END IF;

    v_failed := false;
    BEGIN
        INSERT INTO artifacts (artifact_type, content) VALUES ('cdc', '{}'::jsonb);
    EXCEPTION WHEN OTHERS THEN v_failed := true; v_state := SQLSTATE; END;
    IF NOT v_failed OR v_state <> '42501' THEN
        RAISE EXCEPTION 'system:cdc inserted an artifact (failed=%, sqlstate=%)', v_failed, v_state;
    END IF;

    -- Update and delete on the two tables it may insert into. On an owner RLS
    -- binds these are filtered to zero rows; on a superuser owner the trigger
    -- raises. Both are refusals, so the row is what is asserted.
    v_rows := 0;
    BEGIN
        UPDATE event_participants SET role = 'hijacked' WHERE id = v_ep;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN v_rows := 0; END;
    IF v_rows <> 0 OR (SELECT role FROM event_participants WHERE id = v_ep) = 'hijacked' THEN
        RAISE EXCEPTION 'system:cdc updated an event participant';
    END IF;

    v_rows := 0;
    BEGIN
        DELETE FROM event_participants WHERE id = v_ep;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN v_rows := 0; END;
    IF v_rows <> 0 OR NOT EXISTS (SELECT 1 FROM event_participants WHERE id = v_ep) THEN
        RAISE EXCEPTION 'system:cdc deleted an event participant';
    END IF;

    v_rows := 0;
    BEGIN
        UPDATE events SET summary = 'hijacked' WHERE id = v_event;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN v_rows := 0; END;
    IF v_rows <> 0 OR (SELECT summary FROM events WHERE id = v_event) = 'hijacked' THEN
        RAISE EXCEPTION 'system:cdc updated an event';
    END IF;

    v_rows := 0;
    BEGIN
        DELETE FROM events WHERE id = v_event;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN v_rows := 0; END;
    IF v_rows <> 0 OR NOT EXISTS (SELECT 1 FROM events WHERE id = v_event) THEN
        RAISE EXCEPTION 'system:cdc deleted an event';
    END IF;

    -- The governance structure, which is admin-only and therefore excludes it.
    v_rows := 0;
    BEGIN
        UPDATE nodes SET archived_at = now() WHERE id = v_scope;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN v_rows := 0; END;
    IF v_rows <> 0 OR (SELECT archived_at FROM nodes WHERE id = v_scope) IS NOT NULL THEN
        RAISE EXCEPTION 'system:cdc archived the scope node';
    END IF;

    v_rows := 0;
    BEGIN
        DELETE FROM edges WHERE id = v_gov_edge;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN v_rows := 0; END;
    IF v_rows <> 0 OR NOT EXISTS (SELECT 1 FROM edges WHERE id = v_gov_edge) THEN
        RAISE EXCEPTION 'system:cdc deleted the governance edge';
    END IF;

    -- Artifacts it did not write, for completeness of "every operation".
    v_rows := 0;
    BEGIN
        UPDATE artifacts SET content = '{"hijacked":true}' WHERE id = v_artifact;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN v_rows := 0; END;
    IF v_rows <> 0 OR (SELECT content->>'hijacked' FROM artifacts WHERE id = v_artifact) IS NOT NULL THEN
        RAISE EXCEPTION 'system:cdc rewrote an artifact';
    END IF;

    -- And merge_nodes() names it.
    v_failed := false;
    BEGIN
        PERFORM merge_nodes(v_marsh, v_subject);
    EXCEPTION WHEN OTHERS THEN
        v_failed := true; v_state := SQLSTATE; v_msg := SQLERRM;
    END;
    IF NOT v_failed
       OR v_state <> '42501'
       OR v_msg NOT LIKE '%merge_nodes is not available to system:cdc%'
       OR v_msg LIKE '%not found%'
    THEN
        RAISE EXCEPTION 'system:cdc merge refusal was sqlstate % message "%"', v_state, v_msg;
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
END
$$;

-- --------------------------------------------------------------------------
-- Obligation 16. node_source_map follows the same rule as the core tables.
--
-- A mapping decides which node a tracked table's change events attach to. With
-- `nsm_insert_policy` at WITH CHECK (true) a viewer could map a source id of
-- its choosing onto a node of its choosing and have CDC record its own text
-- against that node, and with `nsm_update_policy` asking only that the node be
-- visible it could re-point an operator's mapping so a real table's future
-- events landed elsewhere. Both are writes, not bookkeeping.
--
-- The raw mapping writes are asserted here, under both owner types. The CDC
-- consequence -- that no event attaches to the viewer's node afterwards -- is
-- asserted in tests/conformance/07_domain_integration.sh, which runs as the
-- connection's own user and can therefore create and track a domain table;
-- this suite runs as a test role with no CREATE on public.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_role    text;
    v_wren    uuid := (SELECT v FROM wmw_fixture WHERE k = 'wren')::uuid;
    v_marsh   uuid := (SELECT v FROM wmw_fixture WHERE k = 'marsh')::uuid;
    v_tobin   uuid := (SELECT v FROM wmw_fixture WHERE k = 'tobin')::uuid;
    v_failed  boolean;
    v_state   text;
    v_rows    integer;
    v_n       integer;
BEGIN
    -- An operator's honest mapping, on source id 501.
    PERFORM set_config('app.current_role', 'admin', true);
    INSERT INTO node_source_map (node_id, source_schema, source_table, source_id)
    VALUES (v_wren, 'wmw', 'probe', '501');

    FOREACH v_role IN ARRAY ARRAY['viewer', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION 'Role did not read back as "%"', v_role;
        END IF;

        -- The mapping has to be visible, or the zero below is a zero for the
        -- wrong reason.
        SELECT count(*) INTO v_n FROM node_source_map
        WHERE source_schema = 'wmw' AND source_table = 'probe' AND source_id = '501';
        IF v_n <> 1 THEN
            RAISE EXCEPTION 'Role "%" cannot see the operator mapping', v_role;
        END IF;

        -- Reproduction 1: map a source id onto a node of its choosing.
        v_failed := false;
        BEGIN
            INSERT INTO node_source_map (node_id, source_schema, source_table, source_id)
            VALUES (v_marsh, 'wmw', 'probe', '604');
        EXCEPTION WHEN OTHERS THEN v_failed := true; v_state := SQLSTATE; END;
        IF NOT v_failed OR v_state <> '42501' THEN
            RAISE EXCEPTION
                'Role "%" inserted a source mapping (failed=%, sqlstate=%)', v_role, v_failed, v_state;
        END IF;
        PERFORM set_config('app.current_role', 'admin', true);
        SELECT count(*) INTO v_n FROM node_source_map
        WHERE source_schema = 'wmw' AND source_table = 'probe' AND source_id = '604';
        IF v_n <> 0 THEN
            RAISE EXCEPTION 'Role "%" left a source mapping behind', v_role;
        END IF;
        PERFORM set_config('app.current_role', v_role, true);

        -- Reproduction 2: re-point the operator's mapping.
        v_rows := 0;
        BEGIN
            UPDATE node_source_map SET node_id = v_marsh
            WHERE source_schema = 'wmw' AND source_table = 'probe' AND source_id = '501';
            GET DIAGNOSTICS v_rows = ROW_COUNT;
        EXCEPTION WHEN OTHERS THEN v_rows := 0; END;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" re-pointed % source mappings', v_role, v_rows;
        END IF;

        v_rows := 0;
        BEGIN
            DELETE FROM node_source_map
            WHERE source_schema = 'wmw' AND source_table = 'probe' AND source_id = '501';
            GET DIAGNOSTICS v_rows = ROW_COUNT;
        EXCEPTION WHEN OTHERS THEN v_rows := 0; END;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" deleted % source mappings', v_role, v_rows;
        END IF;

        PERFORM set_config('app.current_role', 'admin', true);
        SELECT count(*) INTO v_n FROM node_source_map
        WHERE source_schema = 'wmw' AND source_table = 'probe'
          AND source_id = '501' AND node_id = v_wren;
        IF v_n <> 1 THEN
            RAISE EXCEPTION 'Role "%" changed or removed the operator mapping', v_role;
        END IF;
    END LOOP;

    -- Anti-vacuity: the roles that may write still can. link_record() is the
    -- ordinary route, and a re-point is the raw one.
    PERFORM set_config('app.current_role', 'team_member', true);
    PERFORM link_record(
        p_source_schema := 'wmw',
        p_source_table  := 'probe',
        p_source_id     := '700',
        p_node_type     := 'product',
        p_label         := 'Team member link');
    SELECT count(*) INTO v_n FROM node_source_map
    WHERE source_schema = 'wmw' AND source_table = 'probe' AND source_id = '700';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'A team_member could not link a record';
    END IF;

    UPDATE node_source_map SET node_id = v_tobin
    WHERE source_schema = 'wmw' AND source_table = 'probe' AND source_id = '501';
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'A team_member could not re-point a mapping (% rows)', v_rows;
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM link_record(
        p_source_schema := 'wmw',
        p_source_table  := 'probe',
        p_source_id     := '701',
        p_node_type     := 'product',
        p_label         := 'Admin link');
    SELECT count(*) INTO v_n FROM node_source_map
    WHERE source_schema = 'wmw' AND source_table = 'probe' AND source_id = '701';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'An admin could not link a record';
    END IF;
END
$$;

DO $$
BEGIN
    RAISE NOTICE 'Who may write: all obligations passed';
END
$$;

ROLLBACK;
