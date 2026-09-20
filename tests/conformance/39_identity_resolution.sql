-- Advisory identity resolution (migration 0033): normalizers, verdicts, the
-- read-only guarantee, and merge-chain resolution under 0029's RLS.
--
-- Work item: work/014-identity-resolution.md (supersedes pull request 20).
-- Contract:  design/proposals/rls-visibility-contract.md D1 and D4; issue 17,
--            "agents perform graph inserts; the database gates outcomes, not
--            steps".
--
-- Negative control: without 0033 this suite fails on its first call, because
-- normalize_identity_value() does not exist.
--
-- Invented names only: Northwind, Ident Merge A/B/C, Ident Cycle X/Y.

SET search_path = rye, public, pg_catalog;
BEGIN;

-- --------------------------------------------------------------------------
-- Anti-vacuity, as in tests/conformance/35_supporting_tables_rls.sql.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_bypass boolean;
    v_role   text;
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
END
$$;

-- --------------------------------------------------------------------------
-- The advisory contract, asserted against the catalog rather than prose.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_callers  text;
    v_control  int;
    v_missing  text;
    v_scanned  int;
    v_secdef   text;
BEGIN
    -- The scan below is only worth anything if it is actually looking at
    -- today's function bodies. CREATE OR REPLACE keeps one pg_proc row per
    -- function, so the helpers rewritten by 0025 to 0030 are the rows this
    -- scan reads -- but assert it rather than assume it.
    SELECT count(*) INTO v_scanned
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'rye' AND p.prosrc IS NOT NULL AND p.prosrc <> '';

    IF v_scanned < 50 THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: only % rye function bodies are readable, so a prosrc scan proves nothing',
            v_scanned;
    END IF;

    SELECT string_agg(required.proname, ', ' ORDER BY required.proname)
    INTO v_missing
    FROM (VALUES
        ('record_assertion'), ('supersede_assertion'), ('accept_assertion'),
        ('reject_candidate'), ('resolve_knowledge_gap'), ('record_distillation'),
        ('schedule_assertion_change'), ('record_event'), ('record_artifact'),
        ('link_record'), ('link_records_batch'), ('merge_nodes'),
        ('update_node_properties'), ('capture_domain_change'),
        ('create_knowledge_candidate'), ('describe_category')
    ) required(proname)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'rye' AND p.proname = required.proname
    );
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: write helpers absent from the scan set: %', v_missing;
    END IF;

    -- A control: the scan finds real callers when there are some.
    SELECT count(*) INTO v_control
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'rye'
      AND p.proname <> 'record_event'
      AND p.prosrc LIKE '%record_event%';
    IF v_control < 3 THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: the prosrc scan found only % callers of record_event', v_control;
    END IF;

    -- The four functions 0033 installs, by signature. Without them every
    -- assertion below is about an empty set.
    SELECT string_agg(required.sig, ', ' ORDER BY required.sig)
    INTO v_missing
    FROM (VALUES
        ('rye.normalize_identity_value(text, text)'),
        ('rye.identity_keys(text, uuid)'),
        ('rye.resolve_node_identity(text, text, jsonb, int, uuid)'),
        ('rye.resolve_merged_node(uuid)')
    ) required(sig)
    WHERE to_regprocedure(required.sig) IS NULL;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 0033 is not applied; missing: %', v_missing;
    END IF;

    -- Nothing in the write path may call the resolver. It is advisory: the
    -- agent decides, the database records the outcome through the ordinary
    -- candidate and review path.
    SELECT string_agg(p.proname, ', ' ORDER BY p.proname)
    INTO v_callers
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'rye'
      AND p.proname <> 'resolve_node_identity'
      AND p.prosrc LIKE '%resolve_node_identity%';

    IF v_callers IS NOT NULL THEN
        RAISE EXCEPTION 'resolve_node_identity must stay advisory; called by: %', v_callers;
    END IF;
    RAISE NOTICE 'PASS: no helper calls resolve_node_identity';

    -- SECURITY INVOKER, all four. The narrow definer probe of
    -- rls-visibility-contract D3 is deliberately not implemented; adopting it
    -- would change this assertion and tests/security/04 on purpose.
    SELECT string_agg(p.proname, ', ' ORDER BY p.proname)
    INTO v_secdef
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'rye'
      AND p.proname IN ('resolve_node_identity', 'identity_keys',
                        'normalize_identity_value', 'resolve_merged_node')
      AND p.prosecdef;

    IF v_secdef IS NOT NULL THEN
        RAISE EXCEPTION 'identity functions must be SECURITY INVOKER, found definer: %', v_secdef;
    END IF;

    -- Every one of them declares its own search_path.
    SELECT string_agg(p.proname, ', ' ORDER BY p.proname)
    INTO v_missing
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'rye'
      AND p.proname IN ('resolve_node_identity', 'identity_keys',
                        'normalize_identity_value', 'resolve_merged_node')
      AND NOT EXISTS (
          SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) c
          WHERE c LIKE 'search_path=%'
      );
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'identity functions must set search_path, missing on: %', v_missing;
    END IF;
    RAISE NOTICE 'PASS: identity functions are SECURITY INVOKER and set search_path';
