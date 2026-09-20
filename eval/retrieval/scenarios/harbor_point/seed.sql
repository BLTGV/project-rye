-- Retrieval eval fixture: Harbor Point Fabrication (fictional).
--
-- Purpose-built to discriminate between retrieval failure classes rather than
-- to be realistic in aggregate. Every element below exists to make one
-- measurement possible:
--
--   near-duplicate labels    entry-point precision under confusable names
--   abbreviation-only label  an entry miss trigram cannot fix by loosening
--   paraphrase-only target   an entry miss only reformulation can fix
--   3-hop causal chain       multi-hop traversal with a real answer
--   associative shortcut     a 1-hop decoy that appears iff semantics
--                            filtering is broken
--   repeated root cause      a cross-subject question with no surface today
--   unsupported question     a refusal target
--
-- Idempotent. Fixed UUIDs under the fa000001 prefix so ground truth in
-- questions.json stays stable across reloads.
--
-- ROLE. The write gate (migration 0026) refuses a viewer and a role-less
-- session, so this file sets `admin` itself rather than inheriting whatever
-- the psql session had. `admin` and not `team_member`, because the last block
-- reads current_valid_assertions to check its own outcome. The database role
-- running psql needs INSERT on the rye tables; scripts/conformance.sh grants
-- exactly that to rye_conformance.

SET search_path = rye, public, pg_catalog;

SELECT set_config('app.current_user_id', 'eval:retrieval-seed', false);
SELECT set_config('app.current_teams', '', false);
SELECT set_config('app.current_role', 'admin', false);

-- --------------------------------------------------------------------------
-- Nodes
-- --------------------------------------------------------------------------

INSERT INTO nodes (id, node_type, label, external_id, external_source, properties, attrs) VALUES
    -- Operating company and its people
    ('fa000001-0001-0001-0001-000000000001', 'org', 'Harbor Point Fabrication', NULL, NULL,
     '{"role":"operator"}', '{"classification":"public"}'),
    ('fa000001-0002-0001-0001-000000000001', 'person', 'Dana Whitfield', NULL, NULL,
     '{"title":"Operations Lead"}', '{"classification":"public"}'),
    ('fa000001-0002-0001-0001-000000000002', 'person', 'Ravi Sundaram', NULL, NULL,
     '{"title":"Project Manager"}', '{"classification":"public"}'),

    -- Paraphrase target plus a near-duplicate distractor. "the fence company"
    -- reaches neither by trigram; only reformulation does.
    ('fa000001-0001-0001-0001-000000000002', 'org', 'Meridian Fence & Gate', NULL, NULL,
     '{"category":"subcontractor"}', '{"classification":"public"}'),
    ('fa000001-0001-0001-0001-000000000003', 'org', 'Meridian Fencing Supply', NULL, NULL,
     '{"category":"supplier"}', '{"classification":"public"}'),

    -- Abbreviation-only label. `HPF` expands to the operating company's name
    -- and nothing else in the label survives the expansion, so the natural
    -- phrasing scores 0.2500 against it -- under the 0.35 floor in
    -- find_nodes(). Measured on PG15 with pg_trgm:
    --   similarity('HPF Drydock', 'Harbor Point Fabrication Drydock') = 0.2500
    -- The parent org scores 0.7576 on the same query, so the miss shows up as
    -- "returned the parent company instead", which is what a real one looks
    -- like. A label sharing a word with the expansion is not this test: the
    -- earlier 'HPF Marine Services' scored 0.5313 against 'Harbor Point
    -- Marine Services' and was found on the first call.
    ('fa000001-0001-0001-0001-000000000004', 'org', 'HPF Drydock', NULL, NULL,
     '{"category":"affiliate"}', '{"classification":"public"}'),

    -- External identity target
    ('fa000001-0001-0001-0001-000000000005', 'org', 'Northwind Trading Co', 'NW-4471', 'eval_erp',
     '{"category":"customer"}', '{"classification":"public"}'),

    -- Root cause shared by two projects
    ('fa000001-0001-0001-0001-000000000006', 'org', 'Coastal Steel Supply', NULL, NULL,
     '{"category":"supplier"}', '{"classification":"public"}'),

    -- Projects
    ('fa000001-0003-0001-0001-000000000001', 'project', 'Pier 9 Rebuild', NULL, NULL,
     '{}', '{"classification":"public"}'),
    ('fa000001-0003-0001-0001-000000000002', 'project', 'Dock 4 Refit', NULL, NULL,
     '{}', '{"classification":"public"}'),
    ('fa000001-0003-0001-0001-000000000003', 'project', 'Slipway Extension', NULL, NULL,
     '{}', '{"classification":"public"}'),

    -- Issues
    ('fa000001-0004-0001-0001-000000000001', 'issue', 'Rebar Shortage', NULL, NULL,
     '{}', '{"classification":"public"}'),
    ('fa000001-0004-0001-0001-000000000002', 'issue', 'Late Delivery Penalty', NULL, NULL,
     '{}', '{"classification":"public"}'),
    ('fa000001-0004-0001-0001-000000000003', 'issue', 'Plate Steel Backorder', NULL, NULL,
     '{}', '{"classification":"public"}'),
    ('fa000001-0004-0001-0001-000000000004', 'issue', 'Permit Backlog', NULL, NULL,
     '{}', '{"classification":"public"}')
