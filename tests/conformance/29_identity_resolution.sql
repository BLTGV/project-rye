-- Advisory identity resolution (migration 0021): normalizers, verdicts,
-- read-only guarantee, and merge-chain resolution.

SET search_path = rye, public, pg_catalog;
BEGIN;

DO $$
DECLARE
    v_after_assertions bigint;
    v_after_events bigint;
    v_after_nodes bigint;
    v_before_assertions bigint;
    v_before_events bigint;
    v_before_nodes bigint;
    v_callers text;
    v_core uuid;
    v_dup_a uuid;
    v_dup_b uuid;
    v_dup_c uuid;
    v_cyc_x uuid;
    v_cyc_y uuid;
    v_failed boolean;
    v_org1 uuid;
    v_org2 uuid;
    v_res jsonb;
    v_secdef text;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:identity-resolution', true);
    PERFORM set_config('app.current_teams', '', true);

    -- ------------------------------------------------------------------
    -- Advisory contract: nothing in the write path may call it.
    -- ------------------------------------------------------------------
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
    RAISE NOTICE 'PASS: identity functions are SECURITY INVOKER';

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
            '{"email":"Contact@Northwind.example","website":"https://www.northwind.example/x"}');
    SELECT id INTO v_org1 FROM nodes WHERE label = 'Ident Northwind' ORDER BY created_at DESC LIMIT 1;

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
            '{"email":"contact@northwind.example"}');
    SELECT id INTO v_org2 FROM nodes WHERE label = 'Ident Northwind Holdings' ORDER BY created_at DESC LIMIT 1;

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

    v_res := resolve_node_identity('ident_org', 'Wholly Unrelated Trading Company');
    IF v_res->>'verdict' <> 'new' THEN
        RAISE EXCEPTION 'unrelated label should be new (got %)', v_res->>'verdict';
    END IF;
    RAISE NOTICE 'PASS: unmatched identity reports new';

    -- ------------------------------------------------------------------
    -- Read-only: consulting the resolver changes nothing.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_before_nodes      FROM nodes;
    SELECT count(*) INTO v_before_events     FROM events;
    SELECT count(*) INTO v_before_assertions FROM assertions;

    PERFORM resolve_node_identity('ident_org', 'Ident Northwind',
                '{"email":"contact@northwind.example"}'::jsonb);
    PERFORM resolve_node_identity('ident_org', 'Nothing At All');

    SELECT count(*) INTO v_after_nodes      FROM nodes;
    SELECT count(*) INTO v_after_events     FROM events;
    SELECT count(*) INTO v_after_assertions FROM assertions;

    IF v_after_nodes <> v_before_nodes
       OR v_after_events <> v_before_events
       OR v_after_assertions <> v_before_assertions THEN
        RAISE EXCEPTION 'resolve_node_identity wrote to the database';
    END IF;
    RAISE NOTICE 'PASS: resolve_node_identity performs no writes';

    -- ------------------------------------------------------------------
    -- Merge chains resolve transitively.
    -- ------------------------------------------------------------------
    INSERT INTO nodes (node_type, label) VALUES
        ('ident_org', 'Ident Merge A'),
        ('ident_org', 'Ident Merge B'),
        ('ident_org', 'Ident Merge C'),
        ('ident_org', 'Ident Cycle X'),
        ('ident_org', 'Ident Cycle Y');
    SELECT id INTO v_dup_a FROM nodes WHERE label = 'Ident Merge A' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_dup_b FROM nodes WHERE label = 'Ident Merge B' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_dup_c FROM nodes WHERE label = 'Ident Merge C' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_cyc_x FROM nodes WHERE label = 'Ident Cycle X' ORDER BY created_at DESC LIMIT 1;
    SELECT id INTO v_cyc_y FROM nodes WHERE label = 'Ident Cycle Y' ORDER BY created_at DESC LIMIT 1;

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
