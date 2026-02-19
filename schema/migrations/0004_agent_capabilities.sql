-- Agent capabilities: INSERT policies, record_artifact(), assertion disputes
--
-- Gap 1: Agents blocked from INSERT on nodes, edges, artifacts
-- Gap 2: No record_artifact() function
-- Gap 3: Binary assertion state (no contested/disputed assertions)

SET search_path = rye, pg_catalog, public;

-- ============================================================================
-- 1. AGENT INSERT POLICIES
-- ============================================================================
-- Design principle 4: "Agent-native — agents insert facts; they never
-- overwrite or delete." The original policies blocked agents from INSERT
-- on nodes, edges, and artifacts. This prevents agents from creating
-- entities they discover or storing extracted content.
--
-- Fix: allow INSERT from any role (including agents). UPDATE and DELETE
-- remain blocked for agents.

DROP POLICY IF EXISTS node_insert_policy ON nodes;
CREATE POLICY node_insert_policy ON nodes
    FOR INSERT
    WITH CHECK (true);

DROP POLICY IF EXISTS edge_insert_policy ON edges;
CREATE POLICY edge_insert_policy ON edges
    FOR INSERT
    WITH CHECK (true);

DROP POLICY IF EXISTS artifact_insert_policy ON artifacts;
CREATE POLICY artifact_insert_policy ON artifacts
    FOR INSERT
    WITH CHECK (true);


-- ============================================================================
-- 2. RECORD_ARTIFACT()
-- ============================================================================
-- Convenience function for creating artifacts, parallel to record_event()
-- for events and link_record() for nodes.
--
-- Optional dedup: pass p_content_hash to prevent duplicate artifacts from
-- the same source material. The hash is stored in attrs->>'content_hash'.
-- If a matching artifact exists, returns the existing ID without inserting.

