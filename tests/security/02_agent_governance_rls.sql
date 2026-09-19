-- Governance tables: who reads, who writes.
--
-- Covers contracts/sql-surface.md "Governance tables: who reads, who writes"
-- and work item 004. Every session shape in the contract is exercised against
-- all nine tables: admin, named role, bound agent, agent-shaped but unbound,
-- and unknown/unset.
--
-- This file must run as a role RLS applies to. scripts/conformance.sh runs it
-- under RYE_TEST_ROLE (rye_conformance), which owns nothing; a superuser run
-- proves nothing because superusers bypass RLS outright.
--
-- Refusals are not uniform, so each assertion checks the right one: a refused
-- INSERT raises 42501, a refused UPDATE or DELETE raises nothing and affects
-- zero rows, and a refused SELECT returns zero rows.

SET search_path = rye, public, pg_catalog;

BEGIN;

CREATE TEMP TABLE gov_fixture (k text PRIMARY KEY, v text);

-- --------------------------------------------------------------------------
-- Setup, as admin
-- --------------------------------------------------------------------------

DO $$
DECLARE
    v_alpha uuid;
    v_beta uuid;
    v_agent_one uuid;
    v_agent_two uuid;
    v_subject uuid;
    v_manager uuid;
    v_token text;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:governance-rls', true);

    v_alpha := ensure_knowledge_domain(
        'rls_gov_area_alpha', 'RLS Governance Alpha',
        'Area an agent holds a grant on.');
    v_beta := ensure_knowledge_domain(
        'rls_gov_area_beta', 'RLS Governance Beta',
        'Area no test agent holds a grant on.');

    PERFORM subscribe_channel_to_domain('slack:#rls-gov-alpha', 'rls_gov_area_alpha', 'candidate_write', true);
    PERFORM subscribe_channel_to_domain('slack:#rls-gov-beta', 'rls_gov_area_beta', 'read', true);

    INSERT INTO domain_claim_policies (domain_id, claim_type, candidate_policy, authority_required)
    VALUES (v_alpha, 'gov_test_claim', 'candidate_until_review', true),
           (v_beta, 'gov_test_claim', 'candidate_until_review', true);

    v_agent_one := create_agent_identity('rls_gov_agent_one', 'RLS Governance Agent One', 'conformance');
    v_agent_two := create_agent_identity('rls_gov_agent_two', 'RLS Governance Agent Two', 'conformance');

    PERFORM grant_agent_capability('rls_gov_agent_one', 'rye.context.read', 'rls_gov_area_alpha');
    PERFORM grant_agent_capability('rls_gov_agent_one', 'rye.candidate.create', 'rls_gov_area_alpha');
    PERFORM grant_agent_capability('rls_gov_agent_one', 'rye.observation.create', 'rls_gov_area_alpha');
    PERFORM grant_agent_capability('rls_gov_agent_two', 'rye.context.read', 'rls_gov_area_beta');

    v_token := issue_agent_token('rls_gov_agent_one', 'governance rls test token');

    -- One log row and one idempotency row for each agent, so "own rows" has
    -- something to be wrong about.
    PERFORM record_agent_action(v_agent_one, 'gov_rls_probe', 'rye.context.read', true);
    PERFORM record_agent_action(v_agent_two, 'gov_rls_probe', 'rye.context.read', true);

    INSERT INTO api_idempotency_keys (agent_id, key, request_hash, response, expires_at)
    VALUES (v_agent_one, 'gov-rls-one', 'hash-one', '{"id":"one"}'::jsonb, now() + interval '1 hour'),
           (v_agent_two, 'gov-rls-two', 'hash-two', '{"id":"two"}'::jsonb, now() + interval '1 hour');

    -- A subject and a manager, for the settlement lookup's relationship step.
    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('person', 'RLS Gov Subject', 'test', 'rls-gov-subject')
    RETURNING id INTO v_subject;

    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('person', 'RLS Gov Manager', 'test', 'rls-gov-manager')
    RETURNING id INTO v_manager;

    INSERT INTO edges (source_id, target_id, edge_type)
    VALUES (v_subject, v_manager, 'reports_to');

    -- A grant whose only holder is an agent. It must never win a settlement.
    PERFORM grant_domain_authority(
        'rls_gov_area_alpha', 'person', 'agent:rls_gov_agent_one',
        ARRAY['gov_test_claim']);

    INSERT INTO gov_fixture (k, v) VALUES
        ('alpha', v_alpha::text),
        ('beta', v_beta::text),
        ('agent_one', v_agent_one::text),
        ('agent_two', v_agent_two::text),
        ('subject', v_subject::text),
        ('manager', v_manager::text),
        ('token', v_token);
