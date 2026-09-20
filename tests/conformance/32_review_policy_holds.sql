-- Review policy holds on every route.
--
-- Contract:  contracts/sql-surface.md, "Review policy holds on every route".
-- Decision:  docs/decisions/0010-review-policy-holds-on-every-route.md.
-- Work item: work/010-review-policy-holds.md.
--
-- The obligations from section H of the decision. Obligation 12 (test 31 no
-- longer pins scope ids) lives in tests/conformance/31_assertion_lifecycle_gate.sql
-- where the case already is; obligations 15 and 16 are run-level and are
-- recorded in the work item, not here.
--
-- Every case runs under a non-superuser role, forges the helper-owned session
-- settings where the raw route needs them, and reads its results back as admin
-- where the acting role could not see them. Invented names only: Wren, Tobin,
-- Marsh.

SET search_path = rye, public, pg_catalog;

BEGIN;

-- --------------------------------------------------------------------------
-- Obligation 1. Refuse to pass vacuously.
--
-- A superuser, or a role with BYPASSRLS, sees past every policy below, and with
-- row_security off so does everyone. Under scripts/conformance.sh the suite runs
-- as rye_conformance through SET ROLE; under scripts/test-nonsuperuser-owner.sh
-- there is no SET ROLE and it runs as the non-superuser owner. Both must be
-- bound by RLS, so both attributes are asserted.
--
-- `SET app.current_role = ...` is a syntax error because current_role is
-- reserved, so every case uses set_config() and asserts the read-back.
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

    FOREACH v_role IN ARRAY ARRAY['agent:t', 'team_member', 'admin'] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION
                'Refusing to pass vacuously: app.current_role did not read back as "%", it reads "%"',
                v_role, current_setting('app.current_role', true);
        END IF;
    END LOOP;

    -- And prove RLS behaviourally on the table these routes write.
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:review-policy', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Wren', '{"suite":"review_policy"}')
    RETURNING id INTO v_node;

    v_probe := record_assertion(
        'compensation', '{"value":"rls probe"}', v_node,
        p_assertion_key := 'review_policy:rls_probe', p_basis := 'assumed'
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
-- Obligations 2, 3, 4, 5. supersede_assertion() and the review policy.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_cand_scope   uuid;
    v_gate         jsonb;
    v_incumbent    uuid;
    v_new          assertions;
    v_open_subject uuid;
    v_paired       uuid;
    v_policy       text;
    v_replacement  uuid;
    v_role         text;
    v_settled      uuid;
    v_strict_scope uuid;
    v_subject      uuid;
    v_roles        text[] := ARRAY['agent:t', 'team_member', 'admin'];
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:review-policy', true);
    PERFORM set_config('app.current_teams', '', true);

    -- Two demoting scopes: strict, and candidates_only, which demotes every
    -- basis except observed.
    INSERT INTO nodes (node_type, label) VALUES ('onboarding_scope', 'Route strict scope')
    RETURNING id INTO v_strict_scope;
    PERFORM record_assertion('review_policy', '{"review_policy":"strict"}', v_strict_scope, p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_strict_scope, p_basis := 'assumed');

    INSERT INTO nodes (node_type, label) VALUES ('onboarding_scope', 'Route candidates_only scope')
    RETURNING id INTO v_cand_scope;
    PERFORM record_assertion('review_policy', '{"review_policy":"candidates_only"}', v_cand_scope, p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_cand_scope, p_basis := 'assumed');

    IF scope_review_policy(v_strict_scope) <> 'strict'
       OR scope_review_policy(v_cand_scope) <> 'candidates_only'
    THEN
        RAISE EXCEPTION 'Premise broken: the fixture scopes are % and %',
            scope_review_policy(v_strict_scope), scope_review_policy(v_cand_scope);
    END IF;

    -- ==================================================================
    -- Obligation 2. Under strict, and under candidates_only with a
    -- non-observed basis, as agent:t, team_member and admin:
    -- supersede_assertion() returns an id whose row is a candidate, the
    -- incumbent is still accepted with superseded_at null, the candidate
    -- is in review_queue, and attrs.review_gate.pending is true. All four,
    -- not the status alone. admin is in the list because the review policy
    -- is not a role rule.
    --
    -- Obligation 3. The same claim through record_assertion() for the same
    -- caller and the same scope also lands candidate. That pairing is how
    -- the acceptance criterion is written, and a suite that does not
    -- assert it cannot show the two helpers agree.
    -- ==================================================================
    FOREACH v_policy IN ARRAY ARRAY['strict', 'candidates_only'] LOOP
        FOREACH v_role IN ARRAY v_roles LOOP
            PERFORM set_config('app.current_role', 'admin', true);
            INSERT INTO nodes (node_type, label, properties)
            VALUES ('thing', 'Tobin route subject', '{"suite":"review_policy"}')
            RETURNING id INTO v_subject;

            -- Recorded before the scope covers it, so the incumbent really
            -- is accepted and there is something to lose.
            v_incumbent := record_assertion(
                'route_probe', '{"value":"standing"}', v_subject,
                p_assertion_key := 'default', p_basis := 'assumed'
            );
            IF (SELECT status FROM assertions WHERE id = v_incumbent) <> 'accepted' THEN
                RAISE EXCEPTION 'Premise broken: the incumbent is not accepted';
            END IF;

            INSERT INTO edges (edge_type, source_id, target_id)
            VALUES ('scope_governs_subject',
                    CASE v_policy WHEN 'strict' THEN v_strict_scope ELSE v_cand_scope END,
                    v_subject);
            IF scope_review_policy(governing_scope(v_subject, NULL, 'route_probe', NULL)) <> v_policy THEN
                RAISE EXCEPTION 'Premise broken: the subject resolves to %, not %',
                    scope_review_policy(governing_scope(v_subject, NULL, 'route_probe', NULL)), v_policy;
            END IF;

            PERFORM set_config('app.current_role', v_role, true);
            IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
                RAISE EXCEPTION 'Refusing to pass vacuously: the role did not read back as "%"', v_role;
            END IF;
            IF NOT EXISTS (SELECT 1 FROM assertions WHERE id = v_incumbent) THEN
                RAISE EXCEPTION
                    'Refusing to pass vacuously: role "%" cannot see the incumbent it is superseding', v_role;
            END IF;

            v_replacement := supersede_assertion(
                v_incumbent, 'route_probe', v_subject, NULL, '{"value":"correction"}',
                p_new_assertion_key := 'default', p_new_basis := 'assumed'
            );

            PERFORM set_config('app.current_role', 'admin', true);
            SELECT * INTO v_new FROM assertions WHERE id = v_replacement;
            IF v_new.status <> 'candidate' THEN
                RAISE EXCEPTION
                    'Under % as "%", supersede_assertion() landed the replacement %, not candidate',
                    v_policy, v_role, v_new.status;
            END IF;
            IF v_new.claim IS DISTINCT FROM '{"value":"correction"}'::jsonb THEN
                RAISE EXCEPTION 'The demoted replacement lost the claim: %', v_new.claim;
            END IF;

            SELECT * INTO v_new FROM assertions WHERE id = v_incumbent;
            IF v_new.status <> 'accepted' OR v_new.superseded_at IS NOT NULL
               OR v_new.superseded_by IS NOT NULL
            THEN
                RAISE EXCEPTION
                    'Under % as "%", the incumbent was ended: status %, superseded_at %, superseded_by %',
                    v_policy, v_role, v_new.status, v_new.superseded_at, v_new.superseded_by;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM current_valid_assertions
                WHERE id = v_incumbent AND claim->>'value' = 'standing'
            ) THEN
                RAISE EXCEPTION 'Under % as "%", the incumbent is no longer current', v_policy, v_role;
            END IF;

            IF NOT EXISTS (
                SELECT 1 FROM review_queue q
                WHERE q.subject_node_id = v_subject
                  AND q.assertion_type = 'route_probe'
                  AND q.candidates @> jsonb_build_array(
                      jsonb_build_object('assertion_id', v_replacement)
                  )
            ) THEN
                RAISE EXCEPTION
                    'Under % as "%", the demoted replacement is not waiting in review_queue',
                    v_policy, v_role;
            END IF;

            SELECT attrs->'review_gate' INTO v_gate FROM assertions WHERE id = v_replacement;
            IF coalesce((v_gate->>'pending')::boolean, false) IS NOT true
               OR v_gate->>'requested_status' <> 'accepted'
               OR v_gate->>'review_policy' <> v_policy
               OR (v_gate->>'incumbent_assertion_id')::uuid IS DISTINCT FROM v_incumbent
            THEN
                RAISE EXCEPTION
                    'Under % as "%", attrs.review_gate is %', v_policy, v_role, v_gate;
            END IF;

            -- Obligation 3, on the same tuple and the same caller.
            PERFORM set_config('app.current_role', v_role, true);
            v_paired := record_assertion(
                'route_probe', '{"value":"the same claim by the other route"}', v_subject,
                p_assertion_key := 'default', p_status := 'accepted', p_basis := 'assumed'
            );
            PERFORM set_config('app.current_role', 'admin', true);
            IF (SELECT status FROM assertions WHERE id = v_paired) <> 'candidate' THEN
                RAISE EXCEPTION
                    'Under % as "%", record_assertion() landed % where supersede_assertion() demoted; the two routes disagree',
                    v_policy, v_role, (SELECT status FROM assertions WHERE id = v_paired);
            END IF;
            IF (SELECT superseded_at FROM assertions WHERE id = v_incumbent) IS NOT NULL THEN
                RAISE EXCEPTION 'record_assertion() ended the incumbent it demoted around';
            END IF;
        END LOOP;
    END LOOP;

    -- ==================================================================
    -- Obligation 4. Nothing said is lost, end to end: a settler accepts
    -- the demoted candidate and that supersedes the incumbent.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'admin', true);
    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Marsh settled subject')
    RETURNING id INTO v_subject;
    v_incumbent := record_assertion(
        'settle_route_probe', '{"value":"standing"}', v_subject,
        p_assertion_key := 'default', p_basis := 'assumed'
    );
    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('scope_governs_subject', v_strict_scope, v_subject);

    PERFORM set_config('app.current_role', 'team_member', true);
    v_settled := supersede_assertion(
        v_incumbent, 'settle_route_probe', v_subject, NULL, '{"value":"accepted later"}',
        p_new_assertion_key := 'default', p_new_basis := 'assumed'
    );
    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT status FROM assertions WHERE id = v_settled) <> 'candidate' THEN
        RAISE EXCEPTION 'Premise broken: the settle fixture did not produce a candidate';
    END IF;

    PERFORM accept_assertion(v_settled, NULL, 'Reviewed', 'test:review-policy');
    -- A deferred refusal is a refusal, so force the commit-time checks here
    -- rather than trusting a suite that ends in ROLLBACK.
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;

    IF (SELECT status FROM assertions WHERE id = v_settled) <> 'accepted' THEN
        RAISE EXCEPTION 'accept_assertion() did not promote the demoted replacement';
    END IF;
    IF (SELECT superseded_by FROM assertions WHERE id = v_incumbent) IS DISTINCT FROM v_settled THEN
        RAISE EXCEPTION
            'Accepting the candidate did not supersede the incumbent: superseded_by is %',
            (SELECT superseded_by FROM assertions WHERE id = v_incumbent);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM current_valid_assertions
        WHERE id = v_settled AND claim->>'value' = 'accepted later'
    ) THEN
        RAISE EXCEPTION 'current_valid_assertions does not carry the accepted replacement';
    END IF;

    -- ==================================================================
    -- Obligation 5. Where record_assertion() would land accepted,
    -- supersede_assertion() behaves exactly as before: under open, and
    -- under candidates_only with basis observed. The replacement is
    -- accepted, the incumbent is superseded and names it, and attrs
    -- carries no review_gate key at all.
    -- ==================================================================
    FOREACH v_policy IN ARRAY ARRAY['open', 'candidates_only'] LOOP
        FOREACH v_role IN ARRAY v_roles LOOP
            PERFORM set_config('app.current_role', 'admin', true);
            INSERT INTO nodes (node_type, label) VALUES ('thing', 'Wren undemoted subject')
            RETURNING id INTO v_open_subject;
            v_incumbent := record_assertion(
                'undemoted_probe', '{"value":"standing"}', v_open_subject,
                p_assertion_key := 'default', p_basis := 'assumed'
            );
            IF v_policy = 'candidates_only' THEN
                INSERT INTO edges (edge_type, source_id, target_id)
                VALUES ('scope_governs_subject', v_cand_scope, v_open_subject);
            END IF;
            IF scope_review_policy(governing_scope(v_open_subject, NULL, 'undemoted_probe', NULL))
               <> v_policy
            THEN
                RAISE EXCEPTION 'Premise broken: the undemoted fixture is %',
                    scope_review_policy(governing_scope(v_open_subject, NULL, 'undemoted_probe', NULL));
            END IF;

            PERFORM set_config('app.current_role', v_role, true);
            v_replacement := supersede_assertion(
                v_incumbent, 'undemoted_probe', v_open_subject, NULL, '{"value":"replaced"}',
                p_new_assertion_key := 'default',
                -- observed is the basis candidates_only leaves alone; under
                -- open the basis makes no difference and this keeps one shape.
                p_new_basis := 'observed'
            );

            PERFORM set_config('app.current_role', 'admin', true);
            SELECT * INTO v_new FROM assertions WHERE id = v_replacement;
            IF v_new.status <> 'accepted' THEN
                RAISE EXCEPTION
                    'Under % as "%", supersede_assertion() demoted a write record_assertion() would have accepted: %',
                    v_policy, v_role, v_new.status;
            END IF;
            IF v_new.attrs ? 'review_gate' THEN
                RAISE EXCEPTION
                    'Under % as "%", an undemoted replacement carries attrs.review_gate: %',
                    v_policy, v_role, v_new.attrs;
            END IF;
            SELECT * INTO v_new FROM assertions WHERE id = v_incumbent;
            IF v_new.superseded_at IS NULL OR v_new.superseded_by IS DISTINCT FROM v_replacement THEN
                RAISE EXCEPTION
                    'Under % as "%", the incumbent was not superseded by its replacement',
                    v_policy, v_role;
            END IF;

            -- And record_assertion() agrees, which is the other half of the
            -- pairing: the same caller landing accepted through both routes.
            PERFORM set_config('app.current_role', v_role, true);
            v_paired := record_assertion(
                'undemoted_probe', '{"value":"by the other route"}', v_open_subject,
                p_assertion_key := 'default', p_status := 'accepted', p_basis := 'observed',
                p_evidence := ARRAY[jsonb_build_object(
                    'kind', 'derivation', 'source_assertion_id', v_replacement
                )]
            );
            PERFORM set_config('app.current_role', 'admin', true);
            IF (SELECT status FROM assertions WHERE id = v_paired) <> 'accepted' THEN
                RAISE EXCEPTION
                    'Under % as "%", record_assertion() demoted where supersede_assertion() did not',
                    v_policy, v_role;
            END IF;
        END LOOP;
    END LOOP;

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
END
$$;

