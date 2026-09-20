-- The reviewer's screen gets what it needs from the views.
--
-- Work item: work/016-admin-view-layer.md. Closes issue 12.
-- Contract:  contracts/sql-surface.md, "Review surfaces".
-- Decision:  docs/decisions/0012-review-surfaces-carry-what-the-screen-needs.md.
-- Tests:     tests/conformance/41_review_surfaces.sql.
--
-- Issue 12 listed five things a review screen needed and the views did not
-- carry, each of which admin/src/server/queries.ts compensated for with a
-- correlated subquery or could not compensate for at all. The compensation is
-- not the problem; a second client writing Rye's own rules again, differently,
-- is. This migration moves them into the views.
--
-- WHAT IS REPLACED. base_effective_confidence(assertions), review_queue,
-- competing_candidates, stale_digests. WHAT IS NEW.
-- base_effective_confidence_unchecked(assertions),
-- projected_effective_confidence(assertions), candidate_assertions_weighted,
-- review_queue_candidates, rejected_candidates. Nothing here touches
-- effective_confidence(), current_assertions_weighted, open_gaps,
-- node_salience, or any helper.
--
-- EXISTING COLUMNS DO NOT MOVE. review_queue and stale_digests keep every
-- column they had, with the same name, type, ordinal position, and content;
-- the new ones are appended. CREATE OR REPLACE VIEW enforces the prefix, but
-- it does not propagate: a dependent view keeps its own expanded column list,
-- so competing_candidates (SELECT * FROM review_queue) does not inherit the
-- appended columns and is re-issued here for that reason alone.
--
-- THE ARITHMETIC IS FACTORED, NOT FORKED. 0019's base_effective_confidence()
-- opens with a current_valid_assertions membership gate, which is why
-- effective_confidence() is null for every candidate. That body moves into
-- base_effective_confidence_unchecked() with the gate removed and one change
-- -- the competing-candidate discount excludes the row itself. The old name
-- becomes a wrapper that applies the gate and returns the same answers it
-- always did: a row in current_valid_assertions is accepted, so it was never
-- its own competitor and the exclusion is a no-op for it.
--
-- WAITING REASON. A row demoted by the review policy carries attrs.review_gate
-- (0027, 0030); one demoted by the settle gate carries attrs.settle_gate
-- (0023). settle_gate wins when candidates under one tuple carry both, because
-- that demotion is the one that needs an admin. 'none' is written rather than
-- null so a client branches without a null test.
--
-- REJECTED IS NOT WAITING. reject_candidate() (0019) leaves status 'candidate'
-- and sets superseded_at with superseded_by null. review_queue requires
-- superseded_at null, so the two sets are disjoint by construction rather than
-- by a filter someone has to remember.
--
-- VISIBILITY. Every view here is security_invoker and none is SECURITY
-- DEFINER, so each shows a caller exactly the rows it could select from the
-- base tables itself. A visible candidate whose incumbent is classified above
-- the caller's read level reads null incumbent_* and false
-- incumbent_is_current -- ordinary RLS silence, which never means absence.

SET search_path = rye, pg_catalog, public;

-- ---------------------------------------------------------------------------
-- A. The arithmetic, without the membership gate.
-- ---------------------------------------------------------------------------

-- 0019's base_effective_confidence() body, verbatim, with two differences:
-- the current_valid_assertions membership gate is gone, and the competing
-- candidate count excludes the row itself. Everything else -- basis prior,
-- source reliability discount, independent-witness lift, half-life decay,
-- competitor discount, clamp -- is unchanged, line for line.
CREATE OR REPLACE FUNCTION base_effective_confidence_unchecked(a assertions)
RETURNS numeric
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_age_seconds numeric;
    v_base numeric;
    v_competitors int;
    v_correction_rate numeric;
    v_discount numeric;
    v_half_life interval;
    v_half_life_json jsonb;
    v_independent int;
    v_lift numeric;
    v_low_sample boolean;
    v_newest_support timestamptz;
    v_result numeric;
    v_witness uuid;
