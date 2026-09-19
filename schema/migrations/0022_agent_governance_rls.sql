-- Row-level security for the nine governance tables.
--
-- Implements "Governance tables: who reads, who writes" in
-- contracts/sql-surface.md and docs/decisions/0007-agent-governance-visibility.md.
--
-- Migration 0016 created eight tables with no RLS at all and enabled (but did
-- not force) it on agent_api_tokens. Any session with direct SQL could read
-- every authority grant, agent identity, capability grant, and audit row, and
-- could call the five write helpers, which carry no role check of their own.
--
-- The fix is policies, not function bodies. `app.current_role` decides, and
-- nothing else does. The five write helpers keep their signatures and stay
-- SECURITY INVOKER; the admin-only write policy on the table each one writes is
-- what refuses a non-admin, so there is one rule in one place.
--
-- The tables are ordered so no policy reads its own table, directly or through
-- a function. A policy that subqueries its own table raises "infinite recursion
-- detected in policy for relation"; one that calls a function reading its own
-- table recurses to "stack depth limit exceeded", SECURITY DEFINER included.
--
--   level 0  role_classification_access            reads nothing
--   level 1  agent_identities                      reads level 0 + session vars
--   level 2  agent_capability_grants, agent_action_log,
--            api_idempotency_keys, agent_api_tokens  reads levels 0-1
--   level 3  knowledge_domains, domain_authorities,
--            channel_domain_subscriptions, domain_claim_policies
--                                                  reads levels 0-2
--
-- A policy reads only levels strictly below its own, so the chain
-- area -> grants -> identities -> roles terminates for every session shape.
--
-- Under FORCE ROW LEVEL SECURITY with an owner that is not a superuser
-- (Supabase), a SECURITY DEFINER function is still subject to every policy,
-- evaluated with the caller's session variables. So no function here is made
-- DEFINER to buy visibility. The agent functions keep working by the two
-- mechanisms the schema already uses: the rows they read are readable to the
-- session that calls them, and the two writes they make on a non-admin's behalf
-- are admitted by the named `app.write_path` gate.

SET search_path = rye, pg_catalog, public;

-- --------------------------------------------------------------------------
-- Session shape: the two published helpers
-- --------------------------------------------------------------------------

-- Agent-shaped: `app.current_role` has the form `agent:<key>`. Decided from the
-- session variable alone, so it is safe inside agent_identities' own policy.
CREATE OR REPLACE FUNCTION rye_current_agent_key()
RETURNS text
SET search_path = rye, pg_catalog
AS $$
    SELECT CASE
        WHEN current_setting('app.current_role', true) LIKE 'agent:%'
        THEN nullif(substr(current_setting('app.current_role', true), 7), '')
        ELSE NULL
    END;
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION rye_current_agent_key() IS
    'The part after `agent:` when app.current_role has that form, else NULL. Reads no table, so it is safe in any policy including agent_identities''. Agent-shaped is rye_current_agent_key() IS NOT NULL.';

-- Bound agent: that key names an active agent_identities row. Reads the roster
-- under the roster's own rule, so it is usable only in policies on tables below
-- agent_identities in the order above. Deliberately not SECURITY DEFINER: it
-- returns NULL rather than a bypass when the caller cannot read the roster.
CREATE OR REPLACE FUNCTION rye_current_agent_id()
RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
    SELECT ai.id
    FROM agent_identities ai
    WHERE ai.active = true
      AND ai.agent_key = rye_current_agent_key()
    LIMIT 1;
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION rye_current_agent_id() IS
    'The agent_identities.id of the active row whose agent_key matches rye_current_agent_key(), else NULL. Bound agent is rye_current_agent_id() IS NOT NULL. Own rows everywhere means agent_id = rye_current_agent_id().';

