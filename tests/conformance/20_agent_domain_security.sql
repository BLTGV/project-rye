-- Agent domain authority, scoped capabilities, and context-pack isolation.

SET search_path = rye, public, pg_catalog;

BEGIN;

DO $$
DECLARE
    v_account_domain uuid;
    v_title_domain uuid;
    v_local_domain uuid;
    v_intake_agent uuid;
    v_reviewer_agent uuid;
    v_token text;
    v_auth jsonb;
    v_authz jsonb;
    v_candidate uuid;
    v_future_candidate uuid;
    v_denied boolean := false;
    v_context jsonb;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:agent-domain-security', true);

    v_account_domain := ensure_knowledge_domain(
        'sec-account-updates',
        'Security Test Account Updates',
        'Shared account status and owner updates for conformance tests.'
    );
    v_title_domain := ensure_knowledge_domain(
        'sec-title-diligence',
        'Security Test Title Diligence',
        'Title, mineral ownership, and diligence facts for conformance tests.'
    );
    v_local_domain := ensure_knowledge_domain(
        'sec-channel-local-ops',
        'Security Test Channel Local Ops',
        'Channel-local operational notes that should not cross unrelated channels.'
    );

    PERFORM subscribe_channel_to_domain('slack:#sec-sales', 'sec-account-updates', 'candidate_write', true);
    PERFORM subscribe_channel_to_domain('slack:#sec-sales', 'sec-channel-local-ops', 'candidate_write', false);
    PERFORM subscribe_channel_to_domain('slack:#sec-finance', 'sec-account-updates', 'read', true);

    PERFORM grant_domain_authority(
        'sec-account-updates',
        'person',
        'person:ava-deal-lead',
        ARRAY['account_status'],
        NULL,
        ARRAY['confirmed']
    );

    IF NOT EXISTS (
        SELECT 1
        FROM domain_authorities da
        WHERE da.domain_id = v_account_domain
          AND da.authority_ref = 'person:ava-deal-lead'
          AND 'account_status' = ANY(da.claim_types)
    ) THEN
        RAISE EXCEPTION 'Expected Ava to be authoritative for account_status in account domain';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM domain_authorities da
        WHERE da.domain_id = v_title_domain
          AND da.authority_ref = 'person:ava-deal-lead'
    ) THEN
        RAISE EXCEPTION 'Ava should not be authoritative in title diligence domain';
    END IF;

    v_intake_agent := create_agent_identity(
        'sec-intake-agent',
        'Security Test Intake Agent',
        'conformance'
    );
    v_reviewer_agent := create_agent_identity(
        'sec-reviewer-agent',
        'Security Test Reviewer Agent',
        'conformance'
    );

    PERFORM grant_agent_capability('sec-intake-agent', 'rye.context.read', 'sec-account-updates');
    PERFORM grant_agent_capability('sec-intake-agent', 'rye.context.read', 'sec-channel-local-ops');
    PERFORM grant_agent_capability('sec-intake-agent', 'rye.candidate.create', 'sec-account-updates');
    PERFORM grant_agent_capability('sec-intake-agent', 'rye.candidate.create', 'sec-channel-local-ops');
    PERFORM grant_agent_capability('sec-reviewer-agent', 'rye.candidate.adjudicate', 'sec-account-updates');
    PERFORM grant_agent_capability('sec-reviewer-agent', 'rye.authoritative.promote', 'sec-account-updates');

    v_token := issue_agent_token('sec-intake-agent', 'sql conformance token');
    IF v_token IS NULL OR left(v_token, 4) <> 'rye_' THEN
        RAISE EXCEPTION 'Expected one-time token value to be returned';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM agent_api_tokens
        WHERE token_hash = v_token
    ) THEN
        RAISE EXCEPTION 'Token table must store only a hash, not the plaintext token';
    END IF;

    v_auth := authenticate_agent_token(v_token);
    IF v_auth->>'agent_key' <> rye_slugify_key('sec-intake-agent') THEN
        RAISE EXCEPTION 'Token authentication returned wrong agent: %', v_auth;
    END IF;

    v_authz := authorize_agent_action(
        v_intake_agent,
        'rye.candidate.create',
        ARRAY['sec-account-updates'],
        NULL,
        NULL
    );
    IF (v_authz->>'allowed')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'Expected candidate create to be allowed in granted domain';
    END IF;

    v_candidate := agent_create_candidate(
        p_agent_id          := v_intake_agent,
        p_candidate_kind    := 'fact',
        p_statement         := 'Apex account owner is Mina as of the current sales review.',
        p_domain_keys       := ARRAY['sec-account-updates'],
        p_source_scope      := 'slack:#sec-sales',
        p_impact_scope      := 'account:apex',
        p_authority_basis   := 'deal lead confirmation',
        p_speech_act        := 'confirmed',
        p_current_or_future := 'current',
        p_evidence_refs     := '[{"source":"slack","id":"sec-sales-001"}]'::jsonb,
        p_confidence        := 0.84
    );

    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = v_candidate
          AND properties->'target_payload'->'domain_keys' ? rye_slugify_key('sec-account-updates')
          AND properties->'target_payload'->>'source_scope' = 'slack:#sec-sales'
          AND properties->'target_payload'->>'authority_basis' = 'deal lead confirmation'
    ) THEN
        RAISE EXCEPTION 'Agent candidate did not preserve domain metadata';
    END IF;

    v_future_candidate := agent_create_candidate(
        p_agent_id          := v_intake_agent,
        p_candidate_kind    := 'procedure',
        p_statement         := 'Starting next month, account handoff must use the weekly account review template.',
        p_domain_keys       := ARRAY['sec-account-updates'],
        p_source_scope      := 'slack:#sec-sales',
        p_impact_scope      := 'process:account-handoff',
        p_current_or_future := 'future',
        p_evidence_refs     := '[{"source":"email","id":"future-001"}]'::jsonb,
        p_confidence        := 0.7
    );

    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = v_future_candidate
          AND properties->'target_payload'->>'current_or_future' = 'future'
    ) THEN
        RAISE EXCEPTION 'Future candidate was not preserved as future metadata';
    END IF;

    BEGIN
        PERFORM agent_create_candidate(
            p_agent_id        := v_intake_agent,
            p_candidate_kind  := 'fact',
            p_statement       := 'Title diligence is complete.',
            p_domain_keys     := ARRAY['sec-title-diligence'],
            p_source_scope    := 'slack:#sec-sales',
            p_evidence_refs   := '[{"source":"slack","id":"sec-title-denied"}]'::jsonb
        );
    EXCEPTION WHEN insufficient_privilege THEN
        v_denied := true;
    END;

    IF NOT v_denied THEN
        RAISE EXCEPTION 'Expected ungranted title-domain candidate create to be denied';
    END IF;

    v_authz := authorize_agent_action(
        v_intake_agent,
        'rye.candidate.create',
        ARRAY['sec-title-diligence'],
        'slack:#sec-sales',
        'title-denied'
    );
    PERFORM record_agent_action(
        v_intake_agent,
        'candidate_create',
        'rye.candidate.create',
        (v_authz->>'allowed')::boolean,
        ARRAY['sec-title-diligence'],
        'slack:#sec-sales',
        'title-denied',
        v_authz->>'reason',
        jsonb_build_object('statement', 'Title diligence is complete.'),
        '{}'::jsonb
    );

    v_authz := authorize_agent_action(
        v_intake_agent,
        'rye.authoritative.promote',
        ARRAY['sec-account-updates'],
        NULL,
        v_candidate::text
    );
    IF (v_authz->>'allowed')::boolean THEN
        RAISE EXCEPTION 'Intake agent should not be allowed to promote authoritative facts';
    END IF;

    v_authz := authorize_agent_action(
        v_reviewer_agent,
        'rye.authoritative.promote',
        ARRAY['sec-account-updates'],
        NULL,
        v_candidate::text
    );
    IF (v_authz->>'allowed')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'Reviewer should be able to promote account-domain facts';
    END IF;

    v_authz := authorize_agent_action(
        v_reviewer_agent,
        'rye.authoritative.promote',
        ARRAY['sec-title-diligence'],
        NULL,
        v_candidate::text
    );
    IF (v_authz->>'allowed')::boolean THEN
        RAISE EXCEPTION 'Reviewer should not be able to promote outside granted domain';
    END IF;

    v_context := agent_get_context_pack(
        v_intake_agent,
        NULL,
        'slack:#sec-sales',
        '{}'::text[]
    );

    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_context->'domains') d
        WHERE d->>'domain_key' = rye_slugify_key('sec-account-updates')
    ) THEN
        RAISE EXCEPTION 'Context pack should include subscribed shared account domain';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_context->'domains') d
        WHERE d->>'domain_key' = rye_slugify_key('sec-channel-local-ops')
    ) THEN
        RAISE EXCEPTION 'Context pack should include channel-local domain only for subscribed channel';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_context->'domains') d
        WHERE d->>'domain_key' = rye_slugify_key('sec-title-diligence')
    ) THEN
        RAISE EXCEPTION 'Context pack leaked unrelated title domain';
    END IF;

    v_context := agent_get_context_pack(
        v_intake_agent,
        NULL,
        'slack:#sec-finance',
        '{}'::text[]
    );

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_context->'domains') d
        WHERE d->>'domain_key' = rye_slugify_key('sec-channel-local-ops')
    ) THEN
        RAISE EXCEPTION 'Channel-local domain leaked to another channel';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM agent_action_log
        WHERE agent_id = v_intake_agent
          AND action = 'candidate_create'
          AND allowed = true
    ) THEN
        RAISE EXCEPTION 'Expected allowed candidate create audit row';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM agent_action_log
        WHERE agent_id = v_intake_agent
          AND action = 'candidate_create'
          AND allowed = false
    ) THEN
        RAISE EXCEPTION 'Expected denied candidate create audit row';
    END IF;
END;
$$;

ROLLBACK;
