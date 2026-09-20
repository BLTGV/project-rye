-- Leftovers fail restrictive.
--
-- Work item: work/018-session-leftovers.md, the schema criteria.
-- Contract:  contracts/sql-surface.md, "Configuration writes need an admin"
--            (the written-name settle gate) and "An unsupported policy value
--            is strict, and cannot be recorded";
--            contracts/category-vocabulary.md, "Describing a category, twice,
--            as an agent".
-- Decision:  docs/decisions/0013-leftovers-fail-restrictive.md, obligations
--            42.1 to 42.8. 42.9 is a CLI obligation and lives in
--            tests/conformance/16_cli_smoke.sh, beside the other CLI tests.
-- Migration: schema/migrations/0036_leftovers_fail_restrictive.sql.
--
-- Negative control: build a tree with scripts/migrate.sh up to 0030 only (not
-- install.sh -- verify.sh requires 0036's objects) and this suite fails at the
-- first case, because review_policy_claim_value() does not exist and because
-- the trigger this file disables and re-enables is not there to disable.
--
-- HOW THE BROKEN ROWS ARE SEEDED, stated rather than hidden. Obligation 42.4
-- needs a review_policy row that 0036's guard would refuse, standing in the
-- table -- the row an instance upgraded from an earlier tree already holds.
-- There is no honest way to write one through a helper, and the conformance
-- role is not the table owner, so the file drops to the table owner for
-- exactly three statements (RESET ROLE, ALTER TABLE ... DISABLE TRIGGER, the
-- inserts, ENABLE TRIGGER, SET ROLE back) and then asserts, under the suite
-- role again, that the trigger is enabled and that the anti-vacuity premises
-- still hold. Under scripts/conformance.sh the suite role is rye_conformance
-- and RESET ROLE lands on the superuser owner; under
-- scripts/test-nonsuperuser-owner.sh there is no SET ROLE and RESET ROLE is a
-- no-op on the non-superuser owner. Both work, and both are visible here.
--
-- Invented names only. Fixed uuids, because the transaction rolls back.

SET search_path = rye, public, pg_catalog;

SELECT current_user AS suite_role \gset

BEGIN;

-- --------------------------------------------------------------------------
-- Anti-vacuity, as tests 30 to 39 do it.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_bypass boolean;
    v_core   uuid;
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
    PERFORM set_config('app.current_user_id', 'test:leftovers', true);
    PERFORM set_config('app.current_teams', '', true);

    SELECT id INTO v_core
    FROM nodes
    WHERE external_source = 'rye_registry' AND external_id = 'core' AND archived_at IS NULL;
    IF v_core IS NULL THEN
        RAISE EXCEPTION 'Core registry node is missing; the install seeds did not run';
    END IF;

    v_probe := record_assertion(
        'compensation', '{"value":"rls probe"}', v_core,
        p_assertion_key := 'leftovers:rls_probe', p_basis := 'assumed'
    );
    PERFORM set_config('app.current_role', 'viewer', true);
    SELECT count(*) INTO v_seen FROM assertions WHERE id = v_probe;
    IF v_seen <> 0 THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: a viewer can read a read-gated assertion type, so RLS is not in force';
    END IF;
    PERFORM set_config('app.current_role', 'admin', true);

    -- The premise of every case below.
    IF to_regprocedure('rye.review_policy_claim_value(jsonb)') IS NULL
       OR to_regprocedure('rye.review_policy_value_supported(jsonb)') IS NULL
       OR to_regprocedure('rye.assertion_review_policy_value_guard()') IS NULL
    THEN
        RAISE EXCEPTION 'Migration 0036 is not applied: its functions are missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'rye' AND c.relname = 'assertions'
          AND t.tgname = 'trg_assertions_review_policy_value'
          AND NOT t.tgisinternal
    ) THEN
        RAISE EXCEPTION 'trg_assertions_review_policy_value is missing from assertions';
    END IF;
END
$$;

-- --------------------------------------------------------------------------
-- Fixtures. Fixed uuids so the seeding step below can name them in plain SQL.
-- --------------------------------------------------------------------------
SELECT set_config('app.current_role', 'admin', true);
SELECT set_config('app.current_user_id', 'test:leftovers', true);
SELECT set_config('app.current_teams', '', true);

DO $$
DECLARE
    v_bad_value  uuid := '42000001-0000-4000-8000-000000000001';
    v_wrong_key  uuid := '42000001-0000-4000-8000-000000000002';
    v_json_null  uuid := '42000001-0000-4000-8000-000000000003';
    v_absent     uuid := '42000001-0000-4000-8000-000000000004';
    v_good       uuid := '42000001-0000-4000-8000-000000000005';
    v_id         uuid;
BEGIN
    FOREACH v_id IN ARRAY ARRAY[v_bad_value, v_wrong_key, v_json_null, v_absent, v_good] LOOP
        INSERT INTO nodes (id, node_type, label)
        VALUES (v_id, 'onboarding_scope', 'Leftovers scope ' || right(v_id::text, 1));
        PERFORM record_assertion('scope_status', '{"status":"active"}', v_id, p_basis := 'assumed');
    END LOOP;

    -- The control: a supported value, recorded the ordinary way.
    PERFORM record_assertion('review_policy', '{"review_policy":"strict"}', v_good,
                             p_basis := 'assumed');

    -- The subject the broken scope governs.
    INSERT INTO nodes (id, node_type, label)
    VALUES ('42000002-0000-4000-8000-000000000001', 'thing', 'Leftovers governed subject');
    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('scope_governs_subject', v_bad_value, '42000002-0000-4000-8000-000000000001');
END
$$;

-- --------------------------------------------------------------------------
-- The seeding step. Three rows an instance upgraded from an earlier tree can
-- already hold, and which 0036 refuses to create: an unsupported value, a claim
-- under the wrong key, and a JSON null. Written as the table owner with the new
-- guard disabled, because there is no other honest way to produce them.
-- --------------------------------------------------------------------------
-- ALTER TABLE refuses while the transaction holds pending deferred trigger
-- events, and every assertion written above leaves some. Flushing them and
-- restoring the deferral is the only way to reach the table, and it is also
-- the check that the fixtures above are themselves sound.
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

RESET ROLE;
ALTER TABLE rye.assertions DISABLE TRIGGER trg_assertions_review_policy_value;

INSERT INTO rye.assertions
    (assertion_type, assertion_key, status, basis, subject_node_id, claim)
VALUES
    ('review_policy', 'default', 'accepted', 'assumed',
     '42000001-0000-4000-8000-000000000001', '{"review_policy":"srtict"}'),
    ('review_policy', 'default', 'accepted', 'assumed',
     '42000001-0000-4000-8000-000000000002', '{"policy":"candidates_only"}'),
    ('review_policy', 'default', 'accepted', 'assumed',
     '42000001-0000-4000-8000-000000000003', '{"review_policy":null}');

SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

ALTER TABLE rye.assertions ENABLE TRIGGER trg_assertions_review_policy_value;
SET ROLE :"suite_role";

-- The escape is closed again, and the suite is bound by RLS again.
DO $$
DECLARE
    v_bypass boolean;
    v_state  "char";
    v_super  boolean;
BEGIN
    SELECT rolsuper, rolbypassrls INTO v_super, v_bypass
    FROM pg_roles WHERE rolname = current_user;
    IF coalesce(v_super, false) OR coalesce(v_bypass, false) THEN
        RAISE EXCEPTION
            'The seeding step left the suite running as %, which is not bound by RLS', current_user;
    END IF;

    SELECT t.tgenabled INTO v_state
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'rye' AND c.relname = 'assertions'
      AND t.tgname = 'trg_assertions_review_policy_value';
    IF v_state IS DISTINCT FROM 'O' THEN
        RAISE EXCEPTION
            'The seeding step left trg_assertions_review_policy_value in state "%", not "O"', v_state;
    END IF;
END
$$;

-- ==========================================================================
-- 42.4  A broken policy value is strict, not an error.
-- ==========================================================================
DO $$
DECLARE
    v_absent    uuid := '42000001-0000-4000-8000-000000000004';
    v_bad_value uuid := '42000001-0000-4000-8000-000000000001';
    v_good      uuid := '42000001-0000-4000-8000-000000000005';
    v_id        uuid;
    v_json_null uuid := '42000001-0000-4000-8000-000000000003';
    v_row       assertions;
    v_scope     uuid;
    v_subject   uuid := '42000002-0000-4000-8000-000000000001';
    v_wrong_key uuid := '42000001-0000-4000-8000-000000000002';
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    -- Anti-vacuity: the seeded rows are there, still carrying what was written.
    IF (SELECT count(*) FROM current_valid_assertions
        WHERE assertion_type = 'review_policy'
          AND subject_node_id IN (v_bad_value, v_wrong_key, v_json_null)) <> 3
    THEN
        RAISE EXCEPTION 'Premise broken: the three seeded review_policy rows are not all live';
    END IF;
    IF (SELECT claim FROM current_valid_assertions
        WHERE assertion_type = 'review_policy' AND subject_node_id = v_bad_value)
       <> '{"review_policy":"srtict"}'::jsonb
    THEN
        RAISE EXCEPTION 'Premise broken: the seeded broken value is not the value that was written';
    END IF;

    -- Reading: broken is strict and ranks strictest; absent is still open.
    FOREACH v_scope IN ARRAY ARRAY[v_bad_value, v_wrong_key, v_json_null] LOOP
        IF scope_review_policy(v_scope) <> 'strict' THEN
            RAISE EXCEPTION
                'Scope % with a broken review_policy reads %, not strict',
                v_scope, scope_review_policy(v_scope);
        END IF;
        IF scope_review_policy_rank(v_scope) <> 0 THEN
            RAISE EXCEPTION
                'Scope % with a broken review_policy ranks %, not 0',
                v_scope, scope_review_policy_rank(v_scope);
        END IF;
    END LOOP;

    IF scope_review_policy(v_absent) <> 'open' OR scope_review_policy_rank(v_absent) <> 2 THEN
        RAISE EXCEPTION
            'A scope with NO review_policy row reads %/% instead of open/2: absent is not broken',
            scope_review_policy(v_absent), scope_review_policy_rank(v_absent);
    END IF;
    IF scope_review_policy(NULL) <> 'open' OR scope_review_policy_rank(NULL) <> 2 THEN
        RAISE EXCEPTION 'A null scope no longer reads open/2';
    END IF;
    IF scope_review_policy(v_good) <> 'strict' OR scope_review_policy_rank(v_good) <> 0 THEN
        RAISE EXCEPTION 'Premise broken: the control scope does not read strict';
    END IF;

    -- Writing a governed subject is careful, not refused.
    PERFORM set_config('app.current_role', 'team_member', true);
    IF governing_scope(v_subject, NULL, 'leftover_probe', NULL) IS DISTINCT FROM v_bad_value THEN
        RAISE EXCEPTION
            'Premise broken: the subject resolves to %, not the broken scope',
            governing_scope(v_subject, NULL, 'leftover_probe', NULL);
    END IF;
    IF effective_review_policy(v_subject, NULL, 'leftover_probe', NULL) <> 'strict' THEN
        RAISE EXCEPTION
            'effective_review_policy on a broken scope is %, not strict',
            effective_review_policy(v_subject, NULL, 'leftover_probe', NULL);
    END IF;

    v_id := record_assertion(
        'leftover_probe', '{"value":"written under a broken policy"}', v_subject,
        p_assertion_key := 'default', p_basis := 'assumed'
    );
    SELECT * INTO v_row FROM assertions WHERE id = v_id;
    IF v_row.status <> 'candidate' THEN
        RAISE EXCEPTION
            'A write under a broken review policy landed %, not candidate', v_row.status;
    END IF;
    IF v_row.attrs->'review_gate'->>'review_policy' IS DISTINCT FROM 'strict' THEN
        RAISE EXCEPTION
            'A write under a broken review policy carries review_gate %', v_row.attrs->'review_gate';
    END IF;

    -- Anti-vacuity: the stored claim is still the broken value, so nothing
    -- quietly repaired it.
    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT claim FROM current_valid_assertions
        WHERE assertion_type = 'review_policy' AND subject_node_id = v_bad_value)
       <> '{"review_policy":"srtict"}'::jsonb
    THEN
        RAISE EXCEPTION 'The broken review_policy row was rewritten; no migration may do that';
    END IF;
END
$$;