-- --------------------------------------------------------------------------
-- Level 1: agent_identities
-- --------------------------------------------------------------------------
-- The roster carries no secret (tokens live in agent_api_tokens, permissions in
-- agent_capability_grants) and it is the deny-list for "an agent is never a
-- settler". A deny-list some callers cannot read is a deny-list that fails
-- open, so its read set is a superset of the read set of every area table.

ALTER TABLE agent_identities ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_identities FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS agent_identities_read_policy ON agent_identities;
CREATE POLICY agent_identities_read_policy ON agent_identities
    FOR SELECT
    USING (
        current_setting('app.current_role', true) = 'admin'
        OR EXISTS (
            SELECT 1 FROM role_classification_access rca
            WHERE rca.role_name = current_setting('app.current_role', true)
        )
        OR rye_current_agent_key() IS NOT NULL
    );

DROP POLICY IF EXISTS agent_identities_insert_policy ON agent_identities;
CREATE POLICY agent_identities_insert_policy ON agent_identities
    FOR INSERT
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS agent_identities_update_policy ON agent_identities;
CREATE POLICY agent_identities_update_policy ON agent_identities
    FOR UPDATE
    USING (current_setting('app.current_role', true) = 'admin')
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS agent_identities_delete_policy ON agent_identities;
CREATE POLICY agent_identities_delete_policy ON agent_identities
    FOR DELETE
    USING (current_setting('app.current_role', true) = 'admin');

-- --------------------------------------------------------------------------
-- Level 2: capability grants, tokens, action log, idempotency keys
-- --------------------------------------------------------------------------
-- These are the instance's security configuration and its audit trail. A
-- team_lead has no more business reading which capabilities an agent holds than
-- reading an access_grant it is not party to. An agent reads its own rows so it
-- can see what it may do and what it did, and no other agent's.

ALTER TABLE agent_capability_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_capability_grants FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS agent_capability_grants_read_policy ON agent_capability_grants;
CREATE POLICY agent_capability_grants_read_policy ON agent_capability_grants
    FOR SELECT
    USING (
        current_setting('app.current_role', true) = 'admin'
        OR agent_capability_grants.agent_id = rye_current_agent_id()
    );

DROP POLICY IF EXISTS agent_capability_grants_insert_policy ON agent_capability_grants;
CREATE POLICY agent_capability_grants_insert_policy ON agent_capability_grants
    FOR INSERT
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS agent_capability_grants_update_policy ON agent_capability_grants;
CREATE POLICY agent_capability_grants_update_policy ON agent_capability_grants
    FOR UPDATE
    USING (current_setting('app.current_role', true) = 'admin')
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS agent_capability_grants_delete_policy ON agent_capability_grants;
CREATE POLICY agent_capability_grants_delete_policy ON agent_capability_grants
    FOR DELETE
    USING (current_setting('app.current_role', true) = 'admin');

-- agent_api_tokens had RLS enabled in 0016 but never forced, so the owner was
-- exempt. The two policies from 0016 keep their names and their rules.
ALTER TABLE agent_api_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_api_tokens FORCE ROW LEVEL SECURITY;

-- agent_action_log is append-only for everyone, admin included, exactly as
-- events and assertion_evidence are treated. There is no UPDATE or DELETE
-- policy: an admin able to edit the log could erase the record of its own
-- grants, and the one thing this table exists for is to be unforgeable after
-- the fact. The insert is admitted from any session through the named gate, so
-- a denial is recorded even when the caller was impersonating another agent.
-- An audit trail the audited action can suppress is not one.
ALTER TABLE agent_action_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_action_log FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS agent_action_log_read_policy ON agent_action_log;
CREATE POLICY agent_action_log_read_policy ON agent_action_log
    FOR SELECT
    USING (
        current_setting('app.current_role', true) = 'admin'
        OR agent_action_log.agent_id = rye_current_agent_id()
    );

DROP POLICY IF EXISTS agent_action_log_insert_policy ON agent_action_log;
CREATE POLICY agent_action_log_insert_policy ON agent_action_log
    FOR INSERT
    WITH CHECK (
        current_setting('app.current_role', true) = 'admin'
        OR current_setting('app.write_path', true) = 'record_agent_action'
    );

