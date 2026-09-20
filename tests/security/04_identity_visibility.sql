-- Identity resolution and merge-chain lookup under RLS.
--
-- Migration: schema/migrations/0033_identity_resolution.sql.
-- Work item: work/014-identity-resolution.md (supersedes pull request 20).
-- Contract:  design/proposals/rls-visibility-contract.md, D1 and D3.
--
-- This suite pins the CURRENT behavior, which is deliberate in both halves:
--
--   Resolution. A node hidden from the caller is not matched, so
--   resolve_node_identity() reports `new` and an agent acting on that verdict
--   would create a duplicate no single role can see alongside the original.
--   That is the split-brain risk the visibility contract describes. The
--   `restricted` verdict proposed there (D3) is NOT implemented: it assumed a
--   SECURITY DEFINER probe could read past RLS, and FORCE ROW LEVEL SECURITY
--   applies to the table owner, so that only holds where the owner has
--   BYPASSRLS. The contract records D3 as blocked on that finding.
--
--   Merge chains. node_merges has forced RLS since 0029 and its read policy
--   anchors on node visibility: a caller that cannot see both endpoints is not
--   told the merge happened. A chain through a node the caller cannot see
--   therefore stops at the last visible link, which is D1 -- prune silently,
--   disclose nothing -- and is recoverable: nothing is written, and a caller
--   with wider access gets the whole chain on a re-run.
--
-- What leaks is asserted positively below: no id, no label, no count, no
-- verdict that differs from a genuinely absent node. If D3 is adopted, these
-- assertions must be changed on purpose rather than discovered failing.
--
-- Invented names only: Hidden Identity Org, Idvis Stale/Bridge/Survivor.

SET search_path = rye, public, pg_catalog;
BEGIN;

DO $$
DECLARE
    v_bypass boolean;
    v_bridge uuid;
    v_core uuid;
    v_hidden uuid;
    v_res jsonb;
    v_role text;
    v_stale uuid;
    v_super boolean;
    v_survivor uuid;
