-- Scenario seed data: populates the graph for all 5 scenarios + recommendation tests.
-- Must run as superuser or a role with full DML on all tables.
-- All scenarios share this seed; each test file is a self-contained transaction.

SET search_path = rye, public, pg_catalog;

BEGIN;

-- ============================================================
-- Helper: set session context for RLS pass-through
-- ============================================================
SET LOCAL "app.current_user_id" = 'seed-admin';
SET LOCAL "app.current_teams"   = 'sales-east,sales-west,sales-smb,engineering,design,marketing,qa,support-t1,support-t2,support-escalation,ma-team,finance';
SET LOCAL "app.current_role"    = 'admin';

-- ============================================================
-- Field classifications (used by redact_properties)
-- ============================================================
INSERT INTO field_classifications (node_type, field_path, classification, min_role) VALUES
    ('person',      'properties.ssn',            'restricted',   'admin'),
    ('person',      'properties.phone',          'internal',     'team_member'),
    ('person',      'properties.email',          'internal',     'team_member'),
    ('person',      'properties.salary',         'restricted',   'admin'),
    ('person',      'properties.home_address',   'confidential', 'team_lead'),
    ('opportunity', 'properties.margin',         'confidential', 'deal_manager'),
    ('opportunity', 'properties.discount',       'confidential', 'deal_manager'),
    ('org',         'properties.revenue',        'confidential', 'deal_manager'),
    ('org',         'properties.nda_terms',      'restricted',   'admin'),
    ('ticket',      'properties.internal_notes', 'confidential', 'team_lead')
ON CONFLICT (node_type, field_path) DO NOTHING;


-- ============================================================
-- SCENARIO 1: Sales Pipeline with Competitive Intelligence
-- ============================================================

-- People (salespeople, managers)
INSERT INTO nodes (id, node_type, label, properties, attrs) VALUES
    -- Sales East team
    ('a0000001-0001-0001-0001-000000000001', 'person', 'Alice Chen',
     '{"first_name":"Alice","last_name":"Chen","email":"alice@co.com","phone":"555-0101","title":"Account Exec"}',
     '{"classification":"internal","teams":["sales-east"]}'),
    ('a0000001-0001-0001-0001-000000000002', 'person', 'Bob Martinez',
     '{"first_name":"Bob","last_name":"Martinez","email":"bob@co.com","phone":"555-0102","title":"Account Exec"}',
     '{"classification":"internal","teams":["sales-east"]}'),
    -- Sales West team
    ('a0000001-0001-0001-0001-000000000003', 'person', 'Carol Wu',
     '{"first_name":"Carol","last_name":"Wu","email":"carol@co.com","phone":"555-0103","title":"Account Exec"}',
     '{"classification":"internal","teams":["sales-west"]}'),
    ('a0000001-0001-0001-0001-000000000004', 'person', 'Dave Johnson',
     '{"first_name":"Dave","last_name":"Johnson","email":"dave@co.com","phone":"555-0104","title":"Account Exec"}',
     '{"classification":"internal","teams":["sales-west"]}'),
    -- Sales SMB team
    ('a0000001-0001-0001-0001-000000000005', 'person', 'Eve Santos',
     '{"first_name":"Eve","last_name":"Santos","email":"eve@co.com","phone":"555-0105","title":"Account Exec"}',
     '{"classification":"internal","teams":["sales-smb"]}'),
    ('a0000001-0001-0001-0001-000000000006', 'person', 'Frank Lee',
     '{"first_name":"Frank","last_name":"Lee","email":"frank@co.com","phone":"555-0106","title":"Account Exec"}',
     '{"classification":"internal","teams":["sales-smb"]}'),
    -- Deal managers (cross-team)
    ('a0000001-0001-0001-0001-000000000007', 'person', 'Grace Kim (DM)',
     '{"first_name":"Grace","last_name":"Kim","email":"grace@co.com","phone":"555-0107","title":"Deal Manager"}',
     '{"classification":"internal","teams":["sales-east","sales-west","sales-smb"]}'),
    ('a0000001-0001-0001-0001-000000000008', 'person', 'Henry Patel (Finance)',
     '{"first_name":"Henry","last_name":"Patel","email":"henry@co.com","phone":"555-0108","title":"Finance Manager"}',
     '{"classification":"internal","teams":["finance"]}')
;

-- Customer orgs
INSERT INTO nodes (id, node_type, label, properties, attrs) VALUES
    ('a0000001-0002-0001-0001-000000000001', 'org', 'Acme Corp',
     '{"name":"Acme Corp","industry":"Manufacturing","revenue":"50M"}',
     '{"classification":"internal","teams":["sales-east"]}'),
    ('a0000001-0002-0001-0001-000000000002', 'org', 'Beta Industries',
     '{"name":"Beta Industries","industry":"Technology","revenue":"120M"}',
     '{"classification":"internal","teams":["sales-east"]}'),
    ('a0000001-0002-0001-0001-000000000003', 'org', 'Gamma Solutions',
     '{"name":"Gamma Solutions","industry":"Consulting","revenue":"30M"}',
     '{"classification":"internal","teams":["sales-west"]}'),
    ('a0000001-0002-0001-0001-000000000004', 'org', 'Delta Health',
     '{"name":"Delta Health","industry":"Healthcare","revenue":"200M"}',
     '{"classification":"internal","teams":["sales-west"]}'),
    ('a0000001-0002-0001-0001-000000000005', 'org', 'Epsilon Retail',
     '{"name":"Epsilon Retail","industry":"Retail","revenue":"15M"}',
     '{"classification":"internal","teams":["sales-smb"]}'),
    ('a0000001-0002-0001-0001-000000000006', 'org', 'Zeta Logistics',
     '{"name":"Zeta Logistics","industry":"Logistics","revenue":"8M"}',
     '{"classification":"internal","teams":["sales-smb"]}')
;

-- Customer contacts (people at customer orgs)
INSERT INTO nodes (id, node_type, label, properties, attrs) VALUES
    ('a0000001-0003-0001-0001-000000000001', 'person', 'Iris Acme',
     '{"first_name":"Iris","last_name":"Acme","email":"iris@acme.com","phone":"555-1001","ssn":"123-45-6789","salary":"85000"}',
     '{}'),
    ('a0000001-0003-0001-0001-000000000002', 'person', 'Jake Beta',
     '{"first_name":"Jake","last_name":"Beta","email":"jake@beta.com","phone":"555-1002","ssn":"234-56-7890","salary":"92000"}',
     '{}'),
    ('a0000001-0003-0001-0001-000000000003', 'person', 'Kara Gamma',
     '{"first_name":"Kara","last_name":"Gamma","email":"kara@gamma.com","phone":"555-1003"}',
     '{}'),
    ('a0000001-0003-0001-0001-000000000004', 'person', 'Liam Delta',
     '{"first_name":"Liam","last_name":"Delta","email":"liam@delta.com","phone":"555-1004"}',
     '{}'),
    -- Shared contact: works with both East and West pipelines
    ('a0000001-0003-0001-0001-000000000005', 'person', 'Maya Cross',
     '{"first_name":"Maya","last_name":"Cross","email":"maya@consulting.com","phone":"555-1005"}',
     '{}'),
    ('a0000001-0003-0001-0001-000000000006', 'person', 'Noah Epsilon',
     '{"first_name":"Noah","last_name":"Epsilon","email":"noah@epsilon.com","phone":"555-1006"}',
     '{}')
;

-- Employs edges (org -> contact)
INSERT INTO edges (edge_type, source_id, target_id, properties, effective_from) VALUES
    ('employs', 'a0000001-0002-0001-0001-000000000001', 'a0000001-0003-0001-0001-000000000001', '{"title":"VP Sales"}', now()),
    ('employs', 'a0000001-0002-0001-0001-000000000002', 'a0000001-0003-0001-0001-000000000002', '{"title":"CTO"}', now()),
    ('employs', 'a0000001-0002-0001-0001-000000000003', 'a0000001-0003-0001-0001-000000000003', '{"title":"Director"}', now()),
    ('employs', 'a0000001-0002-0001-0001-000000000004', 'a0000001-0003-0001-0001-000000000004', '{"title":"CMO"}', now()),
    ('employs', 'a0000001-0002-0001-0001-000000000005', 'a0000001-0003-0001-0001-000000000006', '{"title":"Owner"}', now());