-- ==========================================================================
-- 42.5  An unsupported value cannot be recorded.
-- ==========================================================================
DO $$
DECLARE
    v_bad      jsonb := '{"review_policy":"bogus_policy_value"}';
    v_claim    jsonb;
    v_failed   boolean;
    v_good     uuid := '42000001-0000-4000-8000-000000000005';
    v_id       uuid;
    v_msg      text;
    v_ok       uuid := '42000003-0000-4000-8000-000000000001';
    v_role     text;
    v_rows     integer;
    v_shape    jsonb;
    v_status   text;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    INSERT INTO nodes (id, node_type, label)
    VALUES (v_ok, 'onboarding_scope', 'Leftovers control scope');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_ok, p_basis := 'assumed');

    -- record_scope_policy() refuses, for every unreadable shape as well as for
    -- an unsupported value.
    FOREACH v_shape IN ARRAY ARRAY[
        v_bad,
        '{"policy":"strict"}'::jsonb,
        '{"review_policy":null}'::jsonb,
        '{}'::jsonb,
        '"not_a_policy"'::jsonb
    ] LOOP
        v_failed := false;
        BEGIN
            PERFORM record_scope_policy(
                p_scope_id := v_ok, p_policy_type := 'review_policy', p_claim := v_shape
            );
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'record_scope_policy accepted the review_policy claim %', v_shape;
        END IF;
        IF v_msg NOT LIKE 'Unsupported review_policy%' THEN
            RAISE EXCEPTION 'record_scope_policy refused % for the wrong reason: %', v_shape, v_msg;
        END IF;
    END LOOP;

    -- Anti-vacuity: the same call with a supported value succeeds.
    v_id := record_scope_policy(
        p_scope_id := v_ok, p_policy_type := 'review_policy',
        p_claim := '{"review_policy":"candidates_only"}'
    );
    IF (SELECT status FROM assertions WHERE id = v_id) <> 'accepted' THEN
        RAISE EXCEPTION 'Premise broken: a supported review_policy did not land accepted as admin';
    END IF;
    IF scope_review_policy(v_ok) <> 'candidates_only' THEN
        RAISE EXCEPTION 'Premise broken: the control scope reads %', scope_review_policy(v_ok);
    END IF;

    -- The row is the gate: a direct INSERT is refused at every status for every
    -- role. The message is pinned only where this guard is the first refusal a
    -- caller meets; where the settle gate refuses first, both are refusals.
    FOREACH v_role IN ARRAY ARRAY['admin', 'team_member', 'agent:t', 'viewer', ''] LOOP
        FOREACH v_status IN ARRAY ARRAY['accepted', 'candidate'] LOOP
            PERFORM set_config('app.current_role', v_role, true);
            v_failed := false;
            BEGIN
                INSERT INTO assertions
                    (assertion_type, assertion_key, status, basis, subject_node_id, claim)
                VALUES ('review_policy', 'leftover_control', v_status, 'assumed', v_ok, v_bad);
            EXCEPTION WHEN OTHERS THEN
                v_failed := true;
                v_msg := SQLERRM;
            END;
            IF NOT v_failed THEN
                RAISE EXCEPTION
                    'Role "%" inserted an unsupported review_policy directly at status %',
                    v_role, v_status;
            END IF;
            IF v_role = 'admin' AND v_msg NOT LIKE 'Unsupported review_policy%' THEN
                RAISE EXCEPTION
                    'An admin was refused the % insert for the wrong reason: %', v_status, v_msg;
            END IF;
            IF v_role = 'team_member' AND v_status = 'candidate'
               AND v_msg NOT LIKE 'Unsupported review_policy%'
            THEN
                RAISE EXCEPTION
                    'A team_member was refused the candidate insert for the wrong reason: %', v_msg;
            END IF;
        END LOOP;
    END LOOP;

    -- Anti-vacuity: the same shape with a supported value lands, at both
    -- statuses, so the refusal above is about the value and not about the row.
    PERFORM set_config('app.current_role', 'admin', true);
    INSERT INTO assertions
        (assertion_type, assertion_key, status, basis, subject_node_id, claim)
    VALUES ('review_policy', 'leftover_control', 'accepted', 'assumed', v_ok,
            '{"review_policy":"strict"}');
    INSERT INTO assertions
        (assertion_type, assertion_key, status, basis, subject_node_id, claim)
    VALUES ('review_policy', 'leftover_control_two', 'candidate', 'assumed', v_ok,
            '{"value":"open"}');

    -- An UPDATE that rewrites a good value into a bad one raises or affects
    -- zero rows, and the claim is unchanged either way.
    SELECT id INTO v_id FROM assertions
    WHERE subject_node_id = v_ok AND assertion_type = 'review_policy'
      AND assertion_key = 'leftover_control' AND status = 'accepted';

    v_failed := false;
    BEGIN
        UPDATE assertions SET claim = v_bad WHERE id = v_id;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        v_rows := 0;
    END;
    IF NOT v_failed AND v_rows <> 0 THEN
        RAISE EXCEPTION 'An unforged UPDATE rewrote a review_policy claim: % rows', v_rows;
    END IF;

    -- The same UPDATE with the write path forged, which is the shape a caller
    -- can always produce, so the refusal must not depend on the policy alone.
    PERFORM set_config('app.write_path', 'accept_assertion', true);
    PERFORM set_config('app.accept_assertion_id', v_id::text, true);
    v_failed := false;
    v_rows := 0;
    BEGIN
        UPDATE assertions SET claim = v_bad WHERE id = v_id;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
    END;
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.accept_assertion_id', '', true);
    IF NOT v_failed AND v_rows <> 0 THEN
        RAISE EXCEPTION 'A forged UPDATE rewrote a review_policy claim: % rows', v_rows;
    END IF;

    SELECT claim INTO v_claim FROM assertions WHERE id = v_id;
    IF v_claim <> '{"review_policy":"strict"}'::jsonb THEN
        RAISE EXCEPTION 'The review_policy claim is now %', v_claim;
    END IF;

    -- Nothing with the bad value exists anywhere afterwards.
    SELECT count(*) INTO v_rows
    FROM assertions
    WHERE assertion_type = 'review_policy'
      AND review_policy_claim_value(claim) = 'bogus_policy_value';
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'An unsupported review_policy value survived: % rows', v_rows;
    END IF;

    -- A standing broken row can still be repaired: superseding it, which is an
    -- UPDATE of the incumbent with the claim untouched, is not refused.
    PERFORM set_config('app.current_role', 'admin', true);
    v_id := record_scope_policy(
        p_scope_id := '42000001-0000-4000-8000-000000000001',
        p_policy_type := 'review_policy',
        p_claim := '{"review_policy":"open"}'
    );
    IF (SELECT status FROM assertions WHERE id = v_id) <> 'accepted' THEN
        RAISE EXCEPTION
            'An admin could not repair a scope carrying a broken review_policy: status %',
            (SELECT status FROM assertions WHERE id = v_id);
    END IF;
    IF scope_review_policy('42000001-0000-4000-8000-000000000001') <> 'open' THEN
        RAISE EXCEPTION 'The repaired scope reads %',
            scope_review_policy('42000001-0000-4000-8000-000000000001');
    END IF;
END
$$;

-- ==========================================================================
-- 42.6  A repeat description works for an agent.
-- ==========================================================================
DO $$
DECLARE
    v_cat     uuid;
    v_cat_two uuid;
    v_failed  boolean;
    v_first   uuid;
    v_rows    integer;
    v_second  uuid;
    v_seen    timestamptz;
    v_third   uuid;
