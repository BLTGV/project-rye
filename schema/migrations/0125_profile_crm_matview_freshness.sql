-- A matview says when it was taken.
--
-- Work item: work/016-admin-view-layer.md. Closes the fifth gap in issue 12.
-- Contract:  contracts/sql-surface.md, "Review surfaces".
-- Decision:  docs/decisions/0012-review-surfaces-carry-what-the-screen-needs.md,
--            section E.
-- Tests:     tests/conformance/41_review_surfaces.sql, obligations 41.11-41.12.
--
-- opportunities_active can serve contact and stage data from an hour ago with
-- nothing on the row saying so. Three ways to stop that were weighed in the
-- decision; the cheap one that cannot lie is chosen: a snapshot_at column in
-- the matview's own select list, so every row carries the instant the snapshot
-- was computed, stamped by whatever refreshed it -- refresh_materialized_views(),
-- a raw REFRESH MATERIALIZED VIEW, or this migration's own CREATE.
--
-- THE COST, STATED. REFRESH ... CONCURRENTLY diffs whole rows, and snapshot_at
-- changes on every row at every refresh, so the concurrent refresh now
-- rewrites every row instead of only the changed ones. opportunities_active
-- holds open opportunities -- a set bounded by a team's pipeline, not by
-- instance size -- so this is milliseconds and bloat autovacuum already
-- handles. It also costs a DROP and CREATE on upgrade, under an exclusive
-- lock: the same operation 0120 already performed.
--
-- WHY A PROFILE FILE. install.sh --profiles may omit crm entirely, and every
-- 01xx file applies after every 00xx one, so a core migration may not mention
-- opportunities_active and a fix placed in one would be overwritten by 0120 on
-- a fresh install. The definition below is 0120's, unchanged except for the
-- appended snapshot_at.
--
-- IT IS AN AGE MARKER, NOT CHANGE DETECTION. opportunities_active_freshness
-- answers "how old is this snapshot", not "is anything newer". Answering the
-- second costs a scan of nodes, edges, and assertions on every read, and the
-- index that would make the node half cheap does not exist. A false "stale" is
-- the safe direction, and the screen says "as of 14:05" either way.

SET search_path = rye, pg_catalog, public;

DROP MATERIALIZED VIEW IF EXISTS opportunities_active;

CREATE MATERIALIZED VIEW opportunities_active AS
SELECT
    n.id AS node_id,
    n.label,
    n.properties->>'code' AS code,
    n.properties->>'name' AS name,
    n.properties->>'estimated_value' AS estimated_value,
    n.attrs->'teams' AS teams,
    stg.claim->>'stage' AS stage,
    stg.claim->>'pipeline' AS pipeline,
    stg.asserted_at AS stage_since,
    val.claim->>'amount' AS current_value,
    wp.claim->>'probability' AS win_probability,
    pc.label AS primary_contact_name,
    pc.id AS primary_contact_id,
    owner.label AS assigned_to_name,
    owner.id AS assigned_to_id,
    n.created_at,
    -- now() is the refreshing transaction's start, so every row of one
    -- snapshot carries one instant and a later refresh carries a later one.
    now() AS snapshot_at
FROM nodes n
LEFT JOIN current_valid_assertions stg
    ON stg.subject_node_id = n.id
   AND stg.assertion_type = 'deal_stage'
   AND stg.assertion_key = 'default'
LEFT JOIN current_valid_assertions val
    ON val.subject_node_id = n.id
   AND val.assertion_type = 'deal_value'
LEFT JOIN current_valid_assertions wp
    ON wp.subject_node_id = n.id
   AND wp.assertion_type = 'win_probability'
LEFT JOIN LATERAL (
    SELECT pc_n.id, pc_n.label
    FROM edges pc_e
    JOIN nodes pc_n ON pc_n.id = pc_e.target_id
    WHERE pc_e.source_id = n.id
      AND pc_e.edge_type = 'primary_contact'
      AND pc_e.archived_at IS NULL
    ORDER BY pc_e.created_at
    LIMIT 1
) pc ON true
LEFT JOIN LATERAL (
    SELECT own_n.id, own_n.label
    FROM edges own_e
    JOIN nodes own_n ON own_n.id = own_e.target_id
    WHERE own_e.source_id = n.id
      AND own_e.edge_type = 'assigned_to'
      AND own_e.properties->>'role' = 'owner'
      AND own_e.archived_at IS NULL
      AND (own_e.effective_from IS NULL OR own_e.effective_from <= now())
      AND (own_e.effective_to IS NULL OR own_e.effective_to > now())
    ORDER BY own_e.effective_from DESC NULLS LAST
    LIMIT 1
) owner ON true
WHERE n.node_type = 'opportunity'
  AND n.archived_at IS NULL
  AND (
      stg.claim->>'stage' IS NULL
      OR stg.claim->>'stage' NOT IN ('closed_won', 'closed_lost', 'dead')
  );

CREATE UNIQUE INDEX IF NOT EXISTS idx_oa_node  ON opportunities_active (node_id);
CREATE INDEX IF NOT EXISTS idx_oa_code         ON opportunities_active (code);
CREATE INDEX IF NOT EXISTS idx_oa_stage        ON opportunities_active (stage);
CREATE INDEX IF NOT EXISTS idx_oa_owner        ON opportunities_active (assigned_to_id);

COMMENT ON MATERIALIZED VIEW opportunities_active IS
    'Open opportunities with stage, value, win probability, primary contact, and owner, as of snapshot_at -- the instant the snapshot was computed, by whatever refreshed it. Read opportunities_active_freshness before trusting it.';

-- stale_after is data, not a constant: an instance retunes it with one
-- registry assertion and no migration.
CREATE OR REPLACE VIEW opportunities_active_freshness
WITH (security_invoker = true) AS
SELECT
    s.snapshot_at,
    now() - s.snapshot_at AS age,
    s.stale_after,
    (s.snapshot_at IS NULL OR now() - s.snapshot_at > s.stale_after) AS stale,
    s.row_count
FROM (
    SELECT
        max(oa.snapshot_at) AS snapshot_at,
        count(*) AS row_count,
        coalesce(
            (registry_value('matview_stale_after:opportunities_active', NULL) #>> '{}')::interval,
            interval '15 minutes'
        ) AS stale_after
    FROM opportunities_active oa
) s;

COMMENT ON VIEW opportunities_active_freshness IS
    'How old the opportunities_active snapshot is: snapshot_at, age, stale_after (registry key matview_stale_after:opportunities_active, default 15 minutes), stale, and row_count. An age marker, not change detection: stale false does not promise the sources are unchanged.';