-- --------------------------------------------------------------------------
-- Obligations 6 and 7. The helper that follows supersede_assertion(), and the
-- helpers that must not change.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_answer     uuid;
    v_digest     uuid;
    v_digest_two uuid;
    v_event      jsonb;
    v_gap        uuid;
    v_new_gap    uuid;
    v_scheduled  uuid;
    v_scope      uuid;
    v_source     uuid;
    v_subject    uuid;
    v_task       uuid;
    v_when       timestamptz := now() + interval '10 days';
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:review-policy', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label) VALUES ('onboarding_scope', 'Helper strict scope')
    RETURNING id INTO v_scope;
    PERFORM record_assertion('review_policy', '{"review_policy":"strict"}', v_scope, p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_scope, p_basis := 'assumed');

    -- ==================================================================
    -- Obligation 6. resolve_knowledge_gap() under strict: the resolution
    -- is a candidate, the knowledge_gap row is still open and still in
    -- open_gaps, and the knowledge_gap_resolved event carries
    -- pending_review true. Under open it closes the gap exactly as it does
    -- today, which tests/conformance/25_core_model_v2.sql asserts
    -- unmodified.
    -- ==================================================================
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('thing', 'Tobin gap subject', '{"suite":"review_policy"}')
    RETURNING id INTO v_subject;

    v_gap := record_assertion(
        'knowledge_gap', '{"question":"who owns this","status":"open"}', v_subject,
        p_assertion_key := 'route_gap', p_basis := 'assumed'
    );
    v_answer := record_assertion(
        'gap_answer', '{"value":"Marsh"}', v_subject,
        p_assertion_key := 'route_gap_answer', p_basis := 'assumed'
    );
    IF NOT EXISTS (SELECT 1 FROM open_gaps WHERE id = v_gap) THEN
        RAISE EXCEPTION 'Premise broken: the gap is not open before the scope covers it';
    END IF;

    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('scope_governs_subject', v_scope, v_subject);
    IF scope_review_policy(governing_scope(v_subject, NULL, 'knowledge_gap', NULL)) <> 'strict' THEN
        RAISE EXCEPTION 'Premise broken: the gap subject is not under a strict policy';
    END IF;

    PERFORM set_config('app.current_role', 'team_member', true);
    PERFORM resolve_knowledge_gap(v_gap, v_answer, 'test:review-policy');
    PERFORM set_config('app.current_role', 'admin', true);

    SELECT id INTO v_new_gap
    FROM assertions
    WHERE subject_node_id = v_subject
      AND assertion_type = 'knowledge_gap'
      AND assertion_key = 'route_gap'
      AND id <> v_gap;
    IF v_new_gap IS NULL THEN
        RAISE EXCEPTION 'resolve_knowledge_gap() wrote no resolution at all';
    END IF;
    IF (SELECT status FROM assertions WHERE id = v_new_gap) <> 'candidate' THEN
        RAISE EXCEPTION
            'resolve_knowledge_gap() under strict filed the resolution as %',
            (SELECT status FROM assertions WHERE id = v_new_gap);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM assertions
        WHERE id = v_new_gap AND (attrs->'review_gate'->>'pending')::boolean
    ) THEN
        RAISE EXCEPTION 'The filed resolution carries no review_gate marker';
    END IF;
    IF (SELECT superseded_at FROM assertions WHERE id = v_gap) IS NOT NULL THEN
        RAISE EXCEPTION 'resolve_knowledge_gap() under strict closed the gap anyway';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM open_gaps WHERE id = v_gap) THEN
        RAISE EXCEPTION 'The unresolved gap left open_gaps, so a reader is told it closed';
    END IF;

    SELECT properties INTO v_event
    FROM events
    WHERE event_type = 'knowledge_gap_resolved'
      AND properties->>'gap_assertion_id' = v_gap::text
    ORDER BY occurred_at DESC
    LIMIT 1;
    IF v_event IS NULL THEN
        RAISE EXCEPTION 'resolve_knowledge_gap() recorded no event; the act did happen';
    END IF;
    IF coalesce((v_event->>'pending_review')::boolean, false) IS NOT true
       OR v_event->>'review_policy' <> 'strict'
       OR (v_event->>'resolved_gap_assertion_id')::uuid IS DISTINCT FROM v_new_gap
    THEN
        RAISE EXCEPTION
            'The knowledge_gap_resolved event does not say the resolution is waiting: %', v_event;
    END IF;

    -- ==================================================================
    -- Obligation 7. The helpers that must not change, each asserted by
    -- effect. record_distillation() applies the policy itself and only
    -- supersedes the digest incumbent when its own write is accepted;
    -- schedule_assertion_change() reaches record_assertion(), which
    -- already demoted; the profile helpers reach record_assertion() too.
    -- ==================================================================
    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Wren digest subject')
    RETURNING id INTO v_subject;
    v_source := record_assertion(
        'digest_source', '{"value":"raw"}', v_subject, p_basis := 'assumed'
    );
    v_digest := record_distillation(
        p_subject_node_id := v_subject, p_subject_edge_id := NULL,
        p_assertion_key := 'route_digest', p_claim := '{"summary":"first"}',
        p_source_assertion_ids := ARRAY[v_source], p_source_event_ids := '{}'::uuid[],
        p_agent := 'test:review-policy'
    );
    IF (SELECT status FROM assertions WHERE id = v_digest) <> 'accepted' THEN
        RAISE EXCEPTION 'Premise broken: the first digest is not accepted';
    END IF;

    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('scope_governs_subject', v_scope, v_subject);
    v_digest_two := record_distillation(
        p_subject_node_id := v_subject, p_subject_edge_id := NULL,
        p_assertion_key := 'route_digest', p_claim := '{"summary":"second"}',
        p_source_assertion_ids := ARRAY[v_source], p_source_event_ids := '{}'::uuid[],
        p_agent := 'test:review-policy'
    );
    IF (SELECT status FROM assertions WHERE id = v_digest_two) <> 'candidate' THEN
        RAISE EXCEPTION
            'record_distillation() under strict landed %', (SELECT status FROM assertions WHERE id = v_digest_two);
    END IF;
    IF (SELECT superseded_at FROM assertions WHERE id = v_digest) IS NOT NULL THEN
        RAISE EXCEPTION 'record_distillation() under strict ended the digest incumbent';
    END IF;

    v_scheduled := schedule_assertion_change(
        p_subject_node_id := v_subject, p_subject_edge_id := NULL,
        p_assertion_type := 'scheduled_probe', p_assertion_key := 'default',
        p_claim := '{"value":"later"}', p_effective_at := v_when,
        p_basis := 'assumed'
    );
    IF (SELECT status FROM assertions WHERE id = v_scheduled) <> 'candidate' THEN
        RAISE EXCEPTION
            'schedule_assertion_change() under strict landed %',
            (SELECT status FROM assertions WHERE id = v_scheduled);
    END IF;

    -- One profile helper, on an ungoverned task, still works end to end.
    v_task := create_task(p_title := 'Route policy task');
    PERFORM advance_task_status(v_task, 'in_progress', 'Started', 'test:review-policy');
    IF NOT EXISTS (
        SELECT 1 FROM current_valid_assertions
        WHERE subject_node_id = v_task AND assertion_type = 'task_status'
          AND claim->>'status' = 'in_progress'
    ) THEN
        RAISE EXCEPTION 'advance_task_status() did not move the status';
    END IF;

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
END
$$;

