-- Token-bound SQL functions for direct database agent runtimes.

SET search_path = rye, pg_catalog, public;

-- A missing scope means an unscoped grant is required. A scoped grant must
-- never become a wildcard merely because the caller omitted scope_ref.
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
        FROM agent_identities identity_row
        WHERE identity_row.id = p_agent_id
          AND identity_row.active = true
    ) THEN
        RETURN false;
    END IF;

    IF cardinality(v_domain_keys) = 0 THEN
        RETURN EXISTS (
            SELECT 1
            FROM agent_capability_grants grant_row
            WHERE grant_row.agent_id = p_agent_id
              AND grant_row.capability = p_capability
              AND grant_row.active = true
              AND (grant_row.expires_at IS NULL OR grant_row.expires_at > now())
              AND (
                  grant_row.scope_ref IS NULL
                  OR (p_scope_ref IS NOT NULL AND grant_row.scope_ref = p_scope_ref)
              )
        );
    END IF;

    RETURN NOT EXISTS (
        SELECT 1
        FROM unnest(v_domain_keys) AS requested(domain_key)
        WHERE NOT EXISTS (
            SELECT 1
            FROM agent_capability_grants grant_row
            LEFT JOIN knowledge_domains domain_row ON domain_row.id = grant_row.domain_id
            WHERE grant_row.agent_id = p_agent_id
              AND grant_row.capability = p_capability
              AND grant_row.active = true
              AND (grant_row.expires_at IS NULL OR grant_row.expires_at > now())
              AND (grant_row.domain_id IS NULL OR domain_row.domain_key = requested.domain_key)
              AND (
                  grant_row.scope_ref IS NULL
                  OR (p_scope_ref IS NOT NULL AND grant_row.scope_ref = p_scope_ref)
              )
        )
    );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION agent_id_from_token(p_token text)
RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_auth jsonb;
    v_agent_id uuid;