BEGIN
    -- A viewer is refused on the first call and on the second: the write gate
    -- one layer below is untouched by the named write path.
    PERFORM set_config('app.current_role', 'viewer', true);
    FOR v_rows IN 1..2 LOOP
        v_failed := false;
        BEGIN
            PERFORM describe_category('leftover_widget', 'A widget, as a viewer would put it.');
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'A viewer described a category on attempt %', v_rows;
        END IF;
    END LOOP;

    PERFORM set_config('app.current_role', 'agent:leftovers', true);
    PERFORM set_config('app.write_path', '', true);

    v_first := describe_category('leftover_widget', 'A widget as this instance means it.');
    SELECT subject_node_id INTO v_cat FROM assertions WHERE id = v_first;
    IF v_cat IS NULL THEN
        RAISE EXCEPTION 'The first describe_category as an agent created no category node';
    END IF;
    IF coalesce(current_setting('app.write_path', true), '') <> '' THEN
        RAISE EXCEPTION
            'describe_category left app.write_path set to "%"',
            current_setting('app.write_path', true);
    END IF;

    -- The second call is the one that used to fail: it is an UPDATE of an
    -- existing node, and an agent may only update through the named gate.
    v_second := describe_category('leftover_widget', 'A widget, said again and better.');
    SELECT subject_node_id INTO v_cat_two FROM assertions WHERE id = v_second;
    IF v_cat_two IS DISTINCT FROM v_cat THEN
        RAISE EXCEPTION
            'The second describe_category used node % rather than the existing %', v_cat_two, v_cat;
    END IF;
    IF v_second = v_first THEN
        RAISE EXCEPTION 'The second describe_category returned the first assertion';
    END IF;
    IF coalesce(current_setting('app.write_path', true), '') <> '' THEN
        RAISE EXCEPTION
            'describe_category left app.write_path set to "%" after the repeat call',
            current_setting('app.write_path', true);
    END IF;
    SELECT count(*) INTO v_rows
    FROM nodes WHERE external_source = 'rye_category' AND external_id = 'leftover_widget'
      AND archived_at IS NULL;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'A repeat description left % category nodes, not 1', v_rows;
    END IF;

    -- Anti-vacuity: the upsert really took the DO UPDATE branch.
    --
    -- The obligation was written as "updated_at advanced", which cannot be
    -- observed here: trg_nodes_touch_updated_at sets updated_at = now() on
    -- every UPDATE, and now() is frozen inside a transaction, so the column
    -- reads the same value however the row got there. What proves the same
    -- thing is the properties merge: an admin empties the category node's
    -- properties, and the next description as an agent puts them back on the
    -- SAME node, with still exactly one category node for the type. An INSERT
    -- would have left two nodes; a no-op would have left properties empty.
    PERFORM set_config('app.current_role', 'admin', true);
    UPDATE nodes SET properties = '{}'::jsonb WHERE id = v_cat;
    IF (SELECT properties FROM nodes WHERE id = v_cat) <> '{}'::jsonb THEN
        RAISE EXCEPTION 'Premise broken: the category node properties were not emptied';
    END IF;

    PERFORM set_config('app.current_role', 'agent:leftovers', true);
    v_third := describe_category('leftover_widget', 'A widget, a third time.');
    IF (SELECT properties->>'node_type' FROM nodes WHERE id = v_cat)
       IS DISTINCT FROM 'leftover_widget'
    THEN
        RAISE EXCEPTION
            'The category node properties were not restored, so the upsert never updated it: %',
            (SELECT properties FROM nodes WHERE id = v_cat);
    END IF;
    SELECT count(*) INTO v_rows
    FROM nodes WHERE external_source = 'rye_category' AND external_id = 'leftover_widget'
      AND archived_at IS NULL;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'A third description left % category nodes, not 1', v_rows;
    END IF;

    -- Anti-vacuity: the same caller, doing the function's own statement
    -- without the gate the function opens, is still refused.
    v_failed := false;
    v_rows := 0;
    BEGIN
        INSERT INTO nodes (node_type, label, external_id, external_source, properties)
        VALUES ('category', 'leftover_widget', 'leftover_widget', 'rye_category',
                jsonb_build_object('forged', true))
        ON CONFLICT (external_source, external_id)
            WHERE external_id IS NOT NULL AND archived_at IS NULL
        DO UPDATE SET properties = nodes.properties || EXCLUDED.properties;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
    END;
    IF NOT v_failed AND v_rows <> 0 THEN
        RAISE EXCEPTION
            'An agent upserted the category node without the named gate: % rows', v_rows;
    END IF;
    IF (SELECT properties ? 'forged' FROM nodes WHERE id = v_cat) THEN
        RAISE EXCEPTION 'An agent rewrote the category node properties without the named gate';
    END IF;

    v_failed := false;
    v_rows := 0;
    BEGIN
        UPDATE nodes SET label = 'forged' WHERE id = v_cat;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
    END;
    IF NOT v_failed AND v_rows <> 0 THEN
        RAISE EXCEPTION
            'An agent updated the category node without the named gate: % rows', v_rows;
    END IF;
    IF (SELECT label FROM nodes WHERE id = v_cat) = 'forged' THEN
        RAISE EXCEPTION 'An agent rewrote the category node label without the named gate';
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
END
$$;