-- api_idempotency_keys is a cache with an expiry, not a record, so admin may
-- delete from it. An agent reads its own rows because agent_create_candidate()
-- must find its own prior response; if it could not, a retried call would
-- silently create a second candidate instead of returning the first.
ALTER TABLE api_idempotency_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE api_idempotency_keys FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS api_idempotency_keys_read_policy ON api_idempotency_keys;
CREATE POLICY api_idempotency_keys_read_policy ON api_idempotency_keys
    FOR SELECT
    USING (
        current_setting('app.current_role', true) = 'admin'
        OR api_idempotency_keys.agent_id = rye_current_agent_id()
    );

DROP POLICY IF EXISTS api_idempotency_keys_insert_policy ON api_idempotency_keys;
CREATE POLICY api_idempotency_keys_insert_policy ON api_idempotency_keys
    FOR INSERT
    WITH CHECK (
        current_setting('app.current_role', true) = 'admin'
        OR current_setting('app.write_path', true) = 'agent_create_candidate'
    );

DROP POLICY IF EXISTS api_idempotency_keys_delete_policy ON api_idempotency_keys;
CREATE POLICY api_idempotency_keys_delete_policy ON api_idempotency_keys
    FOR DELETE
    USING (current_setting('app.current_role', true) = 'admin');

-- --------------------------------------------------------------------------
-- Level 3: the four area tables
-- --------------------------------------------------------------------------
-- An agent holds an area when it has an active, unexpired grant whose domain_id
-- is that area or null. A null domain_id is instance-wide and holds every area,
-- which is what has_agent_capability() already means by it. The capability name
-- is not part of the rule: any grant holds the area for reading that area's
-- governance rows. That is deliberately wider than the capability filter the
-- agent functions apply to their own answers, so RLS never subtracts from what
-- agent_get_context_pack() would have returned.
--
-- No level-3 policy reads another level-3 table, so the four are independent.

ALTER TABLE knowledge_domains ENABLE ROW LEVEL SECURITY;
ALTER TABLE knowledge_domains FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS knowledge_domains_read_policy ON knowledge_domains;
CREATE POLICY knowledge_domains_read_policy ON knowledge_domains
    FOR SELECT
    USING (
        current_setting('app.current_role', true) = 'admin'
        OR EXISTS (
            SELECT 1 FROM role_classification_access rca
            WHERE rca.role_name = current_setting('app.current_role', true)
        )
        OR EXISTS (
            SELECT 1
            FROM agent_capability_grants g
            WHERE g.agent_id = rye_current_agent_id()
              AND g.active = true
              AND (g.expires_at IS NULL OR g.expires_at > now())
              AND (g.domain_id IS NULL OR g.domain_id = knowledge_domains.id)
        )
    );

DROP POLICY IF EXISTS knowledge_domains_insert_policy ON knowledge_domains;
CREATE POLICY knowledge_domains_insert_policy ON knowledge_domains
    FOR INSERT
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS knowledge_domains_update_policy ON knowledge_domains;
CREATE POLICY knowledge_domains_update_policy ON knowledge_domains
    FOR UPDATE
    USING (current_setting('app.current_role', true) = 'admin')
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS knowledge_domains_delete_policy ON knowledge_domains;
CREATE POLICY knowledge_domains_delete_policy ON knowledge_domains
    FOR DELETE
    USING (current_setting('app.current_role', true) = 'admin');

ALTER TABLE domain_authorities ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain_authorities FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS domain_authorities_read_policy ON domain_authorities;
CREATE POLICY domain_authorities_read_policy ON domain_authorities
    FOR SELECT
    USING (
        current_setting('app.current_role', true) = 'admin'
        OR EXISTS (
            SELECT 1 FROM role_classification_access rca
            WHERE rca.role_name = current_setting('app.current_role', true)
        )
        OR EXISTS (
            SELECT 1
            FROM agent_capability_grants g
            WHERE g.agent_id = rye_current_agent_id()
              AND g.active = true
              AND (g.expires_at IS NULL OR g.expires_at > now())
              AND (g.domain_id IS NULL OR g.domain_id = domain_authorities.domain_id)
        )
    );