BEGIN
    IF a.id IS NULL THEN
        RETURN NULL;
    END IF;

    v_base := coalesce(
        a.confidence,
        (registry_value('basis_prior:' || a.basis, NULL) #>> '{}')::numeric,
        0.50
    );

    SELECT witness_node_id INTO v_witness
    FROM assertion_evidence
    WHERE assertion_id = a.id
      AND kind = 'source'
      AND witness_node_id IS NOT NULL
    ORDER BY recorded_at, id
    LIMIT 1;

    IF v_witness IS NOT NULL THEN
        SELECT correction_rate, low_sample
        INTO v_correction_rate, v_low_sample
        FROM source_reliability
        WHERE witness_node_id = v_witness;
        IF coalesce(v_low_sample, true) = false THEN
            v_base := v_base * (1 - least(coalesce(v_correction_rate, 0), 0.5));
        END IF;
    END IF;

    SELECT count(DISTINCT witness_node_id) INTO v_independent
    FROM assertion_evidence
    WHERE assertion_id = a.id
      AND kind IN ('source', 'corroboration')
      AND witness_node_id IS NOT NULL;
    v_lift := 1 + 0.1 * least(v_independent, 3);

    SELECT max(recorded_at) INTO v_newest_support
    FROM assertion_evidence
    WHERE assertion_id = a.id
      AND kind = 'corroboration'
      AND coalesce((attrs->>'independent')::boolean, false);

    v_half_life_json := registry_value(
        'half_life:' || canonical_type('assertion_type', a.assertion_type), NULL
    );
    IF v_half_life_json IS NOT NULL AND jsonb_typeof(v_half_life_json) <> 'null' THEN
        v_half_life := (v_half_life_json #>> '{}')::interval;
    END IF;

    -- The one judgement in this migration. A projection answers "what would
    -- this row carry if it were the value", and at that moment it is not one
    -- of its own competitors. Without the exclusion a lone candidate projects
    -- 0.8 of what the identical claim reads a second after acceptance, which
    -- would teach reviewers to distrust the number.
    SELECT count(*) INTO v_competitors
    FROM assertions candidate
    WHERE candidate.subject_ref = a.subject_ref
      AND canonical_type('assertion_type', candidate.assertion_type)
          = canonical_type('assertion_type', a.assertion_type)
      AND candidate.assertion_key = a.assertion_key
      AND candidate.status = 'candidate'
      AND candidate.superseded_at IS NULL
      AND candidate.id <> a.id;
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

COMMENT ON FUNCTION base_effective_confidence_unchecked(assertions) IS
    'The confidence arithmetic with no current_valid_assertions membership gate, and with the row excluded from its own competing-candidate discount. base_effective_confidence() and projected_effective_confidence() are the two gates over it.';

-- Same answers as 0019's, by construction: the gate is applied here instead of
-- inside the arithmetic, and a row in current_valid_assertions is accepted, so
-- it never counted itself as a competing candidate.
CREATE OR REPLACE FUNCTION base_effective_confidence(a assertions)
RETURNS numeric
SET search_path = rye, pg_catalog
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM current_valid_assertions c WHERE c.id = a.id) THEN
        RETURN NULL;
    END IF;
    RETURN base_effective_confidence_unchecked(a);
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION base_effective_confidence(assertions) IS
    'Confidence arithmetic for a row that is in current_valid_assertions, null for any other row. Unchanged in behaviour from 0019; the body now delegates to base_effective_confidence_unchecked().';

-- What a live row would carry. Null for a row that is not live, so a
-- superseded or rejected candidate projects nothing. The pattern_claim cap is
-- exactly the one effective_confidence() applies.
CREATE OR REPLACE FUNCTION projected_effective_confidence(a assertions)
RETURNS numeric
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_pattern_cap numeric;
    v_result numeric;
BEGIN
    IF a.id IS NULL
       OR a.superseded_at IS NOT NULL
       OR a.status IS NULL
       OR a.status NOT IN ('candidate', 'accepted')
    THEN
        RETURN NULL;
    END IF;

    v_result := base_effective_confidence_unchecked(a);
    IF v_result IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT min(base_effective_confidence(ROW(pattern.*)::assertions))
    INTO v_pattern_cap
    FROM assertion_evidence ae
    JOIN current_valid_assertions pattern ON pattern.id = ae.source_assertion_id
    JOIN nodes pattern_node ON pattern_node.id = pattern.subject_node_id
    WHERE ae.assertion_id = a.id
      AND ae.kind = 'derivation'
      AND pattern.assertion_type = 'pattern_claim'
      AND pattern_node.node_type = 'pattern';

    IF v_pattern_cap IS NOT NULL THEN
        v_result := least(v_result, v_pattern_cap);
    END IF;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION projected_effective_confidence(assertions) IS
    'What a live assertion would carry as the current value: the same arithmetic as effective_confidence(), with the row excluded from its own competing-candidate discount. Null unless superseded_at is null and status is candidate or accepted. For a row in current_valid_assertions it equals effective_confidence().';

-- The candidate mirror of current_assertions_weighted (0019).
CREATE OR REPLACE VIEW candidate_assertions_weighted
WITH (security_invoker = true) AS
SELECT a.*, projected_effective_confidence(ROW(a.*)::assertions) AS projected_effective_confidence
FROM assertions a
WHERE a.status = 'candidate'
  AND a.superseded_at IS NULL;

COMMENT ON VIEW candidate_assertions_weighted IS
    'Live candidates with the confidence each would carry if accepted. The candidate mirror of current_assertions_weighted.';

-- ---------------------------------------------------------------------------
-- B. review_queue says who, against what, and why it is waiting.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW review_queue
WITH (security_invoker = true) AS
SELECT
    -- 0018's columns, in 0018's order, with 0018's content.
    q.subject_ref,
    q.subject_node_id,
    q.subject_edge_id,
    q.assertion_type,
    q.assertion_key,
    q.candidate_count,
    q.candidates,
    -- Appended by 0035.
    subject.label AS subject_label,
    subject.node_type AS subject_node_type,
    q.newest_candidate_at,
    inc.id AS incumbent_assertion_id,
    inc.claim AS incumbent_claim,
    inc.basis AS incumbent_basis,
    inc.confidence AS incumbent_confidence,
    inc.effective_confidence AS incumbent_effective_confidence,
    inc.asserted_at AS incumbent_asserted_at,
    inc.attrs AS incumbent_attrs,
    coalesce(inc.is_current, false) AS incumbent_is_current,
    q.waiting_reason,
    q.waiting_detail
FROM (
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
        ) ORDER BY a.asserted_at, a.id) AS candidates,
        max(a.asserted_at) AS newest_candidate_at,
        CASE
            WHEN bool_or(a.attrs ? 'settle_gate') THEN 'settle_gate'
            WHEN bool_or(a.attrs ? 'review_gate') THEN 'review_gate'
            ELSE 'none'
        END AS waiting_reason,
        CASE
            WHEN bool_or(a.attrs ? 'settle_gate') THEN (
                array_agg(a.attrs->'settle_gate' ORDER BY a.asserted_at, a.id)
                    FILTER (WHERE a.attrs ? 'settle_gate')
            )[1]
            WHEN bool_or(a.attrs ? 'review_gate') THEN (
                array_agg(a.attrs->'review_gate' ORDER BY a.asserted_at, a.id)
                    FILTER (WHERE a.attrs ? 'review_gate')
            )[1]
            ELSE NULL
        END AS waiting_detail
    FROM assertions a
    WHERE a.status = 'candidate'
      AND a.superseded_at IS NULL
    GROUP BY
        a.subject_ref,
        a.subject_node_id,
        a.subject_edge_id,
        canonical_type('assertion_type', a.assertion_type),
        a.assertion_key
) q
LEFT JOIN nodes subject ON subject.id = q.subject_node_id
LEFT JOIN LATERAL (
    -- The row an acceptance would supersede: accepted and unsuperseded, which
    -- is not always the row that is currently effective. A future-dated or
    -- expired accepted row is displaced by an acceptance just the same, and
    -- current_valid_assertions does not show it; is_current keeps the old
    -- distinction visible instead of losing it.
    SELECT
        i.id,
        i.claim,
        i.basis,
        i.confidence,
        i.asserted_at,
        i.attrs,
        effective_confidence(ROW(i.*)::assertions) AS effective_confidence,
        EXISTS (SELECT 1 FROM current_valid_assertions c WHERE c.id = i.id) AS is_current
    FROM assertions i
    WHERE i.subject_ref = q.subject_ref
      AND canonical_type('assertion_type', i.assertion_type) = q.assertion_type
      AND i.assertion_key = q.assertion_key
      AND i.status = 'accepted'
      AND i.superseded_at IS NULL
    ORDER BY i.asserted_at DESC, i.id
    LIMIT 1
) inc ON true;