-- --------------------------------------------------------------------------
-- Obligations 8 and 9. The raw supersede-and-replace route, which agrees with
-- the helper by refusing.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_failed     boolean;
    v_incumbent  uuid;
    v_msg        text;
    v_replacement uuid;
    v_role       text;
    v_rows       integer;
    v_scope      uuid;
    v_subject    uuid;
    v_roles      text[] := ARRAY['agent:t', 'team_member', 'admin'];
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:review-policy', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label) VALUES ('onboarding_scope', 'Raw route strict scope')
    RETURNING id INTO v_scope;
    PERFORM record_assertion('review_policy', '{"review_policy":"strict"}', v_scope, p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_scope, p_basis := 'assumed');

    -- ==================================================================
    -- Obligation 8. Under strict, with every supersede setting forged: end
    -- an accepted row naming a fresh id, insert that id accepted on the
    -- same tuple. The insert is demoted, the tuple then carries nothing
    -- accepted, and the transaction is refused at the deferred check. A
    -- plpgsql EXCEPTION block does not see a deferred trigger, so the
    -- check is forced inside the block.
    -- ==================================================================
    FOREACH v_role IN ARRAY v_roles LOOP
        PERFORM set_config('app.current_role', 'admin', true);
        INSERT INTO nodes (node_type, label) VALUES ('thing', 'Raw route subject')
        RETURNING id INTO v_subject;
        v_incumbent := record_assertion(
            'raw_route_probe', '{"value":"standing"}', v_subject,
            p_assertion_key := 'default', p_basis := 'assumed'
        );
        INSERT INTO edges (edge_type, source_id, target_id)
        VALUES ('scope_governs_subject', v_scope, v_subject);
        IF scope_review_policy(governing_scope(v_subject, NULL, 'raw_route_probe', NULL)) <> 'strict' THEN
            RAISE EXCEPTION 'Premise broken: the raw-route subject is not under strict';
        END IF;

        PERFORM set_config('app.current_role', v_role, true);
        IF NOT EXISTS (SELECT 1 FROM assertions WHERE id = v_incumbent) THEN
            RAISE EXCEPTION
                'Refusing to pass vacuously: role "%" cannot see the row it is attacking', v_role;
        END IF;

        v_failed := false;
        v_replacement := gen_random_uuid();
        BEGIN
            PERFORM set_config('app.write_path', 'supersede_assertion', true);
            PERFORM set_config('app.supersede_assertion_id', v_incumbent::text, true);
            UPDATE assertions SET superseded_at = now(), superseded_by = v_replacement
            WHERE id = v_incumbent;
            GET DIAGNOSTICS v_rows = ROW_COUNT;
            PERFORM set_config('app.write_path', '', true);
            IF v_rows <> 1 THEN
                RAISE EXCEPTION
                    'Premise broken: role "%" could not end the accepted row, so the route never starts',
                    v_role;
            END IF;
            INSERT INTO assertions (
                id, assertion_type, assertion_key, status, basis, subject_node_id, claim
            ) VALUES (
                v_replacement, 'raw_route_probe', 'default', 'accepted', 'assumed',
                v_subject, '{"value":"raw replacement"}'
            );
            IF (SELECT status FROM assertions WHERE id = v_replacement) <> 'candidate' THEN
                RAISE EXCEPTION
                    'Role "%" landed a raw accepted replacement under strict: the insert exemption is still in place',
                    v_role;
            END IF;
            SET CONSTRAINTS trg_assertions_transition_complete IMMEDIATE;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        SET CONSTRAINTS trg_assertions_transition_complete DEFERRED;
        PERFORM set_config('app.write_path', '', true);

        IF NOT v_failed THEN
            RAISE EXCEPTION
                'Role "%" committed a raw supersede-and-replace under strict', v_role;
        END IF;
        IF v_msg NOT LIKE '%left with no accepted assertion standing%' THEN
            RAISE EXCEPTION 'Role "%" was refused for an unexpected reason: %', v_role, v_msg;
        END IF;

        -- Read back as admin: the attacker's own view proves nothing.
        PERFORM set_config('app.current_role', 'admin', true);
        IF (SELECT superseded_at FROM assertions WHERE id = v_incumbent) IS NOT NULL THEN
            RAISE EXCEPTION 'Role "%" left the incumbent ended after the refusal', v_role;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM current_valid_assertions
            WHERE id = v_incumbent AND claim->>'value' = 'standing'
        ) THEN
            RAISE EXCEPTION 'Role "%" emptied the key: nothing is lost is false', v_role;
        END IF;

        -- And nothing is lost by the honest route either: the same statement
        -- through supersede_assertion() is recorded as a suggestion beside
        -- the incumbent.
        PERFORM set_config('app.current_role', v_role, true);
        v_replacement := supersede_assertion(
            v_incumbent, 'raw_route_probe', v_subject, NULL, '{"value":"raw replacement"}',
            p_new_assertion_key := 'default', p_new_basis := 'assumed'
        );
        PERFORM set_config('app.current_role', 'admin', true);
        IF (SELECT status FROM assertions WHERE id = v_replacement) <> 'candidate' THEN
            RAISE EXCEPTION 'The honest route did not file the refused statement as a candidate';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM review_queue
            WHERE subject_node_id = v_subject AND assertion_type = 'raw_route_probe'
        ) THEN
            RAISE EXCEPTION 'The filed statement is not in review_queue';
        END IF;
    END LOOP;

    -- ==================================================================
    -- Obligation 9. The honest half of 0008 obligation 15 still holds
    -- under a non-demoting policy: the same raw shape under open commits
    -- accepted, exactly as before.
    -- ==================================================================
    FOREACH v_role IN ARRAY v_roles LOOP
        PERFORM set_config('app.current_role', 'admin', true);
        INSERT INTO nodes (node_type, label) VALUES ('thing', 'Raw open subject')
        RETURNING id INTO v_subject;
        v_incumbent := record_assertion(
            'raw_open_probe', '{"value":"standing"}', v_subject,
            p_assertion_key := 'default', p_basis := 'assumed'
        );
        IF scope_review_policy(governing_scope(v_subject, NULL, 'raw_open_probe', NULL)) <> 'open' THEN
            RAISE EXCEPTION 'Premise broken: the raw open fixture is not under an open policy';
        END IF;

        PERFORM set_config('app.current_role', v_role, true);
        v_replacement := gen_random_uuid();
        PERFORM set_config('app.write_path', 'supersede_assertion', true);
        PERFORM set_config('app.supersede_assertion_id', v_incumbent::text, true);
        UPDATE assertions SET superseded_at = now(), superseded_by = v_replacement
        WHERE id = v_incumbent;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        PERFORM set_config('app.write_path', '', true);
        IF v_rows <> 1 THEN
            RAISE EXCEPTION 'Premise broken: role "%" could not end the open-scope row', v_role;
        END IF;
        INSERT INTO assertions (
            id, assertion_type, assertion_key, status, basis, subject_node_id, claim
        ) VALUES (
            v_replacement, 'raw_open_probe', 'default', 'accepted', 'assumed',
            v_subject, '{"value":"raw replacement"}'
        );
        SET CONSTRAINTS trg_assertions_transition_complete IMMEDIATE;
        SET CONSTRAINTS trg_assertions_transition_complete DEFERRED;

        PERFORM set_config('app.current_role', 'admin', true);
        IF (SELECT status FROM assertions WHERE id = v_replacement) <> 'accepted' THEN
            RAISE EXCEPTION
                'Under open, role "%" got % for a raw replacement; the shape used to commit accepted',
                v_role, (SELECT status FROM assertions WHERE id = v_replacement);
        END IF;
        IF (SELECT superseded_by FROM assertions WHERE id = v_incumbent) IS DISTINCT FROM v_replacement THEN
            RAISE EXCEPTION 'Under open, the incumbent does not name its raw replacement';
        END IF;
    END LOOP;

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
END
$$;

