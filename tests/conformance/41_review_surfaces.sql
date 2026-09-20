-- The reviewer's screen gets what it needs from the views.
--
-- Work item: work/016-admin-view-layer.md. Closes issue 12.
-- Contract:  contracts/sql-surface.md, "Review surfaces".
-- Decision:  docs/decisions/0012-review-surfaces-carry-what-the-screen-needs.md,
--            numbered obligations 41.1 to 41.12.
-- Migrations: schema/migrations/0035_review_surfaces.sql (core),
--            schema/migrations/0125_profile_crm_matview_freshness.sql (crm).
--
-- Negative control: without 0035 the suite fails at the object survey below,
-- before any fixture is written. Without 0125 on a crm install it fails at
-- the same survey's profile branch. On a pm-only install the matview
-- obligations are skipped by name and the rest still run.
--
-- Vacuity: the suite refuses to run as a role that bypasses RLS, refuses a
-- session with row_security off, reads every role back after setting it, and
-- asserts the existence of every object it tests before testing it.
--
-- The matview obligations (41.11, 41.12) need more than one transaction,
-- because now() is the transaction's start instant and "a refresh advanced
-- the snapshot" cannot be observed inside the transaction that refreshed.
-- They commit one fixture opportunity, marked external_source
-- 'conformance:v2' so tests/scenarios/01_sales_pipeline.sql's counts exclude
-- it, and they are the only part of this file that commits.
--
-- Invented names only: Brannock, Halloway, Corvin, Ashgrove, Dunmore,
-- Meridian, Tamsin, Wren.

SET search_path = rye, public, pg_catalog;

-- ==========================================================================
-- Anti-vacuity and the object survey. Both run outside the fixture
-- transaction so a missing object fails at the top.
-- ==========================================================================
DO $$
DECLARE
    v_bypass boolean;
    v_missing text[] := '{}'::text[];
    v_name text;
    v_role text;
    v_super boolean;
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

    FOREACH v_role IN ARRAY ARRAY['team_member', 'viewer', '', 'admin'] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION
                'Refusing to pass vacuously: app.current_role did not read back as "%", it reads "%"',
                v_role, current_setting('app.current_role', true);
        END IF;
    END LOOP;
    PERFORM set_config('app.current_role', 'admin', true);

    -- 0035's objects, by name, so the negative control fails here.
    FOREACH v_name IN ARRAY ARRAY[
        'rye.candidate_assertions_weighted',
        'rye.review_queue',
        'rye.review_queue_candidates',
        'rye.competing_candidates',
        'rye.rejected_candidates',
        'rye.stale_digests'
    ] LOOP
        IF to_regclass(v_name) IS NULL THEN
            v_missing := array_append(v_missing, v_name);
        END IF;
    END LOOP;
    FOREACH v_name IN ARRAY ARRAY[
        'rye.base_effective_confidence_unchecked(rye.assertions)',
        'rye.base_effective_confidence(rye.assertions)',
        'rye.projected_effective_confidence(rye.assertions)',
        'rye.effective_confidence(rye.assertions)'
    ] LOOP
        IF to_regprocedure(v_name) IS NULL THEN
            v_missing := array_append(v_missing, v_name);
        END IF;
    END LOOP;
    IF cardinality(v_missing) > 0 THEN
        RAISE EXCEPTION
            'Migration 0035 is not applied: missing %', array_to_string(v_missing, ', ');
    END IF;

    -- Every one of them is security_invoker, and none is a SECURITY DEFINER
    -- reader wearing a view's clothes.
    FOREACH v_name IN ARRAY ARRAY[
        'candidate_assertions_weighted', 'review_queue', 'review_queue_candidates',
        'competing_candidates', 'rejected_candidates', 'stale_digests'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'rye' AND c.relname = v_name
              AND 'security_invoker=true' = ANY(coalesce(c.reloptions, '{}'::text[]))
        ) THEN
            RAISE EXCEPTION 'View rye.% is not security_invoker', v_name;
        END IF;
    END LOOP;

    -- The crm branch. Absent profile is skipped by name; present profile
    -- without 0125 fails loudly rather than skipping.
    IF to_regclass('rye.opportunities_active') IS NULL THEN
        RAISE NOTICE '41: crm profile is not installed; obligations 41.11 and 41.12 are skipped.';
    ELSE
        -- information_schema.columns does not list materialized views, so
        -- this one reads pg_attribute.
        IF NOT EXISTS (
            SELECT 1 FROM pg_attribute
            WHERE attrelid = to_regclass('rye.opportunities_active')
              AND attname = 'snapshot_at' AND attnum > 0 AND NOT attisdropped
        ) THEN
            RAISE EXCEPTION
                'The crm profile is installed but opportunities_active has no snapshot_at: migration 0125 is missing';
        END IF;
        IF to_regclass('rye.opportunities_active_freshness') IS NULL THEN
            RAISE EXCEPTION
                'The crm profile is installed but rye.opportunities_active_freshness is missing: migration 0125 is missing';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'rye' AND c.relname = 'opportunities_active_freshness'
              AND 'security_invoker=true' = ANY(coalesce(c.reloptions, '{}'::text[]))
        ) THEN
            RAISE EXCEPTION 'View rye.opportunities_active_freshness is not security_invoker';
        END IF;
    END IF;
END
$$;

-- ==========================================================================
-- 41.8 Existing columns did not move, and 41.9 competing_candidates
-- inherited the appended ones. Catalog-only, so they need no fixture.
-- ==========================================================================
DO $$
DECLARE
    v_expected text[];
    v_types text[];
    v_i int;
    v_got text;
    v_got_type text;