-- ==========================================================================
-- 42.7  Expired and inactive grants reach nothing.
-- 42.8  The instance-wide predicate is pinned from outside.
--
-- Both obligations are about one row filter with one source:
-- authenticate_agent_token()'s grant subquery. The Worker's capability tests
-- (admin/src/server/worker.ts) read only the array it returns, so what is
-- pinned here is the array. The HTTP half of 42.7 and 42.8 lives in
-- tests/conformance/21_api_security.sh, which the admin area owns.
-- ==========================================================================
DO $$
DECLARE
    v_area      uuid;
    v_caps      jsonb;
    v_grant     uuid;
    v_token     text;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    v_area := ensure_knowledge_domain(
        'leftover_area', 'Leftover area', 'An area, for the grant filter.'
    );
    PERFORM create_agent_identity('leftover_agent', 'Leftover agent', 'test');
    v_token := issue_agent_token('leftover_agent', 'leftovers');

    -- No grants yet: the array is empty, which is the baseline every case below
    -- is measured against.
    v_caps := authenticate_agent_token(v_token)->'capabilities';
    IF v_caps IS DISTINCT FROM '[]'::jsonb THEN
        RAISE EXCEPTION 'Premise broken: a grant-less agent authenticates with %', v_caps;
    END IF;

    -- 42.7a An expired grant is not in the array.
    v_grant := grant_agent_capability(
        'leftover_agent', 'rye.domain.admin', 'leftover_area',
        p_expires_at := now() - interval '1 hour'
    );
    v_caps := authenticate_agent_token(v_token)->'capabilities';
    IF v_caps @> '[{"capability":"rye.domain.admin"}]'::jsonb THEN
        RAISE EXCEPTION 'An expired rye.domain.admin grant is in the capability array: %', v_caps;
    END IF;

    -- Anti-vacuity: the same grant unexpired IS in the array, so the filter is
    -- about expiry and not about the grant.
    UPDATE agent_capability_grants SET expires_at = now() + interval '1 hour'
    WHERE id = v_grant;
    v_caps := authenticate_agent_token(v_token)->'capabilities';
    IF NOT (v_caps @> '[{"capability":"rye.domain.admin"}]'::jsonb) THEN
        RAISE EXCEPTION 'An unexpired rye.domain.admin grant is missing from %', v_caps;
    END IF;

    -- 42.7b A deactivated grant is not in the array either.
    UPDATE agent_capability_grants SET active = false WHERE id = v_grant;
    v_caps := authenticate_agent_token(v_token)->'capabilities';
    IF v_caps @> '[{"capability":"rye.domain.admin"}]'::jsonb THEN
        RAISE EXCEPTION 'A deactivated rye.domain.admin grant is in the capability array: %', v_caps;
    END IF;
    UPDATE agent_capability_grants SET active = true WHERE id = v_grant;

    -- 42.8 The instance-wide predicate. A grant that names an area carries that
    -- area's key; a grant that names none carries a null domain_key, and null is
    -- the only thing that says "instance-wide". Both grants exist at once, so the
    -- test is about the predicate and not about which grant was written.
    PERFORM grant_agent_capability('leftover_agent', 'rye.review.read', 'leftover_area');
    v_caps := authenticate_agent_token(v_token)->'capabilities';
    IF NOT (v_caps @> '[{"capability":"rye.review.read","domain_key":"leftover_area"}]'::jsonb) THEN
        RAISE EXCEPTION 'An area-scoped rye.review.read grant does not carry its area key: %', v_caps;
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_caps) c
        WHERE c->>'capability' = 'rye.review.read' AND c->>'domain_key' IS NULL
    ) THEN
        RAISE EXCEPTION
            'An agent whose only rye.review.read grant names an area holds an instance-wide one: %',
            v_caps;
    END IF;

    PERFORM create_agent_identity('leftover_agent_wide', 'Leftover wide agent', 'test');
    PERFORM grant_agent_capability('leftover_agent_wide', 'rye.review.read');
    v_token := issue_agent_token('leftover_agent_wide', 'leftovers');
    v_caps := authenticate_agent_token(v_token)->'capabilities';
    IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_caps) c
        WHERE c->>'capability' = 'rye.review.read' AND c->>'domain_key' IS NULL
    ) THEN
        RAISE EXCEPTION
            'An agent granted rye.review.read with no area does not hold an instance-wide grant: %',
            v_caps;
    END IF;
END
$$;

