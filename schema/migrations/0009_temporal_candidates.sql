-- Temporal assertions, v2 assertion lifecycle, and structural candidates.

SET search_path = rye, pg_catalog, public;

ALTER TABLE assertions
    ADD COLUMN IF NOT EXISTS effective_to timestamptz;

DROP INDEX IF EXISTS idx_assertions_active_unique;
DROP INDEX IF EXISTS idx_assertions_active_window_unique;

CREATE UNIQUE INDEX idx_assertions_active_unique
    ON assertions (
        subject_ref,
        assertion_type,
        assertion_key,
        coalesce(effective_at, '-infinity'::timestamptz),
        coalesce(effective_to, 'infinity'::timestamptz)
    )
    WHERE superseded_at IS NULL AND status = 'accepted';

CREATE INDEX IF NOT EXISTS idx_assertions_temporal_node_key
    ON assertions (subject_node_id, assertion_type, assertion_key, effective_at, effective_to)
    WHERE subject_node_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_assertions_temporal_edge_key
    ON assertions (subject_edge_id, assertion_type, assertion_key, effective_at, effective_to)
    WHERE subject_edge_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_assertions_current_subject_asserted
    ON assertions (subject_ref, asserted_at)
    WHERE superseded_at IS NULL AND status = 'accepted';

DROP POLICY IF EXISTS assertion_update_policy ON assertions;
CREATE POLICY assertion_update_policy ON assertions
    FOR UPDATE
    USING (
        (
            current_setting('app.write_path', true) = 'supersede_assertion'
            AND id::text = current_setting('app.supersede_assertion_id', true)
        )
        OR (
            current_setting('app.write_path', true) = 'assertion_effective_window'
            AND id::text = current_setting('app.effective_window_assertion_id', true)
        )
        OR (
            current_setting('app.write_path', true) = 'accept_assertion'
            AND id::text = current_setting('app.accept_assertion_id', true)
        )
        OR (
            current_setting('app.write_path', true) = 'assertion_classification'
            AND id::text = current_setting('app.classification_assertion_id', true)
        )
    )
    WITH CHECK (
        (
            current_setting('app.write_path', true) = 'supersede_assertion'
            AND id::text = current_setting('app.supersede_assertion_id', true)
        )
        OR (
            current_setting('app.write_path', true) = 'assertion_effective_window'
            AND id::text = current_setting('app.effective_window_assertion_id', true)
        )
        OR (
            current_setting('app.write_path', true) = 'accept_assertion'
            AND id::text = current_setting('app.accept_assertion_id', true)
        )
        OR (
            current_setting('app.write_path', true) = 'assertion_classification'
            AND id::text = current_setting('app.classification_assertion_id', true)
        )
    );

CREATE OR REPLACE FUNCTION assertions_immutable_guard() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_path text := current_setting('app.write_path', true);
BEGIN
    IF NEW.claim IS DISTINCT FROM OLD.claim
       OR NEW.assertion_type IS DISTINCT FROM OLD.assertion_type
       OR NEW.assertion_key IS DISTINCT FROM OLD.assertion_key
       OR NEW.subject_node_id IS DISTINCT FROM OLD.subject_node_id
       OR NEW.subject_edge_id IS DISTINCT FROM OLD.subject_edge_id
       OR NEW.asserted_at IS DISTINCT FROM OLD.asserted_at
       OR NEW.basis IS DISTINCT FROM OLD.basis
       OR NEW.confidence IS DISTINCT FROM OLD.confidence
       OR NEW.attrs IS DISTINCT FROM OLD.attrs
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'Assertion content is immutable';
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status
       AND NOT (
           OLD.status = 'candidate'
           AND NEW.status = 'accepted'
           AND v_path = 'accept_assertion'
           AND NEW.id::text = current_setting('app.accept_assertion_id', true)
       )
    THEN
        RAISE EXCEPTION 'Assertion status may transition only candidate to accepted via accept_assertion()';
    END IF;

    IF NEW.classification IS DISTINCT FROM OLD.classification
       AND NOT (
           v_path = 'assertion_classification'
           AND NEW.id::text = current_setting('app.classification_assertion_id', true)
       )
    THEN
        RAISE EXCEPTION 'Assertion classification is immutable outside evidence propagation';
    END IF;

    IF NEW.effective_at IS DISTINCT FROM OLD.effective_at THEN
        RAISE EXCEPTION 'Assertion effective_at is immutable';
    END IF;

    IF NEW.effective_to IS DISTINCT FROM OLD.effective_to THEN
        IF v_path <> 'assertion_effective_window'
           OR NEW.id::text <> current_setting('app.effective_window_assertion_id', true)
           OR NEW.effective_to IS NULL
           OR (OLD.effective_at IS NOT NULL AND NEW.effective_to <= OLD.effective_at)
           OR (OLD.effective_to IS NOT NULL AND NEW.effective_to > OLD.effective_to)
        THEN
            RAISE EXCEPTION 'Only helper-controlled narrowing of effective_to is allowed';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW current_valid_assertions
