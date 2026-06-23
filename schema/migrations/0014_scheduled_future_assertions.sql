-- Scheduled future assertions.
--
-- A future-effective accepted assertion should not make today's accepted
-- assertion disappear. This migration lets record_assertion schedule a future
-- row for the same subject/type/key by closing the current row's effective
-- window at the future effective_at, while leaving both rows unsuperseded.

SET search_path = rye, pg_catalog, public;

DROP INDEX IF EXISTS idx_assertions_active_unique;

CREATE UNIQUE INDEX IF NOT EXISTS idx_assertions_active_window_unique
    ON assertions (
        subject_ref,
        assertion_type,
        assertion_key,
        coalesce(effective_at, '-infinity'::timestamptz),
        coalesce(effective_to, 'infinity'::timestamptz)
    )
    WHERE superseded_at IS NULL;

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
    );

CREATE OR REPLACE FUNCTION assertions_immutable_guard() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
BEGIN
    IF NEW.claim IS NOT DISTINCT FROM OLD.claim
       AND NEW.assertion_type IS NOT DISTINCT FROM OLD.assertion_type
       AND NEW.assertion_key IS NOT DISTINCT FROM OLD.assertion_key
       AND NEW.subject_node_id IS NOT DISTINCT FROM OLD.subject_node_id
       AND NEW.subject_edge_id IS NOT DISTINCT FROM OLD.subject_edge_id
       AND NEW.asserted_at IS NOT DISTINCT FROM OLD.asserted_at
       AND NEW.effective_at IS NOT DISTINCT FROM OLD.effective_at
       AND NEW.source_event_id IS NOT DISTINCT FROM OLD.source_event_id
       AND NEW.confidence IS NOT DISTINCT FROM OLD.confidence
       AND NEW.attrs IS NOT DISTINCT FROM OLD.attrs
       AND NEW.created_at IS NOT DISTINCT FROM OLD.created_at
    THEN
        IF NEW.effective_to IS DISTINCT FROM OLD.effective_to THEN
            IF NEW.effective_to IS NULL
               OR (OLD.effective_at IS NOT NULL AND NEW.effective_to <= OLD.effective_at)
               OR (OLD.effective_to IS NOT NULL AND NEW.effective_to > OLD.effective_to)
            THEN
                RAISE EXCEPTION
                    'Only narrowing an assertion effective_to window is allowed.';
            END IF;
        END IF;

        RETURN NEW;
    END IF;

    RAISE EXCEPTION
        'Assertion content is immutable. Only superseded_at, superseded_by, and effective_to window narrowing may be updated.';
END;
$$ LANGUAGE plpgsql;

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
    v_future_existing assertions;
    v_has_existing boolean := false;
    v_mode text;
    v_next_future_at timestamptz;
    v_new_id uuid;
    v_new_effective_to timestamptz;
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

    IF p_effective_at IS NOT NULL AND p_effective_at > now() THEN
        SELECT *
        INTO v_future_existing
        FROM assertions
        WHERE subject_node_id IS NOT DISTINCT FROM p_subject_node_id
          AND subject_edge_id IS NOT DISTINCT FROM p_subject_edge_id
          AND assertion_type = p_assertion_type
          AND assertion_key = v_assertion_key
          AND superseded_at IS NULL
          AND effective_at IS NOT DISTINCT FROM p_effective_at
          AND effective_to IS NOT DISTINCT FROM p_effective_to
        LIMIT 1;

        IF FOUND
           AND v_future_existing.claim = p_claim
           AND v_future_existing.confidence IS NOT DISTINCT FROM p_confidence
        THEN
            RETURN v_future_existing.id;
        END IF;

        v_new_id := gen_random_uuid();

        IF FOUND THEN
            PERFORM mark_assertion_superseded(v_future_existing.id, v_new_id);
        END IF;

        SELECT *
        INTO v_existing
        FROM assertions
        WHERE subject_node_id IS NOT DISTINCT FROM p_subject_node_id
          AND subject_edge_id IS NOT DISTINCT FROM p_subject_edge_id
          AND assertion_type = p_assertion_type
          AND assertion_key = v_assertion_key
          AND superseded_at IS NULL
          AND (effective_at IS NULL OR effective_at <= now())
          AND (effective_to IS NULL OR effective_to > now())
        ORDER BY effective_at DESC NULLS LAST, created_at DESC
        LIMIT 1;

        IF FOUND
           AND (v_existing.effective_to IS NULL OR v_existing.effective_to > p_effective_at)
        THEN
            PERFORM set_config('app.write_path', 'assertion_effective_window', true);
            PERFORM set_config('app.effective_window_assertion_id', v_existing.id::text, true);

            UPDATE assertions
            SET effective_to = p_effective_at
            WHERE id = v_existing.id;

            PERFORM set_config('app.write_path', '', true);
            PERFORM set_config('app.effective_window_assertion_id', '', true);
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
            v_attrs || jsonb_build_object('record_mode', 'current', 'scheduled_future', true)
        );

        RETURN v_new_id;
    END IF;

    SELECT min(effective_at)
    INTO v_next_future_at
    FROM assertions
    WHERE subject_node_id IS NOT DISTINCT FROM p_subject_node_id
      AND subject_edge_id IS NOT DISTINCT FROM p_subject_edge_id
      AND assertion_type = p_assertion_type
      AND assertion_key = v_assertion_key
      AND superseded_at IS NULL
      AND effective_at > now();

    v_new_effective_to := p_effective_to;
    IF v_next_future_at IS NOT NULL
       AND (v_new_effective_to IS NULL OR v_new_effective_to > v_next_future_at)
    THEN
        v_new_effective_to := v_next_future_at;
    END IF;

    SELECT *
    INTO v_existing
    FROM assertions
    WHERE subject_node_id IS NOT DISTINCT FROM p_subject_node_id
      AND subject_edge_id IS NOT DISTINCT FROM p_subject_edge_id
      AND assertion_type = p_assertion_type
      AND assertion_key = v_assertion_key
      AND superseded_at IS NULL
      AND (effective_at IS NULL OR effective_at <= now())
      AND (effective_to IS NULL OR effective_to > now())
    ORDER BY effective_at DESC NULLS LAST, created_at DESC
    LIMIT 1;

    v_has_existing := FOUND;

    IF v_has_existing
       AND v_existing.claim = p_claim
       AND v_existing.effective_at IS NOT DISTINCT FROM p_effective_at
       AND v_existing.effective_to IS NOT DISTINCT FROM v_new_effective_to
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
        v_new_effective_to,
        p_source_event_id,
        p_confidence,
        v_attrs || jsonb_build_object('record_mode', 'current')
    );

    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;