-- --------------------------------------------------------------------------
-- Obligations 10, 11 and 13. Several scopes, both id orders, and a scope whose
-- stored review_policy nobody supports.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_a          uuid;
    v_b          uuid;
    v_broken     uuid;
    v_canonical  uuid;
    v_copy       assertions;
    v_duplicate  uuid;
    v_failed     boolean;
    v_high       uuid;
    v_id         uuid;
    v_low        uuid;
    v_open       uuid;
    v_order      integer;
    v_probe      uuid;
    v_strict     uuid;
    v_subject    uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:review-policy', true);
    PERFORM set_config('app.current_teams', '', true);

    -- ==================================================================
    -- Obligation 10. Two active scopes, one open and one strict, both with
    -- a live scope_governs_subject edge onto one subject. The answer is
    -- strict whichever scope has the lower id. The ids are generated, not
    -- pinned: two fresh uuids are sorted and the strict role is given to
    -- the lower one on the first pass and to the higher one on the second,
    -- so both orders are covered without a literal uuid anywhere.
    -- ==================================================================
    FOR v_order IN 1..2 LOOP
        v_a := gen_random_uuid();
        v_b := gen_random_uuid();
        v_low := least(v_a, v_b);
        v_high := greatest(v_a, v_b);
        IF v_low = v_high THEN
            RAISE EXCEPTION 'Refusing to pass vacuously: the two generated scope ids are equal';
        END IF;
        IF v_order = 1 THEN
            v_strict := v_low; v_open := v_high;
        ELSE
            v_strict := v_high; v_open := v_low;
        END IF;

        INSERT INTO nodes (id, node_type, label)
        VALUES (v_strict, 'onboarding_scope', 'Multi strict scope');
        INSERT INTO nodes (id, node_type, label)
        VALUES (v_open, 'onboarding_scope', 'Multi open scope');
        PERFORM record_assertion('review_policy', '{"review_policy":"strict"}', v_strict, p_basis := 'assumed');
        PERFORM record_assertion('scope_status', '{"status":"active"}', v_strict, p_basis := 'assumed');
        PERFORM record_assertion('review_policy', '{"review_policy":"open"}', v_open, p_basis := 'assumed');
        PERFORM record_assertion('scope_status', '{"status":"active"}', v_open, p_basis := 'assumed');
        IF scope_review_policy(v_strict) <> 'strict' OR scope_review_policy(v_open) <> 'open' THEN
            RAISE EXCEPTION 'Premise broken: pass % did not build one strict and one open scope', v_order;
        END IF;

        INSERT INTO nodes (node_type, label) VALUES ('thing', 'Doubly governed subject')
        RETURNING id INTO v_subject;
        INSERT INTO edges (edge_type, source_id, target_id)
        VALUES ('scope_governs_subject', v_strict, v_subject);
        INSERT INTO edges (edge_type, source_id, target_id)
        VALUES ('scope_governs_subject', v_open, v_subject);

        IF governing_scope(v_subject, NULL, 'multi_probe', NULL) IS DISTINCT FROM v_strict THEN
            RAISE EXCEPTION
                'Pass % (strict id % open id %): governing_scope() returned %, not the strict scope',
                v_order, v_strict, v_open,
                governing_scope(v_subject, NULL, 'multi_probe', NULL);
        END IF;
        IF scope_review_policy(governing_scope(v_subject, NULL, 'multi_probe', NULL)) <> 'strict' THEN
            RAISE EXCEPTION 'Pass %: the doubly governed subject does not read strict', v_order;
        END IF;

        -- And it bites: a write on that subject lands as a candidate.
        v_probe := record_assertion(
            'multi_probe', '{"value":"written"}', v_subject,
            p_assertion_key := 'default', p_basis := 'assumed'
        );
        IF (SELECT status FROM assertions WHERE id = v_probe) <> 'candidate' THEN
            RAISE EXCEPTION 'Pass %: a write under two scopes landed %, not candidate',
                v_order, (SELECT status FROM assertions WHERE id = v_probe);
        END IF;

        -- ==============================================================
        -- Obligation 11. merge_nodes() across an open and a strict scope,
        -- in this id order: afterwards the surviving node reads strict and
        -- the copied assertion is a candidate in review_queue on the
        -- canonical node. Anti-vacuity first: the duplicate's side really
        -- reads open and the canonical's really reads strict.
        -- ==============================================================
        INSERT INTO nodes (node_type, label) VALUES ('thing', 'Merge duplicate')
        RETURNING id INTO v_duplicate;
        INSERT INTO nodes (node_type, label) VALUES ('thing', 'Merge canonical')
        RETURNING id INTO v_canonical;
        INSERT INTO edges (edge_type, source_id, target_id)
        VALUES ('scope_governs_subject', v_open, v_duplicate);
        INSERT INTO edges (edge_type, source_id, target_id)
        VALUES ('scope_governs_subject', v_strict, v_canonical);

        IF scope_review_policy(governing_scope(v_duplicate, NULL, 'merge_probe', NULL)) <> 'open'
           OR scope_review_policy(governing_scope(v_canonical, NULL, 'merge_probe', NULL)) <> 'strict'
        THEN
            RAISE EXCEPTION
                'Pass %: the merge fixture is not open/strict, it is %/%',
                v_order,
                scope_review_policy(governing_scope(v_duplicate, NULL, 'merge_probe', NULL)),
                scope_review_policy(governing_scope(v_canonical, NULL, 'merge_probe', NULL));
        END IF;

        v_id := record_assertion(
            'merge_probe', '{"value":"open side"}', v_duplicate,
            p_assertion_key := 'default', p_basis := 'assumed'
        );
        IF (SELECT status FROM assertions WHERE id = v_id) <> 'accepted' THEN
            RAISE EXCEPTION 'Pass %: the open-side source assertion is not accepted', v_order;
        END IF;

        PERFORM merge_nodes(v_duplicate, v_canonical, 'test:review-policy');

        IF scope_review_policy(governing_scope(v_canonical, NULL, 'merge_probe', NULL)) <> 'strict' THEN
            RAISE EXCEPTION
                'Pass % (strict id % open id %): after the merge the surviving node reads %, so a strict area went open',
                v_order, v_strict, v_open,
                scope_review_policy(governing_scope(v_canonical, NULL, 'merge_probe', NULL));
        END IF;

        SELECT * INTO v_copy
        FROM assertions
        WHERE subject_node_id = v_canonical AND assertion_type = 'merge_probe';
        IF v_copy.id IS NULL THEN
            RAISE EXCEPTION 'Pass %: the merge did not carry the assertion across', v_order;
        END IF;
        IF v_copy.status <> 'candidate' THEN
            RAISE EXCEPTION
                'Pass %: the copy landed % on the canonical node, so the duplicate''s open policy carried across',
                v_order, v_copy.status;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM review_queue
            WHERE subject_node_id = v_canonical AND assertion_type = 'merge_probe'
        ) THEN
            RAISE EXCEPTION 'Pass %: the copy is not waiting in review_queue', v_order;
        END IF;
    END LOOP;

    -- ==================================================================
    -- Obligation 13. scope_review_policy_rank() never raises. A scope
    -- carrying an unsupported review_policy value ranks as open, so it
    -- does not break a write on a subject a second scope also governs,
    -- while scope_review_policy() on that scope still raises.
    -- ==================================================================
    INSERT INTO nodes (node_type, label) VALUES ('onboarding_scope', 'Broken policy scope')
    RETURNING id INTO v_broken;
    PERFORM record_assertion('review_policy', '{"review_policy":"whenever"}', v_broken, p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_broken, p_basis := 'assumed');

    IF scope_review_policy_rank(v_broken) <> 2 THEN
        RAISE EXCEPTION 'A scope with an unsupported review_policy ranks %, not open',
            scope_review_policy_rank(v_broken);
    END IF;
    IF scope_review_policy_rank(NULL) <> 2 THEN
        RAISE EXCEPTION 'A null scope does not rank as open';
    END IF;
    IF scope_review_policy_rank(v_strict) <> 0 THEN
        RAISE EXCEPTION 'Premise broken: a strict scope does not rank 0';
    END IF;

    v_failed := false;
    BEGIN
        PERFORM scope_review_policy(v_broken);
    EXCEPTION WHEN OTHERS THEN
        v_failed := SQLERRM LIKE 'Unsupported review_policy%';
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'scope_review_policy() stopped raising on an unsupported stored value';
    END IF;

    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Neighbour of a broken scope')
    RETURNING id INTO v_subject;
    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('scope_governs_subject', v_broken, v_subject);
    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('scope_governs_subject', v_strict, v_subject);

    IF governing_scope(v_subject, NULL, 'broken_probe', NULL) IS DISTINCT FROM v_strict THEN
        RAISE EXCEPTION
            'The broken scope was selected over the strict one: %',
            governing_scope(v_subject, NULL, 'broken_probe', NULL);
    END IF;
    v_probe := record_assertion(
        'broken_probe', '{"value":"written next to a broken scope"}', v_subject,
        p_assertion_key := 'default', p_basis := 'assumed'
    );
    IF (SELECT status FROM assertions WHERE id = v_probe) <> 'candidate' THEN
        RAISE EXCEPTION
            'A write beside a broken scope landed %, not candidate',
            (SELECT status FROM assertions WHERE id = v_probe);
    END IF;

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
END
$$;