BEGIN
    -- 41.8, review_queue and competing_candidates: 0018's seven columns, in
    -- 0018's positions, with 0018's types.
    v_expected := ARRAY['subject_ref', 'subject_node_id', 'subject_edge_id',
                        'assertion_type', 'assertion_key', 'candidate_count',
                        'candidates'];
    v_types := ARRAY['text', 'uuid', 'uuid', 'text', 'text', 'bigint', 'jsonb'];
    FOR v_i IN 1..cardinality(v_expected) LOOP
        SELECT column_name, data_type INTO v_got, v_got_type
        FROM information_schema.columns
        WHERE table_schema = 'rye' AND table_name = 'review_queue'
          AND ordinal_position = v_i;
        IF v_got IS DISTINCT FROM v_expected[v_i] OR v_got_type IS DISTINCT FROM v_types[v_i] THEN
            RAISE EXCEPTION
                '41.8: review_queue column % is %/%, expected %/%',
                v_i, v_got, v_got_type, v_expected[v_i], v_types[v_i];
        END IF;
    END LOOP;

    -- 41.8, stale_digests: 0018's nine columns, likewise.
    v_expected := ARRAY['digest_assertion_id', 'subject_ref', 'subject_node_id',
                        'subject_edge_id', 'assertion_key', 'watermark',
                        'newer_subject_assertion', 'overturned_source',
                        'salience_score'];
    FOR v_i IN 1..cardinality(v_expected) LOOP
        SELECT column_name INTO v_got
        FROM information_schema.columns
        WHERE table_schema = 'rye' AND table_name = 'stale_digests'
          AND ordinal_position = v_i;
        IF v_got IS DISTINCT FROM v_expected[v_i] THEN
            RAISE EXCEPTION
                '41.8: stale_digests column % is %, expected %', v_i, v_got, v_expected[v_i];
        END IF;
    END LOOP;

    -- The new columns come after, in the contract's order.
    v_expected := ARRAY['subject_label', 'subject_node_type', 'newest_candidate_at',
                        'incumbent_assertion_id', 'incumbent_claim', 'incumbent_basis',
                        'incumbent_confidence', 'incumbent_effective_confidence',
                        'incumbent_asserted_at', 'incumbent_attrs',
                        'incumbent_is_current', 'waiting_reason', 'waiting_detail'];
    FOR v_i IN 1..cardinality(v_expected) LOOP
        SELECT column_name INTO v_got
        FROM information_schema.columns
        WHERE table_schema = 'rye' AND table_name = 'review_queue'
          AND ordinal_position = 7 + v_i;
        IF v_got IS DISTINCT FROM v_expected[v_i] THEN
            RAISE EXCEPTION
                '41.8: review_queue appended column % is %, expected %',
                7 + v_i, v_got, v_expected[v_i];
        END IF;
    END LOOP;

    v_expected := ARRAY['newer_assertion_ids', 'newer_latest_asserted_at',
                        'overturned_source_assertion_ids'];
    FOR v_i IN 1..cardinality(v_expected) LOOP
        SELECT column_name INTO v_got
        FROM information_schema.columns
        WHERE table_schema = 'rye' AND table_name = 'stale_digests'
          AND ordinal_position = 9 + v_i;
        IF v_got IS DISTINCT FROM v_expected[v_i] THEN
            RAISE EXCEPTION
                '41.8: stale_digests appended column % is %, expected %',
                9 + v_i, v_got, v_expected[v_i];
        END IF;
    END LOOP;

    -- 41.9: competing_candidates exposes exactly review_queue's columns, at
    -- the same positions. A dependent view keeps its own expanded column
    -- list, so this fails whenever review_queue is replaced and it is not.
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns rq
        FULL JOIN information_schema.columns cc
          ON cc.table_schema = 'rye' AND cc.table_name = 'competing_candidates'
         AND cc.ordinal_position = rq.ordinal_position
        WHERE rq.table_schema = 'rye' AND rq.table_name = 'review_queue'
          AND (cc.column_name IS DISTINCT FROM rq.column_name
               OR cc.data_type IS DISTINCT FROM rq.data_type)
    ) THEN
        RAISE EXCEPTION
            '41.9: competing_candidates does not expose review_queue''s columns at the same positions';
    END IF;
    IF (SELECT count(*) FROM information_schema.columns
        WHERE table_schema = 'rye' AND table_name = 'competing_candidates')
       <> (SELECT count(*) FROM information_schema.columns
           WHERE table_schema = 'rye' AND table_name = 'review_queue')
    THEN
        RAISE EXCEPTION '41.9: competing_candidates has a different column count';
    END IF;
END
$$;

-- ==========================================================================
-- Fixtures and obligations 41.1 to 41.7 and 41.10. One transaction, rolled
-- back: nothing here is left behind.
-- ==========================================================================
BEGIN;

CREATE TEMP TABLE t41 (k text PRIMARY KEY, id uuid) ON COMMIT DROP;

DO $$
DECLARE
    v_event uuid;
    v_id uuid;
    v_node uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:review-surfaces', true);
    PERFORM set_config('app.current_teams', '', true);

    -- Subjects. external_source 'conformance:v2' keeps the scenario suites'
    -- counts unchanged even though this transaction rolls back.
    INSERT INTO nodes (node_type, label, external_id, external_source)
    VALUES ('org', 'Brannock Freight', gen_random_uuid()::text, 'conformance:v2')
    RETURNING id INTO v_node;
    INSERT INTO t41 VALUES ('node_plain', v_node);

    INSERT INTO nodes (node_type, label, external_id, external_source)
    VALUES ('org', 'Halloway Group', gen_random_uuid()::text, 'conformance:v2')
    RETURNING id INTO v_node;
    INSERT INTO t41 VALUES ('node_incumbent', v_node);

    INSERT INTO nodes (node_type, label, external_id, external_source)
    VALUES ('org', 'Corvin Mill', gen_random_uuid()::text, 'conformance:v2')
    RETURNING id INTO v_node;
    INSERT INTO t41 VALUES ('node_two', v_node);

    INSERT INTO nodes (node_type, label, external_id, external_source)
    VALUES ('org', 'Ashgrove Depot', gen_random_uuid()::text, 'conformance:v2')
    RETURNING id INTO v_node;
    INSERT INTO t41 VALUES ('node_lone', v_node);

    INSERT INTO nodes (node_type, label, external_id, external_source)
    VALUES ('org', 'Dunmore Partners', gen_random_uuid()::text, 'conformance:v2')
    RETURNING id INTO v_node;
    INSERT INTO t41 VALUES ('node_classified', v_node);

    -- A node nobody outside the team may read. Both branches of RLS silence
    -- hang off this one: a candidate on it, and evidence witnessed by it.
    -- INSERT ... RETURNING applies the SELECT policy to the new row, so the
    -- writer has to be on the team to write it at all.
    PERFORM set_config('app.current_teams', 'suite41-vault', true);
    INSERT INTO nodes (node_type, label, external_id, external_source, attrs)
    VALUES ('org', 'Wren Vault Records', gen_random_uuid()::text, 'conformance:v2',
            '{"classification":"confidential","teams":["suite41-vault"]}')
    RETURNING id INTO v_node;
    INSERT INTO t41 VALUES ('node_hidden', v_node);
    PERFORM set_config('app.current_teams', '', true);

    v_event := record_event(
        p_event_type := 'meeting',
        p_summary := 'Suite 41 fixture call',
        p_participant_ids := ARRAY[(SELECT id FROM t41 WHERE k = 'node_plain')],
        p_participant_roles := ARRAY['regarding'],
        p_actor := 'test:review-surfaces'
    );
    INSERT INTO t41 VALUES ('event', v_event);

    -- Preconditions. Nothing governs the plain subjects, so a plainly
    -- recorded candidate is a plainly recorded candidate.
    IF scope_review_policy(governing_scope(
           (SELECT id FROM t41 WHERE k = 'node_plain'), NULL, 'service_tier', NULL)) <> 'open'
    THEN
        RAISE EXCEPTION
            '41 precondition: a scope already governs the plain fixture subject (%)',
            scope_review_policy(governing_scope(
                (SELECT id FROM t41 WHERE k = 'node_plain'), NULL, 'service_tier', NULL));
    END IF;

    -- 41.1's candidate: live, plainly recorded, confidence 0.70.
    v_id := record_assertion(
        'service_tier', '{"tier":"gold"}', (SELECT id FROM t41 WHERE k = 'node_plain'),
        p_assertion_key := 'suite41:basic', p_confidence := 0.70,
        p_status := 'candidate', p_basis := 'assumed'
    );
    INSERT INTO t41 VALUES ('cand_plain', v_id);
