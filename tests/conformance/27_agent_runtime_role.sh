#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required for agent runtime role tests}"

is_superuser="$(psql "$DATABASE_URL" -Atqc "SELECT rolsuper FROM pg_roles WHERE rolname = current_user")"
if [[ "$is_superuser" != "t" ]]; then
  echo "SKIP: runtime role privilege test requires role administration"
  exit 0
fi

RUNTIME_ROLE="rye_runtime_boundary_test"

cleanup() {
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null 2>&1 || true
DROP OWNED BY ${RUNTIME_ROLE};
DROP ROLE IF EXISTS ${RUNTIME_ROLE};
SQL
}
trap cleanup EXIT

cleanup

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
CREATE ROLE ${RUNTIME_ROLE};
SQL

seed_output="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<'SQL'
SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false);
SELECT set_config('app.current_user_id', 'test:agent-runtime-role', false);
SELECT rye.ensure_knowledge_domain('runtime-role-a', 'Runtime Role A', 'Allowed runtime role domain.');
SELECT rye.ensure_knowledge_domain('runtime-role-b', 'Runtime Role B', 'Foreign runtime role domain.');
INSERT INTO rye.field_classifications (node_type, field_path, classification, min_role)
VALUES ('runtime_role_account', 'properties.secret_note', 'confidential', 'manager')
ON CONFLICT (node_type, field_path)
DO UPDATE SET classification = EXCLUDED.classification, min_role = EXCLUDED.min_role;

WITH inserted AS (
  INSERT INTO rye.nodes (node_type, label, external_source, external_id, properties)
  VALUES (
    'runtime_role_account',
    'Runtime Role Visible',
    'conformance',
    'runtime-role-visible',
    '{"public_note":"visible","secret_note":"runtime secret"}'::jsonb
  )
  ON CONFLICT DO NOTHING
  RETURNING id
)
SELECT count(*) FROM inserted;

WITH inserted AS (
  INSERT INTO rye.nodes (node_type, label, external_source, external_id, properties)
  VALUES (
    'runtime_role_account',
    'Runtime Role Mixed',
    'conformance',
    'runtime-role-mixed',
    '{"public_note":"mixed"}'::jsonb
  )
  ON CONFLICT DO NOTHING
  RETURNING id
)
SELECT count(*) FROM inserted;

DO $$
DECLARE
  v_visible uuid;
  v_mixed uuid;
  v_event uuid;
BEGIN
  SELECT id INTO v_visible FROM rye.nodes WHERE external_source = 'conformance' AND external_id = 'runtime-role-visible';
  SELECT id INTO v_mixed FROM rye.nodes WHERE external_source = 'conformance' AND external_id = 'runtime-role-mixed';
  v_event := rye.record_event(
    p_event_type        := 'runtime_role_membership_confirmed',
    p_summary           := 'Runtime role memberships confirmed',
    p_participant_ids   := ARRAY[v_visible, v_mixed],
    p_participant_roles := ARRAY['subject', 'subject'],
    p_actor             := 'test:agent-runtime-role'
  );
  PERFORM rye.assign_node_domain_membership(v_visible, 'runtime-role-a', v_event);
  PERFORM rye.assign_node_domain_membership(v_mixed, 'runtime-role-a', v_event);
  PERFORM rye.assign_node_domain_membership(v_mixed, 'runtime-role-b', v_event);
END;
$$;

SELECT rye.create_agent_identity('runtime-role-agent', 'Runtime Role Agent', 'conformance');
SELECT rye.grant_agent_capability('runtime-role-agent', 'rye.context.read', 'runtime-role-a');
SELECT rye.grant_agent_capability('runtime-role-agent', 'rye.candidate.create', 'runtime-role-a');
SELECT rye.grant_agent_capability('runtime-role-agent', 'rye.observation.create', 'runtime-role-a');
SELECT rye.grant_agent_capability('runtime-role-agent', 'rye.review.read', 'runtime-role-a');
SELECT rye.grant_agent_capability('runtime-role-agent', 'rye.candidate.adjudicate', 'runtime-role-a');
SELECT rye.grant_agent_capability('runtime-role-agent', 'rye.authoritative.promote', 'runtime-role-a');
SELECT rye.issue_agent_token('runtime-role-agent', 'runtime role token');
SQL
)"
token="$(tail -n 1 <<<"$seed_output")"

./scripts/grant_agent_runtime.sh --db-url "$DATABASE_URL" --role "$RUNTIME_ROLE" >/dev/null

