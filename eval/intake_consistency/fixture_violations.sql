-- Intake consistency fixture: one violation of each of the four intake rules.
--
-- Invented business. Lumen Fabrication retools a production line; Rosa Delgado
-- leaves and Tomas Vance picks the line up. Every name here is made up.
--
-- Run as a non-superuser database role. The session role changes per block,
-- because the graph shape is a person's write and the claims are an agent's.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f eval/intake_consistency/fixture_violations.sql
--
-- Then run eval/intake_consistency/checks.sql. Each of the four checks returns
-- exactly one finding. fixture_fixed.sql repairs all four.

\set ON_ERROR_STOP on
SET search_path = rye, public, pg_catalog;

-- A non-superuser role, so RLS applies. scripts/conformance.sh creates
-- rye_conformance and grants it; this fixture assumes the same role exists.
SET ROLE rye_conformance;

-- ---------------------------------------------------------------------------
-- Graph shape. A person writes nodes and edges; there is no helper for either,
-- and an agent may not close an edge at all.
-- ---------------------------------------------------------------------------
SELECT set_config('app.current_role', 'team_member', false);

INSERT INTO nodes (id, node_type, label, properties)
VALUES
  ('a0000000-0000-4000-8000-000000000001', 'org',     'Lumen Fabrication', '{}'::jsonb),
  ('a0000000-0000-4000-8000-000000000002', 'person',  'Rosa Delgado',      '{}'::jsonb),
  ('a0000000-0000-4000-8000-000000000003', 'person',  'Tomas Vance',       '{}'::jsonb),
  ('a0000000-0000-4000-8000-000000000004', 'project', 'Line 3 Retool',     '{}'::jsonb);

INSERT INTO edges (id, edge_type, source_id, target_id, properties, effective_from, effective_to)
VALUES
  -- Rule 1 violation: still open after the departure below.
  ('b0000000-0000-4000-8000-000000000001', 'employs',
   'a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000002',
   '{"title":"line engineer"}'::jsonb, '2025-02-03T00:00:00Z', NULL),
  -- Rule 1 violation: the role edge is open too.
  ('b0000000-0000-4000-8000-000000000002', 'assigned_to',
   'a0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000004',
   '{"role":"line owner"}'::jsonb, '2025-04-01T00:00:00Z', NULL),
  -- Tomas takes the line on September 1.
  ('b0000000-0000-4000-8000-000000000003', 'assigned_to',
   'a0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000004',
   '{"role":"line owner"}'::jsonb, '2026-09-01T00:00:00Z', NULL);

-- ---------------------------------------------------------------------------
-- Source material. Events are the evidence the claims below rest on.
-- ---------------------------------------------------------------------------
SELECT set_config('app.current_role', 'agent:intake-fixture', false);

SELECT record_event(
    p_event_type := 'note',
    p_summary := 'Staffing channel: Rosa Delgado''s last day is August 31',
    p_properties := '{"container":"#staffing"}'::jsonb,
    p_participant_ids := ARRAY['a0000000-0000-4000-8000-000000000002']::uuid[],
    p_participant_roles := ARRAY['subject'],
    p_actor := 'agent:intake-fixture',
    p_occurred_at := '2026-08-28T15:10:00Z'
) AS ev_departure \gset

SELECT record_event(
    p_event_type := 'note',
    p_summary := 'Line 3 standup: gearbox delivery slipped, line is blocked',
    p_properties := '{"container":"#line-3"}'::jsonb,
    p_participant_ids := ARRAY['a0000000-0000-4000-8000-000000000004']::uuid[],
    p_participant_roles := ARRAY['subject'],
    p_actor := 'agent:intake-fixture',
    p_occurred_at := '2026-09-05T10:00:00Z'
) AS ev_blocked \gset

SELECT record_event(
    p_event_type := 'note',
    p_summary := 'Line 3 channel export for the first week of September',
    p_properties := '{"container":"#line-3"}'::jsonb,
    p_participant_ids := ARRAY['a0000000-0000-4000-8000-000000000004']::uuid[],
    p_participant_roles := ARRAY['subject'],
    p_actor := 'agent:intake-fixture',
    p_occurred_at := '2026-09-08T10:00:00Z'
) AS ev_volume \gset