END
$$;

-- --------------------------------------------------------------------------
-- 41.1 A candidate projects a number, and effective_confidence() still does
--      not. The second half is the anti-vacuity: it proves the new function
--      and not a changed fixture.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_cand uuid := (SELECT id FROM t41 WHERE k = 'cand_plain');
    v_eff numeric;
    v_proj numeric;
    v_weighted numeric;
BEGIN
    SELECT effective_confidence(ROW(a.*)::assertions) INTO v_eff
    FROM assertions a WHERE a.id = v_cand;
    IF v_eff IS NOT NULL THEN
        RAISE EXCEPTION
            '41.1 anti-vacuity: effective_confidence() answered % for a candidate; the fixture is not a candidate',
            v_eff;
    END IF;

    SELECT projected_effective_confidence INTO v_proj
    FROM review_queue_candidates WHERE assertion_id = v_cand;
    IF v_proj IS NULL THEN
        RAISE EXCEPTION '41.1: review_queue_candidates projected no confidence for a live candidate';
    END IF;

    SELECT projected_effective_confidence INTO v_weighted
    FROM candidate_assertions_weighted WHERE id = v_cand;
    IF v_weighted IS NULL OR v_weighted IS DISTINCT FROM v_proj THEN
        RAISE EXCEPTION
            '41.1: candidate_assertions_weighted says %, review_queue_candidates says %',
            v_weighted, v_proj;
    END IF;

    -- A superseded row is not live and projects nothing.
    IF (SELECT projected_effective_confidence(ROW(a.*)::assertions)
        FROM assertions a WHERE a.superseded_at IS NOT NULL LIMIT 1) IS NOT NULL
    THEN
        RAISE EXCEPTION '41.1: a superseded assertion projected a confidence';
    END IF;
END
$$;

-- --------------------------------------------------------------------------
-- 41.2 The projection agrees with effective_confidence() on every accepted
--      row. This is what keeps the two functions one piece of arithmetic.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_disagreements int;
    v_nonnull int;
    v_rows int;
BEGIN
    SELECT count(*),
           count(*) FILTER (WHERE effective_confidence(ROW(a.*)::assertions) IS NOT NULL),
           count(*) FILTER (
               WHERE projected_effective_confidence(ROW(a.*)::assertions)
                     IS DISTINCT FROM effective_confidence(ROW(a.*)::assertions)
           )
    INTO v_rows, v_nonnull, v_disagreements
    FROM current_valid_assertions a;

    IF v_rows < 3 THEN
        RAISE EXCEPTION
            '41.2 anti-vacuity: current_valid_assertions returned % rows', v_rows;
    END IF;
    IF v_nonnull < 1 THEN
        RAISE EXCEPTION
            '41.2 anti-vacuity: no accepted row carries an effective confidence at all';
    END IF;
    IF v_disagreements <> 0 THEN
        RAISE EXCEPTION
            '41.2: projected_effective_confidence disagrees with effective_confidence on % of % accepted rows',
            v_disagreements, v_rows;
    END IF;
END
$$;

-- --------------------------------------------------------------------------
-- 41.3 A lone candidate is not its own competitor: it projects what it will
--      carry once accepted. A second candidate on the tuple lowers both.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_after numeric;
    v_before numeric;
    v_c1 uuid;
    v_c2 uuid;
    v_lone uuid;
    v_p1 numeric;
    v_p1_alone numeric;
    v_p2 numeric;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    v_lone := record_assertion(
        'service_tier', '{"tier":"silver"}', (SELECT id FROM t41 WHERE k = 'node_lone'),
        p_assertion_key := 'default', p_confidence := 0.70,
        p_status := 'candidate', p_basis := 'assumed'
    );
    SELECT projected_effective_confidence(ROW(a.*)::assertions) INTO v_before
    FROM assertions a WHERE a.id = v_lone;

    PERFORM accept_assertion(v_lone, p_reason := 'Suite 41 projection check');

    SELECT effective_confidence(ROW(a.*)::assertions) INTO v_after
    FROM assertions a WHERE a.id = v_lone;

    IF v_before IS NULL OR v_after IS NULL THEN
        RAISE EXCEPTION '41.3: projection % or post-acceptance value % is null', v_before, v_after;
    END IF;
    IF round(v_before, 6) <> round(v_after, 6) THEN
        RAISE EXCEPTION
            '41.3: a lone candidate projected % and carried % once accepted', v_before, v_after;
    END IF;

    -- Two live candidates on one tuple discount each other, and neither
    -- discounts itself.
    v_c1 := record_assertion(
        'service_tier', '{"tier":"gold"}', (SELECT id FROM t41 WHERE k = 'node_two'),
        p_assertion_key := 'default', p_confidence := 0.70,
        p_status := 'candidate', p_basis := 'assumed'
    );
    SELECT projected_effective_confidence(ROW(a.*)::assertions) INTO v_p1_alone
    FROM assertions a WHERE a.id = v_c1;

    v_c2 := record_assertion(
        'service_tier', '{"tier":"bronze"}', (SELECT id FROM t41 WHERE k = 'node_two'),
        p_assertion_key := 'default', p_confidence := 0.70,
        p_status := 'candidate', p_basis := 'assumed'
    );
    SELECT projected_effective_confidence INTO v_p1 FROM review_queue_candidates WHERE assertion_id = v_c1;
    SELECT projected_effective_confidence INTO v_p2 FROM review_queue_candidates WHERE assertion_id = v_c2;

    IF v_p1 IS NULL OR v_p2 IS NULL THEN
        RAISE EXCEPTION '41.3: a competing candidate projected null (% and %)', v_p1, v_p2;
    END IF;
    IF v_p1 >= v_p1_alone OR v_p2 >= v_p1_alone THEN
        RAISE EXCEPTION
            '41.3: a second live candidate did not lower the projections (alone %, then % and %)',
            v_p1_alone, v_p1, v_p2;
    END IF;
    IF round(v_p1, 6) <> round(v_p1_alone * 0.8, 6) THEN
        RAISE EXCEPTION
            '41.3: one competitor should discount by 0.8: % became %, expected %',
            v_p1_alone, v_p1, v_p1_alone * 0.8;
    END IF;

    INSERT INTO t41 VALUES ('cand_two_a', v_c1), ('cand_two_b', v_c2);