privileges="$(psql "$DATABASE_URL" -Atq <<SQL
SELECT has_function_privilege(
  '${RUNTIME_ROLE}',
  'rye.agent_search_nodes_with_token(text,text,text[],text,integer)',
  'EXECUTE'
);
SELECT has_function_privilege(
  '${RUNTIME_ROLE}',
  'rye.agent_get_context_pack(uuid,text,text,text[])',
  'EXECUTE'
);
SELECT has_function_privilege(
  '${RUNTIME_ROLE}',
  'rye.agent_promote_candidate_with_token(text,uuid,jsonb)',
  'EXECUTE'
);
SQL
)"
[[ "$privileges" == $'t\nf\nt' ]] || {
  echo "Runtime role received an unexpected function privilege set: $privileges" >&2
  exit 1
}

if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null 2>&1
SET ROLE ${RUNTIME_ROLE};
SELECT * FROM rye.nodes LIMIT 1;
SQL
then
  echo "Runtime role unexpectedly read Rye tables directly" >&2
  exit 1
fi

if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null 2>&1
SET ROLE ${RUNTIME_ROLE};
SELECT rye.agent_get_context_pack(
  (SELECT id FROM rye.agent_identities WHERE agent_key = 'runtime_role_agent'),
  NULL,
  NULL,
  ARRAY['runtime-role-a']
);
SQL
then
  echo "Runtime role unexpectedly called raw identity-taking helper" >&2
  exit 1
fi

search_json="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq -v token="$token" <<SQL
SET ROLE ${RUNTIME_ROLE};
SELECT rye.agent_search_nodes_with_token(
  :'token',
  'Runtime Role',
  ARRAY['runtime-role-a'],
  NULL,
  20
);
SQL
)"

if [[ "$search_json" != *"Runtime Role Visible"* || "$search_json" == *"Runtime Role Mixed"* || "$search_json" == *"runtime secret"* ]]; then
  echo "Runtime role search crossed domain or classification boundaries" >&2
  echo "$search_json" >&2
  exit 1
fi

candidate_id="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq -v token="$token" <<'SQL'
SET ROLE rye_runtime_boundary_test;
SELECT rye.agent_create_candidate_with_token(
  :'token',
  '{
    "candidate_kind":"fact",
    "statement":"Runtime role candidate remains bounded.",
    "domain_keys":["runtime-role-a"],
    "source_scope":"runtime:role-test",
    "evidence_refs":[{"source":"test","id":"runtime-role-candidate"}]
  }'::jsonb,
  'runtime-role-candidate-1'
);
SQL
)"

review_json="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq -v token="$token" <<'SQL'
SET ROLE rye_runtime_boundary_test;
SELECT rye.agent_review_queue_with_token(
  :'token', NULL, NULL, 'Runtime role candidate remains bounded.', false, 20, 0
);
SQL
)"

[[ "$review_json" == *"Runtime role candidate remains bounded."* ]] || {
  echo "Token-bound review queue omitted the scoped candidate" >&2
  echo "$review_json" >&2
  exit 1
}

visible_node_id="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<'SQL'
SELECT set_config('app.current_role', 'admin', false);
SELECT id FROM rye.nodes
WHERE external_source = 'conformance' AND external_id = 'runtime-role-visible';
SQL
)"
visible_node_id="$(tail -n 1 <<<"$visible_node_id")"

promotion_json="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq \
  -v token="$token" -v candidate_id="$candidate_id" -v subject_id="$visible_node_id" <<'SQL'
SET ROLE rye_runtime_boundary_test;
SELECT rye.agent_promote_candidate_with_token(
  :'token',
  :'candidate_id'::uuid,
  jsonb_build_object(
    'target_type', 'assertion',
    'subject_node_id', :'subject_id',
    'assertion_type', 'runtime_reviewed_status',
    'assertion_key', 'default',
    'claim', jsonb_build_object('status', 'accepted')
  )
);
SQL
)"

[[ "$promotion_json" == *'"target_type": "assertion"'* || "$promotion_json" == *'"target_type":"assertion"'* ]] || {
  echo "Token-bound reviewer promotion failed: $promotion_json" >&2
  exit 1
}

membership_output="$(psql "$DATABASE_URL" -Atq <<SQL
SELECT set_config('app.current_role', 'admin', false);
SELECT count(*)
FROM rye.node_domain_memberships membership
JOIN rye.knowledge_domains domain_row ON domain_row.id = membership.domain_id
WHERE membership.node_id = '${candidate_id}'::uuid
  AND domain_row.domain_key = rye.rye_slugify_key('runtime-role-a')
  AND membership.source_event_id IS NOT NULL;
SQL
)"
membership_count="$(tail -n 1 <<<"$membership_output")"

[[ "$membership_count" == "1" ]] || {
  echo "Token-bound candidate did not receive sourced domain membership" >&2
  exit 1
}

echo "Agent runtime role boundary test passed"