END;
$$;

-- --------------------------------------------------------------------------
-- 1. Admin reads all nine and writes the eight that are writable
-- --------------------------------------------------------------------------

DO $$
DECLARE
    v_alpha uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'alpha');
    v_agent_one uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'agent_one');
    v_agent_two uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'agent_two');
    v_rows int;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    IF NOT EXISTS (SELECT 1 FROM knowledge_domains WHERE id = v_alpha)
       OR NOT EXISTS (SELECT 1 FROM domain_authorities WHERE domain_id = v_alpha)
       OR NOT EXISTS (SELECT 1 FROM channel_domain_subscriptions WHERE domain_id = v_alpha)
       OR NOT EXISTS (SELECT 1 FROM domain_claim_policies WHERE domain_id = v_alpha)
       OR NOT EXISTS (SELECT 1 FROM agent_identities WHERE id = v_agent_one)
       OR NOT EXISTS (SELECT 1 FROM agent_capability_grants WHERE agent_id = v_agent_one)
       OR NOT EXISTS (SELECT 1 FROM agent_action_log WHERE agent_id = v_agent_two)
       OR NOT EXISTS (SELECT 1 FROM api_idempotency_keys WHERE agent_id = v_agent_two)
       OR NOT EXISTS (SELECT 1 FROM agent_api_tokens WHERE agent_id = v_agent_one)
    THEN
        RAISE EXCEPTION 'admin cannot read one of the nine governance tables';
    END IF;

    UPDATE knowledge_domains SET purpose = purpose WHERE id = v_alpha;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'admin could not update knowledge_domains';
    END IF;

    UPDATE agent_identities SET label = label WHERE id = v_agent_two;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'admin could not update agent_identities';
    END IF;

    DELETE FROM api_idempotency_keys WHERE agent_id = v_agent_two AND key = 'gov-rls-two';
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'admin could not delete an expired idempotency row';
    END IF;

    INSERT INTO api_idempotency_keys (agent_id, key, request_hash, response, expires_at)
    VALUES (v_agent_two, 'gov-rls-two', 'hash-two', '{"id":"two"}'::jsonb, now() + interval '1 hour');
END;
$$;

-- agent_action_log is append-only for everyone, admin included.
DO $$
DECLARE
    v_agent_one uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'agent_one');
    v_rows int;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    UPDATE agent_action_log SET reason = 'tampered' WHERE agent_id = v_agent_one;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'admin updated % agent_action_log rows; the log is append-only', v_rows;
    END IF;

    DELETE FROM agent_action_log WHERE agent_id = v_agent_one;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'admin deleted % agent_action_log rows; the log is append-only', v_rows;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM agent_action_log WHERE agent_id = v_agent_one) THEN
        RAISE EXCEPTION 'the admin log row disappeared';
    END IF;
END;
$$;

-- --------------------------------------------------------------------------
-- 2. A named role reads the four area tables and the roster, nothing else
-- --------------------------------------------------------------------------

DO $$
DECLARE
    v_alpha uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'alpha');
    v_beta uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'beta');
    v_agent_one uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'agent_one');
    v_rows int;
    v_refused boolean;