END
$$;

DO $$
DECLARE
    v_after_assertions bigint;
    v_after_events bigint;
    v_after_nodes bigint;
    v_before_assertions bigint;
    v_before_events bigint;
    v_before_nodes bigint;
    v_core uuid;
    v_dup_a uuid;
    v_dup_b uuid;
    v_dup_c uuid;
    v_cyc_x uuid;
    v_cyc_y uuid;
    v_failed boolean;
    v_merge_d uuid;
    v_merge_e uuid;
    v_org1 uuid;
    v_org2 uuid;
    v_res jsonb;
    v_role text;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:identity-resolution', true);
    PERFORM set_config('app.current_teams', '', true);

    -- ------------------------------------------------------------------
    -- Normalizers
    -- ------------------------------------------------------------------
    IF normalize_identity_value('  Https://WWW.Acme.COM/about?x=1 ', 'domain') <> 'acme.com' THEN
        RAISE EXCEPTION 'domain normalizer failed';
    END IF;
    IF normalize_identity_value('  Bob@Acme.com ', 'lower') <> 'bob@acme.com' THEN
        RAISE EXCEPTION 'lower normalizer failed';
    END IF;
    IF normalize_identity_value('+1 (555) 010-9999', 'digits_only') <> '15550109999' THEN
        RAISE EXCEPTION 'digits_only normalizer failed';
    END IF;
    IF normalize_identity_value(NULL, 'lower') IS NOT NULL THEN
        RAISE EXCEPTION 'null input must normalize to null';
    END IF;
    IF normalize_identity_value('   ', 'trim') IS NOT NULL THEN
        RAISE EXCEPTION 'blank input must normalize to null';
    END IF;
    RAISE NOTICE 'PASS: normalizers behave';

    -- An unknown normalizer raises rather than passing the value through;
    -- a silent pass-through would quietly widen identity.
    v_failed := false;
    BEGIN
        PERFORM normalize_identity_value('x', 'fancy_matcher');
    EXCEPTION WHEN others THEN
        v_failed := true;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'unknown normalizer was accepted';
    END IF;
    RAISE NOTICE 'PASS: unknown normalizer raises';

    -- ------------------------------------------------------------------
    -- Declared identity keys drive exact matching.
    -- ------------------------------------------------------------------
    SELECT id INTO v_core
    FROM nodes
    WHERE external_source = 'rye_registry' AND external_id = 'core' AND archived_at IS NULL;

    IF v_core IS NULL THEN
        RAISE EXCEPTION 'The core registry node is missing; registry entries cannot be written';
    END IF;

    PERFORM record_assertion(
        p_assertion_type := 'registry_entry',
        p_assertion_key := 'identity_keys:ident_org',
        p_subject_node_id := v_core,
        p_claim := jsonb_build_object(
            'value', '[{"property":"email","normalize":"lower"},
                       {"property":"website","normalize":"domain"}]'::jsonb,
            'layer', 'core'),
        p_basis := 'assumed',
        p_status := 'accepted'
    );

    IF jsonb_array_length(identity_keys('ident_org')) <> 2 THEN
        RAISE EXCEPTION 'identity_keys did not resolve the registry entry';
    END IF;
    IF jsonb_array_length(identity_keys('ident_never_configured')) <> 0 THEN
        RAISE EXCEPTION 'unconfigured node type must yield an empty key list';
    END IF;
    RAISE NOTICE 'PASS: identity_keys resolves from the registry';

    INSERT INTO nodes (node_type, label, external_id, external_source, properties)
    VALUES ('ident_org', 'Ident Northwind', 'IDENT-1', 'ident_suite',
            '{"email":"Contact@Northwind.example","website":"https://www.northwind.example/x"}')
    RETURNING id INTO v_org1;

    -- Normalization is applied on both sides: different spelling, same identity.
    v_res := resolve_node_identity('ident_org', NULL,
                 '{"email":"  contact@northwind.EXAMPLE "}'::jsonb);
    IF v_res->>'verdict' <> 'match' THEN
        RAISE EXCEPTION 'normalized email did not produce a match (got %)', v_res->>'verdict';
    END IF;
    IF v_res->'candidates'->0->>'match_reason' <> 'identity:email' THEN
        RAISE EXCEPTION 'match reason should name the identity key (got %)',
            v_res->'candidates'->0->>'match_reason';
    END IF;
    IF (v_res->'candidates'->0->>'node_id') <> v_org1::text THEN
        RAISE EXCEPTION 'match named the wrong node';
    END IF;
    RAISE NOTICE 'PASS: declared identity key matches across spelling differences';

    v_res := resolve_node_identity('ident_org', NULL,
                 '{"website":"http://northwind.example/other/path"}'::jsonb);
    IF v_res->>'verdict' <> 'match' THEN
        RAISE EXCEPTION 'domain-normalized website did not match (got %)', v_res->>'verdict';
    END IF;
    RAISE NOTICE 'PASS: domain normalizer matches across url shapes';

    v_res := resolve_node_identity('ident_org', NULL,
                 '{"external_source":"ident_suite","external_id":"IDENT-1"}'::jsonb);
    IF v_res->>'verdict' <> 'match'
       OR v_res->'candidates'->0->>'match_reason' <> 'external_id' THEN
        RAISE EXCEPTION 'external identity did not match exactly (got %)', v_res;
    END IF;
    RAISE NOTICE 'PASS: external identity matches exactly';

    -- ------------------------------------------------------------------
    -- Two nodes sharing an identity key is ambiguous, not a match.
    -- ------------------------------------------------------------------
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('ident_org', 'Ident Northwind Holdings',
            '{"email":"contact@northwind.example"}')
    RETURNING id INTO v_org2;

    v_res := resolve_node_identity('ident_org', NULL,
                 '{"email":"contact@northwind.example"}'::jsonb);
    IF v_res->>'verdict' <> 'ambiguous' THEN
        RAISE EXCEPTION 'duplicate identity key should be ambiguous (got %)', v_res->>'verdict';
    END IF;
    IF (v_res->>'exact_count')::int <> 2 THEN
        RAISE EXCEPTION 'expected two exact candidates, got %', v_res->>'exact_count';
    END IF;
    RAISE NOTICE 'PASS: competing identity keys report ambiguous';

    -- ------------------------------------------------------------------
    -- A similar name is grounds for review, never an identity claim.
    -- ------------------------------------------------------------------
    v_res := resolve_node_identity('ident_org', 'Ident Northwnd');
    IF v_res->>'verdict' <> 'ambiguous' THEN
        RAISE EXCEPTION 'near-miss label should be ambiguous (got %)', v_res->>'verdict';
    END IF;
    IF (v_res->>'exact_count')::int <> 0 OR (v_res->>'fuzzy_count')::int < 1 THEN
        RAISE EXCEPTION 'near-miss should be fuzzy-only (%)', v_res;
    END IF;
    IF v_res->'candidates'->0->>'exact' <> 'false' THEN
        RAISE EXCEPTION 'fuzzy candidate must not be flagged exact';
    END IF;
    RAISE NOTICE 'PASS: similar names never produce a match verdict';

    -- Even a label identical to an existing node is not a match: only
    -- external identity and declared keys are evidence of identity.
    v_res := resolve_node_identity('ident_org', 'Ident Northwind');
    IF v_res->>'verdict' <> 'ambiguous' THEN
        RAISE EXCEPTION 'an exactly equal label must still be ambiguous (got %)', v_res->>'verdict';
    END IF;
    RAISE NOTICE 'PASS: an identical label is still only ambiguous';

    v_res := resolve_node_identity('ident_org', 'Wholly Unrelated Trading Company');
    IF v_res->>'verdict' <> 'new' THEN
        RAISE EXCEPTION 'unrelated label should be new (got %)', v_res->>'verdict';
    END IF;
    RAISE NOTICE 'PASS: unmatched identity reports new';

    -- ------------------------------------------------------------------
    -- Read-only: consulting the resolver changes nothing. Under every role,
    -- including the two that may not write at all after 0026.
    -- ------------------------------------------------------------------
    FOREACH v_role IN ARRAY ARRAY['admin', 'team_member', 'viewer', 'agent:ident', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);

        SELECT count(*) INTO v_before_nodes      FROM nodes;
        SELECT count(*) INTO v_before_events     FROM events;
        SELECT count(*) INTO v_before_assertions FROM assertions;

        v_res := resolve_node_identity('ident_org', 'Ident Northwind',
                     '{"email":"contact@northwind.example"}'::jsonb);
        IF v_res->>'verdict' IS NULL THEN
            RAISE EXCEPTION 'role "%" got no verdict from the resolver', v_role;
        END IF;
        PERFORM resolve_node_identity('ident_org', 'Nothing At All');
        PERFORM resolve_merged_node(v_org1);

        SELECT count(*) INTO v_after_nodes      FROM nodes;
        SELECT count(*) INTO v_after_events     FROM events;
        SELECT count(*) INTO v_after_assertions FROM assertions;

        IF v_after_nodes <> v_before_nodes
           OR v_after_events <> v_before_events
           OR v_after_assertions <> v_before_assertions THEN
            RAISE EXCEPTION 'the resolver wrote to the database under role "%"', v_role;
        END IF;
    END LOOP;
    PERFORM set_config('app.current_role', 'admin', true);
    RAISE NOTICE 'PASS: the resolver is a pure read for every role, writers and readers alike';

    -- An unclassified population resolves the same way for a reader as for an
    -- admin: nothing here is hidden, so nothing here should differ.
    PERFORM set_config('app.current_role', 'viewer', true);
    v_res := resolve_node_identity('ident_org', NULL,
                 '{"external_source":"ident_suite","external_id":"IDENT-1"}'::jsonb);
    IF v_res->>'verdict' <> 'match' THEN
        RAISE EXCEPTION 'a viewer must resolve an unclassified identity (got %)', v_res->>'verdict';
    END IF;
    PERFORM set_config('app.current_role', '', true);
    v_res := resolve_node_identity('ident_org', NULL,
                 '{"external_source":"ident_suite","external_id":"IDENT-1"}'::jsonb);
    IF v_res->>'verdict' <> 'match' THEN
        RAISE EXCEPTION 'a role-less session must resolve an unclassified identity (got %)', v_res->>'verdict';
    END IF;
    PERFORM set_config('app.current_role', 'admin', true);
    RAISE NOTICE 'PASS: viewer and role-less sessions read the resolver';

    -- ------------------------------------------------------------------
    -- Merge chains resolve transitively, under 0029's RLS on node_merges.
    -- ------------------------------------------------------------------
    INSERT INTO nodes (node_type, label) VALUES ('ident_org', 'Ident Merge A') RETURNING id INTO v_dup_a;
    INSERT INTO nodes (node_type, label) VALUES ('ident_org', 'Ident Merge B') RETURNING id INTO v_dup_b;
    INSERT INTO nodes (node_type, label) VALUES ('ident_org', 'Ident Merge C') RETURNING id INTO v_dup_c;
    INSERT INTO nodes (node_type, label) VALUES ('ident_org', 'Ident Merge D') RETURNING id INTO v_merge_d;
    INSERT INTO nodes (node_type, label) VALUES ('ident_org', 'Ident Merge E') RETURNING id INTO v_merge_e;
    INSERT INTO nodes (node_type, label) VALUES ('ident_org', 'Ident Cycle X') RETURNING id INTO v_cyc_x;
    INSERT INTO nodes (node_type, label) VALUES ('ident_org', 'Ident Cycle Y') RETURNING id INTO v_cyc_y;

    IF resolve_merged_node(v_dup_a) <> v_dup_a THEN
        RAISE EXCEPTION 'an unmerged node must resolve to itself';
    END IF;

    INSERT INTO node_merges (duplicate_id, canonical_id, merged_by)
    VALUES (v_dup_a, v_dup_b, 'test'), (v_dup_b, v_dup_c, 'test');

    IF resolve_merged_node(v_dup_a) <> v_dup_c THEN
        RAISE EXCEPTION 'merge chain did not resolve transitively';
    END IF;
    IF resolve_merged_node(v_dup_b) <> v_dup_c THEN
        RAISE EXCEPTION 'partial merge chain did not resolve';
    END IF;
    IF resolve_merged_node(NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'null input must resolve to null';
    END IF;
    RAISE NOTICE 'PASS: merge chains resolve transitively';

    -- The real write path: merge_nodes() archives the duplicate, and the
    -- archived id still traces to the survivor. 0029 made node_merges forced
    -- RLS and insert-only; this is the check that the lookup survived it.
    PERFORM merge_nodes(v_merge_d, v_merge_e, 'test:identity-resolution');
    IF resolve_merged_node(v_merge_d) <> v_merge_e THEN
        RAISE EXCEPTION 'a merge recorded by merge_nodes() did not resolve';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = v_merge_d AND archived_at IS NOT NULL) THEN
        RAISE EXCEPTION 'fixture invalid: merge_nodes() did not archive the duplicate';
    END IF;
    RAISE NOTICE 'PASS: an archived duplicate traces to the surviving node';

    -- Every role that can see both nodes gets the chain. node_merges'
    -- read policy anchors on node visibility, exactly as edges do, so this
    -- needs no SECURITY DEFINER.
    FOREACH v_role IN ARRAY ARRAY['team_member', 'viewer', 'agent:ident', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF resolve_merged_node(v_dup_a) <> v_dup_c THEN
            RAISE EXCEPTION
                'role "%" can see every node in the chain but did not resolve it to the live node', v_role;
        END IF;
        IF resolve_merged_node(v_merge_d) <> v_merge_e THEN
            RAISE EXCEPTION 'role "%" did not resolve a merge_nodes() merge', v_role;
        END IF;
    END LOOP;
    PERFORM set_config('app.current_role', 'admin', true);
    RAISE NOTICE 'PASS: the merge chain resolves for every role that can see the nodes';

    INSERT INTO node_merges (duplicate_id, canonical_id, merged_by)
    VALUES (v_cyc_x, v_cyc_y, 'test'), (v_cyc_y, v_cyc_x, 'test');

    v_failed := false;
    BEGIN
        PERFORM resolve_merged_node(v_cyc_x);
    EXCEPTION WHEN others THEN
        v_failed := true;
    END;
    IF NOT v_failed THEN
        RAISE EXCEPTION 'merge cycle did not raise';
    END IF;
    RAISE NOTICE 'PASS: merge cycles raise instead of looping';
END
$$;

ROLLBACK;
