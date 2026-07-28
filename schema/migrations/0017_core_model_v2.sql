-- Rye Core Model v2 lifecycle, evidence, registry, confidence, and views.

SET search_path = rye, pg_catalog, public;

DROP VIEW IF EXISTS active_disputes;
DROP FUNCTION IF EXISTS contest_assertion(uuid, jsonb, text, numeric, text, uuid, text);
DROP FUNCTION IF EXISTS resolve_dispute(uuid, text, text);
DROP FUNCTION IF EXISTS promote_candidate_to_assertion(
    uuid, uuid, text, text, jsonb, timestamptz, timestamptz, numeric, text
);

-- Final data-driven assertion visibility policy, including edge subjects and
-- assertion-level classification.
DROP POLICY IF EXISTS assertion_read_policy ON assertions;
CREATE POLICY assertion_read_policy ON assertions
    FOR SELECT
    USING (
        (
            (subject_node_id IS NOT NULL
             AND EXISTS (SELECT 1 FROM nodes WHERE id = assertions.subject_node_id))
            OR
            (subject_edge_id IS NOT NULL
             AND EXISTS (SELECT 1 FROM edges WHERE id = assertions.subject_edge_id))
        )
        AND (
            classification IS NULL
            OR classification = 'public'
            OR EXISTS (
                SELECT 1
                FROM role_classification_access rca
                WHERE rca.role_name = current_setting('app.current_role', true)
                  AND classification = ANY(rca.classifications)
            )
        )
        AND (
            NOT EXISTS (
                SELECT 1 FROM assertion_type_access ata
                WHERE ata.assertion_type = assertions.assertion_type
                  AND ata.operation = 'read'
            )
            OR EXISTS (
                SELECT 1 FROM assertion_type_access ata
                WHERE ata.assertion_type = assertions.assertion_type
                  AND ata.operation = 'read'
                  AND current_setting('app.current_role', true) = ANY(ata.allowed_roles)
            )
        )
    );

-- Digest narratives carry the digest classification in attrs. Enforce that
-- classification even when the artifact's source node is otherwise visible.
DROP POLICY IF EXISTS artifact_read_policy ON artifacts;
CREATE POLICY artifact_read_policy ON artifacts
    FOR SELECT
    USING (
        (
            source_node_id IS NULL
            OR EXISTS (SELECT 1 FROM nodes WHERE id = artifacts.source_node_id)
        )
        AND (
            attrs->>'classification' IS NULL
            OR attrs->>'classification' = 'public'
            OR EXISTS (
                SELECT 1
                FROM role_classification_access rca
                WHERE rca.role_name = current_setting('app.current_role', true)
                  AND attrs->>'classification' = ANY(rca.classifications)
            )
        )
    );