BEGIN
    PERFORM set_config('app.current_role', 'team_lead', true);

    IF NOT EXISTS (SELECT 1 FROM knowledge_domains WHERE id = v_alpha)
       OR NOT EXISTS (SELECT 1 FROM knowledge_domains WHERE id = v_beta)
       OR NOT EXISTS (SELECT 1 FROM domain_authorities WHERE domain_id = v_alpha)
       OR NOT EXISTS (SELECT 1 FROM channel_domain_subscriptions WHERE domain_id = v_beta)
       OR NOT EXISTS (SELECT 1 FROM domain_claim_policies WHERE domain_id = v_beta)
       OR NOT EXISTS (SELECT 1 FROM agent_identities WHERE id = v_agent_one)
    THEN
        RAISE EXCEPTION 'a named role cannot read the area tables or the roster';
    END IF;

    IF (SELECT count(*) FROM agent_capability_grants) <> 0
       OR (SELECT count(*) FROM agent_action_log) <> 0
       OR (SELECT count(*) FROM api_idempotency_keys) <> 0
       OR (SELECT count(*) FROM agent_api_tokens) <> 0
    THEN
        RAISE EXCEPTION 'a named role read grants, log rows, idempotency rows, or tokens';
    END IF;

    UPDATE knowledge_domains SET purpose = 'tampered' WHERE id = v_alpha;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'a named role updated knowledge_domains';
    END IF;

    DELETE FROM domain_authorities WHERE domain_id = v_alpha;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'a named role deleted a domain authority';
    END IF;

    v_refused := false;
    BEGIN
        INSERT INTO knowledge_domains (domain_key, label, purpose)
        VALUES ('rls_gov_sneak_named', 'Sneak', 'Named role direct insert.');
    EXCEPTION WHEN insufficient_privilege THEN
        v_refused := true;
    END;
    PERFORM set_config('app.current_role', 'team_lead', true);
    IF NOT v_refused THEN
        RAISE EXCEPTION 'a named role inserted a knowledge domain directly';
    END IF;

    v_refused := false;
    BEGIN
        INSERT INTO agent_capability_grants (agent_id, capability)
        VALUES (v_agent_one, 'rye.authoritative.promote');
    EXCEPTION WHEN insufficient_privilege THEN
        v_refused := true;
    END;
    PERFORM set_config('app.current_role', 'team_lead', true);
    IF NOT v_refused THEN
        RAISE EXCEPTION 'a named role inserted a capability grant directly';
    END IF;
END;
$$;

-- --------------------------------------------------------------------------
-- 3. A bound agent reads the areas it holds, the roster, and its own rows
-- --------------------------------------------------------------------------

DO $$
DECLARE
    v_alpha uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'alpha');
    v_beta uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'beta');
    v_agent_one uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'agent_one');
    v_agent_two uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'agent_two');
    v_rows int;
    v_refused boolean;
BEGIN
    PERFORM set_config('app.current_role', 'agent:rls_gov_agent_one', true);

    IF rye_current_agent_key() <> 'rls_gov_agent_one' THEN
        RAISE EXCEPTION 'rye_current_agent_key did not read app.current_role';
    END IF;
    IF rye_current_agent_id() <> v_agent_one THEN
        RAISE EXCEPTION 'rye_current_agent_id did not resolve the bound agent';
    END IF;

    -- Areas it holds, and only those.
    IF NOT EXISTS (SELECT 1 FROM knowledge_domains WHERE id = v_alpha) THEN
        RAISE EXCEPTION 'a bound agent cannot read the area it holds';
    END IF;
    IF EXISTS (SELECT 1 FROM knowledge_domains WHERE id = v_beta) THEN
        RAISE EXCEPTION 'a bound agent read an area it holds no grant on';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM domain_authorities WHERE domain_id = v_alpha)
       OR NOT EXISTS (SELECT 1 FROM channel_domain_subscriptions WHERE domain_id = v_alpha)
       OR NOT EXISTS (SELECT 1 FROM domain_claim_policies WHERE domain_id = v_alpha)
    THEN
        RAISE EXCEPTION 'a bound agent cannot read the governance rows of an area it holds';
    END IF;
    IF EXISTS (SELECT 1 FROM domain_authorities WHERE domain_id = v_beta)
       OR EXISTS (SELECT 1 FROM channel_domain_subscriptions WHERE domain_id = v_beta)
       OR EXISTS (SELECT 1 FROM domain_claim_policies WHERE domain_id = v_beta)
    THEN
        RAISE EXCEPTION 'a bound agent read governance rows of an area it does not hold';
    END IF;

    -- The whole roster, including the other agent.
    IF NOT EXISTS (SELECT 1 FROM agent_identities WHERE id = v_agent_two) THEN
        RAISE EXCEPTION 'a bound agent cannot read the roster, so the settler deny-list fails open';
    END IF;

    -- Own rows only.
    IF NOT EXISTS (SELECT 1 FROM agent_capability_grants WHERE agent_id = v_agent_one) THEN
        RAISE EXCEPTION 'a bound agent cannot read its own grants';
    END IF;
    IF EXISTS (SELECT 1 FROM agent_capability_grants WHERE agent_id = v_agent_two) THEN
        RAISE EXCEPTION 'a bound agent read another agent''s capability grants';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM agent_action_log WHERE agent_id = v_agent_one) THEN
        RAISE EXCEPTION 'a bound agent cannot read its own action log rows';
    END IF;
    IF EXISTS (SELECT 1 FROM agent_action_log WHERE agent_id = v_agent_two) THEN
        RAISE EXCEPTION 'a bound agent read another agent''s action log rows';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM api_idempotency_keys WHERE agent_id = v_agent_one) THEN
        RAISE EXCEPTION 'a bound agent cannot read its own idempotency rows';
    END IF;
    IF EXISTS (SELECT 1 FROM api_idempotency_keys WHERE agent_id = v_agent_two) THEN
        RAISE EXCEPTION 'a bound agent read another agent''s idempotency rows';
    END IF;

    -- Never a token.
    IF (SELECT count(*) FROM agent_api_tokens) <> 0 THEN
        RAISE EXCEPTION 'a bound agent read a token row';
    END IF;

    -- No writes anywhere.
    UPDATE agent_capability_grants SET capability = 'rye.admin.manage' WHERE agent_id = v_agent_one;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'a bound agent updated its own capability grant';
    END IF;

    DELETE FROM agent_action_log WHERE agent_id = v_agent_one;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'a bound agent deleted its own action log rows';
    END IF;

    DELETE FROM knowledge_domains WHERE id = v_alpha;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'a bound agent deleted an area';
    END IF;

    v_refused := false;
    BEGIN
        INSERT INTO agent_capability_grants (agent_id, capability)
        VALUES (v_agent_one, 'rye.authoritative.promote');
    EXCEPTION WHEN insufficient_privilege THEN
        v_refused := true;
    END;
    PERFORM set_config('app.current_role', 'agent:rls_gov_agent_one', true);
    IF NOT v_refused THEN
        RAISE EXCEPTION 'a bound agent granted itself a capability directly';
    END IF;

    v_refused := false;
    BEGIN
        INSERT INTO agent_identities (agent_key, label, runtime)
        VALUES ('rls_gov_sneak_agent', 'Sneak', 'conformance');
    EXCEPTION WHEN insufficient_privilege THEN
        v_refused := true;
    END;
    PERFORM set_config('app.current_role', 'agent:rls_gov_agent_one', true);
    IF NOT v_refused THEN
        RAISE EXCEPTION 'a bound agent created an identity directly';
    END IF;

    v_refused := false;
    BEGIN
        INSERT INTO domain_authorities (domain_id, authority_kind, authority_ref)
        VALUES (v_alpha, 'person', 'agent:rls_gov_agent_one');
    EXCEPTION WHEN insufficient_privilege THEN
        v_refused := true;
    END;
    PERFORM set_config('app.current_role', 'agent:rls_gov_agent_one', true);
    IF NOT v_refused THEN
        RAISE EXCEPTION 'a bound agent gave itself authority directly';
    END IF;