DROP POLICY IF EXISTS domain_authorities_insert_policy ON domain_authorities;
CREATE POLICY domain_authorities_insert_policy ON domain_authorities
    FOR INSERT
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS domain_authorities_update_policy ON domain_authorities;
CREATE POLICY domain_authorities_update_policy ON domain_authorities
    FOR UPDATE
    USING (current_setting('app.current_role', true) = 'admin')
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS domain_authorities_delete_policy ON domain_authorities;
CREATE POLICY domain_authorities_delete_policy ON domain_authorities
    FOR DELETE
    USING (current_setting('app.current_role', true) = 'admin');

ALTER TABLE channel_domain_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE channel_domain_subscriptions FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS channel_domain_subscriptions_read_policy ON channel_domain_subscriptions;
CREATE POLICY channel_domain_subscriptions_read_policy ON channel_domain_subscriptions
    FOR SELECT
    USING (
        current_setting('app.current_role', true) = 'admin'
        OR EXISTS (
            SELECT 1 FROM role_classification_access rca
            WHERE rca.role_name = current_setting('app.current_role', true)
        )
        OR EXISTS (
            SELECT 1
            FROM agent_capability_grants g
            WHERE g.agent_id = rye_current_agent_id()
              AND g.active = true
              AND (g.expires_at IS NULL OR g.expires_at > now())
              AND (g.domain_id IS NULL OR g.domain_id = channel_domain_subscriptions.domain_id)
        )
    );

DROP POLICY IF EXISTS channel_domain_subscriptions_insert_policy ON channel_domain_subscriptions;
CREATE POLICY channel_domain_subscriptions_insert_policy ON channel_domain_subscriptions
    FOR INSERT
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS channel_domain_subscriptions_update_policy ON channel_domain_subscriptions;
CREATE POLICY channel_domain_subscriptions_update_policy ON channel_domain_subscriptions
    FOR UPDATE
    USING (current_setting('app.current_role', true) = 'admin')
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS channel_domain_subscriptions_delete_policy ON channel_domain_subscriptions;
CREATE POLICY channel_domain_subscriptions_delete_policy ON channel_domain_subscriptions
    FOR DELETE
    USING (current_setting('app.current_role', true) = 'admin');

ALTER TABLE domain_claim_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain_claim_policies FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS domain_claim_policies_read_policy ON domain_claim_policies;
CREATE POLICY domain_claim_policies_read_policy ON domain_claim_policies
    FOR SELECT
    USING (
        current_setting('app.current_role', true) = 'admin'
        OR EXISTS (
            SELECT 1 FROM role_classification_access rca
            WHERE rca.role_name = current_setting('app.current_role', true)
        )
        OR EXISTS (
            SELECT 1
            FROM agent_capability_grants g
            WHERE g.agent_id = rye_current_agent_id()
              AND g.active = true
              AND (g.expires_at IS NULL OR g.expires_at > now())
              AND (g.domain_id IS NULL OR g.domain_id = domain_claim_policies.domain_id)
        )
    );

DROP POLICY IF EXISTS domain_claim_policies_insert_policy ON domain_claim_policies;
CREATE POLICY domain_claim_policies_insert_policy ON domain_claim_policies
    FOR INSERT
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS domain_claim_policies_update_policy ON domain_claim_policies;
CREATE POLICY domain_claim_policies_update_policy ON domain_claim_policies
    FOR UPDATE
    USING (current_setting('app.current_role', true) = 'admin')
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS domain_claim_policies_delete_policy ON domain_claim_policies;
CREATE POLICY domain_claim_policies_delete_policy ON domain_claim_policies
    FOR DELETE
    USING (current_setting('app.current_role', true) = 'admin');