CREATE OR REPLACE FUNCTION supersede_assertion(
    p_old_assertion_id uuid,
    p_new_assertion_type text,
    p_new_subject_node_id uuid,
    p_new_subject_edge_id uuid,
    p_new_claim jsonb,
    p_new_assertion_key text DEFAULT NULL,
    p_new_effective_at timestamptz DEFAULT NULL,
    p_new_effective_to timestamptz DEFAULT NULL,
    p_new_confidence numeric DEFAULT NULL,
    p_new_basis text DEFAULT NULL,
    p_new_evidence jsonb[] DEFAULT NULL,
    p_new_attrs jsonb DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_evidence jsonb[];
    v_new_id uuid := gen_random_uuid();
    v_old assertions;
BEGIN
    PERFORM set_config('app.write_path', 'supersede_assertion', true);
    PERFORM set_config('app.supersede_assertion_id', p_old_assertion_id::text, true);

    SELECT * INTO v_old
    FROM assertions
    WHERE id = p_old_assertion_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Assertion % not found', p_old_assertion_id;
    END IF;
    IF v_old.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION 'Assertion % is already superseded', p_old_assertion_id;
    END IF;
    IF v_old.status <> 'accepted' THEN
        RAISE EXCEPTION 'Only accepted assertions may be superseded; reject candidates instead';
    END IF;
    IF coalesce(p_new_assertion_type, v_old.assertion_type) IS DISTINCT FROM v_old.assertion_type
       OR coalesce(nullif(trim(p_new_assertion_key), ''), v_old.assertion_key)
          IS DISTINCT FROM v_old.assertion_key
       OR coalesce(p_new_subject_node_id, v_old.subject_node_id)
          IS DISTINCT FROM v_old.subject_node_id
       OR coalesce(p_new_subject_edge_id, v_old.subject_edge_id)
          IS DISTINCT FROM v_old.subject_edge_id
    THEN
        RAISE EXCEPTION
            'Cross-tuple supersession is not allowed; subject, assertion_type, and assertion_key must match';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        v_old.subject_ref || ':' || v_old.assertion_type || ':' || v_old.assertion_key,
        0
    ));

    v_evidence := coalesce(
        p_new_evidence,
        ARRAY[jsonb_build_object(
            'kind', 'derivation',
            'source_assertion_id', v_old.id
        )]
    );

    PERFORM mark_assertion_superseded(v_old.id, v_new_id);

    INSERT INTO assertions (
        id,
        assertion_type,
        assertion_key,
        status,
        basis,
        classification,
        subject_node_id,
        subject_edge_id,
        claim,
        effective_at,
        effective_to,
        confidence,
        attrs
    ) VALUES (
        v_new_id,
        v_old.assertion_type,
        v_old.assertion_key,
        'accepted',
        coalesce(p_new_basis, v_old.basis),
        v_old.classification,
        v_old.subject_node_id,
        v_old.subject_edge_id,
        p_new_claim,
        coalesce(p_new_effective_at, v_old.effective_at),
        coalesce(p_new_effective_to, v_old.effective_to),
        coalesce(p_new_confidence, v_old.confidence),
        coalesce(p_new_attrs, v_old.attrs)
    );

    PERFORM append_assertion_evidence(v_new_id, v_evidence);
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.supersede_assertion_id', '', true);
    RETURN v_new_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.supersede_assertion_id', '', true);
    RAISE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION accept_assertion(
    p_assertion_id uuid,
    p_evidence jsonb[] DEFAULT NULL,
    p_reason text DEFAULT NULL,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_candidate assertions;
    v_event_id uuid;
    v_incumbent assertions;
    v_participant_ids uuid[];
    v_participant_roles text[];
BEGIN
    PERFORM set_config('app.write_path', 'accept_assertion', true);
    PERFORM set_config('app.accept_assertion_id', p_assertion_id::text, true);

    SELECT * INTO v_candidate
    FROM assertions
    WHERE id = p_assertion_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Candidate assertion % not found', p_assertion_id;
    END IF;
    IF v_candidate.status <> 'candidate' OR v_candidate.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION 'Assertion % is not a live candidate', p_assertion_id;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        v_candidate.subject_ref || ':' || v_candidate.assertion_type || ':' || v_candidate.assertion_key,
        0
    ));

    SELECT * INTO v_incumbent
    FROM current_valid_assertions
    WHERE subject_ref = v_candidate.subject_ref
      AND assertion_type = v_candidate.assertion_type
      AND assertion_key = v_candidate.assertion_key
    LIMIT 1;

    IF FOUND
       AND v_candidate.basis = 'inferred'
       AND v_incumbent.basis <> 'inferred'
    THEN
        RAISE EXCEPTION
            'Inferred candidate % cannot displace % accepted assertion %',
            p_assertion_id,
            v_incumbent.basis,
            v_incumbent.id;
    END IF;

    IF FOUND THEN
        PERFORM mark_assertion_superseded(v_incumbent.id, p_assertion_id);
    END IF;

    PERFORM append_assertion_evidence(p_assertion_id, p_evidence);

    PERFORM set_config('app.write_path', 'accept_assertion', true);
    PERFORM set_config('app.accept_assertion_id', p_assertion_id::text, true);
    UPDATE assertions SET status = 'accepted' WHERE id = p_assertion_id;
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.accept_assertion_id', '', true);

    IF v_candidate.subject_node_id IS NOT NULL THEN
        v_participant_ids := ARRAY[v_candidate.subject_node_id];
        v_participant_roles := ARRAY['subject'];
    ELSE
        SELECT ARRAY[source_id, target_id], ARRAY['edge_source', 'edge_target']
        INTO v_participant_ids, v_participant_roles
        FROM edges WHERE id = v_candidate.subject_edge_id;
    END IF;

    v_event_id := record_event(
        p_event_type := 'assertion_accepted',
        p_summary := format('Accepted candidate assertion %s/%s', v_candidate.assertion_type, v_candidate.assertion_key),
        p_properties := jsonb_build_object(
            'assertion_id', p_assertion_id,
            'displaced_assertion_id', v_incumbent.id,
            'reason', p_reason
        ),
        p_participant_ids := coalesce(v_participant_ids, '{}'::uuid[]),
        p_participant_roles := coalesce(v_participant_roles, '{}'::text[]),
        p_actor := p_actor
    );

    RETURN p_assertion_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.accept_assertion_id', '', true);
    RAISE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION reject_candidate(
    p_assertion_id uuid,
    p_reason text,
    p_actor text DEFAULT NULL
) RETURNS void
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_candidate assertions;
    v_participant_ids uuid[];
    v_participant_roles text[];