-- ---------------------------------------------------------------------------
-- Rule 1 violation: the departure is recorded, the two edges stay open.
-- ---------------------------------------------------------------------------
SELECT record_assertion(
    p_assertion_type := 'employment_status',
    p_claim := '{"status":"departed"}'::jsonb,
    p_subject_node_id := 'a0000000-0000-4000-8000-000000000002',
    p_assertion_key := 'default',
    p_effective_at := '2026-08-31T00:00:00Z',
    p_status := 'accepted',
    p_basis := 'reported',
    p_evidence := ARRAY[jsonb_build_object('kind', 'source', 'event_id', :'ev_departure')]
) AS a_departed \gset

-- ---------------------------------------------------------------------------
-- Rule 3 violation: the claim about the handoff edge is effective June 15;
-- the edge opens September 1. Two stories about one handoff.
-- ---------------------------------------------------------------------------
SELECT record_assertion(
    p_assertion_type := 'assignment_status',
    p_claim := '{"status":"owner"}'::jsonb,
    p_subject_edge_id := 'b0000000-0000-4000-8000-000000000003',
    p_assertion_key := 'default',
    p_effective_at := '2026-06-15T00:00:00Z',
    p_status := 'accepted',
    p_basis := 'reported',
    p_evidence := ARRAY[jsonb_build_object('kind', 'source', 'event_id', :'ev_departure')]
) AS a_handoff \gset

-- Source claims the digest is allowed to rest on.
SELECT record_assertion(
    p_assertion_type := 'task_status',
    p_claim := '{"status":"blocked","blocked_on":"gearbox"}'::jsonb,
    p_subject_node_id := 'a0000000-0000-4000-8000-000000000004',
    p_assertion_key := 'default',
    p_effective_at := '2026-09-05T00:00:00Z',
    p_status := 'accepted',
    p_basis := 'reported',
    p_evidence := ARRAY[jsonb_build_object('kind', 'source', 'event_id', :'ev_blocked')]
) AS a_status \gset

SELECT record_assertion(
    p_assertion_type := 'message_volume',
    p_claim := '{"message_count":214,"peak_hour_utc":10}'::jsonb,
    p_subject_node_id := 'a0000000-0000-4000-8000-000000000004',
    p_assertion_key := 'default',
    p_effective_at := '2026-09-08T00:00:00Z',
    p_status := 'accepted',
    p_basis := 'observed',
    p_evidence := ARRAY[jsonb_build_object('kind', 'source', 'event_id', :'ev_volume')]
) AS a_volume \gset

-- ---------------------------------------------------------------------------
-- Rule 2 violation: the digest rests on the task status alone, and claims a
-- clearance height and a peak hour no source establishes. It also carries no
-- source window, which is the rule 4 violation.
-- ---------------------------------------------------------------------------
SELECT record_distillation(
    p_subject_node_id := 'a0000000-0000-4000-8000-000000000004',
    p_subject_edge_id := NULL,
    p_assertion_key := 'status',
    p_claim := '{"status":"blocked","blocked_on":"gearbox","clearance_height_ft":18,"peak_hour_utc":9}'::jsonb,
    p_source_assertion_ids := ARRAY[:'a_status']::uuid[],
    p_source_event_ids := ARRAY[:'ev_blocked']::uuid[],
    p_status := 'accepted',
    p_agent := 'agent:intake-fixture'
) AS d_status \gset

-- ---------------------------------------------------------------------------
-- Rule 4 violation, second shape: the window is cited but does not contain the
-- source it was computed from.
-- ---------------------------------------------------------------------------
SELECT record_assertion(
    p_assertion_type := 'throughput_estimate',
    p_claim := '{"units_per_shift":42}'::jsonb,
    p_subject_node_id := 'a0000000-0000-4000-8000-000000000004',
    p_assertion_key := 'default',
    p_effective_at := '2026-09-09T00:00:00Z',
    p_status := 'accepted',
    p_basis := 'inferred',
    p_evidence := ARRAY[jsonb_build_object('kind', 'derivation', 'source_assertion_id', :'a_status')],
    p_attrs := '{"source_window":{"from":"2026-09-01T00:00:00Z","to":"2026-09-02T00:00:00Z"}}'::jsonb
) AS a_throughput \gset

SELECT 'fixture loaded' AS status;
