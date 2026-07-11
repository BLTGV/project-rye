-- Temporal domain membership for fail-closed scoped agent reads.

SET search_path = rye, pg_catalog, public;

CREATE TABLE IF NOT EXISTS node_domain_memberships (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id         uuid NOT NULL REFERENCES nodes(id),
    domain_id       uuid NOT NULL REFERENCES knowledge_domains(id),
    scope_ref       text,
    effective_at    timestamptz NOT NULL DEFAULT now(),
    effective_to    timestamptz,
    source_event_id uuid NOT NULL REFERENCES events(id),
    properties      jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    CHECK (effective_to IS NULL OR effective_to > effective_at)
);

CREATE INDEX IF NOT EXISTS idx_node_domain_memberships_node_time
    ON node_domain_memberships (node_id, effective_at, effective_to);

CREATE INDEX IF NOT EXISTS idx_node_domain_memberships_domain_time
    ON node_domain_memberships (domain_id, effective_at, effective_to);

CREATE UNIQUE INDEX IF NOT EXISTS idx_node_domain_memberships_active_unique
    ON node_domain_memberships (node_id, domain_id, coalesce(scope_ref, ''))
    WHERE effective_to IS NULL;

CREATE OR REPLACE FUNCTION prevent_node_domain_membership_overlap()
RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended(
        concat_ws(
            chr(31),
            NEW.node_id::text,
            NEW.domain_id::text,
            coalesce(NEW.scope_ref, '')
        ),
        0
    ));

    IF EXISTS (
        SELECT 1
        FROM node_domain_memberships existing
        WHERE existing.node_id = NEW.node_id
          AND existing.domain_id = NEW.domain_id
          AND coalesce(existing.scope_ref, '') = coalesce(NEW.scope_ref, '')
          AND existing.id <> coalesce(NEW.id, gen_random_uuid())
          AND tstzrange(existing.effective_at, existing.effective_to, '[)')
              && tstzrange(NEW.effective_at, NEW.effective_to, '[)')
    ) THEN
        RAISE EXCEPTION
            'Node domain membership overlaps an existing range for node %, domain %, scope %',
            NEW.node_id,
            NEW.domain_id,
            coalesce(NEW.scope_ref, '<global>')
            USING ERRCODE = '23P01';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_node_domain_membership_overlap ON node_domain_memberships;
CREATE TRIGGER trg_node_domain_membership_overlap
    BEFORE INSERT OR UPDATE OF node_id, domain_id, scope_ref, effective_at, effective_to
    ON node_domain_memberships
    FOR EACH ROW
    EXECUTE FUNCTION prevent_node_domain_membership_overlap();

