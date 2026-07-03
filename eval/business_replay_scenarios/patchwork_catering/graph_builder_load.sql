SELECT set_config('app.current_role', 'admin', false);
SET search_path = rye, pg_catalog, public;

DO $$
DECLARE
    v_scope uuid;
    v_pipeline uuid;
    v_slack uuid;
    v_atlas_email uuid;
    v_willow_email uuid;
    v_baxter_email uuid;
    v_leads_sheet uuid;
    v_workboard_sheet uuid;
    v_process_note uuid;
    v_ana uuid;
    v_sofia uuid;
    v_marco uuid;
    v_nora uuid;
    v_eli uuid;
    v_theo uuid;
    v_rae uuid;
    v_priya uuid;
    v_miguel uuid;
    v_jenna uuid;
    v_omar uuid;
    v_lena uuid;
    v_deshawn uuid;
    v_patchwork uuid;
    v_atlas uuid;
    v_crest uuid;
    v_willow uuid;
    v_river_hall uuid;
    v_baxter uuid;
    v_atlas_project uuid;
    v_willow_project uuid;
    v_baxter_project uuid;
    v_atlas_opp uuid;
    v_willow_opp uuid;
    v_baxter_opp uuid;
    v_atlas_pricing_task uuid;
    v_atlas_resend_task uuid;
    v_atlas_rentals_task uuid;
    v_willow_site_task uuid;
    v_willow_staffing_task uuid;
    v_baxter_scope_task uuid;
    v_atlas_contract_milestone uuid;
    v_willow_site_milestone uuid;
    v_willow_proposal_milestone uuid;
    v_blocker uuid;
    v_candidate uuid;
