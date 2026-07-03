-- Temporal assertions and knowledge candidates
--
-- This migration keeps current_assertions backward-compatible while adding
-- effective end dates, point-in-time reads, and helper functions for the
-- evidence -> candidate -> accepted knowledge workflow.

SET search_path = rye, pg_catalog, public;

ALTER TABLE assertions
    ADD COLUMN IF NOT EXISTS effective_to timestamptz;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'assertions_effective_window'
          AND conrelid = 'assertions'::regclass
    ) THEN
        ALTER TABLE assertions
            ADD CONSTRAINT assertions_effective_window
            CHECK (
                effective_to IS NULL
                OR effective_at IS NULL
                OR effective_to > effective_at
            );
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_assertions_temporal_node_key
    ON assertions (subject_node_id, assertion_type, assertion_key, effective_at, effective_to)
    WHERE subject_node_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_assertions_temporal_edge_key
    ON assertions (subject_edge_id, assertion_type, assertion_key, effective_at, effective_to)
    WHERE subject_edge_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_assertions_current_temporal
    ON assertions (subject_ref, assertion_type, assertion_key, effective_at, effective_to)
    WHERE superseded_at IS NULL;

CREATE OR REPLACE FUNCTION assertions_immutable_guard() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
BEGIN
    IF NEW.claim IS DISTINCT FROM OLD.claim
       OR NEW.assertion_type IS DISTINCT FROM OLD.assertion_type
       OR NEW.assertion_key IS DISTINCT FROM OLD.assertion_key
       OR NEW.subject_node_id IS DISTINCT FROM OLD.subject_node_id
       OR NEW.subject_edge_id IS DISTINCT FROM OLD.subject_edge_id
       OR NEW.asserted_at IS DISTINCT FROM OLD.asserted_at
       OR NEW.effective_at IS DISTINCT FROM OLD.effective_at
       OR NEW.effective_to IS DISTINCT FROM OLD.effective_to
       OR NEW.source_event_id IS DISTINCT FROM OLD.source_event_id
       OR NEW.confidence IS DISTINCT FROM OLD.confidence
       OR NEW.attrs IS DISTINCT FROM OLD.attrs
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION
            'Assertion content is immutable. Only superseded_at and superseded_by may be updated.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW current_valid_assertions
WITH (security_invoker = true) AS
SELECT *
FROM assertions
WHERE superseded_at IS NULL
  AND (effective_at IS NULL OR effective_at <= now())
  AND (effective_to IS NULL OR effective_to > now());

