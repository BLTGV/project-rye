-- Who may reject a suggestion, and an edge carries its own classification.
--
-- Contract:  contracts/sql-surface.md, "Who may reject a suggestion" and
--            "Edges carry their own classification".
-- Decision:  docs/decisions/0014-who-may-reject-and-edges-carry-their-own-classification.md,
--            test obligations 43.1 to 43.15.
-- Work item: work/018-session-leftovers.md, second migration.
-- Migration: schema/migrations/0037_reject_authority_edge_classification.sql.
-- Issues:    38, and the reject_candidate() finding recorded on 32.
--
-- Runs under both database owner types. scripts/conformance.sh runs it as the
-- non-superuser rye_conformance role through SET ROLE when the connection is a
-- superuser; scripts/test-nonsuperuser-owner.sh runs it as rye_owner, which is
-- NOSUPERUSER NOBYPASSRLS, with no SET ROLE. It refuses to run in any other
-- shape rather than skipping.
--
-- Two steps need the table owner rather than the suite role: seeding a row with
-- a trigger disabled. `SELECT current_user AS suite_role \gset` remembers who
-- the suite is, RESET ROLE reaches the owner, and SET ROLE :"suite_role" comes
-- back. ALTER TABLE ... DISABLE TRIGGER raises "pending trigger events" once an
-- assertion has been written in the transaction, so SET CONSTRAINTS ALL
-- IMMEDIATE / DEFERRED brackets each owner step.
--
-- Refusal shape follows the standing rule: a refused INSERT raises 42501; a
-- refused UPDATE raises where the owner is a superuser and affects zero rows
-- where the owner is bound by RLS. Where the route is a helper the helper's own
-- sentence is asserted, because the helper refuses before it writes; where the
-- route is a raw UPDATE the row is asserted and the error is not.
--
-- Negative control: without 0037 this suite fails in the first block, which
-- names the three triggers and the edge policy.
--
-- Invented names only.

SET search_path = rye, public, pg_catalog;

SELECT current_user AS suite_role \gset

BEGIN;

CREATE TEMP TABLE t43 (k text PRIMARY KEY, v text);

-- ---------------------------------------------------------------------------
-- Anti-vacuity, and 0037 is present.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_bypass  boolean;
    v_missing text;
    v_role    text;
    v_super   boolean;
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

    FOREACH v_role IN ARRAY ARRAY['admin', 'team_member', 'viewer',
                                  'agent:alpha', 'agent:beta', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION
                'Refusing to pass vacuously: app.current_role did not read back as "%", it reads "%"',
                v_role, current_setting('app.current_role', true);
        END IF;
    END LOOP;

    -- Migration 0037, named object by named object.
    SELECT string_agg(required.name, ', ' ORDER BY required.name)
    INTO v_missing
    FROM (VALUES ('assertion_authorship_stamp'),
                 ('assertion_rejection_authority_guard'),
                 ('enforce_edge_classification_with_teams')) required(name)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'rye' AND p.proname = required.name
    );
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 0037 has not been applied: missing function %', v_missing;
    END IF;

    SELECT string_agg(required.tgname, ', ' ORDER BY required.tgname)
    INTO v_missing
    FROM (VALUES ('assertions', 'trg_assertion_authorship_stamp'),
                 ('assertions', 'trg_assertions_reject_authority'),
                 ('edges',      'trg_edges_classification_check')) required(relname, tgname)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'rye'
          AND c.relname = required.relname
          AND t.tgname = required.tgname
          AND NOT t.tgisinternal
    );
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 0037 has not been applied: missing trigger %', v_missing;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'rye' AND tablename = 'edges'
          AND policyname = 'edge_read_policy'
          AND qual LIKE '%classification%'
    ) THEN
        RAISE EXCEPTION
            'migration 0037 has not been applied: edge_read_policy does not read the edge''s own classification';
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:reject-authority', true);
    PERFORM set_config('app.current_teams', '', true);
END
$$;

