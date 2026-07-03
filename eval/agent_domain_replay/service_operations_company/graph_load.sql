SET search_path = rye, public, pg_catalog;

SELECT rye.ensure_knowledge_domain('account-health', 'Account Health', 'Customer health, owner updates, and account commitments.');
SELECT rye.ensure_knowledge_domain('support-operations', 'Support Operations', 'Support incidents, escalations, and resolutions.');
SELECT rye.ensure_knowledge_domain('implementation-projects', 'Implementation Projects', 'Delivery milestones and project status.');
SELECT rye.ensure_knowledge_domain('billing-risk', 'Billing Risk', 'Invoice holds, billing clearance, and collection risk.');
SELECT rye.ensure_knowledge_domain('systems-adoption', 'Systems Adoption', 'Planned system-of-record and process changes.');

SELECT rye.subscribe_channel_to_domain('slack:#accounts-beacon', 'account-health', 'candidate_write', true);
SELECT rye.subscribe_channel_to_domain('slack:#accounts-beacon', 'implementation-projects', 'read', true);
SELECT rye.subscribe_channel_to_domain('slack:#accounts-beacon', 'billing-risk', 'read', true);
SELECT rye.subscribe_channel_to_domain('slack:#support-beacon', 'support-operations', 'candidate_write', false);
SELECT rye.subscribe_channel_to_domain('slack:#support-beacon', 'account-health', 'read', true);
SELECT rye.subscribe_channel_to_domain('slack:#projects-beacon', 'implementation-projects', 'candidate_write', false);
SELECT rye.subscribe_channel_to_domain('slack:#projects-beacon', 'support-operations', 'read', true);
SELECT rye.subscribe_channel_to_domain('slack:#finance-beacon', 'billing-risk', 'candidate_write', false);
SELECT rye.subscribe_channel_to_domain('slack:#finance-beacon', 'account-health', 'read', true);
SELECT rye.subscribe_channel_to_domain('slack:#accounts-beacon', 'systems-adoption', 'candidate_write', true);

SELECT rye.grant_domain_authority('account-health', 'person', 'person:simone-bell', ARRAY['account_status', 'customer_commitment'], NULL, ARRAY['confirmed', 'policy_set']);
SELECT rye.grant_domain_authority('support-operations', 'person', 'person:jae-lin', ARRAY['support_status', 'incident_resolution'], NULL, ARRAY['confirmed']);
SELECT rye.grant_domain_authority('implementation-projects', 'person', 'person:omar-velez', ARRAY['milestone', 'delivery_status'], NULL, ARRAY['confirmed']);
SELECT rye.grant_domain_authority('billing-risk', 'person', 'person:tess-morgan', ARRAY['invoice_hold', 'billing_clearance'], NULL, ARRAY['confirmed']);
SELECT rye.grant_domain_authority('systems-adoption', 'person', 'person:simone-bell', ARRAY['crm_pm_process'], NULL, ARRAY['policy_set']);

SELECT rye.create_agent_identity('fixture-service-intake', 'Fixture Service Intake Agent', 'replay');
SELECT rye.grant_agent_capability('fixture-service-intake', 'rye.candidate.create', 'account-health');
SELECT rye.grant_agent_capability('fixture-service-intake', 'rye.candidate.create', 'support-operations');
SELECT rye.grant_agent_capability('fixture-service-intake', 'rye.candidate.create', 'implementation-projects');
SELECT rye.grant_agent_capability('fixture-service-intake', 'rye.candidate.create', 'billing-risk');
SELECT rye.grant_agent_capability('fixture-service-intake', 'rye.candidate.create', 'systems-adoption');

WITH agent AS (SELECT id FROM rye.agent_identities WHERE agent_key = 'fixture-service-intake')
SELECT rye.agent_create_candidate(id, 'fact', 'Greenridge Clinics account health is green going into the 2026-06-24 portal pilot.', '{}'::jsonb, ARRAY['account-health'], 'slack:#accounts-beacon', 'account:greenridge-clinics', 'account owner confirmation', 'confirmed', 'current', '[{"source":"email","id":"greenridge-status-2026-06-22"}]'::jsonb, '{}'::uuid[], 'bf-001', '{}'::uuid[], '{}'::uuid[], 0.9, 'bf-001')
FROM agent;

WITH agent AS (SELECT id FROM rye.agent_identities WHERE agent_key = 'fixture-service-intake')
SELECT rye.agent_create_candidate(id, 'fact', 'Greenridge ticket S-778 is resolved and no longer blocks portal pilot.', '{}'::jsonb, ARRAY['support-operations'], 'slack:#support-beacon', 'account:greenridge-clinics', 'support lead confirmation', 'confirmed', 'current', '[{"source":"slack","channel":"#support-beacon","ts":"2026-05-08T16:40:00"}]'::jsonb, '{}'::uuid[], 'bf-002', '{}'::uuid[], '{}'::uuid[], 0.88, 'bf-002')
FROM agent;

WITH agent AS (SELECT id FROM rye.agent_identities WHERE agent_key = 'fixture-service-intake')
SELECT rye.agent_create_candidate(id, 'fact', 'Greenridge invoice INV-2044 billing hold is released after PO correction.', '{}'::jsonb, ARRAY['billing-risk'], 'slack:#finance-beacon', 'account:greenridge-clinics', 'finance reviewer confirmation', 'confirmed', 'current', '[{"source":"slack","channel":"#finance-beacon","ts":"2026-06-18T09:55:00"}]'::jsonb, '{}'::uuid[], 'bf-003', '{}'::uuid[], '{}'::uuid[], 0.9, 'bf-003')
FROM agent;

WITH agent AS (SELECT id FROM rye.agent_identities WHERE agent_key = 'fixture-service-intake')
SELECT rye.agent_create_candidate(id, 'task', 'Greenridge portal pilot starts 2026-06-24 and training is planned for 2026-06-27.', '{}'::jsonb, ARRAY['implementation-projects'], 'slack:#projects-beacon', 'project:greenridge-portal-pilot', 'delivery lead confirmation', 'confirmed', 'future', '[{"source":"spreadsheet","name":"Project Tracker","date":"2026-06-22"}]'::jsonb, '{}'::uuid[], 'bf-004', '{}'::uuid[], '{}'::uuid[], 0.86, 'bf-004')
FROM agent;

WITH agent AS (SELECT id FROM rye.agent_identities WHERE agent_key = 'fixture-service-intake')
SELECT rye.agent_create_candidate(id, 'procedure', 'Starting 2026-08-01, CRM account stage and PM milestone changes should be made in Rye dashboards as record of work.', '{}'::jsonb, ARRAY['systems-adoption'], 'slack:#accounts-beacon', 'process:crm-pm-record-of-work', 'account owner process policy', 'policy_set', 'future', '[{"source":"email","id":"greenridge-status-2026-06-22"}]'::jsonb, '{}'::uuid[], 'bf-005', '{}'::uuid[], '{}'::uuid[], 0.87, 'bf-005')
FROM agent;
