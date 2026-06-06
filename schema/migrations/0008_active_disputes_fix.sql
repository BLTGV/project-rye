-- 0008_active_disputes_fix.sql
--
-- Refine active_disputes so it surfaces genuine contested assertions rather
-- than any subject that merely has multiple active assertions of the same type.
--
-- The original view flagged every (subject, assertion_type) group with more
-- than one active assertion. That conflates two different things:
--   1. a single-valued fact with competing claims (a real dispute, created via
--      contest_assertion, which marks the contesting row with attrs->'dispute'), and
--   2. a multi-valued, append-only log (e.g. 'observation' or 'action_item'),
--      where many active assertions per subject is the intended, healthy state.
--
-- A true dispute is identifiable: contest_assertion() stamps attrs->'dispute'
-- on the contesting assertion. We require at least one such marker in the group.
-- Same columns/shape as before, so consumers (admin console, agents) are unaffected.

SET search_path = rye, pg_catalog;

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
        'source_event_id', a.source_event_id,
        'dispute', a.attrs->'dispute'
    ) ORDER BY a.asserted_at) AS assertions
FROM assertions a
WHERE a.superseded_at IS NULL
GROUP BY a.subject_node_id, a.subject_edge_id, a.assertion_type
HAVING count(*) FILTER (WHERE a.attrs ? 'dispute') > 0;