-- Pipelines
INSERT INTO nodes (id, node_type, label, properties, attrs) VALUES
    ('a0000001-0004-0001-0001-000000000001', 'pipeline', 'Enterprise Pipeline',
     '{"code":"ENT","default_stage":"prospecting"}',
     '{"classification":"internal","teams":["sales-east"]}'),
    ('a0000001-0004-0001-0001-000000000002', 'pipeline', 'Mid-Market Pipeline',
     '{"code":"MID","default_stage":"prospecting"}',
     '{"classification":"internal","teams":["sales-west"]}'),
    ('a0000001-0004-0001-0001-000000000003', 'pipeline', 'SMB Pipeline',
     '{"code":"SMB","default_stage":"prospecting"}',
     '{"classification":"internal","teams":["sales-smb"]}')
;

-- Opportunities (12 across 3 pipelines)
-- classification=internal ensures team-based access control via node_read_policy
INSERT INTO nodes (id, node_type, label, properties, attrs) VALUES
    -- Enterprise (sales-east): 4 opps
    ('a0000001-0005-0001-0001-000000000001', 'opportunity', 'Acme Platform Deal',
     '{"name":"Acme Platform Deal","estimated_value":"500000","margin":"0.35","discount":"0.10"}',
     '{"classification":"internal","teams":["sales-east"]}'),
    ('a0000001-0005-0001-0001-000000000002', 'opportunity', 'Beta Cloud Migration',
     '{"name":"Beta Cloud Migration","estimated_value":"1200000","margin":"0.40","discount":"0.15"}',
     '{"classification":"internal","teams":["sales-east"]}'),
    ('a0000001-0005-0001-0001-000000000003', 'opportunity', 'Acme Phase 2',
     '{"name":"Acme Phase 2","estimated_value":"300000","margin":"0.30","discount":"0.05"}',
     '{"classification":"internal","teams":["sales-east"]}'),
    ('a0000001-0005-0001-0001-000000000004', 'opportunity', 'Beta Analytics',
     '{"name":"Beta Analytics","estimated_value":"800000","margin":"0.45","discount":"0.12"}',
     '{"classification":"internal","teams":["sales-east"]}'),
    -- Mid-Market (sales-west): 4 opps
    ('a0000001-0005-0001-0001-000000000005', 'opportunity', 'Gamma Consulting Suite',
     '{"name":"Gamma Consulting Suite","estimated_value":"150000","margin":"0.25","discount":"0.08"}',
     '{"classification":"internal","teams":["sales-west"]}'),
    ('a0000001-0005-0001-0001-000000000006', 'opportunity', 'Delta Health Portal',
     '{"name":"Delta Health Portal","estimated_value":"2000000","margin":"0.50","discount":"0.20"}',
     '{"classification":"internal","teams":["sales-west"]}'),
    ('a0000001-0005-0001-0001-000000000007', 'opportunity', 'Gamma Data Platform',
     '{"name":"Gamma Data Platform","estimated_value":"200000","margin":"0.30","discount":"0.10"}',
     '{"classification":"internal","teams":["sales-west"]}'),
    ('a0000001-0005-0001-0001-000000000008', 'opportunity', 'Delta Compliance Tool',
     '{"name":"Delta Compliance Tool","estimated_value":"450000","margin":"0.35","discount":"0.05"}',
     '{"classification":"internal","teams":["sales-west"]}'),
    -- SMB (sales-smb): 4 opps
    ('a0000001-0005-0001-0001-000000000009', 'opportunity', 'Epsilon POS System',
     '{"name":"Epsilon POS System","estimated_value":"25000","margin":"0.20","discount":"0.0"}',
     '{"classification":"internal","teams":["sales-smb"]}'),
    ('a0000001-0005-0001-0001-000000000010', 'opportunity', 'Zeta Fleet Tracker',
     '{"name":"Zeta Fleet Tracker","estimated_value":"35000","margin":"0.22","discount":"0.0"}',
     '{"classification":"internal","teams":["sales-smb"]}'),
    ('a0000001-0005-0001-0001-000000000011', 'opportunity', 'Epsilon Loyalty App',
     '{"name":"Epsilon Loyalty App","estimated_value":"15000","margin":"0.18","discount":"0.0"}',
     '{"classification":"internal","teams":["sales-smb"]}'),
    ('a0000001-0005-0001-0001-000000000012', 'opportunity', 'Zeta Warehouse WMS',
     '{"name":"Zeta Warehouse WMS","estimated_value":"40000","margin":"0.25","discount":"0.0"}',
     '{"classification":"internal","teams":["sales-smb"]}')
;

-- Pipeline membership edges
INSERT INTO edges (edge_type, source_id, target_id, properties) VALUES
    ('pipeline_member', 'a0000001-0005-0001-0001-000000000001', 'a0000001-0004-0001-0001-000000000001', '{}'),
    ('pipeline_member', 'a0000001-0005-0001-0001-000000000002', 'a0000001-0004-0001-0001-000000000001', '{}'),
    ('pipeline_member', 'a0000001-0005-0001-0001-000000000003', 'a0000001-0004-0001-0001-000000000001', '{}'),
    ('pipeline_member', 'a0000001-0005-0001-0001-000000000004', 'a0000001-0004-0001-0001-000000000001', '{}'),
    ('pipeline_member', 'a0000001-0005-0001-0001-000000000005', 'a0000001-0004-0001-0001-000000000002', '{}'),
    ('pipeline_member', 'a0000001-0005-0001-0001-000000000006', 'a0000001-0004-0001-0001-000000000002', '{}'),
    ('pipeline_member', 'a0000001-0005-0001-0001-000000000007', 'a0000001-0004-0001-0001-000000000002', '{}'),
    ('pipeline_member', 'a0000001-0005-0001-0001-000000000008', 'a0000001-0004-0001-0001-000000000002', '{}'),
    ('pipeline_member', 'a0000001-0005-0001-0001-000000000009', 'a0000001-0004-0001-0001-000000000003', '{}'),
    ('pipeline_member', 'a0000001-0005-0001-0001-000000000010', 'a0000001-0004-0001-0001-000000000003', '{}'),
    ('pipeline_member', 'a0000001-0005-0001-0001-000000000011', 'a0000001-0004-0001-0001-000000000003', '{}'),
    ('pipeline_member', 'a0000001-0005-0001-0001-000000000012', 'a0000001-0004-0001-0001-000000000003', '{}');

-- Assigned-to edges (opp -> salesperson)
INSERT INTO edges (edge_type, source_id, target_id, properties, effective_from) VALUES
    ('assigned_to', 'a0000001-0005-0001-0001-000000000001', 'a0000001-0001-0001-0001-000000000001', '{"role":"owner"}', now()),
    ('assigned_to', 'a0000001-0005-0001-0001-000000000002', 'a0000001-0001-0001-0001-000000000001', '{"role":"owner"}', now()),
    ('assigned_to', 'a0000001-0005-0001-0001-000000000003', 'a0000001-0001-0001-0001-000000000002', '{"role":"owner"}', now()),
    ('assigned_to', 'a0000001-0005-0001-0001-000000000004', 'a0000001-0001-0001-0001-000000000002', '{"role":"owner"}', now()),
    ('assigned_to', 'a0000001-0005-0001-0001-000000000005', 'a0000001-0001-0001-0001-000000000003', '{"role":"owner"}', now()),
    ('assigned_to', 'a0000001-0005-0001-0001-000000000006', 'a0000001-0001-0001-0001-000000000003', '{"role":"owner"}', now()),
    ('assigned_to', 'a0000001-0005-0001-0001-000000000007', 'a0000001-0001-0001-0001-000000000004', '{"role":"owner"}', now()),
    ('assigned_to', 'a0000001-0005-0001-0001-000000000008', 'a0000001-0001-0001-0001-000000000004', '{"role":"owner"}', now()),
    ('assigned_to', 'a0000001-0005-0001-0001-000000000009', 'a0000001-0001-0001-0001-000000000005', '{"role":"owner"}', now()),
    ('assigned_to', 'a0000001-0005-0001-0001-000000000010', 'a0000001-0001-0001-0001-000000000005', '{"role":"owner"}', now()),
    ('assigned_to', 'a0000001-0005-0001-0001-000000000011', 'a0000001-0001-0001-0001-000000000006', '{"role":"owner"}', now()),
    ('assigned_to', 'a0000001-0005-0001-0001-000000000012', 'a0000001-0001-0001-0001-000000000006', '{"role":"owner"}', now());

