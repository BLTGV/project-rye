-- A gated configuration type cannot be aliased away.
--
-- Contract:  contracts/sql-surface.md, "Configuration writes need an admin",
--            paragraph "A gated type cannot be aliased away".
-- Decision:  docs/decisions/0007-configuration-writes-need-an-admin.md.
-- Work item: work/011-loose-ends.md, acceptance criterion 2.
-- Migration: schema/migrations/0028_gated_type_alias.sql.
--
-- The hole this closes, found by the work/005 verification: a registry entry
-- keyed `type_alias:assertion_type:registry_entry` makes canonical_type()
-- resolve the gated name to something else, so record_assertion() stores a
-- later configuration write under the alias target and the settle gate --
-- which compares the stored spelling -- never sees it.
--
-- The gated set is read from assertion_type_access rather than named here, so
-- this suite covers whatever is gated in the instance it runs against, today
-- registry_entry and review_policy and tomorrow whatever a later migration
-- adds.
--
-- Negative control: run scripts/migrate.sh up to 0027 only and this suite
-- fails at the first case, because the alias lands as an ordinary registry
-- entry. Invented names only.

SET search_path = rye, public, pg_catalog;

BEGIN;

-- --------------------------------------------------------------------------
-- Anti-vacuity, as in tests/conformance/30_configuration_gate.sql.
--
-- A superuser, or a role with BYPASSRLS, sees past every policy here, and with
-- row_security off so does everyone. Under scripts/conformance.sh the suite
-- runs as rye_conformance through SET ROLE; under
-- scripts/test-nonsuperuser-owner.sh there is no SET ROLE and it runs as the
-- non-superuser owner. Both must be bound by RLS.
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
    PERFORM set_config('app.current_user_id', 'test:gated-type-alias', true);
    PERFORM set_config('app.current_teams', '', true);

    SELECT id INTO v_core
    FROM nodes
    WHERE external_source = 'rye_registry' AND external_id = 'core' AND archived_at IS NULL;
    IF v_core IS NULL THEN
        RAISE EXCEPTION 'Core registry node is missing; the install seeds did not run';
    END IF;

    v_probe := record_assertion(
        'compensation', '{"value":"rls probe"}', v_core,
        p_assertion_key := 'alias_gate:rls_probe', p_basis := 'assumed'
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
-- The rule, in five cases.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_accepted   uuid;
    v_alias_key  text;
    v_cand       uuid;
    v_core       uuid;
    v_failed     boolean;
    v_gated      text[];
    v_id         uuid;
    v_msg        text;
    v_role       text;
    v_roles      text[] := ARRAY['admin', 'agent:t', 'viewer', 'team_member', ''];
    v_rows       integer;
    v_scope      uuid;
    v_status     text;
    v_stored     text;
    v_type       text;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:gated-type-alias', true);
    PERFORM set_config('app.current_teams', '', true);

    SELECT id INTO v_core
    FROM nodes
    WHERE external_source = 'rye_registry' AND external_id = 'core' AND archived_at IS NULL;

    -- The gated set is data. Read it; never name it.
    SELECT array_agg(assertion_type ORDER BY assertion_type) INTO v_gated
    FROM assertion_type_access
    WHERE operation = 'settle';

    IF coalesce(cardinality(v_gated), 0) = 0 THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: no assertion type is settle-gated, so there is nothing to alias away';
    END IF;
    IF NOT ('registry_entry' = ANY(v_gated)) OR NOT ('review_policy' = ANY(v_gated)) THEN
        RAISE EXCEPTION
            'Premise broken: the seeded settle rows are missing. Gated set is %', v_gated;
    END IF;

    -- ==================================================================
    -- Case 0, anti-vacuity for the rule itself. Aliasing is a real route:
    -- an alias on an ungated type changes the spelling a later write is
    -- stored under. That is the mechanism the cases below refuse for a
    -- gated type, and this proves it is not already broken.
    -- ==================================================================
    PERFORM record_assertion(
        'registry_entry', '{"value":"alias_gate_to"}', v_core,
        p_assertion_key := 'type_alias:assertion_type:alias_gate_from',
        p_status := 'accepted', p_basis := 'assumed'
    );
    IF canonical_type('assertion_type', 'alias_gate_from') <> 'alias_gate_to' THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: an ordinary alias does not resolve, so refusing one proves nothing. Got %',
            canonical_type('assertion_type', 'alias_gate_from');
    END IF;

    INSERT INTO nodes (node_type, label) VALUES ('thing', 'Alias gate subject')
    RETURNING id INTO v_id;
    v_id := record_assertion(
        'alias_gate_from', '{"value":"routed"}', v_id,
        p_assertion_key := 'default', p_basis := 'assumed'
    );
    SELECT assertion_type INTO v_stored FROM assertions WHERE id = v_id;
    IF v_stored <> 'alias_gate_to' THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: a write under an aliased name was stored as %, so an alias does not route a write at all',
            v_stored;
    END IF;

    -- ==================================================================
    -- Case 1. record_assertion() refuses an alias out of a gated type, at
    -- every status, for every role, admin included. Demotion is not an
    -- answer here: a candidate alias is one acceptance away from live.
    -- ==================================================================
    FOREACH v_type IN ARRAY v_gated LOOP
        v_alias_key := 'type_alias:assertion_type:' || v_type;

        FOREACH v_role IN ARRAY v_roles LOOP
            FOREACH v_status IN ARRAY ARRAY['accepted', 'candidate'] LOOP
                PERFORM set_config('app.current_role', v_role, true);
                v_failed := false;
                BEGIN
                    PERFORM record_assertion(
                        'registry_entry', '{"value":"decoy_type"}', v_core,
                        p_assertion_key := v_alias_key,
                        p_status := v_status, p_basis := 'assumed'
                    );
                EXCEPTION WHEN OTHERS THEN
                    v_failed := true;
                    v_msg := SQLERRM;
                END;
                IF NOT v_failed THEN
                    RAISE EXCEPTION
                        'Role "%" recorded a type alias (status %) out of the gated type %',
                        v_role, v_status, v_type;
                END IF;
                -- admin and team_member are writing roles under every
                -- migration in this tree, so their refusal must be this rule
                -- and not a role policy that happens to refuse first.
                IF v_role IN ('admin', 'team_member')
                   AND v_msg NOT LIKE '%Cannot record a type alias from%'
                THEN
                    RAISE EXCEPTION
                        'Role "%" was refused the % alias out of % for the wrong reason: %',
                        v_role, v_status, v_type, v_msg;
                END IF;
            END LOOP;

            -- The raw INSERT, which is the route record_assertion() cannot
            -- cover, at both statuses.
            FOREACH v_status IN ARRAY ARRAY['accepted', 'candidate'] LOOP
                v_failed := false;
                BEGIN
                    INSERT INTO assertions (
                        assertion_type, assertion_key, status, basis,
                        subject_node_id, claim
                    ) VALUES (
                        'registry_entry', v_alias_key, v_status, 'assumed',
                        v_core, '{"value":"decoy_type"}'
                    );
                EXCEPTION WHEN OTHERS THEN
                    v_failed := true;
                    v_msg := SQLERRM;
                END;
                IF NOT v_failed THEN
                    RAISE EXCEPTION
                        'Role "%" inserted a % type alias out of the gated type % directly',
                        v_role, v_status, v_type;
                END IF;
                IF v_role IN ('admin', 'team_member')
                   AND v_msg NOT LIKE '%Cannot record a type alias from%'
                THEN
                    RAISE EXCEPTION
                        'Role "%" raw INSERT of a % alias out of % failed for the wrong reason: %',
                        v_role, v_status, v_type, v_msg;
                END IF;
            END LOOP;
        END LOOP;

        PERFORM set_config('app.current_role', 'admin', true);
        SELECT count(*) INTO v_rows
        FROM assertions
        WHERE assertion_type = 'registry_entry' AND assertion_key = v_alias_key;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION
                'A type alias out of the gated type % exists after every attempt: % rows',
                v_type, v_rows;
        END IF;
        IF canonical_type('assertion_type', v_type) <> v_type THEN
            RAISE EXCEPTION
                'The gated type % now canonicalizes to %, so a write under the gated name misses the gate',
                v_type, canonical_type('assertion_type', v_type);
        END IF;
    END LOOP;

    -- ==================================================================
    -- Case 1b. The two routes the work/011 Verifier checked by hand:
    -- schedule_assertion_change(), which reaches record_assertion(), and a
    -- future-effective record_assertion(), which takes the scheduling branch
    -- and supersedes a same-instant incumbent before inserting. Both refused,
    -- for a writing role and for an admin.
    -- ==================================================================
    FOREACH v_role IN ARRAY ARRAY['admin', 'team_member', 'agent:t'] LOOP
        PERFORM set_config('app.current_role', v_role, true);

        v_failed := false;
        BEGIN
            PERFORM schedule_assertion_change(
                p_subject_node_id := v_core,
                p_subject_edge_id := NULL,
                p_assertion_type  := 'registry_entry',
                p_assertion_key   := 'type_alias:assertion_type:registry_entry',
                p_claim           := '{"value":"decoy_type"}',
                p_effective_at    := now() + interval '1 day',
                p_basis           := 'assumed'
            );
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION
                'Role "%" scheduled a type alias out of a gated type', v_role;
        END IF;
        IF v_role IN ('admin', 'team_member')
           AND v_msg NOT LIKE '%Cannot record a type alias from%'
        THEN
            RAISE EXCEPTION
                'Role "%" scheduled alias failed for the wrong reason: %', v_role, v_msg;
        END IF;

        v_failed := false;
        BEGIN
            PERFORM record_assertion(
                'registry_entry', '{"value":"decoy_type"}', v_core,
                p_assertion_key := 'type_alias:assertion_type:review_policy',
                p_effective_at := now() + interval '2 days',
                p_status := 'accepted', p_basis := 'assumed'
            );
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION
                'Role "%" recorded a future-effective type alias out of a gated type', v_role;
        END IF;
        IF v_role IN ('admin', 'team_member')
           AND v_msg NOT LIKE '%Cannot record a type alias from%'
        THEN
            RAISE EXCEPTION
                'Role "%" future-effective alias failed for the wrong reason: %', v_role, v_msg;
        END IF;
    END LOOP;

    PERFORM set_config('app.current_role', 'admin', true);
    IF EXISTS (
        SELECT 1 FROM assertions
        WHERE assertion_type = 'registry_entry'
          AND assertion_key IN (
              'type_alias:assertion_type:registry_entry',
              'type_alias:assertion_type:review_policy'
          )
    ) THEN
        RAISE EXCEPTION 'A scheduled or future-effective alias out of a gated type survived';
    END IF;

    -- ==================================================================
    -- Case 2. A scoped alias is the same alias. registry_value() reads a
    -- scope's own registry entries before the core ones, so an alias
    -- recorded on a scope node routes writes in that scope; the rule reads
    -- the key, not the subject.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'admin', true);
    INSERT INTO nodes (node_type, label) VALUES ('onboarding_scope', 'Alias gate scope')
    RETURNING id INTO v_scope;
    PERFORM record_assertion('scope_status', '{"status":"active"}', v_scope, p_basis := 'assumed');

    v_failed := false;
    BEGIN
        PERFORM record_assertion(
            'registry_entry', '{"value":"decoy_type"}', v_scope,
            p_assertion_key := 'type_alias:assertion_type:registry_entry',
            p_status := 'accepted', p_basis := 'assumed'
        );
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
        v_msg := SQLERRM;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'An admin recorded a scoped type alias out of registry_entry';
    END IF;
    IF v_msg NOT LIKE '%Cannot record a type alias from%' THEN
        RAISE EXCEPTION 'The scoped alias was refused for the wrong reason: %', v_msg;
    END IF;

    -- ==================================================================
    -- Case 3. accept_assertion() of a candidate alias. The only way such a
    -- candidate exists is that the type was gated after it was recorded,
    -- which is exactly what "adding a type to the gate is an INSERT, not a
    -- migration" makes possible. Acceptance is refused for every role.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'admin', true);
    v_cand := record_assertion(
        'registry_entry', '{"value":"decoy_type"}', v_core,
        p_assertion_key := 'type_alias:assertion_type:alias_gate_late',
        p_status := 'candidate', p_basis := 'assumed'
    );
    IF (SELECT status FROM assertions WHERE id = v_cand) <> 'candidate' THEN
        RAISE EXCEPTION 'Premise broken: the pre-gate alias candidate was not recorded';
    END IF;

    INSERT INTO assertion_type_access (assertion_type, operation, allowed_roles)
    VALUES ('alias_gate_late', 'settle', ARRAY['admin'])
    ON CONFLICT (assertion_type, operation) DO NOTHING;
    IF assertion_settle_roles('alias_gate_late') IS NULL THEN
        RAISE EXCEPTION 'Premise broken: the probe type was not gated, so case 3 proves nothing';
    END IF;

    FOREACH v_role IN ARRAY v_roles LOOP
        PERFORM set_config('app.current_role', v_role, true);
        v_failed := false;
        BEGIN
            PERFORM accept_assertion(v_cand);
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" accepted a candidate alias out of a gated type', v_role;
        END IF;
        IF v_role = 'admin' AND v_msg NOT LIKE '%Cannot record a type alias from%' THEN
            RAISE EXCEPTION
                'An admin was refused the candidate alias acceptance for the wrong reason: %', v_msg;
        END IF;
        PERFORM set_config('app.current_role', 'admin', true);
        IF (SELECT status FROM assertions WHERE id = v_cand) <> 'candidate' THEN
            RAISE EXCEPTION 'Role "%" left the candidate alias accepted', v_role;
        END IF;
    END LOOP;

    -- The gated type still resolves to itself, which is the point: the
    -- candidate is invisible to canonical_type() and cannot become visible.
    IF canonical_type('assertion_type', 'alias_gate_late') <> 'alias_gate_late' THEN
        RAISE EXCEPTION
            'The late-gated type canonicalizes to %',
            canonical_type('assertion_type', 'alias_gate_late');
    END IF;

    -- ==================================================================
    -- Case 4. Supersession. An accepted alias recorded before the gate
    -- cannot be replaced with another alias out of the same name: the
    -- replacement is an INSERT and the INSERT is refused. Neither
    -- supersede_assertion() nor record_assertion() on the same key gets
    -- through.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'admin', true);
    v_accepted := record_assertion(
        'registry_entry', '{"value":"alias_gate_early_target"}', v_core,
        p_assertion_key := 'type_alias:assertion_type:alias_gate_early',
        p_status := 'accepted', p_basis := 'assumed'
    );
    IF (SELECT status FROM assertions WHERE id = v_accepted) <> 'accepted' THEN
        RAISE EXCEPTION 'Premise broken: the pre-gate accepted alias was not recorded';
    END IF;

    INSERT INTO assertion_type_access (assertion_type, operation, allowed_roles)
    VALUES ('alias_gate_early', 'settle', ARRAY['admin'])
    ON CONFLICT (assertion_type, operation) DO NOTHING;

    FOREACH v_role IN ARRAY v_roles LOOP
        PERFORM set_config('app.current_role', v_role, true);

        v_failed := false;
        BEGIN
            PERFORM supersede_assertion(
                v_accepted, 'registry_entry', v_core, NULL,
                '{"value":"decoy_type"}',
                p_new_assertion_key := 'type_alias:assertion_type:alias_gate_early',
                p_new_basis := 'assumed'
            );
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION 'Role "%" superseded an alias out of a gated type', v_role;
        END IF;
        IF v_role = 'admin' AND v_msg NOT LIKE '%Cannot record a type alias from%' THEN
            RAISE EXCEPTION
                'An admin''s supersession of the alias failed for the wrong reason: %', v_msg;
        END IF;

        v_failed := false;
        BEGIN
            PERFORM record_assertion(
                'registry_entry', '{"value":"decoy_type"}', v_core,
                p_assertion_key := 'type_alias:assertion_type:alias_gate_early',
                p_status := 'accepted', p_basis := 'assumed'
            );
        EXCEPTION WHEN OTHERS THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;
        IF NOT v_failed THEN
            RAISE EXCEPTION
                'Role "%" replaced an alias out of a gated type through record_assertion()', v_role;
        END IF;

        PERFORM set_config('app.current_role', 'admin', true);
        IF (SELECT superseded_at FROM assertions WHERE id = v_accepted) IS NOT NULL THEN
            RAISE EXCEPTION 'Role "%" ended the standing alias while replacing nothing', v_role;
        END IF;
    END LOOP;

    -- ==================================================================
    -- Case 5. What the rule does not touch, stated so a later reader does
    -- not widen it by accident.
    --
    -- An alias INTO a gated type is allowed. It narrows: a write under the
    -- aliased name canonicalizes to the gated spelling and is then demoted
    -- for a non-admin like any other configuration write.
    -- ==================================================================
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM record_assertion(
        'registry_entry', '{"value":"registry_entry"}', v_core,
        p_assertion_key := 'type_alias:assertion_type:alias_gate_draft',
        p_status := 'accepted', p_basis := 'assumed'
    );
    IF canonical_type('assertion_type', 'alias_gate_draft') <> 'registry_entry' THEN
        RAISE EXCEPTION
            'An alias into a gated type was refused or does not resolve: %',
            canonical_type('assertion_type', 'alias_gate_draft');
    END IF;

    PERFORM set_config('app.current_role', 'team_member', true);
    v_id := record_assertion(
        'alias_gate_draft', '{"value":"through the front door"}', v_core,
        p_assertion_key := 'alias_gate:through_alias',
        p_status := 'accepted', p_basis := 'assumed'
    );
    PERFORM set_config('app.current_role', 'admin', true);
    IF (SELECT status FROM assertions WHERE id = v_id) <> 'candidate' THEN
        RAISE EXCEPTION
            'A write under an alias into a gated type landed accepted for a team_member';
    END IF;
    IF (SELECT assertion_type FROM assertions WHERE id = v_id) <> 'registry_entry' THEN
        RAISE EXCEPTION
            'A write under an alias into a gated type was stored as %',
            (SELECT assertion_type FROM assertions WHERE id = v_id);
    END IF;

    -- An alias on another kind is untouched: the rule is about assertion
    -- types, because that is what the settle gate keys on.
    PERFORM record_assertion(
        'registry_entry', '{"value":"organization"}', v_core,
        p_assertion_key := 'type_alias:node_type:registry_entry',
        p_status := 'accepted', p_basis := 'assumed'
    );
    IF canonical_type('node_type', 'registry_entry') <> 'organization' THEN
        RAISE EXCEPTION
            'A node_type alias sharing the gated name was refused: %',
            canonical_type('node_type', 'registry_entry');
    END IF;

    -- And an ordinary configuration write by an admin still works, so the
    -- new branch did not break the gate it lives in.
    v_id := record_assertion(
        'registry_entry', '{"value":"still_working"}', v_core,
        p_assertion_key := 'alias_gate:admin_ok',
        p_status := 'accepted', p_basis := 'assumed'
    );
    IF (SELECT status FROM assertions WHERE id = v_id) <> 'accepted' THEN
        RAISE EXCEPTION 'An admin can no longer record an accepted registry entry';
    END IF;

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
END
$$;

ROLLBACK;