BEGIN
    -- ------------------------------------------------------------------
    -- Anti-vacuity, as in tests/conformance/35_supporting_tables_rls.sql.
    -- A session that bypasses RLS cannot test RLS, so fail rather than skip.
    -- ------------------------------------------------------------------
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

    IF to_regprocedure('rye.resolve_node_identity(text, text, jsonb, int, uuid)') IS NULL
       OR to_regprocedure('rye.resolve_merged_node(uuid)') IS NULL THEN
        RAISE EXCEPTION 'migration 0033 is not applied; there is nothing here to pin';
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:identity-visibility', true);
    PERFORM set_config('app.current_teams', 'locked', true);

    SELECT id INTO v_core
    FROM nodes
    WHERE external_source = 'rye_registry' AND external_id = 'core' AND archived_at IS NULL;

    IF v_core IS NULL THEN
        RAISE EXCEPTION 'The core registry node is missing; registry entries cannot be written';
    END IF;

    PERFORM record_assertion(
        p_assertion_type := 'registry_entry',
        p_assertion_key := 'identity_keys:idvis_org',
        p_subject_node_id := v_core,
        p_claim := jsonb_build_object(
            'value', '[{"property":"email","normalize":"lower"}]'::jsonb,
            'layer', 'core'),
        p_basis := 'assumed',
        p_status := 'accepted'
    );

    INSERT INTO nodes (node_type, label, properties, attrs)
    VALUES ('idvis_org', 'Hidden Identity Org',
            '{"email":"ops@hidden.example"}',
            '{"classification":"confidential","teams":["locked"]}')
    RETURNING id INTO v_hidden;

    -- A merge chain whose middle node is the hidden one:
    --   Idvis Stale -> Hidden Identity Org -> Idvis Survivor
    INSERT INTO nodes (node_type, label) VALUES ('idvis_org', 'Idvis Stale')
    RETURNING id INTO v_stale;
    INSERT INTO nodes (node_type, label) VALUES ('idvis_org', 'Idvis Survivor')
    RETURNING id INTO v_survivor;
    -- ...and a chain with nothing hidden in it, as the control.
    INSERT INTO nodes (node_type, label) VALUES ('idvis_org', 'Idvis Bridge')
    RETURNING id INTO v_bridge;

    INSERT INTO node_merges (duplicate_id, canonical_id, merged_by) VALUES
        (v_stale,  v_hidden,    'test'),
        (v_hidden, v_survivor,  'test'),
        (v_bridge, v_survivor,  'test');

    -- ------------------------------------------------------------------
    -- Cleared caller: an ordinary writing role on the team that owns the
    -- classification. Not an admin, so node_merges' admin branch is not what
    -- is being tested here.
    -- ------------------------------------------------------------------
    PERFORM set_config('app.current_role', 'team_member', true);
    PERFORM set_config('app.current_teams', 'locked', true);

    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = v_hidden) THEN
        RAISE EXCEPTION 'fixture invalid: the cleared caller cannot see the classified node';
    END IF;

    v_res := resolve_node_identity('idvis_org', NULL, '{"email":"ops@hidden.example"}'::jsonb);
    IF v_res->>'verdict' <> 'match' THEN
        RAISE EXCEPTION 'cleared caller should match the hidden org (got %)', v_res->>'verdict';
    END IF;
    IF v_res->'candidates'->0->>'node_id' <> v_hidden::text THEN
        RAISE EXCEPTION 'cleared caller matched the wrong node';
    END IF;
    RAISE NOTICE 'PASS: a cleared non-admin caller resolves the identity';

    IF resolve_merged_node(v_stale) <> v_survivor THEN
        RAISE EXCEPTION 'cleared caller did not follow the chain through the classified node';
    END IF;
    RAISE NOTICE 'PASS: a cleared caller follows a merge chain through a classified node';

    -- ------------------------------------------------------------------
    -- Uncleared callers: same role with no team, and an unknown role. Only
    -- visibility changes.
    -- ------------------------------------------------------------------
    FOREACH v_role IN ARRAY ARRAY['team_member', 'identity_uncleared', 'viewer', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        PERFORM set_config('app.current_teams', '', true);

        IF EXISTS (SELECT 1 FROM nodes WHERE id = v_hidden) THEN
            RAISE EXCEPTION
                'fixture invalid: role "%" can still see the classified node', v_role;
        END IF;

        -- Resolution: `new`, and nothing about the hidden node comes back.
        v_res := resolve_node_identity('idvis_org', NULL, '{"email":"ops@hidden.example"}'::jsonb);

        IF v_res->>'verdict' <> 'new' THEN
            RAISE EXCEPTION
                'uncleared role "%" got verdict %; if D3 (restricted) was implemented, update this test deliberately',
                v_role, v_res->>'verdict';
        END IF;
        IF jsonb_array_length(v_res->'candidates') <> 0 THEN
            RAISE EXCEPTION 'hidden node leaked into the candidate list for role "%"', v_role;
        END IF;
        IF (v_res->>'exact_count')::int <> 0 OR (v_res->>'fuzzy_count')::int <> 0 THEN
            RAISE EXCEPTION 'hidden node leaked as a count for role "%": %', v_role, v_res;
        END IF;
        IF v_res::text LIKE '%Hidden Identity Org%' OR v_res::text LIKE '%' || v_hidden::text || '%' THEN
            RAISE EXCEPTION 'the verdict payload names the hidden node for role "%"', v_role;
        END IF;

        -- A genuinely absent identity is indistinguishable from the hidden
        -- one. That is the split-brain risk, stated as an assertion.
        IF v_res->>'verdict'
           IS DISTINCT FROM (resolve_node_identity('idvis_org', NULL,
                                '{"email":"nobody@absent.example"}'::jsonb)->>'verdict') THEN
            RAISE EXCEPTION
                'hidden and absent identities became distinguishable for role "%"', v_role;
        END IF;

        -- Merge chains: the walk stops at the last visible link and returns
        -- no id the caller cannot read.
        IF resolve_merged_node(v_stale) <> v_stale THEN
            RAISE EXCEPTION
                'role "%" followed a merge chain through a node it cannot see (got %)',
                v_role, resolve_merged_node(v_stale);
        END IF;

        -- The control: a chain with no hidden link still resolves, so the
        -- pruning above is about visibility and not about the role.
        IF resolve_merged_node(v_bridge) <> v_survivor THEN
            RAISE EXCEPTION
                'role "%" could not follow a fully visible merge chain', v_role;
        END IF;
    END LOOP;

    RAISE NOTICE 'PASS: hidden identity reports new and leaks no candidate (D3 not implemented)';
    RAISE NOTICE 'PASS: a merge chain through an invisible node prunes silently (D1)';
END
$$;

ROLLBACK;