CREATE OR REPLACE FUNCTION assertions_as_of(
    p_as_of timestamptz DEFAULT now()
) RETURNS SETOF assertions
SET search_path = rye, pg_catalog
AS $$
    SELECT *
    FROM assertions
    WHERE (effective_at IS NULL OR effective_at <= p_as_of)
      AND (effective_to IS NULL OR effective_to > p_as_of)
      AND superseded_by IS NULL;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION record_assertion(
    p_assertion_type text,
    p_claim jsonb,
    p_subject_node_id uuid DEFAULT NULL,
    p_subject_edge_id uuid DEFAULT NULL,
    p_assertion_key text DEFAULT 'default',
    p_effective_at timestamptz DEFAULT NULL,
    p_effective_to timestamptz DEFAULT NULL,
    p_source_event_id uuid DEFAULT NULL,
    p_confidence numeric DEFAULT NULL,
    p_mode text DEFAULT 'current',
    p_superseded_by uuid DEFAULT NULL,
    p_attrs jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_key text;
    v_attrs jsonb;
    v_existing assertions;
    v_has_existing boolean := false;
    v_mode text;
    v_new_id uuid;
    v_subject_ref text;
BEGIN
    v_mode := lower(coalesce(nullif(trim(p_mode), ''), 'current'));
    v_assertion_key := coalesce(nullif(trim(p_assertion_key), ''), 'default');
    v_attrs := coalesce(p_attrs, '{}'::jsonb);

    IF (p_subject_node_id IS NULL) = (p_subject_edge_id IS NULL) THEN
        RAISE EXCEPTION 'Exactly one of subject_node_id or subject_edge_id is required';
    END IF;

    IF nullif(trim(p_assertion_type), '') IS NULL THEN
        RAISE EXCEPTION 'assertion_type is required';
    END IF;

    IF p_claim IS NULL THEN
        RAISE EXCEPTION 'claim is required';
    END IF;

    IF p_mode IS NOT NULL AND v_mode NOT IN ('current', 'historical', 'candidate') THEN
        RAISE EXCEPTION 'Unsupported assertion record mode: %', p_mode;
    END IF;

    IF p_effective_at IS NOT NULL
       AND p_effective_to IS NOT NULL
       AND p_effective_to <= p_effective_at
    THEN
        RAISE EXCEPTION 'effective_to must be after effective_at';
    END IF;

    IF p_confidence IS NOT NULL AND (p_confidence < 0 OR p_confidence > 1) THEN
        RAISE EXCEPTION 'confidence must be between 0 and 1';
    END IF;

    IF p_subject_node_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM nodes WHERE id = p_subject_node_id)
    THEN
        RAISE EXCEPTION 'Subject node % not found', p_subject_node_id;
    END IF;

    IF p_subject_edge_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM edges WHERE id = p_subject_edge_id)
    THEN
        RAISE EXCEPTION 'Subject edge % not found', p_subject_edge_id;
    END IF;

    v_subject_ref := coalesce('n:' || p_subject_node_id::text, 'e:' || p_subject_edge_id::text);

    IF v_mode = 'historical' THEN
        INSERT INTO assertions (
            assertion_type,
            assertion_key,
            subject_node_id,
            subject_edge_id,
            claim,
            effective_at,
            effective_to,
            superseded_at,
            superseded_by,
            source_event_id,
            confidence,
            attrs
        ) VALUES (
            p_assertion_type,
            v_assertion_key,
            p_subject_node_id,
            p_subject_edge_id,
            p_claim,
            p_effective_at,
            p_effective_to,
            now(),
            p_superseded_by,
            p_source_event_id,
            p_confidence,
            v_attrs || jsonb_build_object('record_mode', 'historical')
        )
        RETURNING id INTO v_new_id;

        RETURN v_new_id;
    END IF;

    IF v_mode = 'candidate' THEN
        v_new_id := gen_random_uuid();

        INSERT INTO assertions (
            id,
            assertion_type,
            assertion_key,
            subject_node_id,
            subject_edge_id,
            claim,
            effective_at,
            effective_to,
            source_event_id,
            confidence,
            attrs
        ) VALUES (
            v_new_id,
            p_assertion_type,
            'candidate:' || v_new_id::text,
            p_subject_node_id,
            p_subject_edge_id,
            p_claim,
            p_effective_at,
            p_effective_to,
            p_source_event_id,
            p_confidence,
            v_attrs || jsonb_build_object(
                'record_mode', 'candidate',
                'candidate_assertion_key', v_assertion_key
            )
        );

        RETURN v_new_id;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        v_subject_ref || ':' || p_assertion_type || ':' || v_assertion_key,
        0
    ));

    SELECT *
    INTO v_existing
    FROM assertions
    WHERE subject_node_id IS NOT DISTINCT FROM p_subject_node_id
      AND subject_edge_id IS NOT DISTINCT FROM p_subject_edge_id
      AND assertion_type = p_assertion_type
      AND assertion_key = v_assertion_key
      AND superseded_at IS NULL;

    v_has_existing := FOUND;

    IF v_has_existing
       AND v_existing.claim = p_claim
       AND v_existing.effective_at IS NOT DISTINCT FROM p_effective_at
       AND v_existing.effective_to IS NOT DISTINCT FROM p_effective_to
       AND v_existing.confidence IS NOT DISTINCT FROM p_confidence
    THEN
        RETURN v_existing.id;
    END IF;

    v_new_id := gen_random_uuid();

    IF v_has_existing THEN
        PERFORM mark_assertion_superseded(v_existing.id, v_new_id);
    END IF;

    INSERT INTO assertions (
        id,
        assertion_type,
        assertion_key,
        subject_node_id,
        subject_edge_id,
        claim,
        effective_at,
        effective_to,
        source_event_id,
        confidence,
        attrs
    ) VALUES (
        v_new_id,
        p_assertion_type,
        v_assertion_key,
        p_subject_node_id,
        p_subject_edge_id,
        p_claim,
        p_effective_at,
        p_effective_to,
        p_source_event_id,
        p_confidence,
        v_attrs || jsonb_build_object('record_mode', 'current')
    );

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

    IF NOT (v_status = ANY(ARRAY[
        'proposed',
        'accepted',
        'rejected',
        'needs_review',
        'duplicate',
        'superseded'
    ])) THEN
        RAISE EXCEPTION 'Unsupported candidate status: %', p_status;
    END IF;

    SELECT *
    INTO v_candidate
    FROM nodes
    WHERE id = p_candidate_id
      AND node_type = 'knowledge_candidate'
      AND archived_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Knowledge candidate % not found', p_candidate_id;
    END IF;

    v_event_id := record_event(
        p_event_type        := 'knowledge_candidate_status_changed',
        p_summary           := format('Knowledge candidate %s: %s', v_status, left(coalesce(v_candidate.label, p_candidate_id::text), 120)),
        p_properties        := jsonb_build_object(
            'candidate_id', p_candidate_id,
            'status', v_status,
            'reason', p_reason
        ),
        p_participant_ids   := ARRAY[p_candidate_id],
        p_participant_roles := ARRAY['candidate'],
        p_actor             := p_actor
    );

    v_assertion_id := record_assertion(
        p_assertion_type    := 'candidate_status',
        p_claim             := jsonb_build_object(
            'status', v_status,
            'reason', p_reason,
            'actor', coalesce(p_actor, current_setting('app.current_user_id', true)),
            'status_at', now()
        ),
        p_subject_node_id   := p_candidate_id,
        p_assertion_key     := 'default',
        p_source_event_id   := v_event_id,
        p_confidence        := 1.0,
        p_mode              := 'current',
        p_attrs             := jsonb_build_object('status_event_id', v_event_id)
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
        'risk'
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

    PERFORM set_candidate_status(
        p_candidate_id := v_candidate_id,
        p_status       := 'proposed',
        p_reason       := 'Candidate created',
        p_actor        := v_created_by
    );

    RETURN v_candidate_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION promote_candidate_to_assertion(
    p_candidate_id uuid,
    p_subject_node_id uuid,
    p_assertion_type text,
    p_assertion_key text,
    p_claim jsonb,
    p_effective_at timestamptz DEFAULT NULL,
    p_effective_to timestamptz DEFAULT NULL,
    p_confidence numeric DEFAULT NULL,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_id uuid;
    v_candidate nodes;
    v_event_id uuid;
    v_source_refs jsonb;
BEGIN
    SELECT *
    INTO v_candidate
    FROM nodes
    WHERE id = p_candidate_id
      AND node_type = 'knowledge_candidate'
      AND archived_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Knowledge candidate % not found', p_candidate_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = p_subject_node_id AND archived_at IS NULL) THEN
        RAISE EXCEPTION 'Subject node % not found', p_subject_node_id;
    END IF;

    v_source_refs := knowledge_candidate_source_refs(p_candidate_id);

    v_event_id := record_event(
        p_event_type        := 'knowledge_candidate_promoted',
        p_summary           := format('Knowledge candidate promoted to assertion: %s', left(coalesce(v_candidate.label, p_candidate_id::text), 120)),
        p_properties        := jsonb_build_object(
            'candidate_id', p_candidate_id,
            'target_type', 'assertion',
            'subject_node_id', p_subject_node_id,
            'assertion_type', p_assertion_type,
            'assertion_key', p_assertion_key,
            'source_refs', v_source_refs
        ),
        p_participant_ids   := ARRAY[p_candidate_id, p_subject_node_id],
        p_participant_roles := ARRAY['candidate', 'subject'],
        p_actor             := p_actor
    );

    v_assertion_id := record_assertion(
        p_assertion_type    := p_assertion_type,
        p_claim             := p_claim,
        p_subject_node_id   := p_subject_node_id,
        p_assertion_key     := p_assertion_key,
        p_effective_at      := p_effective_at,
        p_effective_to      := p_effective_to,
        p_source_event_id   := v_event_id,
        p_confidence        := p_confidence,
        p_mode              := 'current',
        p_attrs             := jsonb_build_object(
            'candidate_id', p_candidate_id,
            'source_refs', v_source_refs,
            'promotion_event_id', v_event_id,
            'promoted_by', coalesce(p_actor, current_setting('app.current_user_id', true))
        )
    );

    PERFORM set_candidate_status(
        p_candidate_id := p_candidate_id,
        p_status       := 'accepted',
        p_reason       := 'Promoted to assertion ' || v_assertion_id::text,
        p_actor        := p_actor
    );

    RETURN v_assertion_id;
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
    v_candidate nodes;
    v_event_id uuid;
    v_label text;
    v_source_refs jsonb;
    v_task_id uuid;
BEGIN
    v_label := nullif(trim(p_label), '');

    IF v_label IS NULL THEN
        RAISE EXCEPTION 'Task label is required';
    END IF;

    SELECT *
    INTO v_candidate
    FROM nodes
    WHERE id = p_candidate_id
      AND node_type = 'knowledge_candidate'
      AND archived_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Knowledge candidate % not found', p_candidate_id;
    END IF;

    v_source_refs := knowledge_candidate_source_refs(p_candidate_id);

    INSERT INTO nodes (node_type, label, properties, attrs)
    VALUES (
        'task',
        v_label,
        coalesce(p_properties, '{}'::jsonb) || jsonb_build_object(
            'status', coalesce(p_properties->>'status', 'open'),
            'candidate_id', p_candidate_id,
            'source_refs', v_source_refs,
            'created_by', coalesce(p_actor, current_setting('app.current_user_id', true))
        ),
        jsonb_build_object(
            'candidate_id', p_candidate_id,
            'source_refs', v_source_refs
        )
    )
    RETURNING id INTO v_task_id;

    INSERT INTO edges (edge_type, source_id, target_id, properties, attrs)
    VALUES (
        'promoted_to',
        p_candidate_id,
        v_task_id,
        jsonb_build_object('target_type', 'task'),
        jsonb_build_object('candidate_id', p_candidate_id)
    );

    v_event_id := record_event(
        p_event_type        := 'knowledge_candidate_promoted',
        p_summary           := format('Knowledge candidate promoted to task: %s', left(v_label, 120)),
        p_properties        := jsonb_build_object(
            'candidate_id', p_candidate_id,
            'target_type', 'task',
            'task_node_id', v_task_id,
            'source_refs', v_source_refs
        ),
        p_participant_ids   := ARRAY[p_candidate_id, v_task_id],
        p_participant_roles := ARRAY['candidate', 'task'],
        p_actor             := p_actor
    );

    PERFORM record_assertion(
        p_assertion_type    := 'task_status',
        p_claim             := jsonb_build_object('status', coalesce(p_properties->>'status', 'open')),
        p_subject_node_id   := v_task_id,
        p_assertion_key     := 'default',
        p_source_event_id   := v_event_id,
        p_confidence        := 1.0,
        p_mode              := 'current',
        p_attrs             := jsonb_build_object(
            'candidate_id', p_candidate_id,
            'source_refs', v_source_refs,
            'promotion_event_id', v_event_id
        )
    );

    PERFORM set_candidate_status(
        p_candidate_id := p_candidate_id,
        p_status       := 'accepted',
        p_reason       := 'Promoted to task ' || v_task_id::text,
        p_actor        := p_actor
    );

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
    v_candidate nodes;
    v_edge_id uuid;
    v_event_id uuid;
    v_source_refs jsonb;
BEGIN
    IF nullif(trim(p_edge_type), '') IS NULL THEN
        RAISE EXCEPTION 'edge_type is required';
    END IF;

    IF p_effective_from IS NOT NULL
       AND p_effective_to IS NOT NULL
       AND p_effective_to <= p_effective_from
    THEN
        RAISE EXCEPTION 'effective_to must be after effective_from';
    END IF;

    SELECT *
    INTO v_candidate
    FROM nodes
    WHERE id = p_candidate_id
      AND node_type = 'knowledge_candidate'
      AND archived_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Knowledge candidate % not found', p_candidate_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = p_source_id AND archived_at IS NULL) THEN
        RAISE EXCEPTION 'Source node % not found', p_source_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = p_target_id AND archived_at IS NULL) THEN
        RAISE EXCEPTION 'Target node % not found', p_target_id;
    END IF;

    v_source_refs := knowledge_candidate_source_refs(p_candidate_id);

    v_event_id := record_event(
        p_event_type        := 'knowledge_candidate_promoted',
        p_summary           := format('Knowledge candidate promoted to edge: %s', p_edge_type),
        p_properties        := jsonb_build_object(
            'candidate_id', p_candidate_id,
            'target_type', 'edge',
            'source_id', p_source_id,
            'target_id', p_target_id,
            'edge_type', p_edge_type,
            'source_refs', v_source_refs
        ),
        p_participant_ids   := ARRAY[p_candidate_id, p_source_id, p_target_id],
        p_participant_roles := ARRAY['candidate', 'source', 'target'],
        p_actor             := p_actor
    );

    INSERT INTO edges (
        edge_type,
        source_id,
        target_id,
        properties,
        effective_from,
        effective_to,
        attrs
    ) VALUES (
        p_edge_type,
        p_source_id,
        p_target_id,
        coalesce(p_properties, '{}'::jsonb),
        p_effective_from,
        p_effective_to,
        jsonb_build_object(
            'candidate_id', p_candidate_id,
            'source_refs', v_source_refs,
            'promotion_event_id', v_event_id,
            'promoted_by', coalesce(p_actor, current_setting('app.current_user_id', true))
        )
    )
    RETURNING id INTO v_edge_id;

    PERFORM set_candidate_status(
        p_candidate_id := p_candidate_id,
        p_status       := 'accepted',
        p_reason       := 'Promoted to edge ' || v_edge_id::text,
        p_actor        := p_actor
    );

    RETURN v_edge_id;
END;
$$ LANGUAGE plpgsql;