COMMENT ON VIEW review_queue IS
    'Live candidates grouped by subject, canonical assertion type, and assertion key, with the subject label, the accepted unsuperseded incumbent an acceptance would supersede, and why the tuple is waiting (settle_gate, review_gate, or none). Null incumbent_* is RLS silence as often as it is absence.';

-- Re-issued, not because its text changed but because a dependent view keeps
-- its own expanded column list: without this, competing_candidates would still
-- have 0018's seven columns.
CREATE OR REPLACE VIEW competing_candidates
WITH (security_invoker = true) AS
SELECT * FROM review_queue WHERE candidate_count > 1;

COMMENT ON VIEW competing_candidates IS
    'review_queue restricted to tuples with more than one live candidate. Carries every review_queue column.';

-- One row per live candidate, for clients that were unnesting
-- review_queue.candidates to join assertions. The evidence columns are a
-- summary, not the evidence: a drawer that wants event summaries and witness
-- labels still joins assertion_support.
CREATE OR REPLACE VIEW review_queue_candidates
WITH (security_invoker = true) AS
SELECT
    a.id AS assertion_id,
    a.subject_ref,
    a.subject_node_id,
    a.subject_edge_id,
    subject.label AS subject_label,
    canonical_type('assertion_type', a.assertion_type) AS assertion_type,
    a.assertion_type AS stored_assertion_type,
    a.assertion_key,
    a.claim,
    a.basis,
    a.confidence,
    a.classification,
    projected_effective_confidence(ROW(a.*)::assertions) AS projected_effective_confidence,
    (registry_value('basis_prior:' || a.basis, NULL) #>> '{}')::numeric AS basis_prior,
    a.asserted_at,
    a.effective_at,
    a.effective_to,
    a.attrs,
    CASE
        WHEN a.attrs ? 'settle_gate' THEN 'settle_gate'
        WHEN a.attrs ? 'review_gate' THEN 'review_gate'
        ELSE 'none'
    END AS waiting_reason,
    CASE
        WHEN a.attrs ? 'settle_gate' THEN a.attrs->'settle_gate'
        WHEN a.attrs ? 'review_gate' THEN a.attrs->'review_gate'
        ELSE NULL
    END AS waiting_detail,
    inc.id AS incumbent_assertion_id,
    coalesce(ev.evidence_count, 0) AS evidence_count,
    coalesce(ev.witness_count, 0) AS witness_count,
    coalesce(ev.evidence_kinds, '{}'::text[]) AS evidence_kinds,
    ev.latest_evidence_at
FROM assertions a
LEFT JOIN nodes subject ON subject.id = a.subject_node_id
LEFT JOIN LATERAL (
    SELECT i.id
    FROM assertions i
    WHERE i.subject_ref = a.subject_ref
      AND canonical_type('assertion_type', i.assertion_type)
          = canonical_type('assertion_type', a.assertion_type)
      AND i.assertion_key = a.assertion_key
      AND i.status = 'accepted'
      AND i.superseded_at IS NULL
    ORDER BY i.asserted_at DESC, i.id
    LIMIT 1
) inc ON true
LEFT JOIN LATERAL (
    -- Counts only evidence this caller can read, so two callers may see
    -- different numbers for one candidate. That is visibility, not
    -- disagreement.
    SELECT
        count(*) AS evidence_count,
        count(DISTINCT e.witness_node_id) FILTER (
            WHERE e.kind IN ('source', 'corroboration') AND e.witness_node_id IS NOT NULL
        ) AS witness_count,
        array_agg(DISTINCT e.kind) AS evidence_kinds,
        max(e.recorded_at) AS latest_evidence_at
    FROM assertion_evidence e
    WHERE e.assertion_id = a.id
) ev ON true
WHERE a.status = 'candidate'
  AND a.superseded_at IS NULL;

COMMENT ON VIEW review_queue_candidates IS
    'One row per live candidate: its own columns, the subject label, the projected effective confidence, the basis prior, why it is waiting, the incumbent it would supersede, and an evidence summary. Evidence counts reflect only what the calling session may read.';

-- ---------------------------------------------------------------------------
-- C. stale_digests names the culprit.
-- ---------------------------------------------------------------------------

-- The booleans are now read off the arrays rather than computed beside them,
-- so newer_subject_assertion is exactly cardinality(newer_assertion_ids) > 0
-- row by row, and membership is unchanged: the same two EXISTS conditions,
-- spelled as "the array is not empty".
CREATE OR REPLACE VIEW stale_digests
WITH (security_invoker = true) AS
SELECT
    -- 0018's columns, in 0018's order.
    digest.digest_assertion_id,
    digest.subject_ref,
    digest.subject_node_id,
    digest.subject_edge_id,
    digest.assertion_key,
    digest.watermark,
    digest.newer_subject_assertion,
    digest.overturned_source,
    digest.salience_score,
    -- Appended by 0035. The arrays are empty, never null.
    digest.newer_assertion_ids,
    digest.newer_latest_asserted_at,
    digest.overturned_source_assertion_ids
FROM (
    SELECT
        d.id AS digest_assertion_id,
        d.subject_ref,
        d.subject_node_id,
        d.subject_edge_id,
        d.assertion_key,
        (d.attrs->>'watermark')::timestamptz AS watermark,
        cardinality(newer.ids) > 0 AS newer_subject_assertion,
        cardinality(overturned.ids) > 0 AS overturned_source,
        salience.salience_score,
        newer.ids AS newer_assertion_ids,
        newer.latest_asserted_at AS newer_latest_asserted_at,
        overturned.ids AS overturned_source_assertion_ids
    FROM current_valid_assertions d
    LEFT JOIN node_salience salience ON salience.node_id = d.subject_node_id
    CROSS JOIN LATERAL (
        SELECT
            coalesce(array_agg(n.id ORDER BY n.asserted_at, n.id), '{}'::uuid[]) AS ids,
            max(n.asserted_at) AS latest_asserted_at
        FROM current_valid_assertions n
        WHERE n.subject_ref = d.subject_ref
          AND n.assertion_type <> 'digest'
          AND n.asserted_at > (d.attrs->>'watermark')::timestamptz
    ) newer
    CROSS JOIN LATERAL (
        SELECT coalesce(array_agg(DISTINCT source.id), '{}'::uuid[]) AS ids
        FROM assertion_evidence ae
        JOIN assertions source ON source.id = ae.source_assertion_id
        WHERE ae.assertion_id = d.id
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
    ) overturned
    WHERE d.assertion_type = 'digest'
      AND d.attrs ? 'watermark'
) digest
WHERE digest.newer_subject_assertion OR digest.overturned_source;

COMMENT ON VIEW stale_digests IS
    'Stale accepted digests with advisory subject salience for hot-first ordering; salience never gates membership. Names the culprit: newer_assertion_ids, newer_latest_asserted_at, and overturned_source_assertion_ids, empty and never null when the matching boolean is false.';

-- ---------------------------------------------------------------------------
-- D. Rejected candidates are a surface, and are never "waiting".
-- ---------------------------------------------------------------------------

-- Membership is a closed candidate with no superseded_by. A candidate closed
-- by naming a replacement was displaced, not rejected, and belongs to the
-- supersession chain. The event join is LEFT: a candidate closed by a raw
-- update has no candidate_rejected event, and the row still appears with null
-- rejected_by and rejected_reason, because a surface that hides an unexplained
-- rejection is worse than one that shows it as unexplained.
CREATE OR REPLACE VIEW rejected_candidates
WITH (security_invoker = true) AS
SELECT
    a.id AS assertion_id,
    a.subject_ref,
    a.subject_node_id,
    a.subject_edge_id,
    subject.label AS subject_label,
    canonical_type('assertion_type', a.assertion_type) AS assertion_type,
    a.assertion_type AS stored_assertion_type,
    a.assertion_key,
    a.claim,
    a.basis,
    a.confidence,
    a.classification,
    a.attrs,
    a.asserted_at,
    a.superseded_at AS rejected_at,
    rejection.actor_system AS rejected_by,
    rejection.properties->>'reason' AS rejected_reason,
    coalesce(a.attrs->>'outcome', rejection.properties->>'outcome') AS rejected_outcome,
    rejection.id AS rejection_event_id
FROM assertions a
LEFT JOIN nodes subject ON subject.id = a.subject_node_id
LEFT JOIN LATERAL (
    SELECT e.id, e.actor_system, e.properties
    FROM events e
    WHERE e.event_type = 'candidate_rejected'
      AND e.properties->>'assertion_id' = a.id::text
    ORDER BY e.occurred_at DESC, e.id
    LIMIT 1
) rejection ON true
WHERE a.status = 'candidate'
  AND a.superseded_at IS NOT NULL
  AND a.superseded_by IS NULL;

COMMENT ON VIEW rejected_candidates IS
    'Candidates closed without a replacement, with who rejected, when, why, and the outcome label, read from the candidate_rejected event. Disjoint from review_queue by construction: review_queue requires superseded_at null.';
