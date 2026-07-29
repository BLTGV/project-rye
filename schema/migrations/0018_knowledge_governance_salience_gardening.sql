-- Knowledge mechanisms v2: scope governance, salience, and vocabulary gardening.

SET search_path = rye, pg_catalog, public;

-- --------------------------------------------------------------------------
-- Type aliases
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION canonical_type_in_scope(
    p_kind text,
    p_value text,
    p_scope uuid DEFAULT NULL
) RETURNS text
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_current text := nullif(trim(p_value), '');
    v_kind text := lower(nullif(trim(p_kind), ''));
    v_next_json jsonb;
    v_next text;
    v_seen text[] := '{}'::text[];
BEGIN
    IF v_kind NOT IN ('node_type', 'edge_type', 'assertion_type') THEN
        RAISE EXCEPTION 'Unsupported type kind: %', p_kind;
    END IF;
    IF v_current IS NULL THEN
        RAISE EXCEPTION 'type value is required';
    END IF;

    LOOP
        IF v_current = ANY(v_seen) THEN
            RAISE EXCEPTION 'Type alias cycle detected for %:%', v_kind, array_to_string(v_seen || v_current, ' -> ');
        END IF;
        v_seen := array_append(v_seen, v_current);

        v_next_json := registry_value('type_alias:' || v_kind || ':' || v_current, p_scope);
        EXIT WHEN v_next_json IS NULL OR jsonb_typeof(v_next_json) = 'null';

        v_next := nullif(trim(v_next_json #>> '{}'), '');
        IF v_next IS NULL THEN
            RAISE EXCEPTION 'Type alias %:% has an empty canonical value', v_kind, v_current;
        END IF;
        v_current := v_next;

        IF cardinality(v_seen) > 64 THEN
            RAISE EXCEPTION 'Type alias chain exceeds 64 entries for %:%', v_kind, p_value;
        END IF;
    END LOOP;

    RETURN v_current;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION canonical_type(
    p_kind text,
    p_value text
) RETURNS text
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_default jsonb;
    v_scope uuid;
BEGIN
    v_default := registry_value('DEFAULT_SCOPE', NULL);
    IF v_default IS NOT NULL AND jsonb_typeof(v_default) <> 'null' THEN
        BEGIN
            v_scope := (v_default #>> '{}')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'DEFAULT_SCOPE registry value must be a scope UUID';
        END;
    END IF;
    RETURN canonical_type_in_scope(p_kind, p_value, v_scope);
END;
$$ LANGUAGE plpgsql STABLE;

-- Normalize all newly inserted graph vocabulary. Existing rows are never
-- rewritten, so historical spellings remain queryable and auditable.
CREATE OR REPLACE FUNCTION normalize_graph_type_on_insert()
RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
BEGIN
    IF TG_TABLE_NAME = 'nodes' THEN
        NEW.node_type := canonical_type('node_type', NEW.node_type);
    ELSIF TG_TABLE_NAME = 'edges' THEN
        NEW.edge_type := canonical_type('edge_type', NEW.edge_type);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_nodes_canonical_type ON nodes;
CREATE TRIGGER trg_nodes_canonical_type
    BEFORE INSERT ON nodes
    FOR EACH ROW EXECUTE FUNCTION normalize_graph_type_on_insert();

DROP TRIGGER IF EXISTS trg_edges_canonical_type ON edges;
CREATE TRIGGER trg_edges_canonical_type
    BEFORE INSERT ON edges
    FOR EACH ROW EXECUTE FUNCTION normalize_graph_type_on_insert();

CREATE OR REPLACE VIEW type_vocabulary_report
WITH (security_invoker = true) AS
WITH vocabulary AS (
    SELECT
        'node_type'::text AS kind,
        n.node_type AS type_value,
        count(*)::bigint AS usage_count,
        min(n.created_at) AS first_seen,
        max(n.created_at) AS last_seen
    FROM nodes n
    GROUP BY n.node_type
    UNION ALL
    SELECT
        'edge_type'::text,
        e.edge_type,
        count(*)::bigint,
        min(e.created_at),
        max(e.created_at)
    FROM edges e
    GROUP BY e.edge_type
    UNION ALL
    SELECT
        'assertion_type'::text,
        a.assertion_type,
        count(*)::bigint,
        min(a.asserted_at),
        max(a.asserted_at)
    FROM assertions a
    GROUP BY a.assertion_type
)
SELECT
    v.kind,
    v.type_value,
    v.usage_count,
    v.first_seen,
    v.last_seen,
    CASE
        WHEN canonical_type(v.kind, v.type_value) = v.type_value THEN NULL
        ELSE canonical_type(v.kind, v.type_value)
    END AS canonical_value
FROM vocabulary v;

COMMENT ON VIEW type_vocabulary_report IS
    'Historical graph vocabulary with usage dates and read-side canonical aliases; existing rows retain their stored spelling.';

-- --------------------------------------------------------------------------
-- Scope governance
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION governing_scope(
    p_subject_node_id uuid,
    p_subject_edge_id uuid,
    p_assertion_type text,
    p_witness_node_id uuid
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_type text := canonical_type('assertion_type', p_assertion_type);
    v_count int;
    v_default jsonb;
    v_scope uuid;
BEGIN
    IF (p_subject_node_id IS NULL) = (p_subject_edge_id IS NULL) THEN
        RAISE EXCEPTION 'Exactly one governing-scope subject is required';
    END IF;

    -- Direct subject coverage. Edge subjects use source endpoint before target.
    WITH subject_nodes AS (
        SELECT p_subject_node_id AS node_id, 0 AS endpoint_priority
        WHERE p_subject_node_id IS NOT NULL
        UNION ALL
        SELECT e.source_id, 0 FROM edges e WHERE e.id = p_subject_edge_id
        UNION ALL
        SELECT e.target_id, 1 FROM edges e WHERE e.id = p_subject_edge_id
    )
    SELECT coverage.source_id
    INTO v_scope
    FROM subject_nodes subject
    JOIN edges coverage
      ON coverage.target_id = subject.node_id
     AND coverage.edge_type = 'scope_governs_subject'
     AND coverage.archived_at IS NULL
     AND (coverage.effective_from IS NULL OR coverage.effective_from <= now())
     AND (coverage.effective_to IS NULL OR coverage.effective_to > now())
    JOIN nodes scope ON scope.id = coverage.source_id
    WHERE scope.node_type = 'onboarding_scope'
      AND scope.archived_at IS NULL
      AND EXISTS (
          SELECT 1 FROM current_valid_assertions status
          WHERE status.subject_node_id = scope.id
            AND status.assertion_type = 'scope_status'
            AND status.claim->>'status' = 'active'
      )
    ORDER BY subject.endpoint_priority, scope.id
    LIMIT 1;
    IF v_scope IS NOT NULL THEN
        RETURN v_scope;
    END IF;

    -- A governed process/project also governs its immediate has_step children.
    WITH subject_nodes AS (
        SELECT p_subject_node_id AS node_id, 0 AS endpoint_priority
        WHERE p_subject_node_id IS NOT NULL
        UNION ALL
        SELECT e.source_id, 0 FROM edges e WHERE e.id = p_subject_edge_id
        UNION ALL
        SELECT e.target_id, 1 FROM edges e WHERE e.id = p_subject_edge_id
    )
    SELECT coverage.source_id
    INTO v_scope
    FROM subject_nodes subject
    JOIN edges step
      ON step.target_id = subject.node_id
     AND step.edge_type = 'has_step'
     AND step.archived_at IS NULL
     AND (step.effective_from IS NULL OR step.effective_from <= now())
     AND (step.effective_to IS NULL OR step.effective_to > now())
    JOIN edges coverage
      ON coverage.target_id = step.source_id
     AND coverage.edge_type = 'scope_governs_subject'
     AND coverage.archived_at IS NULL
     AND (coverage.effective_from IS NULL OR coverage.effective_from <= now())
     AND (coverage.effective_to IS NULL OR coverage.effective_to > now())
    JOIN nodes scope ON scope.id = coverage.source_id
    WHERE scope.node_type = 'onboarding_scope'
      AND scope.archived_at IS NULL
      AND EXISTS (
          SELECT 1 FROM current_valid_assertions status
          WHERE status.subject_node_id = scope.id
            AND status.assertion_type = 'scope_status'
            AND status.claim->>'status' = 'active'
      )
    ORDER BY subject.endpoint_priority, scope.id
    LIMIT 1;
    IF v_scope IS NOT NULL THEN
        RETURN v_scope;
    END IF;

    -- Type coverage is intentionally strict: multiple active claims are an
    -- administrative ambiguity and must fail at write time.
    SELECT count(DISTINCT scope.id), min(scope.id)
    INTO v_count, v_scope
    FROM nodes scope
    JOIN current_valid_assertions status
      ON status.subject_node_id = scope.id
     AND status.assertion_type = 'scope_status'
     AND status.claim->>'status' = 'active'
    JOIN current_valid_assertions governed
      ON governed.subject_node_id = scope.id
     AND governed.assertion_type = 'registry_entry'
     AND governed.assertion_key = 'governed_type:' || v_assertion_type
    WHERE scope.node_type = 'onboarding_scope'
      AND scope.archived_at IS NULL;

    IF v_count > 1 THEN
        RAISE EXCEPTION 'Ambiguous governing scope for assertion type %: % active scopes claim it', v_assertion_type, v_count;
    ELSIF v_count = 1 THEN
        RETURN v_scope;
    END IF;

    -- Source coverage via the primary witness.
    IF p_witness_node_id IS NOT NULL THEN
        SELECT scope.id
        INTO v_scope
        FROM edges coverage
        JOIN nodes scope ON scope.id = coverage.source_id
        WHERE coverage.edge_type = 'scope_governs_source'
          AND coverage.target_id = p_witness_node_id
          AND coverage.archived_at IS NULL
          AND (coverage.effective_from IS NULL OR coverage.effective_from <= now())
          AND (coverage.effective_to IS NULL OR coverage.effective_to > now())
          AND scope.node_type = 'onboarding_scope'
          AND scope.archived_at IS NULL
          AND EXISTS (
              SELECT 1 FROM current_valid_assertions status
              WHERE status.subject_node_id = scope.id
                AND status.assertion_type = 'scope_status'
                AND status.claim->>'status' = 'active'
          )
        ORDER BY scope.id
        LIMIT 1;
        IF v_scope IS NOT NULL THEN
            RETURN v_scope;
        END IF;
    END IF;

    v_default := registry_value('DEFAULT_SCOPE', NULL);
    IF v_default IS NOT NULL AND jsonb_typeof(v_default) <> 'null' THEN
        BEGIN
            v_scope := (v_default #>> '{}')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'DEFAULT_SCOPE registry value must be a scope UUID';
        END;

        IF EXISTS (
            SELECT 1 FROM nodes scope
            WHERE scope.id = v_scope
              AND scope.node_type = 'onboarding_scope'
              AND scope.archived_at IS NULL
              AND EXISTS (
                  SELECT 1 FROM current_valid_assertions status
                  WHERE status.subject_node_id = scope.id
                    AND status.assertion_type = 'scope_status'
                    AND status.claim->>'status' = 'active'
              )
        ) THEN
            RETURN v_scope;
        END IF;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION scope_review_policy(p_scope_id uuid)
RETURNS text
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_policy text;
BEGIN
    IF p_scope_id IS NULL THEN
        RETURN 'open';
    END IF;

    SELECT lower(coalesce(
        nullif(a.claim->>'review_policy', ''),
        nullif(a.claim->>'value', ''),
        CASE WHEN jsonb_typeof(a.claim) = 'string' THEN a.claim #>> '{}' END,
        'open'
    ))
    INTO v_policy
    FROM current_valid_assertions a
    WHERE a.subject_node_id = p_scope_id
      AND a.assertion_type = 'review_policy'
      AND a.assertion_key = 'default'
    ORDER BY a.asserted_at DESC, a.id
    LIMIT 1;

    v_policy := coalesce(v_policy, 'open');
    IF v_policy NOT IN ('open', 'candidates_only', 'strict') THEN
        RAISE EXCEPTION 'Unsupported review_policy % on scope %', v_policy, p_scope_id;
    END IF;
    RETURN v_policy;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION compile_scope_policy(
    p_scope_id uuid
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM nodes
        WHERE id = p_scope_id
          AND node_type = 'onboarding_scope'
          AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Onboarding scope % not found', p_scope_id;
    END IF;

    RETURN jsonb_build_object(
        'scope_id', p_scope_id,
        'scope', (SELECT to_jsonb(n) FROM nodes n WHERE n.id = p_scope_id),
        'review_policy', scope_review_policy(p_scope_id),
        'assertions', (
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                'assertion_id', a.id,
                'assertion_type', a.assertion_type,
                'assertion_key', a.assertion_key,
                'claim', a.claim,
                'confidence', a.confidence,
                'asserted_at', a.asserted_at
            ) ORDER BY a.assertion_type, a.assertion_key), '[]'::jsonb)
            FROM current_valid_assertions a
            WHERE a.subject_node_id = p_scope_id
        ),
        'enabled_plugins', (
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                'plugin_node_id', p.id,
                'plugin_id', p.external_id,
                'label', p.label,
                'manifest', p.properties->'manifest'
            ) ORDER BY p.external_id), '[]'::jsonb)
            FROM edges e
            JOIN nodes p ON p.id = e.target_id
            WHERE e.source_id = p_scope_id
              AND e.edge_type = 'scope_enables_plugin'
              AND e.archived_at IS NULL
              AND p.archived_at IS NULL
        )
    );