END;
$$;

-- --------------------------------------------------------------------------
-- 4. Agent-shaped but unbound reads the roster and nothing else
-- --------------------------------------------------------------------------

DO $$
DECLARE
    v_agent_one uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'agent_one');
BEGIN
    PERFORM set_config('app.current_role', 'agent:no_such_agent_key', true);

    IF rye_current_agent_key() <> 'no_such_agent_key' THEN
        RAISE EXCEPTION 'an agent-shaped session did not report its key';
    END IF;
    IF rye_current_agent_id() IS NOT NULL THEN
        RAISE EXCEPTION 'an unbound agent-shaped session resolved to an identity';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM agent_identities WHERE id = v_agent_one) THEN
        RAISE EXCEPTION 'an agent-shaped session cannot read the roster';
    END IF;

    IF (SELECT count(*) FROM knowledge_domains) <> 0
       OR (SELECT count(*) FROM domain_authorities) <> 0
       OR (SELECT count(*) FROM channel_domain_subscriptions) <> 0
       OR (SELECT count(*) FROM domain_claim_policies) <> 0
       OR (SELECT count(*) FROM agent_capability_grants) <> 0
       OR (SELECT count(*) FROM agent_action_log) <> 0
       OR (SELECT count(*) FROM api_idempotency_keys) <> 0
       OR (SELECT count(*) FROM agent_api_tokens) <> 0
    THEN
        RAISE EXCEPTION 'an agent-shaped but unbound session read more than the roster';
    END IF;

    -- The stored slug is the key. agent:rls-gov-agent-one is agent-shaped and
    -- is not the bound agent rls_gov_agent_one.
    PERFORM set_config('app.current_role', 'agent:rls-gov-agent-one', true);
    IF rye_current_agent_id() IS NOT NULL THEN
        RAISE EXCEPTION 'a hyphenated key resolved to a stored slug';
    END IF;
END;
$$;

-- --------------------------------------------------------------------------
-- 5. Unknown and unset read zero rows from all nine
-- --------------------------------------------------------------------------