-- Primary contact edges (opp -> customer contact)
INSERT INTO edges (edge_type, source_id, target_id, properties) VALUES
    ('primary_contact', 'a0000001-0005-0001-0001-000000000001', 'a0000001-0003-0001-0001-000000000001', '{}'),
    ('primary_contact', 'a0000001-0005-0001-0001-000000000002', 'a0000001-0003-0001-0001-000000000002', '{}'),
    ('primary_contact', 'a0000001-0005-0001-0001-000000000003', 'a0000001-0003-0001-0001-000000000001', '{}'),
    ('primary_contact', 'a0000001-0005-0001-0001-000000000004', 'a0000001-0003-0001-0001-000000000002', '{}'),
    ('primary_contact', 'a0000001-0005-0001-0001-000000000005', 'a0000001-0003-0001-0001-000000000003', '{}'),
    ('primary_contact', 'a0000001-0005-0001-0001-000000000006', 'a0000001-0003-0001-0001-000000000004', '{}'),
    ('primary_contact', 'a0000001-0005-0001-0001-000000000007', 'a0000001-0003-0001-0001-000000000003', '{}'),
    ('primary_contact', 'a0000001-0005-0001-0001-000000000008', 'a0000001-0003-0001-0001-000000000004', '{}'),
    -- Cross-scenario contact (Maya Cross used in both East and West)
    ('primary_contact', 'a0000001-0005-0001-0001-000000000002', 'a0000001-0003-0001-0001-000000000005', '{"role":"advisor"}'),
    ('primary_contact', 'a0000001-0005-0001-0001-000000000006', 'a0000001-0003-0001-0001-000000000005', '{"role":"advisor"}'),
    ('primary_contact', 'a0000001-0005-0001-0001-000000000009', 'a0000001-0003-0001-0001-000000000006', '{}'),
    ('primary_contact', 'a0000001-0005-0001-0001-000000000010', 'a0000001-0003-0001-0001-000000000006', '{}');

-- Deal stage assertions (varied stages for aggregate testing)
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence) VALUES
    ('deal_stage', 'default', 'a0000001-0005-0001-0001-000000000001', '{"stage":"negotiation","pipeline":"ENT"}', 1.0),
    ('deal_stage', 'default', 'a0000001-0005-0001-0001-000000000002', '{"stage":"proposal","pipeline":"ENT"}', 1.0),
    ('deal_stage', 'default', 'a0000001-0005-0001-0001-000000000003', '{"stage":"discovery","pipeline":"ENT"}', 1.0),
    ('deal_stage', 'default', 'a0000001-0005-0001-0001-000000000004', '{"stage":"negotiation","pipeline":"ENT"}', 1.0),
    ('deal_stage', 'default', 'a0000001-0005-0001-0001-000000000005', '{"stage":"proposal","pipeline":"MID"}', 1.0),
    ('deal_stage', 'default', 'a0000001-0005-0001-0001-000000000006', '{"stage":"negotiation","pipeline":"MID"}', 1.0),
    ('deal_stage', 'default', 'a0000001-0005-0001-0001-000000000007', '{"stage":"prospecting","pipeline":"MID"}', 1.0),
    ('deal_stage', 'default', 'a0000001-0005-0001-0001-000000000008', '{"stage":"discovery","pipeline":"MID"}', 1.0),
    ('deal_stage', 'default', 'a0000001-0005-0001-0001-000000000009', '{"stage":"proposal","pipeline":"SMB"}', 1.0),
    ('deal_stage', 'default', 'a0000001-0005-0001-0001-000000000010', '{"stage":"negotiation","pipeline":"SMB"}', 1.0),
    ('deal_stage', 'default', 'a0000001-0005-0001-0001-000000000011', '{"stage":"prospecting","pipeline":"SMB"}', 1.0),
    ('deal_stage', 'default', 'a0000001-0005-0001-0001-000000000012', '{"stage":"discovery","pipeline":"SMB"}', 1.0);

-- Deal value assertions
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence) VALUES
    ('deal_value', 'default', 'a0000001-0005-0001-0001-000000000001', '{"amount":"500000"}', 0.9),
    ('deal_value', 'default', 'a0000001-0005-0001-0001-000000000002', '{"amount":"1200000"}', 0.85),
    ('deal_value', 'default', 'a0000001-0005-0001-0001-000000000003', '{"amount":"300000"}', 0.7),
    ('deal_value', 'default', 'a0000001-0005-0001-0001-000000000004', '{"amount":"800000"}', 0.8),
    ('deal_value', 'default', 'a0000001-0005-0001-0001-000000000005', '{"amount":"150000"}', 0.75),
    ('deal_value', 'default', 'a0000001-0005-0001-0001-000000000006', '{"amount":"2000000"}', 0.6),
    ('deal_value', 'default', 'a0000001-0005-0001-0001-000000000007', '{"amount":"200000"}', 0.5),
    ('deal_value', 'default', 'a0000001-0005-0001-0001-000000000008', '{"amount":"450000"}', 0.65),
    ('deal_value', 'default', 'a0000001-0005-0001-0001-000000000009', '{"amount":"25000"}', 0.9),
    ('deal_value', 'default', 'a0000001-0005-0001-0001-000000000010', '{"amount":"35000"}', 0.85),
    ('deal_value', 'default', 'a0000001-0005-0001-0001-000000000011', '{"amount":"15000"}', 0.8),
    ('deal_value', 'default', 'a0000001-0005-0001-0001-000000000012', '{"amount":"40000"}', 0.75);

-- Win probability assertions
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence) VALUES
    ('win_probability', 'default', 'a0000001-0005-0001-0001-000000000001', '{"probability":"0.70"}', 0.8),
    ('win_probability', 'default', 'a0000001-0005-0001-0001-000000000002', '{"probability":"0.55"}', 0.7),
    ('win_probability', 'default', 'a0000001-0005-0001-0001-000000000003', '{"probability":"0.30"}', 0.6),
    ('win_probability', 'default', 'a0000001-0005-0001-0001-000000000004', '{"probability":"0.65"}', 0.75),
    ('win_probability', 'default', 'a0000001-0005-0001-0001-000000000005', '{"probability":"0.50"}', 0.7),
    ('win_probability', 'default', 'a0000001-0005-0001-0001-000000000006', '{"probability":"0.40"}', 0.5),
    ('win_probability', 'default', 'a0000001-0005-0001-0001-000000000007', '{"probability":"0.20"}', 0.4),
    ('win_probability', 'default', 'a0000001-0005-0001-0001-000000000008', '{"probability":"0.35"}', 0.55),
    ('win_probability', 'default', 'a0000001-0005-0001-0001-000000000009', '{"probability":"0.80"}', 0.9),
    ('win_probability', 'default', 'a0000001-0005-0001-0001-000000000010', '{"probability":"0.75"}', 0.85),
    ('win_probability', 'default', 'a0000001-0005-0001-0001-000000000011', '{"probability":"0.15"}', 0.5),
    ('win_probability', 'default', 'a0000001-0005-0001-0001-000000000012', '{"probability":"0.45"}', 0.6);

-- Financial terms (role-gated: deal_manager, finance, admin only)
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence) VALUES
    ('financial_terms', 'default', 'a0000001-0005-0001-0001-000000000001',
     '{"discount_pct":10,"payment_terms":"net-30","prepay_required":false}', 0.95),
    ('financial_terms', 'default', 'a0000001-0005-0001-0001-000000000002',
     '{"discount_pct":15,"payment_terms":"net-60","prepay_required":false}', 0.9),
    ('financial_terms', 'default', 'a0000001-0005-0001-0001-000000000006',
     '{"discount_pct":20,"payment_terms":"net-90","prepay_required":true}', 0.85),
    ('financial_terms', 'default', 'a0000001-0005-0001-0001-000000000010',
     '{"discount_pct":0,"payment_terms":"net-15","prepay_required":false}', 0.95);