WITH (security_invoker = true) AS
SELECT *
FROM assertions
WHERE status = 'accepted'
  AND superseded_at IS NULL
  AND (effective_at IS NULL OR effective_at <= now())
  AND (effective_to IS NULL OR effective_to > now());

CREATE OR REPLACE VIEW current_assertions
WITH (security_invoker = true) AS
SELECT * FROM current_valid_assertions;

CREATE OR REPLACE FUNCTION assertions_as_of(
    p_effective timestamptz,
    p_known_as_of timestamptz DEFAULT NULL
) RETURNS SETOF assertions
SET search_path = rye, pg_catalog
AS $$
    SELECT a.*
    FROM assertions a
    WHERE a.status = 'accepted'
      AND (a.effective_at IS NULL OR a.effective_at <= p_effective)
      AND (a.effective_to IS NULL OR a.effective_to > p_effective)
      AND a.asserted_at <= coalesce(p_known_as_of, p_effective)
      AND (
          a.superseded_at IS NULL
          OR a.superseded_at > coalesce(p_known_as_of, p_effective)
          -- Backdated correction: a superseded row still answers effective
          -- times its successor does not govern. Without this, correcting a
          -- fact with a later effective_at retires the old truth in
          -- knowledge-time and history before the correction becomes
          -- unqueryable (found by blind scenario evaluation, issue #7).
          OR EXISTS (
              SELECT 1 FROM assertions s
              WHERE s.id = a.superseded_by
                AND s.effective_at IS NOT NULL
                AND s.effective_at > p_effective
          )
      );
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION classification_rank(p_classification text)
RETURNS int
SET search_path = rye, pg_catalog
AS $$
    SELECT CASE
        WHEN p_classification IS NULL THEN 0
        WHEN p_classification = 'public' THEN 1
        WHEN p_classification = 'internal' THEN 2
        WHEN p_classification = 'confidential' THEN 3
        WHEN p_classification = 'restricted' THEN 4
        ELSE 2
    END;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION assertion_access_teams(p_assertion_id uuid)
RETURNS text[]
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion assertions;
    v_source text[];
    v_target text[];
BEGIN
    SELECT * INTO v_assertion FROM assertions WHERE id = p_assertion_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source assertion % not found', p_assertion_id;
    END IF;

    IF v_assertion.subject_node_id IS NOT NULL THEN
        SELECT ARRAY(SELECT jsonb_array_elements_text(coalesce(attrs->'teams', '[]'::jsonb)))
        INTO v_source
        FROM nodes
        WHERE id = v_assertion.subject_node_id;
        RETURN coalesce(v_source, '{}'::text[]);
    END IF;

    SELECT
        ARRAY(SELECT jsonb_array_elements_text(coalesce(ns.attrs->'teams', '[]'::jsonb))),
        ARRAY(SELECT jsonb_array_elements_text(coalesce(nt.attrs->'teams', '[]'::jsonb)))
    INTO v_source, v_target
    FROM edges e
    JOIN nodes ns ON ns.id = e.source_id
    JOIN nodes nt ON nt.id = e.target_id
    WHERE e.id = v_assertion.subject_edge_id;

    IF cardinality(coalesce(v_source, '{}'::text[])) = 0 THEN
        RETURN coalesce(v_target, '{}'::text[]);
    END IF;
    IF cardinality(coalesce(v_target, '{}'::text[])) = 0 THEN
        RETURN coalesce(v_source, '{}'::text[]);
    END IF;

    RETURN ARRAY(
        SELECT team
        FROM unnest(v_source) AS team
        WHERE team = ANY(v_target)
        ORDER BY team
    );
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION derived_assertion_classification(
    p_source_assertion_ids uuid[]
) RETURNS text
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_classification text;
    v_current text;
    v_id uuid;
    v_population text[];
    v_source_population text[];
    v_population_initialized boolean := false;
BEGIN
    IF cardinality(coalesce(p_source_assertion_ids, '{}'::uuid[])) = 0 THEN
        RETURN NULL;
    END IF;

    FOREACH v_id IN ARRAY p_source_assertion_ids LOOP
        SELECT coalesce(
            a.classification,
            n.attrs->>'classification',
            CASE
                WHEN classification_rank(ns.attrs->>'classification')
                     >= classification_rank(nt.attrs->>'classification')
                THEN ns.attrs->>'classification'
                ELSE nt.attrs->>'classification'
            END
        )
        INTO v_current
        FROM assertions a
        LEFT JOIN nodes n ON n.id = a.subject_node_id
        LEFT JOIN edges e ON e.id = a.subject_edge_id
        LEFT JOIN nodes ns ON ns.id = e.source_id
        LEFT JOIN nodes nt ON nt.id = e.target_id
        WHERE a.id = v_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Source assertion % not found', v_id;
        END IF;

        IF classification_rank(v_current) > classification_rank(v_classification) THEN
            v_classification := v_current;
        END IF;

        v_source_population := assertion_access_teams(v_id);
        IF cardinality(v_source_population) > 0 THEN
            IF NOT v_population_initialized THEN
                v_population := v_source_population;
                v_population_initialized := true;
            ELSE
                v_population := ARRAY(
                    SELECT team
                    FROM unnest(v_population) AS team
                    WHERE team = ANY(v_source_population)
                    ORDER BY team
                );
                IF cardinality(v_population) = 0 THEN
                    RAISE EXCEPTION
                        'Cannot derive assertion from mixed-access sources: no access population can see every source';
                END IF;
            END IF;
        END IF;
    END LOOP;

    RETURN v_classification;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION append_assertion_evidence(
    p_assertion_id uuid,
    p_evidence jsonb[]
) RETURNS void
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_attrs jsonb;
    v_event_id uuid;
    v_item jsonb;
    v_kind text;
    v_source_assertion_id uuid;
    v_witness_node_id uuid;
    v_independent boolean;
BEGIN
    IF p_evidence IS NULL THEN
        RETURN;
    END IF;

    FOREACH v_item IN ARRAY p_evidence LOOP
        v_kind := nullif(trim(v_item->>'kind'), '');
        v_event_id := nullif(v_item->>'event_id', '')::uuid;
        v_source_assertion_id := nullif(v_item->>'source_assertion_id', '')::uuid;
        v_witness_node_id := nullif(v_item->>'witness_node_id', '')::uuid;
        v_attrs := coalesce(v_item->'attrs', '{}'::jsonb);

        IF v_kind = 'corroboration' THEN
            v_independent := v_witness_node_id IS NOT NULL
                AND NOT EXISTS (
                    SELECT 1
                    FROM assertion_evidence ae
                    WHERE ae.assertion_id = p_assertion_id
                      AND ae.kind IN ('source', 'corroboration')
                      AND ae.witness_node_id = v_witness_node_id
                );
            v_attrs := v_attrs || jsonb_build_object('independent', v_independent);
        END IF;

        INSERT INTO assertion_evidence (
            assertion_id,
            kind,
            event_id,
            source_assertion_id,
            witness_node_id,
            attrs
        ) VALUES (
            p_assertion_id,
            v_kind,
            v_event_id,
            v_source_assertion_id,
            v_witness_node_id,
            v_attrs
        );
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION propagate_assertion_classification_from_evidence()
RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_classification text;
    v_source_ids uuid[];
BEGIN
    IF NEW.kind <> 'derivation' THEN
        RETURN NEW;
    END IF;

    SELECT array_agg(DISTINCT source_assertion_id ORDER BY source_assertion_id)
    INTO v_source_ids
    FROM assertion_evidence
    WHERE assertion_id = NEW.assertion_id
      AND kind = 'derivation';

    v_classification := derived_assertion_classification(v_source_ids);

    PERFORM set_config('app.write_path', 'assertion_classification', true);
    PERFORM set_config('app.classification_assertion_id', NEW.assertion_id::text, true);
    UPDATE assertions
    SET classification = v_classification
    WHERE id = NEW.assertion_id
      AND classification IS DISTINCT FROM v_classification;
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.classification_assertion_id', '', true);

    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.classification_assertion_id', '', true);
    RAISE;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_assertion_evidence_classification ON assertion_evidence;
CREATE TRIGGER trg_assertion_evidence_classification
    AFTER INSERT ON assertion_evidence
    FOR EACH ROW
    EXECUTE FUNCTION propagate_assertion_classification_from_evidence();

CREATE OR REPLACE FUNCTION enforce_assertion_evidence_required()
RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
BEGIN
    IF NEW.basis <> 'assumed'
       AND NOT EXISTS (
           SELECT 1 FROM assertion_evidence ae WHERE ae.assertion_id = NEW.id
       )
    THEN
        RAISE EXCEPTION
            'Assertion % with basis % requires at least one evidence row',
            NEW.id,
            NEW.basis;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_assertion_evidence_required ON assertions;
CREATE CONSTRAINT TRIGGER trg_assertion_evidence_required
    AFTER INSERT OR UPDATE OF status, basis ON assertions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION enforce_assertion_evidence_required();

CREATE OR REPLACE FUNCTION record_assertion(
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
    p_attrs jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_existing assertions;
    v_key text := coalesce(nullif(trim(p_assertion_key), ''), 'default');
    v_new_effective_to timestamptz := p_effective_to;
    v_new_id uuid := gen_random_uuid();
    v_next_future_at timestamptz;
    v_status text := lower(coalesce(nullif(trim(p_status), ''), 'accepted'));
    v_basis text := lower(coalesce(nullif(trim(p_basis), ''), 'unknown'));
    v_subject_ref text;
BEGIN
    IF (p_subject_node_id IS NULL) = (p_subject_edge_id IS NULL) THEN
        RAISE EXCEPTION 'Exactly one of subject_node_id or subject_edge_id is required';
    END IF;
    IF nullif(trim(p_assertion_type), '') IS NULL THEN
        RAISE EXCEPTION 'assertion_type is required';
    END IF;
    IF p_claim IS NULL THEN
        RAISE EXCEPTION 'claim is required';
    END IF;
    IF v_status NOT IN ('candidate', 'accepted') THEN
        RAISE EXCEPTION 'Unsupported assertion status: %', p_status;
    END IF;
    IF v_basis NOT IN ('observed', 'reported', 'inferred', 'assumed', 'unknown') THEN
        RAISE EXCEPTION 'Unsupported assertion basis: %', p_basis;
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

    v_subject_ref := coalesce(
        'n:' || p_subject_node_id::text,
        'e:' || p_subject_edge_id::text
    );

    IF v_status = 'accepted' THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(
            v_subject_ref || ':' || p_assertion_type || ':' || v_key,
            0
        ));

        IF p_effective_at IS NOT NULL AND p_effective_at > now() THEN
            SELECT *
            INTO v_existing
            FROM assertions
            WHERE subject_ref = v_subject_ref
              AND assertion_type = p_assertion_type
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

            SELECT min(effective_at)
            INTO v_next_future_at
            FROM assertions
            WHERE subject_ref = v_subject_ref
              AND assertion_type = p_assertion_type
              AND assertion_key = v_key
              AND status = 'accepted'
              AND superseded_at IS NULL
              AND effective_at > p_effective_at;

            IF v_next_future_at IS NOT NULL
               AND (v_new_effective_to IS NULL OR v_new_effective_to > v_next_future_at)
            THEN
                v_new_effective_to := v_next_future_at;
            END IF;

            SELECT *
            INTO v_existing
            FROM assertions
            WHERE subject_ref = v_subject_ref
              AND assertion_type = p_assertion_type
              AND assertion_key = v_key
              AND status = 'accepted'
              AND superseded_at IS NULL
              AND (effective_at IS NULL OR effective_at < p_effective_at)
              AND (effective_to IS NULL OR effective_to > p_effective_at)
            ORDER BY effective_at DESC NULLS LAST, asserted_at DESC
            LIMIT 1;

            IF FOUND
               AND (v_existing.effective_to IS NULL
                    OR v_existing.effective_to > p_effective_at)
            THEN
                PERFORM set_config('app.write_path', 'assertion_effective_window', true);
                PERFORM set_config('app.effective_window_assertion_id', v_existing.id::text, true);
                UPDATE assertions SET effective_to = p_effective_at WHERE id = v_existing.id;
                PERFORM set_config('app.write_path', '', true);
                PERFORM set_config('app.effective_window_assertion_id', '', true);
            END IF;
        ELSIF p_effective_to IS NULL OR p_effective_to > now() THEN
            SELECT *
            INTO v_existing
            FROM assertions
            WHERE subject_ref = v_subject_ref
              AND assertion_type = p_assertion_type
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
        p_assertion_type,
        v_key,
        v_status,
        v_basis,
        p_classification,
        p_subject_node_id,
        p_subject_edge_id,
        p_claim,
        p_effective_at,
        v_new_effective_to,
        p_confidence,
        coalesce(p_attrs, '{}'::jsonb)
    );

    PERFORM append_assertion_evidence(v_new_id, p_evidence);
    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION knowledge_candidate_source_refs(
    p_candidate_id uuid
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
    SELECT coalesce(
        jsonb_agg(
            jsonb_build_object(
                'node_id', e.target_id,
                'edge_type', e.edge_type,
                'created_at', e.created_at
            )
            ORDER BY e.created_at
        ),
        '[]'::jsonb
    )
    FROM edges e
    WHERE e.source_id = p_candidate_id
      AND e.edge_type IN ('supported_by', 'derived_from')
      AND e.archived_at IS NULL;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION set_candidate_status(
    p_candidate_id uuid,
    p_status text,
    p_reason text DEFAULT NULL,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_id uuid;
    v_candidate nodes;
    v_event_id uuid;
    v_status text;
BEGIN
    v_status := lower(coalesce(nullif(trim(p_status), ''), ''));
    IF v_status NOT IN ('proposed', 'accepted', 'rejected', 'needs_review', 'duplicate', 'superseded') THEN
        RAISE EXCEPTION 'Unsupported candidate status: %', p_status;
    END IF;

    SELECT * INTO v_candidate
    FROM nodes
    WHERE id = p_candidate_id
      AND node_type = 'knowledge_candidate'
      AND archived_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Knowledge candidate % not found', p_candidate_id;
    END IF;

    v_event_id := record_event(
        p_event_type := 'knowledge_candidate_status_changed',
        p_summary := format('Knowledge candidate %s: %s', v_status, left(coalesce(v_candidate.label, p_candidate_id::text), 120)),
        p_properties := jsonb_build_object('candidate_id', p_candidate_id, 'status', v_status, 'reason', p_reason),
        p_participant_ids := ARRAY[p_candidate_id],
        p_participant_roles := ARRAY['candidate'],
        p_actor := p_actor
    );

    v_assertion_id := record_assertion(
        p_assertion_type := 'candidate_status',
        p_claim := jsonb_build_object(
            'status', v_status,
            'reason', p_reason,
            'actor', coalesce(p_actor, current_setting('app.current_user_id', true)),
            'status_at', now()
        ),
        p_subject_node_id := p_candidate_id,
        p_evidence := ARRAY[jsonb_build_object('kind', 'source', 'event_id', v_event_id)],
        p_basis := 'observed',
        p_confidence := 1.0,
        p_attrs := jsonb_build_object('status_event_id', v_event_id)
    );
    RETURN v_assertion_id;
END;
$$ LANGUAGE plpgsql;

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
    v_created_by text := coalesce(p_created_by, current_setting('app.current_user_id', true));
    v_event_id uuid;
    v_kind text := lower(coalesce(nullif(trim(p_candidate_kind), ''), ''));
    v_statement text := nullif(trim(p_statement), '');
BEGIN
    IF v_kind NOT IN ('task', 'edge', 'decision', 'procedure', 'preference', 'risk') THEN
        RAISE EXCEPTION 'Unsupported structural candidate kind: %', p_candidate_kind;
    END IF;
    IF v_statement IS NULL THEN
        RAISE EXCEPTION 'Candidate statement is required';
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
    SELECT 'supported_by', v_candidate_id, id, jsonb_build_object('created_by', v_created_by),
           jsonb_build_object('candidate_id', v_candidate_id)
    FROM unnest(coalesce(p_source_node_ids, '{}'::uuid[])) AS id;

    INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
    SELECT 'derived_from', v_candidate_id, id, jsonb_build_object('created_by', v_created_by),
           jsonb_build_object('candidate_id', v_candidate_id)
    FROM unnest(coalesce(p_derived_from_node_ids, '{}'::uuid[])) AS id;

    v_event_id := record_event(
        p_event_type := 'knowledge_candidate_created',
        p_summary := format('Structural knowledge candidate proposed: %s', left(v_statement, 120)),
        p_properties := jsonb_build_object(
            'candidate_id', v_candidate_id,
            'candidate_kind', v_kind,
            'statement', v_statement,
            'target_payload', coalesce(p_target_payload, '{}'::jsonb)
        ),
        p_participant_ids := ARRAY[v_candidate_id],
        p_participant_roles := ARRAY['candidate'],
        p_actor := v_created_by
    );

    PERFORM set_candidate_status(v_candidate_id, 'proposed', 'Candidate created', v_created_by);
    RETURN v_candidate_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION promote_candidate_to_task(
    p_candidate_id uuid,
    p_label text,
    p_properties jsonb DEFAULT '{}'::jsonb,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_event_id uuid;
    v_source_refs jsonb;
    v_task_id uuid;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM nodes
        WHERE id = p_candidate_id AND node_type = 'knowledge_candidate' AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Knowledge candidate % not found', p_candidate_id;
    END IF;
    IF nullif(trim(p_label), '') IS NULL THEN
        RAISE EXCEPTION 'Task label is required';
    END IF;

    v_source_refs := knowledge_candidate_source_refs(p_candidate_id);
    INSERT INTO nodes (node_type, label, properties, attrs)
    VALUES (
        'task',
        p_label,
        coalesce(p_properties, '{}'::jsonb) || jsonb_build_object(
            'status', coalesce(p_properties->>'status', 'open'),
            'candidate_id', p_candidate_id,
            'source_refs', v_source_refs
        ),
        jsonb_build_object('candidate_id', p_candidate_id, 'source_refs', v_source_refs)
    )
    RETURNING id INTO v_task_id;

    INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
    VALUES ('promoted_to', p_candidate_id, v_task_id, '{"target_type":"task"}',
            jsonb_build_object('candidate_id', p_candidate_id));

    v_event_id := record_event(
        p_event_type := 'knowledge_candidate_promoted',
        p_summary := format('Knowledge candidate promoted to task: %s', left(p_label, 120)),
        p_properties := jsonb_build_object('candidate_id', p_candidate_id, 'task_node_id', v_task_id),
        p_participant_ids := ARRAY[p_candidate_id, v_task_id],
        p_participant_roles := ARRAY['candidate', 'task'],
        p_actor := p_actor
    );

    PERFORM record_assertion(
        p_assertion_type := 'task_status',
        p_claim := jsonb_build_object('status', coalesce(p_properties->>'status', 'open')),
        p_subject_node_id := v_task_id,
        p_evidence := ARRAY[jsonb_build_object('kind', 'source', 'event_id', v_event_id)],
        p_basis := 'observed',
        p_confidence := 1.0,
        p_attrs := jsonb_build_object('candidate_id', p_candidate_id, 'source_refs', v_source_refs)
    );
    PERFORM set_candidate_status(p_candidate_id, 'accepted', 'Promoted to task ' || v_task_id, p_actor);
    RETURN v_task_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION promote_candidate_to_edge(
    p_candidate_id uuid,
    p_source_id uuid,
    p_target_id uuid,
    p_edge_type text,
    p_properties jsonb DEFAULT '{}'::jsonb,
    p_effective_from timestamptz DEFAULT NULL,
    p_effective_to timestamptz DEFAULT NULL,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_edge_id uuid;
    v_event_id uuid;
    v_source_refs jsonb;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM nodes
        WHERE id = p_candidate_id AND node_type = 'knowledge_candidate' AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Knowledge candidate % not found', p_candidate_id;
    END IF;
    IF nullif(trim(p_edge_type), '') IS NULL THEN
        RAISE EXCEPTION 'edge_type is required';
    END IF;

    v_source_refs := knowledge_candidate_source_refs(p_candidate_id);
    v_event_id := record_event(
        p_event_type := 'knowledge_candidate_promoted',
        p_summary := format('Knowledge candidate promoted to edge: %s', p_edge_type),
        p_properties := jsonb_build_object(
            'candidate_id', p_candidate_id,
            'source_id', p_source_id,
            'target_id', p_target_id,
            'edge_type', p_edge_type
        ),
        p_participant_ids := ARRAY[p_candidate_id, p_source_id, p_target_id],
        p_participant_roles := ARRAY['candidate', 'source', 'target'],
        p_actor := p_actor
    );

    INSERT INTO edges (
        edge_type, source_id, target_id, properties, effective_from, effective_to, attrs
    ) VALUES (
        p_edge_type, p_source_id, p_target_id, coalesce(p_properties, '{}'::jsonb),
        p_effective_from, p_effective_to,
        jsonb_build_object(
            'candidate_id', p_candidate_id,
            'source_refs', v_source_refs,
            'promotion_event_id', v_event_id
        )
    )
    RETURNING id INTO v_edge_id;

    PERFORM set_candidate_status(p_candidate_id, 'accepted', 'Promoted to edge ' || v_edge_id, p_actor);
    RETURN v_edge_id;
END;
$$ LANGUAGE plpgsql;