DO $$
DECLARE
    v_alpha uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'alpha');
    v_shape text;
    v_total bigint;
    v_rows int;
    v_refused boolean;
BEGIN
    FOREACH v_shape IN ARRAY ARRAY['not_a_role_name', ''] LOOP
        PERFORM set_config('app.current_role', v_shape, true);

        SELECT (SELECT count(*) FROM knowledge_domains)
             + (SELECT count(*) FROM domain_authorities)
             + (SELECT count(*) FROM channel_domain_subscriptions)
             + (SELECT count(*) FROM domain_claim_policies)
             + (SELECT count(*) FROM agent_identities)
             + (SELECT count(*) FROM agent_capability_grants)
             + (SELECT count(*) FROM agent_action_log)
             + (SELECT count(*) FROM api_idempotency_keys)
             + (SELECT count(*) FROM agent_api_tokens)
        INTO v_total;

        IF v_total <> 0 THEN
            RAISE EXCEPTION 'session shape % read % governance rows; it must read none',
                coalesce(nullif(v_shape, ''), '<unset>'), v_total;
        END IF;

        UPDATE knowledge_domains SET purpose = 'tampered' WHERE id = v_alpha;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'session shape % updated an area', v_shape;
        END IF;

        v_refused := false;
        BEGIN
            INSERT INTO agent_action_log (agent_id, action, allowed)
            VALUES (NULL, 'gov_rls_forged', true);
        EXCEPTION WHEN insufficient_privilege THEN
            v_refused := true;
        END;
        PERFORM set_config('app.current_role', v_shape, true);
        IF NOT v_refused THEN
            RAISE EXCEPTION 'session shape % forged an action log row without the gate', v_shape;
        END IF;
    END LOOP;
END;
$$;

-- --------------------------------------------------------------------------
-- 6. The five write helpers refuse every non-admin
-- --------------------------------------------------------------------------

DO $$
DECLARE
    v_shape text;
    v_refused boolean;
    v_state text;
BEGIN
    FOREACH v_shape IN ARRAY ARRAY['team_lead', 'agent:rls_gov_agent_one', 'agent:no_such_agent_key', 'viewer', ''] LOOP

        -- ensure_knowledge_domain
        PERFORM set_config('app.current_role', v_shape, true);
        v_refused := false;
        BEGIN
            PERFORM ensure_knowledge_domain('rls_gov_self_serve', 'Self Serve', 'Escalation attempt.');
        EXCEPTION WHEN OTHERS THEN
            v_refused := true;
            v_state := SQLSTATE;
        END;
        PERFORM set_config('app.current_role', v_shape, true);
        IF NOT v_refused THEN
            RAISE EXCEPTION 'shape % created a knowledge domain', v_shape;
        END IF;

        -- subscribe_channel_to_domain
        v_refused := false;
        BEGIN
            PERFORM subscribe_channel_to_domain('slack:#rls-gov-escalate', 'rls_gov_area_alpha', 'admin', true);
        EXCEPTION WHEN OTHERS THEN
            v_refused := true;
        END;
        PERFORM set_config('app.current_role', v_shape, true);
        IF NOT v_refused THEN
            RAISE EXCEPTION 'shape % subscribed a channel to an area', v_shape;
        END IF;

        -- grant_domain_authority
        v_refused := false;
        BEGIN
            PERFORM grant_domain_authority('rls_gov_area_alpha', 'person', 'person:escalating-caller');
        EXCEPTION WHEN OTHERS THEN
            v_refused := true;
        END;
        PERFORM set_config('app.current_role', v_shape, true);
        IF NOT v_refused THEN
            RAISE EXCEPTION 'shape % gave itself authority over an area', v_shape;
        END IF;

        -- create_agent_identity
        v_refused := false;
        BEGIN
            PERFORM create_agent_identity('rls_gov_self_agent', 'Self Agent', 'conformance');
        EXCEPTION WHEN OTHERS THEN
            v_refused := true;
        END;
        PERFORM set_config('app.current_role', v_shape, true);
        IF NOT v_refused THEN
            RAISE EXCEPTION 'shape % created an agent identity', v_shape;
        END IF;

        -- grant_agent_capability
        v_refused := false;
        BEGIN
            PERFORM grant_agent_capability('rls_gov_agent_one', 'rye.authoritative.promote', 'rls_gov_area_alpha');
        EXCEPTION WHEN OTHERS THEN
            v_refused := true;
        END;
        PERFORM set_config('app.current_role', v_shape, true);
        IF NOT v_refused THEN
            RAISE EXCEPTION 'shape % granted a capability', v_shape;
        END IF;
    END LOOP;

    -- Nothing leaked through.
    PERFORM set_config('app.current_role', 'admin', true);
    IF EXISTS (SELECT 1 FROM knowledge_domains WHERE domain_key = 'rls_gov_self_serve')
       OR EXISTS (SELECT 1 FROM agent_identities WHERE agent_key = 'rls_gov_self_agent')
       OR EXISTS (SELECT 1 FROM domain_authorities WHERE authority_ref = 'person:escalating-caller')
       OR EXISTS (SELECT 1 FROM channel_domain_subscriptions WHERE channel_ref = 'slack:#rls-gov-escalate')
       OR EXISTS (SELECT 1 FROM agent_capability_grants WHERE capability = 'rye.authoritative.promote')
    THEN
        RAISE EXCEPTION 'a non-admin escalation attempt left a row behind';
    END IF;