ALTER TABLE node_domain_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE node_domain_memberships FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ndm_admin_read ON node_domain_memberships;
CREATE POLICY ndm_admin_read ON node_domain_memberships
    FOR SELECT
    USING (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS ndm_admin_insert ON node_domain_memberships;
CREATE POLICY ndm_admin_insert ON node_domain_memberships
    FOR INSERT
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS ndm_admin_update ON node_domain_memberships;
CREATE POLICY ndm_admin_update ON node_domain_memberships
    FOR UPDATE
    USING (current_setting('app.current_role', true) = 'admin')
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS ndm_admin_delete ON node_domain_memberships;
CREATE POLICY ndm_admin_delete ON node_domain_memberships
    FOR DELETE
    USING (false);

CREATE OR REPLACE FUNCTION assign_node_domain_membership(
    p_node_id uuid,
    p_domain_key text,
    p_source_event_id uuid,
    p_scope_ref text DEFAULT NULL,
    p_effective_at timestamptz DEFAULT now(),
    p_effective_to timestamptz DEFAULT NULL,
    p_properties jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_domain_id uuid;
    v_membership_id uuid;
BEGIN
    IF coalesce(current_setting('app.current_role', true), '') <> 'admin' THEN
        RAISE EXCEPTION 'Node domain membership assignment requires admin context'
            USING ERRCODE = '42501';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = p_node_id AND archived_at IS NULL) THEN
        RAISE EXCEPTION 'Active node % not found', p_node_id;
    END IF;

    SELECT id INTO v_domain_id
    FROM knowledge_domains
    WHERE domain_key = rye_slugify_key(p_domain_key)
      AND archived_at IS NULL;

    IF v_domain_id IS NULL THEN
        RAISE EXCEPTION 'Knowledge domain % not found', p_domain_key;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM events WHERE id = p_source_event_id) THEN
        RAISE EXCEPTION 'Membership source event % not found', p_source_event_id;
    END IF;

    INSERT INTO node_domain_memberships (
        node_id,
        domain_id,
        scope_ref,
        effective_at,
        effective_to,
        source_event_id,
        properties
    ) VALUES (
        p_node_id,
        v_domain_id,
        nullif(trim(coalesce(p_scope_ref, '')), ''),
        coalesce(p_effective_at, now()),
        p_effective_to,
        p_source_event_id,
        coalesce(p_properties, '{}'::jsonb)
    )
    RETURNING id INTO v_membership_id;

    RETURN v_membership_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION end_node_domain_membership(
    p_membership_id uuid,
    p_effective_to timestamptz DEFAULT now()
) RETURNS boolean
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_updated integer;
BEGIN
    IF coalesce(current_setting('app.current_role', true), '') <> 'admin' THEN
        RAISE EXCEPTION 'Node domain membership changes require admin context'
            USING ERRCODE = '42501';
    END IF;

    UPDATE node_domain_memberships
    SET effective_to = p_effective_to
    WHERE id = p_membership_id
      AND effective_to IS NULL
      AND p_effective_to > effective_at;

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    RETURN v_updated = 1;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION agent_can_read_node(
    p_agent_id uuid,
    p_node_id uuid,
    p_as_of timestamptz DEFAULT now(),
    p_scope_ref text DEFAULT NULL
) RETURNS boolean
SET search_path = rye, pg_catalog
AS $$
    WITH active_memberships AS (
        SELECT m.domain_id, m.scope_ref
        FROM node_domain_memberships m
        WHERE m.node_id = p_node_id
          AND m.effective_at <= coalesce(p_as_of, now())
          AND (m.effective_to IS NULL OR m.effective_to > coalesce(p_as_of, now()))
    )
    SELECT EXISTS (SELECT 1 FROM active_memberships)
       AND NOT EXISTS (
           SELECT 1
           FROM active_memberships membership
           WHERE NOT EXISTS (
               SELECT 1
               FROM agent_capability_grants grant_row
               WHERE grant_row.agent_id = p_agent_id
                 AND grant_row.capability = 'rye.context.read'
                 AND grant_row.active = true
                 AND (grant_row.expires_at IS NULL OR grant_row.expires_at > now())
                 AND (
                     grant_row.domain_id IS NULL
                     OR grant_row.domain_id = membership.domain_id
                 )
                 AND (
                     grant_row.scope_ref IS NULL
                     OR grant_row.scope_ref = coalesce(membership.scope_ref, p_scope_ref)
                 )
           )
       );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION attach_node_domain_memberships(
    p_node_id uuid,
    p_domain_keys text[],
    p_scope_ref text,
    p_source_event_id uuid,
    p_effective_at timestamptz DEFAULT now(),
    p_properties jsonb DEFAULT '{}'::jsonb
) RETURNS integer
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_inserted integer;
    v_previous_role text;
