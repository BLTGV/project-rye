-- Close cross-domain and cross-channel discovery in scoped agent context packs.

SET search_path = rye, pg_catalog, public;

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
            jsonb_build_object(
                'scope_ref', p_scope_ref,
                'channel_ref', p_channel_ref,
                'domain_keys', p_domain_keys
            ),
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
          AND d.domain_key IN (SELECT domain_key FROM selected_domain_keys)
          AND EXISTS (
              SELECT 1
              FROM agent_capability_grants g
              LEFT JOIN knowledge_domains granted_domain ON granted_domain.id = g.domain_id
              WHERE g.agent_id = p_agent_id
                AND g.capability = 'rye.context.read'
                AND g.active = true
                AND (g.expires_at IS NULL OR g.expires_at > now())
                AND (g.domain_id IS NULL OR granted_domain.domain_key = d.domain_key)
                AND (
                    (p_scope_ref IS NULL AND g.scope_ref IS NULL)
                    OR (
                        p_scope_ref IS NOT NULL
                        AND (g.scope_ref IS NULL OR g.scope_ref = p_scope_ref)
                    )
                )
          )
    ),
    authorized_domain_keys AS (
        SELECT domain_key FROM selected_domains
    ),
    domains_json AS (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
            'domain_id', d.id,
            'domain_key', d.domain_key,
            'label', d.label,
            'purpose', d.purpose,
            'properties', CASE
                WHEN has_agent_capability(
                    p_agent_id,
                    'rye.domain.admin',
                    ARRAY[d.domain_key],
                    p_scope_ref
                ) THEN d.properties
                ELSE '{}'::jsonb
            END,
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
                  AND (
                      a.scope_ref IS NULL
                      OR a.scope_ref = p_scope_ref
                      OR a.scope_ref = p_channel_ref
                  )
            ),
            'claim_policies', (
                SELECT coalesce(jsonb_agg(jsonb_build_object(
                    'claim_type', p.claim_type,
                    'candidate_policy', p.candidate_policy,
                    'authority_required', p.authority_required,
                    'properties', CASE
                        WHEN has_agent_capability(
                            p_agent_id,
                            'rye.domain.admin',
                            ARRAY[d.domain_key],
                            p_scope_ref
                        ) THEN p.properties
                        ELSE '{}'::jsonb
                    END
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
          AND jsonb_typeof(n.properties->'target_payload'->'domain_keys') = 'array'
          AND jsonb_array_length(n.properties->'target_payload'->'domain_keys') > 0
          AND (
              p_channel_ref IS NULL
              OR n.properties->'target_payload'->>'source_scope' IS NULL
              OR n.properties->'target_payload'->>'source_scope' = p_channel_ref
          )
          AND NOT EXISTS (
              SELECT 1
              FROM jsonb_array_elements_text(
                  n.properties->'target_payload'->'domain_keys'
              ) AS candidate_domain(domain_key)
              WHERE rye_slugify_key(candidate_domain.domain_key) IS NULL
                 OR rye_slugify_key(candidate_domain.domain_key)
                    NOT IN (SELECT domain_key FROM authorized_domain_keys)
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
        jsonb_build_object(
            'scope_ref', p_scope_ref,
            'channel_ref', p_channel_ref,
            'domain_keys', p_domain_keys
        ),
        jsonb_build_object(
            'domain_count', jsonb_array_length(coalesce(v_payload->'domains', '[]'::jsonb)),
            'candidate_count', jsonb_array_length(coalesce(v_payload->'open_candidates', '[]'::jsonb))
        )
    );

    RETURN v_payload;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