-- ---------------------------------------------------------------------------
-- 43.8 authorship is stamped, 43.1 and 43.2 an agent closes only its own,
-- 43.3 the correction route, 43.4 a person closes ordinary suggestions,
-- 43.9 the write gate is unchanged.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_a1     uuid;
    v_a1b    uuid;
    v_ad     uuid;
    v_attrs  jsonb;
    v_failed boolean;
    v_msg    text;
    v_raw    uuid;
    v_role   text;
    v_rows   int;
    v_subj   uuid;
    v_tm     uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:reject-authority', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label, attrs)
    VALUES ('thing', 'Reject Authority Subject', '{"classification":"public"}')
    RETURNING id INTO v_subj;
    INSERT INTO t43 VALUES ('subject', v_subj::text);

    -- ==================================================================
    -- 43.8 Authorship cannot be chosen by the caller, on either route.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'agent:alpha', true);
    v_a1 := record_assertion(
        'reject_probe', '{"value":"alpha first"}', v_subj,
        p_assertion_key := 'r1', p_status := 'candidate', p_basis := 'assumed',
        p_attrs := '{"recorded_by":"agent:someone-else","recorded_by_label":"forged","note":"kept"}'
    );

    SELECT attrs INTO v_attrs FROM assertions WHERE id = v_a1;
    IF v_attrs->>'recorded_by' IS DISTINCT FROM 'agent:alpha' THEN
        RAISE EXCEPTION
            'record_assertion() left recorded_by as "%" for a session whose role is agent:alpha',
            v_attrs->>'recorded_by';
    END IF;
    IF v_attrs::text LIKE '%someone-else%' THEN
        RAISE EXCEPTION
            'the caller''s supplied recorded_by survived somewhere in attrs: %', v_attrs;
    END IF;
    IF v_attrs->>'recorded_by_label' IS DISTINCT FROM 'test:reject-authority' THEN
        RAISE EXCEPTION
            'recorded_by_label is "%", not the session''s app.current_user_id',
            v_attrs->>'recorded_by_label';
    END IF;
    IF v_attrs->>'note' IS DISTINCT FROM 'kept' THEN
        RAISE EXCEPTION 'the stamp dropped an attrs key the caller supplied: %', v_attrs;
    END IF;

    INSERT INTO assertions (
        assertion_type, assertion_key, status, basis, subject_node_id, claim, attrs
    ) VALUES (
        'reject_probe', 'r_raw', 'candidate', 'assumed', v_subj,
        '{"value":"alpha raw"}', '{"recorded_by":"agent:someone-else"}'
    ) RETURNING id INTO v_raw;

    SELECT attrs INTO v_attrs FROM assertions WHERE id = v_raw;
    IF v_attrs->>'recorded_by' IS DISTINCT FROM 'agent:alpha' THEN
        RAISE EXCEPTION
            'a raw INSERT kept the caller''s recorded_by: %', v_attrs;
    END IF;
    IF v_attrs::text LIKE '%someone-else%' THEN
        RAISE EXCEPTION 'a raw INSERT left the forged author in attrs: %', v_attrs;
    END IF;
    RAISE NOTICE 'PASS 43.8: authorship is stamped from the session on every route';

    -- ==================================================================
    -- 43.1 An agent cannot close another agent's suggestion.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'agent:beta', true);

    SELECT count(*) INTO v_rows FROM assertions WHERE id = v_a1;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: agent:beta cannot read the candidate, so a refusal proves nothing';
    END IF;

    v_failed := false;
    BEGIN
        PERFORM reject_candidate(v_a1, 'beta disagrees');
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        v_msg := SQLERRM;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'agent:beta closed a suggestion recorded by agent:alpha';
    END IF;
    IF v_msg NOT LIKE '%may close only its own%' THEN
        RAISE EXCEPTION 'agent:beta was refused for the wrong reason: %', v_msg;
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT superseded_at FROM assertions WHERE id = v_a1) IS NOT NULL THEN
        RAISE EXCEPTION 'the candidate agent:beta was refused is no longer live';
    END IF;
    RAISE NOTICE 'PASS 43.1: an agent cannot close another agent''s suggestion';

    -- ==================================================================
    -- 43.2 An agent cannot close a person's suggestion.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'team_member', true);
    v_tm := record_assertion(
        'reject_probe', '{"value":"person said"}', v_subj,
        p_assertion_key := 'r2', p_status := 'candidate', p_basis := 'assumed'
    );
    IF (SELECT attrs->>'recorded_by' FROM assertions WHERE id = v_tm)
       IS DISTINCT FROM 'team_member'
    THEN
        RAISE EXCEPTION 'the person''s candidate was not attributed to team_member';
    END IF;

    PERFORM set_config('app.current_role', 'agent:beta', true);
    v_failed := false;
    BEGIN
        PERFORM reject_candidate(v_tm, 'beta disagrees with a person');
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        v_msg := SQLERRM;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'agent:beta closed a team_member''s suggestion';
    END IF;
    IF v_msg NOT LIKE '%may close only its own%' THEN
        RAISE EXCEPTION 'agent:beta was refused a person''s suggestion for the wrong reason: %', v_msg;
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT superseded_at FROM assertions WHERE id = v_tm) IS NOT NULL THEN
        RAISE EXCEPTION 'the person''s candidate is no longer live after a refused rejection';
    END IF;
    RAISE NOTICE 'PASS 43.2: an agent cannot close a person''s suggestion';

    -- ==================================================================
    -- 43.9 The write gate is unchanged: viewer and an unset role close
    -- nothing, and the candidate is untouched.
    -- ==================================================================
    FOREACH v_role IN ARRAY ARRAY['viewer', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_failed := false;
        BEGIN
            PERFORM reject_candidate(v_tm, 'a reader closing a suggestion');
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'role "%" closed a suggestion', v_role;
        END IF;
        PERFORM set_config('app.current_role', 'admin', true);
        IF (SELECT superseded_at FROM assertions WHERE id = v_tm) IS NOT NULL THEN
            RAISE EXCEPTION 'role "%" closed the candidate after all', v_role;
        END IF;
    END LOOP;
    RAISE NOTICE 'PASS 43.9: viewer and an unset role close nothing';

    -- ==================================================================
    -- 43.3 The correction route still works: an agent closes its own
    -- pending suggestion and files a corrected one.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'agent:alpha', true);
    PERFORM reject_candidate(v_a1, 'alpha corrects itself: the figure was stale', 'agent:alpha', 'stale');

    v_a1b := record_assertion(
        'reject_probe', '{"value":"alpha corrected"}', v_subj,
        p_assertion_key := 'r1', p_status := 'candidate', p_basis := 'assumed'
    );

    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT superseded_at FROM assertions WHERE id = v_a1) IS NULL THEN
        RAISE EXCEPTION 'agent:alpha could not close its own suggestion';
    END IF;
    IF (SELECT status FROM assertions WHERE id = v_a1) <> 'candidate' THEN
        RAISE EXCEPTION 'a rejected candidate changed status';
    END IF;
    IF (SELECT attrs->>'recorded_by' FROM assertions WHERE id = v_a1)
       IS DISTINCT FROM 'agent:alpha'
    THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: the closed row is not attributed to agent:alpha, so the match proves nothing';
    END IF;

    -- The candidate_rejected event, which rejected_candidates (0035) reads.
    IF NOT EXISTS (
        SELECT 1 FROM events e
        WHERE e.event_type = 'candidate_rejected'
          AND e.properties->>'assertion_id' = v_a1::text
          AND e.properties->>'reason' LIKE '%the figure was stale%'
          AND e.properties->>'outcome' = 'stale'
    ) THEN
        RAISE EXCEPTION 'the rejection recorded no candidate_rejected event with reason and outcome';
    END IF;
    IF to_regclass('rye.rejected_candidates') IS NOT NULL THEN
        SELECT count(*) INTO v_rows
        FROM rejected_candidates WHERE assertion_id = v_a1;
        IF v_rows <> 1 THEN
            RAISE EXCEPTION 'the closed candidate is not in rejected_candidates';
        END IF;
    END IF;

    SELECT count(*) INTO v_rows
    FROM review_queue q
    WHERE q.subject_node_id = v_subj
      AND q.assertion_key = 'r1'
      AND q.candidates::text LIKE '%' || v_a1b::text || '%';
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'the corrected suggestion is not waiting in review_queue';
    END IF;
    RAISE NOTICE 'PASS 43.3: an agent closes its own suggestion and files a correction';

    -- ==================================================================
    -- 43.4 A person still rejects ordinary suggestions: one an agent
    -- recorded and one an admin recorded.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'admin', true);
    v_ad := record_assertion(
        'reject_probe', '{"value":"admin said"}', v_subj,
        p_assertion_key := 'r4', p_status := 'candidate', p_basis := 'assumed'
    );

    PERFORM set_config('app.current_role', 'team_member', true);
    PERFORM reject_candidate(v_raw, 'a person closes an agent suggestion', 'person:one');
    PERFORM reject_candidate(v_ad, 'a person closes an admin suggestion', 'person:one');

    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT superseded_at FROM assertions WHERE id = v_raw) IS NULL
       OR (SELECT superseded_at FROM assertions WHERE id = v_ad) IS NULL
    THEN
        RAISE EXCEPTION 'team_member could not close an ordinary suggestion';
    END IF;
    RAISE NOTICE 'PASS 43.4: a named writing role closes ordinary suggestions';

    INSERT INTO t43 VALUES ('tm_candidate', v_tm::text);
