#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required for API security tests}"

# The admin API server is a Node app; inside the postgres test container there
# is no node/npm, so skip there — docker-test.sh re-runs this test from the host.
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "SKIP: node/npm not available; skipping API security test"
  exit 0
fi

pick_port() {
  node -e "const net = require('node:net'); const server = net.createServer(); server.listen(0, '127.0.0.1', () => { console.log(server.address().port); server.close(); });"
}

PORT="${RYE_API_SECURITY_TEST_PORT:-$(pick_port)}"
# Unique per run: idempotency keys persist in the database, so a reused key
# from a prior run would return that run's (already promoted) candidate.
IDEM_KEY="api-security-idem-$(date +%s)-$$"
BASE_URL="http://127.0.0.1:${PORT}"
LOG_FILE="${TMPDIR:-/tmp}/rye-api-security-${PORT}.log"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

json_get() {
  node -e "const obj = JSON.parse(process.argv[1]); const path = process.argv[2].split('.'); let cur = obj; for (const key of path) cur = cur?.[key]; if (cur === undefined || cur === null) process.exit(2); if (typeof cur === 'object') console.log(JSON.stringify(cur)); else console.log(cur);" "$1" "$2"
}

status_code() {
  curl -s -o /dev/null -w "%{http_code}" "$@"
}

seed_sql="$(cat <<'SQL'
SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false);
SELECT rye.ensure_knowledge_domain(
  'api-account-updates',
  'API Test Account Updates',
  'Shared account updates for API security tests.',
  NULL,
  '{"secret_internal_note":"should be redacted from low privilege API clients"}'::jsonb
);
SELECT rye.create_agent_identity('api-candidate-agent', 'API Candidate Agent', 'conformance');
SELECT rye.create_agent_identity('api-reviewer-agent', 'API Reviewer Agent', 'conformance');
SELECT rye.grant_agent_capability('api-candidate-agent', 'rye.context.read', 'api-account-updates');
SELECT rye.grant_agent_capability('api-candidate-agent', 'rye.candidate.create', 'api-account-updates');
SELECT rye.grant_agent_capability('api-reviewer-agent', 'rye.context.read', 'api-account-updates');
SELECT rye.grant_agent_capability('api-reviewer-agent', 'rye.review.read', 'api-account-updates');
SELECT rye.grant_agent_capability('api-reviewer-agent', 'rye.candidate.adjudicate', 'api-account-updates');
SELECT rye.grant_agent_capability('api-reviewer-agent', 'rye.authoritative.promote', 'api-account-updates');
SELECT rye.grant_agent_capability('api-reviewer-agent', 'rye.audit.read', NULL);
INSERT INTO rye.nodes (node_type, label, properties)
VALUES ('account', 'API Security Test Account', '{"suite":"api_security"}')
RETURNING id;
SQL
)"

subject_id="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<<"$seed_sql" | tail -n 1)"
candidate_token="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<'SQL'
SET search_path = rye, public, pg_catalog;
SELECT rye.issue_agent_token('api-candidate-agent', 'api security candidate token');
SQL
)"
reviewer_token="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<'SQL'
SET search_path = rye, public, pg_catalog;
SELECT rye.issue_agent_token('api-reviewer-agent', 'api security reviewer token');
SQL
)"

RYE_INSTANCES="[{\"id\":\"api-security\",\"label\":\"API Security\",\"databaseUrl\":\"${DATABASE_URL}\"}]" \
DEFAULT_INSTANCE="api-security" \
RYE_API_AUTH_MODE="required" \
RYE_ADMIN_API_PORT="$PORT" \
npm --prefix admin run dev:api >"$LOG_FILE" 2>&1 &
SERVER_PID=$!

for _ in {1..80}; do
  if [[ "$(status_code "${BASE_URL}/api/health")" == "200" ]]; then
    break
  fi
  sleep 0.25
done

if [[ "$(status_code "${BASE_URL}/api/health")" != "200" ]]; then
  echo "API server did not start. Log follows:" >&2
  cat "$LOG_FILE" >&2
  exit 1
fi

missing_status="$(status_code "${BASE_URL}/api/domains")"
[[ "$missing_status" == "401" ]] || { echo "Expected missing token 401, got $missing_status" >&2; exit 1; }

invalid_status="$(status_code -H "Authorization: Bearer not-a-real-token" "${BASE_URL}/api/domains")"
[[ "$invalid_status" == "401" ]] || { echo "Expected invalid token 401, got $invalid_status" >&2; exit 1; }

admin_only_routes=(
  "/api/catalog"
  "/api/dashboard"
  "/api/knowledge-map"
  "/api/workspace/crm"
  "/api/workspace/pm"
  "/api/nodes"
  "/api/nodes/${subject_id}"
  "/api/nodes/${subject_id}/knowledge"
  "/api/nodes/${subject_id}/graph"
  "/api/disputes"
  "/api/events"
)

for route in "${admin_only_routes[@]}"; do
  route_status="$(status_code -H "Authorization: Bearer ${candidate_token}" "${BASE_URL}${route}")"
  [[ "$route_status" == "403" ]] || {
    echo "Expected candidate token to be denied from admin route ${route}, got ${route_status}" >&2
    exit 1
  }
