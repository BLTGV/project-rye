\set ON_ERROR_STOP on

BEGIN;
SELECT set_config('app.current_user_id', 'bluebird_graph_builder', true);
SELECT set_config('app.current_role', 'admin', true);
SET LOCAL search_path = rye, public;

CREATE TEMP TABLE _bb_ids(key text PRIMARY KEY, id uuid) ON COMMIT DROP;
CREATE TEMP TABLE _bb_source_ref(ref text PRIMARY KEY, item_id uuid) ON COMMIT DROP;
CREATE TEMP TABLE _bb_candidate_ids(candidate_id text PRIMARY KEY, node_id uuid) ON COMMIT DROP;
CREATE TEMP TABLE _bb_candidates AS
SELECT t.value AS candidate, t.value->'sme_review' AS review
FROM jsonb_array_elements(:'merged'::jsonb) AS t(value);

CREATE OR REPLACE FUNCTION pg_temp.bb_upsert_node(
    p_node_type text,
    p_label text,
    p_external_source text,
    p_external_id text,
    p_properties jsonb DEFAULT '{}'::jsonb,
    p_attrs jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_id uuid;
BEGIN
    INSERT INTO rye.nodes(node_type, label, external_source, external_id, properties, attrs)
    VALUES (p_node_type, p_label, p_external_source, p_external_id, coalesce(p_properties, '{}'::jsonb), coalesce(p_attrs, '{}'::jsonb))
    ON CONFLICT (external_source, external_id)
        WHERE external_id IS NOT NULL AND archived_at IS NULL
    DO UPDATE
        SET label = EXCLUDED.label,
            properties = rye.nodes.properties || EXCLUDED.properties,
            attrs = rye.nodes.attrs || EXCLUDED.attrs,
            updated_at = now()
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.bb_upsert_edge(
    p_edge_type text,
    p_source_id uuid,
    p_target_id uuid,
    p_properties jsonb DEFAULT '{}'::jsonb,
    p_attrs jsonb DEFAULT '{}'::jsonb,
    p_effective_from timestamptz DEFAULT NULL,
    p_effective_to timestamptz DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_id uuid;
BEGIN
    SELECT id INTO v_id
    FROM rye.edges
    WHERE edge_type = p_edge_type
      AND source_id = p_source_id
      AND target_id = p_target_id
      AND effective_from IS NOT DISTINCT FROM p_effective_from
      AND effective_to IS NOT DISTINCT FROM p_effective_to
      AND archived_at IS NULL
    LIMIT 1;

    IF v_id IS NULL THEN
        INSERT INTO rye.edges(edge_type, source_id, target_id, properties, attrs, effective_from, effective_to)
        VALUES (p_edge_type, p_source_id, p_target_id, coalesce(p_properties, '{}'::jsonb), coalesce(p_attrs, '{}'::jsonb), p_effective_from, p_effective_to)
        RETURNING id INTO v_id;
    END IF;

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.bb_candidate_uuid(p_candidate_key text) RETURNS uuid
LANGUAGE sql
AS $$
    SELECT node_id FROM pg_temp._bb_candidate_ids WHERE candidate_id = p_candidate_key
$$;

CREATE OR REPLACE FUNCTION pg_temp.bb_promote_assertion_once(
    p_candidate_key text,
    p_subject_id uuid,
    p_assertion_type text,
    p_assertion_key text,
    p_claim jsonb,
    p_effective_at timestamptz DEFAULT NULL,
    p_effective_to timestamptz DEFAULT NULL,
    p_confidence numeric DEFAULT 1.0
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_candidate_id uuid;
    v_assertion_id uuid;
BEGIN
    v_candidate_id := pg_temp.bb_candidate_uuid(p_candidate_key);
    IF v_candidate_id IS NULL THEN
        RAISE EXCEPTION 'Candidate % not found', p_candidate_key;
    END IF;

    SELECT id INTO v_assertion_id
    FROM rye.assertions
    WHERE subject_node_id = p_subject_id
      AND assertion_type = p_assertion_type
      AND assertion_key = p_assertion_key
      AND attrs->>'candidate_id' = v_candidate_id::text
      AND superseded_at IS NULL
    LIMIT 1;

    IF v_assertion_id IS NULL THEN
        v_assertion_id := rye.promote_candidate_to_assertion(
            p_candidate_id    := v_candidate_id,
            p_subject_node_id := p_subject_id,
            p_assertion_type  := p_assertion_type,
            p_assertion_key   := p_assertion_key,
            p_claim           := p_claim,
            p_effective_at    := p_effective_at,
            p_effective_to    := p_effective_to,
            p_confidence      := p_confidence,
            p_actor           := 'bluebird_graph_builder'
        );
    END IF;

    RETURN v_assertion_id;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.bb_promote_edge_once(
    p_candidate_key text,
    p_source_id uuid,
    p_target_id uuid,
    p_edge_type text,
    p_properties jsonb DEFAULT '{}'::jsonb,
    p_effective_from timestamptz DEFAULT NULL,
    p_effective_to timestamptz DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_candidate_id uuid;
    v_edge_id uuid;
BEGIN
    v_candidate_id := pg_temp.bb_candidate_uuid(p_candidate_key);
    IF v_candidate_id IS NULL THEN
        RAISE EXCEPTION 'Candidate % not found', p_candidate_key;
    END IF;

    SELECT id INTO v_edge_id
    FROM rye.edges
    WHERE attrs->>'candidate_id' = v_candidate_id::text
      AND edge_type = p_edge_type
      AND source_id = p_source_id
      AND target_id = p_target_id
      AND archived_at IS NULL
    LIMIT 1;

    IF v_edge_id IS NULL THEN
        v_edge_id := rye.promote_candidate_to_edge(
            p_candidate_id   := v_candidate_id,
            p_source_id      := p_source_id,
            p_target_id      := p_target_id,
            p_edge_type      := p_edge_type,
            p_properties     := p_properties,
            p_effective_from := p_effective_from,
            p_effective_to   := p_effective_to,
            p_actor          := 'bluebird_graph_builder'
        );
    END IF;

    RETURN v_edge_id;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.bb_schedule_deal_once(
    p_candidate_key text,
    p_opp_id uuid,
    p_stage text,
    p_effective_at timestamptz,
    p_reason text,
    p_plan_properties jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_candidate_id uuid;
    v_assertion_id uuid;
    v_plan_props jsonb;
BEGIN
    v_candidate_id := pg_temp.bb_candidate_uuid(p_candidate_key);
    v_plan_props := coalesce(p_plan_properties, '{}'::jsonb) || jsonb_build_object(
        'candidate_id', v_candidate_id::text,
        'candidate_key', p_candidate_key,
        'source_refs', rye.knowledge_candidate_source_refs(v_candidate_id),
        'scenario', 'bluebird_bakes'
    );

    v_assertion_id := rye.schedule_deal_stage_change(
        p_opp_id          := p_opp_id,
        p_stage           := p_stage,
        p_effective_at    := p_effective_at,
        p_reason          := p_reason,
        p_actor           := 'bluebird_graph_builder',
        p_plan_properties := v_plan_props
    );

    PERFORM rye.set_candidate_status(v_candidate_id, 'accepted', 'Promoted to scheduled deal stage assertion ' || v_assertion_id::text, 'bluebird_graph_builder');
    RETURN v_assertion_id;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.bb_schedule_task_once(
    p_candidate_key text,
    p_task_id uuid,
    p_status text,
    p_effective_at timestamptz,
    p_reason text,
    p_plan_properties jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_candidate_id uuid;
    v_assertion_id uuid;
    v_plan_props jsonb;
BEGIN
    v_candidate_id := pg_temp.bb_candidate_uuid(p_candidate_key);
    v_plan_props := coalesce(p_plan_properties, '{}'::jsonb) || jsonb_build_object(
        'candidate_id', v_candidate_id::text,
        'candidate_key', p_candidate_key,
        'source_refs', rye.knowledge_candidate_source_refs(v_candidate_id),
        'scenario', 'bluebird_bakes'
    );

    v_assertion_id := rye.schedule_task_status_change(
        p_task_id         := p_task_id,
        p_status          := p_status,
        p_effective_at    := p_effective_at,
        p_reason          := p_reason,
        p_actor           := 'bluebird_graph_builder',
        p_plan_properties := v_plan_props
    );

    PERFORM rye.set_candidate_status(v_candidate_id, 'accepted', 'Promoted to scheduled task status assertion ' || v_assertion_id::text, 'bluebird_graph_builder');
    RETURN v_assertion_id;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.bb_schedule_milestone_once(
    p_candidate_key text,
    p_milestone_id uuid,
    p_status text,
    p_effective_at timestamptz,
    p_reason text,
    p_plan_properties jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_candidate_id uuid;
    v_assertion_id uuid;
    v_plan_props jsonb;
BEGIN
    v_candidate_id := pg_temp.bb_candidate_uuid(p_candidate_key);
    v_plan_props := coalesce(p_plan_properties, '{}'::jsonb) || jsonb_build_object(
        'candidate_id', v_candidate_id::text,
        'candidate_key', p_candidate_key,
        'source_refs', rye.knowledge_candidate_source_refs(v_candidate_id),
        'scenario', 'bluebird_bakes'
    );

    v_assertion_id := rye.schedule_milestone_status_change(
        p_milestone_id    := p_milestone_id,
        p_status          := p_status,
        p_effective_at    := p_effective_at,
        p_reason          := p_reason,
        p_actor           := 'bluebird_graph_builder',
        p_plan_properties := v_plan_props
    );

    PERFORM rye.set_candidate_status(v_candidate_id, 'accepted', 'Promoted to scheduled milestone status assertion ' || v_assertion_id::text, 'bluebird_graph_builder');
    RETURN v_assertion_id;
END;
$$;

DO $$
DECLARE
    v_scope uuid;
    v_plugin record;
    v_event uuid;
BEGIN
    v_scope := rye.create_onboarding_scope(
        p_scope_key  := 'bluebird_bakes:retail_launch_sales_intake',
        p_label      := 'Bluebird Bakes Retail Launch and Sales Intake',
        p_purpose    := 'Represent SME-reviewed Bluebird Bakes retail launch controls, wholesale sales plans, source-of-truth rules, and open evidence gaps from the June 2026 replay packet.',
        p_boundary   := jsonb_build_object(
            'scenario', 'bluebird_bakes',
            'source_window', jsonb_build_object('start', '2026-04-09', 'end', '2026-06-22'),
            'in_scope', jsonb_build_array('source policies', 'retailer launch procedure', 'GreenMart pilot dependencies and future plans', 'Lakeside future proposal plan', 'candidate evidence gaps'),
            'out_of_scope', jsonb_build_array('unstated conversation context', 'scenario_brief.md', 'unverified CrumbCRM and KitchenBoard current records')
        ),
        p_owner      := 'Bluebird Bakes operations review',
        p_created_by := 'bluebird_graph_builder',
        p_properties := jsonb_build_object('scenario', 'bluebird_bakes', 'load_type', 'business_replay')
    );
    INSERT INTO _bb_ids VALUES ('scope', v_scope) ON CONFLICT (key) DO UPDATE SET id = EXCLUDED.id;

    FOR v_plugin IN
        SELECT external_id AS plugin_id, label, properties->'manifest' AS manifest
        FROM rye.nodes
        WHERE node_type = 'plugin'
          AND external_source = 'rye_plugin'
          AND external_id IN ('rye-source-context', 'rye-evidence-anchor', 'rye-org', 'rye-crm', 'rye-project-management', 'rye-declared-knowledge')
    LOOP
        PERFORM rye.enable_plugin_for_scope(v_scope, v_plugin.plugin_id, v_plugin.label, coalesce(v_plugin.manifest, '{}'::jsonb), 'bluebird_graph_builder');
    END LOOP;

    PERFORM rye.record_scope_policy(
        v_scope,
        'evidence_policy'::text,
        jsonb_build_object(
            'accepted_fact_requirement', 'Accepted facts must retain source_item support and candidate/SME provenance.',
            'official_current_status_rule', 'Current sales stages, forecasts, launch task status, launch task owner/due dates, and milestone status/target dates require the named source of truth record.',
            'allowed_packet_evidence', jsonb_build_array('Slack excerpts', 'email messages', 'SME review decisions'),
            'needs_more_evidence_action', 'leave as needs_review candidate and create an evidence-review task'
        ),
        'bluebird-source-and-candidate-provenance'::text,
        'bluebird_graph_builder'::text,
        NULL::timestamptz,
        NULL::timestamptz
    );

    PERFORM rye.record_scope_policy(
        v_scope,
        'retention_policy'::text,
        jsonb_build_object(
            'retain', jsonb_build_array('source item raw text', 'candidate fact payloads', 'SME decisions', 'promotion events'),
            'reason', 'business replay auditability'
        ),
        'bluebird-replay-retention'::text,
        'bluebird_graph_builder'::text,
        NULL::timestamptz,
        NULL::timestamptz
    );

    v_event := rye.activate_onboarding_scope(v_scope, 'bluebird_graph_builder');

    PERFORM rye.record_artifact(
        p_artifact_type := 'business_replay_input_packet',
        p_content := jsonb_build_object(
            'scenario', 'bluebird_bakes',
            'files', jsonb_build_array(
                jsonb_build_object('path', '/home/casey/git/project-rye/eval/business_replay_scenarios/bluebird_bakes/source_material.md', 'sha256', '60806ee5eef51979316861f77297325323a4a8eb3b7efaece0972973e6cbd67e'),
                jsonb_build_object('path', '/home/casey/git/project-rye/eval/business_replay_scenarios/bluebird_bakes/candidate_facts.json', 'sha256', 'c95939e03d3af70176497f04f5209e82dab6e516af58c44feca9606e17daa841'),
                jsonb_build_object('path', '/home/casey/git/project-rye/eval/business_replay_scenarios/bluebird_bakes/sme_review.json', 'sha256', '98269b89d97580eeb54cfb3032f8de77b0cecfa93e291dd66248c7d653d348aa')
            )
        ),
        p_source_event_id := v_event,
        p_source_node_id := v_scope,
        p_related_node_ids := ARRAY[v_scope],
        p_location := jsonb_build_object('scenario_dir', '/home/casey/git/project-rye/eval/business_replay_scenarios/bluebird_bakes'),
        p_content_hash := 'bluebird_bakes_input_packet_60806ee5_c95939e0_98269b89'
    );
END $$;

CREATE TEMP TABLE _bb_source_item_seed(
    source_ref text PRIMARY KEY,
    external_id text NOT NULL,
    account_key text NOT NULL,
    container_key text NOT NULL,
    source_type text NOT NULL,
    container_label text NOT NULL,
    occurred_at timestamptz NOT NULL,
    actor_name text NOT NULL,
    subject text,
    body text NOT NULL
) ON COMMIT DROP;

INSERT INTO _bb_source_item_seed VALUES
('Slack #retail-launch 2026-04-09 Elena Rossi', 'source_item:slack:retail-launch:2026-04-09T16-35:elena-rossi', 'slack', 'slack:#retail-launch', 'slack_message', '#retail-launch', '2026-04-09 16:35:00-04', 'Elena Rossi', NULL, $bb$The almond label incident has to become a process change. No retailer launch should ship without an explicit QA label approval step.$bb$),
('Slack #retail-launch 2026-05-02 Jules Kim', 'source_item:slack:retail-launch:2026-05-02T09-20:jules-kim', 'slack', 'slack:#retail-launch', 'slack_message', '#retail-launch', '2026-05-02 09:20:00-04', 'Jules Kim', NULL, $bb$Retail launch checklist now has three required work items: QA label approval, case pack test, and first shipment booking. Use KitchenBoard for launch task status. Slack is just for notes.$bb$),
('Slack #retail-launch 2026-06-18 Priya Shah', 'source_item:slack:retail-launch:2026-06-18T14-08:priya-shah', 'slack', 'slack:#retail-launch', 'slack_message', '#retail-launch', '2026-06-18 14:08:00-04', 'Priya Shah', NULL, $bb$GreenMart allergen label approval is in review. I own it. Due 2026-07-09. It cannot be approved until Omar signs off on the revised allergen language.$bb$),
('Slack #retail-launch 2026-06-19 Marcus Reed', 'source_item:slack:retail-launch:2026-06-19T11-45:marcus-reed', 'slack', 'slack:#retail-launch', 'slack_message', '#retail-launch', '2026-06-19 11:45:00-04', 'Marcus Reed', NULL, $bb$GreenMart case pack test is in progress and I own it. We are testing 12 packs per case because freezer shelf height is tight. Due 2026-07-12.$bb$),
('Slack #retail-launch 2026-06-20 Caleb Moore', 'source_item:slack:retail-launch:2026-06-20T08-05:caleb-moore', 'slack', 'slack:#retail-launch', 'slack_message', '#retail-launch', '2026-06-20 08:05:00-04', 'Caleb Moore', NULL, $bb$ColdLink first shipment booking is todo. I own it. Need Wyatt to confirm the frozen dock appointment. Due 2026-07-15.$bb$),
('Slack #retail-launch 2026-06-21 Jules Kim', 'source_item:slack:retail-launch:2026-06-21T13-22:jules-kim', 'slack', 'slack:#retail-launch', 'slack_message', '#retail-launch', '2026-06-21 13:22:00-04', 'Jules Kim', NULL, $bb$GreenMart pilot ship date is a milestone. Current state is waiting on customer approval. Target is 2026-07-24. If label approval and case pack both pass, mark the milestone approved on 2026-07-22.$bb$),
('Slack #retail-launch 2026-06-22 Elena Rossi', 'source_item:slack:retail-launch:2026-06-22T09-00:elena-rossi', 'slack', 'slack:#retail-launch', 'slack_message', '#retail-launch', '2026-06-22 09:00:00-04', 'Elena Rossi', NULL, $bb$KitchenBoard remains official for launch task and milestone status until 2026-07-20. LaunchPad becomes official for project task and milestone status on 2026-07-20.$bb$),
('Slack #wholesale-sales 2026-06-17 Tina Alvarez', 'source_item:slack:wholesale-sales:2026-06-17T10-12:tina-alvarez', 'slack', 'slack:#wholesale-sales', 'slack_message', '#wholesale-sales', '2026-06-17 10:12:00-04', 'Tina Alvarez', NULL, $bb$GreenMart frozen pastry pilot is proposal sent. Omar is reviewing revised allergen language with legal. If he accepts it, move GreenMart to contract review on 2026-07-11.$bb$),
('Slack #wholesale-sales 2026-06-18 Dana Wu', 'source_item:slack:wholesale-sales:2026-06-18T15-30:dana-wu', 'slack', 'slack:#wholesale-sales', 'slack_message', '#wholesale-sales', '2026-06-18 15:30:00-04', 'Dana Wu', NULL, $bb$Forecast values: GreenMart frozen pastry pilot is $128,000 annualized at 70%. Lakeside Coffee seasonal croissant program is $52,000 at 35%.$bb$),
('Slack #wholesale-sales 2026-06-20 Tina Alvarez', 'source_item:slack:wholesale-sales:2026-06-20T10-44:tina-alvarez', 'slack', 'slack:#wholesale-sales', 'slack_message', '#wholesale-sales', '2026-06-20 10:44:00-04', 'Tina Alvarez', NULL, $bb$Lakeside Coffee is still qualification. Sophie wants final pricing before a proposal. If Dana sends final pricing, move Lakeside to proposal sent on 2026-07-18.$bb$),
('Slack #wholesale-sales 2026-06-22 Elena Rossi', 'source_item:slack:wholesale-sales:2026-06-22T09-25:elena-rossi', 'slack', 'slack:#wholesale-sales', 'slack_message', '#wholesale-sales', '2026-06-22 09:25:00-04', 'Elena Rossi', NULL, $bb$CrumbCRM is current truth for sales stage and next sales action. LaunchPad is not a sales source. Checklist v2 starts 2026-08-05 for new retailer launches only.$bb$),
('Email 2026-04-09 Elena Rossi, Label mistake postmortem', 'source_item:email:2026-04-09T18-12:elena-rossi:label-mistake-postmortem', 'email', 'email:operational-review', 'email_message', 'Operational review email packet', '2026-04-09 18:12:00-04', 'Elena Rossi', 'Label mistake postmortem', $bb$The outdated almond proof shipped because launch status was scattered between email and Slack. Effective immediately, retailer launches need a QA label approval task before first shipment.$bb$),
('Email 2026-06-17 Omar Blake, GreenMart allergen language', 'source_item:email:2026-06-17T14-42:omar-blake:greenmart-allergen-language', 'email', 'email:operational-review', 'email_message', 'Operational review email packet', '2026-06-17 14:42:00-04', 'Omar Blake', 'GreenMart allergen language', $bb$We are close on the frozen pastry pilot. Legal wants the allergen statement revised one more time. If the updated wording is acceptable, I can approve it on July 10 and send the deal to contract review July 11.$bb$),
('Email 2026-06-18 Sophie Grant, Lakeside seasonal croissants', 'source_item:email:2026-06-18T16-20:sophie-grant:lakeside-seasonal-croissants', 'email', 'email:operational-review', 'email_message', 'Operational review email packet', '2026-06-18 16:20:00-04', 'Sophie Grant', 'Lakeside seasonal croissants', $bb$Please send final pricing before we review a proposal. If Dana can get pricing to us before July 18, I can take the seasonal croissant program to our buying meeting that day.$bb$),
('Email 2026-06-21 Wyatt Ford, GreenMart first shipment booking', 'source_item:email:2026-06-21T08-28:wyatt-ford:greenmart-first-shipment-booking', 'email', 'email:operational-review', 'email_message', 'Operational review email packet', '2026-06-21 08:28:00-04', 'Wyatt Ford', 'GreenMart first shipment booking', $bb$Caleb, ColdLink can hold a frozen dock appointment for the week of July 22, but I need the final case pack by July 15.$bb$),
('Email 2026-06-22 Jules Kim, Launch source rules', 'source_item:email:2026-06-22T07-55:jules-kim:launch-source-rules', 'email', 'email:operational-review', 'email_message', 'Operational review email packet', '2026-06-22 07:55:00-04', 'Jules Kim', 'Launch source rules', $bb$For current answers, CrumbCRM owns sales stages and next sales actions. KitchenBoard owns launch tasks and milestones. LaunchPad replaces KitchenBoard for task and milestone status starting July 20. Retailer onboarding checklist v2 starts August 5 for new launches only; do not convert GreenMart unless Elena approves.$bb$);

DO $$
DECLARE
    r record;
    v_scope uuid := (SELECT id FROM _bb_ids WHERE key = 'scope');
    v_account uuid;
    v_container uuid;
    v_item uuid;
BEGIN
    INSERT INTO _bb_ids VALUES
      ('source_account:slack', pg_temp.bb_upsert_node('source_account', 'Bluebird Bakes Slack Workspace', 'bluebird_bakes_source', 'source_account:slack', jsonb_build_object('source_type', 'slack', 'confirmation_status', 'provided_for_operational_review', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'))),
      ('source_account:email', pg_temp.bb_upsert_node('source_account', 'Bluebird Bakes Email Export', 'bluebird_bakes_source', 'source_account:email', jsonb_build_object('source_type', 'email', 'confirmation_status', 'provided_for_operational_review', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes')))
    ON CONFLICT (key) DO UPDATE SET id = EXCLUDED.id;

    FOR r IN SELECT DISTINCT account_key, container_key, container_label FROM _bb_source_item_seed LOOP
        v_account := (SELECT id FROM _bb_ids WHERE key = 'source_account:' || r.account_key);
        v_container := pg_temp.bb_upsert_node('source_container', r.container_label, 'bluebird_bakes_source', 'source_container:' || r.container_key, jsonb_build_object('source_account_id', v_account::text, 'source_type', r.account_key, 'container_key', r.container_key, 'confirmation_status', 'provided_for_operational_review', 'context_note', 'Container name retained as provenance only; business meaning comes from item text and SME review.', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
        INSERT INTO _bb_ids VALUES ('source_container:' || r.container_key, v_container) ON CONFLICT (key) DO UPDATE SET id = EXCLUDED.id;
        PERFORM pg_temp.bb_upsert_edge('contains_item', v_account, v_container, jsonb_build_object('relationship', 'account_contains_container'), jsonb_build_object('scenario', 'bluebird_bakes'));
    END LOOP;

    FOR r IN SELECT * FROM _bb_source_item_seed ORDER BY occurred_at LOOP
        v_container := (SELECT id FROM _bb_ids WHERE key = 'source_container:' || r.container_key);
        v_item := pg_temp.bb_upsert_node('source_item', r.source_ref, 'bluebird_bakes_source', r.external_id, jsonb_build_object('source_ref', r.source_ref, 'source_type', r.source_type, 'container', r.container_label, 'occurred_at', r.occurred_at, 'actor_name', r.actor_name, 'subject', r.subject, 'body', r.body, 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
        INSERT INTO _bb_source_ref VALUES (r.source_ref, v_item) ON CONFLICT (ref) DO UPDATE SET item_id = EXCLUDED.item_id;
        PERFORM pg_temp.bb_upsert_edge('contains_item', v_container, v_item, jsonb_build_object('source_ref', r.source_ref), jsonb_build_object('scenario', 'bluebird_bakes'));
        PERFORM rye.record_artifact(p_artifact_type := 'source_item_raw', p_content := jsonb_build_object('source_ref', r.source_ref, 'source_type', r.source_type, 'occurred_at', r.occurred_at, 'actor_name', r.actor_name, 'subject', r.subject, 'body', r.body), p_source_node_id := v_item, p_related_node_ids := ARRAY[v_item, v_container], p_location := jsonb_build_object('source_ref', r.source_ref), p_content_hash := md5(r.external_id || ':' || r.body));
    END LOOP;

    PERFORM rye.record_event('source_context_intake_completed', 'Loaded Bluebird Bakes source account, container, and item provenance', jsonb_build_object('scenario', 'bluebird_bakes', 'source_item_count', (SELECT count(*) FROM _bb_source_ref)), ARRAY[v_scope, (SELECT id FROM _bb_ids WHERE key = 'source_account:slack'), (SELECT id FROM _bb_ids WHERE key = 'source_account:email')], ARRAY['scope', 'source_account', 'source_account'], 'bluebird_graph_builder');
END $$;

DO $$
DECLARE
    r record;
    v_candidate_id uuid;
    v_candidate_key text;
    v_raw_kind text;
    v_kind text;
    v_decision text;
    v_source_refs text[];
    v_source_node_ids uuid[];
    v_payload jsonb;
BEGIN
    FOR r IN SELECT candidate, review FROM _bb_candidates LOOP
        v_candidate_key := r.candidate->>'id';
        v_raw_kind := r.candidate->>'kind';
        v_kind := CASE v_raw_kind WHEN 'source_policy' THEN 'policy_change' WHEN 'future_plan' THEN 'fact' WHEN 'decision' THEN 'decision' WHEN 'procedure' THEN 'procedure' WHEN 'risk' THEN 'risk' WHEN 'task' THEN 'task' WHEN 'edge' THEN 'edge' ELSE 'fact' END;
        v_decision := coalesce(r.review->>'decision', 'needs_review');
        SELECT coalesce(array_agg(src.ref), '{}'::text[]) INTO v_source_refs FROM jsonb_array_elements_text(coalesce(r.candidate->'source_refs', '[]'::jsonb)) AS src(ref);
        SELECT coalesce(array_agg(sr.item_id ORDER BY refs.ord), '{}'::uuid[]) INTO v_source_node_ids FROM unnest(v_source_refs) WITH ORDINALITY AS refs(ref, ord) JOIN _bb_source_ref sr ON sr.ref = refs.ref;
        v_payload := jsonb_build_object('scenario', 'bluebird_bakes', 'candidate_id', v_candidate_key, 'original_kind', v_raw_kind, 'candidate_fact', r.candidate - 'sme_review', 'sme_review', r.review, 'sme_decision', v_decision, 'source_refs', to_jsonb(v_source_refs));

        SELECT id INTO v_candidate_id FROM rye.nodes WHERE node_type = 'knowledge_candidate' AND external_source = 'bluebird_bakes_candidate' AND external_id = v_candidate_key AND archived_at IS NULL LIMIT 1;
        IF v_candidate_id IS NULL THEN
            v_candidate_id := rye.create_knowledge_candidate(v_kind, r.candidate->>'statement', v_payload, ARRAY[(SELECT id FROM _bb_ids WHERE key = 'scope')], 'bluebird_bakes:' || v_candidate_key, 'bluebird_graph_builder', v_source_node_ids, '{}'::uuid[], (r.candidate->>'confidence')::numeric);
            UPDATE rye.nodes SET external_source = 'bluebird_bakes_candidate', external_id = v_candidate_key, properties = properties || jsonb_build_object('scenario', 'bluebird_bakes', 'candidate_id', v_candidate_key, 'sme_decision', v_decision, 'target_payload', v_payload), attrs = attrs || jsonb_build_object('scenario', 'bluebird_bakes') WHERE id = v_candidate_id;
        END IF;

        INSERT INTO _bb_candidate_ids VALUES (v_candidate_key, v_candidate_id) ON CONFLICT (candidate_id) DO UPDATE SET node_id = EXCLUDED.node_id;
        IF v_decision = 'needs_more_evidence' THEN
            PERFORM rye.set_candidate_status(v_candidate_id, 'needs_review', coalesce(r.review->>'business_answer', 'Needs more evidence'), 'bluebird_graph_builder');
        END IF;
    END LOOP;
END $$;

DO $$
DECLARE
    name text;
    v_node uuid;
    v_scope uuid := (SELECT id FROM _bb_ids WHERE key = 'scope');
    v_greenmart_opp uuid;
    v_lakeside_opp uuid;
    v_greenmart_project uuid;
    v_review_project uuid;
    v_label_task uuid;
    v_omar_task uuid;
    v_case_pack_task uuid;
    v_shipment_task uuid;
    v_final_case_pack_task uuid;
    v_ship_milestone uuid;
    v_proc_launch uuid;
    v_proc_checklist uuid;
    v_proc_checklist_v2 uuid;
    r record;
    v_review_task uuid;
    v_event uuid;
BEGIN
    INSERT INTO _bb_ids VALUES
      ('org:bluebird-bakes', pg_temp.bb_upsert_node('org', 'Bluebird Bakes', 'bluebird_bakes_business', 'org:bluebird-bakes', jsonb_build_object('org_type', 'company', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'))),
      ('org:greenmart', pg_temp.bb_upsert_node('org', 'GreenMart', 'bluebird_bakes_business', 'org:greenmart', jsonb_build_object('org_type', 'retailer', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'))),
      ('org:lakeside-coffee', pg_temp.bb_upsert_node('org', 'Lakeside Coffee', 'bluebird_bakes_business', 'org:lakeside-coffee', jsonb_build_object('org_type', 'customer', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'))),
      ('org:coldlink', pg_temp.bb_upsert_node('org', 'ColdLink', 'bluebird_bakes_business', 'org:coldlink', jsonb_build_object('org_type', 'logistics_partner', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes')))
    ON CONFLICT (key) DO UPDATE SET id = EXCLUDED.id;

    FOREACH name IN ARRAY ARRAY['Elena Rossi','Jules Kim','Priya Shah','Marcus Reed','Caleb Moore','Tina Alvarez','Dana Wu','Omar Blake','Sophie Grant','Wyatt Ford'] LOOP
        v_node := pg_temp.bb_upsert_node('person', name, 'bluebird_bakes_business', 'person:' || lower(replace(name, ' ', '-')), jsonb_build_object('mentioned_in_scenario', true, 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
        INSERT INTO _bb_ids VALUES ('person:' || lower(replace(name, ' ', '-')), v_node) ON CONFLICT (key) DO UPDATE SET id = EXCLUDED.id;
    END LOOP;

    FOREACH name IN ARRAY ARRAY['CrumbCRM','KitchenBoard','LaunchPad'] LOOP
        v_node := pg_temp.bb_upsert_node('system', name, 'bluebird_bakes_business', 'system:' || lower(name), jsonb_build_object('system_name', name, 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
        INSERT INTO _bb_ids VALUES ('system:' || lower(name), v_node) ON CONFLICT (key) DO UPDATE SET id = EXCLUDED.id;
        PERFORM pg_temp.bb_upsert_edge('uses_system', v_scope, v_node, jsonb_build_object('context', 'source policy'), jsonb_build_object('scenario', 'bluebird_bakes'));
    END LOOP;

    PERFORM pg_temp.bb_upsert_node('pipeline', 'Wholesale Sales Pipeline', 'bluebird_bakes_business', 'pipeline:wholesale-sales', jsonb_build_object('code', 'WHOLESALE', 'default_stage', 'unverified', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
    v_greenmart_opp := pg_temp.bb_upsert_node('opportunity', 'GreenMart frozen pastry pilot', 'bluebird_bakes_business', 'opportunity:greenmart-frozen-pastry-pilot', jsonb_build_object('code', 'BB-OPP-GREENMART-PILOT', 'name', 'GreenMart frozen pastry pilot', 'account_name', 'GreenMart', 'pipeline', 'Wholesale Sales', 'official_current_stage_status', 'needs CrumbCRM evidence', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
    v_lakeside_opp := pg_temp.bb_upsert_node('opportunity', 'Lakeside Coffee seasonal croissant program', 'bluebird_bakes_business', 'opportunity:lakeside-seasonal-croissant-program', jsonb_build_object('code', 'BB-OPP-LAKESIDE-CROISSANT', 'name', 'Lakeside Coffee seasonal croissant program', 'account_name', 'Lakeside Coffee', 'pipeline', 'Wholesale Sales', 'official_current_stage_status', 'needs CrumbCRM evidence', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
    INSERT INTO _bb_ids VALUES ('opportunity:greenmart', v_greenmart_opp), ('opportunity:lakeside', v_lakeside_opp) ON CONFLICT (key) DO UPDATE SET id = EXCLUDED.id;

    v_greenmart_project := pg_temp.bb_upsert_node('project', 'GreenMart frozen pastry pilot launch', 'bluebird_bakes_business', 'project:greenmart-frozen-pastry-pilot', jsonb_build_object('code', 'BB-PROJ-GREENMART', 'account_name', 'GreenMart', 'project_type', 'retailer_launch', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
    v_review_project := pg_temp.bb_upsert_node('project', 'Bluebird Bakes evidence review', 'bluebird_bakes_business', 'project:evidence-review', jsonb_build_object('code', 'BB-PROJ-EVIDENCE', 'project_type', 'candidate_review', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
    INSERT INTO _bb_ids VALUES ('project:greenmart', v_greenmart_project), ('project:evidence-review', v_review_project) ON CONFLICT (key) DO UPDATE SET id = EXCLUDED.id;
    PERFORM pg_temp.bb_upsert_edge('regarding', v_greenmart_project, v_greenmart_opp, jsonb_build_object('context', 'launch project for opportunity'), jsonb_build_object('scenario', 'bluebird_bakes'));

    v_label_task := pg_temp.bb_upsert_node('task', 'GreenMart allergen label approval', 'bluebird_bakes_business', 'task:greenmart-allergen-label-approval', jsonb_build_object('code', 'BB-TASK-GM-LABEL', 'title', 'GreenMart allergen label approval', 'task_type', 'launch_work_item', 'official_status_owner_due', 'needs KitchenBoard evidence', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
    v_omar_task := pg_temp.bb_upsert_node('task', 'Omar Blake signoff on GreenMart revised allergen language', 'bluebird_bakes_business', 'task:omar-signoff-greenmart-revised-allergen-language', jsonb_build_object('code', 'BB-TASK-GM-OMAR', 'title', 'Omar Blake signoff on GreenMart revised allergen language', 'task_type', 'approval', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
    v_case_pack_task := pg_temp.bb_upsert_node('task', 'GreenMart case pack test', 'bluebird_bakes_business', 'task:greenmart-case-pack-test', jsonb_build_object('code', 'BB-TASK-GM-CASEPACK', 'title', 'GreenMart case pack test', 'task_type', 'launch_work_item', 'case_pack_under_test', 12, 'official_status_owner_due', 'needs KitchenBoard evidence', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
    v_shipment_task := pg_temp.bb_upsert_node('task', 'ColdLink first shipment booking', 'bluebird_bakes_business', 'task:coldlink-first-shipment-booking', jsonb_build_object('code', 'BB-TASK-GM-SHIPBOOK', 'title', 'ColdLink first shipment booking', 'task_type', 'shipment_booking', 'official_status_owner_due', 'needs KitchenBoard evidence', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
    v_final_case_pack_task := pg_temp.bb_upsert_node('task', 'Final GreenMart case pack', 'bluebird_bakes_business', 'task:final-greenmart-case-pack', jsonb_build_object('code', 'BB-TASK-GM-FINALCASE', 'title', 'Final GreenMart case pack', 'task_type', 'dependency', 'due_date', '2026-07-15', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
    v_ship_milestone := pg_temp.bb_upsert_node('milestone', 'GreenMart pilot ship date', 'bluebird_bakes_business', 'milestone:greenmart-pilot-ship-date', jsonb_build_object('code', 'BB-MILE-GM-SHIP', 'name', 'GreenMart pilot ship date', 'official_status_target', 'needs KitchenBoard evidence', 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
    INSERT INTO _bb_ids VALUES ('task:greenmart-label', v_label_task), ('task:omar-signoff', v_omar_task), ('task:greenmart-case-pack', v_case_pack_task), ('task:coldlink-shipment-booking', v_shipment_task), ('task:final-case-pack', v_final_case_pack_task), ('milestone:greenmart-ship', v_ship_milestone) ON CONFLICT (key) DO UPDATE SET id = EXCLUDED.id;

    PERFORM pg_temp.bb_upsert_edge('contains', v_greenmart_project, v_label_task, jsonb_build_object('added_from', 'confirmed dependency anchor'), jsonb_build_object('scenario', 'bluebird_bakes'));
    PERFORM pg_temp.bb_upsert_edge('contains', v_greenmart_project, v_omar_task, jsonb_build_object('added_from', 'confirmed approval plan'), jsonb_build_object('scenario', 'bluebird_bakes'));
    PERFORM pg_temp.bb_upsert_edge('contains', v_greenmart_project, v_case_pack_task, jsonb_build_object('added_from', 'confirmed case pack decision anchor'), jsonb_build_object('scenario', 'bluebird_bakes'));
    PERFORM pg_temp.bb_upsert_edge('contains', v_greenmart_project, v_shipment_task, jsonb_build_object('added_from', 'confirmed dependency anchor'), jsonb_build_object('scenario', 'bluebird_bakes'));
    PERFORM pg_temp.bb_upsert_edge('contains', v_greenmart_project, v_final_case_pack_task, jsonb_build_object('added_from', 'confirmed dock appointment dependency'), jsonb_build_object('scenario', 'bluebird_bakes'));
    PERFORM pg_temp.bb_upsert_edge('contains', v_greenmart_project, v_ship_milestone, jsonb_build_object('added_from', 'confirmed future approval plan'), jsonb_build_object('scenario', 'bluebird_bakes'));
    PERFORM pg_temp.bb_upsert_edge('assigned_to', v_omar_task, (SELECT id FROM _bb_ids WHERE key = 'person:omar-blake'), jsonb_build_object('role', 'owner', 'basis', 'named signoff approver'), jsonb_build_object('scenario', 'bluebird_bakes'));
    PERFORM pg_temp.bb_upsert_edge('regarding', v_label_task, v_greenmart_opp, jsonb_build_object('context', 'launch task for opportunity'), jsonb_build_object('scenario', 'bluebird_bakes'));
    PERFORM pg_temp.bb_upsert_edge('regarding', v_case_pack_task, v_greenmart_opp, jsonb_build_object('context', 'launch task for opportunity'), jsonb_build_object('scenario', 'bluebird_bakes'));
    PERFORM pg_temp.bb_upsert_edge('regarding', v_shipment_task, v_greenmart_opp, jsonb_build_object('context', 'launch task for opportunity'), jsonb_build_object('scenario', 'bluebird_bakes'));

    v_proc_launch := pg_temp.bb_upsert_node('procedure', 'Retailer launch process', 'bluebird_bakes_business', 'procedure:retailer-launch-process', jsonb_build_object('scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
    v_proc_checklist := pg_temp.bb_upsert_node('procedure', 'Retail launch checklist', 'bluebird_bakes_business', 'procedure:retail-launch-checklist', jsonb_build_object('scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
    v_proc_checklist_v2 := pg_temp.bb_upsert_node('procedure', 'Retailer onboarding checklist v2', 'bluebird_bakes_business', 'procedure:retailer-onboarding-checklist-v2', jsonb_build_object('scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
    INSERT INTO _bb_ids VALUES ('procedure:retailer-launch-process', v_proc_launch), ('procedure:retail-launch-checklist', v_proc_checklist), ('procedure:checklist-v2', v_proc_checklist_v2) ON CONFLICT (key) DO UPDATE SET id = EXCLUDED.id;

    FOR r IN
        SELECT c.candidate->>'id' AS candidate_key,
               c.review->'promotion_instruction'->'fields'->>'needed_evidence' AS needed_evidence,
               c.review->>'business_answer' AS business_answer,
               row_number() OVER (ORDER BY c.candidate->>'id') AS rn
        FROM _bb_candidates c
        WHERE c.review->>'decision' = 'needs_more_evidence'
    LOOP
        v_review_task := pg_temp.bb_upsert_node('task', 'Verify: ' || r.needed_evidence, 'bluebird_bakes_business', 'review_task:' || r.candidate_key, jsonb_build_object('code', 'BB-REV-' || lpad(r.rn::text, 3, '0'), 'title', 'Verify: ' || r.needed_evidence, 'task_type', 'evidence_review', 'candidate_id', r.candidate_key, 'needed_evidence', r.needed_evidence, 'description', r.business_answer, 'scenario', 'bluebird_bakes'), jsonb_build_object('scenario', 'bluebird_bakes'));
        PERFORM pg_temp.bb_upsert_edge('contains', v_review_project, v_review_task, jsonb_build_object('added_from', 'needs_more_evidence SME decision'), jsonb_build_object('scenario', 'bluebird_bakes'));
        PERFORM pg_temp.bb_upsert_edge('regarding', v_review_task, pg_temp.bb_candidate_uuid(r.candidate_key), jsonb_build_object('context', 'evidence_gap_candidate'), jsonb_build_object('scenario', 'bluebird_bakes'));
        v_event := rye.record_event('review_requested', 'Verify: ' || r.needed_evidence, jsonb_build_object('candidate_id', r.candidate_key, 'needed_evidence', r.needed_evidence, 'scenario', 'bluebird_bakes'), ARRAY[v_review_task, pg_temp.bb_candidate_uuid(r.candidate_key)], ARRAY['task', 'candidate'], 'bluebird_graph_builder');
        PERFORM rye.record_assertion('task_status', jsonb_build_object('status', 'needs_review', 'reason', 'SME requested source-of-truth evidence before promotion'), v_review_task, NULL, 'default', NULL, NULL, v_event, 1.0, 'current', NULL, jsonb_build_object('candidate_id', pg_temp.bb_candidate_uuid(r.candidate_key), 'scenario', 'bluebird_bakes'));
    END LOOP;
END $$;

DO $$
DECLARE
    v_scope uuid := (SELECT id FROM _bb_ids WHERE key = 'scope');
    v_assertion uuid;
    v_edge uuid;
BEGIN
    v_assertion := pg_temp.bb_promote_assertion_once('crumbcrm-sales-truth', v_scope, 'source_of_truth_policy', 'crumbcrm-sales-truth', jsonb_build_object('system', 'CrumbCRM', 'owns', jsonb_build_array('sales_stage', 'next_sales_action'), 'scope', 'current sales answers', 'effective_start', '2026-06-22'), '2026-06-22 00:00:00-04', NULL, 1.0);
    v_assertion := pg_temp.bb_promote_assertion_once('kitchenboard-launch-truth', v_scope, 'source_of_truth_policy', 'kitchenboard-launch-truth', jsonb_build_object('system', 'KitchenBoard', 'owns', jsonb_build_array('launch_task_status', 'launch_milestone_status'), 'scope', 'retailer launch tasks and milestones', 'effective_end', '2026-07-20'), NULL, '2026-07-20 00:00:00-04', 1.0);
    v_assertion := pg_temp.bb_promote_assertion_once('launchpad-status-future-truth', v_scope, 'source_of_truth_policy', 'launchpad-status-future-truth', jsonb_build_object('system', 'LaunchPad', 'owns', jsonb_build_array('project_task_status', 'project_milestone_status'), 'scope', 'project tasks and milestones', 'effective_start', '2026-07-20'), '2026-07-20 00:00:00-04', NULL, 1.0);
    v_assertion := pg_temp.bb_promote_assertion_once('launchpad-not-sales-source', v_scope, 'source_of_truth_policy', 'launchpad-not-sales-source', jsonb_build_object('system', 'LaunchPad', 'does_not_own', jsonb_build_array('sales_stage', 'next_sales_action'), 'scope', 'sales data'), '2026-06-22 00:00:00-04', NULL, 1.0);
    v_assertion := pg_temp.bb_promote_assertion_once('checklist-v2-new-launches-only', (SELECT id FROM _bb_ids WHERE key = 'procedure:checklist-v2'), 'procedure_status', 'checklist-v2-new-launches-only', jsonb_build_object('policy', 'retailer_onboarding_checklist_v2', 'effective_start', '2026-08-05', 'scope', 'new retailer launches only', 'excluded_project', 'GreenMart frozen pastry pilot', 'exception_approver', 'Elena Rossi'), '2026-08-05 00:00:00-04', NULL, 1.0);
    v_assertion := pg_temp.bb_promote_assertion_once('qa-label-before-shipment', (SELECT id FROM _bb_ids WHERE key = 'procedure:retailer-launch-process'), 'procedure_status', 'qa-label-before-shipment', jsonb_build_object('process', 'retailer_launch', 'requirement', 'QA label approval task before first shipment', 'effective_start', '2026-04-09'), '2026-04-09 00:00:00-04', NULL, 1.0);
    v_assertion := pg_temp.bb_promote_assertion_once('retail-launch-checklist-items', (SELECT id FROM _bb_ids WHERE key = 'procedure:retail-launch-checklist'), 'procedure_status', 'required-work-items', jsonb_build_object('checklist', 'retail_launch', 'required_work_items', jsonb_build_array('QA label approval', 'case pack test', 'first shipment booking'), 'status_source', 'KitchenBoard'), '2026-05-02 00:00:00-04', NULL, 1.0);
    v_assertion := pg_temp.bb_promote_assertion_once('almond-label-status-risk', (SELECT id FROM _bb_ids WHERE key = 'procedure:retailer-launch-process'), 'process_risk', 'almond-label-status-risk', jsonb_build_object('risk', 'launch status scattered across informal channels can cause label mistakes', 'incident', 'outdated almond proof shipped', 'mitigation', 'explicit QA label approval before first shipment'), '2026-04-09 00:00:00-04', NULL, 1.0);

    v_edge := pg_temp.bb_promote_edge_once('greenmart-label-omar-dependency', (SELECT id FROM _bb_ids WHERE key = 'task:omar-signoff'), (SELECT id FROM _bb_ids WHERE key = 'task:greenmart-label'), 'blocks', jsonb_build_object('relationship', 'blocked_by', 'plain_english', 'GreenMart allergen label approval cannot be completed until Omar Blake signs off on the revised allergen language.'), '2026-06-18 14:08:00-04', NULL);
    v_assertion := pg_temp.bb_schedule_task_once('greenmart-omar-approval-plan', (SELECT id FROM _bb_ids WHERE key = 'task:omar-signoff'), 'approved', '2026-07-10 00:00:00-04', 'Updated wording is acceptable', jsonb_build_object('condition', 'updated wording is acceptable', 'planned_status', 'approved', 'source_of_truth_to_update', 'KitchenBoard'));
    v_assertion := pg_temp.bb_schedule_deal_once('greenmart-contract-review-plan', (SELECT id FROM _bb_ids WHERE key = 'opportunity:greenmart'), 'contract_review', '2026-07-11 00:00:00-04', 'Omar Blake accepts revised allergen language', jsonb_build_object('condition', 'Omar Blake accepts revised allergen language', 'source_of_truth_to_update', 'CrumbCRM', 'pipeline', 'Wholesale Sales'));
    v_assertion := pg_temp.bb_promote_assertion_once('greenmart-case-pack-12', (SELECT id FROM _bb_ids WHERE key = 'task:greenmart-case-pack'), 'project_decision', 'case-pack-under-test', jsonb_build_object('project', 'GreenMart frozen pastry pilot', 'case_pack_under_test', 12, 'reason', 'freezer shelf height is tight'), '2026-06-19 00:00:00-04', NULL, 1.0);
    v_edge := pg_temp.bb_promote_edge_once('greenmart-dock-appointment-dependency', (SELECT id FROM _bb_ids WHERE key = 'task:coldlink-shipment-booking'), (SELECT id FROM _bb_ids WHERE key = 'task:final-case-pack'), 'depends_on', jsonb_build_object('relationship', 'depends_on', 'dependency_due_date', '2026-07-15', 'dock_appointment_window', 'week of 2026-07-22', 'external_contact', 'Wyatt Ford', 'plain_english', 'ColdLink needs the final GreenMart case pack by 2026-07-15 to hold a frozen dock appointment for the week of 2026-07-22.'), '2026-06-21 08:28:00-04', NULL);
    v_assertion := pg_temp.bb_schedule_milestone_once('greenmart-ship-approval-plan', (SELECT id FROM _bb_ids WHERE key = 'milestone:greenmart-ship'), 'approved', '2026-07-22 00:00:00-04', 'Label approval and case pack both pass', jsonb_build_object('conditions', jsonb_build_array('label approval passes', 'case pack passes'), 'source_of_truth_to_update', 'LaunchPad', 'corrected_by_sme', true));
    v_assertion := pg_temp.bb_promote_assertion_once('greenmart-launch-risk', (SELECT id FROM _bb_ids WHERE key = 'project:greenmart'), 'project_risk', 'pilot-shipment-dependencies', jsonb_build_object('project', 'GreenMart frozen pastry pilot', 'risk', 'pilot shipment schedule depends on multiple open launch approvals', 'dependencies', jsonb_build_array('allergen label approval', 'case pack test', 'final case pack by 2026-07-15', 'frozen dock appointment confirmation', 'customer approval')), '2026-06-21 00:00:00-04', NULL, 1.0);
    v_assertion := pg_temp.bb_schedule_deal_once('lakeside-proposal-plan', (SELECT id FROM _bb_ids WHERE key = 'opportunity:lakeside'), 'proposal_sent', '2026-07-18 00:00:00-04', 'Dana Wu sends final pricing', jsonb_build_object('condition', 'Dana Wu sends final pricing', 'source_of_truth_to_update', 'CrumbCRM', 'customer_meeting_date', '2026-07-18', 'pipeline', 'Wholesale Sales'));
END $$;

COMMIT;

SELECT rye.refresh_materialized_views();