-- Negotiation stance (role-gated: deal_manager, admin only)
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence) VALUES
    ('negotiation_stance', 'default', 'a0000001-0005-0001-0001-000000000001',
     '{"stance":"flexible on timeline, firm on price"}', 0.7),
    ('negotiation_stance', 'default', 'a0000001-0005-0001-0001-000000000006',
     '{"stance":"budget constrained, open to phased deployment"}', 0.65);

-- Sentiment assertions (ungated)
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence) VALUES
    ('sentiment', 'default', 'a0000001-0003-0001-0001-000000000001', '{"sentiment":"positive","notes":"enthusiastic about platform"}', 0.8),
    ('sentiment', 'default', 'a0000001-0003-0001-0001-000000000002', '{"sentiment":"neutral","notes":"evaluating competitors"}', 0.7),
    ('sentiment', 'default', 'a0000001-0003-0001-0001-000000000003', '{"sentiment":"positive","notes":"ready to move forward"}', 0.85),
    ('sentiment', 'default', 'a0000001-0003-0001-0001-000000000004', '{"sentiment":"cautious","notes":"concerned about timeline"}', 0.6);

-- CRM activity events (40+ across deals)
DO $$
DECLARE
    v_opp_ids uuid[] := ARRAY[
        'a0000001-0005-0001-0001-000000000001','a0000001-0005-0001-0001-000000000002',
        'a0000001-0005-0001-0001-000000000003','a0000001-0005-0001-0001-000000000004',
        'a0000001-0005-0001-0001-000000000005','a0000001-0005-0001-0001-000000000006',
        'a0000001-0005-0001-0001-000000000007','a0000001-0005-0001-0001-000000000008',
        'a0000001-0005-0001-0001-000000000009','a0000001-0005-0001-0001-000000000010',
        'a0000001-0005-0001-0001-000000000011','a0000001-0005-0001-0001-000000000012'
    ];
    v_types text[] := ARRAY['call','email','meeting','proposal_sent','demo'];
    v_event_id uuid;
    i int;
BEGIN
    FOR i IN 1..48 LOOP
        v_event_id := gen_random_uuid();

        INSERT INTO events (id, event_type, occurred_at, summary, properties, actor_system)
        VALUES (
            v_event_id,
            v_types[1 + (i % 5)],
            now() - (i || ' hours')::interval,
            format('Activity %s on deal', i),
            jsonb_build_object('duration_min', 15 + (i % 45), 'outcome', CASE WHEN i % 3 = 0 THEN 'positive' ELSE 'neutral' END),
            'crm-system'
        );

        INSERT INTO event_participants (event_id, node_id, role)
        VALUES (v_event_id, v_opp_ids[1 + (i % 12)], 'subject')
        ON CONFLICT DO NOTHING;
    END LOOP;
END;
$$;


-- ============================================================
-- SCENARIO 2: Cross-Functional Product Launch (PM)
-- ============================================================

-- Team member people for PM
INSERT INTO nodes (id, node_type, label, properties, attrs) VALUES
    ('b0000001-0001-0001-0001-000000000001', 'person', 'PM-Eng-Alice',
     '{"first_name":"Alice","last_name":"Eng","email":"alice.eng@co.com"}',
     '{"classification":"internal","teams":["engineering"]}'),
    ('b0000001-0001-0001-0001-000000000002', 'person', 'PM-Eng-Bob',
     '{"first_name":"Bob","last_name":"Eng","email":"bob.eng@co.com"}',
     '{"classification":"internal","teams":["engineering"]}'),
    ('b0000001-0001-0001-0001-000000000003', 'person', 'PM-Design-Carol',
     '{"first_name":"Carol","last_name":"Design","email":"carol.design@co.com"}',
     '{"classification":"internal","teams":["design"]}'),
    ('b0000001-0001-0001-0001-000000000004', 'person', 'PM-Mktg-Dave',
     '{"first_name":"Dave","last_name":"Mktg","email":"dave.mktg@co.com"}',
     '{"classification":"internal","teams":["marketing"]}'),
    ('b0000001-0001-0001-0001-000000000005', 'person', 'PM-Mktg-Eve',
     '{"first_name":"Eve","last_name":"Mktg","email":"eve.mktg@co.com"}',
     '{"classification":"internal","teams":["marketing"]}'),
    ('b0000001-0001-0001-0001-000000000006', 'person', 'PM-QA-Frank',
     '{"first_name":"Frank","last_name":"QA","email":"frank.qa@co.com"}',
     '{"classification":"internal","teams":["qa"]}')
;

-- Project, milestones, sprints
INSERT INTO nodes (id, node_type, label, properties, attrs) VALUES
    ('b0000001-0002-0001-0001-000000000001', 'project', 'Q3 Product Launch',
     '{"code":"PRJ-2601-0001","name":"Q3 Product Launch"}',
     '{"classification":"internal","teams":["engineering","design","marketing","qa"]}'),
    ('b0000001-0002-0001-0001-000000000002', 'milestone', 'Alpha Release',
     '{"code":"MIL-2601-0001","target_date":"2026-03-15"}',
     '{"classification":"internal","teams":["engineering","design","marketing","qa"]}'),
    ('b0000001-0002-0001-0001-000000000003', 'milestone', 'Beta Release',
     '{"code":"MIL-2601-0002","target_date":"2026-04-30"}',
     '{"classification":"internal","teams":["engineering","design","marketing","qa"]}'),
    ('b0000001-0002-0001-0001-000000000004', 'sprint', 'Sprint 1',
     '{"code":"SPR-2601-0001","start":"2026-02-01","end":"2026-02-14"}',
     '{"classification":"internal","teams":["engineering","design","marketing","qa"]}'),
    ('b0000001-0002-0001-0001-000000000005', 'sprint', 'Sprint 2',
     '{"code":"SPR-2601-0002","start":"2026-02-15","end":"2026-02-28"}',
     '{"classification":"internal","teams":["engineering","design","marketing","qa"]}'),
    ('b0000001-0002-0001-0001-000000000006', 'sprint', 'Sprint 3',
     '{"code":"SPR-2601-0003","start":"2026-03-01","end":"2026-03-14"}',
     '{"classification":"internal","teams":["engineering","design","marketing","qa"]}')
;

-- Tasks (30 tasks across teams)
DO $$
DECLARE
    v_task_id uuid;
    v_teams text[];
    v_statuses text[];
    v_owners uuid[];
    i int;