done

reviewer_admin_status="$(status_code -H "Authorization: Bearer ${reviewer_token}" "${BASE_URL}/api/nodes")"
[[ "$reviewer_admin_status" == "403" ]] || {
  echo "Expected reviewer agent token to be denied from admin node search, got ${reviewer_admin_status}" >&2
  exit 1
}

domains_json="$(curl -sS -H "Authorization: Bearer ${candidate_token}" "${BASE_URL}/api/domains")"
if [[ "$domains_json" == *"secret_internal_note"* ]]; then
  echo "Low-privilege domain response exposed restricted properties" >&2
  echo "$domains_json" >&2
  exit 1
fi

candidate_body='{
  "candidate_kind":"fact",
  "statement":"Brightline account health is green per account owner confirmation.",
  "domain_keys":["api-account-updates"],
  "source_scope":"slack:#api-sales",
  "impact_scope":"account:brightline",
  "authority_basis":"account owner explicit confirmation",
  "speech_act":"confirmed",
  "current_or_future":"current",
  "evidence_refs":[{"source":"slack","id":"api-security-001"}],
  "confidence":0.82
}'

candidate_json_1="$(curl -sS \
  -H "Authorization: Bearer ${candidate_token}" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: ${IDEM_KEY}" \
  -d "$candidate_body" \
  "${BASE_URL}/api/candidates")"
candidate_id_1="$(json_get "$candidate_json_1" "id")"

candidate_json_2="$(curl -sS \
  -H "Authorization: Bearer ${candidate_token}" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: ${IDEM_KEY}" \
  -d "$candidate_body" \
  "${BASE_URL}/api/candidates")"
candidate_id_2="$(json_get "$candidate_json_2" "id")"

[[ "$candidate_id_1" == "$candidate_id_2" ]] || {
  echo "Expected idempotent candidate id, got $candidate_id_1 and $candidate_id_2" >&2
  exit 1
}

denied_candidate_status="$(status_code \
  -H "Authorization: Bearer ${candidate_token}" \
  -H "Content-Type: application/json" \
  -d '{"candidate_kind":"fact","statement":"Title work is complete.","domain_keys":["api-title-diligence"]}' \
  "${BASE_URL}/api/candidates")"
[[ "$denied_candidate_status" == "403" ]] || {
  echo "Expected ungranted candidate domain 403, got $denied_candidate_status" >&2
  exit 1
}

promote_body="$(cat <<JSON
{
  "target_type":"assertion",
  "subject_node_id":"${subject_id}",
  "assertion_type":"account_health",
  "assertion_key":"default",
  "claim":{"health":"green","source":"api-security-test"},
  "confidence":0.9
}
JSON
)"

candidate_promote_status="$(status_code \
  -H "Authorization: Bearer ${candidate_token}" \
  -H "Content-Type: application/json" \
  -d "$promote_body" \
  "${BASE_URL}/api/candidates/${candidate_id_1}/promote")"
[[ "$candidate_promote_status" == "403" ]] || {
  echo "Expected candidate token promotion 403, got $candidate_promote_status" >&2
  exit 1
}

reviewer_promote_status="$(status_code \
  -H "Authorization: Bearer ${reviewer_token}" \
  -H "Content-Type: application/json" \
  -d "$promote_body" \
  "${BASE_URL}/api/candidates/${candidate_id_1}/promote")"
[[ "$reviewer_promote_status" == "200" ]] || {
  echo "Expected reviewer promotion 200, got $reviewer_promote_status" >&2
  curl -sS -H "Authorization: Bearer ${reviewer_token}" "${BASE_URL}/api/audit/actions?limit=10" >&2 || true
  exit 1
}

audit_denied_status="$(status_code -H "Authorization: Bearer ${candidate_token}" "${BASE_URL}/api/audit/actions")"
[[ "$audit_denied_status" == "403" ]] || {
  echo "Expected low-privilege audit read 403, got $audit_denied_status" >&2
  exit 1
}

audit_json="$(curl -sS -H "Authorization: Bearer ${reviewer_token}" "${BASE_URL}/api/audit/actions?limit=20")"
if [[ "$audit_json" != *"candidate_promote"* || "$audit_json" != *"false"* || "$audit_json" != *"true"* ]]; then
  echo "Expected audit log to include allowed and denied promotion actions" >&2
  echo "$audit_json" >&2
  exit 1
fi

candidate_token_id="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<SQL
SET search_path = rye, public, pg_catalog;
WITH cfg AS (SELECT set_config('app.current_role', 'admin', false))
SELECT id
FROM rye.agent_api_tokens, cfg
WHERE token_hash = encode(digest('${candidate_token}', 'sha256'), 'hex')
LIMIT 1;
SQL
)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<SQL >/dev/null
SET search_path = rye, public, pg_catalog;
SELECT rye.revoke_agent_token('${candidate_token_id}'::uuid, 'api-security-test');
SQL

revoked_status="$(status_code -H "Authorization: Bearer ${candidate_token}" "${BASE_URL}/api/domains")"
[[ "$revoked_status" == "401" ]] || {
  echo "Expected revoked token API request 401, got $revoked_status" >&2
  exit 1
}

echo "API security test passed"