END;
$$;

-- --------------------------------------------------------------------------
-- 7. The two named gates, and only those two
-- --------------------------------------------------------------------------

DO $$
DECLARE
    v_agent_one uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'agent_one');
    v_refused boolean;
BEGIN
    PERFORM set_config('app.current_role', 'agent:rls_gov_agent_one', true);
    PERFORM set_config('app.write_path', '', true);

    v_refused := false;
    BEGIN
        INSERT INTO api_idempotency_keys (agent_id, key, request_hash, response)
        VALUES (v_agent_one, 'gov-rls-ungated', 'hash', '{"id":"x"}'::jsonb);
    EXCEPTION WHEN insufficient_privilege THEN
        v_refused := true;
    END;
    PERFORM set_config('app.current_role', 'agent:rls_gov_agent_one', true);
    IF NOT v_refused THEN
        RAISE EXCEPTION 'an idempotency row was written without the agent_create_candidate gate';
    END IF;

    -- The wrong gate is no gate.
    PERFORM set_config('app.write_path', 'record_agent_action', true);
    v_refused := false;
    BEGIN
        INSERT INTO api_idempotency_keys (agent_id, key, request_hash, response)
        VALUES (v_agent_one, 'gov-rls-wrong-gate', 'hash', '{"id":"x"}'::jsonb);
    EXCEPTION WHEN insufficient_privilege THEN
        v_refused := true;
    END;
    PERFORM set_config('app.current_role', 'agent:rls_gov_agent_one', true);
    PERFORM set_config('app.write_path', '', true);
    IF NOT v_refused THEN
        RAISE EXCEPTION 'the record_agent_action gate admitted an idempotency row';
    END IF;

    -- record_agent_action opens its own gate, so a denial is logged even from a
    -- session that could not write the log directly.
    PERFORM record_agent_action(v_agent_one, 'gov_rls_denial', 'rye.context.read', false);
    IF coalesce(current_setting('app.write_path', true), '') <> '' THEN
        RAISE EXCEPTION 'record_agent_action left app.write_path set to %',
            current_setting('app.write_path', true);
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    IF NOT EXISTS (
        SELECT 1 FROM agent_action_log
        WHERE agent_id = v_agent_one AND action = 'gov_rls_denial' AND allowed = false
    ) THEN
        RAISE EXCEPTION 'record_agent_action did not record the denial';
    END IF;
END;
$$;

-- --------------------------------------------------------------------------
-- 8. The agent functions answer as before for a valid agent
-- --------------------------------------------------------------------------

DO $$
DECLARE
    v_agent_one uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'agent_one');
    v_agent_two uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'agent_two');
    v_token text := (SELECT v FROM gov_fixture WHERE k = 'token');
    v_auth jsonb;
    v_authz jsonb;
    v_context jsonb;
    v_observation uuid;
    v_candidate uuid;
    v_retry uuid;
    v_denied boolean;