BEGIN
    v_teams := ARRAY[
        'engineering', 'engineering', 'engineering', 'engineering',
        'engineering', 'engineering', 'engineering', 'engineering',
        'engineering', 'engineering', 'engineering', 'engineering',
        'design', 'design', 'design', 'design',
        'design', 'design',
        'marketing', 'marketing', 'marketing', 'marketing',
        'marketing', 'marketing',
        'qa', 'qa', 'qa', 'qa',
        'qa', 'qa'
    ];
    v_statuses := ARRAY[
        'done','done','done','done','done','done','done','done',
        'in_review','in_review','in_review','in_review','in_review','in_review',
        'in_progress','in_progress','in_progress','in_progress','in_progress','in_progress','in_progress','in_progress',
        'todo','todo','todo','todo',
        'blocked','blocked',
        'backlog','backlog'
    ];
    v_owners := ARRAY[
        'b0000001-0001-0001-0001-000000000001','b0000001-0001-0001-0001-000000000002',
        'b0000001-0001-0001-0001-000000000001','b0000001-0001-0001-0001-000000000002',
        'b0000001-0001-0001-0001-000000000001','b0000001-0001-0001-0001-000000000002',
        'b0000001-0001-0001-0001-000000000001','b0000001-0001-0001-0001-000000000002',
        'b0000001-0001-0001-0001-000000000001','b0000001-0001-0001-0001-000000000002',
        'b0000001-0001-0001-0001-000000000001','b0000001-0001-0001-0001-000000000002',
        'b0000001-0001-0001-0001-000000000003','b0000001-0001-0001-0001-000000000003',
        'b0000001-0001-0001-0001-000000000003','b0000001-0001-0001-0001-000000000003',
        'b0000001-0001-0001-0001-000000000003','b0000001-0001-0001-0001-000000000003',
        'b0000001-0001-0001-0001-000000000004','b0000001-0001-0001-0001-000000000004',
        'b0000001-0001-0001-0001-000000000005','b0000001-0001-0001-0001-000000000005',
        'b0000001-0001-0001-0001-000000000004','b0000001-0001-0001-0001-000000000005',
        'b0000001-0001-0001-0001-000000000006','b0000001-0001-0001-0001-000000000006',
        'b0000001-0001-0001-0001-000000000006','b0000001-0001-0001-0001-000000000006',
        'b0000001-0001-0001-0001-000000000006','b0000001-0001-0001-0001-000000000006'
    ];

    FOR i IN 1..30 LOOP
        v_task_id := ('b0000001-0003-0001-0001-' || lpad(i::text, 12, '0'))::uuid;

        INSERT INTO nodes (id, node_type, label, properties, attrs)
        VALUES (
            v_task_id,
            'task',
            format('Task %s: %s work item', i, v_teams[i]),
            jsonb_build_object(
                'code', format('TSK-2601-%s', lpad(i::text, 4, '0')),
                'title', format('Task %s', i),
                'story_points', 1 + (i % 8),
                'estimated_hours', 2 + (i % 16),
                'priority', CASE WHEN i % 4 = 0 THEN 'high' WHEN i % 3 = 0 THEN 'medium' ELSE 'low' END
            ),
            jsonb_build_object('classification', 'internal', 'teams', jsonb_build_array(v_teams[i]))
        )
        ;

        -- task_status assertion
        INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
        VALUES ('task_status', 'default', v_task_id,
                jsonb_build_object('status', v_statuses[i]), 1.0);

        -- estimate assertion
        INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
        VALUES ('estimate', 'default', v_task_id,
                jsonb_build_object('hours', 2 + (i % 16), 'points', 1 + (i % 8)), 0.9);

        -- project contains edge
        INSERT INTO edges (edge_type, source_id, target_id, properties)
        VALUES ('contains', 'b0000001-0002-0001-0001-000000000001', v_task_id, '{}');

        -- assigned_to edge
        INSERT INTO edges (edge_type, source_id, target_id, properties, effective_from)
        VALUES ('assigned_to', v_task_id, v_owners[i], '{"role":"owner"}', now());

        -- sprint membership (distribute across sprints)
        INSERT INTO edges (edge_type, source_id, target_id, properties)
        VALUES ('sprint_member', v_task_id,
                ('b0000001-0002-0001-0001-' || lpad((4 + ((i-1) / 10))::text, 12, '0'))::uuid,
                '{}');
    END LOOP;

    -- Cross-team blockers (3 blockers)
    -- Engineering task 15 blocks Marketing task 19
    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES ('blocks', 'b0000001-0003-0001-0001-000000000015', 'b0000001-0003-0001-0001-000000000019', '{"reason":"API not ready"}');
    -- Design task 13 blocks QA task 25
    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES ('blocks', 'b0000001-0003-0001-0001-000000000013', 'b0000001-0003-0001-0001-000000000025', '{"reason":"UI not finalized"}');
    -- Engineering task 1 blocks Design task 17
    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES ('blocks', 'b0000001-0003-0001-0001-000000000001', 'b0000001-0003-0001-0001-000000000017', '{"reason":"Core component needed"}');

    -- Generate 150+ PM events (status changes, comments, time logs)
    FOR i IN 1..160 LOOP
        v_task_id := gen_random_uuid(); -- reusing variable for event_id

        INSERT INTO events (id, event_type, occurred_at, summary, properties, actor_system)
        VALUES (
            v_task_id,
            CASE WHEN i % 3 = 0 THEN 'status_change'
                 WHEN i % 3 = 1 THEN 'comment'
                 ELSE 'time_log' END,
            now() - (i || ' hours')::interval,
            format('PM event %s', i),
            jsonb_build_object('detail', format('event detail %s', i),
                               'hours', CASE WHEN i % 3 = 2 THEN (1 + (i % 8))::numeric ELSE null END),
            'pm-system'
        );

        INSERT INTO event_participants (event_id, node_id, role)
        VALUES (v_task_id, ('b0000001-0003-0001-0001-' || lpad((1 + (i % 30))::text, 12, '0'))::uuid, 'subject')
        ON CONFLICT DO NOTHING;
    END LOOP;
END;
$$;


-- ============================================================
-- SCENARIO 3: Customer Support Escalation Chain
-- ============================================================

-- Support team members
INSERT INTO nodes (id, node_type, label, properties, attrs) VALUES
    ('c0000001-0001-0001-0001-000000000001', 'person', 'Support-T1-Amy',
     '{"first_name":"Amy","last_name":"T1","email":"amy.t1@co.com"}',
     '{"classification":"internal","teams":["support-t1"]}'),
    ('c0000001-0001-0001-0001-000000000002', 'person', 'Support-T1-Ben',
     '{"first_name":"Ben","last_name":"T1","email":"ben.t1@co.com"}',
     '{"classification":"internal","teams":["support-t1"]}'),
    ('c0000001-0001-0001-0001-000000000003', 'person', 'Support-T2-Cara',
     '{"first_name":"Cara","last_name":"T2","email":"cara.t2@co.com"}',
     '{"classification":"internal","teams":["support-t2"]}'),
    ('c0000001-0001-0001-0001-000000000004', 'person', 'Support-Esc-Dan',
     '{"first_name":"Dan","last_name":"Esc","email":"dan.esc@co.com"}',
     '{"classification":"internal","teams":["support-escalation"]}')
;

-- Customer orgs for support (some confidential under NDA)
INSERT INTO nodes (id, node_type, label, properties, attrs) VALUES
    ('c0000001-0002-0001-0001-000000000001', 'org', 'PublicCorp',
     '{"name":"PublicCorp","industry":"Retail"}', '{}'),
    ('c0000001-0002-0001-0001-000000000002', 'org', 'NDA-SecureCo',
     '{"name":"NDA-SecureCo","industry":"Defense","nda_terms":"classified"}',
     '{"classification":"confidential","teams":["support-t2","support-escalation"]}'),
    ('c0000001-0002-0001-0001-000000000003', 'org', 'HealthTech Inc',
     '{"name":"HealthTech Inc","industry":"Healthcare"}', '{}'),
    ('c0000001-0002-0001-0001-000000000004', 'org', 'TopSecret Gov',
     '{"name":"TopSecret Gov","industry":"Government","nda_terms":"top-secret"}',
     '{"classification":"restricted","teams":["support-escalation"]}')
;

-- Support contacts
INSERT INTO nodes (id, node_type, label, properties, attrs) VALUES
    ('c0000001-0003-0001-0001-000000000001', 'person', 'Cust-Public-1',
     '{"first_name":"Pat","last_name":"Public","email":"pat@publiccorp.com"}', '{}'),
    ('c0000001-0003-0001-0001-000000000002', 'person', 'Cust-NDA-1',
     '{"first_name":"Nora","last_name":"NDA","email":"nora@secureco.com"}',
     '{"classification":"confidential","teams":["support-t2","support-escalation"]}'),
    ('c0000001-0003-0001-0001-000000000003', 'person', 'Cust-Health-1',
     '{"first_name":"Hal","last_name":"Health","email":"hal@healthtech.com"}', '{}'),
    ('c0000001-0003-0001-0001-000000000004', 'person', 'Cust-TopSecret-1',
     '{"first_name":"Gina","last_name":"Gov","email":"gina@topsecretgov.gov"}',
     '{"classification":"restricted","teams":["support-escalation"]}')
;

-- Employs edges for support contacts
INSERT INTO edges (edge_type, source_id, target_id, properties) VALUES
    ('employs', 'c0000001-0002-0001-0001-000000000001', 'c0000001-0003-0001-0001-000000000001', '{}'),
    ('employs', 'c0000001-0002-0001-0001-000000000002', 'c0000001-0003-0001-0001-000000000002', '{}'),
    ('employs', 'c0000001-0002-0001-0001-000000000003', 'c0000001-0003-0001-0001-000000000003', '{}'),
    ('employs', 'c0000001-0002-0001-0001-000000000004', 'c0000001-0003-0001-0001-000000000004', '{}');