BEGIN
    v_scope := create_onboarding_scope(
        p_scope_key := 'patchwork-catering-rye-dashboard',
        p_label := 'Patchwork Pantry Rye CRM/PM Dashboard',
        p_purpose := 'Use Rye as the first CRM and project dashboard for Patchwork Pantry after SME-confirmed migration from communication and spreadsheet evidence.',
        p_boundary := jsonb_build_object(
            'business', 'Patchwork Pantry Catering',
            'no_existing_crm_or_pm', true,
            'candidate_sources', jsonb_build_array('Slack #event-desk', 'Email', 'Lead Tracker spreadsheet', 'Event Workboard spreadsheet'),
            'review_gate', 'Ana Rivera or Sofia Klein confirms candidates before they become official Rye records'
        ),
        p_owner := 'Ana Rivera',
        p_created_by := 'patchwork-clean-graph-builder',
        p_properties := jsonb_build_object('scenario', 'patchwork_catering')
    );

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES (
        'pipeline',
        'Patchwork event opportunities',
        jsonb_build_object('code', 'PATCHWORK-EVENTS', 'default_stage', 'qualification', 'scenario', 'patchwork_catering'),
        jsonb_build_object('classification', 'internal'),
        'PATCHWORK-EVENTS',
        'patchwork_rye'
    )
    RETURNING id INTO v_pipeline;

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES
        ('source_item', 'Slack #event-desk export, June 18-22', jsonb_build_object('source_type', 'slack_export', 'scenario', 'patchwork_catering'), '{}'::jsonb, 'patchwork-slack-event-desk-2026-06-18-22', 'patchwork_source_packet'),
        ('source_item', 'Atlas Labs summer offsite email thread', jsonb_build_object('source_type', 'email_thread', 'scenario', 'patchwork_catering'), '{}'::jsonb, 'patchwork-email-atlas-2026-06-17', 'patchwork_source_packet'),
        ('source_item', 'Willow Creek School gala email thread', jsonb_build_object('source_type', 'email_thread', 'scenario', 'patchwork_catering'), '{}'::jsonb, 'patchwork-email-willow-2026-06-20', 'patchwork_source_packet'),
        ('source_item', 'Baxter-Diaz dessert bar email', jsonb_build_object('source_type', 'email', 'scenario', 'patchwork_catering'), '{}'::jsonb, 'patchwork-email-baxter-2026-06-21', 'patchwork_source_packet'),
        ('source_item', 'Lead Tracker spreadsheet export, June 22', jsonb_build_object('source_type', 'spreadsheet_export', 'scenario', 'patchwork_catering'), '{}'::jsonb, 'patchwork-lead-tracker-2026-06-22', 'patchwork_source_packet'),
        ('source_item', 'Event Workboard spreadsheet export, June 22', jsonb_build_object('source_type', 'spreadsheet_export', 'scenario', 'patchwork_catering'), '{}'::jsonb, 'patchwork-event-workboard-2026-06-22', 'patchwork_source_packet'),
        ('source_item', 'Rye pilot start process note', jsonb_build_object('source_type', 'process_note', 'scenario', 'patchwork_catering'), '{}'::jsonb, 'patchwork-rye-pilot-note-2026-06-22', 'patchwork_source_packet');

    SELECT id INTO v_slack FROM nodes WHERE external_id = 'patchwork-slack-event-desk-2026-06-18-22';
    SELECT id INTO v_atlas_email FROM nodes WHERE external_id = 'patchwork-email-atlas-2026-06-17';
    SELECT id INTO v_willow_email FROM nodes WHERE external_id = 'patchwork-email-willow-2026-06-20';
    SELECT id INTO v_baxter_email FROM nodes WHERE external_id = 'patchwork-email-baxter-2026-06-21';
    SELECT id INTO v_leads_sheet FROM nodes WHERE external_id = 'patchwork-lead-tracker-2026-06-22';
    SELECT id INTO v_workboard_sheet FROM nodes WHERE external_id = 'patchwork-event-workboard-2026-06-22';
    SELECT id INTO v_process_note FROM nodes WHERE external_id = 'patchwork-rye-pilot-note-2026-06-22';

    INSERT INTO artifacts (artifact_type, source_node_id, content, location, attrs)
    VALUES (
        'source_packet',
        v_process_note,
        jsonb_build_object('summary', 'Patchwork source packet includes Slack, email, Lead Tracker, Event Workboard, and Rye pilot process note. These sources are evidence for candidate facts, not authoritative status by themselves.'),
        jsonb_build_object('path', 'eval/business_replay_scenarios/patchwork_catering/source_material.md'),
        jsonb_build_object('scenario', 'patchwork_catering')
    );

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES
        ('org', 'Patchwork Pantry Catering', jsonb_build_object('scenario', 'patchwork_catering', 'org_type', 'internal'), '{}'::jsonb, 'patchwork-pantry-catering', 'patchwork'),
        ('org', 'Atlas Labs', jsonb_build_object('scenario', 'patchwork_catering', 'org_type', 'customer'), '{}'::jsonb, 'atlas-labs', 'patchwork'),
        ('org', 'Crest Rentals', jsonb_build_object('scenario', 'patchwork_catering', 'org_type', 'vendor'), '{}'::jsonb, 'crest-rentals', 'patchwork'),
        ('org', 'Willow Creek School', jsonb_build_object('scenario', 'patchwork_catering', 'org_type', 'customer'), '{}'::jsonb, 'willow-creek-school', 'patchwork'),
        ('org', 'River Hall', jsonb_build_object('scenario', 'patchwork_catering', 'org_type', 'venue'), '{}'::jsonb, 'river-hall', 'patchwork'),
        ('org', 'Baxter-Diaz wedding', jsonb_build_object('scenario', 'patchwork_catering', 'org_type', 'prospective_customer'), '{}'::jsonb, 'baxter-diaz-wedding', 'patchwork');

    SELECT id INTO v_patchwork FROM nodes WHERE external_id = 'patchwork-pantry-catering';
    SELECT id INTO v_atlas FROM nodes WHERE external_id = 'atlas-labs';
    SELECT id INTO v_crest FROM nodes WHERE external_id = 'crest-rentals';
    SELECT id INTO v_willow FROM nodes WHERE external_id = 'willow-creek-school';
    SELECT id INTO v_river_hall FROM nodes WHERE external_id = 'river-hall';
    SELECT id INTO v_baxter FROM nodes WHERE external_id = 'baxter-diaz-wedding';

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES
        ('person', 'Ana Rivera', jsonb_build_object('scenario', 'patchwork_catering', 'role', 'Owner and general manager'), '{}'::jsonb, 'ana-rivera', 'patchwork'),
        ('person', 'Sofia Klein', jsonb_build_object('scenario', 'patchwork_catering', 'role', 'Sales and event coordinator'), '{}'::jsonb, 'sofia-klein', 'patchwork'),
        ('person', 'Marco Bell', jsonb_build_object('scenario', 'patchwork_catering', 'role', 'Chef and menu lead'), '{}'::jsonb, 'marco-bell', 'patchwork'),
        ('person', 'Nora Voss', jsonb_build_object('scenario', 'patchwork_catering', 'role', 'Operations and rentals coordinator'), '{}'::jsonb, 'nora-voss', 'patchwork'),
        ('person', 'Eli Grant', jsonb_build_object('scenario', 'patchwork_catering', 'role', 'Staffing lead'), '{}'::jsonb, 'eli-grant', 'patchwork'),
        ('person', 'Theo Marsh', jsonb_build_object('scenario', 'patchwork_catering', 'role', 'Finance and deposits'), '{}'::jsonb, 'theo-marsh', 'patchwork'),
        ('person', 'Rae Chen', jsonb_build_object('scenario', 'patchwork_catering', 'role', 'Event captain'), '{}'::jsonb, 'rae-chen', 'patchwork'),
        ('person', 'Priya Menon', jsonb_build_object('scenario', 'patchwork_catering', 'role', 'Atlas Labs workplace experience manager'), '{}'::jsonb, 'priya-menon', 'patchwork'),
        ('person', 'Miguel Arroyo', jsonb_build_object('scenario', 'patchwork_catering', 'role', 'Willow Creek School gala chair'), '{}'::jsonb, 'miguel-arroyo', 'patchwork'),
        ('person', 'Jenna Baxter', jsonb_build_object('scenario', 'patchwork_catering', 'role', 'Baxter-Diaz wedding contact'), '{}'::jsonb, 'jenna-baxter', 'patchwork'),
        ('person', 'Omar Diaz', jsonb_build_object('scenario', 'patchwork_catering', 'role', 'Baxter-Diaz wedding stakeholder'), '{}'::jsonb, 'omar-diaz', 'patchwork'),
        ('person', 'Lena Park', jsonb_build_object('scenario', 'patchwork_catering', 'role', 'Crest Rentals account manager'), '{}'::jsonb, 'lena-park', 'patchwork'),
        ('person', 'DeShawn Price', jsonb_build_object('scenario', 'patchwork_catering', 'role', 'River Hall venue manager'), '{}'::jsonb, 'deshawn-price', 'patchwork');

    SELECT id INTO v_ana FROM nodes WHERE external_id = 'ana-rivera';
    SELECT id INTO v_sofia FROM nodes WHERE external_id = 'sofia-klein';
    SELECT id INTO v_marco FROM nodes WHERE external_id = 'marco-bell';
    SELECT id INTO v_nora FROM nodes WHERE external_id = 'nora-voss';
    SELECT id INTO v_eli FROM nodes WHERE external_id = 'eli-grant';
    SELECT id INTO v_theo FROM nodes WHERE external_id = 'theo-marsh';
    SELECT id INTO v_rae FROM nodes WHERE external_id = 'rae-chen';
    SELECT id INTO v_priya FROM nodes WHERE external_id = 'priya-menon';
    SELECT id INTO v_miguel FROM nodes WHERE external_id = 'miguel-arroyo';
    SELECT id INTO v_jenna FROM nodes WHERE external_id = 'jenna-baxter';
    SELECT id INTO v_omar FROM nodes WHERE external_id = 'omar-diaz';
    SELECT id INTO v_lena FROM nodes WHERE external_id = 'lena-park';
    SELECT id INTO v_deshawn FROM nodes WHERE external_id = 'deshawn-price';

    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES
        ('works_at', v_ana, v_patchwork, jsonb_build_object('role', 'Owner and general manager')),
        ('works_at', v_sofia, v_patchwork, jsonb_build_object('role', 'Sales and event coordinator')),
        ('works_at', v_marco, v_patchwork, jsonb_build_object('role', 'Chef and menu lead')),
        ('works_at', v_nora, v_patchwork, jsonb_build_object('role', 'Operations and rentals coordinator')),
        ('works_at', v_eli, v_patchwork, jsonb_build_object('role', 'Staffing lead')),
        ('works_at', v_theo, v_patchwork, jsonb_build_object('role', 'Finance and deposits')),
        ('works_at', v_rae, v_patchwork, jsonb_build_object('role', 'Event captain')),
        ('works_at', v_priya, v_atlas, jsonb_build_object('role', 'Workplace experience manager')),
        ('works_at', v_miguel, v_willow, jsonb_build_object('role', 'Gala chair')),
        ('works_at', v_lena, v_crest, jsonb_build_object('role', 'Account manager')),
        ('works_at', v_deshawn, v_river_hall, jsonb_build_object('role', 'Venue manager')),
        ('stakeholder_for', v_omar, v_baxter, jsonb_build_object('role', 'Wedding stakeholder'));

    v_atlas_opp := create_opportunity(
        p_name := 'Atlas Labs summer offsite catering',
        p_pipeline_code := 'PATCHWORK-EVENTS',
        p_assigned_to_id := v_sofia,
        p_properties := jsonb_build_object('scenario', 'patchwork_catering', 'estimated_value', '18600'),
        p_teams := ARRAY['patchwork']
    );
    PERFORM advance_deal_stage(v_atlas_opp, 'proposal_sent', 'Confirmed by Ana/Sofia from Slack, email, and lead tracker evidence.', 'patchwork-clean-graph-builder');

    v_willow_opp := create_opportunity(
        p_name := 'Willow Creek School gala',
        p_pipeline_code := 'PATCHWORK-EVENTS',
        p_assigned_to_id := v_ana,
        p_properties := jsonb_build_object('scenario', 'patchwork_catering', 'estimated_value', '32000', 'estimated_guests', 220),
        p_teams := ARRAY['patchwork']
    );

    v_baxter_opp := create_opportunity(
        p_name := 'Baxter-Diaz late-night dessert bar',
        p_pipeline_code := 'PATCHWORK-EVENTS',
        p_assigned_to_id := v_sofia,
        p_properties := jsonb_build_object('scenario', 'patchwork_catering', 'estimated_value', '7800', 'event_month', 'September 2026'),
        p_teams := ARRAY['patchwork']
    );
    PERFORM advance_deal_stage(v_baxter_opp, 'needs_scope', 'SME confirmed this is not yet a full wedding package.', 'patchwork-clean-graph-builder');

    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES
        ('primary_contact', v_atlas_opp, v_priya, jsonb_build_object('role', 'customer_contact')),
        ('customer_account', v_atlas_opp, v_atlas, jsonb_build_object('relationship', 'prospective_customer')),
        ('primary_contact', v_willow_opp, v_miguel, jsonb_build_object('role', 'customer_contact')),
        ('customer_account', v_willow_opp, v_willow, jsonb_build_object('relationship', 'prospective_customer')),
        ('venue_under_review', v_willow_opp, v_river_hall, jsonb_build_object('reason', 'River Hall kitchen access affects staffing and proposal')),
        ('primary_contact', v_baxter_opp, v_jenna, jsonb_build_object('role', 'customer_contact')),
        ('customer_account', v_baxter_opp, v_baxter, jsonb_build_object('relationship', 'prospective_customer'));

    PERFORM record_assertion('deal_value', jsonb_build_object('amount', 18600, 'currency', 'USD', 'source', 'SME correction from old spreadsheet value'), v_atlas_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, NULL, 1.0, 'current', NULL, jsonb_build_object('source', 'rye-crm'));
    PERFORM record_assertion('win_probability', jsonb_build_object('probability', 0.60, 'source', 'SME correction from old spreadsheet probability'), v_atlas_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, NULL, 1.0, 'current', NULL, jsonb_build_object('source', 'rye-crm'));
    PERFORM record_assertion('next_sales_action', jsonb_build_object('next_action', 'Send revised vegetarian station pricing by 2026-06-24'), v_atlas_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, NULL, 1.0, 'current', NULL, jsonb_build_object('source', 'rye-crm'));

    PERFORM record_assertion('deal_value', jsonb_build_object('amount', 32000, 'currency', 'USD', 'source', 'SME-confirmed tentative value'), v_willow_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, NULL, 1.0, 'current', NULL, jsonb_build_object('source', 'rye-crm'));
    PERFORM record_assertion('win_probability', jsonb_build_object('probability', 0.45, 'source', 'SME-confirmed cap until kitchen access and headcount are known'), v_willow_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, NULL, 1.0, 'current', NULL, jsonb_build_object('source', 'rye-crm'));
    PERFORM record_assertion('next_sales_action', jsonb_build_object('next_action', 'Complete River Hall site walk and confirm kitchen access on 2026-06-27'), v_willow_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, NULL, 1.0, 'current', NULL, jsonb_build_object('source', 'rye-crm'));

    PERFORM record_assertion('deal_value', jsonb_build_object('amount', 7800, 'currency', 'USD', 'source', 'SME-confirmed rough value'), v_baxter_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, NULL, 1.0, 'current', NULL, jsonb_build_object('source', 'rye-crm'));
    PERFORM record_assertion('win_probability', jsonb_build_object('probability', 0.30, 'source', 'SME-confirmed low-confidence inquiry'), v_baxter_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, NULL, 1.0, 'current', NULL, jsonb_build_object('source', 'rye-crm'));
    PERFORM record_assertion('next_sales_action', jsonb_build_object('next_action', 'Ask Jenna whether they want dessert only or dessert plus coffee service by 2026-06-25'), v_baxter_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, NULL, 1.0, 'current', NULL, jsonb_build_object('source', 'rye-crm'));

    PERFORM schedule_deal_stage_change(v_atlas_opp, 'contract_review', '2026-06-26T09:00:00-04:00', 'Only if Priya approves the updated package.', 'patchwork-clean-graph-builder', jsonb_build_object('condition', 'Priya approves revised vegetarian station pricing'));
    PERFORM schedule_deal_stage_change(v_willow_opp, 'proposal_sent', '2026-06-30T09:00:00-04:00', 'Only if headcount and River Hall kitchen access are workable after the site walk.', 'patchwork-clean-graph-builder', jsonb_build_object('condition', 'Headcount and kitchen access are workable'));

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES
        ('project', 'Atlas Labs summer offsite delivery', jsonb_build_object('code', 'PATCHWORK-PRJ-ATLAS', 'scenario', 'patchwork_catering', 'customer', 'Atlas Labs'), jsonb_build_object('teams', jsonb_build_array('patchwork'), 'classification', 'internal'), 'PATCHWORK-PRJ-ATLAS', 'patchwork_rye'),
        ('project', 'Willow Creek School gala qualification', jsonb_build_object('code', 'PATCHWORK-PRJ-WILLOW', 'scenario', 'patchwork_catering', 'customer', 'Willow Creek School'), jsonb_build_object('teams', jsonb_build_array('patchwork'), 'classification', 'internal'), 'PATCHWORK-PRJ-WILLOW', 'patchwork_rye'),
        ('project', 'Baxter-Diaz dessert bar scope', jsonb_build_object('code', 'PATCHWORK-PRJ-BAXTER', 'scenario', 'patchwork_catering', 'customer', 'Baxter-Diaz'), jsonb_build_object('teams', jsonb_build_array('patchwork'), 'classification', 'internal'), 'PATCHWORK-PRJ-BAXTER', 'patchwork_rye');

    SELECT id INTO v_atlas_project FROM nodes WHERE external_id = 'PATCHWORK-PRJ-ATLAS';
    SELECT id INTO v_willow_project FROM nodes WHERE external_id = 'PATCHWORK-PRJ-WILLOW';
    SELECT id INTO v_baxter_project FROM nodes WHERE external_id = 'PATCHWORK-PRJ-BAXTER';

    v_atlas_pricing_task := create_task('Atlas revised vegetarian station pricing', 'Revise vegetarian station pricing before Priya takes the package to finance.', v_atlas_project, v_marco, jsonb_build_object('scenario', 'patchwork_catering', 'task_type', 'menu_pricing', 'due_date', '2026-06-24', 'priority', 'high'), ARRAY['patchwork'], ARRAY[v_atlas_opp], ARRAY['related_opportunity']);
    PERFORM advance_task_status(v_atlas_pricing_task, 'in_progress', 'SME-confirmed from Slack and Event Workboard.', 'patchwork-clean-graph-builder');

    v_atlas_resend_task := create_task('Send Atlas revised pricing to Priya', 'Send updated Atlas pricing after Marco finishes the vegetarian station revision.', v_atlas_project, v_sofia, jsonb_build_object('scenario', 'patchwork_catering', 'task_type', 'customer_follow_up', 'due_date', '2026-06-24', 'priority', 'high'), ARRAY['patchwork'], ARRAY[v_atlas_opp], ARRAY['related_opportunity']);
    PERFORM advance_task_status(v_atlas_resend_task, 'todo', 'SME-confirmed follow-up task.', 'patchwork-clean-graph-builder');
    INSERT INTO edges (edge_type, source_id, target_id, properties) VALUES ('depends_on', v_atlas_resend_task, v_atlas_pricing_task, jsonb_build_object('dependency_type', 'finish_to_start', 'reason', 'Pricing must be revised before Sofia sends it to Priya.'));

    v_atlas_rentals_task := create_task('Atlas rentals confirmation', 'Confirm Atlas lounge furniture after Crest receives revised tent dimensions.', v_atlas_project, v_nora, jsonb_build_object('scenario', 'patchwork_catering', 'task_type', 'vendor_confirmation', 'due_date', '2026-06-25', 'priority', 'high'), ARRAY['patchwork'], ARRAY[v_atlas_opp], ARRAY['related_opportunity']);
    PERFORM advance_task_status(v_atlas_rentals_task, 'blocked', 'Corrected from Event Workboard Done?; Crest still needs revised tent dimensions.', 'patchwork-clean-graph-builder');

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES ('dependency', 'Crest needs revised tent dimensions', jsonb_build_object('scenario', 'patchwork_catering', 'reason', 'Crest cannot confirm lounge furniture availability and price without revised tent dimensions.'), '{}'::jsonb, 'PATCHWORK-DEP-CREST-TENT-DIMENSIONS', 'patchwork_rye')
    RETURNING id INTO v_blocker;
    INSERT INTO edges (edge_type, source_id, target_id, properties) VALUES ('blocks', v_blocker, v_atlas_rentals_task, jsonb_build_object('reason', 'Crest needs revised tent dimensions before confirming lounge furniture.'));

    v_willow_site_task := create_task('Willow Creek site walk checklist', 'Prepare the River Hall site walk checklist before the June 27 walk.', v_willow_project, v_rae, jsonb_build_object('scenario', 'patchwork_catering', 'task_type', 'site_walk', 'due_date', '2026-06-27', 'priority', 'medium'), ARRAY['patchwork'], ARRAY[v_willow_opp], ARRAY['related_opportunity']);
    PERFORM advance_task_status(v_willow_site_task, 'todo', 'SME-confirmed from Willow Creek email and Slack.', 'patchwork-clean-graph-builder');
    INSERT INTO edges (edge_type, source_id, target_id, properties) VALUES ('collaborates_on', v_ana, v_willow_site_task, jsonb_build_object('role', 'collaborator'));

    v_willow_staffing_task := create_task('Willow Creek staffing estimate', 'Update staffing estimate after River Hall kitchen access is known.', v_willow_project, v_ana, jsonb_build_object('scenario', 'patchwork_catering', 'task_type', 'staffing_estimate', 'priority', 'medium'), ARRAY['patchwork'], ARRAY[v_willow_opp], ARRAY['related_opportunity']);
    PERFORM advance_task_status(v_willow_staffing_task, 'waiting_on_site_walk', 'Waiting on River Hall prep kitchen access and site walk.', 'patchwork-clean-graph-builder');
    INSERT INTO edges (edge_type, source_id, target_id, properties) VALUES ('depends_on', v_willow_staffing_task, v_willow_site_task, jsonb_build_object('dependency_type', 'information_needed', 'reason', 'If River Hall has no prep kitchen access, plan for two extra runners and a refrigerated van.'));

    v_baxter_scope_task := create_task('Clarify Baxter-Diaz dessert bar scope', 'Ask Jenna if they want dessert only or dessert plus coffee service.', v_baxter_project, v_sofia, jsonb_build_object('scenario', 'patchwork_catering', 'task_type', 'scope_clarification', 'due_date', '2026-06-25', 'priority', 'medium'), ARRAY['patchwork'], ARRAY[v_baxter_opp], ARRAY['related_opportunity']);
    PERFORM advance_task_status(v_baxter_scope_task, 'todo', 'SME-confirmed scope question before rough options are ready.', 'patchwork-clean-graph-builder');

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES
        ('milestone', 'Atlas contract signed and deposit received', jsonb_build_object('code', 'PATCHWORK-MIL-ATLAS-CONTRACT', 'name', 'Atlas contract signed and deposit received', 'target_date', '2026-06-28', 'priority', 'high', 'scenario', 'patchwork_catering'), jsonb_build_object('teams', jsonb_build_array('patchwork'), 'classification', 'internal'), 'PATCHWORK-MIL-ATLAS-CONTRACT', 'patchwork_rye'),
        ('milestone', 'Willow Creek River Hall site walk', jsonb_build_object('code', 'PATCHWORK-MIL-WILLOW-SITE-WALK', 'name', 'Willow Creek River Hall site walk', 'target_date', '2026-06-27', 'priority', 'medium', 'scenario', 'patchwork_catering'), jsonb_build_object('teams', jsonb_build_array('patchwork'), 'classification', 'internal'), 'PATCHWORK-MIL-WILLOW-SITE-WALK', 'patchwork_rye'),
        ('milestone', 'Willow Creek proposal decision', jsonb_build_object('code', 'PATCHWORK-MIL-WILLOW-PROPOSAL', 'name', 'Willow Creek proposal decision', 'target_date', '2026-06-30', 'priority', 'medium', 'scenario', 'patchwork_catering'), jsonb_build_object('teams', jsonb_build_array('patchwork'), 'classification', 'internal'), 'PATCHWORK-MIL-WILLOW-PROPOSAL', 'patchwork_rye');

    SELECT id INTO v_atlas_contract_milestone FROM nodes WHERE external_id = 'PATCHWORK-MIL-ATLAS-CONTRACT';
    SELECT id INTO v_willow_site_milestone FROM nodes WHERE external_id = 'PATCHWORK-MIL-WILLOW-SITE-WALK';
    SELECT id INTO v_willow_proposal_milestone FROM nodes WHERE external_id = 'PATCHWORK-MIL-WILLOW-PROPOSAL';

    PERFORM record_assertion('milestone_status', jsonb_build_object('status', 'waiting_customer', 'reason', 'Waiting on Priya approval and deposit follow-up.'), v_atlas_contract_milestone, NULL, 'default', '2026-06-22T12:00:00Z', NULL, NULL, 1.0, 'current', NULL, jsonb_build_object('source', 'rye-project-management'));
    PERFORM record_assertion('milestone_status', jsonb_build_object('status', 'planned', 'reason', 'Site walk planned for June 27.'), v_willow_site_milestone, NULL, 'default', '2026-06-22T12:00:00Z', NULL, NULL, 1.0, 'current', NULL, jsonb_build_object('source', 'rye-project-management'));
    PERFORM record_assertion('milestone_status', jsonb_build_object('status', 'pending_site_walk', 'reason', 'Proposal decision waits on headcount and kitchen access.'), v_willow_proposal_milestone, NULL, 'default', '2026-06-22T12:00:00Z', NULL, NULL, 1.0, 'current', NULL, jsonb_build_object('source', 'rye-project-management'));

    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES
        ('contains', v_atlas_project, v_atlas_contract_milestone, jsonb_build_object('kind', 'milestone')),
        ('contains', v_willow_project, v_willow_site_milestone, jsonb_build_object('kind', 'milestone')),
        ('contains', v_willow_project, v_willow_proposal_milestone, jsonb_build_object('kind', 'milestone')),
        ('assigned_to', v_atlas_contract_milestone, v_theo, jsonb_build_object('role', 'owner')),
        ('assigned_to', v_willow_site_milestone, v_rae, jsonb_build_object('role', 'owner')),
        ('assigned_to', v_willow_proposal_milestone, v_ana, jsonb_build_object('role', 'owner')),
        ('depends_on', v_atlas_contract_milestone, v_atlas_resend_task, jsonb_build_object('reason', 'Contract review waits on accepted revised pricing.')),
        ('depends_on', v_willow_proposal_milestone, v_willow_site_milestone, jsonb_build_object('reason', 'Proposal decision waits on site walk results.'));

    PERFORM schedule_milestone_status_change(v_atlas_contract_milestone, 'approved', '2026-06-28T17:00:00-04:00', 'Only if Priya signs the revised package and Theo receives the deposit.', 'patchwork-clean-graph-builder', jsonb_build_object('condition', 'Priya signs and deposit is received'));

    FOREACH v_candidate IN ARRAY ARRAY[
        create_knowledge_candidate('policy_change', 'Imported Slack, email, Lead Tracker, and Event Workboard records are candidates until Ana Rivera or Sofia Klein confirms them.', jsonb_build_object('scenario', 'patchwork_catering'), ARRAY[v_scope], 'patchwork-source-evidence-not-truth', 'patchwork-clean-intake', ARRAY[v_slack, v_leads_sheet, v_workboard_sheet, v_process_note], '{}', 0.95),
        create_knowledge_candidate('policy_change', 'Starting July 1, Rye should be checked first for opportunity status, next sales action, task status, and milestone status.', jsonb_build_object('scenario', 'patchwork_catering'), ARRAY[v_scope], 'patchwork-rye-first-july', 'patchwork-clean-intake', ARRAY[v_process_note], '{}', 0.95),
        create_knowledge_candidate('fact', 'Atlas Labs summer offsite catering is Sofia-owned, proposal sent, value $18,600, probability 60%, with revised vegetarian station pricing due June 24.', jsonb_build_object('record_type', 'opportunity', 'opportunity_id', v_atlas_opp), ARRAY[v_scope], 'patchwork-atlas-opportunity', 'patchwork-clean-intake', ARRAY[v_slack, v_atlas_email, v_leads_sheet], '{}', 0.92),
        create_knowledge_candidate('fact', 'Willow Creek School gala is Ana-owned, qualification stage, $32,000 tentative value, 45% probability, with River Hall site walk on June 27.', jsonb_build_object('record_type', 'opportunity', 'opportunity_id', v_willow_opp), ARRAY[v_scope], 'patchwork-willow-opportunity', 'patchwork-clean-intake', ARRAY[v_slack, v_willow_email, v_leads_sheet], '{}', 0.9),
        create_knowledge_candidate('fact', 'Baxter-Diaz late-night dessert bar is Sofia-owned, needs scope, $7,800 tentative value, and needs Jenna to clarify dessert-only versus coffee service.', jsonb_build_object('record_type', 'opportunity', 'opportunity_id', v_baxter_opp), ARRAY[v_scope], 'patchwork-baxter-opportunity', 'patchwork-clean-intake', ARRAY[v_slack, v_baxter_email, v_leads_sheet], '{}', 0.88),
        create_knowledge_candidate('task', 'Atlas rentals confirmation is blocked, not done, until Crest receives revised tent dimensions and replies.', jsonb_build_object('record_type', 'task', 'task_id', v_atlas_rentals_task), ARRAY[v_scope], 'patchwork-atlas-rentals-blocked', 'patchwork-clean-intake', ARRAY[v_slack, v_atlas_email, v_workboard_sheet], '{}', 0.95)
    ] LOOP
        PERFORM set_candidate_status(v_candidate, 'accepted', 'Accepted by Ana Rivera and Sofia Klein SME interview.', 'patchwork-sme');
    END LOOP;

    v_candidate := create_knowledge_candidate('fact', 'Old Lead Tracker value for Atlas was $17,800 and old probability was 55%.', jsonb_build_object('record_type', 'opportunity', 'opportunity_id', v_atlas_opp), ARRAY[v_scope], 'patchwork-reject-old-atlas-forecast', 'patchwork-clean-intake', ARRAY[v_leads_sheet], '{}', 0.85);
    PERFORM set_candidate_status(v_candidate, 'rejected', 'SME corrected Atlas value to $18,600 and probability to 60%.', 'patchwork-sme');

    v_candidate := create_knowledge_candidate('fact', 'Atlas Labs opportunity decision: Priya approval of the revised package is still pending.', jsonb_build_object('record_type', 'decision', 'opportunity_id', v_atlas_opp, 'milestone_id', v_atlas_contract_milestone), ARRAY[v_scope], 'patchwork-pending-priya-approval', 'patchwork-clean-intake', ARRAY[v_atlas_email], '{}', 0.9);
    PERFORM set_candidate_status(v_candidate, 'needs_review', 'Needs Priya approval before contract review and deposit can be treated as complete.', 'patchwork-sme');

    v_candidate := create_knowledge_candidate('fact', 'Project task decision: Crest response after revised tent dimensions is still pending for Atlas rentals confirmation.', jsonb_build_object('record_type', 'decision', 'task_id', v_atlas_rentals_task), ARRAY[v_scope], 'patchwork-pending-crest-response', 'patchwork-clean-intake', ARRAY[v_atlas_email], '{}', 0.9);
    PERFORM set_candidate_status(v_candidate, 'needs_review', 'Needs vendor response before rentals can be unblocked.', 'patchwork-sme');

    v_candidate := create_knowledge_candidate('fact', 'Willow Creek opportunity and project task decision: River Hall prep kitchen access and final headcount remain pending.', jsonb_build_object('record_type', 'decision', 'opportunity_id', v_willow_opp, 'task_id', v_willow_staffing_task), ARRAY[v_scope], 'patchwork-pending-river-hall-access', 'patchwork-clean-intake', ARRAY[v_slack, v_willow_email], '{}', 0.88);
    PERFORM set_candidate_status(v_candidate, 'needs_review', 'Needs site walk result before staffing estimate and proposal work are official.', 'patchwork-sme');

    v_candidate := create_knowledge_candidate('fact', 'Baxter-Diaz opportunity and project task decision: Jenna Baxter still needs to answer whether they want dessert only or dessert plus coffee service.', jsonb_build_object('record_type', 'decision', 'opportunity_id', v_baxter_opp, 'task_id', v_baxter_scope_task), ARRAY[v_scope], 'patchwork-pending-baxter-scope', 'patchwork-clean-intake', ARRAY[v_baxter_email], '{}', 0.9);
    PERFORM set_candidate_status(v_candidate, 'needs_review', 'Needs customer scope answer before rough options are ready.', 'patchwork-sme');

    PERFORM record_source_of_truth_policy(v_scope, 'deal_stage', 'Rye CRM/PM dashboard', '2026-06-22T12:00:00Z', 'Ana Rivera or Sofia Klein confirms imported candidates before they become official Rye records.', ARRAY['Slack evidence', 'Email evidence', 'Lead Tracker import', 'SME confirmation'], 'No prior CRM', 'Patchwork has no existing CRM; confirmed Rye opportunity records are the dashboard of record.', 'patchwork-clean-graph-builder', 'current_deal_stage');
    PERFORM record_source_of_truth_policy(v_scope, 'sales_next_action', 'Rye CRM/PM dashboard', '2026-06-22T12:00:00Z', 'Ana Rivera or Sofia Klein confirms imported candidates before they become official Rye records.', ARRAY['Slack evidence', 'Email evidence', 'Lead Tracker import', 'SME confirmation'], 'No prior CRM', 'Patchwork has no existing CRM; confirmed Rye next actions are the dashboard of record.', 'patchwork-clean-graph-builder', 'current_sales_next_action');
    PERFORM record_source_of_truth_policy(v_scope, 'project_task_status', 'Rye CRM/PM dashboard', '2026-06-22T12:00:00Z', 'Ana Rivera or Sofia Klein confirms imported candidates before they become official Rye records.', ARRAY['Slack evidence', 'Email evidence', 'Event Workboard import', 'SME confirmation'], 'No prior PM system', 'Patchwork has no existing PM; confirmed Rye task records are the dashboard of record.', 'patchwork-clean-graph-builder', 'current_project_task_status');
    PERFORM record_source_of_truth_policy(v_scope, 'project_milestone_status', 'Rye CRM/PM dashboard', '2026-06-22T12:00:00Z', 'Ana Rivera or Sofia Klein confirms imported candidates before they become official Rye records.', ARRAY['Slack evidence', 'Email evidence', 'Event Workboard import', 'SME confirmation'], 'No prior PM system', 'Patchwork has no existing PM; confirmed Rye milestone records are the dashboard of record.', 'patchwork-clean-graph-builder', 'current_project_milestone_status');

    PERFORM record_source_of_truth_policy(v_scope, 'deal_stage', 'Rye CRM/PM dashboard', '2026-07-01T09:00:00-04:00', 'New opportunity status updates should be entered or confirmed in Rye first; spreadsheets are evidence/import staging only.', ARRAY['Rye dashboard update', 'SME confirmation when imported'], 'Lead Tracker status columns', 'July 1 operating policy: Rye is checked first for opportunity status after migration.', 'patchwork-clean-graph-builder', 'july_1_deal_stage');
    PERFORM record_source_of_truth_policy(v_scope, 'sales_next_action', 'Rye CRM/PM dashboard', '2026-07-01T09:00:00-04:00', 'New sales next actions should be entered or confirmed in Rye first; spreadsheets are evidence/import staging only.', ARRAY['Rye dashboard update', 'SME confirmation when imported'], 'Lead Tracker next step columns', 'July 1 operating policy: Rye is checked first for sales next actions after migration.', 'patchwork-clean-graph-builder', 'july_1_sales_next_action');
    PERFORM record_source_of_truth_policy(v_scope, 'project_task_status', 'Rye CRM/PM dashboard', '2026-07-01T09:00:00-04:00', 'New task status updates should be entered or confirmed in Rye first; workboard rows are evidence/import staging only.', ARRAY['Rye dashboard update', 'SME confirmation when imported'], 'Event Workboard status columns', 'July 1 operating policy: Rye is checked first for task status after migration.', 'patchwork-clean-graph-builder', 'july_1_project_task_status');
    PERFORM record_source_of_truth_policy(v_scope, 'project_milestone_status', 'Rye CRM/PM dashboard', '2026-07-01T09:00:00-04:00', 'New milestone status updates should be entered or confirmed in Rye first; workboard rows are evidence/import staging only.', ARRAY['Rye dashboard update', 'SME confirmation when imported'], 'Event Workboard milestone rows', 'July 1 operating policy: Rye is checked first for milestone status after migration.', 'patchwork-clean-graph-builder', 'july_1_project_milestone_status');

    PERFORM record_event(
        p_event_type := 'rye_dashboard_migration_confirmed',
        p_summary := 'Patchwork Pantry confirmed Rye as CRM/PM dashboard after candidate review.',
        p_properties := jsonb_build_object('scenario', 'patchwork_catering', 'confirmed_by', jsonb_build_array('Ana Rivera', 'Sofia Klein')),
        p_participant_ids := ARRAY[v_scope],
        p_participant_roles := ARRAY['scope'],
        p_actor := 'patchwork-sme',
        p_occurred_at := '2026-06-22T12:00:00Z'
    );
END $$;

SELECT refresh_materialized_views();