BEGIN
    -- Exchanging a token is the trusted layer's job, and agent_api_tokens is
    -- admin-only, so authentication is checked from an admin session.
    PERFORM set_config('app.current_role', 'admin', true);
    v_auth := authenticate_agent_token(v_token);
    IF v_auth IS NULL OR v_auth->>'agent_key' <> 'rls_gov_agent_one' THEN
        RAISE EXCEPTION 'token authentication no longer returns the agent: %', v_auth;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_auth->'capabilities') c
        WHERE c->>'capability' = 'rye.context.read'
          AND c->>'domain_key' = 'rls_gov_area_alpha'
    ) THEN
        RAISE EXCEPTION 'token authentication lost the agent capabilities: %', v_auth;
    END IF;

    PERFORM set_config('app.current_role', 'agent:rls_gov_agent_one', true);
    PERFORM set_config('app.current_user_id', 'rls_gov_agent_one', true);

    IF NOT has_agent_capability(v_agent_one, 'rye.context.read', ARRAY['rls_gov_area_alpha']) THEN
        RAISE EXCEPTION 'has_agent_capability denied a capability the agent holds';
    END IF;
    IF has_agent_capability(v_agent_one, 'rye.context.read', ARRAY['rls_gov_area_beta']) THEN
        RAISE EXCEPTION 'has_agent_capability allowed an area the agent does not hold';
    END IF;

    v_authz := authorize_agent_action(v_agent_one, 'rye.candidate.create', ARRAY['rls_gov_area_alpha']);
    IF (v_authz->>'allowed')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'authorize_agent_action denied a held capability: %', v_authz;
    END IF;
    v_authz := authorize_agent_action(v_agent_one, 'rye.authoritative.promote', ARRAY['rls_gov_area_alpha']);
    IF (v_authz->>'allowed')::boolean THEN
        RAISE EXCEPTION 'authorize_agent_action allowed a capability the agent does not hold';
    END IF;

    v_context := agent_get_context_pack(v_agent_one, NULL, 'slack:#rls-gov-alpha', '{}'::text[]);
    IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_context->'domains') d
        WHERE d->>'domain_key' = 'rls_gov_area_alpha'
    ) THEN
        RAISE EXCEPTION 'the context pack lost the area the agent holds: %', v_context;
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_context->'domains') d
        WHERE d->>'domain_key' = 'rls_gov_area_beta'
    ) THEN
        RAISE EXCEPTION 'the context pack leaked an area the agent does not hold';
    END IF;

    v_observation := agent_submit_observation(
        v_agent_one,
        'Governance RLS observation.',
        ARRAY['rls_gov_area_alpha'],
        'slack:#rls-gov-alpha');
    IF v_observation IS NULL THEN
        RAISE EXCEPTION 'agent_submit_observation returned nothing';
    END IF;

    v_candidate := agent_create_candidate(
        p_agent_id       := v_agent_one,
        p_candidate_kind := 'decision',
        p_statement      := 'Governance RLS candidate.',
        p_domain_keys    := ARRAY['rls_gov_area_alpha'],
        p_source_scope   := 'slack:#rls-gov-alpha',
        p_evidence_refs  := '[{"source":"test","id":"gov-rls-1"}]'::jsonb,
        p_idempotency_key := 'gov-rls-idem-1');
    IF v_candidate IS NULL THEN
        RAISE EXCEPTION 'agent_create_candidate returned nothing';
    END IF;

    v_retry := agent_create_candidate(
        p_agent_id       := v_agent_one,
        p_candidate_kind := 'decision',
        p_statement      := 'Governance RLS candidate.',
        p_domain_keys    := ARRAY['rls_gov_area_alpha'],
        p_source_scope   := 'slack:#rls-gov-alpha',
        p_evidence_refs  := '[{"source":"test","id":"gov-rls-1"}]'::jsonb,
        p_idempotency_key := 'gov-rls-idem-1');
    IF v_retry IS DISTINCT FROM v_candidate THEN
        RAISE EXCEPTION 'the idempotent retry created a second candidate: % then %', v_candidate, v_retry;
    END IF;

    -- An area the agent does not hold is still refused. The denial row that
    -- record_agent_action writes first is rolled back with the RAISE, because
    -- catching the exception here aborts the subtransaction; section 7 is where
    -- the gate itself is checked.
    v_denied := false;
    BEGIN
        PERFORM agent_create_candidate(
            p_agent_id       := v_agent_one,
            p_candidate_kind := 'decision',
            p_statement      := 'Governance RLS candidate in an unheld area.',
            p_domain_keys    := ARRAY['rls_gov_area_beta'],
            p_source_scope   := 'slack:#rls-gov-beta');
    EXCEPTION WHEN insufficient_privilege THEN
        v_denied := true;
    END;
    PERFORM set_config('app.current_role', 'agent:rls_gov_agent_one', true);
    IF NOT v_denied THEN
        RAISE EXCEPTION 'an agent created a candidate in an area it does not hold';
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    IF NOT EXISTS (
        SELECT 1 FROM agent_action_log
        WHERE agent_id = v_agent_one AND action = 'candidate_create' AND allowed = true
    ) THEN
        RAISE EXCEPTION 'the allowed candidate create was not logged';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM api_idempotency_keys
        WHERE agent_id = v_agent_one AND key = 'gov-rls-idem-1'
    ) THEN
        RAISE EXCEPTION 'agent_create_candidate did not store its idempotency row';
    END IF;

    -- Whether has_agent_capability() answers about another agent's id depends
    -- on whether the function owner is a superuser, so it is not asserted here.
    -- What is asserted, in section 3 and by direct SQL, is that this session
    -- cannot read agent two's grants. That is the rule RLS owns.
    PERFORM set_config('app.current_role', 'agent:rls_gov_agent_one', true);
    IF EXISTS (SELECT 1 FROM agent_capability_grants WHERE agent_id = v_agent_two) THEN
        RAISE EXCEPTION 'an agent read another agent''s capability grants';
    END IF;