END
$$;

-- --------------------------------------------------------------------------
-- 41.4 The queue answers without a subquery: who, against what, and why it
--      is waiting.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_cand uuid;
    v_edge uuid;
    v_gov uuid;
    v_incumbent uuid;
    v_q record;
    v_scope uuid;
    v_sg uuid;
    v_rg uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    v_incumbent := record_assertion(
        'service_tier', '{"tier":"standard"}', (SELECT id FROM t41 WHERE k = 'node_incumbent'),
        p_assertion_key := 'default', p_confidence := 0.60, p_basis := 'assumed'
    );
    v_cand := record_assertion(
        'service_tier', '{"tier":"premium"}', (SELECT id FROM t41 WHERE k = 'node_incumbent'),
        p_assertion_key := 'default', p_confidence := 0.80,
        p_status := 'candidate', p_basis := 'assumed'
    );

    SELECT * INTO v_q FROM review_queue
    WHERE subject_node_id = (SELECT id FROM t41 WHERE k = 'node_incumbent')
      AND assertion_type = 'service_tier' AND assertion_key = 'default';
    IF NOT FOUND THEN
        RAISE EXCEPTION '41.4: the tuple is not in review_queue';
    END IF;
    IF v_q.subject_label <> 'Halloway Group' OR v_q.subject_node_type <> 'org' THEN
        RAISE EXCEPTION '41.4: subject is %/%', v_q.subject_label, v_q.subject_node_type;
    END IF;
    IF v_q.incumbent_assertion_id IS DISTINCT FROM v_incumbent THEN
        RAISE EXCEPTION '41.4: incumbent is %, expected %', v_q.incumbent_assertion_id, v_incumbent;
    END IF;
    IF v_q.incumbent_claim IS DISTINCT FROM '{"tier":"standard"}'::jsonb
       OR v_q.incumbent_basis <> 'assumed'
       OR v_q.incumbent_confidence <> 0.60
       OR v_q.incumbent_effective_confidence IS NULL
       OR v_q.incumbent_asserted_at IS NULL
       OR v_q.incumbent_attrs IS NULL
       OR v_q.incumbent_is_current IS NOT TRUE
    THEN
        RAISE EXCEPTION
            '41.4: incumbent detail is claim=% basis=% confidence=% effective=% current=%',
            v_q.incumbent_claim, v_q.incumbent_basis, v_q.incumbent_confidence,
            v_q.incumbent_effective_confidence, v_q.incumbent_is_current;
    END IF;
    IF v_q.waiting_reason <> 'none' OR v_q.waiting_detail IS NOT NULL THEN
        RAISE EXCEPTION
            '41.4: a plainly recorded candidate reads waiting_reason %/%',
            v_q.waiting_reason, v_q.waiting_detail;
    END IF;
    IF v_q.newest_candidate_at IS DISTINCT FROM (SELECT asserted_at FROM assertions WHERE id = v_cand) THEN
        RAISE EXCEPTION '41.4: newest_candidate_at is not the candidate''s asserted_at';
    END IF;
    IF (SELECT incumbent_assertion_id FROM review_queue_candidates WHERE assertion_id = v_cand)
       IS DISTINCT FROM v_incumbent
    THEN
        RAISE EXCEPTION '41.4: review_queue_candidates names a different incumbent';
    END IF;

    -- Anti-vacuity: the named incumbent is the row acceptance actually ends.
    PERFORM accept_assertion(v_cand, p_reason := 'Suite 41 incumbent check');
    IF NOT EXISTS (
        SELECT 1 FROM assertions
        WHERE id = v_incumbent AND superseded_at IS NOT NULL AND superseded_by = v_cand
    ) THEN
        RAISE EXCEPTION
            '41.4 anti-vacuity: accept_assertion() did not supersede the row review_queue named as incumbent';
    END IF;

    -- The two gates. A strict scope governs one subject; the gated type
    -- registry_entry is settled by admin alone.
    INSERT INTO nodes (node_type, label) VALUES ('onboarding_scope', 'Suite 41 strict scope')
    RETURNING id INTO v_scope;
    PERFORM record_assertion('review_policy', '{"review_policy":"strict"}', v_scope, p_basis := 'assumed');
    -- governing_scope() only sees an active scope.
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_scope, p_basis := 'assumed');

    INSERT INTO nodes (node_type, label, external_id, external_source)
    VALUES ('thing', 'Meridian Holdings', gen_random_uuid()::text, 'conformance:v2')
    RETURNING id INTO v_gov;
    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('scope_governs_subject', v_scope, v_gov) RETURNING id INTO v_edge;
    IF scope_review_policy(governing_scope(v_gov, NULL, 'registry_entry', NULL)) <> 'strict' THEN
        RAISE EXCEPTION '41.4 precondition: the strict scope does not govern the fixture subject';
    END IF;

    -- review_gate only: admin clears the settle gate, the review policy demotes.
    v_rg := record_assertion(
        'registry_entry', '{"value":"suite41-a"}', v_gov,
        p_assertion_key := 'suite41:review', p_basis := 'assumed'
    );
    IF (SELECT status FROM assertions WHERE id = v_rg) <> 'candidate'
       OR NOT (SELECT attrs ? 'review_gate' FROM assertions WHERE id = v_rg)
    THEN
        RAISE EXCEPTION '41.4 precondition: the review policy did not demote and mark the admin write';
    END IF;
    IF (SELECT waiting_reason FROM review_queue
        WHERE subject_node_id = v_gov AND assertion_key = 'suite41:review') <> 'review_gate'
    THEN
        RAISE EXCEPTION '41.4: a review-gated tuple does not read review_gate';
    END IF;

    -- settle_gate only, on an ungoverned subject: team_member cannot settle
    -- a configuration type, so record_assertion() demotes and says so.
    PERFORM set_config('app.current_role', 'team_member', true);
    v_sg := record_assertion(
        'registry_entry', '{"value":"suite41-b"}', (SELECT id FROM t41 WHERE k = 'node_plain'),
        p_assertion_key := 'suite41:settle', p_basis := 'assumed'
    );
    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT status FROM assertions WHERE id = v_sg) <> 'candidate'
       OR NOT (SELECT attrs ? 'settle_gate' FROM assertions WHERE id = v_sg)
    THEN
        RAISE EXCEPTION '41.4 precondition: the settle gate did not demote and mark the team_member write';
    END IF;
    SELECT * INTO v_q FROM review_queue
    WHERE subject_node_id = (SELECT id FROM t41 WHERE k = 'node_plain')
      AND assertion_key = 'suite41:settle';
    IF v_q.waiting_reason <> 'settle_gate'
       OR v_q.waiting_detail IS DISTINCT FROM (SELECT attrs->'settle_gate' FROM assertions WHERE id = v_sg)
    THEN
        RAISE EXCEPTION
            '41.4: a settle-gated tuple reads %/%', v_q.waiting_reason, v_q.waiting_detail;
    END IF;

    -- Both markers on one tuple: settle_gate wins, because that demotion is
    -- the one that needs an admin.
    v_rg := record_assertion(
        'registry_entry', '{"value":"suite41-c"}', v_gov,
        p_assertion_key := 'suite41:both', p_basis := 'assumed'
    );
    PERFORM set_config('app.current_role', 'team_member', true);
    v_sg := record_assertion(
        'registry_entry', '{"value":"suite41-d"}', v_gov,
        p_assertion_key := 'suite41:both', p_basis := 'assumed'
    );
    PERFORM set_config('app.current_role', 'admin', true);
    IF NOT (SELECT attrs ? 'review_gate' FROM assertions WHERE id = v_rg)
       OR NOT (SELECT attrs ? 'settle_gate' FROM assertions WHERE id = v_sg)
    THEN
        RAISE EXCEPTION '41.4 precondition: the both-markers tuple does not carry both markers';
    END IF;
    SELECT * INTO v_q FROM review_queue
    WHERE subject_node_id = v_gov AND assertion_key = 'suite41:both';
    IF v_q.candidate_count <> 2 OR v_q.waiting_reason <> 'settle_gate' THEN
        RAISE EXCEPTION
            '41.4: a tuple carrying both markers reads % over % candidates, expected settle_gate',
            v_q.waiting_reason, v_q.candidate_count;
    END IF;
    IF (SELECT waiting_reason FROM review_queue_candidates WHERE assertion_id = v_rg) <> 'review_gate'
       OR (SELECT waiting_reason FROM review_queue_candidates WHERE assertion_id = v_sg) <> 'settle_gate'
    THEN
        RAISE EXCEPTION
            '41.4: review_queue_candidates does not report each candidate''s own reason';
    END IF;