END
$$;

-- ---------------------------------------------------------------------------
-- 43.5 Closing a configuration suggestion is deciding it, on the stored
-- spelling and on the canonical one.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_alias  uuid;
    v_cfg    uuid;
    v_core   uuid;
    v_failed boolean;
    v_msg    text;
    v_role   text;
    v_subj   uuid := (SELECT v FROM t43 WHERE k = 'subject')::uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_teams', '', true);

    IF assertion_settle_roles('registry_entry') IS NULL THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: registry_entry is not settle-gated in this instance';
    END IF;

    -- Recorded BY agent:alpha, so the refusal below proves that configuration
    -- beats authorship and not merely that the caller is a stranger.
    PERFORM set_config('app.current_role', 'agent:alpha', true);
    v_cfg := record_assertion(
        'registry_entry', '{"value":"probe"}', v_subj,
        p_assertion_key := 'reject_probe:config',
        p_status := 'candidate', p_basis := 'assumed'
    );
    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT attrs->>'recorded_by' FROM assertions WHERE id = v_cfg)
       IS DISTINCT FROM 'agent:alpha'
    THEN
        RAISE EXCEPTION 'the configuration candidate was not recorded by agent:alpha';
    END IF;

    FOREACH v_role IN ARRAY ARRAY['agent:alpha', 'team_member'] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_failed := false;
        BEGIN
            PERFORM reject_candidate(v_cfg, 'closing a configuration suggestion');
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'role "%" closed a registry_entry suggestion', v_role;
        END IF;
        IF v_msg NOT LIKE '%is Rye configuration%' THEN
            RAISE EXCEPTION 'role "%" was refused the configuration suggestion for the wrong reason: %',
                v_role, v_msg;
        END IF;
        PERFORM set_config('app.current_role', 'admin', true);
        IF (SELECT superseded_at FROM assertions WHERE id = v_cfg) IS NOT NULL THEN
            RAISE EXCEPTION 'role "%" closed the configuration suggestion after all', v_role;
        END IF;
    END LOOP;

    PERFORM reject_candidate(v_cfg, 'an admin decides the configuration suggestion', 'person:admin');
    IF (SELECT superseded_at FROM assertions WHERE id = v_cfg) IS NULL THEN
        RAISE EXCEPTION 'an admin could not close a configuration suggestion';
    END IF;

    -- The canonical half. An alias INTO a gated type is allowed (0028), and a
    -- raw INSERT keeps the written spelling, which is the only way a row of a
    -- gated type carries a name the settle rows do not list.
    SELECT id INTO v_core
    FROM nodes
    WHERE external_source = 'rye_registry' AND external_id = 'core' AND archived_at IS NULL;
    IF v_core IS NULL THEN
        RAISE EXCEPTION 'Core registry node is missing; the install seeds did not run';
    END IF;

    PERFORM record_assertion(
        'registry_entry', '{"value":"registry_entry"}', v_core,
        p_assertion_key := 'type_alias:assertion_type:reject_probe_cfg',
        p_status := 'accepted', p_basis := 'assumed'
    );
    IF canonical_type('assertion_type', 'reject_probe_cfg') <> 'registry_entry' THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: the alias does not resolve, it reads %',
            canonical_type('assertion_type', 'reject_probe_cfg');
    END IF;
    IF assertion_settle_roles('reject_probe_cfg') IS NOT NULL THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: the aliased spelling has its own settle row, so the canonical half proves nothing';
    END IF;

    INSERT INTO assertions (
        assertion_type, assertion_key, status, basis, subject_node_id, claim
    ) VALUES (
        'reject_probe_cfg', 'reject_probe:aliased', 'candidate', 'assumed', v_subj,
        '{"value":"aliased configuration"}'
    ) RETURNING id INTO v_alias;

    PERFORM set_config('app.current_role', 'team_member', true);
    IF canonical_type('assertion_type', 'reject_probe_cfg') <> 'registry_entry' THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: team_member cannot resolve the alias, so its refusal proves nothing';
    END IF;
    v_failed := false;
    BEGIN
        PERFORM reject_candidate(v_alias, 'closing an aliased configuration suggestion');
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        v_msg := SQLERRM;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'team_member closed a suggestion of a type aliased into registry_entry';
    END IF;
    IF v_msg NOT LIKE '%is Rye configuration%' THEN
        RAISE EXCEPTION 'the aliased configuration refusal had the wrong reason: %', v_msg;
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT superseded_at FROM assertions WHERE id = v_alias) IS NOT NULL THEN
        RAISE EXCEPTION 'team_member closed the aliased configuration suggestion after all';
    END IF;
    PERFORM reject_candidate(v_alias, 'an admin decides the aliased configuration suggestion');
    IF (SELECT superseded_at FROM assertions WHERE id = v_alias) IS NULL THEN
        RAISE EXCEPTION 'an admin could not close the aliased configuration suggestion';
    END IF;
    RAISE NOTICE 'PASS 43.5: configuration suggestions are closed only by their settle roles, under either spelling';
