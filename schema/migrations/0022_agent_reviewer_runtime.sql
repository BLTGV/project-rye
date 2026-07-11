-- Token-bound reviewer, adjudication, promotion, and process evaluation tools.

SET search_path = rye, pg_catalog, public;

CREATE OR REPLACE FUNCTION knowledge_candidate_domain_keys(
    p_candidate_id uuid
) RETURNS text[]
SET search_path = rye, pg_catalog
AS $$
    SELECT ARRAY(
        SELECT DISTINCT rye_slugify_key(value)
        FROM nodes candidate
        CROSS JOIN LATERAL jsonb_array_elements_text(
            CASE
                WHEN jsonb_typeof(candidate.properties->'target_payload'->'domain_keys') = 'array'
                    THEN candidate.properties->'target_payload'->'domain_keys'
                ELSE '[]'::jsonb
            END
        ) requested(value)
        WHERE candidate.id = p_candidate_id
          AND candidate.node_type = 'knowledge_candidate'
          AND candidate.archived_at IS NULL
          AND rye_slugify_key(value) IS NOT NULL
        ORDER BY rye_slugify_key(value)
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION agent_review_queue_with_token(
    p_token text,
    p_status text DEFAULT NULL,
    p_kind text DEFAULT NULL,
    p_query text DEFAULT NULL,
    p_include_closed boolean DEFAULT false,
    p_limit integer DEFAULT 80,
    p_offset integer DEFAULT 0
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_agent_id uuid;
    v_limit integer := greatest(1, least(coalesce(p_limit, 80), 200));
    v_offset integer := greatest(0, coalesce(p_offset, 0));
    v_previous_role text;
    v_payload jsonb;
BEGIN
    v_agent_id := agent_id_from_token(p_token);
    v_previous_role := current_setting('app.current_role', true);
    PERFORM set_config('app.current_role', 'admin', true);

    WITH candidate_rows AS (
        SELECT
            candidate.id,
            candidate.label AS statement,
            candidate.properties->>'candidate_kind' AS candidate_kind,
            coalesce(status_assertion.claim->>'status', 'proposed') AS status,
            candidate.properties->'target_payload' AS target_payload,
            candidate.properties->'target_payload'->>'source_scope' AS source_scope,
            candidate.properties->'target_payload'->>'impact_scope' AS impact_scope,
            to_jsonb(knowledge_candidate_domain_keys(candidate.id)) AS domain_keys,
            (
                SELECT coalesce(jsonb_agg(jsonb_build_object(
                    'node_id', source_edge.target_id,
                    'edge_type', source_edge.edge_type,
                    'created_at', source_edge.created_at
                ) ORDER BY source_edge.created_at), '[]'::jsonb)
                FROM edges source_edge
                WHERE source_edge.source_id = candidate.id
                  AND source_edge.edge_type IN ('supported_by', 'derived_from')
                  AND source_edge.archived_at IS NULL
                  AND agent_can_read_node(
                      v_agent_id,
                      source_edge.target_id,
                      now(),
                      candidate.properties->'target_payload'->>'source_scope'
                  )
            ) AS source_refs,
            candidate.created_at
        FROM nodes candidate
        LEFT JOIN current_valid_assertions status_assertion
          ON status_assertion.subject_node_id = candidate.id
         AND status_assertion.assertion_type = 'candidate_status'
         AND status_assertion.assertion_key = 'default'
        WHERE candidate.node_type = 'knowledge_candidate'
          AND candidate.archived_at IS NULL
          AND agent_can_read_node(v_agent_id, candidate.id, now(), candidate.properties->'target_payload'->>'source_scope')
          AND has_agent_capability(
              v_agent_id,
              'rye.review.read',
              knowledge_candidate_domain_keys(candidate.id),
              candidate.properties->'target_payload'->>'source_scope'
          )
          AND (
              coalesce(p_include_closed, false)
              OR coalesce(status_assertion.claim->>'status', 'proposed') IN ('proposed', 'needs_review')
          )
          AND (p_status IS NULL OR coalesce(status_assertion.claim->>'status', 'proposed') = p_status)
          AND (p_kind IS NULL OR candidate.properties->>'candidate_kind' = p_kind)
          AND (
              nullif(trim(coalesce(p_query, '')), '') IS NULL
              OR candidate.label ILIKE '%' || p_query || '%'
          )
        ORDER BY candidate.created_at DESC, candidate.id
        LIMIT v_limit OFFSET v_offset
    )
    SELECT jsonb_build_object(
        'agent_id', v_agent_id,
        'results', coalesce(jsonb_agg(to_jsonb(candidate_rows) ORDER BY created_at DESC), '[]'::jsonb),
        'limit', v_limit,
        'offset', v_offset
    )
    INTO v_payload
    FROM candidate_rows;

    PERFORM record_agent_action(
        v_agent_id,
        'review_queue_read',
        'rye.review.read',
        true,
        '{}'::text[],
        NULL,
        NULL,
        'scoped review queue returned',
        jsonb_build_object('status', p_status, 'kind', p_kind, 'query', left(coalesce(p_query, ''), 160)),
        jsonb_build_object('result_count', jsonb_array_length(v_payload->'results'))
    );

    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RETURN v_payload;
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION agent_adjudicate_candidate_with_token(
    p_token text,
    p_candidate_id uuid,
    p_status text,
    p_reason text DEFAULT NULL
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_agent_id uuid;
    v_agent_key text;
    v_domain_keys text[];
    v_scope_ref text;
    v_assertion_id uuid;
    v_previous_role text;
BEGIN
    IF p_status NOT IN ('needs_review', 'rejected', 'duplicate', 'superseded') THEN
        RAISE EXCEPTION 'Reviewer status must be needs_review, rejected, duplicate, or superseded'
            USING ERRCODE = '22023';
    END IF;

    v_agent_id := agent_id_from_token(p_token);
    v_previous_role := current_setting('app.current_role', true);
    PERFORM set_config('app.current_role', 'admin', true);

    SELECT agent_key INTO v_agent_key FROM agent_identities WHERE id = v_agent_id;
    v_domain_keys := knowledge_candidate_domain_keys(p_candidate_id);
    SELECT properties->'target_payload'->>'source_scope'
    INTO v_scope_ref
    FROM nodes
    WHERE id = p_candidate_id
      AND node_type = 'knowledge_candidate'
      AND archived_at IS NULL;

    IF NOT FOUND OR cardinality(v_domain_keys) = 0 THEN
        RAISE EXCEPTION 'Candidate is missing or has no explicit domain classification'
            USING ERRCODE = '22023';
    END IF;

    IF NOT has_agent_capability(v_agent_id, 'rye.candidate.adjudicate', v_domain_keys, v_scope_ref) THEN
        PERFORM record_agent_action(
            v_agent_id, 'candidate_adjudicate', 'rye.candidate.adjudicate', false,
            v_domain_keys, v_scope_ref, p_candidate_id::text,
            'missing capability grant', jsonb_build_object('status', p_status), '{}'::jsonb
        );
        RAISE EXCEPTION 'Agent is not authorized to adjudicate this candidate'
            USING ERRCODE = '42501';
    END IF;

    v_assertion_id := set_candidate_status(
        p_candidate_id,
        p_status,
        coalesce(p_reason, 'Candidate adjudicated by token-bound reviewer'),
        'agent:' || v_agent_key
    );

    PERFORM record_agent_action(
        v_agent_id, 'candidate_adjudicate', 'rye.candidate.adjudicate', true,
        v_domain_keys, v_scope_ref, p_candidate_id::text,
        p_status, jsonb_build_object('status', p_status),
        jsonb_build_object('status_assertion_id', v_assertion_id)
    );

    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RETURN jsonb_build_object(
        'candidate_id', p_candidate_id,
        'status', p_status,
        'status_assertion_id', v_assertion_id
    );
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION agent_evaluate_process_transition_with_token(
    p_token text,
    p_candidate_id uuid,
    p_actor_ref text,
    p_actor_node_id uuid DEFAULT NULL,
    p_as_of timestamptz DEFAULT now(),
    p_apply boolean DEFAULT false
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_agent_id uuid;
    v_domain_keys text[];
    v_scope_ref text;
    v_required_capability text;
    v_result jsonb;
    v_previous_role text;
BEGIN
    v_agent_id := agent_id_from_token(p_token);
    v_previous_role := current_setting('app.current_role', true);
    PERFORM set_config('app.current_role', 'admin', true);

    v_domain_keys := knowledge_candidate_domain_keys(p_candidate_id);
    SELECT properties->'target_payload'->>'source_scope'
    INTO v_scope_ref
    FROM nodes
    WHERE id = p_candidate_id
      AND node_type = 'knowledge_candidate'
      AND archived_at IS NULL;

    IF NOT FOUND OR cardinality(v_domain_keys) = 0 THEN
        RAISE EXCEPTION 'Candidate is missing or has no explicit domain classification'
            USING ERRCODE = '22023';
    END IF;

    v_required_capability := CASE
        WHEN coalesce(p_apply, false) THEN 'rye.authoritative.promote'
        ELSE 'rye.candidate.adjudicate'
    END;

    IF NOT has_agent_capability(v_agent_id, v_required_capability, v_domain_keys, v_scope_ref) THEN
        PERFORM record_agent_action(
            v_agent_id, 'process_transition_evaluate', v_required_capability, false,
            v_domain_keys, v_scope_ref, p_candidate_id::text,
            'missing capability grant', jsonb_build_object('apply', p_apply), '{}'::jsonb
        );
        RAISE EXCEPTION 'Agent is not authorized to evaluate or apply this process transition'
            USING ERRCODE = '42501';
    END IF;

    v_result := evaluate_process_transition(
        p_candidate_id,
        p_actor_ref,
        p_actor_node_id,
        coalesce(p_as_of, now()),
        coalesce(p_apply, false)
    );

    PERFORM record_agent_action(
        v_agent_id, 'process_transition_evaluate', v_required_capability, true,
        v_domain_keys, v_scope_ref, p_candidate_id::text,
        v_result->>'decision',
        jsonb_build_object('apply', p_apply, 'actor_ref', p_actor_ref),
        jsonb_build_object(
            'decision_id', v_result->'decision_id',
            'decision', v_result->'decision',
            'applied', v_result->'applied'
        )
    );

    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RETURN v_result;
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION agent_promote_candidate_with_token(
    p_token text,
    p_candidate_id uuid,
    p_promotion jsonb
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_agent_id uuid;
    v_agent_key text;
    v_domain_keys text[];
    v_scope_ref text;
    v_target_type text;
    v_target_id uuid;
    v_source_event_id uuid;
    v_previous_role text;
    v_result jsonb;
BEGIN
    v_agent_id := agent_id_from_token(p_token);
    v_previous_role := current_setting('app.current_role', true);
    PERFORM set_config('app.current_role', 'admin', true);
    SELECT agent_key INTO v_agent_key FROM agent_identities WHERE id = v_agent_id;

    v_domain_keys := knowledge_candidate_domain_keys(p_candidate_id);
    SELECT properties->'target_payload'->>'source_scope'
    INTO v_scope_ref
    FROM nodes
    WHERE id = p_candidate_id
      AND node_type = 'knowledge_candidate'
      AND archived_at IS NULL;

    IF NOT FOUND OR cardinality(v_domain_keys) = 0 THEN
        RAISE EXCEPTION 'Candidate is missing or has no explicit domain classification'
            USING ERRCODE = '22023';
    END IF;

    IF NOT has_agent_capability(v_agent_id, 'rye.authoritative.promote', v_domain_keys, v_scope_ref) THEN
        PERFORM record_agent_action(
            v_agent_id, 'candidate_promote', 'rye.authoritative.promote', false,
            v_domain_keys, v_scope_ref, p_candidate_id::text,
            'missing capability grant', jsonb_build_object('target_type', p_promotion->>'target_type'), '{}'::jsonb
        );
        RAISE EXCEPTION 'Agent is not authorized to promote this candidate'
            USING ERRCODE = '42501';
    END IF;

    IF EXISTS (
        SELECT 1 FROM nodes candidate
        WHERE candidate.id = p_candidate_id
          AND (
              nullif(candidate.properties->'target_payload'->>'process_node_id', '') IS NOT NULL
              OR nullif(candidate.properties->'target_payload'->>'transition_key', '') IS NOT NULL
          )
    ) THEN
        v_result := evaluate_process_transition(
            p_candidate_id,
            p_promotion->>'actor_ref',
            nullif(p_promotion->>'actor_node_id', '')::uuid,
            coalesce(nullif(p_promotion->>'as_of', '')::timestamptz, now()),
            true
        );
        PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
        RETURN v_result;
    END IF;

    v_target_type := lower(coalesce(nullif(trim(p_promotion->>'target_type'), ''), ''));
    CASE v_target_type
        WHEN 'assertion' THEN
            IF NOT agent_can_read_node(
                v_agent_id,
                (p_promotion->>'subject_node_id')::uuid,
                now(),
                v_scope_ref
            ) THEN
                RAISE EXCEPTION 'Promotion subject is outside the complete domain grant'
                    USING ERRCODE = '42501';
            END IF;
            v_target_id := promote_candidate_to_assertion(
                p_candidate_id,
                (p_promotion->>'subject_node_id')::uuid,
                p_promotion->>'assertion_type',
                coalesce(nullif(p_promotion->>'assertion_key', ''), 'default'),
                coalesce(p_promotion->'claim', '{}'::jsonb),
                nullif(p_promotion->>'effective_at', '')::timestamptz,
                nullif(p_promotion->>'effective_to', '')::timestamptz,
                nullif(p_promotion->>'confidence', '')::numeric,
                'agent:' || v_agent_key
            );
        WHEN 'task' THEN
            v_target_id := promote_candidate_to_task(
                p_candidate_id,
                p_promotion->>'label',
                coalesce(p_promotion->'properties', '{}'::jsonb),
                'agent:' || v_agent_key
            );

            SELECT event_row.id INTO v_source_event_id
            FROM events event_row
            JOIN event_participants participant ON participant.event_id = event_row.id
            WHERE participant.node_id = v_target_id
              AND participant.role = 'task'
              AND event_row.event_type = 'knowledge_candidate_promoted'
            ORDER BY event_row.occurred_at DESC, event_row.id DESC
            LIMIT 1;

            PERFORM attach_node_domain_memberships(
                v_target_id,
                v_domain_keys,
                v_scope_ref,
                v_source_event_id,
                now(),
                jsonb_build_object('source', 'candidate_promotion')
            );
        WHEN 'edge' THEN
            IF NOT agent_can_read_node(v_agent_id, (p_promotion->>'source_id')::uuid, now(), v_scope_ref)
               OR NOT agent_can_read_node(v_agent_id, (p_promotion->>'target_id')::uuid, now(), v_scope_ref)
            THEN
                RAISE EXCEPTION 'Promotion endpoints are outside the complete domain grant'
                    USING ERRCODE = '42501';
            END IF;
            v_target_id := promote_candidate_to_edge(
                p_candidate_id,
                (p_promotion->>'source_id')::uuid,
                (p_promotion->>'target_id')::uuid,
                p_promotion->>'edge_type',
                coalesce(p_promotion->'properties', '{}'::jsonb),
                nullif(p_promotion->>'effective_from', '')::timestamptz,
                nullif(p_promotion->>'effective_to', '')::timestamptz,
                'agent:' || v_agent_key
            );
        ELSE
            RAISE EXCEPTION 'Unsupported promotion target_type: %', v_target_type
                USING ERRCODE = '22023';
    END CASE;

    PERFORM record_agent_action(
        v_agent_id, 'candidate_promote', 'rye.authoritative.promote', true,
        v_domain_keys, v_scope_ref, p_candidate_id::text,
        'candidate promoted', jsonb_build_object('target_type', v_target_type),
        jsonb_build_object('target_id', v_target_id)
    );

    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RETURN jsonb_build_object('target_type', v_target_type, 'id', v_target_id);
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION knowledge_candidate_domain_keys(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_review_queue_with_token(text, text, text, text, boolean, integer, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_adjudicate_candidate_with_token(text, uuid, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_evaluate_process_transition_with_token(text, uuid, text, uuid, timestamptz, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_promote_candidate_with_token(text, uuid, jsonb) FROM PUBLIC;