-- ==========================================================================
-- 42.1  A pre-gate alias no longer routes past the gate.
-- 42.2  Aliasing out of a gated type is still refused.
-- 42.3  settle_gate() agrees.
--
-- Last, because recording the alias changes what every later
-- record_assertion('review_policy', ...) in this transaction is stored as.
-- ==========================================================================
DO $$
DECLARE
    v_alias   uuid;
    v_core    uuid;
    v_failed  boolean;
    v_gate    jsonb;
    v_id      uuid;
    v_msg     text;
    v_roles   text[];
    v_row     assertions;
    v_status  text;
    v_subject uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    SELECT id INTO v_core FROM nodes
    WHERE external_source = 'rye_registry' AND external_id = 'core' AND archived_at IS NULL;

    SELECT allowed_roles INTO v_roles FROM assertion_type_access
    WHERE assertion_type = 'review_policy' AND operation = 'settle';
    IF v_roles IS NULL THEN
        RAISE EXCEPTION 'Premise broken: review_policy is not settle-gated on this instance';
    END IF;

    -- The alias is recorded in the window before the type was gated. That
    -- window is real: "adding a type to the gate is an INSERT, not a
    -- migration", so every instance had one.
    DELETE FROM assertion_type_access
    WHERE assertion_type = 'review_policy' AND operation = 'settle';
    IF assertion_settle_roles('review_policy') IS NOT NULL THEN
        RAISE EXCEPTION 'Premise broken: the settle row survived the delete';
    END IF;

    v_alias := record_assertion(
        'registry_entry', '{"value":"leftover_policy_note"}', v_core,
        p_assertion_key := 'type_alias:assertion_type:review_policy',
        p_status := 'accepted', p_basis := 'assumed'
    );
    IF (SELECT status FROM assertions WHERE id = v_alias) <> 'accepted' THEN
        RAISE EXCEPTION 'Premise broken: the pre-gate alias did not land accepted';
    END IF;

    INSERT INTO assertion_type_access (assertion_type, operation, allowed_roles)
    VALUES ('review_policy', 'settle', v_roles);

    -- Anti-vacuity: the alias resolves, so the hole is open.
    IF canonical_type('assertion_type', 'review_policy') = 'review_policy' THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: review_policy still canonicalizes to itself, so no alias stands';
    END IF;
    IF assertion_settle_roles(canonical_type('assertion_type', 'review_policy')) IS NOT NULL THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: the alias target is itself gated, so the canonical lookup would have caught it';
    END IF;

    -- 42.1 The write is demoted, and says which spelling gated it.
    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Leftovers alias subject')
    RETURNING id INTO v_subject;

    PERFORM set_config('app.current_role', 'team_member', true);
    v_id := record_assertion(
        'review_policy', '{"review_policy":"open"}', v_subject,
        p_assertion_key := 'default', p_status := 'accepted', p_basis := 'assumed'
    );
    SELECT * INTO v_row FROM assertions WHERE id = v_id;
    IF v_row.status <> 'candidate' THEN
        RAISE EXCEPTION
            'A team_member write under a pre-gate alias landed %, not candidate', v_row.status;
    END IF;
    IF (v_row.attrs->'settle_gate'->>'pending')::boolean IS DISTINCT FROM true
       OR v_row.attrs->'settle_gate'->>'gated_as' IS DISTINCT FROM 'review_policy'
       OR NOT (v_row.attrs->'settle_gate'->'allowed_roles' @> '["admin"]'::jsonb)
    THEN
        RAISE EXCEPTION
            'The demotion under a pre-gate alias carries settle_gate %', v_row.attrs->'settle_gate';
    END IF;

    -- Anti-vacuity: the same call as an allowed role lands accepted, so the
    -- demotion is the gate and not the route.
    PERFORM set_config('app.current_role', 'admin', true);
    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Leftovers alias subject two')
    RETURNING id INTO v_subject;
    v_id := record_assertion(
        'review_policy', '{"review_policy":"open"}', v_subject,
        p_assertion_key := 'default', p_status := 'accepted', p_basis := 'assumed'
    );
    SELECT * INTO v_row FROM assertions WHERE id = v_id;
    IF v_row.status <> 'accepted' OR v_row.attrs ? 'settle_gate' THEN
        RAISE EXCEPTION
            'An admin write under the pre-gate alias landed % with attrs %',
            v_row.status, v_row.attrs;
    END IF;
    IF v_row.assertion_type <> 'leftover_policy_note' THEN
        RAISE EXCEPTION
            'Premise broken: the write was stored as %, so the alias did not route it',
            v_row.assertion_type;
    END IF;

    -- 42.2 0028's rule is unchanged: a NEW alias out of a gated type is refused
    -- at every status, admin included.
    FOREACH v_status IN ARRAY ARRAY['accepted', 'candidate'] LOOP
        v_failed := false;
        BEGIN
            PERFORM record_assertion(
                'registry_entry', '{"value":"leftover_decoy"}', v_core,
                p_assertion_key := 'type_alias:assertion_type:review_policy',
                p_status := v_status, p_basis := 'assumed'
            );
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'An admin recorded a % alias out of review_policy', v_status;
        END IF;
        IF v_msg NOT LIKE '%Cannot record a type alias from%' THEN
            RAISE EXCEPTION 'The % alias was refused for the wrong reason: %', v_status, v_msg;
        END IF;
    END LOOP;

    -- 42.3 settle_gate() answers by the same rule.
    v_gate := settle_gate('review_policy');
    IF (v_gate->>'gated')::boolean IS DISTINCT FROM true
       OR NOT (v_gate->'allowed_roles' @> '["admin"]'::jsonb)
       OR v_gate->'gated_as' <> 'null'::jsonb
    THEN
        RAISE EXCEPTION
            'settle_gate(review_policy) under a pre-gate alias returned %', v_gate;
    END IF;

    v_gate := settle_gate('leftover_policy_note');
    IF (v_gate->>'gated')::boolean IS DISTINCT FROM false
       OR v_gate->'gated_as' <> 'null'::jsonb
       OR v_gate->'allowed_roles' <> 'null'::jsonb
    THEN
        RAISE EXCEPTION 'settle_gate on the ungated alias target returned %', v_gate;
    END IF;

    -- An alias INTO a gated type is the other direction, and is allowed. There
    -- the gated spelling is not the one the caller passed, so gated_as names it.
    PERFORM record_assertion(
        'registry_entry', '{"value":"registry_entry"}', v_core,
        p_assertion_key := 'type_alias:assertion_type:leftover_draft_config',
        p_status := 'accepted', p_basis := 'assumed'
    );
    v_gate := settle_gate('leftover_draft_config');
    IF (v_gate->>'gated')::boolean IS DISTINCT FROM true
       OR v_gate->>'gated_as' IS DISTINCT FROM 'registry_entry'
       OR NOT (v_gate->'allowed_roles' @> '["admin"]'::jsonb)
    THEN
        RAISE EXCEPTION 'settle_gate on an alias into a gated type returned %', v_gate;
    END IF;

    PERFORM set_config('app.current_role', 'team_member', true);
    v_gate := settle_gate('leftover_draft_config');
    IF (v_gate->>'may_settle')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'settle_gate told a team_member it may settle an aliased gated type: %', v_gate;
    END IF;

    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Leftovers alias-into subject')
    RETURNING id INTO v_subject;
    v_id := record_assertion(
        'leftover_draft_config', '{"value":"proposed"}', v_subject,
        p_assertion_key := 'default', p_status := 'accepted', p_basis := 'assumed'
    );
    SELECT * INTO v_row FROM assertions WHERE id = v_id;
    IF v_row.status <> 'candidate'
       OR v_row.attrs->'settle_gate'->>'gated_as' IS DISTINCT FROM 'registry_entry'
    THEN
        RAISE EXCEPTION
            'A write under an alias into a gated type landed % with settle_gate %',
            v_row.status, v_row.attrs->'settle_gate';
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
END
$$;

