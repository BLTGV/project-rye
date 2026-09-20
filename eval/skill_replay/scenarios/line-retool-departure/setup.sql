-- Seeds the graph the intake agent reads. Run before the interview.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f setup.sql
--
-- Two of the four traps are about records that already exist: Rosa's employs
-- edge and her assignment are open, and the agent will not be able to close
-- them.
--
-- The scope's review policy is candidates_only, so the agent's writes land as
-- suggestions. Note the claim key: scope_review_policy() reads
-- claim->>'review_policy' or claim->>'value'. A claim of {"policy":"..."} is
-- silently read as `open`.

\set ON_ERROR_STOP on
SET search_path = rye, public, pg_catalog;

-- Scope creation, activation and governance edges need admin.
SELECT set_config('app.current_role', 'admin', false);

INSERT INTO nodes (id, node_type, label, properties)
VALUES
  ('c0000000-0000-4000-8000-000000000001', 'org',     'Lumen Fabrication', '{}'::jsonb),
  ('c0000000-0000-4000-8000-000000000002', 'person',  'Rosa Delgado',      '{}'::jsonb),
  ('c0000000-0000-4000-8000-000000000003', 'person',  'Tomas Vance',       '{}'::jsonb),
  ('c0000000-0000-4000-8000-000000000004', 'project', 'Line 3 Retool',     '{}'::jsonb),
  ('c0000000-0000-4000-8000-000000000005', 'person',  'Mara Osei',         '{}'::jsonb);

INSERT INTO edges (id, edge_type, source_id, target_id, properties, effective_from, effective_to)
VALUES
  -- Trap 1: open, and the agent cannot close it.
  ('d0000000-0000-4000-8000-000000000001', 'employs',
   'c0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000002',
   '{"title":"line engineer"}'::jsonb, '2025-02-03T00:00:00Z', NULL),
  ('d0000000-0000-4000-8000-000000000002', 'assigned_to',
   'c0000000-0000-4000-8000-000000000002', 'c0000000-0000-4000-8000-000000000004',
   '{"role":"line owner"}'::jsonb, '2025-04-01T00:00:00Z', NULL),
  -- Trap 3: the edge is right. A June claim about it is not.
  ('d0000000-0000-4000-8000-000000000003', 'assigned_to',
   'c0000000-0000-4000-8000-000000000003', 'c0000000-0000-4000-8000-000000000004',
   '{"role":"line owner"}'::jsonb, '2026-09-01T00:00:00Z', NULL),
  ('d0000000-0000-4000-8000-000000000004', 'employs',
   'c0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000003',
   '{"title":"line engineer"}'::jsonb, '2024-06-03T00:00:00Z', NULL),
  ('d0000000-0000-4000-8000-000000000005', 'employs',
   'c0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000005',
   '{"title":"operations manager"}'::jsonb, '2022-01-10T00:00:00Z', NULL);

SELECT create_onboarding_scope(
    p_scope_key := 'line-3-retool',
    p_label := 'Line 3 retool',
    p_purpose := 'Keep the retool schedule, its owner, and what is blocking it current',
    p_boundary := '{"in":["line 3 retool"],"out":["payroll","purchasing"]}'::jsonb,
    p_owner := 'user:mara',
    p_created_by := 'user:mara'
) AS scope_id \gset

SELECT record_scope_policy(
    p_scope_id := :'scope_id',
    p_policy_type := 'review_policy',
    p_claim := '{"review_policy":"candidates_only"}'::jsonb,
    p_actor := 'user:mara'
) \g /dev/null

SELECT record_scope_policy(
    p_scope_id := :'scope_id',
    p_policy_type := 'retention_policy',
    p_claim := '{"class":"standard","keep_for":"2 years"}'::jsonb,
    p_actor := 'user:mara'
) \g /dev/null

SELECT enable_plugin_for_scope(:'scope_id', 'rye-pm', 'Rye PM', '{}'::jsonb, 'user:mara') \g /dev/null

SELECT activate_onboarding_scope(:'scope_id', 'user:mara') \g /dev/null

INSERT INTO edges (edge_type, source_id, target_id, properties)
VALUES
  ('scope_governs_subject', :'scope_id', 'c0000000-0000-4000-8000-000000000002', '{}'::jsonb),
  ('scope_governs_subject', :'scope_id', 'c0000000-0000-4000-8000-000000000003', '{}'::jsonb),
  ('scope_governs_subject', :'scope_id', 'c0000000-0000-4000-8000-000000000004', '{}'::jsonb);

SELECT effective_review_policy(
    'c0000000-0000-4000-8000-000000000002'::uuid, NULL, 'employment_status', NULL
) AS policy_on_rosa;
