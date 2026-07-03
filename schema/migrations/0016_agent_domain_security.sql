-- Agent domain authority, scoped agent access, and context packs.
--
-- This layer gives external agent runtimes a narrow, auditable interface:
-- agents submit observations and candidates, while authoritative promotion
-- remains gated by explicit capabilities.

SET search_path = rye, pg_catalog, public;

CREATE TABLE IF NOT EXISTS knowledge_domains (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    domain_key    text NOT NULL UNIQUE,
    label         text NOT NULL,
    purpose       text NOT NULL,
    owner_node_id uuid REFERENCES nodes(id),
    properties    jsonb NOT NULL DEFAULT '{}',
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    archived_at   timestamptz
);

CREATE INDEX IF NOT EXISTS idx_knowledge_domains_active
    ON knowledge_domains (domain_key)
    WHERE archived_at IS NULL;

CREATE TABLE IF NOT EXISTS domain_authorities (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    domain_id       uuid NOT NULL REFERENCES knowledge_domains(id),
    authority_kind  text NOT NULL CHECK (authority_kind IN ('person', 'system', 'team', 'role', 'source')),
    authority_ref   text NOT NULL,
    claim_types     text[] NOT NULL DEFAULT '{}',
    scope_ref       text,
    speech_acts     text[] NOT NULL DEFAULT ARRAY['confirmed', 'approved', 'decided', 'policy_set'],
    effective_at    timestamptz NOT NULL DEFAULT now(),
    effective_to    timestamptz,
    active          boolean NOT NULL DEFAULT true,
    properties      jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    CHECK (effective_to IS NULL OR effective_to > effective_at)
);

CREATE INDEX IF NOT EXISTS idx_domain_authorities_domain
    ON domain_authorities (domain_id, authority_kind, authority_ref)
    WHERE active = true;

CREATE TABLE IF NOT EXISTS channel_domain_subscriptions (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    channel_ref  text NOT NULL,
    domain_id    uuid NOT NULL REFERENCES knowledge_domains(id),
    access_level text NOT NULL DEFAULT 'read' CHECK (access_level IN ('read', 'candidate_write', 'review', 'admin')),
    is_shared    boolean NOT NULL DEFAULT true,
    properties   jsonb NOT NULL DEFAULT '{}',
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (channel_ref, domain_id)
);

CREATE INDEX IF NOT EXISTS idx_channel_domain_subscriptions_channel
    ON channel_domain_subscriptions (channel_ref);

CREATE TABLE IF NOT EXISTS domain_claim_policies (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    domain_id          uuid NOT NULL REFERENCES knowledge_domains(id),
    claim_type         text NOT NULL,
    candidate_policy   text NOT NULL DEFAULT 'candidate_until_review',
    authority_required boolean NOT NULL DEFAULT true,
    properties         jsonb NOT NULL DEFAULT '{}',
    created_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (domain_id, claim_type)
);

