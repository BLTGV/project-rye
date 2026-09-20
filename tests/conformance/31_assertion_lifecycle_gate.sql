-- The row is the gate, not the route.
--
-- Contract:  contracts/sql-surface.md, "The row is the gate, not the route".
-- Decision:  docs/decisions/0008-the-row-is-the-gate-for-assertion-lifecycle.md.
-- Work item: work/007-assertion-lifecycle-gate.md.
--
-- The fourteen obligations from section H of the decision, in order. Every
-- case runs under a non-superuser role and forges every helper-owned session
-- setting first, because any caller can set them. Invented names only: Wren,
-- Tobin, Marsh.

SET search_path = rye, public, pg_catalog;

BEGIN;

-- --------------------------------------------------------------------------
-- Obligation 1. Refuse to pass vacuously.
--
-- A superuser bypasses RLS even when it is forced, and with row_security off
-- every refusal below would be a refusal for the wrong reason.
-- scripts/conformance.sh runs SQL suites under a non-superuser role when the
-- connection is a superuser, so this suite requires that.
--
-- `SET app.current_role = ...` is a syntax error because current_role is a
-- reserved word, so every case uses set_config() and asserts the read-back.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_node  uuid;
    v_probe uuid;
    v_role  text;
    v_seen  integer;
    v_super boolean;