-- ==========================================================================
-- 42.10  A demotion cannot be settled by the role it excluded.
--
-- Found by verification of the first cut of 0036: the demoted row's STORED
-- type is the ungated alias target, so assertion_settle_gate_guard() saw an
-- ordinary candidate and accept_assertion() promoted it FOR THE VERY ROLE THE
-- GATE HAD JUST EXCLUDED, while review_queue told the reviewer an admin was
-- required. The row is the gate: attrs.settle_gate.allowed_roles now drives
-- the same two refusals the type gate makes.
--
-- Runs after the block above, which leaves the pre-gate alias standing.
-- ==========================================================================
DO $$
DECLARE
    v_attrs   jsonb;
    v_failed  boolean;
    v_gate    jsonb;
    v_id      uuid;
    v_ids     uuid[] := '{}'::uuid[];
    v_msg     text;
    v_role    text;
    v_roles   text[] := ARRAY['team_member', 'agent:t'];
    v_row     assertions;
    v_rows    integer;
    v_subject uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    -- Premise: the alias from the block above still stands, so a write under
    -- the gated name is stored under an UNGATED type. Without that, every
    -- refusal below would be the ordinary type gate and would prove nothing.
    IF canonical_type('assertion_type', 'review_policy') = 'review_policy'
       OR assertion_settle_roles(canonical_type('assertion_type', 'review_policy')) IS NOT NULL
    THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: the pre-gate alias does not stand, or its target is itself gated';
    END IF;

    FOREACH v_role IN ARRAY v_roles LOOP
        PERFORM set_config('app.current_role', 'admin', true);
        INSERT INTO nodes (node_type, label) VALUES ('thing', 'Leftovers settle marker subject')
        RETURNING id INTO v_subject;

        PERFORM set_config('app.current_role', v_role, true);
        v_id := record_assertion(
            'review_policy', '{"review_policy":"open"}', v_subject,
            p_assertion_key := 'default', p_status := 'accepted', p_basis := 'assumed'
        );
        v_ids := v_ids || v_id;
        SELECT * INTO v_row FROM assertions WHERE id = v_id;
        IF v_row.status <> 'candidate'
           OR NOT (v_row.attrs->'settle_gate'->'allowed_roles' @> '["admin"]'::jsonb)
        THEN
            RAISE EXCEPTION
                'Premise broken for "%": the write landed % with settle_gate %',
                v_role, v_row.status, v_row.attrs->'settle_gate';
        END IF;
        IF assertion_settle_roles(v_row.assertion_type) IS NOT NULL THEN
            RAISE EXCEPTION
                'Premise broken: the stored type % is itself gated, so the marker is not what refuses',
                v_row.assertion_type;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM review_queue WHERE assertion_type = v_row.assertion_type) THEN
            RAISE EXCEPTION 'Premise broken for "%": the demotion is not in review_queue', v_role;
        END IF;

        -- accept_assertion() refuses. It is SECURITY DEFINER, so on the Docker
        -- owner it runs as a superuser and the trigger is the only thing that
        -- can stop it -- which is the point of putting the rule there.
        v_failed := false;
        BEGIN
            PERFORM accept_assertion(v_id);
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION
                'Role "%" accepted its own settle-gate demotion through accept_assertion()', v_role;
        END IF;
        IF v_msg NOT LIKE '%waiting on the settle gate%' THEN
            RAISE EXCEPTION 'Role "%" was refused for the wrong reason: %', v_role, v_msg;
        END IF;
        IF (SELECT status FROM assertions WHERE id = v_id) <> 'candidate' THEN
            RAISE EXCEPTION 'Role "%" left its demotion accepted', v_role;
        END IF;

        -- The raw UPDATE with the accept write path forged, which is the shape
        -- any caller can produce, so the refusal must not rest on the policy.
        PERFORM set_config('app.write_path', 'accept_assertion', true);
        PERFORM set_config('app.accept_assertion_id', v_id::text, true);
        v_failed := false;
        v_rows := 0;
        BEGIN
            UPDATE assertions SET status = 'accepted' WHERE id = v_id;
            GET DIAGNOSTICS v_rows = ROW_COUNT;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
        END;
        PERFORM set_config('app.write_path', '', true);
        PERFORM set_config('app.accept_assertion_id', '', true);
        IF NOT v_failed AND v_rows <> 0 THEN
            RAISE EXCEPTION
                'Role "%" promoted its own demotion with a forged accept path: % rows', v_role, v_rows;
        END IF;
        IF (SELECT status FROM assertions WHERE id = v_id) <> 'candidate' THEN
            RAISE EXCEPTION 'Role "%" promoted its own demotion by raw UPDATE', v_role;
        END IF;

        -- The marker cannot be washed off first. 0025 refuses an attrs write
        -- that drops a key or changes an existing key's value, including
        -- through the forged assertion_outcome write path.
        v_failed := false;
        v_rows := 0;
        BEGIN
            UPDATE assertions SET attrs = attrs - 'settle_gate' WHERE id = v_id;
            GET DIAGNOSTICS v_rows = ROW_COUNT;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
        END;
        IF NOT v_failed AND v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" stripped the settle_gate marker: % rows', v_role, v_rows;
        END IF;

        PERFORM set_config('app.write_path', 'assertion_outcome', true);
        PERFORM set_config('app.outcome_assertion_id', v_id::text, true);
        v_failed := false;
        v_rows := 0;
        BEGIN
            UPDATE assertions
            SET attrs = (attrs - 'settle_gate') || jsonb_build_object('outcome', 'correct')
            WHERE id = v_id;
            GET DIAGNOSTICS v_rows = ROW_COUNT;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
        END;
        IF NOT v_failed AND v_rows <> 0 THEN
            RAISE EXCEPTION
                'Role "%" stripped the settle_gate marker through the outcome path: % rows',
                v_role, v_rows;
        END IF;

        v_failed := false;
        v_rows := 0;
        BEGIN
            UPDATE assertions
            SET attrs = jsonb_set(attrs, '{settle_gate,allowed_roles}', to_jsonb(ARRAY[v_role]))
                        || jsonb_build_object('outcome', 'correct')
            WHERE id = v_id;
            GET DIAGNOSTICS v_rows = ROW_COUNT;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
        END;
        PERFORM set_config('app.write_path', '', true);
        PERFORM set_config('app.outcome_assertion_id', '', true);
        IF NOT v_failed AND v_rows <> 0 THEN
            RAISE EXCEPTION
                'Role "%" rewrote settle_gate.allowed_roles to name itself: % rows', v_role, v_rows;
        END IF;

        SELECT attrs INTO v_attrs FROM assertions WHERE id = v_id;
        IF NOT (v_attrs->'settle_gate'->'allowed_roles' @> '["admin"]'::jsonb) THEN
            RAISE EXCEPTION 'Role "%" changed the marker: attrs are now %', v_role, v_attrs;
        END IF;
    END LOOP;

    -- Anti-vacuity: an admin still accepts both, so the rule is the gate and
    -- not a wall. Without this every refusal above could be a broken helper.
    PERFORM set_config('app.current_role', 'admin', true);
    FOREACH v_id IN ARRAY v_ids LOOP
        PERFORM accept_assertion(v_id);
        IF (SELECT status FROM assertions WHERE id = v_id) <> 'accepted' THEN
            RAISE EXCEPTION 'An admin could not accept a settle-gate demotion';
        END IF;
    END LOOP;

    -- A raw INSERT at accepted carrying a forged marker naming the caller's own
    -- role gains nothing: the marker is read only when the stored type is
    -- UNGATED, and for an ungated type an accepted row was always allowed. It
    -- can add a refusal, never remove one. Pinned so the forged case is on the
    -- record as a no-op rather than as an untested hole.
    PERFORM set_config('app.current_role', 'team_member', true);
    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Leftovers forged marker subject')
    RETURNING id INTO v_subject;
    INSERT INTO assertions
        (assertion_type, assertion_key, status, basis, subject_node_id, claim, attrs)
    VALUES ('leftover_policy_note', 'default', 'accepted', 'assumed', v_subject,
            '{"review_policy":"open"}',
            '{"settle_gate":{"allowed_roles":["team_member"]}}');

    -- And a forged marker naming somebody else only refuses the forger.
    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Leftovers forged marker subject two')
    RETURNING id INTO v_subject;
    v_failed := false;
    BEGIN
        INSERT INTO assertions
            (assertion_type, assertion_key, status, basis, subject_node_id, claim, attrs)
        VALUES ('leftover_policy_note', 'default', 'accepted', 'assumed', v_subject,
                '{"review_policy":"open"}',
                '{"settle_gate":{"allowed_roles":["admin"]}}');
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        v_msg := SQLERRM;
    END;
    IF NOT v_failed OR v_msg NOT LIKE '%waiting on the settle gate%' THEN
        RAISE EXCEPTION
            'A forged marker naming another role did not refuse the forger: failed=% msg=%',
            v_failed, v_msg;
    END IF;

    -- A gated STORED type is still judged by its settle row, never by a marker,
    -- so a forged marker can never widen the type gate.
    v_failed := false;
    BEGIN
        INSERT INTO assertions
            (assertion_type, assertion_key, status, basis, subject_node_id, claim, attrs)
        VALUES ('registry_entry', 'leftover_forged_marker', 'accepted', 'assumed', v_subject,
                '{"value":"x"}',
                '{"settle_gate":{"allowed_roles":["team_member"]}}');
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        v_msg := SQLERRM;
    END;
    IF NOT v_failed OR v_msg NOT LIKE '%is Rye configuration%' THEN
        RAISE EXCEPTION
            'A forged marker widened the type gate on a gated stored type: failed=% msg=%',
            v_failed, v_msg;
    END IF;

    -- ------------------------------------------------------------------
    -- settle_gate() normalises its argument exactly as record_assertion()
    -- does, so asking first is truthful. It did not, and a padded spelling
    -- answered gated false / may_settle true and was then demoted.
    -- ------------------------------------------------------------------
    PERFORM set_config('app.current_role', 'team_member', true);
    v_gate := settle_gate(' review_policy ');
    IF (v_gate->>'gated')::boolean IS DISTINCT FROM true
       OR (v_gate->>'may_settle')::boolean IS DISTINCT FROM false
       OR v_gate->>'assertion_type' IS DISTINCT FROM 'review_policy'
       OR NOT (v_gate->'allowed_roles' @> '["admin"]'::jsonb)
    THEN
        RAISE EXCEPTION 'settle_gate with a padded argument returned %', v_gate;
    END IF;

    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Leftovers padded subject')
    RETURNING id INTO v_subject;
    v_id := record_assertion(
        ' review_policy ', '{"review_policy":"open"}', v_subject,
        p_assertion_key := 'default', p_status := 'accepted', p_basis := 'assumed'
    );
    IF (SELECT status FROM assertions WHERE id = v_id) <> 'candidate' THEN
        RAISE EXCEPTION
            'A padded gated type was not demoted, so settle_gate and record_assertion still disagree';
    END IF;

    -- A CASE VARIANT IS A DIFFERENT TYPE, and that is not a regression.
    -- Neither settle_gate() nor record_assertion() lowercases, so
    -- 'REVIEW_POLICY' is an assertion type of its own: ungated, and a write
    -- under it lands accepted under that spelling. It is a policy no-op,
    -- because registry_value() and governing_scope() match the literal
    -- 'review_policy' and never read 'REVIEW_POLICY' as configuration. It
    -- predates migration 0036 and is pinned here so nobody mistakes it for one.
    v_gate := settle_gate('REVIEW_POLICY');
    IF (v_gate->>'gated')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'A case variant is now gated; this pin needs rewriting: %', v_gate;
    END IF;
    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Leftovers case variant subject')
    RETURNING id INTO v_subject;
    v_id := record_assertion(
        'REVIEW_POLICY', '{"review_policy":"open"}', v_subject,
        p_assertion_key := 'default', p_status := 'accepted', p_basis := 'assumed'
    );
    SELECT * INTO v_row FROM assertions WHERE id = v_id;
    IF v_row.status <> 'accepted' OR v_row.assertion_type <> 'REVIEW_POLICY' THEN
        RAISE EXCEPTION
            'The case variant behaved differently than pinned: status % type %',
            v_row.status, v_row.assertion_type;
    END IF;
    -- The no-op half: nothing reads it as a review policy.
    PERFORM set_config('app.current_role', 'admin', true);
    IF scope_review_policy('42000001-0000-4000-8000-000000000004') <> 'open' THEN
        RAISE EXCEPTION 'A case variant was read as configuration somewhere';
    END IF;
