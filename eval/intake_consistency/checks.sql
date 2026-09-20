-- The four intake consistency checks, executable.
--
-- These are reads. They change nothing and need no more than a role that may
-- see the rows. The same four queries are documented, with what each one can
-- and cannot decide, in
-- skills/rye-pattern-library/references/intake-consistency-checks.md.
-- Edit both or they drift.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f eval/intake_consistency/checks.sql
--
-- A clean instance returns no rows from any of them.

\set ON_ERROR_STOP on
SET search_path = rye, public, pg_catalog;
SET ROLE rye_conformance;
SELECT set_config('app.current_role', 'team_member', false) \g /dev/null

\echo '== check 1: departed people with an open employs or role edge =='

WITH role_edge_type(edge_type) AS (
    VALUES ('employs'), ('reports_to'), ('assigned_to'),
           ('member_of'), ('project_member'), ('affiliated_with')
),
departed AS (
    SELECT a.subject_node_id AS person_id,
           a.id              AS departure_assertion_id,
           a.effective_at    AS departed_at
    FROM current_valid_assertions a
    WHERE a.assertion_type = 'employment_status'
      AND a.claim->>'status' = 'departed'
      AND a.subject_node_id IS NOT NULL
)
SELECT n.label        AS person,
       d.departed_at,
       e.id           AS open_edge_id,
       e.edge_type,
       e.effective_to,
       d.departure_assertion_id
FROM departed d
JOIN nodes n ON n.id = d.person_id
JOIN edges e ON e.source_id = d.person_id OR e.target_id = d.person_id
JOIN role_edge_type r ON r.edge_type = e.edge_type
WHERE e.archived_at IS NULL
  AND (e.effective_to IS NULL OR e.effective_to > d.departed_at)
ORDER BY n.label, e.edge_type;

\echo '== check 2: digest claim keys no source assertion covers =='

WITH digest AS (
    SELECT a.id, a.assertion_key, a.claim
    FROM assertions a
    WHERE a.assertion_type = 'digest'
      AND a.superseded_at IS NULL
      AND jsonb_typeof(a.claim) = 'object'
),
digest_key AS (
    SELECT d.id, d.assertion_key, k.key AS claim_key
    FROM digest d
    CROSS JOIN LATERAL jsonb_object_keys(d.claim) AS k(key)
    WHERE k.key NOT IN ('as_of', 'summary', 'narrative', 'source_window')
),
source_key AS (
    SELECT ae.assertion_id AS id, k.key AS claim_key
    FROM assertion_evidence ae
    JOIN assertions s ON s.id = ae.source_assertion_id
    CROSS JOIN LATERAL jsonb_object_keys(s.claim) AS k(key)
    WHERE ae.kind = 'derivation'
      AND jsonb_typeof(s.claim) = 'object'
)
SELECT dk.id AS digest_assertion_id,
       dk.assertion_key AS facet,
       dk.claim_key AS uncovered_key
FROM digest_key dk
WHERE NOT EXISTS (
    SELECT 1 FROM source_key sk
    WHERE sk.id = dk.id AND sk.claim_key = dk.claim_key
)
ORDER BY dk.id, dk.claim_key;

\echo '== check 3: assertions whose effective_at disagrees with the edge window =='

WITH named_edge AS MATERIALIZED (
    SELECT a.id, a.assertion_type, a.assertion_key, a.effective_at,
           a.subject_edge_id AS edge_id
    FROM assertions a
    WHERE a.superseded_at IS NULL
      AND a.subject_edge_id IS NOT NULL
      AND a.effective_at IS NOT NULL
    UNION ALL
    SELECT a.id, a.assertion_type, a.assertion_key, a.effective_at,
           (a.attrs->>'edge_id')::uuid
    FROM assertions a
    WHERE a.superseded_at IS NULL
      AND a.subject_edge_id IS NULL
      AND a.effective_at IS NOT NULL
      AND a.attrs->>'edge_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
)
SELECT ne.id AS assertion_id,
       ne.assertion_type,
       ne.assertion_key,
       ne.effective_at,
       e.id AS edge_id,
       e.edge_type,
       e.effective_from,
       e.effective_to
FROM named_edge ne
JOIN edges e ON e.id = ne.edge_id
WHERE (e.effective_from IS NOT NULL AND ne.effective_at < e.effective_from)
   OR (e.effective_to   IS NOT NULL AND ne.effective_at >= e.effective_to)
ORDER BY ne.id;

\echo '== check 4a: derived numeric claims citing no source window =='

WITH derived AS (
    SELECT a.id, a.assertion_type, a.assertion_key, a.claim, a.attrs
    FROM assertions a
    WHERE a.superseded_at IS NULL
      AND (a.basis = 'inferred' OR a.assertion_type = 'digest')
      AND jsonb_typeof(a.claim) = 'object'
      AND EXISTS (
          SELECT 1 FROM jsonb_each(a.claim) v
          WHERE jsonb_typeof(v.value) = 'number'
      )
)
SELECT d.id AS assertion_id,
       d.assertion_type,
       d.assertion_key,
       d.attrs->'source_window' AS cited_window
FROM derived d
WHERE d.attrs#>>'{source_window,from}' IS NULL
   OR d.attrs#>>'{source_window,to}'   IS NULL
   OR d.attrs#>>'{source_window,from}' !~ '^\d{4}-\d{2}-\d{2}'
   OR d.attrs#>>'{source_window,to}'   !~ '^\d{4}-\d{2}-\d{2}'
ORDER BY d.id;

\echo '== check 4b: cited source windows that do not contain their own sources =='

WITH windowed AS MATERIALIZED (
    SELECT a.id,
           (a.attrs#>>'{source_window,from}')::timestamptz AS window_from,
           (a.attrs#>>'{source_window,to}')::timestamptz   AS window_to
    FROM assertions a
    WHERE a.superseded_at IS NULL
      AND a.attrs#>>'{source_window,from}' ~ '^\d{4}-\d{2}-\d{2}'
      AND a.attrs#>>'{source_window,to}'   ~ '^\d{4}-\d{2}-\d{2}'
),
source_time AS (
    SELECT ae.assertion_id AS id, 'event' AS source_kind,
           ev.id AS source_id, ev.occurred_at AS source_at
    FROM assertion_evidence ae
    JOIN events ev ON ev.id = ae.event_id
    WHERE ae.kind IN ('source', 'corroboration')
      AND coalesce(ae.attrs->>'role', '') <> 'distillation_record'
    UNION ALL
    SELECT ae.assertion_id, 'assertion',
           s.id, coalesce(s.effective_at, s.asserted_at)
    FROM assertion_evidence ae
    JOIN assertions s ON s.id = ae.source_assertion_id
    WHERE ae.kind = 'derivation'
)
SELECT w.id AS assertion_id,
       st.source_kind,
       st.source_id,
       st.source_at,
       w.window_from,
       w.window_to
FROM windowed w
JOIN source_time st ON st.id = w.id
WHERE st.source_at < w.window_from
   OR st.source_at > w.window_to
ORDER BY w.id, st.source_at;
