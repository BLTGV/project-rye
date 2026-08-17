-- Identity resolution under RLS.
--
-- Pins the CURRENT behavior: a node hidden from the caller is not matched, so
-- resolve_node_identity() reports `new` and an agent acting on that verdict
-- would create a duplicate no single role can see alongside the original.
--
-- That is the split-brain risk described in
-- design/proposals/rls-visibility-contract.md D3. The `restricted` verdict
-- proposed there is deliberately NOT implemented: it assumed a SECURITY
-- DEFINER probe could read past RLS, and FORCE ROW LEVEL SECURITY applies to
-- the table owner, so that only holds when the owner has BYPASSRLS.
--
-- If D3 is adopted, this test must be updated on purpose rather than
-- discovered to be failing.

SET search_path = rye, public, pg_catalog;
BEGIN;

DO $$
DECLARE
    v_bypasses_rls boolean;
    v_core uuid;
    v_hidden uuid;
    v_res jsonb;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:identity-visibility', true);
    PERFORM set_config('app.current_teams', 'locked', true);

    SELECT id INTO v_core
    FROM nodes
    WHERE external_source = 'rye_registry' AND external_id = 'core' AND archived_at IS NULL;

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
            '{"classification":"confidential","teams":["locked"]}');
    SELECT id INTO v_hidden FROM nodes WHERE label = 'Hidden Identity Org' ORDER BY created_at DESC LIMIT 1;

    -- Cleared caller sees it and gets a match.
    v_res := resolve_node_identity('idvis_org', NULL, '{"email":"ops@hidden.example"}'::jsonb);
    IF v_res->>'verdict' <> 'match' THEN
        RAISE EXCEPTION 'cleared caller should match the hidden org (got %)', v_res->>'verdict';
    END IF;
    RAISE NOTICE 'PASS: cleared caller resolves the identity';

    -- Step down to a role with no team and no access_grants. The seeded
    -- 'admin' role holds a standing grant to confidential nodes.
    PERFORM set_config('app.current_teams', '', true);
    PERFORM set_config('app.current_role', 'identity_uncleared', true);

    SELECT rolsuper INTO v_bypasses_rls FROM pg_roles WHERE rolname = current_user;
    IF v_bypasses_rls THEN
        RAISE NOTICE 'SKIP: % bypasses RLS; run under RYE_TEST_ROLE for coverage', current_user;
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM nodes WHERE id = v_hidden) THEN
        RAISE EXCEPTION 'fixture invalid: restricted node is still visible';
    END IF;

    v_res := resolve_node_identity('idvis_org', NULL, '{"email":"ops@hidden.example"}'::jsonb);

    IF v_res->>'verdict' <> 'new' THEN
        RAISE EXCEPTION
            'uncleared caller got verdict %; if D3 (restricted) was implemented, update this test deliberately',
            v_res->>'verdict';
    END IF;
    IF jsonb_array_length(v_res->'candidates') <> 0 THEN
        RAISE EXCEPTION 'hidden node leaked into the candidate list';
    END IF;
    RAISE NOTICE 'PASS: hidden identity reports new and leaks no candidate (D3 not implemented)';
END
$$;

ROLLBACK;