-- --------------------------------------------------------------------------
-- Obligation 14. The agent promotion gate follows the strictest scope.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_cand      uuid;
    v_failed    boolean;
    v_msg       text;
    v_open      uuid;
    v_strict    uuid;
    v_subject   uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:review-policy', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label) VALUES ('onboarding_scope', 'Promote open scope')
    RETURNING id INTO v_open;
    PERFORM record_assertion('review_policy', '{"review_policy":"open"}', v_open, p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_open, p_basis := 'assumed');

    INSERT INTO nodes (node_type, label) VALUES ('onboarding_scope', 'Promote strict scope')
    RETURNING id INTO v_strict;
    PERFORM record_assertion('review_policy', '{"review_policy":"strict"}', v_strict, p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_strict, p_basis := 'assumed');

    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Doubly governed promotion subject')
    RETURNING id INTO v_subject;
    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('scope_governs_subject', v_open, v_subject);
    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('scope_governs_subject', v_strict, v_subject);

    PERFORM create_agent_identity('route_open_agent', 'Route open agent', 'test');
    PERFORM create_agent_identity('route_strict_agent', 'Route strict agent', 'test');
    PERFORM grant_agent_capability(
        'route_open_agent', 'rye.authoritative.promote', p_scope_ref := v_open::text
    );
    PERFORM grant_agent_capability(
        'route_strict_agent', 'rye.authoritative.promote', p_scope_ref := v_strict::text
    );

    -- Anti-vacuity: the open-scope agent really does hold the capability it
    -- was granted, and really does not hold the other one. If neither were
    -- true the refusal below would prove nothing.
    PERFORM set_config('app.current_role', 'agent:route_open_agent', true);
    IF NOT agent_can_promote_in_scope(v_open) THEN
        RAISE EXCEPTION 'Premise broken: the open-scope agent does not hold its own grant';
    END IF;
    IF agent_can_promote_in_scope(v_strict) THEN
        RAISE EXCEPTION 'Premise broken: the open-scope agent holds the strict scope too';
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    v_cand := record_assertion(
        'promote_probe', '{"value":"suggested"}', v_subject,
        p_assertion_key := 'default', p_status := 'candidate', p_basis := 'assumed'
    );

    PERFORM set_config('app.current_role', 'agent:route_open_agent', true);
    PERFORM set_config('app.current_user_id', 'route_open_agent', true);
    v_failed := false;
    BEGIN
        PERFORM accept_assertion(v_cand);
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        v_msg := SQLERRM;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION
            'An agent holding promote for the looser of two governing scopes accepted anyway';
    END IF;
    IF v_msg NOT LIKE '%rye.authoritative.promote%' THEN
        RAISE EXCEPTION 'The agent acceptance was refused for the wrong reason: %', v_msg;
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT status FROM assertions WHERE id = v_cand) <> 'candidate' THEN
        RAISE EXCEPTION 'The refused acceptance still promoted the candidate';
    END IF;

    PERFORM set_config('app.current_role', 'agent:route_strict_agent', true);
    PERFORM set_config('app.current_user_id', 'route_strict_agent', true);
    PERFORM accept_assertion(v_cand, NULL, 'Reviewed', 'route_strict_agent');

    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:review-policy', true);
    IF (SELECT status FROM assertions WHERE id = v_cand) <> 'accepted' THEN
        RAISE EXCEPTION
            'An agent holding promote for the strictest governing scope could not accept';
    END IF;

    SET CONSTRAINTS ALL IMMEDIATE;
END
$$;

ROLLBACK;
