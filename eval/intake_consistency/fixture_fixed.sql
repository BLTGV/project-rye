-- Repairs every violation fixture_violations.sql loaded. After this file runs,
-- all four checks in eval/intake_consistency/checks.sql return no rows.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f eval/intake_consistency/fixture_fixed.sql
--
-- These four blocks are the four examples in the "Intake consistency" section
-- of docs/agent-ops-guide.md, in order and verbatim apart from the session
-- setup below. Edit both or they drift.
--
-- Nothing is edited in place except the two edge windows. An edge ends with
-- effective_to; a claim is replaced by superseding it.

\set ON_ERROR_STOP on
SET search_path = rye, public, pg_catalog;
SET ROLE rye_conformance;

-- ---------------------------------------------------------------------------
-- Rule 1. As team_member. Ends every open employs or role edge on the date the
-- current accepted departure gives. An agent-shaped session reports UPDATE 0
-- here and changes nothing.
-- ---------------------------------------------------------------------------
SELECT set_config('app.current_role', 'team_member', false);

UPDATE edges e
SET effective_to = d.departed_at
FROM (
    SELECT a.subject_node_id AS person_id,
           a.effective_at    AS departed_at
    FROM current_valid_assertions a
    WHERE a.assertion_type = 'employment_status'
      AND a.claim->>'status' = 'departed'
      AND a.effective_at IS NOT NULL
) d
WHERE (e.source_id = d.person_id OR e.target_id = d.person_id)
  AND e.edge_type IN ('employs', 'affiliated_with', 'reports_to', 'member_of',
                      'assigned_to', 'project_member', 'sprint_member',
                      'pipeline_member', 'territory_member',
                      'primary_contact', 'secondary_contact')
  AND e.archived_at IS NULL
  AND e.effective_to IS NULL;

-- ---------------------------------------------------------------------------
-- Rule 1, handoff disposition. `owns` and `responsible_for` are not on the
-- list above. Closing one leaves the thing unowned, which is a worse record
-- than a stale one. A person names the successor; then the old edge ends on
-- the same date the new one opens.
-- ---------------------------------------------------------------------------
INSERT INTO edges (edge_type, source_id, target_id, properties, effective_from)
SELECT e.edge_type, 'a0000000-0000-4000-8000-000000000003', e.target_id,
       e.properties, '2026-08-31T00:00:00Z'
FROM edges e
WHERE e.id = 'b0000000-0000-4000-8000-000000000005'
  AND e.effective_to IS NULL;

UPDATE edges
SET effective_to = '2026-08-31T00:00:00Z'
WHERE id = 'b0000000-0000-4000-8000-000000000005'
  AND effective_to IS NULL;

-- ---------------------------------------------------------------------------
-- Rule 2 and rule 4. As an agent. Every claim key is established by one of the
-- two sources, and the window the numbers came from is cited.
-- ---------------------------------------------------------------------------
SELECT set_config('app.current_role', 'agent:intake-fixture', false);

SELECT record_distillation(
    p_subject_node_id := (SELECT id FROM nodes WHERE label = 'Line 3 Retool'),
    p_subject_edge_id := NULL,
    p_assertion_key := 'status',
    p_claim := '{"status":"blocked","blocked_on":"gearbox",
                 "message_count":214,"peak_hour_utc":10}'::jsonb,
    p_source_assertion_ids := ARRAY(
        SELECT a.id FROM current_valid_assertions a
        WHERE a.subject_node_id = (SELECT id FROM nodes WHERE label = 'Line 3 Retool')
          AND a.assertion_type IN ('task_status', 'message_volume')
    ),
    p_source_event_ids := '{}'::uuid[],
    p_status := 'accepted',
    p_agent := 'agent:intake-fixture',
    p_attrs := '{"source_window":{"from":"2026-09-01T00:00:00Z",
                                  "to":"2026-09-30T00:00:00Z"}}'::jsonb
);

-- ---------------------------------------------------------------------------
-- Rule 3. As an agent. Replaces the misdated claim with one dated off the
-- edge. record_assertion() cannot do this: when the claim, basis and
-- confidence match the incumbent it returns the incumbent's id and writes
-- nothing, whatever effective_at is passed.
-- ---------------------------------------------------------------------------
SELECT supersede_assertion(
    p_old_assertion_id := a.id,
    p_new_assertion_type := a.assertion_type,
    p_new_subject_node_id := NULL,
    p_new_subject_edge_id := e.id,
    p_new_claim := a.claim,
    p_new_assertion_key := a.assertion_key,
    p_new_effective_at := e.effective_from,
    p_new_basis := a.basis,
    p_new_evidence := ARRAY[jsonb_build_object(
        'kind', 'source',
        'event_id', (SELECT id FROM events
                     WHERE summary LIKE 'Staffing channel:%' LIMIT 1)
    )]
)
FROM assertions a
JOIN edges e ON e.id = a.subject_edge_id
WHERE a.assertion_type = 'assignment_status'
  AND a.superseded_at IS NULL
  AND a.effective_at < e.effective_from;

-- ---------------------------------------------------------------------------
-- Rule 4. As an agent. The replacement cites the window containing its source.
-- supersede_assertion() again: record_assertion() ignores p_attrs when the
-- claim matches.
-- ---------------------------------------------------------------------------
SELECT supersede_assertion(
    p_old_assertion_id := a.id,
    p_new_assertion_type := a.assertion_type,
    p_new_subject_node_id := a.subject_node_id,
    p_new_subject_edge_id := NULL,
    p_new_claim := a.claim,
    p_new_assertion_key := a.assertion_key,
    p_new_effective_at := a.effective_at,
    p_new_basis := a.basis,
    p_new_evidence := ARRAY[jsonb_build_object(
        'kind', 'derivation',
        'source_assertion_id', (SELECT s.id FROM current_valid_assertions s
                                WHERE s.assertion_type = 'task_status'
                                LIMIT 1)
    )],
    p_new_attrs := '{"source_window":{"from":"2026-09-01T00:00:00Z",
                                      "to":"2026-09-30T00:00:00Z"}}'::jsonb
)
FROM assertions a
WHERE a.assertion_type = 'throughput_estimate'
  AND a.superseded_at IS NULL;

-- ---------------------------------------------------------------------------
-- Rule 4, the observed count. A number read off a week's export still needs
-- the week. The window ends the 9th, not the 8th, because it has to contain
-- the export event at 2026-09-08T10:00Z that the claim cites.
-- ---------------------------------------------------------------------------
SELECT supersede_assertion(
    p_old_assertion_id := a.id,
    p_new_assertion_type := a.assertion_type,
    p_new_subject_node_id := a.subject_node_id,
    p_new_subject_edge_id := NULL,
    p_new_claim := a.claim,
    p_new_assertion_key := a.assertion_key,
    p_new_effective_at := a.effective_at,
    p_new_basis := a.basis,
    p_new_evidence := ARRAY[jsonb_build_object(
        'kind', 'source',
        'event_id', (SELECT id FROM events
                     WHERE summary LIKE 'Line 3 channel export%' LIMIT 1)
    )],
    p_new_attrs := '{"source_window":{"from":"2026-09-01T00:00:00Z",
                                      "to":"2026-09-09T00:00:00Z"}}'::jsonb
)
FROM assertions a
WHERE a.assertion_type = 'message_volume'
  AND a.superseded_at IS NULL;

SELECT 'fixture repaired' AS status;
