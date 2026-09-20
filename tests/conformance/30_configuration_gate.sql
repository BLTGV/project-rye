-- Configuration writes need an admin.
--
-- Contract:  contracts/sql-surface.md, "Configuration writes need an admin".
-- Decision:  docs/decisions/0007-configuration-writes-need-an-admin.md.
-- Work item: work/005-registry-write-gate.md.
--
-- The eleven obligations from the decision record, in order, plus the
-- anti-vacuity guards. Invented names only: Bob, John, Dana.

SET search_path = rye, public, pg_catalog;

BEGIN;

-- --------------------------------------------------------------------------
-- Anti-vacuity: RLS must actually be in force, or every case below would
-- pass for the wrong reason. A superuser bypasses RLS even when it is
-- forced, so this suite refuses to run as one. scripts/conformance.sh runs
-- SQL suites under a non-superuser role when the connection is a superuser.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_core    uuid;
    v_probe   uuid;
    v_seen    integer;
    v_super   boolean;
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

    -- And prove it behaviourally on the very table this gate protects: a
    -- read-gated assertion type written by an admin must be invisible to a
    -- viewer. If it is visible, RLS is not filtering and nothing below means
    -- anything.
    SELECT id INTO v_core
    FROM nodes
    WHERE external_source = 'rye_registry' AND external_id = 'core' AND archived_at IS NULL;
    IF v_core IS NULL THEN
        RAISE EXCEPTION 'Core registry node is missing; the install seeds did not run';
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:configuration-gate', true);
    PERFORM set_config('app.current_teams', '', true);

    v_probe := record_assertion(
        'compensation', '{"value":"rls probe"}', v_core,
        p_assertion_key := 'conformance_gate:rls_probe', p_basis := 'assumed'
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
-- The gate itself, and the eleven obligations.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_after        jsonb;
    v_agent_id     uuid;
    v_alias_cand   uuid;
    v_answer       jsonb;
    v_area_agent   uuid;
    -- Who asks the settlement question, before and after the attacks. Each
    -- role is always compared with its own earlier answer, never with an
    -- admin's. contracts/sql-surface.md, "Governance tables: who reads, who
    -- writes", and the settlement lookup's "Who may call it, and what each
    -- caller sees", give a session that cannot see the area
    -- domain_not_found, so an admin baseline is not the answer a blind
    -- caller is owed. The list holds a bound agent that may see the fixture
    -- area, an agent-shaped role bound to no identity, and an unset role.
    v_ask_roles    text[] := ARRAY[
        'admin', 'agent:config_gate_area', 'agent:t', 'viewer', 'team_member', ''
    ];
    -- Who tries to settle configuration. Since migration 0026
    -- (docs/decisions/0009-who-may-write.md) `viewer` and an unset role may not
    -- write the core tables at all, so they never reach the settle gate: their
    -- INSERTs raise 42501 and their UPDATEs affect zero rows silently. They
    -- stay in v_ask_roles above, which only reads, and their refusals are
    -- covered by tests/conformance/32_who_may_write.sql. What is left here is
    -- the set of non-admin roles that still write, which is what this gate is
    -- for.
    v_gate_write_roles text[] := ARRAY['agent:t', 'team_member'];
    v_base_exp     jsonb := '{}'::jsonb;
    v_base_self    jsonb := '{}'::jsonb;
    v_baseline     jsonb;
    v_blind        boolean;
    v_bob          uuid;
    v_cand         uuid;
    v_claim        jsonb;
    v_core         uuid;
    v_dana         uuid;
    v_domain       uuid;
    v_edge         uuid;
    v_failed       boolean;
    v_gate         jsonb;
    v_id           uuid;
    v_incumbent    uuid;
    v_john         uuid;
    v_key          text;
    v_msg          text;
    v_policy       text;
    v_role         text;
    v_policy_row   uuid;
    v_row          assertions;
    v_rows         integer;
    v_selfbase     jsonb;
    v_subject      uuid;
    v_scope_cand   uuid;
    v_scope_open   uuid;
    v_scope_strict uuid;
    v_scoped       uuid;
    v_self_cand    uuid;
    v_then         timestamptz := now() - interval '30 days';
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:configuration-gate', true);
    PERFORM set_config('app.current_teams', '', true);

    SELECT id INTO v_core
    FROM nodes
    WHERE external_source = 'rye_registry' AND external_id = 'core' AND archived_at IS NULL;

    -- ------------------------------------------------------------------
    -- Obligation 9, taken first: the install seeds are accepted, so the
    -- gate did not demote them on the way in.
    -- ------------------------------------------------------------------
    IF registry_value('basis_prior:observed', NULL) IS DISTINCT FROM '0.95'::jsonb THEN
        RAISE EXCEPTION
            'Install seed basis_prior:observed is %, not 0.95; the gate demoted the seeds',
            registry_value('basis_prior:observed', NULL);
    END IF;

    -- ------------------------------------------------------------------
    -- The gate is readable, and it says the same thing to everyone it
    -- binds. settle_gate() is how a client asks before it offers.
    -- ------------------------------------------------------------------
    v_gate := settle_gate('registry_entry');
    IF (v_gate->>'gated')::boolean IS DISTINCT FROM true
       OR NOT (v_gate->'allowed_roles' @> '["admin"]'::jsonb)
       OR (v_gate->>'may_settle')::boolean IS DISTINCT FROM true
       OR v_gate->>'current_role' <> 'admin'
    THEN
        RAISE EXCEPTION 'settle_gate(registry_entry) as admin returned %', v_gate;
    END IF;
    IF (settle_gate('review_policy')->>'gated')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'review_policy is not gated: %', settle_gate('review_policy');
    END IF;

    v_gate := settle_gate('conformance_gate_ungoverned_type');
    IF (v_gate->>'gated')::boolean IS DISTINCT FROM false
       OR (v_gate->>'may_settle')::boolean IS DISTINCT FROM true
       OR v_gate->'allowed_roles' <> 'null'::jsonb
    THEN
        RAISE EXCEPTION 'An ungated type answered %', v_gate;
    END IF;

    FOREACH v_role IN ARRAY ARRAY['agent:t', 'viewer', 'team_member', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_gate := settle_gate('registry_entry');
        IF (v_gate->>'gated')::boolean IS DISTINCT FROM true
           OR (v_gate->>'may_settle')::boolean IS DISTINCT FROM false
           OR NOT (v_gate->'allowed_roles' @> '["admin"]'::jsonb)
        THEN
            RAISE EXCEPTION 'settle_gate is invisible or permissive for role "%": %', v_role, v_gate;
        END IF;
    END LOOP;
    PERFORM set_config('app.current_role', 'admin', true);

    -- ------------------------------------------------------------------
    -- Fixtures: three scopes, one per review policy, and the people the
    -- settlement answer is about.
    -- ------------------------------------------------------------------
    INSERT INTO nodes (node_type, label) VALUES ('onboarding_scope', 'Config gate open scope')
    RETURNING id INTO v_scope_open;
    INSERT INTO nodes (node_type, label) VALUES ('onboarding_scope', 'Config gate candidates_only scope')
    RETURNING id INTO v_scope_cand;
    INSERT INTO nodes (node_type, label) VALUES ('onboarding_scope', 'Config gate strict scope')
    RETURNING id INTO v_scope_strict;

    PERFORM record_assertion('review_policy', '{"review_policy":"open"}', v_scope_open,
                             p_basis := 'assumed');
    PERFORM record_assertion('review_policy', '{"review_policy":"candidates_only"}', v_scope_cand,
                             p_basis := 'assumed');
    PERFORM record_assertion('review_policy', '{"review_policy":"strict"}', v_scope_strict,
                             p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_scope_open, p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_scope_cand, p_basis := 'assumed');
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_scope_strict, p_basis := 'assumed');

    -- An admin's own review_policy writes must still be accepted, or the
    -- policies below would not be set at all.
    IF scope_review_policy(v_scope_strict) <> 'strict'
       OR scope_review_policy(v_scope_cand) <> 'candidates_only'
       OR scope_review_policy(v_scope_open) <> 'open'
    THEN
        RAISE EXCEPTION 'An admin could not record the fixture review policies';
    END IF;

    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('person', 'Bob', 'conformance_gate', 'bob') RETURNING id INTO v_bob;
    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('person', 'John', 'conformance_gate', 'john') RETURNING id INTO v_john;
    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('person', 'Dana', 'conformance_gate', 'dana') RETURNING id INTO v_dana;

    INSERT INTO edges (edge_type, source_id, target_id, effective_from)
    VALUES ('reports_to', v_john, v_bob, v_then) RETURNING id INTO v_edge;

    v_domain := ensure_knowledge_domain(
        p_domain_key    := 'conformance-config-gate',
        p_label         := 'Conformance Configuration Gate',
        p_purpose       := 'Validate the configuration settle gate.',
        p_owner_node_id := v_dana
    );

    -- One agent that is bound and holds the fixture area, so at least one
    -- agent in the comparison below has a real settlement answer to lose.
    -- Keys are stored slugified; ask under the slug form.
    v_area_agent := create_agent_identity(
        'config_gate_area', 'Configuration gate area agent', 'test');
    PERFORM grant_agent_capability(
        'config_gate_area', 'rye.knowledge.read',
        p_domain_key := 'conformance-config-gate'
    );
    IF v_area_agent IS NULL THEN
        RAISE EXCEPTION 'The fixture area agent was not created';
    END IF;

    -- ------------------------------------------------------------------
    -- Obligation 10, first half: the answer before anyone attacks it.
    -- An expectation is set on John by his manager, so John never settles
    -- it, whatever the speech act says.
    -- ------------------------------------------------------------------
    v_baseline := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'expectation',
        p_speaker_id := v_john,
        p_domain_key := 'conformance-config-gate',
        p_speech_act := 'self_commitment'
    );
    IF v_baseline->>'step' <> 'relationship'
       OR (v_baseline->>'settler_count')::int <> 1
       OR v_baseline->'settlers'->0->>'node_id' <> v_bob::text
       OR v_baseline->'settlers'->0->>'relationship' <> 'manager'
       OR (v_baseline->'speaker'->>'is_settler')::boolean IS DISTINCT FROM false
    THEN
        RAISE EXCEPTION 'Expected Bob to settle an expectation on John before the attack, got %', v_baseline;
    END IF;

    -- The same question asked by every role that will ask it again after
    -- the attacks. Each role's own answer now is what it is owed later.
    FOREACH v_role IN ARRAY v_ask_roles LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_answer := rye_settlers(
            p_subject_id := v_john,
            p_claim_type := 'expectation',
            p_speaker_id := v_john,
            p_domain_key := 'conformance-config-gate',
            p_speech_act := 'self_commitment'
        );
        v_base_exp := v_base_exp || jsonb_build_object(v_role, v_answer);

        -- Pin the visibility rule rather than assume it: a role that cannot
        -- read the area is told domain_not_found, and a role that can is
        -- told who settles.
        v_blind := v_role IN ('agent:t', '');
        IF v_blind AND (v_answer->>'reason' IS DISTINCT FROM 'domain_not_found'
                        OR v_answer->>'step' IS DISTINCT FROM 'none') THEN
            RAISE EXCEPTION
                'Role "%" cannot see the fixture area, so it is owed domain_not_found before the attacks, got %',
                v_role, v_answer;
        END IF;
        IF NOT v_blind AND v_answer->>'step' IS DISTINCT FROM 'relationship' THEN
            RAISE EXCEPTION
                'Role "%" should see the fixture area before the attacks, got %', v_role, v_answer;
        END IF;
    END LOOP;
    PERFORM set_config('app.current_role', 'admin', true);

    -- ==================================================================
    -- Obligation 1. A non-admin's accepted configuration write lands as a
    -- candidate, marked, under every role and every review policy --
    -- including no policy recorded at all, which is a fresh install.
    -- ==================================================================
    FOREACH v_policy IN ARRAY ARRAY['none', 'open', 'candidates_only', 'strict'] LOOP
        PERFORM set_config('app.current_role', 'admin', true);

        UPDATE edges SET archived_at = now()
        WHERE edge_type = 'scope_governs_subject'
          AND target_id = v_core
          AND archived_at IS NULL;

        IF v_policy = 'none' THEN
            IF governing_scope(v_core, NULL, 'registry_entry', NULL) IS NOT NULL THEN
                RAISE EXCEPTION
                    'Premise broken: a scope already governs the core registry node, so the no-policy case is not the no-policy case';
            END IF;
        ELSE
            v_scoped := CASE v_policy
                WHEN 'open' THEN v_scope_open
                WHEN 'candidates_only' THEN v_scope_cand
                ELSE v_scope_strict
            END;
            INSERT INTO edges (edge_type, source_id, target_id)
            VALUES ('scope_governs_subject', v_scoped, v_core);
            IF governing_scope(v_core, NULL, 'registry_entry', NULL) IS DISTINCT FROM v_scoped THEN
                RAISE EXCEPTION 'Premise broken: the core registry node is not governed by the % scope', v_policy;
            END IF;
            IF scope_review_policy(v_scoped) <> v_policy THEN
                RAISE EXCEPTION 'Premise broken: fixture scope policy is %, wanted %',
                    scope_review_policy(v_scoped), v_policy;
            END IF;
        END IF;

        FOREACH v_role IN ARRAY v_gate_write_roles LOOP
            PERFORM set_config('app.current_role', v_role, true);

            FOREACH v_key IN ARRAY ARRAY[
                'type_alias:assertion_type:expectation',
                'self_settled_type:expectation',
                'conformance_gate:arbitrary'
            ] LOOP
                v_claim := CASE v_key
                    WHEN 'type_alias:assertion_type:expectation' THEN '{"value":"commitment"}'::jsonb
                    WHEN 'self_settled_type:expectation' THEN '{"value":true}'::jsonb
                    ELSE '{"value":"probe"}'::jsonb
                END;

                v_id := record_assertion(
                    'registry_entry', v_claim, v_core,
                    p_assertion_key := v_key,
                    p_status := 'accepted',
                    p_basis := 'assumed'
                );

                SELECT * INTO v_row FROM assertions WHERE id = v_id;
                IF v_row.status <> 'candidate' THEN
                    RAISE EXCEPTION
                        'Role "%" landed an accepted registry_entry % under review policy %',
                        v_role, v_key, v_policy;
                END IF;
                IF (v_row.attrs->'settle_gate'->>'pending')::boolean IS DISTINCT FROM true
                   OR v_row.attrs->'settle_gate'->>'requested_status' <> 'accepted'
                   OR NOT (v_row.attrs->'settle_gate'->'allowed_roles' @> '["admin"]'::jsonb)
                THEN
                    RAISE EXCEPTION
                        'Role "%" was not told why % is waiting under review policy %: attrs %',
                        v_role, v_key, v_policy, v_row.attrs;
                END IF;

                -- Nothing said is lost: it is in the queue an admin reads,
                -- carrying the marker, visible to the caller who wrote it.
                IF NOT EXISTS (
                    SELECT 1
                    FROM review_queue rq,
                         jsonb_array_elements(rq.candidates) AS candidate(value)
                    WHERE candidate.value->>'assertion_id' = v_id::text
                      AND (candidate.value->'attrs'->'settle_gate'->>'pending')::boolean
                ) THEN
                    RAISE EXCEPTION
                        'Role "%" wrote % under review policy % and it is not in review_queue',
                        v_role, v_key, v_policy;
                END IF;

                IF registry_value(v_key, NULL) IS NOT NULL THEN
                    RAISE EXCEPTION
                        'Role "%" changed the registry value of % under review policy %',
                        v_role, v_key, v_policy;
                END IF;
            END LOOP;

            -- The same for review_policy, the key to every other lock: an
            -- attempt to relax a strict scope lands as a suggestion.
            v_id := record_assertion(
                'review_policy', '{"review_policy":"open"}', v_scope_strict,
                p_status := 'accepted', p_basis := 'assumed'
            );
            SELECT * INTO v_row FROM assertions WHERE id = v_id;
            IF v_row.status <> 'candidate'
               OR (v_row.attrs->'settle_gate'->>'pending')::boolean IS DISTINCT FROM true
            THEN
                RAISE EXCEPTION
                    'Role "%" set a review_policy under review policy %: status %, attrs %',
                    v_role, v_policy, v_row.status, v_row.attrs;
            END IF;
            IF scope_review_policy(v_scope_strict) <> 'strict' THEN
                RAISE EXCEPTION 'Role "%" relaxed a strict scope to %',
                    v_role, scope_review_policy(v_scope_strict);
            END IF;

            -- ==========================================================
            -- Obligation 2. A direct INSERT of an accepted gated row
            -- raises, under the same roles.
            -- ==========================================================
            v_failed := false;
            BEGIN
                INSERT INTO assertions (
                    assertion_type, assertion_key, status, basis,
                    subject_node_id, claim
                ) VALUES (
                    'registry_entry', 'type_alias:assertion_type:expectation',
                    'accepted', 'assumed', v_core, '{"value":"commitment"}'
                );
            EXCEPTION WHEN OTHERS THEN
                v_failed := true;
                v_msg := SQLERRM;
            END;
            IF NOT v_failed THEN
                RAISE EXCEPTION
                    'Role "%" inserted an accepted registry_entry directly under review policy %',
                    v_role, v_policy;
            END IF;
            IF v_msg NOT LIKE '%is Rye configuration%' THEN
                RAISE EXCEPTION
                    'Role "%" direct INSERT failed for the wrong reason: %', v_role, v_msg;
            END IF;
        END LOOP;
    END LOOP;

    -- Leave the core registry node ungoverned again.
    PERFORM set_config('app.current_role', 'admin', true);
    UPDATE edges SET archived_at = now()
    WHERE edge_type = 'scope_governs_subject'
      AND target_id = v_core
      AND archived_at IS NULL;

    -- ==================================================================
    -- Obligation 3. No lifecycle helper and no raw UPDATE promotes a
    -- registry candidate for a non-admin.
    -- ==================================================================
    FOREACH v_role IN ARRAY v_gate_write_roles LOOP
        PERFORM set_config('app.current_role', 'admin', true);
        v_cand := record_assertion(
            'registry_entry', '{"value":"commitment"}', v_core,
            p_assertion_key := 'conformance_gate:promote_probe',
            p_status := 'candidate', p_basis := 'assumed'
        );

        PERFORM set_config('app.current_role', v_role, true);

        v_failed := false;
        BEGIN
            PERFORM accept_assertion(v_cand);
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" accepted a registry candidate', v_role;
        END IF;
        IF v_msg NOT LIKE '%is Rye configuration%' THEN
            RAISE EXCEPTION 'Role "%" accept_assertion failed for the wrong reason: %', v_role, v_msg;
        END IF;
        IF (SELECT status FROM assertions WHERE id = v_cand) <> 'candidate' THEN
            RAISE EXCEPTION 'Role "%" left the registry candidate accepted after a failed accept', v_role;
        END IF;

        -- The raw UPDATE, by a caller who sets the helper's own session
        -- variables itself. The update policy trusts them; the gate does not.
        v_failed := false;
        BEGIN
            PERFORM set_config('app.write_path', 'accept_assertion', true);
            PERFORM set_config('app.accept_assertion_id', v_cand::text, true);
            UPDATE assertions SET status = 'accepted' WHERE id = v_cand;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        PERFORM set_config('app.write_path', '', true);
        PERFORM set_config('app.accept_assertion_id', '', true);
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" promoted a registry candidate with a raw UPDATE', v_role;
        END IF;
        IF v_msg NOT LIKE '%is Rye configuration%' THEN
            RAISE EXCEPTION 'Role "%" raw UPDATE failed for the wrong reason: %', v_role, v_msg;
        END IF;
        IF (SELECT status FROM assertions WHERE id = v_cand) <> 'candidate' THEN
            RAISE EXCEPTION 'Role "%" left the registry candidate accepted after a failed raw UPDATE', v_role;
        END IF;
    END LOOP;

    -- ==================================================================
    -- Obligation 4. A capability grant is not an admin. An agent holding
    -- rye.authoritative.promote for the governing scope still cannot
    -- accept a registry candidate.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'admin', true);
    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('scope_governs_subject', v_scope_strict, v_core);

    v_agent_id := create_agent_identity('config_gate_agent', 'Configuration gate agent', 'test');
    PERFORM grant_agent_capability(
        'config_gate_agent', 'rye.authoritative.promote',
        p_scope_ref := v_scope_strict::text
    );
    v_cand := record_assertion(
        'registry_entry', '{"value":"commitment"}', v_core,
        p_assertion_key := 'conformance_gate:capability_probe',
        p_status := 'candidate', p_basis := 'assumed'
    );

    PERFORM set_config('app.current_role', 'agent:config_gate_agent', true);
    PERFORM set_config('app.current_user_id', 'config_gate_agent', true);
    IF NOT agent_can_promote_in_scope(v_scope_strict) THEN
        RAISE EXCEPTION
            'Premise broken: the fixture agent does not hold rye.authoritative.promote, so obligation 4 proves nothing';
    END IF;

    v_failed := false;
    BEGIN
        PERFORM accept_assertion(v_cand);
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        v_msg := SQLERRM;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'An agent holding rye.authoritative.promote accepted a registry candidate';
    END IF;
    IF v_msg NOT LIKE '%is Rye configuration%' THEN
        RAISE EXCEPTION 'The capability-holding agent was refused for the wrong reason: %', v_msg;
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:configuration-gate', true);
    UPDATE edges SET archived_at = now()
    WHERE edge_type = 'scope_governs_subject'
      AND target_id = v_core
      AND archived_at IS NULL;

    -- ==================================================================
    -- Obligation 5. supersede_assertion() refuses rather than demotes, and
    -- the incumbent is untouched afterwards: a non-admin cannot erase an
    -- accepted entry by proposing a replacement.
    -- ==================================================================
    v_incumbent := record_assertion(
        'registry_entry', '{"value":"kept"}', v_core,
        p_assertion_key := 'conformance_gate:incumbent',
        p_status := 'accepted', p_basis := 'assumed'
    );
    IF (SELECT status FROM assertions WHERE id = v_incumbent) <> 'accepted' THEN
        RAISE EXCEPTION 'An admin could not record an accepted registry entry';
    END IF;

    FOREACH v_role IN ARRAY v_gate_write_roles LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_failed := false;
        BEGIN
            PERFORM supersede_assertion(
                v_incumbent, 'registry_entry', v_core, NULL,
                '{"value":"hijacked"}',
                p_new_assertion_key := 'conformance_gate:incumbent',
                p_new_basis := 'assumed'
            );
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" superseded an accepted registry entry', v_role;
        END IF;
        IF v_msg NOT LIKE '%is Rye configuration%' THEN
            RAISE EXCEPTION 'Role "%" supersede_assertion failed for the wrong reason: %', v_role, v_msg;
        END IF;

        SELECT * INTO v_row FROM assertions WHERE id = v_incumbent;
        IF v_row.status <> 'accepted' OR v_row.superseded_at IS NOT NULL THEN
            RAISE EXCEPTION
                'Role "%" left the incumbent registry entry as status %, superseded_at %',
                v_role, v_row.status, v_row.superseded_at;
        END IF;
    END LOOP;

    PERFORM set_config('app.current_role', 'admin', true);
    IF registry_value('conformance_gate:incumbent', NULL) IS DISTINCT FROM '"kept"'::jsonb THEN
        RAISE EXCEPTION 'The incumbent registry value changed to %',
            registry_value('conformance_gate:incumbent', NULL);
    END IF;

    -- ==================================================================
    -- Obligation 5b. Ending an accepted configuration record changes the
    -- configuration, so the same roles gate it. A caller who may not settle
    -- a gated type may not change an accepted row of it at all -- not
    -- superseded_at, not effective_to, not claim, not attrs -- even with the
    -- helpers' own session variables spoofed. For review_policy this is not
    -- merely a loss: ending an accepted `strict` policy drops the scope back
    -- to `open`, and the next ordinary write lands accepted.
    -- ==================================================================
    FOREACH v_role IN ARRAY v_gate_write_roles LOOP
        PERFORM set_config('app.current_role', v_role, true);

        -- End it, by spoofing the supersession write path.
        v_failed := false;
        BEGIN
            PERFORM set_config('app.write_path', 'supersede_assertion', true);
            PERFORM set_config('app.supersede_assertion_id', v_incumbent::text, true);
            UPDATE assertions SET superseded_at = now() WHERE id = v_incumbent;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        PERFORM set_config('app.write_path', '', true);
        PERFORM set_config('app.supersede_assertion_id', '', true);
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" ended an accepted registry entry with a spoofed supersession', v_role;
        END IF;
        IF v_msg NOT LIKE '%is Rye configuration%' THEN
            RAISE EXCEPTION 'Role "%" spoofed supersession failed for the wrong reason: %', v_role, v_msg;
        END IF;

        -- Narrow its effective window.
        v_failed := false;
        BEGIN
            PERFORM set_config('app.write_path', 'assertion_effective_window', true);
            PERFORM set_config('app.effective_window_assertion_id', v_incumbent::text, true);
            UPDATE assertions SET effective_to = now() + interval '1 hour' WHERE id = v_incumbent;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        PERFORM set_config('app.write_path', '', true);
        PERFORM set_config('app.effective_window_assertion_id', '', true);
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" narrowed the window of an accepted registry entry', v_role;
        END IF;
        IF v_msg NOT LIKE '%is Rye configuration%' THEN
            RAISE EXCEPTION 'Role "%" window narrowing failed for the wrong reason: %', v_role, v_msg;
        END IF;

        -- Rewrite its claim.
        v_failed := false;
        BEGIN
            PERFORM set_config('app.write_path', 'supersede_assertion', true);
            PERFORM set_config('app.supersede_assertion_id', v_incumbent::text, true);
            UPDATE assertions SET claim = '{"value":"rewritten"}' WHERE id = v_incumbent;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        PERFORM set_config('app.write_path', '', true);
        PERFORM set_config('app.supersede_assertion_id', '', true);
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" rewrote the claim of an accepted registry entry', v_role;
        END IF;
        IF v_msg NOT LIKE '%is Rye configuration%' THEN
            RAISE EXCEPTION 'Role "%" claim rewrite failed for the wrong reason: %', v_role, v_msg;
        END IF;

        -- Rewrite its attrs, on the one write path that the immutability
        -- guard lets attrs through.
        v_failed := false;
        BEGIN
            PERFORM set_config('app.write_path', 'assertion_outcome', true);
            PERFORM set_config('app.outcome_assertion_id', v_incumbent::text, true);
            UPDATE assertions SET attrs = attrs || '{"hijacked":true}'::jsonb WHERE id = v_incumbent;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        PERFORM set_config('app.write_path', '', true);
        PERFORM set_config('app.outcome_assertion_id', '', true);
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" rewrote the attrs of an accepted registry entry', v_role;
        END IF;
        IF v_msg NOT LIKE '%is Rye configuration%' THEN
            RAISE EXCEPTION 'Role "%" attrs rewrite failed for the wrong reason: %', v_role, v_msg;
        END IF;

        -- Delete it. assertion_delete_policy is USING (false), so RLS
        -- refuses silently: no exception, no rows.
        DELETE FROM assertions WHERE id = v_incumbent;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'Role "%" deleted % accepted registry entries', v_role, v_rows;
        END IF;

        SELECT * INTO v_row FROM assertions WHERE id = v_incumbent;
        IF v_row.id IS NULL
           OR v_row.status <> 'accepted'
           OR v_row.superseded_at IS NOT NULL
           OR v_row.effective_to IS NOT NULL
           OR v_row.claim IS DISTINCT FROM '{"value":"kept"}'::jsonb
           OR v_row.attrs ? 'hijacked'
        THEN
            RAISE EXCEPTION 'Role "%" changed the accepted registry entry: %', v_role, to_jsonb(v_row);
        END IF;
    END LOOP;

    -- Nothing may delete an assertion, not even an admin: the delete policy
    -- is USING (false) and history is never removed.
    PERFORM set_config('app.current_role', 'admin', true);
    DELETE FROM assertions WHERE id = v_incumbent;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'An admin deleted % assertion rows; assertions are never deleted', v_rows;
    END IF;
    IF registry_value('conformance_gate:incumbent', NULL) IS DISTINCT FROM '"kept"'::jsonb THEN
        RAISE EXCEPTION 'The incumbent registry value changed to %',
            registry_value('conformance_gate:incumbent', NULL);
    END IF;

    -- The escalation this closes: ending a scope's accepted strict policy.
    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Config gate governed subject')
    RETURNING id INTO v_subject;
    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('scope_governs_subject', v_scope_strict, v_subject);
    IF governing_scope(v_subject, NULL, 'conformance_gate_ordinary', NULL) IS DISTINCT FROM v_scope_strict THEN
        RAISE EXCEPTION 'Premise broken: the fixture subject is not governed by the strict scope';
    END IF;

    SELECT id INTO v_policy_row
    FROM assertions
    WHERE subject_node_id = v_scope_strict
      AND assertion_type = 'review_policy'
      AND status = 'accepted'
      AND superseded_at IS NULL
    ORDER BY asserted_at DESC, id
    LIMIT 1;
    IF v_policy_row IS NULL THEN
        RAISE EXCEPTION 'Premise broken: the strict scope has no accepted review_policy to end';
    END IF;

    FOREACH v_role IN ARRAY v_gate_write_roles LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_failed := false;
        BEGIN
            PERFORM set_config('app.write_path', 'supersede_assertion', true);
            PERFORM set_config('app.supersede_assertion_id', v_policy_row::text, true);
            UPDATE assertions SET superseded_at = now() WHERE id = v_policy_row;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        PERFORM set_config('app.write_path', '', true);
        PERFORM set_config('app.supersede_assertion_id', '', true);
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" ended a scope''s accepted review_policy', v_role;
        END IF;
        IF v_msg NOT LIKE '%is Rye configuration%' THEN
            RAISE EXCEPTION 'Role "%" review_policy erase failed for the wrong reason: %', v_role, v_msg;
        END IF;

        IF scope_review_policy(v_scope_strict) <> 'strict' THEN
            RAISE EXCEPTION 'Role "%" dropped the scope review policy to %',
                v_role, scope_review_policy(v_scope_strict);
        END IF;

        -- And the consequence that made it an escalation: an ordinary write
        -- governed by that scope still has to wait for review.
        v_id := record_assertion(
            'conformance_gate_ordinary', '{"value":1}', v_subject,
            p_assertion_key := 'after_erase_attempt_' || coalesce(nullif(v_role, ''), 'unset'),
            p_status := 'accepted', p_basis := 'assumed'
        );
        IF (SELECT status FROM assertions WHERE id = v_id) <> 'candidate' THEN
            RAISE EXCEPTION
                'Role "%" landed an ordinary accepted write under a scope it tried to unlock', v_role;
        END IF;
    END LOOP;

    -- A declared self-settled type is configuration too: ending it would move
    -- who may settle that claim, restrictively but still without an admin.
    PERFORM set_config('app.current_role', 'admin', true);
    v_id := record_assertion(
        'registry_entry', '{"value":true}', v_core,
        p_assertion_key := 'self_settled_type:availability',
        p_status := 'accepted', p_basis := 'assumed'
    );
    IF (SELECT status FROM assertions WHERE id = v_id) <> 'accepted' THEN
        RAISE EXCEPTION 'An admin could not declare a self-settled type';
    END IF;

    v_selfbase := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'availability',
        p_speaker_id := v_john,
        p_domain_key := 'conformance-config-gate',
        p_speech_act := 'self_commitment'
    );
    IF v_selfbase->'settlers'->0->>'node_id' IS DISTINCT FROM v_john::text
       OR v_selfbase->'settlers'->0->>'relationship' <> 'self'
       OR (v_selfbase->'speaker'->>'is_settler')::boolean IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION 'Premise broken: a declared self type does not settle to the subject: %', v_selfbase;
    END IF;

    -- Each role's own answer before the erase attempts.
    FOREACH v_role IN ARRAY v_ask_roles LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_answer := rye_settlers(
            p_subject_id := v_john,
            p_claim_type := 'availability',
            p_speaker_id := v_john,
            p_domain_key := 'conformance-config-gate',
            p_speech_act := 'self_commitment'
        );
        v_base_self := v_base_self || jsonb_build_object(v_role, v_answer);
        v_blind := v_role IN ('agent:t', '');
        IF v_blind AND (v_answer->>'reason' IS DISTINCT FROM 'domain_not_found'
                        OR v_answer->>'step' IS DISTINCT FROM 'none') THEN
            RAISE EXCEPTION
                'Role "%" cannot see the fixture area, so it is owed domain_not_found for a self type, got %',
                v_role, v_answer;
        END IF;
        -- A sighted role's baseline is checked, not merely stored: an
        -- already-wrong baseline would make the comparison after the
        -- attacks agree with itself and prove nothing.
        IF NOT v_blind AND (
               v_answer->>'step' IS DISTINCT FROM 'relationship'
               OR v_answer->'settlers'->0->>'node_id' IS DISTINCT FROM v_john::text
               OR v_answer->'settlers'->0->>'relationship' IS DISTINCT FROM 'self'
               OR v_answer->'speaker'->>'is_settler' IS DISTINCT FROM 'true'
           ) THEN
            RAISE EXCEPTION
                'Role "%" should be told John settles his own availability before the erase attempts, got %',
                v_role, v_answer;
        END IF;
    END LOOP;
    PERFORM set_config('app.current_role', 'admin', true);

    FOREACH v_role IN ARRAY v_gate_write_roles LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_failed := false;
        BEGIN
            PERFORM set_config('app.write_path', 'supersede_assertion', true);
            PERFORM set_config('app.supersede_assertion_id', v_id::text, true);
            UPDATE assertions SET superseded_at = now() WHERE id = v_id;
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        PERFORM set_config('app.write_path', '', true);
        PERFORM set_config('app.supersede_assertion_id', '', true);
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" ended a declared self-settled type', v_role;
        END IF;
        IF v_msg NOT LIKE '%is Rye configuration%' THEN
            RAISE EXCEPTION 'Role "%" self type erase failed for the wrong reason: %', v_role, v_msg;
        END IF;
    END LOOP;

    FOREACH v_role IN ARRAY v_ask_roles LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_answer := rye_settlers(
            p_subject_id := v_john,
            p_claim_type := 'availability',
            p_speaker_id := v_john,
            p_domain_key := 'conformance-config-gate',
            p_speech_act := 'self_commitment'
        );
        IF v_answer->>'step' IS DISTINCT FROM v_base_self->v_role->>'step'
           OR v_answer->>'reason' IS DISTINCT FROM v_base_self->v_role->>'reason'
           OR v_answer->>'settler_count' IS DISTINCT FROM v_base_self->v_role->>'settler_count'
           OR v_answer->'settlers'->0->>'node_id' IS DISTINCT FROM v_base_self->v_role->'settlers'->0->>'node_id'
           OR v_answer->'settlers'->0->>'relationship' IS DISTINCT FROM v_base_self->v_role->'settlers'->0->>'relationship'
           OR v_answer->'speaker'->>'is_settler' IS DISTINCT FROM v_base_self->v_role->'speaker'->>'is_settler'
        THEN
            RAISE EXCEPTION
                'Role "%" sees a different answer for a declared self type after the erase attempts: % vs %',
                v_role, v_answer, v_base_self->v_role;
        END IF;
    END LOOP;

    -- The strongest statement of what obligation 10 is for: a session that
    -- can see everything is told exactly what it was told before.
    PERFORM set_config('app.current_role', 'admin', true);
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'availability',
        p_speaker_id := v_john,
        p_domain_key := 'conformance-config-gate',
        p_speech_act := 'self_commitment'
    );
    IF v_answer->'settlers'->0->>'node_id' IS DISTINCT FROM v_selfbase->'settlers'->0->>'node_id'
       OR v_answer->'settlers'->0->>'relationship' IS DISTINCT FROM v_selfbase->'settlers'->0->>'relationship'
       OR v_answer->'speaker'->>'is_settler' IS DISTINCT FROM v_selfbase->'speaker'->>'is_settler'
    THEN
        RAISE EXCEPTION
            'An admin sees a different answer for a declared self type after the erase attempts: % vs %',
            v_answer, v_selfbase;
    END IF;

    -- An admin keeps every lifecycle operation on the same rows: supersede
    -- the incumbent, and narrow an accepted window through the helper.
    PERFORM set_config('app.current_role', 'admin', true);
    v_id := supersede_assertion(
        v_incumbent, 'registry_entry', v_core, NULL,
        '{"value":"replaced"}',
        p_new_assertion_key := 'conformance_gate:incumbent',
        p_new_basis := 'assumed'
    );
    IF (SELECT superseded_at FROM assertions WHERE id = v_incumbent) IS NULL THEN
        RAISE EXCEPTION 'An admin could not supersede an accepted registry entry';
    END IF;
    IF registry_value('conformance_gate:incumbent', NULL) IS DISTINCT FROM '"replaced"'::jsonb THEN
        RAISE EXCEPTION 'An admin''s supersession did not take: %',
            registry_value('conformance_gate:incumbent', NULL);
    END IF;

    PERFORM record_assertion(
        'registry_entry', '{"value":"scheduled_replacement"}', v_core,
        p_assertion_key := 'conformance_gate:incumbent',
        p_effective_at := now() + interval '1 day',
        p_status := 'accepted', p_basis := 'assumed'
    );
    IF (SELECT effective_to FROM assertions WHERE id = v_id) IS NULL THEN
        RAISE EXCEPTION 'An admin could not narrow the window of an accepted registry entry';
    END IF;

    -- ==================================================================
    -- Obligation 6. schedule_assertion_change() routes through
    -- record_assertion(), so it demotes, and the scheduled row never
    -- becomes effective.
    -- ==================================================================
    FOREACH v_role IN ARRAY v_gate_write_roles LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_id := schedule_assertion_change(
            p_subject_node_id := v_core,
            p_subject_edge_id := NULL,
            p_assertion_type  := 'registry_entry',
            p_assertion_key   := 'conformance_gate:scheduled',
            p_claim           := '{"value":"later"}',
            p_effective_at    := now() + interval '1 day',
            p_basis           := 'assumed'
        );
        SELECT * INTO v_row FROM assertions WHERE id = v_id;
        IF v_row.status <> 'candidate'
           OR (v_row.attrs->'settle_gate'->>'pending')::boolean IS DISTINCT FROM true
        THEN
            RAISE EXCEPTION
                'Role "%" scheduled an accepted registry entry: status %, attrs %',
                v_role, v_row.status, v_row.attrs;
        END IF;
        IF EXISTS (
            SELECT 1 FROM assertions
            WHERE id = v_id AND status = 'accepted'
        ) THEN
            RAISE EXCEPTION 'Role "%" scheduled row became accepted', v_role;
        END IF;
        IF registry_value('conformance_gate:scheduled', NULL) IS NOT NULL THEN
            RAISE EXCEPTION 'Role "%" scheduled entry is already the registry value', v_role;
        END IF;
    END LOOP;

    -- ==================================================================
    -- Obligation 7. record_scope_policy() routes through
    -- record_assertion() too, and a strict scope stays strict.
    -- ==================================================================
    FOREACH v_role IN ARRAY v_gate_write_roles LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_id := record_scope_policy(
            p_scope_id     := v_scope_strict,
            p_policy_type  := 'review_policy',
            p_claim        := '{"review_policy":"open"}'
        );
        SELECT * INTO v_row FROM assertions WHERE id = v_id;
        IF v_row.status <> 'candidate'
           OR (v_row.attrs->'settle_gate'->>'pending')::boolean IS DISTINCT FROM true
        THEN
            RAISE EXCEPTION
                'Role "%" recorded a scope review_policy: status %, attrs %',
                v_role, v_row.status, v_row.attrs;
        END IF;
        IF scope_review_policy(v_scope_strict) <> 'strict' THEN
            RAISE EXCEPTION 'Role "%" relaxed the strict scope to % through record_scope_policy',
                v_role, scope_review_policy(v_scope_strict);
        END IF;
    END LOOP;

    -- ==================================================================
    -- Obligation 8. An admin still works, both ways: recording an accepted
    -- entry, and accepting a non-admin's suggestion so nothing is lost.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'admin', true);
    v_id := record_assertion(
        'registry_entry', '{"value":"admin_ok"}', v_core,
        p_assertion_key := 'conformance_gate:admin_ok',
        p_status := 'accepted', p_basis := 'assumed'
    );
    IF (SELECT status FROM assertions WHERE id = v_id) <> 'accepted' THEN
        RAISE EXCEPTION 'An admin could not record an accepted registry entry';
    END IF;
    IF registry_value('conformance_gate:admin_ok', NULL) IS DISTINCT FROM '"admin_ok"'::jsonb THEN
        RAISE EXCEPTION 'An admin''s registry entry is not readable: %',
            registry_value('conformance_gate:admin_ok', NULL);
    END IF;

    SELECT id INTO v_cand
    FROM assertions
    WHERE assertion_type = 'registry_entry'
      AND assertion_key = 'conformance_gate:arbitrary'
      AND status = 'candidate'
      AND superseded_at IS NULL
    ORDER BY asserted_at, id
    LIMIT 1;
    IF v_cand IS NULL THEN
        RAISE EXCEPTION 'No non-admin suggestion survived to be accepted; nothing said was kept';
    END IF;
    PERFORM accept_assertion(v_cand);
    IF (SELECT status FROM assertions WHERE id = v_cand) <> 'accepted' THEN
        RAISE EXCEPTION 'An admin could not accept a non-admin registry suggestion';
    END IF;
    IF registry_value('conformance_gate:arbitrary', NULL) IS DISTINCT FROM '"probe"'::jsonb THEN
        RAISE EXCEPTION 'The accepted suggestion is not the registry value: %',
            registry_value('conformance_gate:arbitrary', NULL);
    END IF;

    -- Obligation 9 again, after everything above.
    IF registry_value('basis_prior:observed', NULL) IS DISTINCT FROM '0.95'::jsonb THEN
        RAISE EXCEPTION 'Install seed basis_prior:observed changed to %',
            registry_value('basis_prior:observed', NULL);
    END IF;

    -- ==================================================================
    -- Obligation 10, second half. After every non-admin attempt above,
    -- the answer to who may settle an expectation on John is unchanged,
    -- for every role that can ask.
    -- ==================================================================
    FOREACH v_role IN ARRAY v_ask_roles LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_answer := rye_settlers(
            p_subject_id := v_john,
            p_claim_type := 'expectation',
            p_speaker_id := v_john,
            p_domain_key := 'conformance-config-gate',
            p_speech_act := 'self_commitment'
        );
        IF v_answer->>'step' IS DISTINCT FROM v_base_exp->v_role->>'step'
           OR v_answer->>'reason' IS DISTINCT FROM v_base_exp->v_role->>'reason'
           OR v_answer->>'settler_count' IS DISTINCT FROM v_base_exp->v_role->>'settler_count'
           OR v_answer->'settlers'->0->>'node_id' IS DISTINCT FROM v_base_exp->v_role->'settlers'->0->>'node_id'
           OR v_answer->'settlers'->0->>'relationship' IS DISTINCT FROM v_base_exp->v_role->'settlers'->0->>'relationship'
           OR v_answer->'speaker'->>'is_settler' IS DISTINCT FROM v_base_exp->v_role->'speaker'->>'is_settler'
        THEN
            RAISE EXCEPTION
                'Role "%" sees a different settlement answer after the non-admin writes: % vs %',
                v_role, v_answer, v_base_exp->v_role;
        END IF;
        IF EXISTS (
            SELECT 1 FROM jsonb_array_elements(v_answer->'settlers') AS s(value)
            WHERE s.value->>'node_id' = v_john::text
        ) THEN
            RAISE EXCEPTION 'Role "%" was told John settles an expectation set on him: %', v_role, v_answer;
        END IF;
    END LOOP;

    -- Same again in one place for the session that can see everything.
    PERFORM set_config('app.current_role', 'admin', true);
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'expectation',
        p_speaker_id := v_john,
        p_domain_key := 'conformance-config-gate',
        p_speech_act := 'self_commitment'
    );
    IF v_answer->>'step' IS DISTINCT FROM v_baseline->>'step'
       OR v_answer->>'settler_count' IS DISTINCT FROM v_baseline->>'settler_count'
       OR v_answer->'settlers'->0->>'node_id' IS DISTINCT FROM v_baseline->'settlers'->0->>'node_id'
       OR v_answer->'settlers'->0->>'relationship' IS DISTINCT FROM v_baseline->'settlers'->0->>'relationship'
       OR v_answer->'speaker'->>'is_settler' IS DISTINCT FROM v_baseline->'speaker'->>'is_settler'
    THEN
        RAISE EXCEPTION
            'An admin sees a different settlement answer after the non-admin writes: % vs %',
            v_answer, v_baseline;
    END IF;

    -- ==================================================================
    -- Obligation 11, anti-vacuity. The same two rows, accepted by an
    -- admin, DO change the answer. A suite that could not show the change
    -- would not have caught the gap it closes.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'admin', true);

    SELECT id INTO v_alias_cand
    FROM assertions
    WHERE assertion_type = 'registry_entry'
      AND assertion_key = 'type_alias:assertion_type:expectation'
      AND status = 'candidate'
      AND superseded_at IS NULL
      AND (attrs->'settle_gate'->>'pending')::boolean
    ORDER BY asserted_at, id
    LIMIT 1;
    SELECT id INTO v_self_cand
    FROM assertions
    WHERE assertion_type = 'registry_entry'
      AND assertion_key = 'self_settled_type:expectation'
      AND status = 'candidate'
      AND superseded_at IS NULL
      AND (attrs->'settle_gate'->>'pending')::boolean
    ORDER BY asserted_at, id
    LIMIT 1;
    IF v_alias_cand IS NULL OR v_self_cand IS NULL THEN
        RAISE EXCEPTION 'The gated suggestions are missing, so the anti-vacuity case cannot run';
    END IF;

    PERFORM accept_assertion(v_self_cand);
    PERFORM accept_assertion(v_alias_cand);

    IF registry_value('type_alias:assertion_type:expectation', NULL)
       IS DISTINCT FROM '"commitment"'::jsonb THEN
        RAISE EXCEPTION 'An admin''s acceptance did not install the alias: %',
            registry_value('type_alias:assertion_type:expectation', NULL);
    END IF;
    IF canonical_type('assertion_type', 'expectation') <> 'commitment' THEN
        RAISE EXCEPTION 'The accepted alias does not resolve: %',
            canonical_type('assertion_type', 'expectation');
    END IF;

    v_after := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'expectation',
        p_speaker_id := v_john,
        p_domain_key := 'conformance-config-gate',
        p_speech_act := 'self_commitment'
    );
    IF v_after->'settlers'->0->>'node_id' IS DISTINCT FROM v_john::text
       OR v_after->'settlers'->0->>'relationship' <> 'self'
       OR (v_after->'speaker'->>'is_settler')::boolean IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: an admin-accepted alias did not change the settlement answer, so the earlier cases prove nothing. Got %',
            v_after;
    END IF;
END
$$;

ROLLBACK;