BEGIN
    v_previous_role := current_setting('app.current_role', true);
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
        p_node_id,
        domain_row.id,
        nullif(trim(coalesce(p_scope_ref, '')), ''),
        p_source_event_id,
        coalesce(p_properties, '{}'::jsonb),
        coalesce(p_effective_at, now())
    FROM unnest(coalesce(p_domain_keys, '{}'::text[])) requested_domain(domain_key)
    JOIN knowledge_domains domain_row
      ON domain_row.domain_key = rye_slugify_key(requested_domain.domain_key)
     AND domain_row.archived_at IS NULL;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RETURN v_inserted;
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.current_role', coalesce(v_previous_role, ''), true);
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Preserve the candidate creation contract while attaching known target
-- domains to the candidate node using the candidate-created event as lineage.
CREATE OR REPLACE FUNCTION create_knowledge_candidate(
    p_candidate_kind text,
    p_statement text,
    p_target_payload jsonb DEFAULT '{}'::jsonb,
    p_review_context_ids uuid[] DEFAULT '{}'::uuid[],
    p_normalized_key text DEFAULT NULL,
    p_created_by text DEFAULT NULL,
    p_source_node_ids uuid[] DEFAULT '{}'::uuid[],
    p_derived_from_node_ids uuid[] DEFAULT '{}'::uuid[],
    p_confidence numeric DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_candidate_id uuid;
    v_created_by text;
    v_event_id uuid;
    v_kind text;
    v_statement text;
BEGIN
    v_kind := lower(coalesce(nullif(trim(p_candidate_kind), ''), ''));
    v_statement := nullif(trim(p_statement), '');
    v_created_by := coalesce(p_created_by, current_setting('app.current_user_id', true));

    IF NOT (v_kind = ANY(ARRAY[
        'fact',
        'task',
        'edge',
        'decision',
        'procedure',
        'preference',
        'risk',
        'context_gap',
        'policy_change',
        'scope_change',
        'plugin_change',
        'dispute'
    ])) THEN
        RAISE EXCEPTION 'Unsupported candidate kind: %', p_candidate_kind;
    END IF;

    IF v_statement IS NULL THEN
        RAISE EXCEPTION 'Candidate statement is required';
    END IF;

    IF p_confidence IS NOT NULL AND (p_confidence < 0 OR p_confidence > 1) THEN
        RAISE EXCEPTION 'confidence must be between 0 and 1';
    END IF;

    INSERT INTO nodes (node_type, label, properties, attrs)
    VALUES (
        'knowledge_candidate',
        left(v_statement, 160),
        jsonb_build_object(
            'candidate_kind', v_kind,
            'statement', v_statement,
            'target_payload', coalesce(p_target_payload, '{}'::jsonb),
            'review_context_ids', to_jsonb(coalesce(p_review_context_ids, '{}'::uuid[])),
            'normalized_key', p_normalized_key,
            'created_by', v_created_by,
            'confidence', p_confidence
        ),
        jsonb_build_object('created_by', v_created_by)
    )
    RETURNING id INTO v_candidate_id;

    INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
    SELECT
        'supported_by',
        v_candidate_id,
        source_node_id,
        jsonb_build_object('created_by', v_created_by),
        jsonb_build_object('candidate_id', v_candidate_id)
    FROM (
        SELECT DISTINCT unnest(coalesce(p_source_node_ids, '{}'::uuid[])) AS source_node_id
    ) source_nodes
    WHERE source_node_id IS NOT NULL;

    INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
    SELECT
        'derived_from',
        v_candidate_id,
        derived_node_id,
        jsonb_build_object('created_by', v_created_by),
        jsonb_build_object('candidate_id', v_candidate_id)
    FROM (
        SELECT DISTINCT unnest(coalesce(p_derived_from_node_ids, '{}'::uuid[])) AS derived_node_id
    ) derived_nodes
    WHERE derived_node_id IS NOT NULL;

    v_event_id := record_event(
        p_event_type        := 'knowledge_candidate_created',
        p_summary           := format('Knowledge candidate proposed: %s', left(v_statement, 120)),
        p_properties        := jsonb_build_object(
            'candidate_id', v_candidate_id,
            'candidate_kind', v_kind,
            'statement', v_statement,
            'target_payload', coalesce(p_target_payload, '{}'::jsonb),
            'review_context_ids', to_jsonb(coalesce(p_review_context_ids, '{}'::uuid[])),
            'normalized_key', p_normalized_key,
            'source_node_ids', to_jsonb(coalesce(p_source_node_ids, '{}'::uuid[])),
            'derived_from_node_ids', to_jsonb(coalesce(p_derived_from_node_ids, '{}'::uuid[]))
        ),
        p_participant_ids   := ARRAY[v_candidate_id],
        p_participant_roles := ARRAY['candidate'],
        p_actor             := v_created_by
    );

    PERFORM attach_node_domain_memberships(
        p_node_id         := v_candidate_id,
        p_domain_keys     := ARRAY(
            SELECT requested_domain.domain_key
            FROM jsonb_array_elements_text(
                CASE
                    WHEN jsonb_typeof(p_target_payload->'domain_keys') = 'array'
                        THEN p_target_payload->'domain_keys'
                    ELSE '[]'::jsonb
                END
            ) requested_domain(domain_key)
        ),
        p_scope_ref       := p_target_payload->>'source_scope',
        p_source_event_id := v_event_id,
        p_effective_at    := now(),
        p_properties      := jsonb_build_object('source', 'candidate_target_payload')
    );

    PERFORM set_candidate_status(
        p_candidate_id := v_candidate_id,
        p_status       := 'proposed',
        p_reason       := 'Candidate created',
        p_actor        := v_created_by
    );

    RETURN v_candidate_id;
END;
$$ LANGUAGE plpgsql;

-- Backfill candidate membership from the durable target payload. The existing
-- candidate-created event remains the membership source; unknown domains stay
-- visible in the gap view rather than being inferred.
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
        candidate.id,
        domain_row.id,
        nullif(trim(coalesce(candidate.properties->'target_payload'->>'source_scope', '')), ''),
        source_event.id,
        jsonb_build_object('source', 'candidate_target_payload_backfill'),
        candidate.created_at
    FROM nodes candidate
    CROSS JOIN LATERAL jsonb_array_elements_text(
        CASE
            WHEN jsonb_typeof(candidate.properties->'target_payload'->'domain_keys') = 'array'
                THEN candidate.properties->'target_payload'->'domain_keys'
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
        WHERE participant.node_id = candidate.id
          AND participant.role = 'candidate'
          AND event_row.event_type = 'knowledge_candidate_created'
        ORDER BY event_row.occurred_at, event_row.id
        LIMIT 1
    ) source_event ON true
    WHERE candidate.node_type = 'knowledge_candidate'
      AND candidate.archived_at IS NULL
      AND NOT EXISTS (
          SELECT 1
          FROM node_domain_memberships existing
          WHERE existing.node_id = candidate.id
            AND existing.domain_id = domain_row.id
            AND coalesce(existing.scope_ref, '') = coalesce(
                nullif(trim(coalesce(candidate.properties->'target_payload'->>'source_scope', '')), ''),
                ''
            )
            AND existing.effective_to IS NULL
      );
END;
$$;

CREATE OR REPLACE VIEW node_domain_membership_gaps
WITH (security_invoker = true) AS
SELECT
    'node:' || node_row.id::text AS gap_id,
    'unclassified_node'::text AS gap_type,
    'high'::text AS severity,
    node_row.id AS node_id,
    node_row.node_type,
    node_row.label,
    NULL::text AS domain_key,
    'Active node has no current domain membership.'::text AS reason
FROM nodes node_row
WHERE node_row.archived_at IS NULL
  AND NOT EXISTS (
      SELECT 1
      FROM node_domain_memberships membership
      WHERE membership.node_id = node_row.id
        AND membership.effective_at <= now()
        AND (membership.effective_to IS NULL OR membership.effective_to > now())
  )
UNION ALL
SELECT
    'candidate-domain:' || candidate.id::text || ':' || requested_domain.domain_key AS gap_id,
    'unknown_candidate_domain'::text AS gap_type,
    'high'::text AS severity,
    candidate.id AS node_id,
    candidate.node_type,
    candidate.label,
    requested_domain.domain_key,
    'Candidate target domain is unknown or lacks a matching membership.'::text AS reason
FROM nodes candidate
CROSS JOIN LATERAL jsonb_array_elements_text(
    CASE
        WHEN jsonb_typeof(candidate.properties->'target_payload'->'domain_keys') = 'array'
            THEN candidate.properties->'target_payload'->'domain_keys'
        ELSE '[]'::jsonb
    END
) requested_domain(domain_key)
LEFT JOIN knowledge_domains domain_row
  ON domain_row.domain_key = rye_slugify_key(requested_domain.domain_key)
 AND domain_row.archived_at IS NULL
WHERE candidate.node_type = 'knowledge_candidate'
  AND candidate.archived_at IS NULL
  AND (
      domain_row.id IS NULL
      OR NOT EXISTS (
          SELECT 1
          FROM node_domain_memberships membership
          WHERE membership.node_id = candidate.id
            AND membership.domain_id = domain_row.id
            AND membership.effective_at <= now()
            AND (membership.effective_to IS NULL OR membership.effective_to > now())
      )
  );

REVOKE ALL ON node_domain_memberships FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION assign_node_domain_membership(uuid, text, uuid, text, timestamptz, timestamptz, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION end_node_domain_membership(uuid, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION agent_can_read_node(uuid, uuid, timestamptz, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION attach_node_domain_memberships(uuid, text[], text, uuid, timestamptz, jsonb) FROM PUBLIC;