END
$$;

-- --------------------------------------------------------------------------
-- 41.5 stale_digests names the culprit, and the arrays agree with the
--      booleans on every row.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_dig_newer uuid;
    v_dig_overturned uuid;
    v_newer uuid;
    v_node uuid;
    v_row record;
    v_src uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    -- A digest whose subject gained a newer accepted fact. now() is frozen
    -- in-transaction, so the newer row must outrun the watermark by hand.
    INSERT INTO nodes (node_type, label, external_id, external_source)
    VALUES ('project', 'Brannock rollout', gen_random_uuid()::text, 'conformance:v2')
    RETURNING id INTO v_node;
    v_src := record_assertion('project_status', '{"status":"active"}', v_node,
                              p_assertion_key := 'default', p_basis := 'assumed');
    v_dig_newer := record_distillation(
        p_subject_node_id := v_node, p_subject_edge_id := NULL,
        p_assertion_key := 'suite41:newer', p_claim := '{"summary":"rollout is on track"}',
        p_source_assertion_ids := ARRAY[v_src], p_source_event_ids := '{}'::uuid[],
        p_agent := 'test:review-surfaces');
    INSERT INTO assertions (assertion_type, assertion_key, subject_node_id,
                            claim, asserted_at, basis)
    VALUES ('project_update', 'suite41:after-digest', v_node, '{"value":"newer"}',
            clock_timestamp() + interval '1 millisecond', 'assumed')
    RETURNING id INTO v_newer;

    -- A digest whose derivation source was superseded.
    INSERT INTO nodes (node_type, label, external_id, external_source)
    VALUES ('project', 'Corvin rebuild', gen_random_uuid()::text, 'conformance:v2')
    RETURNING id INTO v_node;
    v_src := record_assertion('project_status', '{"status":"active"}', v_node,
                              p_assertion_key := 'default', p_basis := 'assumed');
    v_dig_overturned := record_distillation(
        p_subject_node_id := v_node, p_subject_edge_id := NULL,
        p_assertion_key := 'suite41:overturned', p_claim := '{"summary":"rebuild is active"}',
        p_source_assertion_ids := ARRAY[v_src], p_source_event_ids := '{}'::uuid[],
        p_agent := 'test:review-surfaces');
    PERFORM supersede_assertion(
        p_old_assertion_id := v_src,
        p_new_assertion_type := 'project_status',
        p_new_subject_node_id := v_node,
        p_new_subject_edge_id := NULL,
        p_new_claim := '{"status":"paused"}'::jsonb,
        p_new_assertion_key := 'default',
        p_new_basis := 'assumed'
    );

    -- Every row: the boolean is exactly "the array is not empty".
    FOR v_row IN SELECT * FROM stale_digests LOOP
        IF v_row.newer_assertion_ids IS NULL OR v_row.overturned_source_assertion_ids IS NULL THEN
            RAISE EXCEPTION
                '41.5: digest % carries a null culprit array', v_row.digest_assertion_id;
        END IF;
        IF v_row.newer_subject_assertion IS DISTINCT FROM (cardinality(v_row.newer_assertion_ids) > 0)
           OR v_row.overturned_source IS DISTINCT FROM (cardinality(v_row.overturned_source_assertion_ids) > 0)
        THEN
            RAISE EXCEPTION
                '41.5: digest % has newer=% ids=% overturned=% ids=%',
                v_row.digest_assertion_id, v_row.newer_subject_assertion,
                v_row.newer_assertion_ids, v_row.overturned_source,
                v_row.overturned_source_assertion_ids;
        END IF;
        IF (v_row.newer_latest_asserted_at IS NULL) <> (cardinality(v_row.newer_assertion_ids) = 0) THEN
            RAISE EXCEPTION
                '41.5: digest % has newer_latest_asserted_at % beside % ids',
                v_row.digest_assertion_id, v_row.newer_latest_asserted_at,
                cardinality(v_row.newer_assertion_ids);
        END IF;
    END LOOP;

    -- Both kinds exist, and each names its own culprit.
    SELECT * INTO v_row FROM stale_digests WHERE digest_assertion_id = v_dig_newer;
    IF NOT FOUND OR NOT v_row.newer_subject_assertion
       OR NOT (v_newer = ANY(v_row.newer_assertion_ids))
       OR v_row.newer_latest_asserted_at IS DISTINCT FROM (SELECT asserted_at FROM assertions WHERE id = v_newer)
    THEN
        RAISE EXCEPTION
            '41.5: the newer-assertion digest does not name % (ids %, latest %)',
            v_newer, v_row.newer_assertion_ids, v_row.newer_latest_asserted_at;
    END IF;

    SELECT * INTO v_row FROM stale_digests WHERE digest_assertion_id = v_dig_overturned;
    IF NOT FOUND OR NOT v_row.overturned_source
       OR NOT (v_src = ANY(v_row.overturned_source_assertion_ids))
    THEN
        RAISE EXCEPTION
            '41.5: the overturned-source digest does not name % (ids %)',
            v_src, v_row.overturned_source_assertion_ids;
    END IF;