BEGIN
    IF nullif(trim(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'Candidate rejection reason is required';
    END IF;

    SELECT * INTO v_candidate
    FROM assertions
    WHERE id = p_assertion_id;
    IF NOT FOUND
       OR v_candidate.status <> 'candidate'
       OR v_candidate.superseded_at IS NOT NULL
    THEN
        RAISE EXCEPTION 'Assertion % is not a live candidate', p_assertion_id;
    END IF;

    PERFORM mark_assertion_superseded(p_assertion_id, NULL);

    IF v_candidate.subject_node_id IS NOT NULL THEN
        v_participant_ids := ARRAY[v_candidate.subject_node_id];
        v_participant_roles := ARRAY['subject'];
    ELSE
        SELECT ARRAY[source_id, target_id], ARRAY['edge_source', 'edge_target']
        INTO v_participant_ids, v_participant_roles
        FROM edges WHERE id = v_candidate.subject_edge_id;
    END IF;

    PERFORM record_event(
        p_event_type := 'candidate_rejected',
        p_summary := format('Rejected candidate assertion %s/%s', v_candidate.assertion_type, v_candidate.assertion_key),
        p_properties := jsonb_build_object('assertion_id', p_assertion_id, 'reason', p_reason),
        p_participant_ids := coalesce(v_participant_ids, '{}'::uuid[]),
        p_participant_roles := coalesce(v_participant_roles, '{}'::text[]),
        p_actor := p_actor
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION resolve_knowledge_gap(
    p_gap_assertion_id uuid,
    p_answer_assertion_id uuid,
    p_actor text DEFAULT NULL
) RETURNS void
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_answer assertions;
    v_gap assertions;
    v_new_id uuid;
BEGIN
    SELECT * INTO v_gap
    FROM current_valid_assertions
    WHERE id = p_gap_assertion_id
      AND assertion_type = 'knowledge_gap';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Open knowledge gap assertion % not found', p_gap_assertion_id;
    END IF;

    SELECT * INTO v_answer
    FROM current_valid_assertions
    WHERE id = p_answer_assertion_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Accepted answer assertion % not found', p_answer_assertion_id;
    END IF;

    v_new_id := supersede_assertion(
        p_old_assertion_id := v_gap.id,
        p_new_assertion_type := v_gap.assertion_type,
        p_new_subject_node_id := v_gap.subject_node_id,
        p_new_subject_edge_id := v_gap.subject_edge_id,
        p_new_claim := v_gap.claim || jsonb_build_object(
            'status', 'resolved',
            'resolved', true,
            'answer_assertion_id', v_answer.id,
            'resolved_at', now(),
            'resolved_by', coalesce(p_actor, current_setting('app.current_user_id', true))
        ),
        p_new_assertion_key := v_gap.assertion_key,
        p_new_basis := 'inferred',
        p_new_evidence := ARRAY[
            jsonb_build_object('kind', 'derivation', 'source_assertion_id', v_gap.id),
            jsonb_build_object('kind', 'derivation', 'source_assertion_id', v_answer.id)
        ],
        p_new_attrs := v_gap.attrs || jsonb_build_object('resolved_gap', true)
    );

    PERFORM record_event(
        p_event_type := 'knowledge_gap_resolved',
        p_summary := 'Knowledge gap resolved by accepted assertion',
        p_properties := jsonb_build_object(
            'gap_assertion_id', v_gap.id,
            'resolved_gap_assertion_id', v_new_id,
            'answer_assertion_id', v_answer.id
        ),
        p_participant_ids := CASE
            WHEN v_gap.subject_node_id IS NOT NULL THEN ARRAY[v_gap.subject_node_id]
            ELSE '{}'::uuid[]
        END,
        p_participant_roles := CASE
            WHEN v_gap.subject_node_id IS NOT NULL THEN ARRAY['subject']
            ELSE '{}'::text[]
        END,
        p_actor := p_actor
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Registry entries are accepted registry_entry assertions on a scope, plugin,
-- or the core registry node. Plugin ties resolve deterministically by plugin ID.
INSERT INTO nodes (node_type, label, external_id, external_source, properties, attrs)
VALUES (
    'registry',
    'Rye Core Registry',
    'core',
    'rye_registry',
    '{"layer":"core"}',
    '{"classification":"public"}'
)
ON CONFLICT (external_source, external_id)
    WHERE external_id IS NOT NULL AND archived_at IS NULL
DO NOTHING;

DO $$
DECLARE
    v_core_id uuid;
    v_entry record;
BEGIN
    SELECT id INTO v_core_id
    FROM nodes
    WHERE external_source = 'rye_registry'
      AND external_id = 'core'
      AND archived_at IS NULL;

    FOR v_entry IN
        SELECT * FROM (VALUES
            ('basis_prior:observed', '0.95'::jsonb),
            ('basis_prior:reported', '0.70'::jsonb),
            ('basis_prior:inferred', '0.60'::jsonb),
            ('basis_prior:assumed', '0.30'::jsonb),
            ('basis_prior:unknown', '0.50'::jsonb)
        ) AS defaults(key, value)
    LOOP
        PERFORM record_assertion(
            p_assertion_type := 'registry_entry',
            p_assertion_key := v_entry.key,
            p_subject_node_id := v_core_id,
            p_claim := jsonb_build_object('value', v_entry.value, 'layer', 'core'),
            p_basis := 'assumed',
            p_status := 'accepted',
            p_attrs := jsonb_build_object('registry_layer', 'core')
        );
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION registry_value(
    p_key text,
    p_scope uuid DEFAULT NULL
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_value jsonb;
BEGIN
    IF p_scope IS NOT NULL THEN
        SELECT a.claim->'value'
        INTO v_value
        FROM current_valid_assertions a
        WHERE a.subject_node_id = p_scope
          AND a.assertion_type = 'registry_entry'
          AND a.assertion_key = p_key
        ORDER BY a.asserted_at DESC
        LIMIT 1;
        IF FOUND THEN
            RETURN v_value;
        END IF;

        SELECT a.claim->'value'
        INTO v_value
        FROM edges enabled
        JOIN nodes plugin ON plugin.id = enabled.target_id
        JOIN current_valid_assertions a ON a.subject_node_id = plugin.id
        WHERE enabled.source_id = p_scope
          AND enabled.edge_type = 'scope_enables_plugin'
          AND enabled.archived_at IS NULL
          AND plugin.archived_at IS NULL
          AND a.assertion_type = 'registry_entry'
          AND a.assertion_key = p_key
        ORDER BY plugin.external_id NULLS LAST, plugin.id, a.asserted_at DESC, a.id
        LIMIT 1;
        IF FOUND THEN
            RETURN v_value;
        END IF;
    END IF;

    SELECT a.claim->'value'
    INTO v_value
    FROM nodes core
    JOIN current_valid_assertions a ON a.subject_node_id = core.id
    WHERE core.external_source = 'rye_registry'
      AND core.external_id = 'core'
      AND core.archived_at IS NULL
      AND a.assertion_type = 'registry_entry'
      AND a.assertion_key = p_key
    ORDER BY a.asserted_at DESC
    LIMIT 1;

    RETURN v_value;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION record_distillation(
    p_subject_node_id uuid,
    p_subject_edge_id uuid,
    p_assertion_key text,
    p_claim jsonb,
    p_source_assertion_ids uuid[],
    p_source_event_ids uuid[],
    p_status text DEFAULT 'accepted',
    p_agent text DEFAULT NULL,
    p_scope_node_id uuid DEFAULT NULL,
    p_confidence numeric DEFAULT NULL,
    p_attrs jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_catalog jsonb;
    v_event_id uuid;
    v_evidence jsonb[] := '{}'::jsonb[];
    v_id uuid;
    v_incumbent assertions;
    v_key text := coalesce(nullif(trim(p_assertion_key), ''), 'default');
    v_new_id uuid := gen_random_uuid();
    v_node_type text;
    v_participant_ids uuid[];
    v_participant_roles text[];
    v_status text := lower(coalesce(nullif(trim(p_status), ''), 'accepted'));
    v_subject_ref text;
    v_watermark timestamptz;
BEGIN
    IF (p_subject_node_id IS NULL) = (p_subject_edge_id IS NULL) THEN
        RAISE EXCEPTION 'Exactly one distillation subject is required';
    END IF;
    IF cardinality(coalesce(p_source_assertion_ids, '{}'::uuid[])) = 0 THEN
        RAISE EXCEPTION 'record_distillation requires at least one source assertion';
    END IF;
    IF v_status NOT IN ('candidate', 'accepted') THEN
        RAISE EXCEPTION 'Unsupported distillation status: %', p_status;
    END IF;

    SELECT max(asserted_at)
    INTO v_watermark
    FROM assertions
    WHERE id = ANY(p_source_assertion_ids);

    IF v_watermark IS NULL
       OR (SELECT count(*) FROM assertions WHERE id = ANY(p_source_assertion_ids))
          <> cardinality(p_source_assertion_ids)
    THEN
        RAISE EXCEPTION 'Every distillation source assertion must exist and be visible';
    END IF;

    IF p_subject_node_id IS NOT NULL THEN
        SELECT node_type INTO v_node_type FROM nodes WHERE id = p_subject_node_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Distillation subject node % not found', p_subject_node_id;
        END IF;
        v_catalog := registry_value('digest_facets:' || v_node_type, p_scope_node_id);
        IF v_catalog IS NOT NULL
           AND NOT (
               (jsonb_typeof(v_catalog) = 'array' AND v_catalog ? v_key)
               OR
               (jsonb_typeof(v_catalog) = 'object' AND v_catalog ? v_key)
           )
        THEN
            RAISE EXCEPTION 'Digest facet % is not registered for node type %', v_key, v_node_type;
        END IF;
        v_participant_ids := ARRAY[p_subject_node_id];
        v_participant_roles := ARRAY['subject'];
    ELSE
        SELECT ARRAY[source_id, target_id], ARRAY['edge_source', 'edge_target']
        INTO v_participant_ids, v_participant_roles
        FROM edges WHERE id = p_subject_edge_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Distillation subject edge % not found', p_subject_edge_id;
        END IF;
    END IF;

    -- Validate classification and access-population intersection before any
    -- lifecycle mutation.
    PERFORM derived_assertion_classification(p_source_assertion_ids);

    v_subject_ref := coalesce(
        'n:' || p_subject_node_id::text,
        'e:' || p_subject_edge_id::text
    );
    PERFORM pg_advisory_xact_lock(hashtextextended(
        v_subject_ref || ':digest:' || v_key,
        0
    ));

    v_event_id := record_event(
        p_event_type := 'distillation',
        p_summary := format('Distilled %s source assertions into digest %s', cardinality(p_source_assertion_ids), v_key),
        p_properties := jsonb_build_object(
            'digest_assertion_id', v_new_id,
            'subject_edge_id', p_subject_edge_id,
            'source_assertion_ids', to_jsonb(p_source_assertion_ids),
            'source_event_ids', to_jsonb(coalesce(p_source_event_ids, '{}'::uuid[])),
            'watermark', v_watermark
        ),
        p_participant_ids := v_participant_ids,
        p_participant_roles := v_participant_roles,
        p_actor := p_agent
    );

    v_evidence := array_append(v_evidence, jsonb_build_object(
        'kind', 'source',
        'event_id', v_event_id,
        'attrs', jsonb_build_object('role', 'distillation_record')
    ));
    FOREACH v_id IN ARRAY p_source_assertion_ids LOOP
        v_evidence := array_append(v_evidence, jsonb_build_object(
            'kind', 'derivation',
            'source_assertion_id', v_id
        ));
    END LOOP;
    FOREACH v_id IN ARRAY coalesce(p_source_event_ids, '{}'::uuid[]) LOOP
        v_evidence := array_append(v_evidence, jsonb_build_object(
            'kind', 'source',
            'event_id', v_id
        ));
    END LOOP;

    IF v_status = 'accepted' THEN
        SELECT * INTO v_incumbent
        FROM current_valid_assertions
        WHERE subject_ref = v_subject_ref
          AND assertion_type = 'digest'
          AND assertion_key = v_key
        LIMIT 1;
        IF FOUND THEN
            PERFORM mark_assertion_superseded(v_incumbent.id, v_new_id);
        END IF;
    END IF;

    INSERT INTO assertions (
        id,
        assertion_type,
        assertion_key,
        status,
        basis,
        subject_node_id,
        subject_edge_id,
        claim,
        confidence,
        attrs
    ) VALUES (
        v_new_id,
        'digest',
        v_key,
        v_status,
        'inferred',
        p_subject_node_id,
        p_subject_edge_id,
        p_claim,
        p_confidence,
        coalesce(p_attrs, '{}'::jsonb) || jsonb_build_object(
            'watermark', v_watermark,
            'distillation_event_id', v_event_id,
            'agent', p_agent
        )
    );
    PERFORM append_assertion_evidence(v_new_id, v_evidence);
    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION effective_confidence(a assertions)
RETURNS numeric
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_age_seconds numeric;
    v_base numeric;
    v_competitors int;
    v_discount numeric;
    v_half_life interval;
    v_half_life_json jsonb;
    v_independent int;
    v_lift numeric;
    v_newest_support timestamptz;
    v_result numeric;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM current_valid_assertions c WHERE c.id = a.id) THEN
        RETURN NULL;
    END IF;

    v_base := coalesce(
        a.confidence,
        (registry_value('basis_prior:' || a.basis, NULL) #>> '{}')::numeric,
        0.50
    );

    SELECT count(DISTINCT witness_node_id)
    INTO v_independent
    FROM assertion_evidence
    WHERE assertion_id = a.id
      AND kind IN ('source', 'corroboration')
      AND witness_node_id IS NOT NULL;
    v_lift := 1 + 0.1 * least(v_independent, 3);

    SELECT max(recorded_at)
    INTO v_newest_support
    FROM assertion_evidence
    WHERE assertion_id = a.id
      AND kind = 'corroboration'
      AND coalesce((attrs->>'independent')::boolean, false);

    v_half_life_json := registry_value('half_life:' || a.assertion_type, NULL);
    IF v_half_life_json IS NOT NULL AND jsonb_typeof(v_half_life_json) <> 'null' THEN
        v_half_life := (v_half_life_json #>> '{}')::interval;
    END IF;

    SELECT count(*)
    INTO v_competitors
    FROM assertions candidate
    WHERE candidate.subject_ref = a.subject_ref
      AND candidate.assertion_type = a.assertion_type
      AND candidate.assertion_key = a.assertion_key
      AND candidate.status = 'candidate'
      AND candidate.superseded_at IS NULL;
    v_discount := greatest(0.5, power(0.8::numeric, v_competitors));

    IF v_half_life IS NULL THEN
        v_result := v_base * v_lift * v_discount;
    ELSE
        v_age_seconds := greatest(
            extract(epoch FROM (now() - greatest(a.asserted_at, coalesce(v_newest_support, a.asserted_at)))),
            0
        );
        v_result := v_base
            * v_lift
            * power(2::numeric, -(v_age_seconds / extract(epoch FROM v_half_life)))
            * v_discount;
    END IF;

    RETURN least(1::numeric, greatest(0::numeric, v_result));
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE VIEW current_assertions_weighted
WITH (security_invoker = true) AS
SELECT a.*, effective_confidence(ROW(a.*)::assertions) AS effective_confidence
FROM current_valid_assertions a;

CREATE OR REPLACE VIEW review_queue
WITH (security_invoker = true) AS
SELECT
    a.subject_ref,
    a.subject_node_id,
    a.subject_edge_id,
    a.assertion_type,
    a.assertion_key,
    count(*) AS candidate_count,
    jsonb_agg(
        jsonb_build_object(
            'assertion_id', a.id,
            'claim', a.claim,
            'basis', a.basis,
            'confidence', a.confidence,
            'classification', a.classification,
            'asserted_at', a.asserted_at,
            'attrs', a.attrs
        )
        ORDER BY a.asserted_at, a.id
    ) AS candidates
FROM assertions a
WHERE a.status = 'candidate'
  AND a.superseded_at IS NULL
GROUP BY
    a.subject_ref,
    a.subject_node_id,
    a.subject_edge_id,
    a.assertion_type,
    a.assertion_key;

CREATE OR REPLACE VIEW competing_candidates
WITH (security_invoker = true) AS
SELECT *
FROM review_queue
WHERE candidate_count > 1;

CREATE OR REPLACE VIEW stale_digests
WITH (security_invoker = true) AS
SELECT
    digest.id AS digest_assertion_id,
    digest.subject_ref,
    digest.subject_node_id,
    digest.subject_edge_id,
    digest.assertion_key,
    (digest.attrs->>'watermark')::timestamptz AS watermark,
    EXISTS (
        SELECT 1
        FROM current_valid_assertions newer
        WHERE newer.subject_ref = digest.subject_ref
          AND newer.assertion_type <> 'digest'
          AND newer.asserted_at > (digest.attrs->>'watermark')::timestamptz
    ) AS newer_subject_assertion,
    EXISTS (
        SELECT 1
        FROM assertion_evidence ae
        JOIN assertions source ON source.id = ae.source_assertion_id
        WHERE ae.assertion_id = digest.id
          AND ae.kind = 'derivation'
          AND (
              source.superseded_at IS NOT NULL
              OR (
                  NOT EXISTS (
                      SELECT 1 FROM current_valid_assertions current_source
                      WHERE current_source.id = source.id
                  )
                  AND EXISTS (
                      SELECT 1 FROM current_valid_assertions replacement
                      WHERE replacement.subject_ref = source.subject_ref
                        AND replacement.assertion_type = source.assertion_type
                        AND replacement.assertion_key = source.assertion_key
                        AND replacement.id <> source.id
                  )
              )
          )
    ) AS overturned_source
FROM current_valid_assertions digest
WHERE digest.assertion_type = 'digest'
  AND digest.attrs ? 'watermark'
  AND (
      EXISTS (
          SELECT 1
          FROM current_valid_assertions newer
          WHERE newer.subject_ref = digest.subject_ref
            AND newer.assertion_type <> 'digest'
            AND newer.asserted_at > (digest.attrs->>'watermark')::timestamptz
      )
      OR EXISTS (
          SELECT 1
          FROM assertion_evidence ae
          JOIN assertions source ON source.id = ae.source_assertion_id
          WHERE ae.assertion_id = digest.id
            AND ae.kind = 'derivation'
            AND (
                source.superseded_at IS NOT NULL
                OR (
                    NOT EXISTS (
                        SELECT 1 FROM current_valid_assertions current_source
                        WHERE current_source.id = source.id
                    )
                    AND EXISTS (
                        SELECT 1 FROM current_valid_assertions replacement
                        WHERE replacement.subject_ref = source.subject_ref
                          AND replacement.assertion_type = source.assertion_type
                          AND replacement.assertion_key = source.assertion_key
                          AND replacement.id <> source.id
                    )
                )
            )
      )
  );

CREATE OR REPLACE VIEW open_gaps
WITH (security_invoker = true) AS
SELECT *
FROM current_valid_assertions
WHERE assertion_type = 'knowledge_gap'
  AND coalesce((claim->>'resolved')::boolean, false) = false
  AND coalesce(claim->>'status', 'open') <> 'resolved';

CREATE OR REPLACE VIEW assertion_support
WITH (security_invoker = true) AS
SELECT
    a.id AS assertion_id,
    coalesce((
        SELECT jsonb_agg(
            jsonb_build_object(
                'evidence_id', ae.id,
                'kind', ae.kind,
                'event_id', ae.event_id,
                'source_assertion_id', ae.source_assertion_id,
                'witness_node_id', ae.witness_node_id,
                'recorded_at', ae.recorded_at,
                'attrs', ae.attrs
            )
            ORDER BY ae.recorded_at, ae.id
        )
        FROM assertion_evidence ae
        WHERE ae.assertion_id = a.id
    ), '[]'::jsonb) AS evidence,
    coalesce((
        SELECT jsonb_agg(
            jsonb_build_object(
                'assertion_id', derived.id,
                'assertion_type', derived.assertion_type,
                'assertion_key', derived.assertion_key,
                'status', derived.status
            )
            ORDER BY derived.asserted_at, derived.id
        )
        FROM assertion_evidence ae
        JOIN assertions derived ON derived.id = ae.assertion_id
        WHERE ae.source_assertion_id = a.id
    ), '[]'::jsonb) AS derived_by
FROM assertions a;

CREATE OR REPLACE VIEW node_context
WITH (security_invoker = true) AS
SELECT
    n.id AS node_id,
    n.node_type,
    n.label,
    n.properties,
    (
        SELECT coalesce(json_agg(jsonb_build_object(
            'edge_id', eo.id,
            'edge_type', eo.edge_type,
            'target_id', eo.target_id,
            'properties', eo.properties
        )), '[]'::json)
        FROM edges eo
        WHERE eo.source_id = n.id AND eo.archived_at IS NULL
    ) AS outbound_edges,
    (
        SELECT coalesce(json_agg(jsonb_build_object(
            'edge_id', ei.id,
            'edge_type', ei.edge_type,
            'source_id', ei.source_id,
            'properties', ei.properties
        )), '[]'::json)
        FROM edges ei
        WHERE ei.target_id = n.id AND ei.archived_at IS NULL
    ) AS inbound_edges,
    (
        SELECT coalesce(json_agg(jsonb_build_object(
            'assertion_id', a.id,
            'assertion_type', a.assertion_type,
            'assertion_key', a.assertion_key,
            'claim', a.claim,
            'basis', a.basis,
            'asserted_at', a.asserted_at,
            'confidence', a.confidence
        )), '[]'::json)
        FROM current_valid_assertions a
        WHERE a.subject_node_id = n.id
    ) AS current_assertions
FROM nodes n
WHERE n.archived_at IS NULL;

CREATE OR REPLACE FUNCTION agent_node_summary(
    p_node_id uuid,
    p_max_items int DEFAULT 10
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
SELECT jsonb_build_object(
    'node', (SELECT row_to_json(n) FROM nodes n WHERE n.id = p_node_id),
    'top_relationships', (
        SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
        FROM (
            SELECT e.edge_type, 'outbound' AS direction, e.properties, e.weight,
                   nt.label AS related_label, nt.node_type AS related_type, nt.id AS related_id
            FROM edges e
            JOIN nodes nt ON nt.id = e.target_id
            WHERE e.source_id = p_node_id AND e.archived_at IS NULL
            UNION ALL
            SELECT e.edge_type, 'inbound', e.properties, e.weight,
                   ns.label, ns.node_type, ns.id
            FROM edges e
            JOIN nodes ns ON ns.id = e.source_id
            WHERE e.target_id = p_node_id AND e.archived_at IS NULL
            ORDER BY weight DESC NULLS LAST
            LIMIT greatest(p_max_items, 0)
        ) r
    ),
    'current_facts', (
        SELECT coalesce(jsonb_agg(to_jsonb(f) ORDER BY f.digest_rank, f.asserted_at DESC), '[]'::jsonb)
        FROM (
            SELECT
                a.assertion_type,
                a.assertion_key,
                a.claim,
                a.confidence,
                a.basis,
                a.asserted_at,
                true AS derived,
                (a.attrs->>'watermark')::timestamptz AS as_of,
                0 AS digest_rank
            FROM current_valid_assertions a
            WHERE a.subject_node_id = p_node_id
              AND a.assertion_type = 'digest'
            UNION ALL
            SELECT
                a.assertion_type,
                a.assertion_key,
                a.claim,
                a.confidence,
                a.basis,
                a.asserted_at,
                false AS derived,
                NULL::timestamptz AS as_of,
                1 AS digest_rank
            FROM current_valid_assertions a
            WHERE a.subject_node_id = p_node_id
              AND a.assertion_type <> 'digest'
              AND NOT EXISTS (
                  SELECT 1
                  FROM current_valid_assertions digest
                  JOIN assertion_evidence ae ON ae.assertion_id = digest.id
                  WHERE digest.subject_node_id = p_node_id
                    AND digest.assertion_type = 'digest'
                    AND ae.kind = 'derivation'
                    AND ae.source_assertion_id = a.id
              )
            ORDER BY digest_rank, asserted_at DESC
            LIMIT greatest(p_max_items, 0)
        ) f
    ),
    'recent_activity', (
        SELECT coalesce(jsonb_agg(to_jsonb(ev)), '[]'::jsonb)
        FROM (
            SELECT e.event_type, e.summary, e.occurred_at, ep.role
            FROM events e
            JOIN event_participants ep ON ep.event_id = e.id
            WHERE ep.node_id = p_node_id
            ORDER BY e.occurred_at DESC
            LIMIT greatest(p_max_items, 0)
        ) ev
    )
);
$$ LANGUAGE sql STABLE;