-- --------------------------------------------------------------------------
-- The two writes made on behalf of a caller who is not an admin
-- --------------------------------------------------------------------------
-- Both use the established named gate: app.write_path set transaction-locally
-- immediately around the function's own statement, and cleared after, because a
-- nested helper clears it. As everywhere else the gate is used it is a guard
-- rail and a seam for trusted layers, not a boundary: a session with direct SQL
-- can set it itself, and it grants nothing if it does. Nothing reads the action
-- log to authorize anything, and an idempotency row only ever returns a
-- response to the agent that owns it.
--
-- Replaced here with unchanged signatures. Only the gate is new.

CREATE OR REPLACE FUNCTION record_agent_action(
    p_agent_id uuid,
    p_action text,
    p_capability text,
    p_allowed boolean,
    p_domain_keys text[] DEFAULT '{}',
    p_scope_ref text DEFAULT NULL,
    p_target_ref text DEFAULT NULL,
    p_reason text DEFAULT NULL,
    p_request jsonb DEFAULT '{}'::jsonb,
    p_result jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_domain_id uuid;
    v_id uuid;
BEGIN
    IF cardinality(coalesce(p_domain_keys, '{}'::text[])) > 0 THEN
        SELECT id INTO v_domain_id
        FROM knowledge_domains
        WHERE domain_key = rye_slugify_key((coalesce(p_domain_keys, '{}'::text[]))[1])
        LIMIT 1;
    END IF;

    BEGIN
        PERFORM set_config('app.write_path', 'record_agent_action', true);

        INSERT INTO agent_action_log (
            agent_id,
            action,
            capability,
            domain_id,
            scope_ref,
            target_ref,
            allowed,
            reason,
            request,
            result
        ) VALUES (
            p_agent_id,
            coalesce(nullif(trim(p_action), ''), 'unknown_action'),
            p_capability,
            v_domain_id,
            p_scope_ref,
            p_target_ref,
            coalesce(p_allowed, false),
            p_reason,
            coalesce(p_request, '{}'::jsonb),
            coalesce(p_result, '{}'::jsonb)
        )
        RETURNING id INTO v_id;

        PERFORM set_config('app.write_path', '', true);
    EXCEPTION WHEN OTHERS THEN
        PERFORM set_config('app.write_path', '', true);
        RAISE;
    END;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION agent_create_candidate(
    p_agent_id uuid,
    p_candidate_kind text,
    p_statement text,
    p_target_payload jsonb DEFAULT '{}'::jsonb,
    p_domain_keys text[] DEFAULT '{}',
    p_source_scope text DEFAULT NULL,
    p_impact_scope text DEFAULT NULL,
    p_authority_basis text DEFAULT NULL,
    p_speech_act text DEFAULT NULL,
    p_current_or_future text DEFAULT 'current',
    p_evidence_refs jsonb DEFAULT '[]'::jsonb,
    p_review_context_ids uuid[] DEFAULT '{}'::uuid[],
    p_normalized_key text DEFAULT NULL,
    p_source_node_ids uuid[] DEFAULT '{}'::uuid[],
    p_derived_from_node_ids uuid[] DEFAULT '{}'::uuid[],
    p_confidence numeric DEFAULT NULL,
    p_idempotency_key text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_allowed boolean;
    v_candidate_id uuid;
    v_domain_keys text[] := ARRAY(
        SELECT DISTINCT rye_slugify_key(value)
        FROM unnest(coalesce(p_domain_keys, '{}'::text[])) AS value
        WHERE rye_slugify_key(value) IS NOT NULL
    );
    v_existing api_idempotency_keys;
    v_payload jsonb;
    v_request_hash text;
BEGIN
    v_allowed := has_agent_capability(p_agent_id, 'rye.candidate.create', v_domain_keys, p_source_scope);
    v_payload := coalesce(p_target_payload, '{}'::jsonb) || jsonb_build_object(
        'domain_keys', to_jsonb(v_domain_keys),
        'source_scope', p_source_scope,
        'impact_scope', p_impact_scope,
        'authority_basis', p_authority_basis,
        'speech_act', p_speech_act,
        'current_or_future', coalesce(nullif(trim(p_current_or_future), ''), 'current'),
        'evidence_refs', coalesce(p_evidence_refs, '[]'::jsonb)
    );

    v_request_hash := encode(public.digest(jsonb_build_object(
        'candidate_kind', p_candidate_kind,
        'statement', p_statement,
        'target_payload', v_payload,
        'review_context_ids', p_review_context_ids,
        'normalized_key', p_normalized_key,
        'source_node_ids', p_source_node_ids,
        'derived_from_node_ids', p_derived_from_node_ids,
        'confidence', p_confidence
    )::text, 'sha256'), 'hex');

    IF NOT v_allowed THEN
        PERFORM record_agent_action(
            p_agent_id,
            'candidate_create',
            'rye.candidate.create',
            false,
            v_domain_keys,
            p_source_scope,
            p_impact_scope,
            'missing capability grant',
            jsonb_build_object('statement', p_statement, 'domain_keys', v_domain_keys),
            '{}'::jsonb
        );
        RAISE EXCEPTION 'Agent is not authorized to create candidate in requested domain/scope'
            USING ERRCODE = '42501';
    END IF;

    IF nullif(trim(coalesce(p_idempotency_key, '')), '') IS NOT NULL THEN
        SELECT * INTO v_existing
        FROM api_idempotency_keys
        WHERE agent_id = p_agent_id
          AND key = p_idempotency_key
          AND (expires_at IS NULL OR expires_at > now());

        IF FOUND THEN
            IF v_existing.request_hash <> v_request_hash THEN
                PERFORM record_agent_action(
                    p_agent_id,
                    'candidate_create',
                    'rye.candidate.create',
                    false,
                    v_domain_keys,
                    p_source_scope,
                    p_impact_scope,
                    'idempotency key reused with different payload',
                    jsonb_build_object('idempotency_key', p_idempotency_key),
                    '{}'::jsonb
                );
                RAISE EXCEPTION 'Idempotency key was already used for a different request'
                    USING ERRCODE = '23505';
            END IF;
            RETURN (v_existing.response->>'id')::uuid;
        END IF;
    END IF;

    v_candidate_id := create_knowledge_candidate(
        p_candidate_kind        := p_candidate_kind,
        p_statement             := p_statement,
        p_target_payload        := v_payload,
        p_review_context_ids    := p_review_context_ids,
        p_normalized_key        := p_normalized_key,
        p_created_by            := p_agent_id::text,
        p_source_node_ids       := p_source_node_ids,
        p_derived_from_node_ids := p_derived_from_node_ids,
        p_confidence            := p_confidence
    );

    IF nullif(trim(coalesce(p_idempotency_key, '')), '') IS NOT NULL THEN
        BEGIN
            PERFORM set_config('app.write_path', 'agent_create_candidate', true);

            INSERT INTO api_idempotency_keys (agent_id, key, request_hash, response, expires_at)
            VALUES (
                p_agent_id,
                p_idempotency_key,
                v_request_hash,
                jsonb_build_object('id', v_candidate_id),
                now() + interval '24 hours'
            );

            PERFORM set_config('app.write_path', '', true);
        EXCEPTION WHEN OTHERS THEN
            PERFORM set_config('app.write_path', '', true);
            RAISE;
        END;
    END IF;

    PERFORM record_agent_action(
        p_agent_id,
        'candidate_create',
        'rye.candidate.create',
        true,
        v_domain_keys,
        p_source_scope,
        v_candidate_id::text,
        'candidate stored',
        jsonb_build_object('statement', p_statement, 'domain_keys', v_domain_keys),
        jsonb_build_object('candidate_id', v_candidate_id)
    );

    RETURN v_candidate_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