END;
$$;

-- --------------------------------------------------------------------------
-- 9. rye_settlers() never returns an agent, under any session shape
-- --------------------------------------------------------------------------

DO $$
DECLARE
    v_subject uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'subject');
    v_manager uuid := (SELECT v::uuid FROM gov_fixture WHERE k = 'manager');
    v_shape text;
    v_answer jsonb;
BEGIN
    FOREACH v_shape IN ARRAY ARRAY['admin', 'team_lead', 'agent:rls_gov_agent_one',
                                   'agent:no_such_agent_key', 'not_a_role_name', ''] LOOP
        PERFORM set_config('app.current_role', v_shape, true);

        v_answer := rye_settlers(
            p_subject_id  := v_subject,
            p_claim_type  := 'gov_test_claim',
            p_domain_key  := 'rls_gov_area_alpha',
            p_speech_act  := 'expectation');

        IF EXISTS (
            SELECT 1 FROM jsonb_array_elements(v_answer->'settlers') s
            WHERE s->>'ref' = 'agent:rls_gov_agent_one'
               OR s->>'ref' = 'rls_gov_agent_one'
        ) THEN
            RAISE EXCEPTION 'shape % got an agent as a settler: %', v_shape, v_answer;
        END IF;

        IF (v_answer->>'contract_version')::int <> 1 THEN
            RAISE EXCEPTION 'shape % got contract_version %', v_shape, v_answer->>'contract_version';
        END IF;
    END LOOP;

    -- Admin and a named role see the same answer: the agent grant is dropped
    -- and the lookup falls through to the manager.
    FOREACH v_shape IN ARRAY ARRAY['admin', 'team_lead'] LOOP
        PERFORM set_config('app.current_role', v_shape, true);
        v_answer := rye_settlers(
            p_subject_id  := v_subject,
            p_claim_type  := 'gov_test_claim',
            p_domain_key  := 'rls_gov_area_alpha',
            p_speech_act  := 'expectation');

        IF v_answer->>'step' <> 'relationship' THEN
            RAISE EXCEPTION 'shape % did not fall through the agent-only grant: %', v_shape, v_answer;
        END IF;
        IF (v_answer->>'excluded_agents')::int < 1 THEN
            RAISE EXCEPTION 'shape % did not count the excluded agent: %', v_shape, v_answer;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(v_answer->'settlers') s
            WHERE (s->>'node_id')::uuid = v_manager
        ) THEN
            RAISE EXCEPTION 'shape % lost the manager default: %', v_shape, v_answer;
        END IF;
    END LOOP;

    -- An area a caller cannot see is indistinguishable from one that does not
    -- exist, and it stops the lookup before the relationship step.
    PERFORM set_config('app.current_role', 'agent:rls_gov_agent_one', true);
    v_answer := rye_settlers(
        p_subject_id  := v_subject,
        p_claim_type  := 'gov_test_claim',
        p_domain_key  := 'rls_gov_area_beta',
        p_speech_act  := 'expectation');
    IF v_answer->>'reason' <> 'domain_not_found'
       OR v_answer->>'step' <> 'none'
       OR jsonb_array_length(v_answer->'settlers') <> 0
    THEN
        RAISE EXCEPTION 'an area the agent does not hold was not reported as domain_not_found: %', v_answer;
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    v_answer := rye_settlers(
        p_subject_id  := v_subject,
        p_claim_type  := 'gov_test_claim',
        p_domain_key  := 'no_such_area_at_all',
        p_speech_act  := 'expectation');
    IF v_answer->>'reason' <> 'domain_not_found' OR (v_answer->>'setup_gap')::boolean THEN
        RAISE EXCEPTION 'an unknown area key changed its answer: %', v_answer;
    END IF;
END;
$$;

ROLLBACK;