END
$$;

-- ---------------------------------------------------------------------------
-- 43.6 The raw route agrees. A forged write path buys nothing.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_alpha  uuid;
    v_beta   uuid;
    v_failed boolean;
    v_subj   uuid := (SELECT v FROM t43 WHERE k = 'subject')::uuid;
BEGIN
    PERFORM set_config('app.current_role', 'agent:alpha', true);
    v_alpha := record_assertion(
        'reject_probe', '{"value":"alpha raw target"}', v_subj,
        p_assertion_key := 'r6a', p_status := 'candidate', p_basis := 'assumed'
    );

    PERFORM set_config('app.current_role', 'agent:beta', true);
    v_beta := record_assertion(
        'reject_probe', '{"value":"beta raw target"}', v_subj,
        p_assertion_key := 'r6b', p_status := 'candidate', p_basis := 'assumed'
    );

    -- Another author's candidate, with the write path forged by hand.
    v_failed := false;
    BEGIN
        PERFORM set_config('app.write_path', 'supersede_assertion', true);
        PERFORM set_config('app.supersede_assertion_id', v_alpha::text, true);
        UPDATE assertions SET superseded_at = now() WHERE id = v_alpha;
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
    END;
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.supersede_assertion_id', '', true);

    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT superseded_at FROM assertions WHERE id = v_alpha) IS NOT NULL THEN
        RAISE EXCEPTION
            'a raw UPDATE with a forged write path closed another author''s candidate';
    END IF;

    -- Anti-vacuity: the same raw shape on its OWN candidate goes through, so
    -- this proves the authority guard and not a policy that blocks every raw
    -- update.
    PERFORM set_config('app.current_role', 'agent:beta', true);
    PERFORM set_config('app.write_path', 'supersede_assertion', true);
    PERFORM set_config('app.supersede_assertion_id', v_beta::text, true);
    UPDATE assertions SET superseded_at = now() WHERE id = v_beta;
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.supersede_assertion_id', '', true);

    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT superseded_at FROM assertions WHERE id = v_beta) IS NULL THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: the raw rejection shape does not work even on the caller''s own candidate';
    END IF;
    RAISE NOTICE 'PASS 43.6: the raw rejection route is bound by the same rule';
END
$$;