-- Support tickets (50 tickets)
DO $$
DECLARE
    v_ticket_id uuid;
    v_event_id uuid;
    v_severities text[] := ARRAY['critical','critical','critical','critical','critical',
                                  'critical','critical','critical','critical','critical',
                                  'high','high','high','high','high','high','high','high',
                                  'high','high','high','high','high','high','high',
                                  'medium','medium','medium','medium','medium','medium',
                                  'medium','medium','medium','medium','medium','medium',
                                  'medium','medium','medium',
                                  'low','low','low','low','low','low','low','low','low','low'];
    v_orgs uuid[] := ARRAY[
        'c0000001-0002-0001-0001-000000000001', -- PublicCorp (public, 20 tickets)
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000001',
        'c0000001-0002-0001-0001-000000000002', -- NDA-SecureCo (confidential, 15 tickets)
        'c0000001-0002-0001-0001-000000000002',
        'c0000001-0002-0001-0001-000000000002',
        'c0000001-0002-0001-0001-000000000002',
        'c0000001-0002-0001-0001-000000000002',
        'c0000001-0002-0001-0001-000000000002',
        'c0000001-0002-0001-0001-000000000002',
        'c0000001-0002-0001-0001-000000000002',
        'c0000001-0002-0001-0001-000000000002',
        'c0000001-0002-0001-0001-000000000002',
        'c0000001-0002-0001-0001-000000000002',
        'c0000001-0002-0001-0001-000000000002',
        'c0000001-0002-0001-0001-000000000002',
        'c0000001-0002-0001-0001-000000000002',
        'c0000001-0002-0001-0001-000000000002',
        'c0000001-0002-0001-0001-000000000003', -- HealthTech (public, 10 tickets)
        'c0000001-0002-0001-0001-000000000003',
        'c0000001-0002-0001-0001-000000000003',
        'c0000001-0002-0001-0001-000000000003',
        'c0000001-0002-0001-0001-000000000003',
        'c0000001-0002-0001-0001-000000000003',
        'c0000001-0002-0001-0001-000000000003',
        'c0000001-0002-0001-0001-000000000003',
        'c0000001-0002-0001-0001-000000000003',
        'c0000001-0002-0001-0001-000000000003',
        'c0000001-0002-0001-0001-000000000004', -- TopSecret Gov (restricted, 5 tickets)
        'c0000001-0002-0001-0001-000000000004',
        'c0000001-0002-0001-0001-000000000004',
        'c0000001-0002-0001-0001-000000000004',
        'c0000001-0002-0001-0001-000000000004'
    ];
    v_teams text[][];
    i int;
BEGIN
    FOR i IN 1..50 LOOP
        v_ticket_id := ('c0000001-0004-0001-0001-' || lpad(i::text, 12, '0'))::uuid;

        -- Assign ticket teams based on org: T1 for public, T2 for confidential, escalation for restricted
        INSERT INTO nodes (id, node_type, label, properties, attrs)
        VALUES (
            v_ticket_id,
            'ticket',
            format('Ticket #%s', i),
            jsonb_build_object(
                'code', format('TKT-%s', lpad(i::text, 4, '0')),
                'description', format('Support issue %s', i),
                'internal_notes', format('Internal analysis for ticket %s', i)
            ),
            CASE
                WHEN i <= 20 THEN '{"classification":"internal","teams":["support-t1","support-t2","support-escalation"]}'::jsonb
                WHEN i <= 35 THEN '{"classification":"confidential","teams":["support-t2","support-escalation"]}'::jsonb
                WHEN i <= 45 THEN '{"classification":"internal","teams":["support-t1","support-t2","support-escalation"]}'::jsonb
                ELSE '{"classification":"restricted","teams":["support-escalation"]}'::jsonb
            END
        )
        ;

        -- Ticket status assertion
        INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
        VALUES ('ticket_status', 'default', v_ticket_id,
                jsonb_build_object(
                    'status', CASE
                        WHEN i % 5 = 0 THEN 'resolved'
                        WHEN i % 5 = 1 THEN 'investigating'
                        WHEN i % 5 = 2 THEN 'waiting'
                        WHEN i % 5 = 3 THEN 'open'
                        ELSE 'reopened'
                    END
                ), 1.0);

        -- Severity assertion
        INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
        VALUES ('severity', 'default', v_ticket_id,
                jsonb_build_object('level', v_severities[i]), 1.0);

        -- Link ticket to customer org
        INSERT INTO edges (edge_type, source_id, target_id, properties)
        VALUES ('regarding', v_ticket_id, v_orgs[i], '{"context":"customer_issue"}');

        -- ticket-created event
        v_event_id := gen_random_uuid();

        INSERT INTO events (id, event_type, occurred_at, summary, properties, actor_system)
        VALUES (v_event_id, 'ticket_created', now() - (i || ' days')::interval,
                format('Ticket #%s created', i),
                jsonb_build_object('severity', v_severities[i]),
                'support-system');

        INSERT INTO event_participants (event_id, node_id, role)
        VALUES (v_event_id, v_ticket_id, 'subject')
        ON CONFLICT DO NOTHING;
    END LOOP;

    -- Additional support events (responses, escalations, notes) = ~150 more
    FOR i IN 1..150 LOOP
        v_event_id := gen_random_uuid();

        INSERT INTO events (id, event_type, occurred_at, summary, properties, actor_system)
        VALUES (
            v_event_id,
            CASE WHEN i % 4 = 0 THEN 'response_sent'
                 WHEN i % 4 = 1 THEN 'escalated'
                 WHEN i % 4 = 2 THEN 'note_added'
                 ELSE 'resolved' END,
            now() - ((i * 3) || ' hours')::interval,
            format('Support event %s', i),
            jsonb_build_object('detail', format('Support detail %s', i)),
            'support-system'
        );

        INSERT INTO event_participants (event_id, node_id, role)
        VALUES (v_event_id, ('c0000001-0004-0001-0001-' || lpad((1 + (i % 50))::text, 12, '0'))::uuid, 'subject')
        ON CONFLICT DO NOTHING;
    END LOOP;

    -- Artifacts (screenshots, logs) attached to tickets
    FOR i IN 1..30 LOOP
        INSERT INTO artifacts (artifact_type, source_node_id, content, attrs)
        VALUES (
            CASE WHEN i % 2 = 0 THEN 'screenshot' ELSE 'log_file' END,
            ('c0000001-0004-0001-0001-' || lpad((1 + (i % 50))::text, 12, '0'))::uuid,
            jsonb_build_object('filename', format('artifact_%s.%s', i, CASE WHEN i % 2 = 0 THEN 'png' ELSE 'log' END)),
            '{}'
        );
    END LOOP;
END;
$$;


-- ============================================================
-- SCENARIO 4: M&A Due Diligence (Maximum Security)
-- ============================================================

-- Acquisition targets (restricted classification)
INSERT INTO nodes (id, node_type, label, properties, attrs) VALUES
    ('d0000001-0001-0001-0001-000000000001', 'org', 'Target Alpha Inc',
     '{"name":"Target Alpha Inc","industry":"AI/ML","revenue":"45M","employee_count":120}',
     '{"classification":"restricted","teams":["ma-team"]}'),
    ('d0000001-0001-0001-0001-000000000002', 'org', 'Target Beta Labs',
     '{"name":"Target Beta Labs","industry":"Biotech","revenue":"80M","employee_count":250}',
     '{"classification":"restricted","teams":["ma-team"]}'),
    ('d0000001-0001-0001-0001-000000000003', 'org', 'Target Gamma Tech',
     '{"name":"Target Gamma Tech","industry":"Cybersecurity","revenue":"30M","employee_count":80}',
     '{"classification":"restricted","teams":["ma-team"]}')
;