END
$$;

-- --------------------------------------------------------------------------
-- 41.6 Rejected is never waiting, and 41.7 displaced is not rejected.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_d1 uuid;
    v_d2 uuid;
    v_node uuid := (SELECT id FROM t41 WHERE k = 'node_plain');
    v_rej uuid;
    v_row record;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    v_rej := record_assertion(
        'service_tier', '{"tier":"platinum"}', v_node,
        p_assertion_key := 'suite41:reject', p_confidence := 0.50,
        p_status := 'candidate', p_basis := 'assumed'
    );
    -- Anti-vacuity: it was waiting before it was rejected.
    IF NOT EXISTS (
        SELECT 1 FROM review_queue
        WHERE subject_node_id = v_node AND assertion_key = 'suite41:reject'
    ) THEN
        RAISE EXCEPTION '41.6 anti-vacuity: the candidate was never in review_queue';
    END IF;
    IF EXISTS (SELECT 1 FROM rejected_candidates WHERE assertion_id = v_rej) THEN
        RAISE EXCEPTION '41.6 anti-vacuity: a live candidate is already in rejected_candidates';
    END IF;

    PERFORM reject_candidate(v_rej, 'Duplicate of the signed order', 'user:tamsin', 'duplicate');

    SELECT * INTO v_row FROM rejected_candidates WHERE assertion_id = v_rej;
    IF NOT FOUND THEN
        RAISE EXCEPTION '41.6: the rejected candidate is not in rejected_candidates';
    END IF;
    IF v_row.rejected_by IS DISTINCT FROM 'user:tamsin'
       OR v_row.rejected_reason IS DISTINCT FROM 'Duplicate of the signed order'
       OR v_row.rejected_outcome IS DISTINCT FROM 'duplicate'
       OR v_row.rejected_at IS NULL
       OR v_row.rejection_event_id IS NULL
    THEN
        RAISE EXCEPTION
            '41.6: rejected_candidates says by=% reason=% outcome=% at=% event=%',
            v_row.rejected_by, v_row.rejected_reason, v_row.rejected_outcome,
            v_row.rejected_at, v_row.rejection_event_id;
    END IF;
    IF v_row.subject_label <> 'Brannock Freight' OR v_row.assertion_type <> 'service_tier' THEN
        RAISE EXCEPTION '41.6: rejected_candidates lost the subject or the type';
    END IF;
    -- Rejected keeps status candidate with superseded_by null. That is why
    -- the two sets cannot be confused.
    IF NOT EXISTS (
        SELECT 1 FROM assertions
        WHERE id = v_rej AND status = 'candidate'
          AND superseded_at IS NOT NULL AND superseded_by IS NULL
    ) THEN
        RAISE EXCEPTION '41.6: reject_candidate() left a shape this view does not describe';
    END IF;
    IF EXISTS (SELECT 1 FROM review_queue WHERE candidates::text LIKE '%' || v_rej::text || '%') THEN
        RAISE EXCEPTION '41.6: a rejected candidate is still waiting in review_queue';
    END IF;
    IF EXISTS (SELECT 1 FROM review_queue_candidates WHERE assertion_id = v_rej) THEN
        RAISE EXCEPTION '41.6: a rejected candidate is still in review_queue_candidates';
    END IF;
    IF EXISTS (
        SELECT 1 FROM review_queue_candidates rqc
        JOIN rejected_candidates rc ON rc.assertion_id = rqc.assertion_id
    ) THEN
        RAISE EXCEPTION '41.6: review_queue_candidates and rejected_candidates overlap';
    END IF;

    -- 41.7 A candidate closed by naming a replacement was displaced, not
    -- rejected, and belongs to the supersession chain.
    v_d1 := record_assertion(
        'service_tier', '{"tier":"a"}', v_node,
        p_assertion_key := 'suite41:displaced', p_status := 'candidate', p_basis := 'assumed'
    );
    v_d2 := record_assertion(
        'service_tier', '{"tier":"b"}', v_node,
        p_assertion_key := 'suite41:displaced', p_status := 'candidate', p_basis := 'assumed'
    );
    PERFORM mark_assertion_superseded(v_d1, v_d2);
    IF NOT EXISTS (
        SELECT 1 FROM assertions WHERE id = v_d1 AND superseded_by = v_d2
    ) THEN
        RAISE EXCEPTION '41.7 anti-vacuity: the displaced candidate does not name its replacement';
    END IF;
    IF EXISTS (SELECT 1 FROM rejected_candidates WHERE assertion_id = v_d1) THEN
        RAISE EXCEPTION '41.7: a candidate closed by naming a replacement reads as rejected';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM review_queue_candidates WHERE assertion_id = v_d2) THEN
        RAISE EXCEPTION '41.7 anti-vacuity: the replacement is not itself waiting';
    END IF;
END
$$;