-- ---------------------------------------------------------------------------
-- Owner step: seed the two rows that need a trigger switched off. The suite
-- role is not the table owner under scripts/conformance.sh.
-- ---------------------------------------------------------------------------
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
RESET ROLE;
ALTER TABLE rye.assertions DISABLE TRIGGER trg_assertion_authorship_stamp;
ALTER TABLE rye.edges DISABLE TRIGGER trg_edges_classification_check;
SET ROLE :"suite_role";

DO $$
DECLARE
    v_hist  uuid;
    v_p1    uuid;
    v_p2    uuid;
    v_subj  uuid := (SELECT v FROM t43 WHERE k = 'subject')::uuid;
    v_unatt uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO assertions (
        assertion_type, assertion_key, status, basis, subject_node_id, claim
    ) VALUES (
        'reject_probe', 'r7', 'candidate', 'assumed', v_subj, '{"value":"no author"}'
    ) RETURNING id INTO v_unatt;
    INSERT INTO t43 VALUES ('unattributed', v_unatt::text);

    INSERT INTO nodes (node_type, label, attrs) VALUES
        ('thing', 'Edge Mark Endpoint One', '{"classification":"public"}')
    RETURNING id INTO v_p1;
    INSERT INTO nodes (node_type, label, attrs) VALUES
        ('thing', 'Edge Mark Endpoint Two', '{"classification":"public"}')
    RETURNING id INTO v_p2;
    INSERT INTO t43 VALUES ('p1', v_p1::text), ('p2', v_p2::text);

    -- The historical shape the trigger would refuse today: teams, no
    -- classification.
    INSERT INTO edges (edge_type, source_id, target_id, attrs)
    VALUES ('relates_to', v_p1, v_p2, '{"teams":["locked"]}')
    RETURNING id INTO v_hist;
    INSERT INTO t43 VALUES ('historical_edge', v_hist::text);
END
$$;

SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
RESET ROLE;
ALTER TABLE rye.assertions ENABLE TRIGGER trg_assertion_authorship_stamp;
ALTER TABLE rye.edges ENABLE TRIGGER trg_edges_classification_check;
SET ROLE :"suite_role";

-- ---------------------------------------------------------------------------
-- 43.7 An unattributed row is closed by people only.
-- 43.14 The historical edge is disclosed, not hidden, and one write repairs it.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_failed boolean;
    v_hist   uuid := (SELECT v FROM t43 WHERE k = 'historical_edge')::uuid;
    v_msg    text;
    v_role   text;
    v_rows   int;
    v_unatt  uuid := (SELECT v FROM t43 WHERE k = 'unattributed')::uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_teams', '', true);

    IF (SELECT attrs ? 'recorded_by' FROM assertions WHERE id = v_unatt) THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: the seeded row carries an author, so 43.7 proves nothing';
    END IF;

    FOREACH v_role IN ARRAY ARRAY['agent:alpha', 'agent:beta'] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_failed := false;
        BEGIN
            PERFORM reject_candidate(v_unatt, 'closing a row with no author');
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'role "%" closed an unattributed suggestion', v_role;
        END IF;
        IF v_msg NOT LIKE '%may close only its own%' THEN
            RAISE EXCEPTION 'role "%" was refused the unattributed row for the wrong reason: %',
                v_role, v_msg;
        END IF;
        PERFORM set_config('app.current_role', 'admin', true);
        IF (SELECT superseded_at FROM assertions WHERE id = v_unatt) IS NOT NULL THEN
            RAISE EXCEPTION 'role "%" closed the unattributed suggestion after all', v_role;
        END IF;
    END LOOP;

    PERFORM set_config('app.current_role', 'team_member', true);
    PERFORM reject_candidate(v_unatt, 'a person closes a row nobody is recorded for');
    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT superseded_at FROM assertions WHERE id = v_unatt) IS NULL THEN
        RAISE EXCEPTION 'a person could not close an unattributed suggestion';
    END IF;
    RAISE NOTICE 'PASS 43.7: unknown authorship is not own authorship';

    -- 43.14. The stated limit: history is not rewritten.
    PERFORM set_config('app.current_role', 'viewer', true);
    SELECT count(*) INTO v_rows FROM edges WHERE id = v_hist;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION
            'the historical team-marked edge with no classification is not readable by viewer; the rule was applied to history';
    END IF;

    -- The repairing session keeps the team it is about to require, because an
    -- UPDATE's new row is checked against the SELECT policy: a session cannot
    -- mark a row out of its own sight. `nodes` has behaved this way since
    -- 0003, and the edge rule inherits it.
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_teams', 'locked', true);
    UPDATE edges SET attrs = attrs || '{"classification":"confidential"}'::jsonb
    WHERE id = v_hist;
    PERFORM set_config('app.current_teams', '', true);

    PERFORM set_config('app.current_role', 'viewer', true);
    SELECT count(*) INTO v_rows FROM edges WHERE id = v_hist;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'the repaired edge is still readable by viewer';
    END IF;
    PERFORM set_config('app.current_role', 'admin', true);
    RAISE NOTICE 'PASS 43.14: an unmarked historical edge stays readable and one write repairs it';
END
$$;