-- Key executives at targets (restricted)
INSERT INTO nodes (id, node_type, label, properties, attrs) VALUES
    ('d0000001-0002-0001-0001-000000000001', 'person', 'CEO Alpha',
     '{"first_name":"Alexandra","last_name":"Alpha","title":"CEO","salary":"450000","ssn":"999-11-1111"}',
     '{"classification":"restricted","teams":["ma-team"]}'),
    ('d0000001-0002-0001-0001-000000000002', 'person', 'CTO Alpha',
     '{"first_name":"Theo","last_name":"Alpha","title":"CTO","salary":"380000","ssn":"999-22-2222"}',
     '{"classification":"restricted","teams":["ma-team"]}'),
    ('d0000001-0002-0001-0001-000000000003', 'person', 'CEO Beta',
     '{"first_name":"Beatrice","last_name":"Beta","title":"CEO","salary":"520000","ssn":"999-33-3333"}',
     '{"classification":"restricted","teams":["ma-team"]}'),
    ('d0000001-0002-0001-0001-000000000004', 'person', 'CFO Beta',
     '{"first_name":"Fabian","last_name":"Beta","title":"CFO","salary":"410000","ssn":"999-44-4444"}',
     '{"classification":"restricted","teams":["ma-team"]}'),
    ('d0000001-0002-0001-0001-000000000005', 'person', 'CEO Gamma',
     '{"first_name":"George","last_name":"Gamma","title":"CEO","salary":"350000","ssn":"999-55-5555"}',
     '{"classification":"restricted","teams":["ma-team"]}')
;

-- Board members and advisors (restricted)
INSERT INTO nodes (id, node_type, label, properties, attrs) VALUES
    ('d0000001-0002-0001-0001-000000000006', 'person', 'Board Member Chen',
     '{"first_name":"Wei","last_name":"Chen","title":"Board Member"}',
     '{"classification":"restricted","teams":["ma-team"]}'),
    ('d0000001-0002-0001-0001-000000000007', 'person', 'Advisor Brooks',
     '{"first_name":"Amanda","last_name":"Brooks","title":"M&A Advisor"}',
     '{"classification":"restricted","teams":["ma-team"]}')
;

-- Edges: employment, board, advisor relationships
INSERT INTO edges (edge_type, source_id, target_id, properties) VALUES
    ('employs', 'd0000001-0001-0001-0001-000000000001', 'd0000001-0002-0001-0001-000000000001', '{"title":"CEO"}'),
    ('employs', 'd0000001-0001-0001-0001-000000000001', 'd0000001-0002-0001-0001-000000000002', '{"title":"CTO"}'),
    ('employs', 'd0000001-0001-0001-0001-000000000002', 'd0000001-0002-0001-0001-000000000003', '{"title":"CEO"}'),
    ('employs', 'd0000001-0001-0001-0001-000000000002', 'd0000001-0002-0001-0001-000000000004', '{"title":"CFO"}'),
    ('employs', 'd0000001-0001-0001-0001-000000000003', 'd0000001-0002-0001-0001-000000000005', '{"title":"CEO"}'),
    ('board_member_of', 'd0000001-0002-0001-0001-000000000006', 'd0000001-0001-0001-0001-000000000001', '{}'),
    ('board_member_of', 'd0000001-0002-0001-0001-000000000006', 'd0000001-0001-0001-0001-000000000002', '{}'),
    ('advises', 'd0000001-0002-0001-0001-000000000007', 'd0000001-0001-0001-0001-000000000001', '{"scope":"M&A"}'),
    ('advises', 'd0000001-0002-0001-0001-000000000007', 'd0000001-0001-0001-0001-000000000003', '{"scope":"M&A"}');

-- Valuation assertions (gated via restricted node)
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence) VALUES
    ('valuation', 'default', 'd0000001-0001-0001-0001-000000000001',
     '{"amount":"120000000","method":"DCF","date":"2026-01-15"}', 0.75),
    ('valuation', 'default', 'd0000001-0001-0001-0001-000000000002',
     '{"amount":"250000000","method":"comparable","date":"2026-01-20"}', 0.7),
    ('valuation', 'default', 'd0000001-0001-0001-0001-000000000003',
     '{"amount":"85000000","method":"DCF","date":"2026-02-01"}', 0.8);

-- Financial terms on M&A targets
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence) VALUES
    ('financial_terms', 'default', 'd0000001-0001-0001-0001-000000000001',
     '{"offer_range":"100M-130M","earnout":"15M over 3yr","structure":"cash+stock"}', 0.6),
    ('financial_terms', 'default', 'd0000001-0001-0001-0001-000000000002',
     '{"offer_range":"220M-270M","earnout":"30M over 2yr","structure":"all-cash"}', 0.55);

-- Negotiation stance on M&A
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence) VALUES
    ('negotiation_stance', 'default', 'd0000001-0001-0001-0001-000000000001',
     '{"stance":"willing to sell, wants retention packages for key staff"}', 0.65),
    ('negotiation_stance', 'default', 'd0000001-0001-0001-0001-000000000002',
     '{"stance":"exploring options, not committed, board divided"}', 0.5);

-- Compensation assertions (hr_admin/admin only)
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence) VALUES
    ('compensation', 'default', 'd0000001-0002-0001-0001-000000000001',
     '{"base":450000,"bonus_target":"40%","equity":"2.5% vested","retention_risk":"medium"}', 0.8),
    ('compensation', 'default', 'd0000001-0002-0001-0001-000000000003',
     '{"base":520000,"bonus_target":"50%","equity":"5% vested","retention_risk":"high"}', 0.75),
    ('compensation', 'default', 'd0000001-0002-0001-0001-000000000005',
     '{"base":350000,"bonus_target":"35%","equity":"8% vested","retention_risk":"low"}', 0.85);

-- Retention risk (ungated but on restricted nodes, so still hidden by node visibility)
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence) VALUES
    ('retention_risk', 'default', 'd0000001-0002-0001-0001-000000000001',
     '{"risk":"medium","key_factor":"wants CTO title post-merger"}', 0.7),
    ('retention_risk', 'default', 'd0000001-0002-0001-0001-000000000002',
     '{"risk":"high","key_factor":"has competing offer"}', 0.8),
    ('retention_risk', 'default', 'd0000001-0002-0001-0001-000000000005',
     '{"risk":"low","key_factor":"founder, mission-aligned"}', 0.9);

-- IP portfolio
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence) VALUES
    ('ip_portfolio', 'default', 'd0000001-0001-0001-0001-000000000001',
     '{"patents":12,"pending":5,"trade_secrets":"substantial","estimated_value":"15M"}', 0.7),
    ('ip_portfolio', 'default', 'd0000001-0001-0001-0001-000000000003',
     '{"patents":8,"pending":3,"trade_secrets":"moderate","estimated_value":"10M"}', 0.65);

-- M&A events (meetings, due diligence reviews, legal reviews)
DO $$
DECLARE
    v_event_id uuid;
    v_targets uuid[] := ARRAY[
        'd0000001-0001-0001-0001-000000000001',
        'd0000001-0001-0001-0001-000000000002',
        'd0000001-0001-0001-0001-000000000003'
    ];
    i int;
BEGIN
    FOR i IN 1..60 LOOP
        v_event_id := gen_random_uuid();

        INSERT INTO events (id, event_type, occurred_at, summary, properties, actor_system)
        VALUES (
            v_event_id,
            CASE WHEN i % 3 = 0 THEN 'dd_review'
                 WHEN i % 3 = 1 THEN 'meeting'
                 ELSE 'legal_review' END,
            now() - (i || ' days')::interval,
            format('M&A event %s for target %s', i, 1 + (i % 3)),
            jsonb_build_object('confidential', true, 'detail', format('M&A detail %s', i)),
            'ma-system'
        );

        INSERT INTO event_participants (event_id, node_id, role)
        VALUES (v_event_id, v_targets[1 + (i % 3)], 'subject')
        ON CONFLICT DO NOTHING;
    END LOOP;
END;
$$;

-- Admin access grant: admin can see all classified nodes
INSERT INTO access_grants (grantee, grant_type, resource_type, access_level, scope) VALUES
    ('admin', 'role', 'node', 'read', '{"classification":"internal"}'),
    ('admin', 'role', 'node', 'read', '{"classification":"confidential"}'),
    ('admin', 'role', 'node', 'read', '{"classification":"restricted"}');