BEGIN
    SELECT rolsuper INTO v_super FROM pg_roles WHERE rolname = current_user;
    IF coalesce(v_super, false) THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: % is a superuser and bypasses RLS. Run this suite under a non-superuser role, as scripts/conformance.sh does.',
            current_user;
    END IF;
    IF current_setting('row_security', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'Refusing to pass vacuously: row_security is %',
            current_setting('row_security', true);
    END IF;

    -- set_config() is the only way to set the role, and it must read back.
    FOREACH v_role IN ARRAY ARRAY['agent:t', 'viewer', 'team_member', '', 'admin'] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION
                'Refusing to pass vacuously: app.current_role did not read back as "%", it reads "%"',
                v_role, current_setting('app.current_role', true);
        END IF;
    END LOOP;

    -- And prove RLS behaviourally on the table this gate protects.
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:lifecycle-gate', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Wren', '{"suite":"lifecycle_gate"}')
    RETURNING id INTO v_node;

    v_probe := record_assertion(
        'compensation', '{"value":"rls probe"}', v_node,
        p_assertion_key := 'lifecycle_gate:rls_probe', p_basis := 'assumed'
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
-- Obligations 2 to 7, 9, 10, 11: the gate itself.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_attempt      integer;
    v_before       assertions;
    v_canonical    uuid;
    v_cand         uuid;
    v_copied       assertions;
    v_deferred_id  uuid;
    v_duplicate    uuid;
    v_failed       boolean;
    v_free         uuid;
    v_gov          uuid;
    v_id           uuid;
    v_msg          text;
    v_narrow_id    uuid;
    v_other        uuid;
    v_path         text;
    v_role         text;
    v_row          assertions;
    v_rows         integer;
    v_scope        uuid;
    v_target       uuid;
    v_paths        text[] := ARRAY[
        'accept_assertion', 'supersede_assertion', 'assertion_effective_window',
        'assertion_classification', 'assertion_outcome'
    ];
    v_roles        text[] := ARRAY['agent:t', 'viewer', 'team_member', ''];
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:lifecycle-gate', true);
    PERFORM set_config('app.current_teams', '', true);

    -- ------------------------------------------------------------------
    -- Fixtures. One scope with a strict review policy, one subject it
    -- governs, one subject nothing governs.
    -- ------------------------------------------------------------------
    INSERT INTO nodes (node_type, label) VALUES ('onboarding_scope', 'Lifecycle gate strict scope')
    RETURNING id INTO v_scope;
    PERFORM record_assertion('review_policy', '{"review_policy":"strict"}', v_scope, p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_scope, p_basis := 'assumed');
    IF scope_review_policy(v_scope) <> 'strict' THEN
        RAISE EXCEPTION 'Premise broken: the fixture scope is %', scope_review_policy(v_scope);
    END IF;

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('thing', 'Tobin governed subject', '{"suite":"lifecycle_gate"}')
    RETURNING id INTO v_gov;
    INSERT INTO edges (edge_type, source_id, target_id) VALUES ('scope_governs_subject', v_scope, v_gov);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('thing', 'Marsh ungoverned subject', '{"suite":"lifecycle_gate"}')
    RETURNING id INTO v_free;

    IF governing_scope(v_gov, NULL, 'lifecycle_probe', NULL) IS DISTINCT FROM v_scope THEN
        RAISE EXCEPTION 'Premise broken: the governed subject resolves to %',
            governing_scope(v_gov, NULL, 'lifecycle_probe', NULL);
    END IF;
    IF scope_review_policy(governing_scope(v_free, NULL, 'lifecycle_probe', NULL)) <> 'open' THEN
        RAISE EXCEPTION 'Premise broken: the ungoverned subject is not under an open policy';
    END IF;

    -- ==================================================================
    -- Obligation 2. A direct INSERT of an accepted ordinary assertion
    -- under a strict scope lands candidate; under open it lands accepted,
    -- which is what record_assertion() would have done for the same caller.
    -- ==================================================================
    FOREACH v_role IN ARRAY v_roles LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION 'app.current_role did not read back as "%"', v_role;
        END IF;
        PERFORM set_config('app.write_path', 'accept_assertion', true);

        v_id := gen_random_uuid();
        INSERT INTO assertions (id, assertion_type, assertion_key, status, basis, subject_node_id, claim)
        VALUES (v_id, 'lifecycle_probe', 'direct_strict_' || coalesce(nullif(v_role, ''), 'unset'),
                'accepted', 'assumed', v_gov, '{"value":"said"}');
        IF (SELECT status FROM assertions WHERE id = v_id) <> 'candidate' THEN
            RAISE EXCEPTION
                'Role "%" landed a direct accepted INSERT under a strict scope as %',
                v_role, (SELECT status FROM assertions WHERE id = v_id);
        END IF;
        IF (SELECT claim FROM assertions WHERE id = v_id) IS DISTINCT FROM '{"value":"said"}'::jsonb THEN
            RAISE EXCEPTION 'Role "%" lost what it said when the row was demoted', v_role;
        END IF;

        v_id := gen_random_uuid();
        INSERT INTO assertions (id, assertion_type, assertion_key, status, basis, subject_node_id, claim)
        VALUES (v_id, 'lifecycle_probe', 'direct_open_' || coalesce(nullif(v_role, ''), 'unset'),
                'accepted', 'assumed', v_free, '{"value":"said"}');
        IF (SELECT status FROM assertions WHERE id = v_id) <> 'accepted' THEN
            RAISE EXCEPTION
                'Role "%" direct accepted INSERT under an open policy landed %, not accepted',
                v_role, (SELECT status FROM assertions WHERE id = v_id);
        END IF;

        -- record_assertion() gives the same two answers for the same caller.
        v_id := record_assertion(
            'lifecycle_probe', '{"value":"said"}', v_gov,
            p_assertion_key := 'helper_strict_' || coalesce(nullif(v_role, ''), 'unset'),
            p_basis := 'assumed'
        );
        IF (SELECT status FROM assertions WHERE id = v_id) <> 'candidate' THEN
            RAISE EXCEPTION 'Role "%" record_assertion under strict landed accepted', v_role;
        END IF;
        v_id := record_assertion(
            'lifecycle_probe', '{"value":"said"}', v_free,
            p_assertion_key := 'helper_open_' || coalesce(nullif(v_role, ''), 'unset'),
            p_basis := 'assumed'
        );
        IF (SELECT status FROM assertions WHERE id = v_id) <> 'accepted' THEN
            RAISE EXCEPTION 'Role "%" record_assertion under open did not land accepted', v_role;
        END IF;

        PERFORM set_config('app.write_path', '', true);
    END LOOP;

    -- ==================================================================
    -- Obligation 3. No raw UPDATE promotes a candidate, whatever the
    -- caller sets first. Every helper-owned write path is tried, with the
    -- matching row id setting pointed at the target.
    --
    -- Under an open policy the refusal arrives at COMMIT, because the fact
    -- that makes a promotion real -- the assertion_accepted event -- is
    -- written after the statement, so the check is deferred. A plpgsql
    -- EXCEPTION block does not see a deferred trigger, so each case forces
    -- it with SET CONSTRAINTS ... IMMEDIATE and puts it back afterwards.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'admin', true);
    FOREACH v_role IN ARRAY v_roles LOOP
        FOREACH v_path IN ARRAY v_paths LOOP
            PERFORM set_config('app.current_role', 'admin', true);
            v_cand := record_assertion(
                'lifecycle_probe', '{"value":"suggested"}', v_free,
                p_assertion_key := 'promote_' || coalesce(nullif(v_role, ''), 'unset') || '_' || v_path,
                p_status := 'candidate', p_basis := 'assumed'
            );

            PERFORM set_config('app.current_role', v_role, true);
            IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
                RAISE EXCEPTION 'app.current_role did not read back as "%"', v_role;
            END IF;
            PERFORM set_config('app.write_path', v_path, true);
            PERFORM set_config('app.accept_assertion_id', v_cand::text, true);
            PERFORM set_config('app.supersede_assertion_id', v_cand::text, true);
            PERFORM set_config('app.effective_window_assertion_id', v_cand::text, true);
            PERFORM set_config('app.classification_assertion_id', v_cand::text, true);
            PERFORM set_config('app.outcome_assertion_id', v_cand::text, true);

            v_failed := false;
            v_rows := -1;
            BEGIN
                UPDATE assertions SET status = 'accepted' WHERE id = v_cand;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                SET CONSTRAINTS trg_assertions_transition_complete IMMEDIATE;
            EXCEPTION WHEN OTHERS THEN
                v_failed := true;
                v_msg := SQLERRM;
            END;
            SET CONSTRAINTS trg_assertions_transition_complete DEFERRED;
            IF NOT v_failed AND v_rows <> 0 THEN
                RAISE EXCEPTION
                    'Role "%" promoted a candidate with a raw UPDATE on write_path "%" (% rows)',
                    v_role, v_path, v_rows;
            END IF;
            IF (SELECT status FROM assertions WHERE id = v_cand) <> 'candidate' THEN
                RAISE EXCEPTION
                    'Role "%" left the candidate accepted after a refused promotion on write_path "%"',
                    v_role, v_path;
            END IF;

            PERFORM set_config('app.write_path', '', true);
        END LOOP;
    END LOOP;

    -- ==================================================================
    -- Obligation 4. No raw UPDATE ends an accepted assertion.
    -- ==================================================================
    FOREACH v_role IN ARRAY v_roles LOOP
        FOREACH v_path IN ARRAY v_paths LOOP
            PERFORM set_config('app.current_role', 'admin', true);
            v_target := record_assertion(
                'lifecycle_probe', '{"value":"standing"}', v_free,
                p_assertion_key := 'erase_' || coalesce(nullif(v_role, ''), 'unset') || '_' || v_path,
                p_basis := 'assumed'
            );
            IF (SELECT status FROM assertions WHERE id = v_target) <> 'accepted' THEN
                RAISE EXCEPTION 'Premise broken: the erase target is not accepted';
            END IF;

            PERFORM set_config('app.current_role', v_role, true);
            PERFORM set_config('app.write_path', v_path, true);
            PERFORM set_config('app.accept_assertion_id', v_target::text, true);
            PERFORM set_config('app.supersede_assertion_id', v_target::text, true);
            PERFORM set_config('app.effective_window_assertion_id', v_target::text, true);
            PERFORM set_config('app.classification_assertion_id', v_target::text, true);
            PERFORM set_config('app.outcome_assertion_id', v_target::text, true);

            v_failed := false;
            v_rows := -1;
            BEGIN
                UPDATE assertions SET superseded_at = now() WHERE id = v_target;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
            EXCEPTION WHEN OTHERS THEN
                v_failed := true;
                v_msg := SQLERRM;
            END;
            IF NOT v_failed AND v_rows <> 0 THEN
                RAISE EXCEPTION
                    'Role "%" ended an accepted assertion with a raw UPDATE on write_path "%" (% rows)',
                    v_role, v_path, v_rows;
            END IF;
            IF (SELECT superseded_at FROM assertions WHERE id = v_target) IS NOT NULL THEN
                RAISE EXCEPTION
                    'Role "%" left superseded_at set after a refused erasure on write_path "%"',
                    v_role, v_path;
            END IF;

            PERFORM set_config('app.write_path', '', true);
        END LOOP;
    END LOOP;

    -- ==================================================================
    -- Obligation 5. No raw narrowing, no attrs rewrite, no classification
    -- change. Each refused, each row unchanged afterwards.
    -- ==================================================================
    FOREACH v_role IN ARRAY v_roles LOOP
        PERFORM set_config('app.current_role', 'admin', true);
        v_target := record_assertion(
            'lifecycle_probe', '{"value":"standing"}', v_free,
            p_assertion_key := 'shape_' || coalesce(nullif(v_role, ''), 'unset'),
            p_effective_at := now() - interval '1 day',
            p_effective_to := now() + interval '30 days',
            p_basis := 'assumed',
            p_attrs := '{"note":"keep"}'
        );
        SELECT * INTO v_before FROM assertions WHERE id = v_target;
        IF v_before.status <> 'accepted' OR v_before.attrs->>'note' <> 'keep' THEN
            RAISE EXCEPTION 'Premise broken: the shape target is %', to_jsonb(v_before);
        END IF;

        PERFORM set_config('app.current_role', v_role, true);
        FOREACH v_path IN ARRAY v_paths LOOP
            PERFORM set_config('app.write_path', v_path, true);
            PERFORM set_config('app.accept_assertion_id', v_target::text, true);
            PERFORM set_config('app.supersede_assertion_id', v_target::text, true);
            PERFORM set_config('app.effective_window_assertion_id', v_target::text, true);
            PERFORM set_config('app.classification_assertion_id', v_target::text, true);
            PERFORM set_config('app.outcome_assertion_id', v_target::text, true);

            FOR v_attempt IN 1..4 LOOP
                v_failed := false;
                v_rows := -1;
                BEGIN
                    CASE v_attempt
                        WHEN 1 THEN
                            UPDATE assertions SET effective_to = now() + interval '1 hour'
                            WHERE id = v_target;
                        WHEN 2 THEN
                            UPDATE assertions SET attrs = attrs - 'note' WHERE id = v_target;
                        WHEN 3 THEN
                            UPDATE assertions SET attrs = attrs || '{"note":"rewritten"}'::jsonb
                            WHERE id = v_target;
                        WHEN 4 THEN
                            UPDATE assertions SET classification = 'public' WHERE id = v_target;
                    END CASE;
                    GET DIAGNOSTICS v_rows = ROW_COUNT;
                    -- The successor of a narrowed window is a commit-time
                    -- check, so force it here; the other three refuse at the
                    -- statement and this is a no-op for them.
                    SET CONSTRAINTS trg_assertions_transition_complete IMMEDIATE;
                EXCEPTION WHEN OTHERS THEN
                    v_failed := true;
                    v_msg := SQLERRM;
                END;
                SET CONSTRAINTS trg_assertions_transition_complete DEFERRED;
                IF NOT v_failed AND v_rows <> 0 THEN
                    RAISE EXCEPTION
                        'Role "%" changed an accepted assertion (attempt %, write_path "%", % rows)',
                        v_role, v_attempt, v_path, v_rows;
                END IF;
            END LOOP;

            PERFORM set_config('app.write_path', '', true);
        END LOOP;

        SELECT * INTO v_row FROM assertions WHERE id = v_target;
        IF v_row.effective_to IS DISTINCT FROM v_before.effective_to
           OR v_row.attrs IS DISTINCT FROM v_before.attrs
           OR v_row.classification IS DISTINCT FROM v_before.classification
           OR v_row.status IS DISTINCT FROM v_before.status
           OR v_row.superseded_at IS DISTINCT FROM v_before.superseded_at
        THEN
            RAISE EXCEPTION 'Role "%" changed the row: % became %',
                v_role, to_jsonb(v_before), to_jsonb(v_row);
        END IF;
    END LOOP;

    -- ==================================================================
    -- Obligation 6. A decoy replacement is refused at the statement: a
    -- superseded_by naming an assertion of a different type or key.
    -- ==================================================================
    FOREACH v_role IN ARRAY v_roles LOOP
        PERFORM set_config('app.current_role', 'admin', true);
        v_target := record_assertion(
            'lifecycle_probe', '{"value":"standing"}', v_free,
            p_assertion_key := 'decoy_target_' || coalesce(nullif(v_role, ''), 'unset'),
            p_basis := 'assumed'
        );
        v_other := record_assertion(
            'lifecycle_other', '{"value":"unrelated"}', v_free,
            p_assertion_key := 'decoy_other_' || coalesce(nullif(v_role, ''), 'unset'),
            p_basis := 'assumed'
        );

        PERFORM set_config('app.current_role', v_role, true);
        PERFORM set_config('app.write_path', 'supersede_assertion', true);
        PERFORM set_config('app.supersede_assertion_id', v_target::text, true);

        v_failed := false;
        v_rows := -1;
        BEGIN
            UPDATE assertions SET superseded_at = now(), superseded_by = v_other
            WHERE id = v_target;
            GET DIAGNOSTICS v_rows = ROW_COUNT;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        PERFORM set_config('app.write_path', '', true);
        IF NOT v_failed AND v_rows <> 0 THEN
            RAISE EXCEPTION
                'Role "%" ended an accepted assertion with a decoy replacement of another type (% rows)',
                v_role, v_rows;
        END IF;
        IF NOT v_failed THEN
            RAISE EXCEPTION
                'Role "%" decoy replacement was filtered rather than refused; it must raise at the statement',
                v_role;
        END IF;
        IF (SELECT superseded_at FROM assertions WHERE id = v_target) IS NOT NULL THEN
            RAISE EXCEPTION 'Role "%" left the decoy erasure standing', v_role;
        END IF;
    END LOOP;

    -- ==================================================================
    -- Obligation 7. A deferred refusal is a refusal. Both commit-time
    -- checks are forced with SET CONSTRAINTS ... IMMEDIATE inside the
    -- block, because a plpgsql EXCEPTION handler does not otherwise see a
    -- deferred trigger, and the row is unchanged after the rollback.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'admin', true);

    -- 7a. A promotion the BEFORE guard allows, with no acceptance event.
    v_deferred_id := record_assertion(
        'lifecycle_probe', '{"value":"unwitnessed"}', v_free,
        p_assertion_key := 'deferred_promotion',
        p_status := 'candidate', p_basis := 'assumed'
    );
    v_failed := false;
    BEGIN
        PERFORM set_config('app.write_path', 'accept_assertion', true);
        PERFORM set_config('app.accept_assertion_id', v_deferred_id::text, true);
        UPDATE assertions SET status = 'accepted' WHERE id = v_deferred_id;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        SET CONSTRAINTS trg_assertions_transition_complete IMMEDIATE;
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        v_msg := SQLERRM;
    END;
    PERFORM set_config('app.write_path', '', true);
    IF NOT v_failed AND v_rows <> 0 THEN
        RAISE EXCEPTION 'A promotion with no assertion_accepted event was allowed to stand';
    END IF;
    IF v_msg NOT LIKE '%assertion_accepted event%' THEN
        RAISE EXCEPTION 'The deferred promotion check failed for the wrong reason: %', v_msg;
    END IF;
    IF (SELECT status FROM assertions WHERE id = v_deferred_id) <> 'candidate' THEN
        RAISE EXCEPTION 'The refused promotion survived the rollback';
    END IF;

    -- 7b. A narrowing the BEFORE guard allows, with no successor.
    v_narrow_id := record_assertion(
        'lifecycle_probe', '{"value":"open ended"}', v_free,
        p_assertion_key := 'deferred_narrowing',
        p_effective_at := now() - interval '1 day',
        p_basis := 'assumed'
    );
    v_failed := false;
    BEGIN
        PERFORM set_config('app.write_path', 'assertion_effective_window', true);
        PERFORM set_config('app.effective_window_assertion_id', v_narrow_id::text, true);
        UPDATE assertions SET effective_to = now() + interval '7 days' WHERE id = v_narrow_id;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        SET CONSTRAINTS trg_assertions_transition_complete IMMEDIATE;
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        v_msg := SQLERRM;
    END;
    PERFORM set_config('app.write_path', '', true);
    IF NOT v_failed AND v_rows <> 0 THEN
        RAISE EXCEPTION 'A window narrowing with no successor was allowed to stand';
    END IF;
    IF v_msg NOT LIKE '%no accepted assertion%' THEN
        RAISE EXCEPTION 'The deferred narrowing check failed for the wrong reason: %', v_msg;
    END IF;
    IF (SELECT effective_to FROM assertions WHERE id = v_narrow_id) IS NOT NULL THEN
        RAISE EXCEPTION 'The refused narrowing survived the rollback';
    END IF;

    -- ==================================================================
    -- Obligation 9. A helper still refuses what it refused before: an
    -- agent under a strict policy cannot accept, and the same caller
    -- cannot reach the same end by raw UPDATE.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'admin', true);
    v_cand := record_assertion(
        'lifecycle_probe', '{"value":"agent suggestion"}', v_gov,
        p_assertion_key := 'agent_strict', p_status := 'candidate', p_basis := 'assumed'
    );

    PERFORM set_config('app.current_role', 'agent:t', true);
    PERFORM set_config('app.current_user_id', 'agent:t', true);
    v_failed := false;
    BEGIN
        PERFORM accept_assertion(v_cand);
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        v_msg := SQLERRM;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'An agent accepted a candidate under a strict review policy';
    END IF;
    IF v_msg NOT LIKE '%rye.authoritative.promote%' THEN
        RAISE EXCEPTION 'The agent acceptance was refused for the wrong reason: %', v_msg;
    END IF;

    v_failed := false;
    v_rows := -1;
    BEGIN
        PERFORM set_config('app.write_path', 'accept_assertion', true);
        PERFORM set_config('app.accept_assertion_id', v_cand::text, true);
        UPDATE assertions SET status = 'accepted' WHERE id = v_cand;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        v_msg := SQLERRM;
    END;
    PERFORM set_config('app.write_path', '', true);
    IF NOT v_failed AND v_rows <> 0 THEN
        RAISE EXCEPTION 'An agent reached acceptance under strict by raw UPDATE';
    END IF;
    IF v_msg NOT LIKE '%rye.authoritative.promote%' THEN
        RAISE EXCEPTION 'The raw agent promotion was refused for the wrong reason: %', v_msg;
    END IF;
    IF (SELECT status FROM assertions WHERE id = v_cand) <> 'candidate' THEN
        RAISE EXCEPTION 'The agent promotion survived';
    END IF;
    PERFORM set_config('app.current_user_id', 'test:lifecycle-gate', true);

    -- ==================================================================
    -- Obligation 10. reject_candidate() still closes a candidate with
    -- superseded_by null, so the accepted-row rule did not swallow the
    -- candidate case.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'admin', true);
    v_cand := record_assertion(
        'lifecycle_probe', '{"value":"withdrawn"}', v_free,
        p_assertion_key := 'reject_probe', p_status := 'candidate', p_basis := 'assumed'
    );
    PERFORM reject_candidate(v_cand, 'Not supported', 'test:lifecycle-gate', 'unsupported');
    SELECT * INTO v_row FROM assertions WHERE id = v_cand;
    IF v_row.superseded_at IS NULL OR v_row.superseded_by IS NOT NULL THEN
        RAISE EXCEPTION
            'reject_candidate left superseded_at % and superseded_by %',
            v_row.superseded_at, v_row.superseded_by;
    END IF;
    IF v_row.attrs->>'outcome' <> 'unsupported' THEN
        RAISE EXCEPTION 'reject_candidate did not label the outcome: %', v_row.attrs;
    END IF;

    -- ==================================================================
    -- Obligation 11. merge_nodes() under a strict scope: the copied
    -- assertion lands as a candidate and appears in review_queue. The
    -- content is preserved; an admin accepts it from review.
    -- ==================================================================
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('thing', 'Tobin duplicate', '{"suite":"lifecycle_gate"}') RETURNING id INTO v_duplicate;
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('thing', 'Tobin canonical', '{"suite":"lifecycle_gate"}') RETURNING id INTO v_canonical;

    -- Recorded before the scope covers them, so the source really is accepted.
    v_id := record_assertion(
        'lifecycle_probe', '{"value":"carried across"}', v_duplicate,
        p_assertion_key := 'merge_probe', p_basis := 'assumed'
    );
    IF (SELECT status FROM assertions WHERE id = v_id) <> 'accepted' THEN
        RAISE EXCEPTION 'Premise broken: the merge source assertion is not accepted';
    END IF;

    INSERT INTO edges (edge_type, source_id, target_id) VALUES ('scope_governs_subject', v_scope, v_duplicate);
    INSERT INTO edges (edge_type, source_id, target_id) VALUES ('scope_governs_subject', v_scope, v_canonical);

    PERFORM merge_nodes(v_duplicate, v_canonical, 'test:lifecycle-gate');

    SELECT * INTO v_copied
    FROM assertions
    WHERE subject_node_id = v_canonical
      AND assertion_type = 'lifecycle_probe'
      AND assertion_key = 'merge_probe';
    IF v_copied.id IS NULL THEN
        RAISE EXCEPTION 'merge_nodes did not carry the assertion to the canonical node';
    END IF;
    IF v_copied.status <> 'candidate' THEN
        RAISE EXCEPTION
            'A merge under a strict scope landed the copied assertion as %, not candidate',
            v_copied.status;
    END IF;
    IF v_copied.claim IS DISTINCT FROM '{"value":"carried across"}'::jsonb THEN
        RAISE EXCEPTION 'The merge lost the claim: %', v_copied.claim;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM review_queue
        WHERE subject_node_id = v_canonical AND assertion_type = 'lifecycle_probe'
    ) THEN
        RAISE EXCEPTION 'The copied assertion is not waiting in review_queue';
    END IF;
    IF (SELECT superseded_by FROM assertions WHERE id = v_id) IS DISTINCT FROM v_copied.id THEN
        RAISE EXCEPTION 'The duplicate''s assertion does not name its replacement';
    END IF;

    -- This suite rolls back, so the deferred checks would never fire and
    -- every write above would be proven only to statement level. Force them.
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
END
$$;