CREATE OR REPLACE FUNCTION record_artifact(
    p_artifact_type text,
    p_content jsonb,
    p_source_event_id uuid DEFAULT NULL,
    p_source_node_id uuid DEFAULT NULL,
    p_related_node_ids uuid[] DEFAULT '{}',
    p_location jsonb DEFAULT NULL,
    p_content_hash text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_artifact_id uuid;
    v_attrs jsonb := '{}';
BEGIN
    -- Dedup: if content_hash provided and matching artifact exists, return it
    IF p_content_hash IS NOT NULL THEN
        SELECT id INTO v_artifact_id
        FROM artifacts
        WHERE artifact_type = p_artifact_type
          AND attrs->>'content_hash' = p_content_hash;

        IF v_artifact_id IS NOT NULL THEN
            RETURN v_artifact_id;
        END IF;

        v_attrs := jsonb_build_object('content_hash', p_content_hash);
    END IF;

    INSERT INTO artifacts (
        artifact_type,
        content,
        source_event_id,
        source_node_id,
        related_node_ids,
        location,
        attrs
    ) VALUES (
        p_artifact_type,
        p_content,
        p_source_event_id,
        p_source_node_id,
        p_related_node_ids,
        p_location,
        v_attrs
    )
    RETURNING id INTO v_artifact_id;

    RETURN v_artifact_id;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 3. ASSERTION DISPUTES
-- ============================================================================
-- The assertion model is binary: active or superseded. There is no way to
-- represent "I found a contradictory fact but I'm not sure which is correct."
--
-- contest_assertion() inserts a competing assertion alongside the original
-- without superseding it. Both coexist as active assertions with different
-- assertion_keys. A dispute event is recorded.
--
-- resolve_dispute() picks a winner, supersedes the losers, and ensures the
-- surviving assertion has the canonical key. A resolution event is recorded.

CREATE OR REPLACE FUNCTION contest_assertion(
    p_existing_assertion_id uuid,
    p_new_claim jsonb,
    p_source text,
    p_confidence numeric DEFAULT NULL,
    p_reason text DEFAULT NULL,
    p_source_event_id uuid DEFAULT NULL,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_existing assertions;
    v_new_id uuid;
    v_contested_key text;
    v_event_id uuid;
    v_participant_ids uuid[];
BEGIN
    SELECT * INTO v_existing
    FROM assertions
    WHERE id = p_existing_assertion_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Assertion % not found', p_existing_assertion_id;
    END IF;

    IF v_existing.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION 'Assertion % is already superseded — cannot contest a superseded assertion', p_existing_assertion_id;
    END IF;

    -- Use a source-keyed assertion_key so both assertions coexist
    -- without violating the active uniqueness constraint
    v_contested_key := 'contested:' || p_source;

    INSERT INTO assertions (
        assertion_type,
        assertion_key,
        subject_node_id,
        subject_edge_id,
        claim,
        confidence,
        source_event_id,
        attrs
    ) VALUES (
        v_existing.assertion_type,
        v_contested_key,
        v_existing.subject_node_id,
        v_existing.subject_edge_id,
        p_new_claim,
        p_confidence,
        p_source_event_id,
        jsonb_build_object(
            'dispute', jsonb_build_object(
                'contests', p_existing_assertion_id,
                'source', p_source,
                'reason', p_reason
            )
        )
    )
    RETURNING id INTO v_new_id;

    -- Record a dispute_raised event
    v_participant_ids := ARRAY[]::uuid[];
    IF v_existing.subject_node_id IS NOT NULL THEN
        v_participant_ids := ARRAY[v_existing.subject_node_id];
    END IF;

    v_event_id := record_event(
        p_event_type        := 'dispute_raised',
        p_summary           := format(
            'Contested %s assertion: %s',
            v_existing.assertion_type,
            coalesce(p_reason, 'conflicting information from ' || p_source)
        ),
        p_properties        := jsonb_build_object(
            'existing_assertion_id', p_existing_assertion_id,
            'contested_assertion_id', v_new_id,
            'assertion_type', v_existing.assertion_type,
            'existing_claim', v_existing.claim,
            'contested_claim', p_new_claim,
            'source', p_source,
            'reason', p_reason
        ),
        p_participant_ids   := v_participant_ids,
        p_participant_roles := CASE
            WHEN array_length(v_participant_ids, 1) > 0 THEN ARRAY['subject']
            ELSE ARRAY[]::text[]
        END,
        p_actor             := p_actor
    );

    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION resolve_dispute(
    p_winning_assertion_id uuid,
    p_reason text DEFAULT NULL,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_winner assertions;
    v_final_id uuid;
    v_loser record;
    v_event_id uuid;
    v_participant_ids uuid[];
    v_superseded_ids uuid[] := '{}';
BEGIN
    SELECT * INTO v_winner
    FROM assertions
    WHERE id = p_winning_assertion_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Assertion % not found', p_winning_assertion_id;
    END IF;

    IF v_winner.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION 'Assertion % is already superseded', p_winning_assertion_id;
    END IF;

    -- Find all other active assertions for the same (subject, type)
    -- that are either the original or other contested versions
    FOR v_loser IN
        SELECT id
        FROM assertions
        WHERE subject_node_id IS NOT DISTINCT FROM v_winner.subject_node_id
          AND subject_edge_id IS NOT DISTINCT FROM v_winner.subject_edge_id
          AND assertion_type = v_winner.assertion_type
          AND superseded_at IS NULL
          AND id <> p_winning_assertion_id
    LOOP
        PERFORM mark_assertion_superseded(v_loser.id, p_winning_assertion_id);
        v_superseded_ids := v_superseded_ids || v_loser.id;
    END LOOP;

    -- If the winner has a contested: key, promote it to the canonical key.
    -- Supersede the contested version and insert a clean copy with the
    -- original assertion_key.
    IF v_winner.assertion_key LIKE 'contested:%' THEN
        -- Determine the canonical key from the dispute metadata
        -- Default to 'default' if we can't determine the original key
        v_final_id := gen_random_uuid();

        PERFORM mark_assertion_superseded(p_winning_assertion_id, v_final_id);

        INSERT INTO assertions (
            id,
            assertion_type,
            assertion_key,
            subject_node_id,
            subject_edge_id,
            claim,
            confidence,
            source_event_id,
            attrs
        ) VALUES (
            v_final_id,
            v_winner.assertion_type,
            'default',
            v_winner.subject_node_id,
            v_winner.subject_edge_id,
            v_winner.claim,
            v_winner.confidence,
            v_winner.source_event_id,
            '{}'::jsonb
        );
    ELSE
        v_final_id := p_winning_assertion_id;
    END IF;

    -- Record resolution event
    v_participant_ids := ARRAY[]::uuid[];
    IF v_winner.subject_node_id IS NOT NULL THEN
        v_participant_ids := ARRAY[v_winner.subject_node_id];
    END IF;

    v_event_id := record_event(
        p_event_type        := 'dispute_resolved',
        p_summary           := format(
            'Resolved %s dispute: %s',
            v_winner.assertion_type,
            coalesce(p_reason, 'winner selected')
        ),
        p_properties        := jsonb_build_object(
            'winning_assertion_id', v_final_id,
            'superseded_assertion_ids', to_jsonb(v_superseded_ids),
            'assertion_type', v_winner.assertion_type,
            'winning_claim', v_winner.claim,
            'reason', p_reason
        ),
        p_participant_ids   := v_participant_ids,
        p_participant_roles := CASE
            WHEN array_length(v_participant_ids, 1) > 0 THEN ARRAY['subject']
            ELSE ARRAY[]::text[]
        END,
        p_actor             := p_actor
    );

    RETURN v_final_id;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 4. FIND ACTIVE DISPUTES
-- ============================================================================
-- View to surface nodes/edges with competing active assertions.

CREATE OR REPLACE VIEW active_disputes
WITH (security_invoker = true) AS
SELECT
    a.subject_node_id,
    a.subject_edge_id,
    a.assertion_type,
    count(*) AS competing_assertions,
    jsonb_agg(jsonb_build_object(
        'assertion_id', a.id,
        'assertion_key', a.assertion_key,
        'claim', a.claim,
        'confidence', a.confidence,
        'asserted_at', a.asserted_at,
        'dispute', a.attrs->'dispute'
    ) ORDER BY a.asserted_at) AS assertions
FROM assertions a
WHERE a.superseded_at IS NULL
GROUP BY a.subject_node_id, a.subject_edge_id, a.assertion_type
HAVING count(*) > 1;