-- --------------------------------------------------------------------------
-- 41.10 The views add no visibility. Every column is something the caller
--       could have selected from the base tables itself, and silence is
--       silence: null incumbent_* is not "no incumbent".
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_cand uuid;
    v_cls_cand uuid;
    v_ev_cand uuid;
    v_hidden uuid := (SELECT id FROM t41 WHERE k = 'node_hidden');
    v_hidden_cand uuid;
    v_incumbent uuid;
    v_node uuid := (SELECT id FROM t41 WHERE k = 'node_classified');
    v_rej_cls uuid;
    v_seen int;
    v_row record;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_teams', 'suite41-vault', true);

    -- A classified incumbent under a readable candidate.
    v_incumbent := record_assertion(
        'service_tier', '{"tier":"sealed"}', v_node,
        p_assertion_key := 'default', p_confidence := 0.55,
        p_basis := 'assumed', p_classification := 'confidential'
    );
    v_cand := record_assertion(
        'service_tier', '{"tier":"open"}', v_node,
        p_assertion_key := 'default', p_confidence := 0.65,
        p_status := 'candidate', p_basis := 'assumed'
    );
    -- A classified candidate of its own.
    v_cls_cand := record_assertion(
        'service_tier', '{"tier":"sealed-candidate"}', v_node,
        p_assertion_key := 'suite41:classified', p_status := 'candidate',
        p_basis := 'assumed', p_classification := 'confidential'
    );
    -- A candidate on a node hidden by team.
    v_hidden_cand := record_assertion(
        'service_tier', '{"tier":"vaulted"}', v_hidden,
        p_assertion_key := 'default', p_status := 'candidate', p_basis := 'assumed'
    );
    -- A readable candidate whose only evidence is witnessed by that node.
    v_ev_cand := record_assertion(
        'service_tier', '{"tier":"witnessed"}',
        (SELECT id FROM t41 WHERE k = 'node_plain'),
        p_assertion_key := 'suite41:witnessed', p_status := 'candidate', p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object(
            'kind', 'source',
            'event_id', (SELECT id FROM t41 WHERE k = 'event'),
            'witness_node_id', v_hidden
        )]
    );
    -- A classified candidate, then rejected.
    v_rej_cls := record_assertion(
        'service_tier', '{"tier":"sealed-reject"}', v_node,
        p_assertion_key := 'suite41:classified-reject', p_status := 'candidate',
        p_basis := 'assumed', p_classification := 'confidential'
    );
    PERFORM reject_candidate(v_rej_cls, 'Superseded by the sealed order', 'user:tamsin');

    -- Anti-vacuity: as admin, on the vault team, every one of these is
    -- visible. A fixture nobody can see proves nothing.
    IF (SELECT count(*) FROM assertions WHERE id = v_incumbent) <> 1
       OR (SELECT count(*) FROM assertions WHERE id = v_cls_cand) <> 1
       OR (SELECT count(*) FROM nodes WHERE id = v_hidden) <> 1
       OR (SELECT count(*) FROM assertion_evidence WHERE assertion_id = v_ev_cand) <> 1
    THEN
        RAISE EXCEPTION
            '41.10 anti-vacuity: admin cannot see its own fixtures; the test would pass for the wrong reason';
    END IF;

    SELECT * INTO v_row FROM review_queue
    WHERE subject_node_id = v_node AND assertion_key = 'default';
    IF v_row.incumbent_assertion_id IS DISTINCT FROM v_incumbent OR NOT v_row.incumbent_is_current THEN
        RAISE EXCEPTION '41.10 anti-vacuity: admin does not see the classified incumbent in review_queue';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM review_queue_candidates WHERE assertion_id = v_cls_cand)
       OR NOT EXISTS (SELECT 1 FROM review_queue_candidates WHERE assertion_id = v_hidden_cand)
       OR NOT EXISTS (SELECT 1 FROM rejected_candidates WHERE assertion_id = v_rej_cls)
    THEN
        RAISE EXCEPTION '41.10 anti-vacuity: admin does not see its own classified or vaulted fixtures';
    END IF;
    SELECT * INTO v_row FROM review_queue_candidates WHERE assertion_id = v_ev_cand;
    IF v_row.evidence_count <> 1 OR v_row.witness_count <> 1
       OR v_row.evidence_kinds IS DISTINCT FROM ARRAY['source']::text[]
       OR v_row.latest_evidence_at IS NULL
    THEN
        RAISE EXCEPTION
            '41.10 anti-vacuity: admin sees evidence_count=% witness_count=% kinds=%',
            v_row.evidence_count, v_row.witness_count, v_row.evidence_kinds;
    END IF;

    -- Now the same rows through a role that may read neither the
    -- classification nor the team.
    PERFORM set_config('app.current_role', 'team_member', true);
    PERFORM set_config('app.current_teams', '', true);

    -- The base tables hide them, which is what the views must match.
    SELECT count(*) INTO v_seen FROM assertions WHERE id = v_incumbent;
    IF v_seen <> 0 THEN
        RAISE EXCEPTION '41.10: a team_member can read the classified incumbent directly';
    END IF;
    IF (SELECT count(*) FROM nodes WHERE id = v_hidden) <> 0 THEN
        RAISE EXCEPTION '41.10: a team_member can read the team-hidden node directly';
    END IF;

    SELECT * INTO v_row FROM review_queue
    WHERE subject_node_id = v_node AND assertion_key = 'default';
    IF NOT FOUND THEN
        RAISE EXCEPTION '41.10: the readable candidate vanished from review_queue for a team_member';
    END IF;
    IF v_row.incumbent_assertion_id IS NOT NULL
       OR v_row.incumbent_claim IS NOT NULL
       OR v_row.incumbent_basis IS NOT NULL
       OR v_row.incumbent_confidence IS NOT NULL
       OR v_row.incumbent_effective_confidence IS NOT NULL
       OR v_row.incumbent_asserted_at IS NOT NULL
       OR v_row.incumbent_attrs IS NOT NULL
       OR v_row.incumbent_is_current IS NOT FALSE
    THEN
        RAISE EXCEPTION
            '41.10: review_queue disclosed a classified incumbent to a team_member (% / %)',
            v_row.incumbent_assertion_id, v_row.incumbent_is_current;
    END IF;
    IF (SELECT incumbent_assertion_id FROM review_queue_candidates WHERE assertion_id = v_cand)
       IS NOT NULL
    THEN
        RAISE EXCEPTION
            '41.10: review_queue_candidates disclosed a classified incumbent to a team_member';
    END IF;

    IF EXISTS (SELECT 1 FROM review_queue_candidates WHERE assertion_id = v_cls_cand)
       OR EXISTS (SELECT 1 FROM candidate_assertions_weighted WHERE id = v_cls_cand)
       OR EXISTS (SELECT 1 FROM review_queue WHERE assertion_key = 'suite41:classified')
    THEN
        RAISE EXCEPTION '41.10: a classified candidate is visible to a team_member';
    END IF;

    IF EXISTS (SELECT 1 FROM review_queue_candidates WHERE assertion_id = v_hidden_cand)
       OR EXISTS (SELECT 1 FROM review_queue WHERE subject_node_id = v_hidden)
    THEN
        RAISE EXCEPTION '41.10: a candidate on a team-hidden node is visible to a team_member';
    END IF;

    IF EXISTS (SELECT 1 FROM rejected_candidates WHERE assertion_id = v_rej_cls) THEN
        RAISE EXCEPTION '41.10: rejected_candidates disclosed a classified rejection to a team_member';
    END IF;

    SELECT * INTO v_row FROM review_queue_candidates WHERE assertion_id = v_ev_cand;
    IF NOT FOUND THEN
        RAISE EXCEPTION '41.10: the readable candidate with hidden evidence vanished entirely';
    END IF;
    IF v_row.evidence_count <> 0 OR v_row.witness_count <> 0
       OR cardinality(v_row.evidence_kinds) <> 0
       OR v_row.latest_evidence_at IS NOT NULL
    THEN
        RAISE EXCEPTION
            '41.10: evidence summary counted rows a team_member cannot read (count=% witnesses=% kinds=%)',
            v_row.evidence_count, v_row.witness_count, v_row.evidence_kinds;
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_teams', '', true);
END
$$;