-- --------------------------------------------------------------------------
-- Obligation 8. Every helper still works for a caller it worked for before,
-- each asserted by its effect and not only by not raising.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_answer      uuid;
    v_classified  uuid;
    v_digest      uuid;
    v_evidence    uuid;
    v_gap         uuid;
    v_id          uuid;
    v_incumbent   uuid;
    v_milestone   uuid;
    v_opp         uuid;
    v_owner       uuid;
    v_pipeline    uuid;
    v_prediction  uuid;
    v_project     uuid;
    v_replacement uuid;
    v_row         assertions;
    v_scheduled   uuid;
    v_scored      int;
    v_source      uuid;
    v_subject     uuid;
    v_task        uuid;
    v_tasks       uuid[];
    v_template    uuid;
    v_when        timestamptz := now() + interval '10 days';
    v_witness     uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:lifecycle-gate', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('thing', 'Helper subject', '{"suite":"lifecycle_gate"}') RETURNING id INTO v_subject;
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Wren witness', '{"suite":"lifecycle_gate"}')
    RETURNING id INTO v_witness;
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Marsh owner', '{"suite":"lifecycle_gate"}') RETURNING id INTO v_owner;

    -- record_assertion
    v_incumbent := record_assertion(
        'helper_probe', '{"value":"first"}', v_subject,
        p_assertion_key := 'default', p_basis := 'assumed'
    );
    IF (SELECT status FROM assertions WHERE id = v_incumbent) <> 'accepted' THEN
        RAISE EXCEPTION 'record_assertion did not land accepted';
    END IF;

    -- supersede_assertion
    v_replacement := supersede_assertion(
        v_incumbent, 'helper_probe', v_subject, NULL, '{"value":"second"}',
        p_new_assertion_key := 'default', p_new_basis := 'assumed'
    );
    SELECT * INTO v_row FROM assertions WHERE id = v_incumbent;
    IF v_row.superseded_at IS NULL OR v_row.superseded_by IS DISTINCT FROM v_replacement THEN
        RAISE EXCEPTION 'supersede_assertion did not end the incumbent with its replacement';
    END IF;
    IF (SELECT status FROM assertions WHERE id = v_replacement) <> 'accepted' THEN
        RAISE EXCEPTION 'supersede_assertion did not leave the replacement accepted';
    END IF;

    -- window narrowing inside record_assertion: a future-effective write
    -- closes the incumbent's window at the new effective_at.
    v_scheduled := record_assertion(
        'helper_probe', '{"value":"third"}', v_subject,
        p_assertion_key := 'default', p_effective_at := v_when, p_basis := 'assumed'
    );
    IF (SELECT effective_to FROM assertions WHERE id = v_replacement) IS DISTINCT FROM v_when THEN
        RAISE EXCEPTION
            'record_assertion did not narrow the incumbent window to %, it is %',
            v_when, (SELECT effective_to FROM assertions WHERE id = v_replacement);
    END IF;

    -- schedule_assertion_change
    v_id := schedule_assertion_change(
        p_subject_node_id := v_subject, p_subject_edge_id := NULL,
        p_assertion_type := 'helper_schedule', p_assertion_key := 'default',
        p_claim := '{"value":"later"}', p_effective_at := now() + interval '3 days',
        p_basis := 'assumed'
    );
    SELECT * INTO v_row FROM assertions WHERE id = v_id;
    IF v_row.status <> 'accepted' OR v_row.effective_at IS NULL THEN
        RAISE EXCEPTION 'schedule_assertion_change wrote %', to_jsonb(v_row);
    END IF;

    -- accept_assertion, on its own tuple, with an incumbent to displace
    v_id := record_assertion(
        'helper_accept', '{"value":"incumbent"}', v_subject,
        p_assertion_key := 'default', p_basis := 'assumed'
    );
    v_answer := record_assertion(
        'helper_accept', '{"value":"better"}', v_subject,
        p_assertion_key := 'default', p_status := 'candidate', p_basis := 'assumed'
    );
    PERFORM accept_assertion(v_answer, NULL, 'Reviewed', 'test:lifecycle-gate');
    IF (SELECT status FROM assertions WHERE id = v_answer) <> 'accepted' THEN
        RAISE EXCEPTION 'accept_assertion did not promote the candidate';
    END IF;
    IF (SELECT superseded_by FROM assertions WHERE id = v_id) IS DISTINCT FROM v_answer THEN
        RAISE EXCEPTION 'accept_assertion did not supersede the incumbent with the winner';
    END IF;

    -- reject_candidate
    v_id := record_assertion(
        'helper_accept', '{"value":"rejected"}', v_subject,
        p_assertion_key := 'default', p_status := 'candidate', p_basis := 'assumed'
    );
    PERFORM reject_candidate(v_id, 'Not supported', 'test:lifecycle-gate');
    IF (SELECT superseded_at FROM assertions WHERE id = v_id) IS NULL THEN
        RAISE EXCEPTION 'reject_candidate did not close the candidate';
    END IF;

    -- mark_assertion_outcome
    v_id := record_assertion(
        'helper_outcome', '{"value":"labelled"}', v_subject, p_basis := 'assumed'
    );
    PERFORM mark_assertion_outcome(v_id, 'correct', '{"outcome_reason":"checked"}');
    SELECT * INTO v_row FROM assertions WHERE id = v_id;
    IF v_row.attrs->>'outcome' <> 'correct' OR v_row.attrs->>'outcome_reason' <> 'checked' THEN
        RAISE EXCEPTION 'mark_assertion_outcome wrote %', v_row.attrs;
    END IF;

    -- record_distillation, which supersedes its incumbent before inserting
    v_source := record_assertion(
        'helper_source', '{"value":"raw"}', v_subject, p_basis := 'assumed'
    );
    v_digest := record_distillation(
        p_subject_node_id := v_subject, p_subject_edge_id := NULL,
        p_assertion_key := 'helper_digest', p_claim := '{"summary":"distilled"}',
        p_source_assertion_ids := ARRAY[v_source], p_source_event_ids := '{}'::uuid[],
        p_agent := 'test:lifecycle-gate'
    );
    IF (SELECT status FROM assertions WHERE id = v_digest) <> 'accepted' THEN
        RAISE EXCEPTION 'record_distillation did not land accepted';
    END IF;
    v_digest := record_distillation(
        p_subject_node_id := v_subject, p_subject_edge_id := NULL,
        p_assertion_key := 'helper_digest', p_claim := '{"summary":"distilled again"}',
        p_source_assertion_ids := ARRAY[v_source], p_source_event_ids := '{}'::uuid[],
        p_agent := 'test:lifecycle-gate'
    );
    IF (SELECT status FROM assertions WHERE id = v_digest) <> 'accepted' THEN
        RAISE EXCEPTION 'A second record_distillation did not replace the digest accepted';
    END IF;

    -- classification propagation from derivation evidence
    v_classified := record_assertion(
        'helper_classified', '{"value":"sensitive"}', v_subject,
        p_basis := 'assumed', p_classification := 'confidential'
    );
    v_evidence := record_assertion(
        'helper_derived', '{"value":"inherits"}', v_subject, p_basis := 'assumed'
    );
    IF (SELECT classification FROM assertions WHERE id = v_evidence) IS NOT NULL THEN
        RAISE EXCEPTION 'Premise broken: the derived row already carries a classification';
    END IF;
    PERFORM append_assertion_evidence(
        v_evidence,
        ARRAY[jsonb_build_object('kind', 'derivation', 'source_assertion_id', v_classified)]
    );
    IF (SELECT classification FROM assertions WHERE id = v_evidence) <> 'confidential' THEN
        RAISE EXCEPTION
            'Classification propagation did not run: the derived row is %',
            (SELECT classification FROM assertions WHERE id = v_evidence);
    END IF;

    -- resolve_knowledge_gap
    v_gap := record_assertion(
        'knowledge_gap', '{"question":"who owns this","status":"open"}', v_subject,
        p_assertion_key := 'helper_gap', p_basis := 'assumed'
    );
    v_answer := record_assertion(
        'helper_answer', '{"value":"Marsh"}', v_subject,
        p_assertion_key := 'helper_gap_answer', p_basis := 'assumed'
    );
    PERFORM resolve_knowledge_gap(v_gap, v_answer, 'test:lifecycle-gate');
    IF (SELECT superseded_at FROM assertions WHERE id = v_gap) IS NULL THEN
        RAISE EXCEPTION 'resolve_knowledge_gap did not close the gap';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM assertions
        WHERE assertion_type = 'knowledge_gap'
          AND assertion_key = 'helper_gap'
          AND subject_node_id = v_subject
          AND status = 'accepted'
          AND superseded_at IS NULL
          AND claim->>'status' = 'resolved'
    ) THEN
        RAISE EXCEPTION 'resolve_knowledge_gap did not write the resolved replacement';
    END IF;

    -- record_prediction and score_due_predictions
    v_id := record_assertion(
        'helper_outcome_key', '{"value":"shipped"}', v_subject,
        p_assertion_key := 'scored', p_basis := 'assumed'
    );
    v_prediction := record_prediction(
        p_subject_node_id := v_subject, p_subject_edge_id := NULL,
        p_assertion_key := 'helper_prediction',
        p_question := 'Will it ship?',
        p_outcome_key := 'helper_outcome_key:scored',
        p_predicted_value := '{"value":"shipped"}',
        p_probability := 0.8,
        p_horizon := now() - interval '1 hour',
        p_witness_node_id := v_witness,
        p_actor := 'test:lifecycle-gate'
    );
    v_scored := score_due_predictions();
    IF v_scored < 1 THEN
        RAISE EXCEPTION 'score_due_predictions scored % predictions', v_scored;
    END IF;
    IF (SELECT attrs->>'outcome' FROM assertions WHERE id = v_prediction) IS NULL THEN
        RAISE EXCEPTION 'score_due_predictions did not label the prediction';
    END IF;

    -- merge_nodes under an open policy carries the assertion across accepted
    DECLARE
        v_dupe uuid;
        v_canon uuid;
    BEGIN
        INSERT INTO nodes (node_type, label) VALUES ('thing', 'Open merge duplicate') RETURNING id INTO v_dupe;
        INSERT INTO nodes (node_type, label) VALUES ('thing', 'Open merge canonical') RETURNING id INTO v_canon;
        PERFORM record_assertion(
            'helper_merge', '{"value":"kept"}', v_dupe,
            p_assertion_key := 'default', p_basis := 'assumed'
        );
        PERFORM merge_nodes(v_dupe, v_canon, 'test:lifecycle-gate');
        IF NOT EXISTS (
            SELECT 1 FROM assertions
            WHERE subject_node_id = v_canon
              AND assertion_type = 'helper_merge'
              AND status = 'accepted'
              AND superseded_at IS NULL
        ) THEN
            RAISE EXCEPTION 'merge_nodes under an open policy did not carry the assertion across accepted';
        END IF;
    END;

    -- ------------------------------------------------------------------
    -- The profile helpers that write assertions.
    -- ------------------------------------------------------------------
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('pipeline', 'Lifecycle gate pipeline',
            '{"suite":"lifecycle_gate","code":"LGP","default_stage":"prospecting"}')
    RETURNING id INTO v_pipeline;

    v_opp := create_opportunity(
        p_name := 'Lifecycle gate opportunity', p_pipeline_code := 'LGP',
        p_assigned_to_id := v_owner, p_properties := '{"suite":"lifecycle_gate"}'
    );
    IF NOT EXISTS (
        SELECT 1 FROM current_valid_assertions
        WHERE subject_node_id = v_opp AND assertion_type = 'deal_stage'
          AND claim->>'stage' = 'prospecting'
    ) THEN
        RAISE EXCEPTION 'create_opportunity did not write an accepted deal_stage';
    END IF;

    PERFORM advance_deal_stage(v_opp, 'qualified', 'Budget confirmed', 'test:lifecycle-gate');
    IF NOT EXISTS (
        SELECT 1 FROM current_valid_assertions
        WHERE subject_node_id = v_opp AND assertion_type = 'deal_stage'
          AND claim->>'stage' = 'qualified'
    ) THEN
        RAISE EXCEPTION 'advance_deal_stage did not move the stage';
    END IF;

    v_id := schedule_deal_stage_change(v_opp, 'proposal', v_when, 'Planned', 'test:lifecycle-gate');
    IF (SELECT effective_at FROM assertions WHERE id = v_id) IS DISTINCT FROM v_when THEN
        RAISE EXCEPTION 'schedule_deal_stage_change did not schedule the change';
    END IF;

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('project', 'Lifecycle gate project', '{"suite":"lifecycle_gate","code":"LGPRJ"}')
    RETURNING id INTO v_project;

    v_task := create_task(p_title := 'Lifecycle gate task', p_assigned_to_id := v_owner);
    IF NOT EXISTS (
        SELECT 1 FROM current_valid_assertions
        WHERE subject_node_id = v_task AND assertion_type = 'task_status'
    ) THEN
        RAISE EXCEPTION 'create_task did not write an accepted task_status';
    END IF;

    PERFORM advance_task_status(v_task, 'in_progress', 'Started', 'test:lifecycle-gate');
    IF NOT EXISTS (
        SELECT 1 FROM current_valid_assertions
        WHERE subject_node_id = v_task AND assertion_type = 'task_status'
          AND claim->>'status' = 'in_progress'
    ) THEN
        RAISE EXCEPTION 'advance_task_status did not move the status';
    END IF;

    v_id := schedule_task_status_change(v_task, 'done', v_when, 'Planned', 'test:lifecycle-gate');
    IF (SELECT effective_at FROM assertions WHERE id = v_id) IS DISTINCT FROM v_when THEN
        RAISE EXCEPTION 'schedule_task_status_change did not schedule the change';
    END IF;

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('milestone', 'Lifecycle gate milestone', '{"suite":"lifecycle_gate","code":"LGM"}')
    RETURNING id INTO v_milestone;
    PERFORM record_assertion(
        'milestone_status', '{"status":"planned"}', v_milestone, p_basis := 'assumed'
    );
    v_id := schedule_milestone_status_change(v_milestone, 'reached', v_when, 'Planned', 'test:lifecycle-gate');
    IF (SELECT effective_at FROM assertions WHERE id = v_id) IS DISTINCT FROM v_when THEN
        RAISE EXCEPTION 'schedule_milestone_status_change did not schedule the change';
    END IF;
    IF (SELECT effective_to FROM current_valid_assertions
        WHERE subject_node_id = v_milestone AND assertion_type = 'milestone_status') IS DISTINCT FROM v_when
    THEN
        RAISE EXCEPTION 'The scheduled milestone change did not narrow the standing window';
    END IF;

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('workflow_template', 'Lifecycle gate workflow',
            '{"suite":"lifecycle_gate","steps":[{"order":1,"title_template":"Prepare {thing}","task_type":"prep"}]}')
    RETURNING id INTO v_template;
    v_tasks := instantiate_workflow(v_template, v_project, '{"thing":"the report"}');
    IF coalesce(array_length(v_tasks, 1), 0) <> 1 THEN
        RAISE EXCEPTION 'instantiate_workflow created % tasks', coalesce(array_length(v_tasks, 1), 0);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM current_valid_assertions
        WHERE subject_node_id = v_tasks[1] AND assertion_type = 'task_status'
    ) THEN
        RAISE EXCEPTION 'instantiate_workflow did not write an accepted task_status';
    END IF;

    -- Every helper above wrote rows whose commit-time checks are still
    -- pending. This suite rolls back, so nothing would ever check them.
    -- Forcing them here is what makes "the helper still works" mean the
    -- helper still commits.
    SET CONSTRAINTS ALL IMMEDIATE;
END
$$;

ROLLBACK;
