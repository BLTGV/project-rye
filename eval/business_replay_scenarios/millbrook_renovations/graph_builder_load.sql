SELECT set_config('app.current_role', 'admin', false);
SET search_path = rye, pg_catalog, public;

DO $$
DECLARE
    v_scope uuid;
    v_pipeline uuid;
    v_slack uuid;
    v_harper_email uuid;
    v_vale_email uuid;
    v_olson_email uuid;
    v_leads_sheet uuid;
    v_deposit_sheet uuid;
    v_roster uuid;
    v_millbrook uuid;
    v_harper_org uuid;
    v_vale_org uuid;
    v_olson_org uuid;
    v_garza_org uuid;
    v_northstar uuid;
    v_city uuid;
    v_dana uuid;
    v_leo uuid;
    v_clara uuid;
    v_mateo uuid;
    v_beth uuid;
    v_ian uuid;
    v_sarah uuid;
    v_chris uuid;
    v_megan uuid;
    v_tom uuid;
    v_harper_opp uuid;
    v_vale_opp uuid;
    v_olson_opp uuid;
    v_garza_opp uuid;
    v_harper_project uuid;
    v_vale_project uuid;
    v_olson_project uuid;
    v_garza_project uuid;
    v_harper_cabinet_task uuid;
    v_harper_proposal_task uuid;
    v_harper_demo_task uuid;
    v_vale_packet_task uuid;
    v_vale_city_task uuid;
    v_olson_estimate_task uuid;
    v_olson_deposit_task uuid;
    v_olson_crew_task uuid;
    v_garza_followup_task uuid;
    v_harper_contract_milestone uuid;
    v_vale_proposal_milestone uuid;
    v_olson_booked_milestone uuid;
    v_olson_crew_milestone uuid;
    v_northstar_blocker uuid;
    v_city_blocker uuid;
    v_deposit_blocker uuid;
    v_candidate uuid;