END
$$;

-- ==========================================================================
-- 42.11  An admin is never locked out of the review queue by a marker.
--
-- attrs is caller-supplied on a raw INSERT, so an agent can write
-- {"settle_gate":{"allowed_roles":[]}} -- or an array that simply excludes
-- admin -- onto a suggestion of an ungated type. Read literally, nobody
-- qualifies: the row could be neither accepted nor rejected and sat in
-- review_queue for good. Self-inflicted, but an admin must always be able to
-- clear the queue, so where the MARKER is the gate an admin always qualifies.
-- Every other role still has to be named. The type gate is untouched: 42.10
-- above already pins that a gated stored type is judged by its settle row.
-- ==========================================================================
DO $$
DECLARE
    v_empty   uuid;
    v_failed  boolean;
    v_manager uuid;
    v_msg     text;
    v_role    text;
    v_subject uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Leftovers lockout subject')
    RETURNING id INTO v_subject;

    PERFORM set_config('app.current_role', 'agent:t', true);
    INSERT INTO assertions
        (assertion_type, assertion_key, status, basis, subject_node_id, claim, attrs)
    VALUES ('leftover_lockout_probe', 'empty', 'candidate', 'assumed', v_subject,
            '{"value":"nobody named"}',
            '{"settle_gate":{"allowed_roles":[]}}')
    RETURNING id INTO v_empty;

    INSERT INTO assertions
        (assertion_type, assertion_key, status, basis, subject_node_id, claim, attrs)
    VALUES ('leftover_lockout_probe', 'manager', 'candidate', 'assumed', v_subject,
            '{"value":"manager named"}',
            '{"settle_gate":{"allowed_roles":["manager"]}}')
    RETURNING id INTO v_manager;

    PERFORM set_config('app.current_role', 'admin', true);
    IF assertion_settle_roles('leftover_lockout_probe') IS NOT NULL THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: the probe type is settle-gated, so the marker is not what decides';
    END IF;

    -- Still closed to everyone the marker does not name.
    FOREACH v_role IN ARRAY ARRAY['team_member', 'agent:other'] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_failed := false;
        BEGIN
            PERFORM accept_assertion(v_empty);
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed OR v_msg NOT LIKE '%waiting on the settle gate%' THEN
            RAISE EXCEPTION
                'Role "%" accepted a row whose marker names nobody: failed=% msg=%',
                v_role, v_failed, v_msg;
        END IF;
        PERFORM set_config('app.current_role', 'admin', true);
        IF (SELECT status FROM assertions WHERE id = v_empty) <> 'candidate' THEN
            RAISE EXCEPTION 'Role "%" left the empty-marker row accepted', v_role;
        END IF;
    END LOOP;

    -- The admin is not. Accepting the empty-marker row is the half this
    -- migration owns; conformance 43 owns rejecting it.
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM accept_assertion(v_empty);
    IF (SELECT status FROM assertions WHERE id = v_empty) <> 'accepted' THEN
        RAISE EXCEPTION 'An admin could not accept a row whose marker names nobody';
    END IF;

    -- A marker naming only another role is the same answer.
    PERFORM accept_assertion(v_manager);
    IF (SELECT status FROM assertions WHERE id = v_manager) <> 'accepted' THEN
        RAISE EXCEPTION 'An admin could not accept a row whose marker names only manager';
    END IF;
END
$$;

ROLLBACK;