-- Explicit access grants for M&A (only 3 users + specific roles)
INSERT INTO access_grants (grantee, grant_type, resource_type, access_level, scope) VALUES
    ('user:ma-lead', 'user', 'node', 'read', '{"classification":"restricted"}'),
    ('user:ma-analyst', 'user', 'node', 'read', '{"classification":"restricted"}'),
    ('user:ma-legal', 'user', 'node', 'read', '{"classification":"restricted"}'),
    ('deal_manager', 'role', 'node', 'read', '{"classification":"restricted"}'),
    ('deal_manager', 'role', 'node', 'read', '{"classification":"internal"}'),
    ('hr_admin', 'role', 'node', 'read', '{"classification":"restricted"}'),
    ('hr_admin', 'role', 'node', 'read', '{"classification":"internal"}'),
    ('finance', 'role', 'node', 'read', '{"classification":"internal"}'),
    ('agent:dd-analyst', 'user', 'node', 'read', '{"node_type":"org"}'),
    ('agent:pm-bot', 'user', 'node', 'read', '{"node_type":"task"}'),
    ('agent:crm-sync', 'user', 'node', 'read', '{"node_type":"opportunity"}');


-- ============================================================
-- SCENARIO 5: Entity Resolution and Audit Trail
-- ============================================================

-- 10 person nodes, 3 pairs are duplicates
INSERT INTO nodes (id, node_type, label, properties, attrs) VALUES
    -- Pair 1: same person
    ('e0000001-0001-0001-0001-000000000001', 'person', 'John Smith',
     '{"first_name":"John","last_name":"Smith","email":"john@example.com","phone":"555-9001"}', '{}'),
    ('e0000001-0001-0001-0001-000000000002', 'person', 'J. Smith',
     '{"first_name":"J.","last_name":"Smith","email":"jsmith@example.com","phone":"555-9001"}', '{}'),
    -- Pair 2: same person
    ('e0000001-0001-0001-0001-000000000003', 'person', 'Maria Garcia',
     '{"first_name":"Maria","last_name":"Garcia","email":"maria@example.com"}', '{}'),
    ('e0000001-0001-0001-0001-000000000004', 'person', 'M. Garcia',
     '{"first_name":"M.","last_name":"Garcia","email":"mgarcia@example.com"}', '{}'),
    -- Pair 3: same person (left unmerged for testing)
    ('e0000001-0001-0001-0001-000000000005', 'person', 'Robert Chen',
     '{"first_name":"Robert","last_name":"Chen","email":"robert@example.com"}', '{}'),
    ('e0000001-0001-0001-0001-000000000006', 'person', 'Rob Chen',
     '{"first_name":"Rob","last_name":"Chen","email":"robchen@example.com"}', '{}'),
    -- Unique people
    ('e0000001-0001-0001-0001-000000000007', 'person', 'Unique Lisa',
     '{"first_name":"Lisa","last_name":"Unique","email":"lisa@example.com"}', '{}'),
    ('e0000001-0001-0001-0001-000000000008', 'person', 'Unique Mike',
     '{"first_name":"Mike","last_name":"Unique","email":"mike@example.com"}', '{}'),
    ('e0000001-0001-0001-0001-000000000009', 'person', 'Unique Nina',
     '{"first_name":"Nina","last_name":"Unique","email":"nina@example.com"}', '{}'),
    ('e0000001-0001-0001-0001-000000000010', 'person', 'Unique Oscar',
     '{"first_name":"Oscar","last_name":"Unique","email":"oscar@example.com"}', '{}')
;

-- Edges for duplicates (each copy has own edges)
INSERT INTO edges (edge_type, source_id, target_id, properties) VALUES
    ('affiliated_with', 'e0000001-0001-0001-0001-000000000001', 'a0000001-0002-0001-0001-000000000001', '{"source":"crm"}'),
    ('affiliated_with', 'e0000001-0001-0001-0001-000000000002', 'a0000001-0002-0001-0001-000000000001', '{"source":"support"}'),
    ('affiliated_with', 'e0000001-0001-0001-0001-000000000003', 'a0000001-0002-0001-0001-000000000002', '{"source":"crm"}'),
    ('affiliated_with', 'e0000001-0001-0001-0001-000000000004', 'a0000001-0002-0001-0001-000000000002', '{"source":"marketing"}'),
    ('affiliated_with', 'e0000001-0001-0001-0001-000000000005', 'a0000001-0002-0001-0001-000000000003', '{"source":"crm"}'),
    ('affiliated_with', 'e0000001-0001-0001-0001-000000000006', 'a0000001-0002-0001-0001-000000000003', '{"source":"linkedin"}');

-- Assertions on duplicates (each copy has own assertions, including supersession chains)
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence) VALUES
    ('lead_score', 'default', 'e0000001-0001-0001-0001-000000000001', '{"score":85}', 0.9),
    ('lead_score', 'default', 'e0000001-0001-0001-0001-000000000002', '{"score":72}', 0.7),
    ('lead_score', 'default', 'e0000001-0001-0001-0001-000000000003', '{"score":60}', 0.8),
    ('lead_score', 'default', 'e0000001-0001-0001-0001-000000000004', '{"score":55}', 0.6),
    ('lead_score', 'default', 'e0000001-0001-0001-0001-000000000005', '{"score":90}', 0.95),
    ('lead_score', 'default', 'e0000001-0001-0001-0001-000000000006', '{"score":88}', 0.85),
    ('contact_info', 'default', 'e0000001-0001-0001-0001-000000000001', '{"preferred":"email"}', 0.9),
    ('contact_info', 'default', 'e0000001-0001-0001-0001-000000000002', '{"preferred":"phone"}', 0.8);

-- Events on duplicates
DO $$
DECLARE
    v_event_id uuid;
    v_people uuid[] := ARRAY[
        'e0000001-0001-0001-0001-000000000001',
        'e0000001-0001-0001-0001-000000000002',
        'e0000001-0001-0001-0001-000000000003',
        'e0000001-0001-0001-0001-000000000004'
    ];
    i int;
BEGIN
    FOR i IN 1..20 LOOP
        v_event_id := gen_random_uuid();

        INSERT INTO events (id, event_type, occurred_at, summary, properties, actor_system)
        VALUES (
            v_event_id,
            CASE WHEN i % 2 = 0 THEN 'email' ELSE 'call' END,
            now() - (i || ' days')::interval,
            format('Interaction %s with person', i),
            jsonb_build_object('outcome', 'completed'),
            'crm-system'
        );

        INSERT INTO event_participants (event_id, node_id, role)
        VALUES (v_event_id, v_people[1 + (i % 4)], 'subject')
        ON CONFLICT DO NOTHING;
    END LOOP;
END;
$$;

-- Node source maps for dedup tracking
INSERT INTO node_source_map (node_id, source_schema, source_table, source_id) VALUES
    ('e0000001-0001-0001-0001-000000000001', 'crm', 'contacts', '1001'),
    ('e0000001-0001-0001-0001-000000000002', 'support', 'users', '2001'),
    ('e0000001-0001-0001-0001-000000000003', 'crm', 'contacts', '1002'),
    ('e0000001-0001-0001-0001-000000000004', 'marketing', 'leads', '3001'),
    ('e0000001-0001-0001-0001-000000000005', 'crm', 'contacts', '1003'),
    ('e0000001-0001-0001-0001-000000000006', 'linkedin', 'profiles', '4001');


-- ============================================================
-- RECOMMENDATION 1: Temporal boundary testing
-- Edges with expired effective_to for time-scoped queries
-- ============================================================
-- Historical assignment: Alice was assigned to opp 1, then replaced by Bob
INSERT INTO edges (id, edge_type, source_id, target_id, properties, effective_from, effective_to)
VALUES (
    'f0000001-0001-0001-0001-000000000001',
    'assigned_to',
    'a0000001-0005-0001-0001-000000000001',
    'a0000001-0001-0001-0001-000000000002',  -- Bob was the old owner
    '{"role":"owner"}',
    now() - interval '90 days',
    now() - interval '30 days'  -- expired 30 days ago
);

-- ============================================================
-- RECOMMENDATION 3: Cross-scenario entity sharing
-- Maya Cross appears in both CRM (Scenario 1) and Support (Scenario 3)
-- ============================================================
-- Maya also has a support ticket in Scenario 3
INSERT INTO edges (edge_type, source_id, target_id, properties)
VALUES ('regarding', 'c0000001-0004-0001-0001-000000000001', 'a0000001-0003-0001-0001-000000000005', '{"context":"reporter"}');

COMMIT;