ON CONFLICT (id) DO NOTHING;

-- --------------------------------------------------------------------------
-- Edges
-- --------------------------------------------------------------------------
-- Causal convention here is cause -affects-> effect, matching the core
-- edge_semantics registry seeded by migration 0032: `affects` is causal,
-- `regarding` is associative, `employs` and `assigned_to` are structural.

INSERT INTO edges (id, edge_type, source_id, target_id, properties) VALUES
    -- Structural
    ('fa000002-0001-0001-0001-000000000001', 'employs',
     'fa000001-0001-0001-0001-000000000001', 'fa000001-0002-0001-0001-000000000001', '{}'),
    ('fa000002-0001-0001-0001-000000000002', 'employs',
     'fa000001-0001-0001-0001-000000000001', 'fa000001-0002-0001-0001-000000000002', '{}'),
    ('fa000002-0001-0001-0001-000000000003', 'assigned_to',
     'fa000001-0003-0001-0001-000000000001', 'fa000001-0002-0001-0001-000000000002', '{}'),

    -- Causal chain: supplier -> shortage -> project -> penalty
    ('fa000002-0002-0001-0001-000000000001', 'affects',
     'fa000001-0001-0001-0001-000000000006', 'fa000001-0004-0001-0001-000000000001', '{}'),
    ('fa000002-0002-0001-0001-000000000002', 'affects',
     'fa000001-0004-0001-0001-000000000001', 'fa000001-0003-0001-0001-000000000001', '{}'),
    ('fa000002-0002-0001-0001-000000000003', 'affects',
     'fa000001-0003-0001-0001-000000000001', 'fa000001-0004-0001-0001-000000000002', '{}'),

    -- Second chain from the same root, so the root cause recurs across
    -- subjects. Answering "what recurs" needs aggregation, not traversal.
    ('fa000002-0002-0001-0001-000000000004', 'affects',
     'fa000001-0001-0001-0001-000000000006', 'fa000001-0004-0001-0001-000000000003', '{}'),
    ('fa000002-0002-0001-0001-000000000005', 'affects',
     'fa000001-0004-0001-0001-000000000003', 'fa000001-0003-0001-0001-000000000002', '{}'),

    -- Unrelated third cause, so the recurring answer is 2 of 3 rather than
    -- trivially universal.
    ('fa000002-0002-0001-0001-000000000006', 'affects',
     'fa000001-0004-0001-0001-000000000004', 'fa000001-0003-0001-0001-000000000003', '{}'),

    -- Associative decoy. A causal query must NOT use this edge: it makes the
    -- supplier look one hop from the penalty. Its presence is what proves the
    -- semantics filter is doing work rather than being untested.
    ('fa000002-0003-0001-0001-000000000001', 'regarding',
     'fa000001-0001-0001-0001-000000000006', 'fa000001-0004-0001-0001-000000000002', '{}'),
    ('fa000002-0003-0001-0001-000000000002', 'regarding',
     'fa000001-0001-0001-0001-000000000002', 'fa000001-0003-0001-0001-000000000001', '{}')
ON CONFLICT (id) DO NOTHING;

-- --------------------------------------------------------------------------
-- Events and assertions
-- --------------------------------------------------------------------------
-- Assertions carry source evidence so provenance correctness is checkable:
-- a cited assertion must exist, be current, and trace to a real event.

DO $$
DECLARE
    v_delivery_event uuid;
    v_status_event uuid;
    v_backorder_event uuid;
