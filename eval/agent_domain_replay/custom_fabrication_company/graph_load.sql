SET search_path = rye, public, pg_catalog;

SELECT rye.ensure_knowledge_domain('quote-pipeline', 'Quote Pipeline', 'Quote stages, values, owners, and customer commitments.');
SELECT rye.ensure_knowledge_domain('engineering-review', 'Engineering Review', 'Drawing readiness, design risk, and engineering approval.');
SELECT rye.ensure_knowledge_domain('production-handoff', 'Production Handoff', 'Traveler packets, production starts, and plant owners.');
SELECT rye.ensure_knowledge_domain('qa-release', 'QA Release', 'QA holds, releases, and rework conditions.');
SELECT rye.ensure_knowledge_domain('fabrication-process', 'Fabrication Process', 'Current and superseded process rules for fabrication work.');

SELECT rye.subscribe_channel_to_domain('slack:#sales-northstar', 'quote-pipeline', 'candidate_write', true);
SELECT rye.subscribe_channel_to_domain('slack:#sales-northstar', 'fabrication-process', 'read', true);
SELECT rye.subscribe_channel_to_domain('slack:#engineering-northstar', 'engineering-review', 'candidate_write', false);
SELECT rye.subscribe_channel_to_domain('slack:#engineering-northstar', 'fabrication-process', 'candidate_write', true);
SELECT rye.subscribe_channel_to_domain('slack:#plant-northstar', 'production-handoff', 'candidate_write', false);
SELECT rye.subscribe_channel_to_domain('slack:#plant-northstar', 'engineering-review', 'read', true);
SELECT rye.subscribe_channel_to_domain('slack:#qa-northstar', 'qa-release', 'candidate_write', false);
SELECT rye.subscribe_channel_to_domain('slack:#qa-northstar', 'production-handoff', 'read', true);

SELECT rye.grant_domain_authority('quote-pipeline', 'person', 'person:mateo-ruiz', ARRAY['quote_stage', 'customer_commitment'], NULL, ARRAY['confirmed']);
SELECT rye.grant_domain_authority('engineering-review', 'person', 'person:avery-cho', ARRAY['drawing_status', 'engineering_risk'], NULL, ARRAY['confirmed', 'policy_set']);
SELECT rye.grant_domain_authority('production-handoff', 'person', 'person:dana-fox', ARRAY['production_start', 'plant_owner'], NULL, ARRAY['confirmed']);
SELECT rye.grant_domain_authority('qa-release', 'person', 'person:lin-park', ARRAY['qa_hold', 'qa_release'], NULL, ARRAY['confirmed']);
SELECT rye.grant_domain_authority('fabrication-process', 'person', 'person:avery-cho', ARRAY['handoff_process'], NULL, ARRAY['policy_set']);

SELECT rye.create_agent_identity('fixture-fabrication-intake', 'Fixture Fabrication Intake Agent', 'replay');
SELECT rye.grant_agent_capability('fixture-fabrication-intake', 'rye.candidate.create', 'quote-pipeline');
SELECT rye.grant_agent_capability('fixture-fabrication-intake', 'rye.candidate.create', 'engineering-review');
SELECT rye.grant_agent_capability('fixture-fabrication-intake', 'rye.candidate.create', 'production-handoff');
SELECT rye.grant_agent_capability('fixture-fabrication-intake', 'rye.candidate.create', 'qa-release');
SELECT rye.grant_agent_capability('fixture-fabrication-intake', 'rye.candidate.create', 'fabrication-process');

WITH agent AS (SELECT id FROM rye.agent_identities WHERE agent_key = 'fixture-fabrication-intake')
SELECT rye.agent_create_candidate(id, 'fact', 'MetroFit quote Q-441 is won at $86,400 after signed PO on 2026-05-22.', '{}'::jsonb, ARRAY['quote-pipeline'], 'slack:#sales-northstar', 'quote:Q-441', 'sales director confirmation', 'confirmed', 'current', '[{"source":"slack","channel":"#sales-northstar","ts":"2026-05-22T13:12:00"}]'::jsonb, '{}'::uuid[], 'nf-001', '{}'::uuid[], '{}'::uuid[], 0.91, 'nf-001')
FROM agent;

WITH agent AS (SELECT id FROM rye.agent_identities WHERE agent_key = 'fixture-fabrication-intake')
SELECT rye.agent_create_candidate(id, 'fact', 'MetroFit drawings rev B are approved for production.', '{}'::jsonb, ARRAY['engineering-review'], 'slack:#engineering-northstar', 'quote:Q-441', 'engineering lead confirmation', 'confirmed', 'current', '[{"source":"slack","channel":"#engineering-northstar","ts":"2026-05-28T15:47:00"}]'::jsonb, '{}'::uuid[], 'nf-002', '{}'::uuid[], '{}'::uuid[], 0.9, 'nf-002')
FROM agent;

WITH agent AS (SELECT id FROM rye.agent_identities WHERE agent_key = 'fixture-fabrication-intake')
SELECT rye.agent_create_candidate(id, 'fact', 'MetroFit traveler packet is complete and production start is 2026-06-12.', '{}'::jsonb, ARRAY['production-handoff'], 'slack:#plant-northstar', 'quote:Q-441', 'plant manager confirmation', 'confirmed', 'current', '[{"source":"slack","channel":"#plant-northstar","ts":"2026-06-10T07:32:00"}]'::jsonb, '{}'::uuid[], 'nf-003', '{}'::uuid[], '{}'::uuid[], 0.89, 'nf-003')
FROM agent;

WITH agent AS (SELECT id FROM rye.agent_identities WHERE agent_key = 'fixture-fabrication-intake')
SELECT rye.agent_create_candidate(id, 'fact', 'MetroFit QA hold was released on 2026-06-16 after recoat.', '{}'::jsonb, ARRAY['qa-release'], 'slack:#qa-northstar', 'quote:Q-441', 'QA lead confirmation', 'confirmed', 'current', '[{"source":"slack","channel":"#qa-northstar","ts":"2026-06-16T14:40:00"}]'::jsonb, '{}'::uuid[], 'nf-004', '{}'::uuid[], '{}'::uuid[], 0.88, 'nf-004')
FROM agent;

WITH agent AS (SELECT id FROM rye.agent_identities WHERE agent_key = 'fixture-fabrication-intake')
SELECT rye.agent_create_candidate(id, 'procedure', 'Quotes Master spreadsheet handoff is superseded for new won jobs after 2026-06-10.', '{}'::jsonb, ARRAY['fabrication-process'], 'slack:#engineering-northstar', 'process:quote-handoff', 'engineering process policy', 'policy_set', 'superseded', '[{"source":"slack","channel":"#engineering-northstar","ts":"2026-06-09T09:05:00"}]'::jsonb, '{}'::uuid[], 'nf-005', '{}'::uuid[], '{}'::uuid[], 0.84, 'nf-005')
FROM agent;

WITH agent AS (SELECT id FROM rye.agent_identities WHERE agent_key = 'fixture-fabrication-intake')
SELECT rye.agent_create_candidate(id, 'fact', 'Harbor Foods Q-455 remains in pricing review with no customer commitment.', '{}'::jsonb, ARRAY['quote-pipeline'], 'slack:#sales-northstar', 'quote:Q-455', 'sales director confirmation', 'confirmed', 'current', '[{"source":"slack","channel":"#sales-northstar","ts":"2026-06-18T10:05:00"}]'::jsonb, '{}'::uuid[], 'nf-006', '{}'::uuid[], '{}'::uuid[], 0.87, 'nf-006')
FROM agent;
