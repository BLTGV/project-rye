SET search_path = rye, public, pg_catalog;

SELECT rye.ensure_knowledge_domain('acquisition-pipeline', 'Acquisition Pipeline', 'Deal stages, owners, next actions, and close timing.');
SELECT rye.ensure_knowledge_domain('account-updates', 'Account Updates', 'Seller, owner, and account health updates shared across channels.');
SELECT rye.ensure_knowledge_domain('title-diligence', 'Title Diligence', 'Title status, title defects, and curative work.');
SELECT rye.ensure_knowledge_domain('closing-funding', 'Closing Funding', 'Funding readiness, wire verification, and closing finance steps.');
SELECT rye.ensure_knowledge_domain('deal-process', 'Deal Process', 'Current and planned process rules for deal execution.');

SELECT rye.subscribe_channel_to_domain('slack:#deals-redtail', 'acquisition-pipeline', 'candidate_write', true);
SELECT rye.subscribe_channel_to_domain('slack:#deals-redtail', 'account-updates', 'candidate_write', true);
SELECT rye.subscribe_channel_to_domain('slack:#deals-redtail', 'deal-process', 'read', true);
SELECT rye.subscribe_channel_to_domain('slack:#title-redtail', 'title-diligence', 'candidate_write', false);
SELECT rye.subscribe_channel_to_domain('slack:#title-redtail', 'account-updates', 'read', true);
SELECT rye.subscribe_channel_to_domain('slack:#title-redtail', 'deal-process', 'candidate_write', true);
SELECT rye.subscribe_channel_to_domain('slack:#finance-redtail', 'closing-funding', 'candidate_write', false);
SELECT rye.subscribe_channel_to_domain('slack:#finance-redtail', 'acquisition-pipeline', 'read', true);
SELECT rye.subscribe_channel_to_domain('slack:#finance-redtail', 'account-updates', 'read', true);

SELECT rye.grant_domain_authority('acquisition-pipeline', 'person', 'person:nora-quinn', ARRAY['stage', 'owner', 'next_action'], NULL, ARRAY['confirmed']);
SELECT rye.grant_domain_authority('account-updates', 'person', 'person:nora-quinn', ARRAY['seller', 'account_health'], NULL, ARRAY['confirmed']);
SELECT rye.grant_domain_authority('title-diligence', 'person', 'person:eli-hart', ARRAY['title_status', 'curative_owner', 'process'], NULL, ARRAY['confirmed', 'policy_set']);
SELECT rye.grant_domain_authority('closing-funding', 'person', 'person:priya-shah', ARRAY['funding_status', 'wire_verification'], NULL, ARRAY['confirmed']);
SELECT rye.grant_domain_authority('deal-process', 'person', 'person:eli-hart', ARRAY['title_exception_process'], NULL, ARRAY['policy_set']);

SELECT rye.create_agent_identity('fixture-mineral-intake', 'Fixture Mineral Intake Agent', 'replay');
SELECT rye.grant_agent_capability('fixture-mineral-intake', 'rye.candidate.create', 'acquisition-pipeline');
SELECT rye.grant_agent_capability('fixture-mineral-intake', 'rye.candidate.create', 'title-diligence');
SELECT rye.grant_agent_capability('fixture-mineral-intake', 'rye.candidate.create', 'closing-funding');
SELECT rye.grant_agent_capability('fixture-mineral-intake', 'rye.candidate.create', 'deal-process');

WITH agent AS (
  SELECT id FROM rye.agent_identities WHERE agent_key = 'fixture-mineral-intake'
)
SELECT rye.agent_create_candidate(id, 'fact', 'Iron Creek is ready to close with target close 2026-06-28.', '{}'::jsonb, ARRAY['acquisition-pipeline'], 'slack:#deals-redtail', 'opportunity:iron-creek', 'deal lead confirmation', 'confirmed', 'current', '[{"source":"slack","channel":"#deals-redtail","ts":"2026-06-25T13:17:00"}]'::jsonb, '{}'::uuid[], 'rm-001', '{}'::uuid[], '{}'::uuid[], 0.9, 'rm-001')
FROM agent;

WITH agent AS (
  SELECT id FROM rye.agent_identities WHERE agent_key = 'fixture-mineral-intake'
)
SELECT rye.agent_create_candidate(id, 'fact', 'Iron Creek title is clear for closing as of 2026-06-24.', '{}'::jsonb, ARRAY['title-diligence'], 'slack:#title-redtail', 'opportunity:iron-creek', 'title lead confirmation', 'confirmed', 'current', '[{"source":"slack","channel":"#title-redtail","ts":"2026-06-24T17:31:00"}]'::jsonb, '{}'::uuid[], 'rm-002', '{}'::uuid[], '{}'::uuid[], 0.92, 'rm-002')
FROM agent;

WITH agent AS (
  SELECT id FROM rye.agent_identities WHERE agent_key = 'fixture-mineral-intake'
)
SELECT rye.agent_create_candidate(id, 'fact', 'Iron Creek funds are ready and wire instructions were verified by callback.', '{}'::jsonb, ARRAY['closing-funding'], 'slack:#finance-redtail', 'opportunity:iron-creek', 'finance lead confirmation', 'confirmed', 'current', '[{"source":"slack","channel":"#finance-redtail","ts":"2026-06-25T12:03:00"}]'::jsonb, '{}'::uuid[], 'rm-003', '{}'::uuid[], '{}'::uuid[], 0.91, 'rm-003')
FROM agent;

WITH agent AS (
  SELECT id FROM rye.agent_identities WHERE agent_key = 'fixture-mineral-intake'
)
SELECT rye.agent_create_candidate(id, 'fact', 'Falcon Mesa is in nurture and should not be treated as active closing.', '{}'::jsonb, ARRAY['acquisition-pipeline'], 'slack:#deals-redtail', 'opportunity:falcon-mesa', 'deal lead confirmation', 'confirmed', 'current', '[{"source":"slack","channel":"#deals-redtail","ts":"2026-06-03T10:40:00"}]'::jsonb, '{}'::uuid[], 'rm-004', '{}'::uuid[], '{}'::uuid[], 0.85, 'rm-004')
FROM agent;

WITH agent AS (
  SELECT id FROM rye.agent_identities WHERE agent_key = 'fixture-mineral-intake'
)
SELECT rye.agent_create_candidate(id, 'procedure', 'Starting 2026-07-15, new title exceptions must be logged in the Title Queue table before Slack discussion.', '{}'::jsonb, ARRAY['deal-process'], 'slack:#title-redtail', 'process:title-exceptions', 'title lead process change', 'policy_set', 'future', '[{"source":"slack","channel":"#title-redtail","ts":"2026-06-25T09:30:00"}]'::jsonb, '{}'::uuid[], 'rm-005', '{}'::uuid[], '{}'::uuid[], 0.88, 'rm-005')
FROM agent;