BEGIN
    v_auth := authenticate_agent_token(p_token);
    IF v_auth IS NULL THEN
        RAISE EXCEPTION 'Invalid or expired Rye agent token'
            USING ERRCODE = '28000';
    END IF;

    v_agent_id := (v_auth->>'agent_id')::uuid;
    RETURN v_agent_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION redact_agent_node_properties(
    p_properties jsonb,
    p_node_type text
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_hidden_fields text[];
BEGIN
    SELECT coalesce(array_agg(DISTINCT split_part(field_path, '.', 2)), '{}'::text[])
    INTO v_hidden_fields
    FROM field_classifications
    WHERE node_type = p_node_type
      AND classification <> 'public';

    RETURN coalesce(p_properties, '{}'::jsonb) - v_hidden_fields;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- Preserve the observation contract while attaching the source item to every
-- known requested domain using the submission event as membership lineage.
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
    v_allowed := has_agent_capability(
        p_agent_id,
        'rye.observation.create',
        v_domain_keys,
        p_source_scope
    );
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

    PERFORM attach_node_domain_memberships(
        p_node_id         := v_node_id,
        p_domain_keys     := v_domain_keys,
        p_scope_ref       := p_source_scope,
        p_source_event_id := v_event_id,
        p_effective_at    := coalesce(p_observed_at, now()),
        p_properties      := jsonb_build_object('source', 'agent_observation')
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

DO $$
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    INSERT INTO node_domain_memberships (
        node_id,
        domain_id,
        scope_ref,
        source_event_id,
        properties,
        effective_at
    )
    SELECT DISTINCT
        source_item.id,
        domain_row.id,
        nullif(trim(coalesce(source_item.properties->>'source_scope', '')), ''),
        source_event.id,
        jsonb_build_object('source', 'agent_observation_backfill'),
        coalesce((source_item.properties->>'observed_at')::timestamptz, source_item.created_at)
    FROM nodes source_item
    CROSS JOIN LATERAL jsonb_array_elements_text(
        CASE
            WHEN jsonb_typeof(source_item.properties->'domain_keys') = 'array'
                THEN source_item.properties->'domain_keys'
            ELSE '[]'::jsonb
        END
    ) requested_domain(domain_key)
    JOIN knowledge_domains domain_row
      ON domain_row.domain_key = rye_slugify_key(requested_domain.domain_key)
     AND domain_row.archived_at IS NULL
    JOIN LATERAL (
        SELECT event_row.id
        FROM events event_row
        JOIN event_participants participant ON participant.event_id = event_row.id
        WHERE participant.node_id = source_item.id
          AND participant.role = 'observation'
          AND event_row.event_type = 'agent_observation_submitted'
        ORDER BY event_row.occurred_at, event_row.id
        LIMIT 1
    ) source_event ON true
    WHERE source_item.node_type = 'source_item'
      AND source_item.archived_at IS NULL
      AND source_item.properties->>'source_kind' = 'agent_observation'
      AND NOT EXISTS (
          SELECT 1
          FROM node_domain_memberships existing
          WHERE existing.node_id = source_item.id
            AND existing.domain_id = domain_row.id
            AND coalesce(existing.scope_ref, '') = coalesce(
                nullif(trim(coalesce(source_item.properties->>'source_scope', '')), ''),
                ''
            )
            AND existing.effective_to IS NULL
      );
END;
$$;

CREATE OR REPLACE FUNCTION agent_context_pack_with_token(
    p_token text,
    p_scope_ref text DEFAULT NULL,
    p_channel_ref text DEFAULT NULL,
    p_domain_keys text[] DEFAULT '{}'
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_agent_id uuid;
    v_payload jsonb;
    v_previous_role text;
BEGIN
    v_agent_id := agent_id_from_token(p_token);
    v_previous_role := current_setting('app.current_role', true);
    PERFORM set_config('app.current_role', 'admin', true);

    BEGIN
        v_payload := agent_get_context_pack(
            v_agent_id,
            p_scope_ref,
            p_channel_ref,
            p_domain_keys
        );
    EXCEPTION WHEN OTHERS THEN
        PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
        RAISE;
    END;

    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RETURN v_payload;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION agent_search_nodes_with_token(
    p_token text,
    p_query text,
    p_domain_keys text[],
    p_scope_ref text DEFAULT NULL,
    p_limit integer DEFAULT 25
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_agent_id uuid;
    v_allowed boolean;
    v_domain_keys text[] := ARRAY(
        SELECT DISTINCT rye_slugify_key(value)
        FROM unnest(coalesce(p_domain_keys, '{}'::text[])) AS value
        WHERE rye_slugify_key(value) IS NOT NULL
    );
    v_limit integer := greatest(1, least(coalesce(p_limit, 25), 100));
    v_payload jsonb;
    v_previous_role text;
BEGIN
    v_agent_id := agent_id_from_token(p_token);
    v_previous_role := current_setting('app.current_role', true);
    PERFORM set_config('app.current_role', 'admin', true);

    IF cardinality(v_domain_keys) = 0 THEN
        PERFORM record_agent_action(
            v_agent_id,
            'node_search',
            'rye.context.read',
            false,
            '{}'::text[],
            p_scope_ref,
            NULL,
            'domain_keys required',
            jsonb_build_object('query', left(coalesce(p_query, ''), 160)),
            '{}'::jsonb
        );
        PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
        RAISE EXCEPTION 'At least one domain key is required for agent node search'
            USING ERRCODE = '22023';
    END IF;

    v_allowed := has_agent_capability(
        v_agent_id,
        'rye.context.read',
        v_domain_keys,
        p_scope_ref
    );

    IF NOT v_allowed THEN
        PERFORM record_agent_action(
            v_agent_id,
            'node_search',
            'rye.context.read',
            false,
            v_domain_keys,
            p_scope_ref,
            NULL,
            'missing capability grant',
            jsonb_build_object('query', left(coalesce(p_query, ''), 160)),
            '{}'::jsonb
        );
        PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
        RAISE EXCEPTION 'Agent is not authorized to search requested domains'
            USING ERRCODE = '42501';
    END IF;

    WITH matches AS (
        SELECT
            node_row.id,
            node_row.node_type,
            node_row.label,
            redact_agent_node_properties(node_row.properties, node_row.node_type) AS properties,
            node_row.created_at,
            CASE
                WHEN nullif(trim(coalesce(p_query, '')), '') IS NULL THEN 0::real
                ELSE public.similarity(node_row.label, p_query)
            END AS match_score
        FROM nodes node_row
        WHERE node_row.archived_at IS NULL
          AND node_row.node_type <> 'knowledge_candidate'
          AND agent_can_read_node(v_agent_id, node_row.id, now(), p_scope_ref)
          AND EXISTS (
              SELECT 1
              FROM node_domain_memberships membership
              JOIN knowledge_domains domain_row ON domain_row.id = membership.domain_id
              WHERE membership.node_id = node_row.id
                AND membership.effective_at <= now()
                AND (membership.effective_to IS NULL OR membership.effective_to > now())
                AND domain_row.domain_key = ANY(v_domain_keys)
          )
          AND (
              nullif(trim(coalesce(p_query, '')), '') IS NULL
              OR node_row.label ILIKE '%' || p_query || '%'
              OR node_row.node_type ILIKE '%' || p_query || '%'
          )
        ORDER BY match_score DESC, node_row.label, node_row.id
        LIMIT v_limit
    )
    SELECT jsonb_build_object(
        'agent_id', v_agent_id,
        'domain_keys', to_jsonb(v_domain_keys),
        'scope_ref', p_scope_ref,
        'query', coalesce(p_query, ''),
        'results', coalesce(jsonb_agg(to_jsonb(matches) ORDER BY match_score DESC, label), '[]'::jsonb)
    )
    INTO v_payload
    FROM matches;

    PERFORM record_agent_action(
        v_agent_id,
        'node_search',
        'rye.context.read',
        true,
        v_domain_keys,
        p_scope_ref,
        NULL,
        'scoped node search returned',
        jsonb_build_object('query', left(coalesce(p_query, ''), 160), 'limit', v_limit),
        jsonb_build_object(
            'result_count', jsonb_array_length(coalesce(v_payload->'results', '[]'::jsonb))
        )
    );

    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RETURN v_payload;
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION agent_node_summary_with_token(
    p_token text,
    p_node_id uuid,
    p_scope_ref text DEFAULT NULL,
    p_max_items integer DEFAULT 10
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_agent_id uuid;
    v_allowed boolean;
    v_max_items integer := greatest(1, least(coalesce(p_max_items, 10), 50));
    v_payload jsonb;
    v_previous_role text;
BEGIN
    v_agent_id := agent_id_from_token(p_token);
    v_previous_role := current_setting('app.current_role', true);
    PERFORM set_config('app.current_role', 'admin', true);
    v_allowed := agent_can_read_node(v_agent_id, p_node_id, now(), p_scope_ref);

    IF NOT v_allowed THEN
        PERFORM record_agent_action(
            v_agent_id,
            'node_summary',
            'rye.context.read',
            false,
            '{}'::text[],
            p_scope_ref,
            p_node_id::text,
            'node is unclassified or outside complete domain grant',
            '{}'::jsonb,
            '{}'::jsonb
        );
        PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
        RAISE EXCEPTION 'Agent is not authorized to read requested node'
            USING ERRCODE = '42501';
    END IF;

    SELECT jsonb_build_object(
        'agent_id', v_agent_id,
        'as_of', now(),
        'node', jsonb_build_object(
            'id', node_row.id,
            'node_type', node_row.node_type,
            'label', node_row.label,
            'properties', redact_agent_node_properties(node_row.properties, node_row.node_type)
        ),
        'domain_memberships', (
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                'domain_key', domain_row.domain_key,
                'scope_ref', membership.scope_ref,
                'effective_at', membership.effective_at,
                'effective_to', membership.effective_to,
                'source_event_id', membership.source_event_id
            ) ORDER BY domain_row.domain_key, membership.scope_ref), '[]'::jsonb)
            FROM node_domain_memberships membership
            JOIN knowledge_domains domain_row ON domain_row.id = membership.domain_id
            WHERE membership.node_id = node_row.id
              AND membership.effective_at <= now()
              AND (membership.effective_to IS NULL OR membership.effective_to > now())
        ),
        'accepted_knowledge', (
            SELECT coalesce(jsonb_agg(to_jsonb(assertion_row) ORDER BY assertion_row.asserted_at DESC), '[]'::jsonb)
            FROM (
                SELECT
                    assertion.id,
                    assertion.assertion_type,
                    assertion.assertion_key,
                    assertion.claim,
                    assertion.confidence,
                    assertion.asserted_at,
                    assertion.effective_at,
                    assertion.effective_to,
                    assertion.source_event_id,
                    'current'::text AS record_mode
                FROM current_valid_assertions assertion
                WHERE assertion.subject_node_id = node_row.id
                  AND coalesce(assertion.attrs->>'record_mode', 'current') = 'current'
                  AND NOT EXISTS (
                      SELECT 1
                      FROM assertion_type_access restricted_type
                      WHERE restricted_type.assertion_type = assertion.assertion_type
                        AND restricted_type.operation = 'read'
                  )
                ORDER BY assertion.asserted_at DESC
                LIMIT v_max_items
            ) assertion_row
        ),
        'relationships', (
            SELECT coalesce(jsonb_agg(to_jsonb(relationship_row)), '[]'::jsonb)
            FROM (
                SELECT
                    edge.edge_type,
                    CASE WHEN edge.source_id = node_row.id THEN 'outbound' ELSE 'inbound' END AS direction,
                    related.id AS related_id,
                    related.node_type AS related_type,
                    related.label AS related_label
                FROM edges edge
                JOIN nodes related
                  ON related.id = CASE
                      WHEN edge.source_id = node_row.id THEN edge.target_id
                      ELSE edge.source_id
                  END
                WHERE (edge.source_id = node_row.id OR edge.target_id = node_row.id)
                  AND edge.archived_at IS NULL
                  AND related.archived_at IS NULL
                  AND agent_can_read_node(v_agent_id, related.id, now(), p_scope_ref)
                ORDER BY edge.weight DESC NULLS LAST, related.label
                LIMIT v_max_items
            ) relationship_row
        ),
        'recent_activity', (
            SELECT coalesce(jsonb_agg(to_jsonb(activity_row) ORDER BY activity_row.occurred_at DESC), '[]'::jsonb)
            FROM (
                SELECT
                    event_row.id AS event_id,
                    event_row.event_type,
                    event_row.occurred_at,
                    participant.role,
                    'explicit_event_date'::text AS date_quality
                FROM events event_row
                JOIN event_participants participant ON participant.event_id = event_row.id
                WHERE participant.node_id = node_row.id
                ORDER BY event_row.occurred_at DESC
                LIMIT v_max_items
            ) activity_row
        )
    )
    INTO v_payload
    FROM nodes node_row
    WHERE node_row.id = p_node_id
      AND node_row.archived_at IS NULL;

    PERFORM record_agent_action(
        v_agent_id,
        'node_summary',
        'rye.context.read',
        true,
        ARRAY(
            SELECT domain_row.domain_key
            FROM node_domain_memberships membership
            JOIN knowledge_domains domain_row ON domain_row.id = membership.domain_id
            WHERE membership.node_id = p_node_id
              AND membership.effective_at <= now()
              AND (membership.effective_to IS NULL OR membership.effective_to > now())
            ORDER BY domain_row.domain_key
        ),
        p_scope_ref,
        p_node_id::text,
        'scoped node summary returned',
        '{}'::jsonb,
        jsonb_build_object('node_id', p_node_id)
    );

    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RETURN v_payload;
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION agent_submit_observation_with_token(
    p_token text,
    p_observation jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_agent_id uuid;
    v_domain_keys text[];
    v_result uuid;
    v_previous_role text;
BEGIN
    IF nullif(trim(coalesce(p_observation->>'statement', '')), '') IS NULL
       OR length(p_observation->>'statement') > 4000
    THEN
        RAISE EXCEPTION 'Observation statement must contain 1 to 4000 characters'
            USING ERRCODE = '22023';
    END IF;

    v_domain_keys := ARRAY(
        SELECT DISTINCT rye_slugify_key(value)
        FROM jsonb_array_elements_text(
            CASE
                WHEN jsonb_typeof(p_observation->'domain_keys') = 'array'
                    THEN p_observation->'domain_keys'
                ELSE '[]'::jsonb
            END
        ) AS value
        WHERE rye_slugify_key(value) IS NOT NULL
    );
    IF cardinality(v_domain_keys) = 0 THEN
        RAISE EXCEPTION 'Observation domain_keys are required'
            USING ERRCODE = '22023';
    END IF;

    v_agent_id := agent_id_from_token(p_token);
    v_previous_role := current_setting('app.current_role', true);
    PERFORM set_config('app.current_role', 'admin', true);

    BEGIN
        v_result := agent_submit_observation(
            p_agent_id      := v_agent_id,
            p_statement     := p_observation->>'statement',
            p_domain_keys   := v_domain_keys,
            p_source_scope  := p_observation->>'source_scope',
            p_impact_scope  := p_observation->>'impact_scope',
            p_evidence_refs := coalesce(p_observation->'evidence_refs', '[]'::jsonb),
            p_observed_at   := coalesce((p_observation->>'observed_at')::timestamptz, now()),
            p_properties    := coalesce(p_observation->'properties', '{}'::jsonb)
        );
    EXCEPTION WHEN OTHERS THEN
        PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
        RAISE;
    END;

    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION agent_create_candidate_with_token(
    p_token text,
    p_candidate jsonb,
    p_idempotency_key text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_agent_id uuid;
    v_domain_keys text[];
    v_review_context_ids uuid[];
    v_source_node_ids uuid[];
    v_derived_node_ids uuid[];
    v_result uuid;
    v_previous_role text;
BEGIN
    IF nullif(trim(coalesce(p_candidate->>'candidate_kind', '')), '') IS NULL THEN
        RAISE EXCEPTION 'candidate_kind is required' USING ERRCODE = '22023';
    END IF;
    IF nullif(trim(coalesce(p_candidate->>'statement', '')), '') IS NULL THEN
        RAISE EXCEPTION 'Candidate statement is required' USING ERRCODE = '22023';
    END IF;

    v_domain_keys := ARRAY(
        SELECT DISTINCT rye_slugify_key(value)
        FROM jsonb_array_elements_text(
            CASE
                WHEN jsonb_typeof(p_candidate->'domain_keys') = 'array'
                    THEN p_candidate->'domain_keys'
                ELSE '[]'::jsonb
            END
        ) AS value
        WHERE rye_slugify_key(value) IS NOT NULL
    );
    IF cardinality(v_domain_keys) = 0 THEN
        RAISE EXCEPTION 'Candidate domain_keys are required'
            USING ERRCODE = '22023';
    END IF;

    v_review_context_ids := ARRAY(
        SELECT value::uuid
        FROM jsonb_array_elements_text(
            CASE
                WHEN jsonb_typeof(p_candidate->'review_context_ids') = 'array'
                    THEN p_candidate->'review_context_ids'
                ELSE '[]'::jsonb
            END
        ) AS value
    );
    v_source_node_ids := ARRAY(
        SELECT value::uuid
        FROM jsonb_array_elements_text(
            CASE
                WHEN jsonb_typeof(p_candidate->'source_node_ids') = 'array'
                    THEN p_candidate->'source_node_ids'
                ELSE '[]'::jsonb
            END
        ) AS value
    );
    v_derived_node_ids := ARRAY(
        SELECT value::uuid
        FROM jsonb_array_elements_text(
            CASE
                WHEN jsonb_typeof(p_candidate->'derived_from_node_ids') = 'array'
                    THEN p_candidate->'derived_from_node_ids'
                ELSE '[]'::jsonb
            END
        ) AS value
    );

    v_agent_id := agent_id_from_token(p_token);
    v_previous_role := current_setting('app.current_role', true);
    PERFORM set_config('app.current_role', 'admin', true);

    BEGIN
        v_result := agent_create_candidate(
            p_agent_id               := v_agent_id,
            p_candidate_kind         := p_candidate->>'candidate_kind',
            p_statement              := p_candidate->>'statement',
            p_target_payload         := coalesce(p_candidate->'target_payload', '{}'::jsonb),
            p_domain_keys            := v_domain_keys,
            p_source_scope           := p_candidate->>'source_scope',
            p_impact_scope           := p_candidate->>'impact_scope',
            p_authority_basis        := p_candidate->>'authority_basis',
            p_speech_act             := p_candidate->>'speech_act',
            p_current_or_future      := coalesce(p_candidate->>'current_or_future', 'current'),
            p_evidence_refs          := coalesce(p_candidate->'evidence_refs', '[]'::jsonb),
            p_review_context_ids     := v_review_context_ids,
            p_normalized_key         := p_candidate->>'normalized_key',
            p_source_node_ids        := v_source_node_ids,
            p_derived_from_node_ids  := v_derived_node_ids,
            p_confidence             := (p_candidate->>'confidence')::numeric,
            p_idempotency_key        := p_idempotency_key
        );
    EXCEPTION WHEN OTHERS THEN
        PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
        RAISE;
    END;

    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Raw identity-taking and administrative functions are trusted gateway/admin
-- primitives. Direct database runtimes receive only the token-bound wrappers.
REVOKE EXECUTE ON FUNCTION ensure_knowledge_domain(text, text, text, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION subscribe_channel_to_domain(text, text, text, boolean, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION grant_domain_authority(text, text, text, text[], text, text[], timestamptz, timestamptz, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION create_agent_identity(text, text, text, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION grant_agent_capability(text, text, text, text, timestamptz, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION issue_agent_token_record(text, text, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION issue_agent_token(text, text, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION revoke_agent_token(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION authenticate_agent_token(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION record_agent_action(uuid, text, text, boolean, text[], text, text, text, jsonb, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION has_agent_capability(uuid, text, text[], text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION authorize_agent_action(uuid, text, text[], text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_get_context_pack(uuid, text, text, text[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_submit_observation(uuid, text, text[], text, text, jsonb, timestamptz, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_create_candidate(uuid, text, text, jsonb, text[], text, text, text, text, text, jsonb, uuid[], text, uuid[], uuid[], numeric, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_id_from_token(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION redact_agent_node_properties(jsonb, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_context_pack_with_token(text, text, text, text[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_search_nodes_with_token(text, text, text[], text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_node_summary_with_token(text, uuid, text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_submit_observation_with_token(text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_create_candidate_with_token(text, jsonb, text) FROM PUBLIC;