END;
$$ LANGUAGE plpgsql STABLE;

-- Replace the v2 helper with an appended scope argument. Dropping by exact
-- signature preserves all callers while avoiding ambiguous defaulted overloads.
DROP FUNCTION record_assertion(
    text, jsonb, uuid, uuid, text, timestamptz, timestamptz,
    numeric, text, text, jsonb[], text, jsonb
);

CREATE FUNCTION record_assertion(
    p_assertion_type text,
    p_claim jsonb,
    p_subject_node_id uuid DEFAULT NULL,
    p_subject_edge_id uuid DEFAULT NULL,
    p_assertion_key text DEFAULT 'default',
    p_effective_at timestamptz DEFAULT NULL,
    p_effective_to timestamptz DEFAULT NULL,
    p_confidence numeric DEFAULT NULL,
    p_status text DEFAULT 'accepted',
    p_basis text DEFAULT 'unknown',
    p_evidence jsonb[] DEFAULT NULL,
    p_classification text DEFAULT NULL,
    p_attrs jsonb DEFAULT '{}'::jsonb,
    p_scope_node_id uuid DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_type text;
    v_existing assertions;
    v_key text := coalesce(nullif(trim(p_assertion_key), ''), 'default');
    v_new_effective_to timestamptz := p_effective_to;
    v_new_id uuid := gen_random_uuid();
    v_next_future_at timestamptz;
    v_policy text;
    v_resolved_scope uuid;
    v_status text := lower(coalesce(nullif(trim(p_status), ''), 'accepted'));
    v_basis text := lower(coalesce(nullif(trim(p_basis), ''), 'unknown'));
    v_subject_ref text;
    v_witness uuid;
BEGIN
    IF (p_subject_node_id IS NULL) = (p_subject_edge_id IS NULL) THEN
        RAISE EXCEPTION 'Exactly one of subject_node_id or subject_edge_id is required';
    END IF;
    IF nullif(trim(p_assertion_type), '') IS NULL THEN
        RAISE EXCEPTION 'assertion_type is required';
    END IF;
    v_assertion_type := canonical_type_in_scope('assertion_type', p_assertion_type, p_scope_node_id);
    IF p_claim IS NULL THEN
        RAISE EXCEPTION 'claim is required';
    END IF;
    IF v_status NOT IN ('candidate', 'accepted') THEN
        RAISE EXCEPTION 'Unsupported assertion status: %', p_status;
    END IF;
    IF v_basis NOT IN ('observed', 'reported', 'inferred', 'assumed', 'unknown') THEN
        RAISE EXCEPTION 'Unsupported assertion basis: %', p_basis;
    END IF;
    IF v_assertion_type = 'pattern_claim' AND v_status = 'accepted' THEN
        RAISE EXCEPTION 'pattern_claim assertions must be recorded as candidates and promoted with accept_assertion()';
    END IF;
    IF v_basis <> 'assumed'
       AND cardinality(coalesce(p_evidence, '{}'::jsonb[])) = 0
    THEN
        RAISE EXCEPTION 'Non-assumed assertions require evidence';
    END IF;
    IF p_effective_at IS NOT NULL
       AND p_effective_to IS NOT NULL
       AND p_effective_to <= p_effective_at
    THEN
        RAISE EXCEPTION 'effective_to must be after effective_at';
    END IF;

    SELECT nullif(evidence->>'witness_node_id', '')::uuid
    INTO v_witness
    FROM unnest(coalesce(p_evidence, '{}'::jsonb[])) WITH ORDINALITY item(evidence, ordinality)
    WHERE evidence->>'kind' IN ('source', 'corroboration')
      AND nullif(evidence->>'witness_node_id', '') IS NOT NULL
    ORDER BY ordinality
    LIMIT 1;

    v_resolved_scope := governing_scope(
        p_subject_node_id,
        p_subject_edge_id,
        v_assertion_type,
        v_witness
    );
    IF p_scope_node_id IS NOT NULL
       AND v_resolved_scope IS NOT NULL
       AND p_scope_node_id <> v_resolved_scope
    THEN
        RAISE EXCEPTION 'Explicit scope % does not match governing scope %', p_scope_node_id, v_resolved_scope;
    END IF;
    v_resolved_scope := coalesce(v_resolved_scope, p_scope_node_id);
    v_assertion_type := canonical_type_in_scope(
        'assertion_type', v_assertion_type, v_resolved_scope
    );
    IF v_assertion_type = 'pattern_claim' AND v_status = 'accepted' THEN
        RAISE EXCEPTION 'pattern_claim assertions must be recorded as candidates and promoted with accept_assertion()';
    END IF;
    v_policy := scope_review_policy(v_resolved_scope);
    IF v_status = 'accepted'
       AND (v_policy = 'strict' OR (v_policy = 'candidates_only' AND v_basis <> 'observed'))
    THEN
        v_status := 'candidate';
    END IF;

    v_subject_ref := coalesce('n:' || p_subject_node_id::text, 'e:' || p_subject_edge_id::text);

    IF v_status = 'accepted' THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(
            v_subject_ref || ':' || v_assertion_type || ':' || v_key, 0
        ));

        IF p_effective_at IS NOT NULL AND p_effective_at > now() THEN
            SELECT * INTO v_existing
            FROM assertions
            WHERE subject_ref = v_subject_ref
              AND assertion_type = v_assertion_type
              AND assertion_key = v_key
              AND status = 'accepted'
              AND superseded_at IS NULL
              AND effective_at IS NOT DISTINCT FROM p_effective_at
            LIMIT 1;

            IF FOUND
               AND v_existing.claim = p_claim
               AND v_existing.basis = v_basis
               AND v_existing.confidence IS NOT DISTINCT FROM p_confidence
            THEN
                PERFORM append_assertion_evidence(v_existing.id, p_evidence);
                RETURN v_existing.id;
            ELSIF FOUND THEN
                PERFORM mark_assertion_superseded(v_existing.id, v_new_id);
            END IF;

            SELECT min(effective_at) INTO v_next_future_at
            FROM assertions
            WHERE subject_ref = v_subject_ref
              AND assertion_type = v_assertion_type
              AND assertion_key = v_key
              AND status = 'accepted'
              AND superseded_at IS NULL
              AND effective_at > p_effective_at;

            IF v_next_future_at IS NOT NULL
               AND (v_new_effective_to IS NULL OR v_new_effective_to > v_next_future_at)
            THEN
                v_new_effective_to := v_next_future_at;
            END IF;

            SELECT * INTO v_existing
            FROM assertions
            WHERE subject_ref = v_subject_ref
              AND assertion_type = v_assertion_type
              AND assertion_key = v_key
              AND status = 'accepted'
              AND superseded_at IS NULL
              AND (effective_at IS NULL OR effective_at < p_effective_at)
              AND (effective_to IS NULL OR effective_to > p_effective_at)
            ORDER BY effective_at DESC NULLS LAST, asserted_at DESC
            LIMIT 1;

            IF FOUND AND (v_existing.effective_to IS NULL OR v_existing.effective_to > p_effective_at) THEN
                PERFORM set_config('app.write_path', 'assertion_effective_window', true);
                PERFORM set_config('app.effective_window_assertion_id', v_existing.id::text, true);
                UPDATE assertions SET effective_to = p_effective_at WHERE id = v_existing.id;
                PERFORM set_config('app.write_path', '', true);
                PERFORM set_config('app.effective_window_assertion_id', '', true);
            END IF;
        ELSIF p_effective_to IS NULL OR p_effective_to > now() THEN
            SELECT * INTO v_existing
            FROM assertions
            WHERE subject_ref = v_subject_ref
              AND assertion_type = v_assertion_type
              AND assertion_key = v_key
              AND status = 'accepted'
              AND superseded_at IS NULL
              AND (effective_at IS NULL OR effective_at <= now())
              AND (effective_to IS NULL OR effective_to > now())
            ORDER BY effective_at DESC NULLS LAST, asserted_at DESC
            LIMIT 1;

            IF FOUND
               AND v_existing.claim = p_claim
               AND v_existing.basis = v_basis
               AND v_existing.confidence IS NOT DISTINCT FROM p_confidence
            THEN
                PERFORM append_assertion_evidence(v_existing.id, p_evidence);
                RETURN v_existing.id;
            END IF;
            IF FOUND THEN
                PERFORM mark_assertion_superseded(v_existing.id, v_new_id);
            END IF;
        END IF;
    END IF;

    INSERT INTO assertions (
        id, assertion_type, assertion_key, status, basis, classification,
        subject_node_id, subject_edge_id, claim, effective_at, effective_to,
        confidence, attrs
    ) VALUES (
        v_new_id, v_assertion_type, v_key, v_status, v_basis, p_classification,
        p_subject_node_id, p_subject_edge_id, p_claim, p_effective_at,
        v_new_effective_to, p_confidence, coalesce(p_attrs, '{}'::jsonb)
    );

    PERFORM append_assertion_evidence(v_new_id, p_evidence);
    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;