-- --------------------------------------------------------------------------
-- 41.9, the row half: competing_candidates holds only contested tuples, and
--       holds the one this suite contested.
-- --------------------------------------------------------------------------
DO $$
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    IF EXISTS (SELECT 1 FROM competing_candidates WHERE candidate_count <= 1) THEN
        RAISE EXCEPTION '41.9: competing_candidates holds an uncontested tuple';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM competing_candidates
        WHERE subject_node_id = (SELECT id FROM t41 WHERE k = 'node_two')
          AND assertion_type = 'service_tier' AND assertion_key = 'default'
          AND candidate_count = 2
          AND waiting_reason = 'none'
          AND subject_label = 'Corvin Mill'
    ) THEN
        RAISE EXCEPTION
            '41.9 anti-vacuity: the contested tuple is missing from competing_candidates, or lost its appended columns';
    END IF;
    IF (SELECT count(*) FROM competing_candidates)
       <> (SELECT count(*) FROM review_queue WHERE candidate_count > 1)
    THEN
        RAISE EXCEPTION '41.9: competing_candidates and review_queue disagree on the contested tuples';
    END IF;
END
$$;

ROLLBACK;

-- ==========================================================================
-- 41.11 and 41.12, the crm profile's matview. These need more than one
-- transaction: now() is the transaction's start, so a refresh cannot be seen
-- to advance the snapshot from inside the transaction that performed it.
-- ==========================================================================

-- One fixture opportunity, so an empty matview cannot pass 41.12 vacuously.
-- Fixed id, so a second run on the same database reuses it.
BEGIN;
DO $$
BEGIN
    IF to_regclass('rye.opportunities_active') IS NULL THEN
        RETURN;
    END IF;
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:review-surfaces', true);
    PERFORM set_config('app.current_teams', '', true);
    INSERT INTO nodes (id, node_type, label, external_id, external_source, properties)
    VALUES ('41000041-0041-0041-0041-000000000041', 'opportunity',
            'Brannock Freight renewal', 'suite41:opportunity', 'conformance:v2',
            '{"code":"SUITE41-OPP","name":"Brannock Freight renewal"}')
    ON CONFLICT (id) DO NOTHING;
    PERFORM refresh_materialized_views();
END
$$;
COMMIT;

-- 41.11 The snapshot is one instant per snapshot, and a refresh advances it.
BEGIN;
DO $$
DECLARE
    v_before timestamptz;
    v_instants int;
    v_rows int;
BEGIN
    IF to_regclass('rye.opportunities_active') IS NULL THEN
        RETURN;
    END IF;
    PERFORM set_config('app.current_role', 'admin', true);

    SELECT count(*), count(DISTINCT snapshot_at), max(snapshot_at)
    INTO v_rows, v_instants, v_before
    FROM opportunities_active;

    IF v_rows < 1 THEN
        RAISE EXCEPTION
            '41.11 anti-vacuity: opportunities_active is empty, so a snapshot marker proves nothing';
    END IF;
    IF v_instants <> 1 THEN
        RAISE EXCEPTION
            '41.11: % rows of one snapshot carry % different snapshot_at values', v_rows, v_instants;
    END IF;
    IF v_before IS NULL THEN
        RAISE EXCEPTION '41.11 anti-vacuity: the pre-refresh snapshot_at is null';
    END IF;
    IF v_before >= now() THEN
        RAISE EXCEPTION
            '41.11 anti-vacuity: the pre-refresh snapshot_at (%) is not earlier than this transaction (%)',
            v_before, now();
    END IF;
    IF (SELECT snapshot_at FROM opportunities_active_freshness) IS DISTINCT FROM v_before THEN
        RAISE EXCEPTION '41.11: opportunities_active_freshness reports a different snapshot_at';
    END IF;

    PERFORM set_config('rye.suite41_before', v_before::text, false);
END
$$;
COMMIT;

BEGIN;
DO $$
BEGIN
    IF to_regclass('rye.opportunities_active') IS NULL THEN
        RETURN;
    END IF;
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM refresh_materialized_views();
END
$$;
COMMIT;

BEGIN;
DO $$
DECLARE
    v_after timestamptz;
    v_before timestamptz;
BEGIN
    IF to_regclass('rye.opportunities_active') IS NULL THEN
        RETURN;
    END IF;
    PERFORM set_config('app.current_role', 'admin', true);
    v_before := nullif(current_setting('rye.suite41_before', true), '')::timestamptz;
    SELECT max(snapshot_at) INTO v_after FROM opportunities_active;
    IF v_before IS NULL OR v_after IS NULL THEN
        RAISE EXCEPTION '41.11: snapshot_at before=% after=%', v_before, v_after;
    END IF;
    IF v_after <= v_before THEN
        RAISE EXCEPTION
            '41.11: refresh_materialized_views() did not advance snapshot_at (% then %)',
            v_before, v_after;
    END IF;
END
$$;

-- 41.12 Freshness is data-driven: stale_after is a registry entry, and the
--       default is 15 minutes. The registry write rolls back with this
--       transaction.
DO $$
DECLARE
    v_core uuid;
    v_row record;
BEGIN
    IF to_regclass('rye.opportunities_active') IS NULL THEN
        RETURN;
    END IF;
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:review-surfaces', true);

    SELECT * INTO v_row FROM opportunities_active_freshness;
    IF v_row.row_count < 1 THEN
        RAISE EXCEPTION
            '41.12 anti-vacuity: opportunities_active_freshness reports % rows', v_row.row_count;
    END IF;
    IF v_row.stale_after IS DISTINCT FROM interval '15 minutes' THEN
        RAISE EXCEPTION
            '41.12: with no registry entry stale_after is %, expected 15 minutes', v_row.stale_after;
    END IF;
    IF v_row.stale THEN
        RAISE EXCEPTION
            '41.12: a snapshot % old is already stale under the 15 minute default', v_row.age;
    END IF;
    IF v_row.age IS NULL OR v_row.age < interval '0' THEN
        RAISE EXCEPTION '41.12: age is %', v_row.age;
    END IF;

    SELECT id INTO v_core FROM nodes
    WHERE external_source = 'rye_registry' AND external_id = 'core' AND archived_at IS NULL;
    IF v_core IS NULL THEN
        RAISE EXCEPTION '41.12: the core registry node is missing';
    END IF;
    PERFORM record_assertion(
        'registry_entry', '{"value":"0 seconds"}'::jsonb, v_core,
        p_assertion_key := 'matview_stale_after:opportunities_active',
        p_basis := 'assumed'
    );

    SELECT * INTO v_row FROM opportunities_active_freshness;
    IF v_row.stale_after IS DISTINCT FROM interval '0 seconds' THEN
        RAISE EXCEPTION
            '41.12: the registry entry did not retune stale_after (it reads %)', v_row.stale_after;
    END IF;
    IF NOT v_row.stale THEN
        RAISE EXCEPTION
            '41.12: with stale_after 0 seconds a % old snapshot still reads fresh', v_row.age;
    END IF;
END
$$;
ROLLBACK;