BEGIN
    IF EXISTS (
        SELECT 1 FROM assertions
        WHERE subject_node_id = 'fa000001-0003-0001-0001-000000000001'
          AND assertion_type = 'project_status'
    ) THEN
        RETURN;  -- already seeded
    END IF;

    v_delivery_event := record_event(
        p_event_type := 'supplier_delivery_missed',
        p_summary := 'Coastal Steel Supply missed two scheduled rebar deliveries',
        p_properties := '{"missed_deliveries": 2}',
        p_participant_ids := ARRAY['fa000001-0001-0001-0001-000000000006'::uuid,
                                   'fa000001-0004-0001-0001-000000000001'::uuid],
        p_participant_roles := ARRAY['supplier', 'issue']
    );

    v_status_event := record_event(
        p_event_type := 'schedule_review',
        p_summary := 'Pier 9 Rebuild schedule review moved the milestone out four weeks',
        p_properties := '{"slip_weeks": 4}',
        p_participant_ids := ARRAY['fa000001-0003-0001-0001-000000000001'::uuid,
                                   'fa000001-0002-0001-0001-000000000002'::uuid],
        p_participant_roles := ARRAY['project', 'reporter']
    );

    v_backorder_event := record_event(
        p_event_type := 'supplier_delivery_missed',
        p_summary := 'Coastal Steel Supply placed plate steel on backorder',
        p_properties := '{}',
        p_participant_ids := ARRAY['fa000001-0001-0001-0001-000000000006'::uuid,
                                   'fa000001-0004-0001-0001-000000000003'::uuid],
        p_participant_roles := ARRAY['supplier', 'issue']
    );

    PERFORM record_assertion(
        p_assertion_type := 'project_status',
        p_claim := '{"status":"delayed","slip_weeks":4}',
        p_subject_node_id := 'fa000001-0003-0001-0001-000000000001',
        p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object(
            'kind', 'source', 'event_id', v_status_event,
            'witness_node_id', 'fa000001-0002-0001-0001-000000000002')]
    );

    PERFORM record_assertion(
        p_assertion_type := 'issue_cause',
        p_claim := '{"cause":"Coastal Steel Supply missed two rebar deliveries"}',
        p_subject_node_id := 'fa000001-0004-0001-0001-000000000001',
        p_basis := 'observed',
        p_evidence := ARRAY[jsonb_build_object(
            'kind', 'source', 'event_id', v_delivery_event,
            'witness_node_id', 'fa000001-0002-0001-0001-000000000001')]
    );

    PERFORM record_assertion(
        p_assertion_type := 'issue_cause',
        p_claim := '{"cause":"Coastal Steel Supply placed plate steel on backorder"}',
        p_subject_node_id := 'fa000001-0004-0001-0001-000000000003',
        p_basis := 'observed',
        p_evidence := ARRAY[jsonb_build_object(
            'kind', 'source', 'event_id', v_backorder_event,
            'witness_node_id', 'fa000001-0002-0001-0001-000000000001')]
    );

    PERFORM record_assertion(
        p_assertion_type := 'subcontractor_role',
        p_claim := '{"role":"perimeter fencing and gate installation"}',
        p_subject_node_id := 'fa000001-0001-0001-0001-000000000002',
        p_basis := 'reported',
        p_evidence := ARRAY[jsonb_build_object('kind', 'source', 'event_id', v_status_event)]
    );

    -- Deliberately absent: any payment_terms assertion. That gap is the
    -- refusal target, and an agent that answers it is confabulating.
END;
$$;

-- --------------------------------------------------------------------------
-- Check the fixture's own outcome
-- --------------------------------------------------------------------------
-- record_assertion() does not always accept. Under a scope whose review
-- policy is `strict`, or `candidates_only` with a basis other than observed,
-- the write lands as a suggestion for a person to accept, and a candidate is
-- absent from current_valid_assertions. The rows would exist, the fixture
-- would load without error, and every direct-fact question would then score
-- as a retrieval failure that is really a policy setting. So say it here.
--
-- The remedy is to load the fixture into a database with no scope governing
-- these subjects, or to accept the candidates with accept_assertion() as a
-- settler. This file does not accept on anyone's behalf: an agent writes
-- candidates and only a person's accept makes a claim current.

DO $$
DECLARE
    v_expected CONSTANT int := 4;
    v_current  int;
    v_pending  int;
BEGIN
    SELECT count(*) INTO v_current
    FROM current_valid_assertions a
    WHERE (a.subject_node_id, a.assertion_type) IN (
        ('fa000001-0003-0001-0001-000000000001'::uuid, 'project_status'),
        ('fa000001-0004-0001-0001-000000000001'::uuid, 'issue_cause'),
        ('fa000001-0004-0001-0001-000000000003'::uuid, 'issue_cause'),
        ('fa000001-0001-0001-0001-000000000002'::uuid, 'subcontractor_role')
    );

    IF v_current < v_expected THEN
        SELECT count(*) INTO v_pending
        FROM assertions a
        WHERE a.status = 'candidate'
          AND a.superseded_at IS NULL
          AND (a.subject_node_id, a.assertion_type) IN (
              ('fa000001-0003-0001-0001-000000000001'::uuid, 'project_status'),
              ('fa000001-0004-0001-0001-000000000001'::uuid, 'issue_cause'),
              ('fa000001-0004-0001-0001-000000000003'::uuid, 'issue_cause'),
              ('fa000001-0001-0001-0001-000000000002'::uuid, 'subcontractor_role')
          );

        RAISE EXCEPTION
            'harbor_point loaded % of % assertions as current (% waiting for review). A review policy on a scope governing these subjects demoted them to candidates, so the direct-fact and provenance questions cannot be answered and would score as retrieval misses. Load the fixture where no scope governs these subjects, or have a settler accept the candidates.',
            v_current, v_expected, v_pending;
    END IF;

    -- The refusal target has to stay absent, or q-unanswerable-01 grades a
    -- correct answer as confabulation.
    IF EXISTS (
        SELECT 1 FROM assertions
        WHERE subject_node_id = 'fa000001-0001-0001-0001-000000000002'
          AND assertion_type = 'payment_terms'
    ) THEN
        RAISE EXCEPTION
            'a payment_terms assertion exists on Meridian Fence & Gate; q-unanswerable-01 is a refusal target and needs that gap to stay open';
    END IF;
END;
$$;