BEGIN
    v_scope := create_onboarding_scope(
        p_scope_key := 'millbrook-renovations-rye-dashboard',
        p_label := 'Millbrook Renovations Rye CRM/PM Dashboard',
        p_purpose := 'Use Rye as Millbrook Home Renovations first CRM and project dashboard after SME-confirmed migration from Slack, email, and spreadsheets.',
        p_boundary := jsonb_build_object(
            'business', 'Millbrook Home Renovations',
            'no_existing_crm_or_pm', true,
            'candidate_sources', jsonb_build_array('Slack #jobs', 'Email', 'Leads & Job Board spreadsheet', 'Deposit Tracker spreadsheet', 'Role roster'),
            'review_gate', 'Dana Mills or Leo Tran confirms imported records before they become official Rye records'
        ),
        p_owner := 'Dana Mills',
        p_created_by := 'millbrook-clean-graph-builder',
        p_properties := jsonb_build_object('scenario', 'millbrook_renovations')
    );

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES (
        'pipeline',
        'Millbrook residential opportunities',
        jsonb_build_object('code', 'MILLBROOK-RESIDENTIAL', 'default_stage', 'qualification', 'scenario', 'millbrook_renovations'),
        jsonb_build_object('classification', 'internal'),
        'MILLBROOK-RESIDENTIAL',
        'millbrook_rye'
    )
    RETURNING id INTO v_pipeline;

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES
        ('source_item', 'Slack #jobs export, June 17-22', jsonb_build_object('source_type', 'slack_export', 'scenario', 'millbrook_renovations'), '{}'::jsonb, 'millbrook-slack-jobs-2026-06-17-22', 'millbrook_source_packet'),
        ('source_item', 'Harper Lane kitchen email thread', jsonb_build_object('source_type', 'email_thread', 'scenario', 'millbrook_renovations'), '{}'::jsonb, 'millbrook-email-harper-2026-06-17', 'millbrook_source_packet'),
        ('source_item', 'Vale ADU feasibility email thread', jsonb_build_object('source_type', 'email_thread', 'scenario', 'millbrook_renovations'), '{}'::jsonb, 'millbrook-email-vale-2026-06-19', 'millbrook_source_packet'),
        ('source_item', 'Olson bathroom leak email thread', jsonb_build_object('source_type', 'email_thread', 'scenario', 'millbrook_renovations'), '{}'::jsonb, 'millbrook-email-olson-2026-06-20', 'millbrook_source_packet'),
        ('source_item', 'Leads and Job Board spreadsheet export, June 22', jsonb_build_object('source_type', 'spreadsheet_export', 'scenario', 'millbrook_renovations'), '{}'::jsonb, 'millbrook-leads-job-board-2026-06-22', 'millbrook_source_packet'),
        ('source_item', 'Deposit Tracker spreadsheet export, June 22', jsonb_build_object('source_type', 'spreadsheet_export', 'scenario', 'millbrook_renovations'), '{}'::jsonb, 'millbrook-deposit-tracker-2026-06-22', 'millbrook_source_packet'),
        ('source_item', 'Millbrook role roster', jsonb_build_object('source_type', 'spreadsheet_export', 'scenario', 'millbrook_renovations'), '{}'::jsonb, 'millbrook-role-roster-2026-06-22', 'millbrook_source_packet');

    SELECT id INTO v_slack FROM nodes WHERE external_id = 'millbrook-slack-jobs-2026-06-17-22';
    SELECT id INTO v_harper_email FROM nodes WHERE external_id = 'millbrook-email-harper-2026-06-17';
    SELECT id INTO v_vale_email FROM nodes WHERE external_id = 'millbrook-email-vale-2026-06-19';
    SELECT id INTO v_olson_email FROM nodes WHERE external_id = 'millbrook-email-olson-2026-06-20';
    SELECT id INTO v_leads_sheet FROM nodes WHERE external_id = 'millbrook-leads-job-board-2026-06-22';
    SELECT id INTO v_deposit_sheet FROM nodes WHERE external_id = 'millbrook-deposit-tracker-2026-06-22';
    SELECT id INTO v_roster FROM nodes WHERE external_id = 'millbrook-role-roster-2026-06-22';

    INSERT INTO artifacts (artifact_type, source_node_id, content, location, attrs)
    VALUES (
        'source_packet',
        v_slack,
        jsonb_build_object('summary', 'Millbrook source packet includes Slack, email, Leads and Job Board, Deposit Tracker, and role roster. These are evidence for candidate records, not official status until Dana or Leo confirms them.'),
        jsonb_build_object('path', 'eval/business_replay_scenarios/millbrook_renovations/source_material.md'),
        jsonb_build_object('scenario', 'millbrook_renovations')
    );

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES
        ('org', 'Millbrook Home Renovations', jsonb_build_object('scenario', 'millbrook_renovations', 'org_type', 'internal'), '{}'::jsonb, 'millbrook-home-renovations', 'millbrook'),
        ('org', 'Harper Lane household', jsonb_build_object('scenario', 'millbrook_renovations', 'org_type', 'customer'), '{}'::jsonb, 'harper-lane-household', 'millbrook'),
        ('org', 'Vale household', jsonb_build_object('scenario', 'millbrook_renovations', 'org_type', 'customer'), '{}'::jsonb, 'vale-household', 'millbrook'),
        ('org', 'Olson household', jsonb_build_object('scenario', 'millbrook_renovations', 'org_type', 'customer'), '{}'::jsonb, 'olson-household', 'millbrook'),
        ('org', 'Garza household', jsonb_build_object('scenario', 'millbrook_renovations', 'org_type', 'customer'), '{}'::jsonb, 'garza-household', 'millbrook'),
        ('org', 'Northstar Cabinets', jsonb_build_object('scenario', 'millbrook_renovations', 'org_type', 'vendor'), '{}'::jsonb, 'northstar-cabinets', 'millbrook'),
        ('org', 'City of Millbrook Permit Office', jsonb_build_object('scenario', 'millbrook_renovations', 'org_type', 'agency'), '{}'::jsonb, 'city-of-millbrook-permit-office', 'millbrook');

    SELECT id INTO v_millbrook FROM nodes WHERE external_id = 'millbrook-home-renovations';
    SELECT id INTO v_harper_org FROM nodes WHERE external_id = 'harper-lane-household';
    SELECT id INTO v_vale_org FROM nodes WHERE external_id = 'vale-household';
    SELECT id INTO v_olson_org FROM nodes WHERE external_id = 'olson-household';
    SELECT id INTO v_garza_org FROM nodes WHERE external_id = 'garza-household';
    SELECT id INTO v_northstar FROM nodes WHERE external_id = 'northstar-cabinets';
    SELECT id INTO v_city FROM nodes WHERE external_id = 'city-of-millbrook-permit-office';

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES
        ('person', 'Dana Mills', jsonb_build_object('scenario', 'millbrook_renovations', 'role', 'Owner and sales lead for complex feasibility jobs'), '{}'::jsonb, 'dana-mills', 'millbrook'),
        ('person', 'Leo Tran', jsonb_build_object('scenario', 'millbrook_renovations', 'role', 'Estimator and residential sales lead'), '{}'::jsonb, 'leo-tran', 'millbrook'),
        ('person', 'Clara Holt', jsonb_build_object('scenario', 'millbrook_renovations', 'role', 'Designer and permit/zoning packet preparer'), '{}'::jsonb, 'clara-holt', 'millbrook'),
        ('person', 'Mateo Ruiz', jsonb_build_object('scenario', 'millbrook_renovations', 'role', 'Operations lead and site estimator'), '{}'::jsonb, 'mateo-ruiz', 'millbrook'),
        ('person', 'Beth Chen', jsonb_build_object('scenario', 'millbrook_renovations', 'role', 'Finance and deposits'), '{}'::jsonb, 'beth-chen', 'millbrook'),
        ('person', 'Ian Brooks', jsonb_build_object('scenario', 'millbrook_renovations', 'role', 'Lead carpenter'), '{}'::jsonb, 'ian-brooks', 'millbrook'),
        ('person', 'Sarah Nguyen', jsonb_build_object('scenario', 'millbrook_renovations', 'role', 'Harper Lane customer contact'), '{}'::jsonb, 'sarah-nguyen', 'millbrook'),
        ('person', 'Chris Vale', jsonb_build_object('scenario', 'millbrook_renovations', 'role', 'Vale household customer contact'), '{}'::jsonb, 'chris-vale', 'millbrook'),
        ('person', 'Megan Olson', jsonb_build_object('scenario', 'millbrook_renovations', 'role', 'Olson household customer contact'), '{}'::jsonb, 'megan-olson', 'millbrook'),
        ('person', 'Tom Garza', jsonb_build_object('scenario', 'millbrook_renovations', 'role', 'Garza household customer contact'), '{}'::jsonb, 'tom-garza', 'millbrook');

    SELECT id INTO v_dana FROM nodes WHERE external_id = 'dana-mills';
    SELECT id INTO v_leo FROM nodes WHERE external_id = 'leo-tran';
    SELECT id INTO v_clara FROM nodes WHERE external_id = 'clara-holt';
    SELECT id INTO v_mateo FROM nodes WHERE external_id = 'mateo-ruiz';
    SELECT id INTO v_beth FROM nodes WHERE external_id = 'beth-chen';
    SELECT id INTO v_ian FROM nodes WHERE external_id = 'ian-brooks';
    SELECT id INTO v_sarah FROM nodes WHERE external_id = 'sarah-nguyen';
    SELECT id INTO v_chris FROM nodes WHERE external_id = 'chris-vale';
    SELECT id INTO v_megan FROM nodes WHERE external_id = 'megan-olson';
    SELECT id INTO v_tom FROM nodes WHERE external_id = 'tom-garza';

    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES
        ('works_at', v_dana, v_millbrook, jsonb_build_object('role', 'Owner and sales lead for complex feasibility jobs')),
        ('works_at', v_leo, v_millbrook, jsonb_build_object('role', 'Estimator and residential sales lead')),
        ('works_at', v_clara, v_millbrook, jsonb_build_object('role', 'Designer and permit/zoning packet preparer')),
        ('works_at', v_mateo, v_millbrook, jsonb_build_object('role', 'Operations lead and site estimator')),
        ('works_at', v_beth, v_millbrook, jsonb_build_object('role', 'Finance and deposits')),
        ('works_at', v_ian, v_millbrook, jsonb_build_object('role', 'Lead carpenter')),
        ('customer_contact_for', v_sarah, v_harper_org, jsonb_build_object('role', 'homeowner')),
        ('customer_contact_for', v_chris, v_vale_org, jsonb_build_object('role', 'homeowner')),
        ('customer_contact_for', v_megan, v_olson_org, jsonb_build_object('role', 'homeowner')),
        ('customer_contact_for', v_tom, v_garza_org, jsonb_build_object('role', 'homeowner'));

    v_harper_opp := create_opportunity('Harper Lane kitchen remodel', 'MILLBROOK-RESIDENTIAL', v_leo, jsonb_build_object('scenario', 'millbrook_renovations', 'estimated_value', '44800'), ARRAY['millbrook']);
    PERFORM advance_deal_stage(v_harper_opp, 'proposal_sent', 'SME-confirmed from Slack, Harper email, and stale lead-sheet correction.', 'millbrook-clean-graph-builder');
    v_vale_opp := create_opportunity('Vale backyard ADU feasibility', 'MILLBROOK-RESIDENTIAL', v_dana, jsonb_build_object('scenario', 'millbrook_renovations', 'estimated_value', '96000'), ARRAY['millbrook']);
    v_olson_opp := create_opportunity('Olson bathroom leak repair', 'MILLBROOK-RESIDENTIAL', v_mateo, jsonb_build_object('scenario', 'millbrook_renovations', 'estimated_value', '8400'), ARRAY['millbrook']);
    PERFORM advance_deal_stage(v_olson_opp, 'site_survey_completed', 'SME-confirmed site visit is complete and estimate is due.', 'millbrook-clean-graph-builder');
    v_garza_opp := create_opportunity('Garza deck replacement follow-up', 'MILLBROOK-RESIDENTIAL', v_leo, jsonb_build_object('scenario', 'millbrook_renovations', 'estimated_value', '18000'), ARRAY['millbrook']);
    PERFORM advance_deal_stage(v_garza_opp, 'paused_nurture', 'Corrected from stale closed-lost spreadsheet row.', 'millbrook-clean-graph-builder');

    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES
        ('primary_contact', v_harper_opp, v_sarah, jsonb_build_object('role', 'customer_contact')),
        ('customer_account', v_harper_opp, v_harper_org, jsonb_build_object('relationship', 'prospective_customer')),
        ('primary_contact', v_vale_opp, v_chris, jsonb_build_object('role', 'customer_contact')),
        ('customer_account', v_vale_opp, v_vale_org, jsonb_build_object('relationship', 'prospective_customer')),
        ('agency_review', v_vale_opp, v_city, jsonb_build_object('reason', 'City feasibility answer gates proposal')),
        ('primary_contact', v_olson_opp, v_megan, jsonb_build_object('role', 'customer_contact')),
        ('customer_account', v_olson_opp, v_olson_org, jsonb_build_object('relationship', 'prospective_customer')),
        ('primary_contact', v_garza_opp, v_tom, jsonb_build_object('role', 'customer_contact')),
        ('customer_account', v_garza_opp, v_garza_org, jsonb_build_object('relationship', 'prospective_customer'));

    PERFORM record_assertion('deal_value', jsonb_build_object('amount', 44800, 'currency', 'USD', 'source', 'Dana correction after Northstar maple cabinet allowance'), v_harper_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, 1.0, 'accepted', 'assumed', NULL, NULL, jsonb_build_object('source', 'rye-crm'));
    PERFORM record_assertion('win_probability', jsonb_build_object('probability', 0.65, 'source', 'Dana correction after cabinet change'), v_harper_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, 1.0, 'accepted', 'assumed', NULL, NULL, jsonb_build_object('source', 'rye-crm'));
    PERFORM record_assertion('next_sales_action', jsonb_build_object('next_action', 'Send revised Northstar maple cabinet allowance by 2026-06-24'), v_harper_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, 1.0, 'accepted', 'assumed', NULL, NULL, jsonb_build_object('source', 'rye-crm'));
    PERFORM record_assertion('deal_value', jsonb_build_object('amount', 96000, 'currency', 'USD', 'source', 'Leads and Job Board row'), v_vale_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, 1.0, 'accepted', 'assumed', NULL, NULL, jsonb_build_object('source', 'rye-crm'));
    PERFORM record_assertion('win_probability', jsonb_build_object('probability', 0.35, 'source', 'Leads and Job Board row'), v_vale_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, 1.0, 'accepted', 'assumed', NULL, NULL, jsonb_build_object('source', 'rye-crm'));
    PERFORM record_assertion('next_sales_action', jsonb_build_object('next_action', 'Send zoning feasibility questions to City of Millbrook by 2026-06-26'), v_vale_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, 1.0, 'accepted', 'assumed', NULL, NULL, jsonb_build_object('source', 'rye-crm'));
    PERFORM record_assertion('deal_value', jsonb_build_object('amount', 8400, 'currency', 'USD', 'source', 'Olson email and spreadsheet'), v_olson_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, 1.0, 'accepted', 'assumed', NULL, NULL, jsonb_build_object('source', 'rye-crm'));
    PERFORM record_assertion('win_probability', jsonb_build_object('probability', 0.75, 'source', 'Leads and Job Board row'), v_olson_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, 1.0, 'accepted', 'assumed', NULL, NULL, jsonb_build_object('source', 'rye-crm'));
    PERFORM record_assertion('next_sales_action', jsonb_build_object('next_action', 'Send insurance-ready estimate by 2026-06-23'), v_olson_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, 1.0, 'accepted', 'assumed', NULL, NULL, jsonb_build_object('source', 'rye-crm'));
    PERFORM record_assertion('deal_value', jsonb_build_object('amount', 18000, 'currency', 'USD', 'source', 'Stale lead sheet value retained but status corrected'), v_garza_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, 1.0, 'accepted', 'assumed', NULL, NULL, jsonb_build_object('source', 'rye-crm'));
    PERFORM record_assertion('next_sales_action', jsonb_build_object('next_action', 'Follow up with Tom Garza on 2026-07-15 about August timing'), v_garza_opp, NULL, 'default', '2026-06-22T12:00:00Z', NULL, 1.0, 'accepted', 'assumed', NULL, NULL, jsonb_build_object('source', 'rye-crm'));

    PERFORM schedule_deal_stage_change(v_harper_opp, 'contract_review', '2026-06-27T09:00:00-04:00', 'Only if Sarah approves the revised Northstar maple cabinet allowance.', 'millbrook-clean-graph-builder', jsonb_build_object('condition', 'Sarah approves revised cabinet allowance'));
    PERFORM schedule_deal_stage_change(v_vale_opp, 'proposal_sent', '2026-07-05T09:00:00-04:00', 'Only if City confirms detached ADU under 650 sqft is feasible.', 'millbrook-clean-graph-builder', jsonb_build_object('condition', 'City confirms detached ADU feasibility'));
    PERFORM schedule_deal_stage_change(v_olson_opp, 'closed_won', '2026-06-25T09:00:00-04:00', 'Only if Megan approves estimate and Beth receives deposit.', 'millbrook-clean-graph-builder', jsonb_build_object('condition', 'Estimate approved and deposit received'));
    PERFORM schedule_deal_stage_change(v_garza_opp, 'qualification', '2026-07-15T09:00:00-04:00', 'Only if Tom confirms August timing.', 'millbrook-clean-graph-builder', jsonb_build_object('condition', 'Tom confirms August timing'));

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES
        ('project', 'Harper Lane kitchen pre-construction', jsonb_build_object('code', 'MILLBROOK-PRJ-HARPER', 'scenario', 'millbrook_renovations', 'customer', 'Harper Lane household'), jsonb_build_object('teams', jsonb_build_array('millbrook'), 'classification', 'internal'), 'MILLBROOK-PRJ-HARPER', 'millbrook_rye'),
        ('project', 'Vale ADU feasibility', jsonb_build_object('code', 'MILLBROOK-PRJ-VALE', 'scenario', 'millbrook_renovations', 'customer', 'Vale household'), jsonb_build_object('teams', jsonb_build_array('millbrook'), 'classification', 'internal'), 'MILLBROOK-PRJ-VALE', 'millbrook_rye'),
        ('project', 'Olson bathroom leak repair', jsonb_build_object('code', 'MILLBROOK-PRJ-OLSON', 'scenario', 'millbrook_renovations', 'customer', 'Olson household'), jsonb_build_object('teams', jsonb_build_array('millbrook'), 'classification', 'internal'), 'MILLBROOK-PRJ-OLSON', 'millbrook_rye'),
        ('project', 'Garza deck nurture', jsonb_build_object('code', 'MILLBROOK-PRJ-GARZA', 'scenario', 'millbrook_renovations', 'customer', 'Garza household'), jsonb_build_object('teams', jsonb_build_array('millbrook'), 'classification', 'internal'), 'MILLBROOK-PRJ-GARZA', 'millbrook_rye');

    SELECT id INTO v_harper_project FROM nodes WHERE external_id = 'MILLBROOK-PRJ-HARPER';
    SELECT id INTO v_vale_project FROM nodes WHERE external_id = 'MILLBROOK-PRJ-VALE';
    SELECT id INTO v_olson_project FROM nodes WHERE external_id = 'MILLBROOK-PRJ-OLSON';
    SELECT id INTO v_garza_project FROM nodes WHERE external_id = 'MILLBROOK-PRJ-GARZA';

    v_harper_cabinet_task := create_task('Harper cabinet allowance revision', 'Revise the Northstar maple cabinet allowance after receiving Northstar written quote.', v_harper_project, v_clara, jsonb_build_object('scenario', 'millbrook_renovations', 'task_type', 'design_pricing', 'due_date', '2026-06-24', 'priority', 'high'), ARRAY['millbrook'], ARRAY[v_harper_opp], ARRAY['related_opportunity']);
    PERFORM advance_task_status(v_harper_cabinet_task, 'in_progress', 'Waiting on Northstar written quote.', 'millbrook-clean-graph-builder');
    v_harper_proposal_task := create_task('Send Harper clean proposal page', 'Send Sarah a clean proposal page after Clara receives the written quote and revises allowance.', v_harper_project, v_leo, jsonb_build_object('scenario', 'millbrook_renovations', 'task_type', 'customer_follow_up', 'due_date', '2026-06-24', 'priority', 'high'), ARRAY['millbrook'], ARRAY[v_harper_opp], ARRAY['related_opportunity']);
    PERFORM advance_task_status(v_harper_proposal_task, 'todo', 'Needs Clara revision first.', 'millbrook-clean-graph-builder');
    INSERT INTO edges (edge_type, source_id, target_id, properties) VALUES ('depends_on', v_harper_proposal_task, v_harper_cabinet_task, jsonb_build_object('dependency_type', 'finish_to_start', 'reason', 'Clean proposal waits on revised cabinet allowance.'));
    v_harper_demo_task := create_task('Harper demolition phasing plan', 'Draft demolition phasing plan before signing if revised proposal is approved.', v_harper_project, v_mateo, jsonb_build_object('scenario', 'millbrook_renovations', 'task_type', 'operations_plan', 'due_date', '2026-06-26', 'priority', 'medium'), ARRAY['millbrook'], ARRAY[v_harper_opp], ARRAY['related_opportunity']);
    PERFORM advance_task_status(v_harper_demo_task, 'conditional_todo', 'Only needed if Sarah approves revised proposal.', 'millbrook-clean-graph-builder');

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES ('dependency', 'Northstar written quote needed', jsonb_build_object('scenario', 'millbrook_renovations', 'reason', 'Northstar written quote is needed before Harper cabinet allowance can be finalized.'), '{}'::jsonb, 'MILLBROOK-DEP-NORTHSTAR-QUOTE', 'millbrook_rye')
    RETURNING id INTO v_northstar_blocker;
    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES
        ('blocks', v_northstar_blocker, v_harper_cabinet_task, jsonb_build_object('reason', 'Northstar written quote is needed before final cabinet allowance.')),
        ('vendor_for', v_northstar, v_harper_cabinet_task, jsonb_build_object('role', 'cabinet quote vendor'));

    v_vale_packet_task := create_task('Vale zoning feasibility packet', 'Prepare zoning questions so the City can answer whether the detached ADU is feasible.', v_vale_project, v_clara, jsonb_build_object('scenario', 'millbrook_renovations', 'task_type', 'zoning_packet', 'due_date', '2026-06-26', 'priority', 'high'), ARRAY['millbrook'], ARRAY[v_vale_opp], ARRAY['related_opportunity']);
    PERFORM advance_task_status(v_vale_packet_task, 'todo', 'City answer is needed before proposal.', 'millbrook-clean-graph-builder');
    v_vale_city_task := create_task('Get Vale City feasibility answer', 'Wait for City answer about detached ADU under 650 sqft before quoting.', v_vale_project, v_dana, jsonb_build_object('scenario', 'millbrook_renovations', 'task_type', 'external_answer', 'priority', 'high'), ARRAY['millbrook'], ARRAY[v_vale_opp], ARRAY['related_opportunity']);
    PERFORM advance_task_status(v_vale_city_task, 'waiting_external', 'Waiting on City of Millbrook feasibility answer.', 'millbrook-clean-graph-builder');
    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES ('dependency', 'City feasibility answer needed for Vale ADU', jsonb_build_object('scenario', 'millbrook_renovations', 'reason', 'Millbrook should not quote Vale ADU until the City confirms detached unit feasibility.'), '{}'::jsonb, 'MILLBROOK-DEP-CITY-FEASIBILITY', 'millbrook_rye')
    RETURNING id INTO v_city_blocker;
    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES
        ('depends_on', v_vale_city_task, v_vale_packet_task, jsonb_build_object('dependency_type', 'information_request', 'reason', 'City answer needs zoning questions first.')),
        ('blocks', v_city_blocker, v_vale_city_task, jsonb_build_object('reason', 'City answer is still pending.')),
        ('reviewed_by', v_vale_city_task, v_city, jsonb_build_object('role', 'external agency'));

    v_olson_estimate_task := create_task('Olson insurance-ready estimate', 'Send Megan Olson an insurance-ready estimate for adjuster review.', v_olson_project, v_mateo, jsonb_build_object('scenario', 'millbrook_renovations', 'task_type', 'estimate', 'due_date', '2026-06-23', 'priority', 'high'), ARRAY['millbrook'], ARRAY[v_olson_opp], ARRAY['related_opportunity']);
    PERFORM advance_task_status(v_olson_estimate_task, 'todo', 'Estimate due June 23.', 'millbrook-clean-graph-builder');
    v_olson_deposit_task := create_task('Confirm Olson deposit', 'Confirm Megan approval and deposit before booking or locking the crew window.', v_olson_project, v_beth, jsonb_build_object('scenario', 'millbrook_renovations', 'task_type', 'deposit_confirmation', 'due_date', '2026-06-25', 'priority', 'high'), ARRAY['millbrook'], ARRAY[v_olson_opp], ARRAY['related_opportunity']);
    PERFORM advance_task_status(v_olson_deposit_task, 'blocked', 'Blocked until customer approval and payment.', 'millbrook-clean-graph-builder');
    v_olson_crew_task := create_task('Olson July 8 crew hold', 'Tentatively hold July 8 crew window without schedule locking until estimate approval and deposit receipt.', v_olson_project, v_beth, jsonb_build_object('scenario', 'millbrook_renovations', 'task_type', 'crew_scheduling', 'due_date', '2026-06-25', 'priority', 'medium'), ARRAY['millbrook'], ARRAY[v_olson_opp], ARRAY['related_opportunity']);
    PERFORM advance_task_status(v_olson_crew_task, 'tentative', 'Do not schedule lock until Megan approves and deposit lands.', 'millbrook-clean-graph-builder');
    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES ('dependency', 'Olson approval and deposit needed', jsonb_build_object('scenario', 'millbrook_renovations', 'reason', 'Estimate approval and deposit receipt are required before booking and schedule lock.'), '{}'::jsonb, 'MILLBROOK-DEP-OLSON-DEPOSIT', 'millbrook_rye')
    RETURNING id INTO v_deposit_blocker;
    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES
        ('depends_on', v_olson_deposit_task, v_olson_estimate_task, jsonb_build_object('dependency_type', 'customer_approval', 'reason', 'Deposit confirmation waits on estimate approval.')),
        ('depends_on', v_olson_crew_task, v_olson_deposit_task, jsonb_build_object('dependency_type', 'payment_gate', 'reason', 'Crew window cannot be locked without deposit.')),
        ('blocks', v_deposit_blocker, v_olson_deposit_task, jsonb_build_object('reason', 'Megan approval and deposit are still pending.')),
        ('blocks', v_deposit_blocker, v_olson_crew_task, jsonb_build_object('reason', 'Crew hold is tentative until deposit lands.'));

    v_garza_followup_task := create_task('Garza July follow-up', 'Ask Tom Garza whether August timing for deck replacement is real.', v_garza_project, v_leo, jsonb_build_object('scenario', 'millbrook_renovations', 'task_type', 'customer_follow_up', 'due_date', '2026-07-15', 'priority', 'medium'), ARRAY['millbrook'], ARRAY[v_garza_opp], ARRAY['related_opportunity']);
    PERFORM advance_task_status(v_garza_followup_task, 'todo', 'Paused/nurture until July 15 follow-up.', 'millbrook-clean-graph-builder');

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES
        ('milestone', 'Harper signed proposal and deposit', jsonb_build_object('code', 'MILLBROOK-MIL-HARPER-CONTRACT', 'name', 'Harper signed proposal and deposit', 'target_date', '2026-06-27', 'priority', 'high', 'scenario', 'millbrook_renovations'), jsonb_build_object('teams', jsonb_build_array('millbrook'), 'classification', 'internal'), 'MILLBROOK-MIL-HARPER-CONTRACT', 'millbrook_rye'),
        ('milestone', 'Vale zoning feasibility decision', jsonb_build_object('code', 'MILLBROOK-MIL-VALE-FEASIBILITY', 'name', 'Vale zoning feasibility decision', 'target_date', '2026-07-05', 'priority', 'high', 'scenario', 'millbrook_renovations'), jsonb_build_object('teams', jsonb_build_array('millbrook'), 'classification', 'internal'), 'MILLBROOK-MIL-VALE-FEASIBILITY', 'millbrook_rye'),
        ('milestone', 'Olson deposit and schedule lock', jsonb_build_object('code', 'MILLBROOK-MIL-OLSON-BOOKED', 'name', 'Olson deposit and schedule lock', 'target_date', '2026-06-25', 'priority', 'high', 'scenario', 'millbrook_renovations'), jsonb_build_object('teams', jsonb_build_array('millbrook'), 'classification', 'internal'), 'MILLBROOK-MIL-OLSON-BOOKED', 'millbrook_rye'),
        ('milestone', 'Olson July 8 crew window', jsonb_build_object('code', 'MILLBROOK-MIL-OLSON-CREW', 'name', 'Olson July 8 crew window', 'target_date', '2026-07-08', 'priority', 'medium', 'scenario', 'millbrook_renovations'), jsonb_build_object('teams', jsonb_build_array('millbrook'), 'classification', 'internal'), 'MILLBROOK-MIL-OLSON-CREW', 'millbrook_rye');

    SELECT id INTO v_harper_contract_milestone FROM nodes WHERE external_id = 'MILLBROOK-MIL-HARPER-CONTRACT';
    SELECT id INTO v_vale_proposal_milestone FROM nodes WHERE external_id = 'MILLBROOK-MIL-VALE-FEASIBILITY';
    SELECT id INTO v_olson_booked_milestone FROM nodes WHERE external_id = 'MILLBROOK-MIL-OLSON-BOOKED';
    SELECT id INTO v_olson_crew_milestone FROM nodes WHERE external_id = 'MILLBROOK-MIL-OLSON-CREW';

    PERFORM record_assertion('milestone_status', jsonb_build_object('status', 'waiting_customer', 'reason', 'Waiting on Sarah approval of revised cabinet allowance and deposit.'), v_harper_contract_milestone, NULL, 'default', '2026-06-22T12:00:00Z', NULL, 1.0, 'accepted', 'assumed', NULL, NULL, jsonb_build_object('source', 'rye-project-management'));
    PERFORM record_assertion('milestone_status', jsonb_build_object('status', 'waiting_city', 'reason', 'Waiting on City feasibility answer before proposal.'), v_vale_proposal_milestone, NULL, 'default', '2026-06-22T12:00:00Z', NULL, 1.0, 'accepted', 'assumed', NULL, NULL, jsonb_build_object('source', 'rye-project-management'));
    PERFORM record_assertion('milestone_status', jsonb_build_object('status', 'waiting_customer_deposit', 'reason', 'Waiting on Megan approval and deposit.'), v_olson_booked_milestone, NULL, 'default', '2026-06-22T12:00:00Z', NULL, 1.0, 'accepted', 'assumed', NULL, NULL, jsonb_build_object('source', 'rye-project-management'));
    PERFORM record_assertion('milestone_status', jsonb_build_object('status', 'tentative', 'reason', 'Crew window is tentative until deposit lands.'), v_olson_crew_milestone, NULL, 'default', '2026-06-22T12:00:00Z', NULL, 1.0, 'accepted', 'assumed', NULL, NULL, jsonb_build_object('source', 'rye-project-management'));

    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES
        ('contains', v_harper_project, v_harper_contract_milestone, jsonb_build_object('kind', 'milestone')),
        ('contains', v_vale_project, v_vale_proposal_milestone, jsonb_build_object('kind', 'milestone')),
        ('contains', v_olson_project, v_olson_booked_milestone, jsonb_build_object('kind', 'milestone')),
        ('contains', v_olson_project, v_olson_crew_milestone, jsonb_build_object('kind', 'milestone')),
        ('assigned_to', v_harper_contract_milestone, v_leo, jsonb_build_object('role', 'owner')),
        ('assigned_to', v_vale_proposal_milestone, v_dana, jsonb_build_object('role', 'owner')),
        ('assigned_to', v_olson_booked_milestone, v_beth, jsonb_build_object('role', 'owner')),
        ('assigned_to', v_olson_crew_milestone, v_beth, jsonb_build_object('role', 'owner')),
        ('depends_on', v_harper_contract_milestone, v_harper_cabinet_task, jsonb_build_object('reason', 'Contract review waits on revised cabinet allowance.')),
        ('depends_on', v_vale_proposal_milestone, v_vale_city_task, jsonb_build_object('reason', 'Proposal waits on City feasibility answer.')),
        ('depends_on', v_olson_booked_milestone, v_olson_deposit_task, jsonb_build_object('reason', 'Booked conversion waits on approval and deposit.')),
        ('depends_on', v_olson_crew_milestone, v_olson_deposit_task, jsonb_build_object('reason', 'Crew window lock waits on deposit.'));

    PERFORM schedule_milestone_status_change(v_harper_contract_milestone, 'approved', '2026-06-27T17:00:00-04:00', 'Only if Sarah approves revised cabinet allowance and deposit is received.', 'millbrook-clean-graph-builder', jsonb_build_object('condition', 'Sarah approval and deposit'));
    PERFORM schedule_milestone_status_change(v_vale_proposal_milestone, 'proposal_ready', '2026-07-05T17:00:00-04:00', 'Only if City confirms detached ADU feasibility.', 'millbrook-clean-graph-builder', jsonb_build_object('condition', 'City confirms detached ADU feasibility'));
    PERFORM schedule_milestone_status_change(v_olson_booked_milestone, 'approved', '2026-06-25T17:00:00-04:00', 'Only if Megan approves estimate and Beth receives deposit.', 'millbrook-clean-graph-builder', jsonb_build_object('condition', 'Estimate approved and deposit received'));

    FOREACH v_candidate IN ARRAY ARRAY[
        create_knowledge_candidate('policy_change', 'Imported Slack, email, Leads and Job Board, Deposit Tracker, and role roster records are candidates until Dana Mills or Leo Tran confirms them.', jsonb_build_object('scenario', 'millbrook_renovations'), ARRAY[v_scope], 'millbrook-source-evidence-not-truth', 'millbrook-clean-intake', ARRAY[v_slack, v_leads_sheet, v_deposit_sheet, v_roster], '{}', 0.98),
        create_knowledge_candidate('policy_change', 'Starting July 8, Rye should be checked first for opportunity status, next customer action, task status, and milestone status if the pilot works.', jsonb_build_object('scenario', 'millbrook_renovations'), ARRAY[v_scope], 'millbrook-rye-first-july-8', 'millbrook-clean-intake', ARRAY[v_slack], '{}', 0.94),
        create_knowledge_candidate('decision', 'Harper Lane kitchen remodel is Leo-owned, proposal sent, value $44,800, probability 65%, with revised Northstar maple allowance due June 24.', jsonb_build_object('record_type', 'opportunity', 'opportunity_id', v_harper_opp), ARRAY[v_scope], 'millbrook-harper-opportunity', 'millbrook-clean-intake', ARRAY[v_slack, v_harper_email, v_leads_sheet], '{}', 0.95),
        create_knowledge_candidate('decision', 'Vale backyard ADU feasibility is Dana-owned, qualification stage, value $96,000, probability 35%, and waits on City feasibility answer.', jsonb_build_object('record_type', 'opportunity', 'opportunity_id', v_vale_opp), ARRAY[v_scope], 'millbrook-vale-opportunity', 'millbrook-clean-intake', ARRAY[v_slack, v_vale_email, v_leads_sheet], '{}', 0.94),
        create_knowledge_candidate('decision', 'Olson bathroom leak repair has site survey complete, value $8,400, probability 75%, with insurance-ready estimate due June 23.', jsonb_build_object('record_type', 'opportunity', 'opportunity_id', v_olson_opp), ARRAY[v_scope], 'millbrook-olson-opportunity', 'millbrook-clean-intake', ARRAY[v_slack, v_olson_email, v_leads_sheet], '{}', 0.94),
        create_knowledge_candidate('decision', 'Garza deck replacement is paused or nurture, not closed lost, with Leo follow-up on July 15.', jsonb_build_object('record_type', 'opportunity', 'opportunity_id', v_garza_opp), ARRAY[v_scope], 'millbrook-garza-opportunity', 'millbrook-clean-intake', ARRAY[v_slack, v_leads_sheet], '{}', 0.9)
    ] LOOP
        PERFORM set_candidate_status(v_candidate, 'accepted', 'Accepted by simulated Dana/Leo SME review.', 'millbrook-sme');
    END LOOP;

    v_candidate := create_knowledge_candidate('decision', 'Old Leads and Job Board value for Harper was $42,000 and old probability was 55%.', jsonb_build_object('record_type', 'opportunity', 'opportunity_id', v_harper_opp), ARRAY[v_scope], 'millbrook-reject-old-harper-forecast', 'millbrook-clean-intake', ARRAY[v_leads_sheet], '{}', 0.86);
    PERFORM set_candidate_status(v_candidate, 'rejected', 'SME corrected Harper value to $44,800 and probability to 65%.', 'millbrook-sme');
    v_candidate := create_knowledge_candidate('decision', 'Garza deck replacement is closed lost with 0% probability.', jsonb_build_object('record_type', 'opportunity', 'opportunity_id', v_garza_opp), ARRAY[v_scope], 'millbrook-reject-garza-closed-lost', 'millbrook-clean-intake', ARRAY[v_leads_sheet], '{}', 0.75);
    PERFORM set_candidate_status(v_candidate, 'rejected', 'Leo corrected Garza to paused/nurture with July 15 follow-up.', 'millbrook-sme');
    v_candidate := create_knowledge_candidate('decision', 'Olson July 8 crew hold is schedule locked because Deposit Tracker says Checked?.', jsonb_build_object('record_type', 'task', 'task_id', v_olson_crew_task), ARRAY[v_scope], 'millbrook-reject-olson-locked-crew-hold', 'millbrook-clean-intake', ARRAY[v_deposit_sheet], '{}', 0.72);
    PERFORM set_candidate_status(v_candidate, 'rejected', 'Beth said crew hold is tentative only until approval and deposit.', 'millbrook-sme');

    v_candidate := create_knowledge_candidate('decision', 'Harper decision: Sarah approval of the revised Northstar cabinet allowance is still pending.', jsonb_build_object('record_type', 'decision', 'opportunity_id', v_harper_opp, 'milestone_id', v_harper_contract_milestone), ARRAY[v_scope], 'millbrook-pending-harper-sarah-approval', 'millbrook-clean-intake', ARRAY[v_harper_email], '{}', 0.9);
    PERFORM set_candidate_status(v_candidate, 'needs_review', 'Needs Sarah approval before contract review and deposit can be treated as complete.', 'millbrook-sme');
    v_candidate := create_knowledge_candidate('decision', 'Project task decision: Northstar written cabinet quote is still pending for Harper cabinet allowance revision.', jsonb_build_object('record_type', 'decision', 'task_id', v_harper_cabinet_task), ARRAY[v_scope], 'millbrook-pending-northstar-quote', 'millbrook-clean-intake', ARRAY[v_slack, v_harper_email], '{}', 0.9);
    PERFORM set_candidate_status(v_candidate, 'needs_review', 'Needs vendor written quote before final allowance.', 'millbrook-sme');
    v_candidate := create_knowledge_candidate('decision', 'Vale decision: City of Millbrook feasibility answer for detached ADU under 650 sqft is still pending.', jsonb_build_object('record_type', 'decision', 'opportunity_id', v_vale_opp, 'task_id', v_vale_city_task, 'milestone_id', v_vale_proposal_milestone), ARRAY[v_scope], 'millbrook-pending-city-feasibility', 'millbrook-clean-intake', ARRAY[v_slack, v_vale_email], '{}', 0.92);
    PERFORM set_candidate_status(v_candidate, 'needs_review', 'Needs City answer before Vale can move to proposal.', 'millbrook-sme');
    v_candidate := create_knowledge_candidate('decision', 'Olson decision: Megan estimate approval and deposit are still pending before booking and schedule lock.', jsonb_build_object('record_type', 'decision', 'opportunity_id', v_olson_opp, 'task_id', v_olson_deposit_task, 'milestone_id', v_olson_booked_milestone), ARRAY[v_scope], 'millbrook-pending-olson-approval-deposit', 'millbrook-clean-intake', ARRAY[v_slack, v_olson_email, v_deposit_sheet], '{}', 0.9);
    PERFORM set_candidate_status(v_candidate, 'needs_review', 'Needs customer approval and deposit before booking.', 'millbrook-sme');
    v_candidate := create_knowledge_candidate('decision', 'Garza decision: Tom Garza still needs to confirm whether August timing is real.', jsonb_build_object('record_type', 'decision', 'opportunity_id', v_garza_opp, 'task_id', v_garza_followup_task), ARRAY[v_scope], 'millbrook-pending-garza-august-timing', 'millbrook-clean-intake', ARRAY[v_slack], '{}', 0.86);
    PERFORM set_candidate_status(v_candidate, 'needs_review', 'Needs Tom response on July 15 before reactivating qualification.', 'millbrook-sme');

    PERFORM record_source_of_truth_policy(v_scope, 'deal_stage', 'Rye CRM/PM dashboard', '2026-06-22T12:00:00Z', 'Dana Mills or Leo Tran confirms imported candidates before they become official Rye records.', ARRAY['Slack evidence', 'Email evidence', 'Leads and Job Board import', 'SME confirmation'], 'No prior CRM', 'Millbrook has no CRM; confirmed Rye opportunity records are the dashboard of record.', 'millbrook-clean-graph-builder', 'current_deal_stage');
    PERFORM record_source_of_truth_policy(v_scope, 'sales_next_action', 'Rye CRM/PM dashboard', '2026-06-22T12:00:00Z', 'Dana Mills or Leo Tran confirms imported candidates before they become official Rye records.', ARRAY['Slack evidence', 'Email evidence', 'Leads and Job Board import', 'SME confirmation'], 'No prior CRM', 'Millbrook has no CRM; confirmed Rye next actions are the dashboard of record.', 'millbrook-clean-graph-builder', 'current_sales_next_action');
    PERFORM record_source_of_truth_policy(v_scope, 'project_task_status', 'Rye CRM/PM dashboard', '2026-06-22T12:00:00Z', 'Dana Mills or Leo Tran confirms imported candidates before they become official Rye records.', ARRAY['Slack evidence', 'Email evidence', 'Job Board import', 'Deposit Tracker import', 'SME confirmation'], 'No prior PM system', 'Millbrook has no PM tool; confirmed Rye task records are the dashboard of record.', 'millbrook-clean-graph-builder', 'current_project_task_status');
    PERFORM record_source_of_truth_policy(v_scope, 'project_milestone_status', 'Rye CRM/PM dashboard', '2026-06-22T12:00:00Z', 'Dana Mills or Leo Tran confirms imported candidates before they become official Rye records.', ARRAY['Slack evidence', 'Email evidence', 'Job Board import', 'Deposit Tracker import', 'SME confirmation'], 'No prior PM system', 'Millbrook has no PM tool; confirmed Rye milestone records are the dashboard of record.', 'millbrook-clean-graph-builder', 'current_project_milestone_status');

    PERFORM record_source_of_truth_policy(v_scope, 'deal_stage', 'Rye CRM/PM dashboard', '2026-07-08T09:00:00-04:00', 'New opportunity status updates should be entered or confirmed in Rye first if the pilot works; spreadsheets are evidence/import staging only.', ARRAY['Rye dashboard update', 'SME confirmation when imported'], 'Leads and Job Board stage columns', 'July 8 operating policy: Rye is checked first for opportunity status after migration.', 'millbrook-clean-graph-builder', 'july_8_deal_stage');
    PERFORM record_source_of_truth_policy(v_scope, 'sales_next_action', 'Rye CRM/PM dashboard', '2026-07-08T09:00:00-04:00', 'New next customer actions should be entered or confirmed in Rye first if the pilot works; spreadsheets are evidence/import staging only.', ARRAY['Rye dashboard update', 'SME confirmation when imported'], 'Leads and Job Board next step columns', 'July 8 operating policy: Rye is checked first for next customer action after migration.', 'millbrook-clean-graph-builder', 'july_8_sales_next_action');
    PERFORM record_source_of_truth_policy(v_scope, 'project_task_status', 'Rye CRM/PM dashboard', '2026-07-08T09:00:00-04:00', 'New task status updates should be entered or confirmed in Rye first if the pilot works; workboard rows are evidence/import staging only.', ARRAY['Rye dashboard update', 'SME confirmation when imported'], 'Job Board workboard rows', 'July 8 operating policy: Rye is checked first for task status after migration.', 'millbrook-clean-graph-builder', 'july_8_project_task_status');
    PERFORM record_source_of_truth_policy(v_scope, 'project_milestone_status', 'Rye CRM/PM dashboard', '2026-07-08T09:00:00-04:00', 'New milestone status updates should be entered or confirmed in Rye first if the pilot works; deposit tracker rows are evidence/import staging only.', ARRAY['Rye dashboard update', 'SME confirmation when imported'], 'Deposit Tracker and workboard rows', 'July 8 operating policy: Rye is checked first for milestone status after migration.', 'millbrook-clean-graph-builder', 'july_8_project_milestone_status');

    PERFORM record_event(
        p_event_type := 'rye_dashboard_migration_confirmed',
        p_summary := 'Millbrook confirmed Rye as CRM/PM dashboard after candidate review.',
        p_properties := jsonb_build_object('scenario', 'millbrook_renovations', 'confirmed_by', jsonb_build_array('Dana Mills', 'Leo Tran')),
        p_participant_ids := ARRAY[v_scope],
        p_participant_roles := ARRAY['scope'],
        p_actor := 'millbrook-sme',
        p_occurred_at := '2026-06-22T12:00:00Z'
    );
END $$;

SELECT refresh_materialized_views();