-- Keep domain overlay writes on canonical node vocabulary.
CREATE OR REPLACE FUNCTION link_record(
    p_source_schema text,
    p_source_table text,
    p_source_id text,
    p_node_type text,
    p_label text,
    p_properties jsonb DEFAULT '{}',
    p_source_id_type text DEFAULT 'int'
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_node_id uuid;
    v_ext_source text;
    v_node_type text := canonical_type('node_type', p_node_type);
BEGIN
    v_ext_source := p_source_schema || '.' || p_source_table;

    SELECT node_id INTO v_node_id
    FROM node_source_map
    WHERE source_schema = p_source_schema
      AND source_table = p_source_table
      AND source_id = p_source_id;

    IF v_node_id IS NULL THEN
        SELECT id INTO v_node_id
        FROM nodes
        WHERE external_id = p_source_id
          AND external_source = v_ext_source
          AND archived_at IS NULL;
    END IF;

    IF v_node_id IS NOT NULL THEN
        UPDATE nodes
        SET properties = properties || p_properties,
            label = coalesce(p_label, label)
        WHERE id = v_node_id;
    ELSE
        INSERT INTO nodes (node_type, label, external_id, external_source, properties)
        VALUES (v_node_type, p_label, p_source_id, v_ext_source, p_properties)
        RETURNING id INTO v_node_id;
    END IF;

    INSERT INTO node_source_map (node_id, source_schema, source_table, source_id, source_id_type)
    VALUES (v_node_id, p_source_schema, p_source_table, p_source_id, p_source_id_type)
    ON CONFLICT (node_id, source_schema, source_table) DO UPDATE
        SET source_id = p_source_id, synced_at = now();

    RETURN v_node_id;
END;
$$ LANGUAGE plpgsql;

-- Scope-aware distillation. The primary source witness is used only for scope
-- resolution; derivation evidence remains the provenance primitive.
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
    v_policy text;
    v_resolved_scope uuid;
    v_status text := lower(coalesce(nullif(trim(p_status), ''), 'accepted'));
    v_subject_ref text;
    v_watermark timestamptz;
    v_witness uuid;
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

    SELECT max(asserted_at) INTO v_watermark
    FROM assertions WHERE id = ANY(p_source_assertion_ids);
    IF v_watermark IS NULL
       OR (SELECT count(*) FROM assertions WHERE id = ANY(p_source_assertion_ids))
          <> cardinality(p_source_assertion_ids)
    THEN
        RAISE EXCEPTION 'Every distillation source assertion must exist and be visible';
    END IF;

    SELECT ae.witness_node_id INTO v_witness
    FROM assertion_evidence ae
    WHERE ae.assertion_id = ANY(p_source_assertion_ids)
      AND ae.kind IN ('source', 'corroboration')
      AND ae.witness_node_id IS NOT NULL
    ORDER BY array_position(p_source_assertion_ids, ae.assertion_id), ae.recorded_at, ae.id
    LIMIT 1;

    v_resolved_scope := governing_scope(p_subject_node_id, p_subject_edge_id, 'digest', v_witness);
    IF p_scope_node_id IS NOT NULL
       AND v_resolved_scope IS NOT NULL
       AND p_scope_node_id <> v_resolved_scope
    THEN
        RAISE EXCEPTION 'Explicit scope % does not match governing scope %', p_scope_node_id, v_resolved_scope;
    END IF;
    v_resolved_scope := coalesce(v_resolved_scope, p_scope_node_id);
    v_policy := scope_review_policy(v_resolved_scope);
    IF v_status = 'accepted' AND v_policy IN ('candidates_only', 'strict') THEN
        v_status := 'candidate';
    END IF;

    IF p_subject_node_id IS NOT NULL THEN
        SELECT node_type INTO v_node_type FROM nodes WHERE id = p_subject_node_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Distillation subject node % not found', p_subject_node_id;
        END IF;
        v_catalog := registry_value('digest_facets:' || v_node_type, v_resolved_scope);
        IF v_catalog IS NOT NULL
           AND NOT ((jsonb_typeof(v_catalog) = 'array' AND v_catalog ? v_key)
                    OR (jsonb_typeof(v_catalog) = 'object' AND v_catalog ? v_key))
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

    PERFORM derived_assertion_classification(p_source_assertion_ids);
    v_subject_ref := coalesce('n:' || p_subject_node_id::text, 'e:' || p_subject_edge_id::text);
    PERFORM pg_advisory_xact_lock(hashtextextended(v_subject_ref || ':digest:' || v_key, 0));

    v_event_id := record_event(
        p_event_type := 'distillation',
        p_summary := format('Distilled %s source assertions into digest %s', cardinality(p_source_assertion_ids), v_key),
        p_properties := jsonb_build_object(
            'digest_assertion_id', v_new_id,
            'subject_edge_id', p_subject_edge_id,
            'source_assertion_ids', to_jsonb(p_source_assertion_ids),
            'source_event_ids', to_jsonb(coalesce(p_source_event_ids, '{}'::uuid[])),
            'watermark', v_watermark,
            'scope_node_id', v_resolved_scope
        ),
        p_participant_ids := v_participant_ids,
        p_participant_roles := v_participant_roles,
        p_actor := p_agent
    );

    v_evidence := array_append(v_evidence, jsonb_build_object(
        'kind', 'source', 'event_id', v_event_id,
        'attrs', jsonb_build_object('role', 'distillation_record')
    ));
    FOREACH v_id IN ARRAY p_source_assertion_ids LOOP
        v_evidence := array_append(v_evidence, jsonb_build_object(
            'kind', 'derivation', 'source_assertion_id', v_id
        ));
    END LOOP;
    FOREACH v_id IN ARRAY coalesce(p_source_event_ids, '{}'::uuid[]) LOOP
        v_evidence := array_append(v_evidence, jsonb_build_object('kind', 'source', 'event_id', v_id));
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
        id, assertion_type, assertion_key, status, basis,
        subject_node_id, subject_edge_id, claim, confidence, attrs
    ) VALUES (
        v_new_id, 'digest', v_key, v_status, 'inferred',
        p_subject_node_id, p_subject_edge_id, p_claim, p_confidence,
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

-- --------------------------------------------------------------------------
-- Salience and canonical review grouping
-- --------------------------------------------------------------------------

CREATE OR REPLACE VIEW node_salience
WITH (security_invoker = true) AS
SELECT
    n.id AS node_id,
    count(*) AS query_count,
    count(DISTINCT e.properties->>'agent_id') AS distinct_agents,
    max(e.occurred_at) AS last_queried_at,
    sum(exp(-extract(epoch FROM (now() - e.occurred_at)) / 2592000.0)) AS salience_score
FROM events e
JOIN event_participants ep ON ep.event_id = e.id
JOIN nodes n ON n.id = ep.node_id
WHERE e.event_type = 'agent_query'
GROUP BY n.id;

COMMENT ON VIEW node_salience IS
    'Advisory cooperative attention signal from log_agent_query events only. It may order work; it must never gate visibility, retention, or deletion.';

CREATE OR REPLACE VIEW review_queue
WITH (security_invoker = true) AS
SELECT
    a.subject_ref,
    a.subject_node_id,
    a.subject_edge_id,
    canonical_type('assertion_type', a.assertion_type) AS assertion_type,
    a.assertion_key,
    count(*) AS candidate_count,
    jsonb_agg(jsonb_build_object(
        'assertion_id', a.id,
        'stored_assertion_type', a.assertion_type,
        'claim', a.claim,
        'basis', a.basis,
        'confidence', a.confidence,
        'classification', a.classification,
        'asserted_at', a.asserted_at,
        'attrs', a.attrs
    ) ORDER BY a.asserted_at, a.id) AS candidates
FROM assertions a
WHERE a.status = 'candidate'
  AND a.superseded_at IS NULL
GROUP BY
    a.subject_ref,
    a.subject_node_id,
    a.subject_edge_id,
    canonical_type('assertion_type', a.assertion_type),
    a.assertion_key;

CREATE OR REPLACE VIEW competing_candidates
WITH (security_invoker = true) AS
SELECT * FROM review_queue WHERE candidate_count > 1;

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
        SELECT 1 FROM current_valid_assertions newer
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
                  NOT EXISTS (SELECT 1 FROM current_valid_assertions current_source WHERE current_source.id = source.id)
                  AND EXISTS (
                      SELECT 1 FROM current_valid_assertions replacement
                      WHERE replacement.subject_ref = source.subject_ref
                        AND replacement.assertion_type = source.assertion_type
                        AND replacement.assertion_key = source.assertion_key
                        AND replacement.id <> source.id
                  )
              )
          )
    ) AS overturned_source,
    salience.salience_score
FROM current_valid_assertions digest
LEFT JOIN node_salience salience ON salience.node_id = digest.subject_node_id
WHERE digest.assertion_type = 'digest'
  AND digest.attrs ? 'watermark'
  AND (
      EXISTS (
          SELECT 1 FROM current_valid_assertions newer
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
                    NOT EXISTS (SELECT 1 FROM current_valid_assertions current_source WHERE current_source.id = source.id)
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

COMMENT ON VIEW stale_digests IS
    'Stale accepted digests with advisory subject salience for hot-first ordering; salience never gates membership.';