-- ---------------------------------------------------------------------------
-- 43.10 to 43.13 An edge carries its own classification.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_edge_assertion uuid;
    v_failed boolean;
    v_marked uuid;
    v_msg    text;
    v_ok     uuid;
    v_p1     uuid := (SELECT v FROM t43 WHERE k = 'p1')::uuid;
    v_p2     uuid := (SELECT v FROM t43 WHERE k = 'p2')::uuid;
    v_role   text;
    v_rows   int;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_teams', 'locked', true);

    INSERT INTO edges (edge_type, source_id, target_id, attrs)
    VALUES ('blocks', v_p1, v_p2,
            '{"classification":"confidential","teams":["locked"]}')
    RETURNING id INTO v_marked;
    INSERT INTO t43 VALUES ('marked_edge', v_marked::text);

    SELECT count(*) INTO v_rows FROM edges WHERE id = v_marked;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: the marked edge is not readable even with the team';
    END IF;

    v_edge_assertion := record_assertion(
        'reject_probe', '{"value":"about a marked edge"}',
        p_subject_edge_id := v_marked,
        p_assertion_key := 'edge_mark', p_status := 'candidate', p_basis := 'assumed'
    );
    SELECT count(*) INTO v_rows FROM assertions WHERE id = v_edge_assertion;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: the assertion about the marked edge is invisible to its own writer';
    END IF;

    -- ==================================================================
    -- 43.10 and 43.11. Every refused session shape, with the endpoints
    -- visible so the refusal is about the edge and not about its ends.
    -- ==================================================================
    PERFORM set_config('app.current_teams', '', true);
    FOREACH v_role IN ARRAY ARRAY['viewer', '', 'team_member'] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF v_role = 'team_member' THEN
            PERFORM set_config('app.current_teams', 'another_team', true);
        ELSE
            PERFORM set_config('app.current_teams', '', true);
        END IF;

        SELECT count(*) INTO v_rows FROM nodes WHERE id IN (v_p1, v_p2);
        IF v_rows <> 2 THEN
            RAISE EXCEPTION
                'Refusing to pass vacuously: role "%" cannot see both endpoints, so hiding the edge proves nothing',
                v_role;
        END IF;

        SELECT count(*) INTO v_rows FROM edges WHERE id = v_marked;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'role "%" read an edge marked confidential', v_role;
        END IF;

        SELECT count(*) INTO v_rows FROM assertions WHERE id = v_edge_assertion;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION
                'role "%" read an assertion whose subject is a hidden edge', v_role;
        END IF;

        -- 43.12. Traversal inherits, with no path through the hidden edge.
        SELECT count(*) INTO v_rows FROM find_paths(v_p1, v_p2, p_max_depth := 2);
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'find_paths walked a hidden edge for role "%"', v_role;
        END IF;
        IF jsonb_array_length(
               neighborhood(v_p1, p_max_depth := 2, p_max_nodes := 50)->'edges'
           ) <> 0
        THEN
            RAISE EXCEPTION 'neighborhood returned a hidden edge for role "%"', v_role;
        END IF;
    END LOOP;

    -- The team session sees all of it.
    PERFORM set_config('app.current_role', 'team_member', true);
    PERFORM set_config('app.current_teams', 'locked', true);
    SELECT count(*) INTO v_rows FROM edges WHERE id = v_marked;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'the team session cannot read the edge its team is named on';
    END IF;
    SELECT count(*) INTO v_rows FROM assertions WHERE id = v_edge_assertion;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'the team session cannot read the assertion about that edge';
    END IF;
    SELECT count(*) INTO v_rows FROM find_paths(v_p1, v_p2, p_max_depth := 2);
    IF v_rows < 1 THEN
        RAISE EXCEPTION 'the team session cannot walk the edge its team is named on';
    END IF;
    IF jsonb_array_length(
           neighborhood(v_p1, p_max_depth := 2, p_max_nodes := 50)->'edges'
       ) < 1
    THEN
        RAISE EXCEPTION 'neighborhood lost the edge for the team session';
    END IF;

    -- A grant is the other way in. resource_type 'edge' needs no constraint
    -- change, and the grant is scoped by edge_id.
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_teams', 'locked', true);
    INSERT INTO access_grants (grantee, grant_type, resource_type, access_level, scope, active)
    VALUES ('edge_grant_reader', 'role', 'edge', 'read',
            jsonb_build_object('edge_id', v_marked::text), true);

    PERFORM set_config('app.current_role', 'edge_grant_reader', true);
    PERFORM set_config('app.current_teams', '', true);
    SELECT count(*) INTO v_rows FROM edges WHERE id = v_marked;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'an active edge grant scoped by edge_id does not open the edge';
    END IF;
    RAISE NOTICE 'PASS 43.10, 43.11, 43.12: a marked edge, its assertions and its paths follow the edge''s own mark';

    -- ==================================================================
    -- 43.13 Teams on an edge require a classification, on INSERT and on
    -- UPDATE, for an admin and for a writing role alike.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_teams', '', true);
    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('mentions', v_p1, v_p2)
    RETURNING id INTO v_ok;

    FOREACH v_role IN ARRAY ARRAY['admin', 'team_member'] LOOP
        PERFORM set_config('app.current_role', v_role, true);

        v_failed := false;
        BEGIN
            INSERT INTO edges (edge_type, source_id, target_id, attrs)
            VALUES ('mentions', v_p1, v_p2, '{"teams":["locked"]}');
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'role "%" inserted a team-marked edge with no classification', v_role;
        END IF;
        IF v_msg NOT LIKE '%Edges with teams must have classification%' THEN
            RAISE EXCEPTION 'role "%" was refused the team-marked edge for the wrong reason: %',
                v_role, v_msg;
        END IF;

        v_failed := false;
        BEGIN
            UPDATE edges SET attrs = '{"teams":["locked"]}'::jsonb WHERE id = v_ok;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'role "%" put teams on an edge with no classification by UPDATE', v_role;
        END IF;
        IF v_msg NOT LIKE '%Edges with teams must have classification%' THEN
            RAISE EXCEPTION 'role "%" was refused the team-marked UPDATE for the wrong reason: %',
                v_role, v_msg;
        END IF;

        PERFORM set_config('app.current_role', 'admin', true);
        IF (SELECT attrs ? 'teams' FROM edges WHERE id = v_ok) THEN
            RAISE EXCEPTION 'role "%" left teams on an unclassified edge', v_role;
        END IF;
    END LOOP;

    -- The same write with a classification is accepted. The writer holds the
    -- team it is about to require, because an UPDATE's new row is checked
    -- against the SELECT policy too.
    PERFORM set_config('app.current_role', 'team_member', true);
    PERFORM set_config('app.current_teams', 'locked', true);
    UPDATE edges SET attrs = '{"classification":"internal","teams":["locked"]}'::jsonb
    WHERE id = v_ok;
    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT attrs->>'classification' FROM edges WHERE id = v_ok) <> 'internal' THEN
        RAISE EXCEPTION 'a team-marked edge with a classification was refused';
    END IF;
    RAISE NOTICE 'PASS 43.13: teams on an edge require a classification';

    PERFORM set_config('app.current_teams', '', true);