CREATE TABLE IF NOT EXISTS agent_identities (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_key         text NOT NULL UNIQUE,
    label             text NOT NULL,
    runtime           text NOT NULL,
    default_scope_ref text,
    active            boolean NOT NULL DEFAULT true,
    properties        jsonb NOT NULL DEFAULT '{}',
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS agent_capability_grants (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id    uuid NOT NULL REFERENCES agent_identities(id),
    capability  text NOT NULL,
    domain_id   uuid REFERENCES knowledge_domains(id),
    scope_ref   text,
    active      boolean NOT NULL DEFAULT true,
    expires_at  timestamptz,
    properties  jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_agent_capability_grants_agent
    ON agent_capability_grants (agent_id, capability)
    WHERE active = true;

CREATE TABLE IF NOT EXISTS agent_api_tokens (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id     uuid NOT NULL REFERENCES agent_identities(id),
    token_hash   text NOT NULL UNIQUE,
    label        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz,
    revoked_at   timestamptz,
    last_used_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_agent_api_tokens_agent
    ON agent_api_tokens (agent_id)
    WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS agent_action_log (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id    uuid REFERENCES agent_identities(id),
    action      text NOT NULL,
    capability  text,
    domain_id   uuid REFERENCES knowledge_domains(id),
    scope_ref   text,
    target_ref  text,
    allowed     boolean NOT NULL,
    reason      text,
    request     jsonb NOT NULL DEFAULT '{}',
    result      jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_agent_action_log_agent
    ON agent_action_log (agent_id, created_at DESC);

CREATE TABLE IF NOT EXISTS api_idempotency_keys (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id     uuid NOT NULL REFERENCES agent_identities(id),
    key          text NOT NULL,
    request_hash text NOT NULL,
    response     jsonb NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz,
    UNIQUE (agent_id, key)
);

CREATE OR REPLACE TRIGGER trg_knowledge_domains_touch_updated_at
    BEFORE UPDATE ON knowledge_domains
    FOR EACH ROW
    EXECUTE FUNCTION touch_updated_at();

CREATE OR REPLACE TRIGGER trg_agent_identities_touch_updated_at
    BEFORE UPDATE ON agent_identities
    FOR EACH ROW
    EXECUTE FUNCTION touch_updated_at();

ALTER TABLE agent_api_tokens ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS agent_api_tokens_admin_read ON agent_api_tokens;
CREATE POLICY agent_api_tokens_admin_read ON agent_api_tokens
    FOR SELECT
    USING (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS agent_api_tokens_admin_write ON agent_api_tokens;
CREATE POLICY agent_api_tokens_admin_write ON agent_api_tokens
    FOR ALL
    USING (current_setting('app.current_role', true) = 'admin')
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

CREATE OR REPLACE FUNCTION ensure_knowledge_domain(
    p_domain_key text,
    p_label text,
    p_purpose text,
    p_owner_node_id uuid DEFAULT NULL,
    p_properties jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_domain_id uuid;
    v_key text;
BEGIN
    v_key := rye_slugify_key(p_domain_key);
    IF v_key IS NULL THEN
        RAISE EXCEPTION 'domain_key is required';
    END IF;
    IF nullif(trim(p_label), '') IS NULL THEN
        RAISE EXCEPTION 'label is required';
    END IF;
    IF nullif(trim(p_purpose), '') IS NULL THEN
        RAISE EXCEPTION 'purpose is required';
    END IF;

    INSERT INTO knowledge_domains (domain_key, label, purpose, owner_node_id, properties)
    VALUES (v_key, p_label, p_purpose, p_owner_node_id, coalesce(p_properties, '{}'::jsonb))
    ON CONFLICT (domain_key)
    DO UPDATE SET
        label = EXCLUDED.label,
        purpose = EXCLUDED.purpose,
        owner_node_id = EXCLUDED.owner_node_id,
        properties = knowledge_domains.properties || EXCLUDED.properties,
        archived_at = NULL,
        updated_at = now()
    RETURNING id INTO v_domain_id;

    RETURN v_domain_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION subscribe_channel_to_domain(
    p_channel_ref text,
    p_domain_key text,
    p_access_level text DEFAULT 'read',
    p_is_shared boolean DEFAULT true,
    p_properties jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_domain_id uuid;
    v_id uuid;
BEGIN
    IF nullif(trim(p_channel_ref), '') IS NULL THEN
        RAISE EXCEPTION 'channel_ref is required';
    END IF;

    SELECT id INTO v_domain_id
    FROM knowledge_domains
    WHERE domain_key = rye_slugify_key(p_domain_key)
      AND archived_at IS NULL;

    IF v_domain_id IS NULL THEN
        RAISE EXCEPTION 'Knowledge domain % not found', p_domain_key;
    END IF;

    INSERT INTO channel_domain_subscriptions (
        channel_ref,
        domain_id,
        access_level,
        is_shared,
        properties
    ) VALUES (
        p_channel_ref,
        v_domain_id,
        coalesce(nullif(trim(p_access_level), ''), 'read'),
        coalesce(p_is_shared, true),
        coalesce(p_properties, '{}'::jsonb)
    )
    ON CONFLICT (channel_ref, domain_id)
    DO UPDATE SET
        access_level = EXCLUDED.access_level,
        is_shared = EXCLUDED.is_shared,
        properties = channel_domain_subscriptions.properties || EXCLUDED.properties
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION grant_domain_authority(
    p_domain_key text,
    p_authority_kind text,
    p_authority_ref text,
    p_claim_types text[] DEFAULT '{}',
    p_scope_ref text DEFAULT NULL,
    p_speech_acts text[] DEFAULT ARRAY['confirmed', 'approved', 'decided', 'policy_set'],
    p_effective_at timestamptz DEFAULT now(),
    p_effective_to timestamptz DEFAULT NULL,
    p_properties jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_domain_id uuid;
    v_id uuid;
BEGIN
    SELECT id INTO v_domain_id
    FROM knowledge_domains
    WHERE domain_key = rye_slugify_key(p_domain_key)
      AND archived_at IS NULL;

    IF v_domain_id IS NULL THEN
        RAISE EXCEPTION 'Knowledge domain % not found', p_domain_key;
    END IF;

    IF nullif(trim(p_authority_ref), '') IS NULL THEN
        RAISE EXCEPTION 'authority_ref is required';
    END IF;

    INSERT INTO domain_authorities (
        domain_id,
        authority_kind,
        authority_ref,
        claim_types,
        scope_ref,
        speech_acts,
        effective_at,
        effective_to,
        properties
    ) VALUES (
        v_domain_id,
        lower(coalesce(nullif(trim(p_authority_kind), ''), 'person')),
        p_authority_ref,
        coalesce(p_claim_types, '{}'::text[]),
        p_scope_ref,
        coalesce(p_speech_acts, ARRAY['confirmed', 'approved', 'decided', 'policy_set']),
        coalesce(p_effective_at, now()),
        p_effective_to,
        coalesce(p_properties, '{}'::jsonb)
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_agent_identity(
    p_agent_key text,
    p_label text,
    p_runtime text,
    p_default_scope_ref text DEFAULT NULL,
    p_properties jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_id uuid;
    v_key text;
BEGIN
    v_key := rye_slugify_key(p_agent_key);
    IF v_key IS NULL THEN
        RAISE EXCEPTION 'agent_key is required';
    END IF;

    INSERT INTO agent_identities (agent_key, label, runtime, default_scope_ref, properties)
    VALUES (
        v_key,
        coalesce(nullif(trim(p_label), ''), v_key),
        coalesce(nullif(trim(p_runtime), ''), 'unknown'),
        p_default_scope_ref,
        coalesce(p_properties, '{}'::jsonb)
    )
    ON CONFLICT (agent_key)
    DO UPDATE SET
        label = EXCLUDED.label,
        runtime = EXCLUDED.runtime,
        default_scope_ref = EXCLUDED.default_scope_ref,
        properties = agent_identities.properties || EXCLUDED.properties,
        active = true,
        updated_at = now()
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION grant_agent_capability(
    p_agent_key text,
    p_capability text,
    p_domain_key text DEFAULT NULL,
    p_scope_ref text DEFAULT NULL,
    p_expires_at timestamptz DEFAULT NULL,
    p_properties jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_agent_id uuid;
    v_domain_id uuid;
    v_id uuid;
BEGIN
    SELECT id INTO v_agent_id
    FROM agent_identities
    WHERE agent_key = rye_slugify_key(p_agent_key)
      AND active = true;

    IF v_agent_id IS NULL THEN
        RAISE EXCEPTION 'Agent % not found', p_agent_key;
    END IF;
    IF nullif(trim(p_capability), '') IS NULL THEN
        RAISE EXCEPTION 'capability is required';
    END IF;

    IF nullif(trim(coalesce(p_domain_key, '')), '') IS NOT NULL THEN
        SELECT id INTO v_domain_id
        FROM knowledge_domains
        WHERE domain_key = rye_slugify_key(p_domain_key)
          AND archived_at IS NULL;

        IF v_domain_id IS NULL THEN
            RAISE EXCEPTION 'Knowledge domain % not found', p_domain_key;
        END IF;
    END IF;

    INSERT INTO agent_capability_grants (
        agent_id,
        capability,
        domain_id,
        scope_ref,
        expires_at,
        properties
    ) VALUES (
        v_agent_id,
        p_capability,
        v_domain_id,
        nullif(trim(coalesce(p_scope_ref, '')), ''),
        p_expires_at,
        coalesce(p_properties, '{}'::jsonb)
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION issue_agent_token_record(
    p_agent_key text,
    p_label text DEFAULT NULL,
    p_expires_at timestamptz DEFAULT NULL
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_agent_id uuid;
    v_token_id uuid;
    v_token text;
BEGIN
    SELECT id INTO v_agent_id
    FROM agent_identities
    WHERE agent_key = rye_slugify_key(p_agent_key)
      AND active = true;

    IF v_agent_id IS NULL THEN
        RAISE EXCEPTION 'Agent % not found', p_agent_key;
    END IF;

    v_token := 'rye_' || encode(public.gen_random_bytes(32), 'hex');

    INSERT INTO agent_api_tokens (agent_id, token_hash, label, expires_at)
    VALUES (
        v_agent_id,
        encode(public.digest(v_token, 'sha256'), 'hex'),
        p_label,
        p_expires_at
    )
    RETURNING id INTO v_token_id;

    RETURN jsonb_build_object(
        'token_id', v_token_id,
        'agent_key', rye_slugify_key(p_agent_key),
        'token', v_token,
        'warning', 'Token is shown once. Rye stores only its SHA-256 hash.'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION issue_agent_token(
    p_agent_key text,
    p_label text DEFAULT NULL,
    p_expires_at timestamptz DEFAULT NULL
) RETURNS text
SET search_path = rye, pg_catalog
AS $$
BEGIN
    RETURN issue_agent_token_record(p_agent_key, p_label, p_expires_at)->>'token';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

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

    RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION authenticate_agent_token(
    p_token text
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_agent agent_identities;
    v_token_id uuid;
    v_token_hash text;
BEGIN
    IF nullif(trim(coalesce(p_token, '')), '') IS NULL THEN
        RETURN NULL;
    END IF;

    v_token_hash := encode(public.digest(p_token, 'sha256'), 'hex');

    SELECT tok.id,
           ai.id,
           ai.agent_key,
           ai.label,
           ai.runtime,
           ai.default_scope_ref,
           ai.active,
           ai.properties,
           ai.created_at,
           ai.updated_at
    INTO v_token_id,
         v_agent.id,
         v_agent.agent_key,
         v_agent.label,
         v_agent.runtime,
         v_agent.default_scope_ref,
         v_agent.active,
         v_agent.properties,
         v_agent.created_at,
         v_agent.updated_at
    FROM agent_api_tokens tok
    JOIN agent_identities ai ON ai.id = tok.agent_id
    WHERE tok.token_hash = v_token_hash
      AND tok.revoked_at IS NULL
      AND (tok.expires_at IS NULL OR tok.expires_at > now())
      AND ai.active = true;

    IF v_agent.id IS NULL THEN
        RETURN NULL;
    END IF;

    UPDATE agent_api_tokens
    SET last_used_at = now()
    WHERE id = v_token_id;

    RETURN jsonb_build_object(
        'agent_id', v_agent.id,
        'agent_key', v_agent.agent_key,
        'label', v_agent.label,
        'runtime', v_agent.runtime,
        'default_scope_ref', v_agent.default_scope_ref,
        'capabilities', (
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                'capability', g.capability,
                'domain_key', d.domain_key,
                'scope_ref', g.scope_ref,
                'expires_at', g.expires_at
            ) ORDER BY g.capability, d.domain_key NULLS FIRST), '[]'::jsonb)
            FROM agent_capability_grants g
            LEFT JOIN knowledge_domains d ON d.id = g.domain_id
            WHERE g.agent_id = v_agent.id
              AND g.active = true
              AND (g.expires_at IS NULL OR g.expires_at > now())
        )
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION revoke_agent_token(
    p_token_id uuid,
    p_actor text DEFAULT NULL
) RETURNS boolean
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_agent_id uuid;
BEGIN
    UPDATE agent_api_tokens
    SET revoked_at = now()
    WHERE id = p_token_id
      AND revoked_at IS NULL
    RETURNING agent_id INTO v_agent_id;

    IF v_agent_id IS NOT NULL THEN
        PERFORM record_agent_action(
            v_agent_id,
            'agent_token_revoke',
            'rye.admin.manage',
            true,
            '{}'::text[],
            NULL,
            p_token_id::text,
            coalesce(p_actor, current_setting('app.current_user_id', true)),
            jsonb_build_object('token_id', p_token_id),
            '{}'::jsonb
        );
        RETURN true;
    END IF;

    RETURN false;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION has_agent_capability(
    p_agent_id uuid,
    p_capability text,
    p_domain_keys text[] DEFAULT '{}',
    p_scope_ref text DEFAULT NULL
) RETURNS boolean
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_domain_keys text[] := ARRAY(
        SELECT DISTINCT rye_slugify_key(value)
        FROM unnest(coalesce(p_domain_keys, '{}'::text[])) AS value
        WHERE rye_slugify_key(value) IS NOT NULL
    );
BEGIN
    IF p_agent_id IS NULL OR nullif(trim(coalesce(p_capability, '')), '') IS NULL THEN
        RETURN false;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM agent_identities ai
        WHERE ai.id = p_agent_id
          AND ai.active = true
    ) THEN
        RETURN false;
    END IF;

    IF cardinality(v_domain_keys) = 0 THEN
        RETURN EXISTS (
            SELECT 1
            FROM agent_capability_grants g
            WHERE g.agent_id = p_agent_id
              AND g.capability = p_capability
              AND g.active = true
              AND (g.expires_at IS NULL OR g.expires_at > now())
              AND (p_scope_ref IS NULL OR g.scope_ref IS NULL OR g.scope_ref = p_scope_ref)
        );
    END IF;

    RETURN NOT EXISTS (
        SELECT 1
        FROM unnest(v_domain_keys) AS requested(domain_key)
        WHERE NOT EXISTS (
            SELECT 1
            FROM agent_capability_grants g
            LEFT JOIN knowledge_domains d ON d.id = g.domain_id
            WHERE g.agent_id = p_agent_id
              AND g.capability = p_capability
              AND g.active = true
              AND (g.expires_at IS NULL OR g.expires_at > now())
              AND (p_scope_ref IS NULL OR g.scope_ref IS NULL OR g.scope_ref = p_scope_ref)
              AND (g.domain_id IS NULL OR d.domain_key = requested.domain_key)
        )
    );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION authorize_agent_action(
    p_agent_id uuid,
    p_capability text,
    p_domain_keys text[] DEFAULT '{}',
    p_scope_ref text DEFAULT NULL,
    p_target_ref text DEFAULT NULL
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_allowed boolean;
BEGIN
    v_allowed := has_agent_capability(p_agent_id, p_capability, p_domain_keys, p_scope_ref);
    RETURN jsonb_build_object(
        'allowed', v_allowed,
        'capability', p_capability,
        'domain_keys', to_jsonb(coalesce(p_domain_keys, '{}'::text[])),
        'scope_ref', p_scope_ref,
        'target_ref', p_target_ref,
        'reason', CASE WHEN v_allowed THEN 'capability granted' ELSE 'missing capability grant' END
    );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION agent_get_context_pack(
    p_agent_id uuid,
    p_scope_ref text DEFAULT NULL,
    p_channel_ref text DEFAULT NULL,
    p_domain_keys text[] DEFAULT '{}'
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_allowed boolean;
    v_payload jsonb;
BEGIN
    v_allowed := has_agent_capability(p_agent_id, 'rye.context.read', p_domain_keys, p_scope_ref);
    IF NOT v_allowed THEN
        PERFORM record_agent_action(
            p_agent_id,
            'context_pack_read',
            'rye.context.read',
            false,
            p_domain_keys,
            p_scope_ref,
            p_channel_ref,
            'missing capability grant',
            jsonb_build_object('scope_ref', p_scope_ref, 'channel_ref', p_channel_ref, 'domain_keys', p_domain_keys),
            '{}'::jsonb
        );
        RAISE EXCEPTION 'Agent is not authorized to read context pack'
            USING ERRCODE = '42501';
    END IF;

    WITH requested_domains AS (
        SELECT DISTINCT rye_slugify_key(value) AS domain_key
        FROM unnest(coalesce(p_domain_keys, '{}'::text[])) AS value
        WHERE rye_slugify_key(value) IS NOT NULL
    ),
    subscribed_domains AS (
        SELECT DISTINCT d.domain_key
        FROM channel_domain_subscriptions s
        JOIN knowledge_domains d ON d.id = s.domain_id
        WHERE p_channel_ref IS NOT NULL
          AND s.channel_ref = p_channel_ref
          AND d.archived_at IS NULL
    ),
    selected_domain_keys AS (
        SELECT domain_key FROM requested_domains
        UNION
        SELECT domain_key FROM subscribed_domains
    ),
    selected_domains AS (
        SELECT d.*
        FROM knowledge_domains d
        WHERE d.archived_at IS NULL
          AND (
              EXISTS (SELECT 1 FROM selected_domain_keys)
              AND d.domain_key IN (SELECT domain_key FROM selected_domain_keys)
          )
          AND has_agent_capability(p_agent_id, 'rye.context.read', ARRAY[d.domain_key], p_scope_ref)
    ),
    domains_json AS (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
            'domain_id', d.id,
            'domain_key', d.domain_key,
            'label', d.label,
            'purpose', d.purpose,
            'properties', d.properties,
            'channel_subscription', (
                SELECT jsonb_build_object(
                    'channel_ref', s.channel_ref,
                    'access_level', s.access_level,
                    'is_shared', s.is_shared
                )
                FROM channel_domain_subscriptions s
                WHERE s.domain_id = d.id
                  AND s.channel_ref = p_channel_ref
                LIMIT 1
            ),
            'authorities', (
                SELECT coalesce(jsonb_agg(jsonb_build_object(
                    'authority_kind', a.authority_kind,
                    'authority_ref', a.authority_ref,
                    'claim_types', a.claim_types,
                    'scope_ref', a.scope_ref,
                    'speech_acts', a.speech_acts,
                    'effective_at', a.effective_at,
                    'effective_to', a.effective_to
                ) ORDER BY a.authority_kind, a.authority_ref), '[]'::jsonb)
                FROM domain_authorities a
                WHERE a.domain_id = d.id
                  AND a.active = true
                  AND (a.effective_at IS NULL OR a.effective_at <= now())
                  AND (a.effective_to IS NULL OR a.effective_to > now())
            ),
            'claim_policies', (
                SELECT coalesce(jsonb_agg(jsonb_build_object(
                    'claim_type', p.claim_type,
                    'candidate_policy', p.candidate_policy,
                    'authority_required', p.authority_required,
                    'properties', p.properties
                ) ORDER BY p.claim_type), '[]'::jsonb)
                FROM domain_claim_policies p
                WHERE p.domain_id = d.id
            )
        ) ORDER BY d.domain_key), '[]'::jsonb) AS domains
       FROM selected_domains d
    ),
    candidates_json AS (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
            'candidate_id', n.id,
            'statement', n.properties->>'statement',
            'candidate_kind', n.properties->>'candidate_kind',
            'status', coalesce(st.claim->>'status', 'missing'),
            'domain_keys', n.properties->'target_payload'->'domain_keys',
            'source_scope', n.properties->'target_payload'->>'source_scope',
            'impact_scope', n.properties->'target_payload'->>'impact_scope',
            'current_or_future', n.properties->'target_payload'->>'current_or_future'
        ) ORDER BY n.created_at DESC), '[]'::jsonb) AS candidates
        FROM nodes n
        LEFT JOIN current_valid_assertions st
          ON st.subject_node_id = n.id
         AND st.assertion_type = 'candidate_status'
         AND st.assertion_key = 'default'
        WHERE n.node_type = 'knowledge_candidate'
          AND n.archived_at IS NULL
          AND coalesce(st.claim->>'status', 'proposed') IN ('proposed', 'needs_review')
          AND EXISTS (SELECT 1 FROM selected_domain_keys)
          AND EXISTS (
              SELECT 1
              FROM jsonb_array_elements_text(coalesce(n.properties->'target_payload'->'domain_keys', '[]'::jsonb)) AS cd(domain_key)
              WHERE rye_slugify_key(cd.domain_key) IN (SELECT domain_key FROM selected_domain_keys)
          )
    )
    SELECT jsonb_build_object(
        'agent_id', p_agent_id,
        'scope_ref', p_scope_ref,
        'channel_ref', p_channel_ref,
        'domains', (SELECT domains FROM domains_json),
        'open_candidates', (SELECT candidates FROM candidates_json)
    )
    INTO v_payload;

    PERFORM record_agent_action(
        p_agent_id,
        'context_pack_read',
        'rye.context.read',
        true,
        p_domain_keys,
        p_scope_ref,
        p_channel_ref,
        'context pack returned',
        jsonb_build_object('scope_ref', p_scope_ref, 'channel_ref', p_channel_ref, 'domain_keys', p_domain_keys),
        jsonb_build_object('domain_count', jsonb_array_length(coalesce(v_payload->'domains', '[]'::jsonb)))
    );

    RETURN v_payload;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION agent_submit_observation(
    p_agent_id uuid,
    p_statement text,
    p_domain_keys text[] DEFAULT '{}',
    p_source_scope text DEFAULT NULL,
    p_impact_scope text DEFAULT NULL,
    p_evidence_refs jsonb DEFAULT '[]'::jsonb,
    p_observed_at timestamptz DEFAULT now(),
    p_properties jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_allowed boolean;
    v_domain_keys text[] := ARRAY(
        SELECT DISTINCT rye_slugify_key(value)
        FROM unnest(coalesce(p_domain_keys, '{}'::text[])) AS value
        WHERE rye_slugify_key(value) IS NOT NULL
    );
    v_node_id uuid;
    v_event_id uuid;
BEGIN
    v_allowed := has_agent_capability(p_agent_id, 'rye.observation.create', v_domain_keys, p_source_scope);
    IF NOT v_allowed THEN
        PERFORM record_agent_action(
            p_agent_id,
            'observation_create',
            'rye.observation.create',
            false,
            v_domain_keys,
            p_source_scope,
            p_impact_scope,
            'missing capability grant',
            jsonb_build_object('statement', p_statement, 'domain_keys', v_domain_keys),
            '{}'::jsonb
        );
        RAISE EXCEPTION 'Agent is not authorized to submit observations'
            USING ERRCODE = '42501';
    END IF;

    INSERT INTO nodes (node_type, label, properties, attrs)
    VALUES (
        'source_item',
        left(coalesce(nullif(trim(p_statement), ''), 'Agent observation'), 160),
        coalesce(p_properties, '{}'::jsonb) || jsonb_build_object(
            'source_kind', 'agent_observation',
            'source_value', 'context_signal',
            'statement', p_statement,
            'domain_keys', to_jsonb(v_domain_keys),
            'source_scope', p_source_scope,
            'impact_scope', p_impact_scope,
            'evidence_refs', coalesce(p_evidence_refs, '[]'::jsonb),
            'observed_at', p_observed_at
        ),
        jsonb_build_object('created_by_agent_id', p_agent_id)
    )
    RETURNING id INTO v_node_id;

    v_event_id := record_event(
        p_event_type        := 'agent_observation_submitted',
        p_summary           := left(coalesce(p_statement, 'Agent observation submitted'), 160),
        p_properties        := jsonb_build_object(
            'agent_id', p_agent_id,
            'source_item_id', v_node_id,
            'domain_keys', to_jsonb(v_domain_keys),
            'source_scope', p_source_scope,
            'impact_scope', p_impact_scope
        ),
        p_participant_ids   := ARRAY[v_node_id],
        p_participant_roles := ARRAY['observation'],
        p_actor             := p_agent_id::text
    );

    PERFORM record_agent_action(
        p_agent_id,
        'observation_create',
        'rye.observation.create',
        true,
        v_domain_keys,
        p_source_scope,
        v_node_id::text,
        'observation stored',
        jsonb_build_object('statement', p_statement),
        jsonb_build_object('source_item_id', v_node_id, 'event_id', v_event_id)
    );

    RETURN v_node_id;
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
        INSERT INTO api_idempotency_keys (agent_id, key, request_hash, response, expires_at)
        VALUES (
            p_agent_id,
            p_idempotency_key,
            v_request_hash,
            jsonb_build_object('id', v_candidate_id),
            now() + interval '24 hours'
        );
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