END
$$;

-- ---------------------------------------------------------------------------
-- 43.15 Nothing else moved.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_order  text[];
    v_plain  uuid;
    v_p1     uuid := (SELECT v FROM t43 WHERE k = 'p1')::uuid;
    v_p2     uuid := (SELECT v FROM t43 WHERE k = 'p2')::uuid;
    v_role   text;
    v_rows   int;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_teams', '', true);

    -- The settle gate still sorts before every guard that can refuse, so
    -- tests/conformance/30_configuration_gate.sql keeps its message. The
    -- authorship stamp sorts ahead of it and never raises, which is why that
    -- is still true.
    SELECT array_agg(t.tgname ORDER BY t.tgname)
    INTO v_order
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'rye' AND c.relname = 'assertions' AND NOT t.tgisinternal;

    IF array_position(v_order, 'trg_assertion_authorship_stamp')
       > array_position(v_order, 'trg_assertion_settle_gate')
    THEN
        RAISE EXCEPTION 'the authorship stamp no longer sorts before the settle gate';
    END IF;
    IF array_position(v_order, 'trg_assertion_settle_gate')
       > array_position(v_order, 'trg_assertions_gate_may_write')
       OR array_position(v_order, 'trg_assertion_settle_gate')
          > array_position(v_order, 'trg_assertions_immutable')
       OR array_position(v_order, 'trg_assertion_settle_gate')
          > array_position(v_order, 'trg_assertions_reject_authority')
    THEN
        RAISE EXCEPTION 'the settle gate no longer sorts first among the guards on assertions';
    END IF;
    IF array_position(v_order, 'trg_assertions_reject_authority')
       < array_position(v_order, 'trg_assertions_immutable')
       OR array_position(v_order, 'trg_assertions_reject_authority')
          < array_position(v_order, 'trg_assertions_gate_may_write')
    THEN
        RAISE EXCEPTION 'the rejection authority guard sorts before an existing guard';
    END IF;

    -- An ordinary unmarked edge reads exactly as it did before.
    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('relates_to', v_p1, v_p2)
    RETURNING id INTO v_plain;

    FOREACH v_role IN ARRAY ARRAY['admin', 'team_member', 'viewer',
                                  'agent:alpha', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        SELECT count(*) INTO v_rows FROM edges WHERE id = v_plain;
        IF v_rows <> 1 THEN
            RAISE EXCEPTION 'role "%" lost an ordinary unmarked edge', v_role;
        END IF;
    END LOOP;

    PERFORM set_config('app.current_role', 'admin', true);
    RAISE NOTICE 'PASS 43.15: trigger order holds and an unmarked edge is readable as before';

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
END
$$;

-- ---------------------------------------------------------------------------
-- 43.16 A suggestion demoted under a pre-gate alias is configuration too.
--
-- 0036 demotes a write whose WRITTEN name is settle-gated even where the
-- stored (canonical) type is not, and marks the row `attrs.settle_gate`
-- with the allowed roles and the spelling that gated it. Its own guard reads
-- that marker when it refuses acceptance. The rejection rule reads it for the
-- same reason: closing such a suggestion is deciding it, and a role the
-- demotion excluded must not be able to make sure it never reaches an admin.
--
-- The author may still withdraw its own, which is the correction route.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_alias   uuid;
    v_core    uuid;
    v_failed  boolean;
    v_m1      uuid;
    v_m2      uuid;
    v_msg     text;
    v_roles   text[];
    v_row     assertions;
    v_subject uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_teams', '', true);

    SELECT id INTO v_core FROM nodes
    WHERE external_source = 'rye_registry' AND external_id = 'core' AND archived_at IS NULL;

    SELECT allowed_roles INTO v_roles FROM assertion_type_access
    WHERE assertion_type = 'review_policy' AND operation = 'settle';
    IF v_roles IS NULL THEN
        RAISE EXCEPTION 'Premise broken: review_policy is not settle-gated on this instance';
    END IF;

    -- The alias is recorded in the window before the type was gated, which is
    -- the only window in which it can be recorded at all. Same fixture as
    -- tests/conformance/42_leftovers.sql.
    DELETE FROM assertion_type_access
    WHERE assertion_type = 'review_policy' AND operation = 'settle';
    v_alias := record_assertion(
        'registry_entry', '{"value":"reject_probe_policy_note"}', v_core,
        p_assertion_key := 'type_alias:assertion_type:review_policy',
        p_status := 'accepted', p_basis := 'assumed'
    );
    INSERT INTO assertion_type_access (assertion_type, operation, allowed_roles)
    VALUES ('review_policy', 'settle', v_roles);

    IF canonical_type('assertion_type', 'review_policy') = 'review_policy' THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: review_policy still canonicalizes to itself, so no alias stands';
    END IF;
    IF assertion_settle_roles(canonical_type('assertion_type', 'review_policy')) IS NOT NULL THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: the alias target is itself gated, so the type lookup would catch it';
    END IF;

    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Reject Marker Subject One')
    RETURNING id INTO v_subject;

    PERFORM set_config('app.current_role', 'agent:alpha', true);
    v_m1 := record_assertion(
        'review_policy', '{"review_policy":"open"}', v_subject,
        p_assertion_key := 'default', p_status := 'accepted', p_basis := 'assumed'
    );
    SELECT * INTO v_row FROM assertions WHERE id = v_m1;
    IF v_row.status <> 'candidate'
       OR NOT (v_row.attrs->'settle_gate'->'allowed_roles' @> '["admin"]'::jsonb)
       OR v_row.attrs->'settle_gate'->>'gated_as' IS DISTINCT FROM 'review_policy'
    THEN
        RAISE EXCEPTION
            'Premise broken: the demotion under the pre-gate alias landed % with settle_gate %',
            v_row.status, v_row.attrs->'settle_gate';
    END IF;
    IF assertion_settle_roles(v_row.assertion_type) IS NOT NULL THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: the stored type % is itself gated, so the marker decides nothing',
            v_row.assertion_type;
    END IF;
    IF v_row.attrs->>'recorded_by' IS DISTINCT FROM 'agent:alpha' THEN
        RAISE EXCEPTION 'Premise broken: the marked suggestion is not attributed to agent:alpha';
    END IF;

    -- A second one, identical, so the admin case has a live row of its own.
    PERFORM set_config('app.current_role', 'agent:alpha', true);
    v_m2 := record_assertion(
        'review_policy', '{"review_policy":"candidates_only"}', v_subject,
        p_assertion_key := 'second', p_status := 'accepted', p_basis := 'assumed'
    );

    -- team_member: a writing role the demotion excluded. Refused.
    PERFORM set_config('app.current_role', 'team_member', true);
    v_failed := false;
    BEGIN
        PERFORM reject_candidate(v_m1, 'closing a marked configuration suggestion');
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        v_msg := SQLERRM;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION
            'team_member closed a suggestion carrying attrs.settle_gate that names only %',
            v_roles;
    END IF;
    IF v_msg NOT LIKE '%Rye configuration%' THEN
        RAISE EXCEPTION 'the marked suggestion refusal had the wrong reason: %', v_msg;
    END IF;

    -- Another agent is refused too: it is neither allowed nor the author.
    PERFORM set_config('app.current_role', 'agent:beta', true);
    v_failed := false;
    BEGIN
        PERFORM reject_candidate(v_m1, 'another agent closing it');
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'agent:beta closed a marked configuration suggestion it did not write';
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT superseded_at FROM assertions WHERE id = v_m1) IS NOT NULL THEN
        RAISE EXCEPTION 'a refused caller closed the marked suggestion after all';
    END IF;

    -- The author withdraws its own: the correction route.
    PERFORM set_config('app.current_role', 'agent:alpha', true);
    PERFORM reject_candidate(v_m1, 'the author withdraws its own marked suggestion');
    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT superseded_at FROM assertions WHERE id = v_m1) IS NULL THEN
        RAISE EXCEPTION 'the authoring agent could not withdraw its own marked suggestion';
    END IF;

    -- An allowed role decides the other one.
    PERFORM reject_candidate(v_m2, 'an admin decides the marked suggestion');
    IF (SELECT superseded_at FROM assertions WHERE id = v_m2) IS NULL THEN
        RAISE EXCEPTION 'an admin could not close a marked configuration suggestion';
    END IF;

    RAISE NOTICE 'PASS 43.16: a suggestion carrying attrs.settle_gate is closed by its allowed roles or by its author';

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
END
$$;

ROLLBACK;
