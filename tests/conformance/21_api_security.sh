#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required for API security tests}"

# The admin API server is a Node app; inside the postgres test container there
# is no node/npm, so skip there — docker-test.sh re-runs this test from the host.
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "SKIP: node/npm not available; skipping API security test"
  exit 0
fi

# The deny-by-default decision is pure and needs no database, so check every
# branch of it first — including the ones no production route can reach over
# HTTP, such as a route the Worker serves that the policy table does not
# declare. Runs standalone as: cd admin && npm run check:routes
npm --prefix admin run --silent check:routes

pick_port() {
  node -e "const net = require('node:net'); const server = net.createServer(); server.listen(0, '127.0.0.1', () => { console.log(server.address().port); server.close(); });"
}

PORT="${RYE_API_SECURITY_TEST_PORT:-$(pick_port)}"
OPEN_PORT="$(pick_port)"
# Unique per run: idempotency keys persist in the database, so a reused key
# from a prior run would return that run's (already promoted) candidate.
IDEM_KEY="api-security-idem-$(date +%s)-$$"
BASE_URL="http://127.0.0.1:${PORT}"
OPEN_URL="http://127.0.0.1:${OPEN_PORT}"
LOG_FILE="${TMPDIR:-/tmp}/rye-api-security-${PORT}.log"
OPEN_LOG_FILE="${TMPDIR:-/tmp}/rye-api-security-open-${OPEN_PORT}.log"

cleanup() {
  for pid in "${SERVER_PID:-}" "${OPEN_SERVER_PID:-}"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup EXIT

json_get() {
  node -e "const obj = JSON.parse(process.argv[1]); const path = process.argv[2].split('.'); let cur = obj; for (const key of path) cur = cur?.[key]; if (cur === undefined) process.exit(2); if (cur === null) { console.log('null'); } else if (typeof cur === 'object') { console.log(JSON.stringify(cur)); } else { console.log(cur); }" "$1" "$2"
}

status_code() {
  curl -s -o /dev/null -w "%{http_code}" "$@"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# expect_status <description> <expected> <curl args...>
expect_status() {
  local desc="$1" expected="$2"
  shift 2
  local got
  got="$(status_code "$@")"
  [[ "$got" == "$expected" ]] || fail "$desc — expected $expected, got $got"
}

# expect_field <description> <json> <path> <expected>
expect_field() {
  local desc="$1" body="$2" path="$3" expected="$4"
  local got
  got="$(json_get "$body" "$path" || true)"
  [[ "$got" == "$expected" ]] || fail "$desc — expected $path = '$expected', got '$got'"
}

# expect_absent <description> <haystack> <needle>
expect_absent() {
  local desc="$1" body="$2" needle="$3"
  if [[ "$body" == *"$needle"* ]]; then
    echo "$body" >&2
    fail "$desc — response contained '$needle'"
  fi
}

# expect_present <description> <haystack> <needle>
expect_present() {
  local desc="$1" body="$2" needle="$3"
  if [[ "$body" != *"$needle"* ]]; then
    echo "$body" >&2
    fail "$desc — response did not contain '$needle'"
  fi
}

seed_sql="$(cat <<'SQL'
SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false);

-- Two areas. Every agent below holds a grant on at most one of them, so any
-- row from the other area appearing in a response is a cross-area leak.
SELECT rye.ensure_knowledge_domain(
  'api-account-updates',
  'API Test Account Updates',
  'Shared account updates for API security tests.',
  NULL,
  '{"secret_internal_note":"should be redacted from low privilege API clients"}'::jsonb
);
SELECT rye.ensure_knowledge_domain(
  'api-title-diligence',
  'API Test Title Diligence',
  'Separate area for API security cross-area tests.',
  NULL,
  '{}'::jsonb
);

-- Distinctive authority and channel markers. A token that does not hold an
-- area must never see that area's marker in any response.
SELECT rye.grant_domain_authority(
  'api-account-updates', 'role', 'api-account-authority-marker', ARRAY['account_health']
);
SELECT rye.grant_domain_authority(
  'api-title-diligence', 'role', 'api-title-authority-marker', ARRAY['title_status']
);
SELECT rye.subscribe_channel_to_domain('slack:#api-account-marker', 'api-account-updates', 'review');
SELECT rye.subscribe_channel_to_domain('slack:#api-title-marker', 'api-title-diligence', 'review');

SELECT rye.create_agent_identity('api-candidate-agent', 'API Candidate Agent', 'conformance');
SELECT rye.create_agent_identity('api-reviewer-agent', 'API Reviewer Agent', 'conformance');
SELECT rye.create_agent_identity('api-title-agent', 'API Title Agent', 'conformance');
SELECT rye.create_agent_identity('api-nograntee-agent', 'API No Grant Agent', 'conformance');

SELECT rye.grant_agent_capability('api-candidate-agent', 'rye.context.read', 'api-account-updates');
SELECT rye.grant_agent_capability('api-candidate-agent', 'rye.candidate.create', 'api-account-updates');
SELECT rye.grant_agent_capability('api-candidate-agent', 'rye.observation.create', 'api-account-updates');
SELECT rye.grant_agent_capability('api-reviewer-agent', 'rye.context.read', 'api-account-updates');
SELECT rye.grant_agent_capability('api-reviewer-agent', 'rye.review.read', 'api-account-updates');
SELECT rye.grant_agent_capability('api-reviewer-agent', 'rye.candidate.adjudicate', 'api-account-updates');
SELECT rye.grant_agent_capability('api-reviewer-agent', 'rye.authoritative.promote', 'api-account-updates');
SELECT rye.grant_agent_capability('api-reviewer-agent', 'rye.audit.read', NULL);

-- Holds the same read capabilities, but only in the other area.
SELECT rye.grant_agent_capability('api-title-agent', 'rye.context.read', 'api-title-diligence');
SELECT rye.grant_agent_capability('api-title-agent', 'rye.review.read', 'api-title-diligence');

-- api-nograntee-agent gets no grants at all: it proves deny by default.

-- A candidate that carries no area keys. Only a grant naming no area sees it.
SELECT rye.create_knowledge_candidate(
  'decision',
  'API security keyless candidate marker.',
  '{}'::jsonb
);

-- A candidate whose area keys are all unsluggable. has_agent_capability drops
-- such keys, so a filter that counted array length instead of testing the keys
-- would hand this row to every rye.review.read holder. It is keyless.
SELECT rye.create_knowledge_candidate(
  'decision',
  'API security unsluggable key candidate marker.',
  '{"domain_keys":["","--"]}'::jsonb
);

-- Mixed arrays: a junk key beside a real one. The junk key must neither hide a
-- held area nor reveal an unheld one. Area keys are stored slugified, which is
-- what rye_slugify_key makes of the hyphenated form used everywhere else here.
SELECT rye.create_knowledge_candidate(
  'decision',
  'API security mixedheldmarker candidate.',
  '{"domain_keys":["","api_account_updates"]}'::jsonb
);
SELECT rye.create_knowledge_candidate(
  'decision',
  'API security mixedunheldmarker candidate.',
  '{"domain_keys":["--","api_title_diligence"]}'::jsonb
);

INSERT INTO rye.nodes (node_type, label, properties)
VALUES ('account', 'API Security Test Account', '{"suite":"api_security"}')
RETURNING id;
SQL
)"

subject_id="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<<"$seed_sql" | tail -n 1)"

issue_token() {
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<SQL
SET search_path = rye, public, pg_catalog;
SELECT rye.issue_agent_token('$1', '$2'${3:+, $3});
SQL
}

candidate_token="$(issue_token api-candidate-agent 'api security candidate token')"
reviewer_token="$(issue_token api-reviewer-agent 'api security reviewer token')"
title_token="$(issue_token api-title-agent 'api security title token')"
nogrant_token="$(issue_token api-nograntee-agent 'api security no-grant token')"
expired_token="$(issue_token api-reviewer-agent 'api security expired token' "now() - interval '1 hour'")"

RYE_INSTANCES="[{\"id\":\"api-security\",\"label\":\"API Security\",\"databaseUrl\":\"${DATABASE_URL}\"}]" \
DEFAULT_INSTANCE="api-security" \
RYE_API_AUTH_MODE="required" \
RYE_ADMIN_API_PORT="$PORT" \
npm --prefix admin run dev:api >"$LOG_FILE" 2>&1 &
SERVER_PID=$!

# A second server with auth mode off, standing in for the reviewer's screen.
RYE_INSTANCES="[{\"id\":\"api-security\",\"label\":\"API Security\",\"databaseUrl\":\"${DATABASE_URL}\"}]" \
DEFAULT_INSTANCE="api-security" \
RYE_API_AUTH_MODE="off" \
RYE_ADMIN_API_PORT="$OPEN_PORT" \
npm --prefix admin run dev:api >"$OPEN_LOG_FILE" 2>&1 &
OPEN_SERVER_PID=$!

wait_for_server() {
  local url="$1" log="$2"
  for _ in {1..80}; do
    if [[ "$(status_code "${url}/api/health")" == "200" ]]; then
      return 0
    fi
    sleep 0.25
  done
  echo "API server at $url did not start. Log follows:" >&2
  cat "$log" >&2
  exit 1
}

wait_for_server "$BASE_URL" "$LOG_FILE"
wait_for_server "$OPEN_URL" "$OPEN_LOG_FILE"

auth() { printf 'Authorization: Bearer %s' "$1"; }

# ---------------------------------------------------------------------------
# 401: the API does not know who is calling.
# ---------------------------------------------------------------------------

expect_status "missing token" 401 "${BASE_URL}/api/domains"
expect_status "unknown token" 401 -H "Authorization: Bearer not-a-real-token" "${BASE_URL}/api/domains"
expect_status "expired token" 401 -H "$(auth "$expired_token")" "${BASE_URL}/api/domains"

missing_body="$(curl -sS "${BASE_URL}/api/domains")"
expect_field "missing token error" "$missing_body" "error" "missing bearer token"
invalid_body="$(curl -sS -H "Authorization: Bearer not-a-real-token" "${BASE_URL}/api/domains")"
expect_field "unknown token error" "$invalid_body" "error" "invalid bearer token"
expired_body="$(curl -sS -H "$(auth "$expired_token")" "${BASE_URL}/api/domains")"
expect_field "expired token error" "$expired_body" "error" "invalid bearer token"

# The two open routes take no token at all.
expect_status "health without token" 200 "${BASE_URL}/api/health"
expect_status "instances without token" 200 "${BASE_URL}/api/instances"

# /api/agent/me takes any valid token and reports only the caller.
me_body="$(curl -sS -H "$(auth "$nogrant_token")" "${BASE_URL}/api/agent/me")"
expect_field "agent/me auth_required" "$me_body" "auth_required" "true"
expect_field "agent/me identity" "$me_body" "agent.agent_key" "api_nograntee_agent"
expect_status "agent/me without token" 401 "${BASE_URL}/api/agent/me"

# ---------------------------------------------------------------------------
# Deny by default: a token with no rye.context.read reaches nothing.
# Every route named in GitHub issue 16, plus the rest of the read surface.
# ---------------------------------------------------------------------------

ungated_routes=(
  "/api/catalog"
  "/api/dashboard"
  "/api/nodes"
  "/api/nodes/${subject_id}"
  "/api/nodes/${subject_id}/graph"
  "/api/nodes/${subject_id}/knowledge"
  "/api/events"
  "/api/knowledge-map"
  "/api/workspace/crm"
  "/api/workspace/pm"
  "/api/gaps"
  "/api/stale-digests"
  "/api/domains"
  "/api/review-queue"
  "/api/candidates/review"
  "/api/review/assertions"
  "/api/audit/actions"
  "/api/context-pack"
)
for route in "${ungated_routes[@]}"; do
  expect_status "no-grant token on ${route}" 403 -H "$(auth "$nogrant_token")" "${BASE_URL}${route}"
done

expect_status "unmatched path" 404 -H "$(auth "$reviewer_token")" "${BASE_URL}/api/not-a-route"

# HEAD is dispatched to the GET handler, so it is judged by the GET row. Any
# method with no row and no handler falls through to the 404 without running
# anything. Both directions are checked exhaustively by `npm run check:routes`;
# these probe the real server over the wire.
expect_status "HEAD on health" 200 -I "${BASE_URL}/api/health"
expect_status "HEAD without a token" 401 -I "${BASE_URL}/api/catalog"
expect_status "HEAD on a deny route" 403 -I -H "$(auth "$reviewer_token")" "${BASE_URL}/api/dashboard"
expect_status "HEAD on a deny route, no grants" 403 -I -H "$(auth "$nogrant_token")" "${BASE_URL}/api/workspace/crm"
expect_status "HEAD on a capability route without the grant" 403 -I -H "$(auth "$nogrant_token")" "${BASE_URL}/api/catalog"
expect_status "HEAD on a capability route with the grant" 200 -I -H "$(auth "$reviewer_token")" "${BASE_URL}/api/catalog"
expect_status "HEAD on the domains listing" 200 -I -H "$(auth "$reviewer_token")" "${BASE_URL}/api/domains"

for method in PUT PATCH DELETE; do
  expect_status "${method} on a deny route" 404 \
    -X "$method" -H "$(auth "$reviewer_token")" "${BASE_URL}/api/dashboard"
  expect_status "${method} on a capability route" 404 \
    -X "$method" -H "$(auth "$reviewer_token")" "${BASE_URL}/api/catalog"
done

# The four console rollups are closed to every agent token, including one that
# holds every capability the instance defines for its area.
for route in "/api/dashboard" "/api/knowledge-map" "/api/workspace/crm" "/api/workspace/pm"; do
  expect_status "granted token on deny route ${route}" 403 -H "$(auth "$reviewer_token")" "${BASE_URL}${route}"
  deny_body="$(curl -sS -H "$(auth "$reviewer_token")" "${BASE_URL}${route}")"
  expect_field "deny reason on ${route}" "$deny_body" "reason" "route not available to agent tokens"
  expect_field "deny check on ${route}" "$deny_body" "policy.check" "deny"
  expect_field "deny capability on ${route}" "$deny_body" "policy.capability" "null"
done

# The 403 body names the policy that refused.
catalog_denied="$(curl -sS -H "$(auth "$nogrant_token")" "${BASE_URL}/api/catalog")"
expect_field "catalog 403 error" "$catalog_denied" "error" "forbidden"
expect_field "catalog 403 reason" "$catalog_denied" "reason" "missing capability grant"
expect_field "catalog 403 action" "$catalog_denied" "policy.action" "catalog_read"
expect_field "catalog 403 capability" "$catalog_denied" "policy.capability" "rye.context.read"
expect_field "catalog 403 check" "$catalog_denied" "policy.check" "global"
expect_field "catalog 403 domain_keys" "$catalog_denied" "policy.domain_keys" "[]"
expect_field "catalog 403 scope_ref" "$catalog_denied" "policy.scope_ref" "null"

# ---------------------------------------------------------------------------
# A properly granted token still reaches the routes it is meant to use.
# ---------------------------------------------------------------------------

granted_routes=(
  "/api/catalog"
  "/api/events"
  "/api/nodes"
  "/api/nodes/${subject_id}"
  "/api/nodes/${subject_id}/graph"
  "/api/nodes/${subject_id}/knowledge"
  "/api/domains"
  "/api/review-queue"
  "/api/candidates/review"
  "/api/review/assertions"
  "/api/gaps"
  "/api/stale-digests"
  "/api/audit/actions"
)
for route in "${granted_routes[@]}"; do
  expect_status "reviewer token on ${route}" 200 -H "$(auth "$reviewer_token")" "${BASE_URL}${route}"
done

# ---------------------------------------------------------------------------
# Row filtering: the domains listing.
# ---------------------------------------------------------------------------

domains_json="$(curl -sS -H "$(auth "$candidate_token")" "${BASE_URL}/api/domains")"
expect_absent "low-privilege domain properties" "$domains_json" "secret_internal_note"
expect_present "held area present" "$domains_json" '"domain_key":"api_account_updates"'
expect_absent "unheld area absent" "$domains_json" '"domain_key":"api_title_diligence"'
expect_absent "unheld area authority absent" "$domains_json" "api-title-authority-marker"
expect_absent "unheld area channel absent" "$domains_json" "slack:#api-title-marker"

title_domains_json="$(curl -sS -H "$(auth "$title_token")" "${BASE_URL}/api/domains")"
expect_present "title agent sees its own area" "$title_domains_json" '"domain_key":"api_title_diligence"'
expect_absent "title agent cannot see account area" "$title_domains_json" '"domain_key":"api_account_updates"'
expect_absent "title agent cannot see account authority" "$title_domains_json" "api-account-authority-marker"
expect_absent "title agent cannot see account channel" "$title_domains_json" "slack:#api-account-marker"

# ---------------------------------------------------------------------------
# Writes: the existing candidate lifecycle, unchanged.
# ---------------------------------------------------------------------------

candidate_body='{
  "candidate_kind":"decision",
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
  -H "$(auth "$candidate_token")" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: ${IDEM_KEY}" \
  -d "$candidate_body" \
  "${BASE_URL}/api/candidates")"
candidate_id_1="$(json_get "$candidate_json_1" "id")"

candidate_json_2="$(curl -sS \
  -H "$(auth "$candidate_token")" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: ${IDEM_KEY}" \
  -d "$candidate_body" \
  "${BASE_URL}/api/candidates")"
candidate_id_2="$(json_get "$candidate_json_2" "id")"

[[ "$candidate_id_1" == "$candidate_id_2" ]] || {
  fail "Expected idempotent candidate id, got $candidate_id_1 and $candidate_id_2"
}

# Checked here, before the promotion below. promote_candidate_node_to_assertion
# archives the candidate node, and the queue only lists live candidates, so
# after promotion this row is gone from every caller's listing and an absence
# assertion on it would prove nothing about the area filter.
reviewer_queue="$(curl -sS -H "$(auth "$reviewer_token")" "${BASE_URL}/api/review-queue?include_closed=1&q=Brightline")"
expect_present "reviewer sees its own area's candidate" "$reviewer_queue" "$candidate_id_1"

title_queue="$(curl -sS -H "$(auth "$title_token")" "${BASE_URL}/api/review-queue?include_closed=1&q=Brightline")"
expect_absent "title agent does not see account candidate" "$title_queue" "$candidate_id_1"

# A valid token used against another area is refused.
cross_area_body="$(curl -sS \
  -H "$(auth "$candidate_token")" \
  -H "Content-Type: application/json" \
  -d '{"candidate_kind":"decision","statement":"Title work is complete.","domain_keys":["api-title-diligence"]}' \
  "${BASE_URL}/api/candidates")"
expect_field "cross-area candidate error" "$cross_area_body" "error" "forbidden"
expect_field "cross-area candidate reason" "$cross_area_body" "reason" "missing capability grant"
expect_field "cross-area candidate capability" "$cross_area_body" "policy.capability" "rye.candidate.create"
expect_field "cross-area candidate check" "$cross_area_body" "policy.check" "domain + scope"
expect_field "cross-area candidate domain_keys" "$cross_area_body" "policy.domain_keys" '["api-title-diligence"]'

# The same refusal on a read route that carries area keys.
expect_status "cross-area context pack" 403 \
  -H "$(auth "$title_token")" \
  "${BASE_URL}/api/context-pack?domain_keys=api-account-updates"

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

expect_status "candidate token cannot promote" 403 \
  -H "$(auth "$candidate_token")" \
  -H "Content-Type: application/json" \
  -d "$promote_body" \
  "${BASE_URL}/api/candidates/${candidate_id_1}/promote"

reviewer_promote_status="$(status_code \
  -H "$(auth "$reviewer_token")" \
  -H "Content-Type: application/json" \
  -d "$promote_body" \
  "${BASE_URL}/api/candidates/${candidate_id_1}/promote")"
[[ "$reviewer_promote_status" == "200" ]] || {
  echo "Expected reviewer promotion 200, got $reviewer_promote_status" >&2
  curl -sS -H "$(auth "$reviewer_token")" "${BASE_URL}/api/audit/actions?limit=10" >&2 || true
  exit 1
}

# ---------------------------------------------------------------------------
# Row filtering: the review queue.
# ---------------------------------------------------------------------------

# Searched by a distinctive word so the assertions do not depend on how many
# candidates other suites left in the database. These markers are never
# promoted, so they stay live for the whole run.
reviewer_keyless="$(curl -sS -H "$(auth "$reviewer_token")" "${BASE_URL}/api/review-queue?include_closed=1&q=keyless")"
expect_absent "reviewer does not see keyless candidate" "$reviewer_keyless" "keyless candidate marker"

title_keyless="$(curl -sS -H "$(auth "$title_token")" "${BASE_URL}/api/review-queue?include_closed=1&q=keyless")"
expect_absent "title agent does not see keyless candidate" "$title_keyless" "keyless candidate marker"

# Area keys that no sluggable key survives are keyless, not "holds it somewhere".
reviewer_unsluggable="$(curl -sS -H "$(auth "$reviewer_token")" "${BASE_URL}/api/review-queue?include_closed=1&q=unsluggable")"
expect_absent "reviewer does not see unsluggable-key candidate" "$reviewer_unsluggable" "unsluggable key candidate marker"

title_unsluggable="$(curl -sS -H "$(auth "$title_token")" "${BASE_URL}/api/review-queue?include_closed=1&q=unsluggable")"
expect_absent "title agent does not see unsluggable-key candidate" "$title_unsluggable" "unsluggable key candidate marker"

# A junk key beside a real key the token holds: shown. Beside one it does not
# hold: hidden. The junk key changes nothing in either direction.
reviewer_mixed_held="$(curl -sS -H "$(auth "$reviewer_token")" "${BASE_URL}/api/review-queue?include_closed=1&q=mixedheldmarker")"
expect_present "reviewer sees mixed array with a held key" "$reviewer_mixed_held" "mixedheldmarker"

title_mixed_held="$(curl -sS -H "$(auth "$title_token")" "${BASE_URL}/api/review-queue?include_closed=1&q=mixedheldmarker")"
expect_absent "title agent does not see the account area's mixed candidate" "$title_mixed_held" "mixedheldmarker"

reviewer_mixed_unheld="$(curl -sS -H "$(auth "$reviewer_token")" "${BASE_URL}/api/review-queue?include_closed=1&q=mixedunheldmarker")"
expect_absent "reviewer does not see mixed array with an unheld key" "$reviewer_mixed_unheld" "mixedunheldmarker"

title_mixed_unheld="$(curl -sS -H "$(auth "$title_token")" "${BASE_URL}/api/review-queue?include_closed=1&q=mixedunheldmarker")"
expect_present "title agent sees its own area's mixed candidate" "$title_mixed_unheld" "mixedunheldmarker"

# Counts report what was returned, not what was withheld. The instance holds
# far more candidates than the title agent may see, so an unfiltered listing
# whose total equals the number of rows it returned is the whole check.
title_all="$(curl -sS -H "$(auth "$title_token")" "${BASE_URL}/api/review-queue?include_closed=1")"
title_total="$(json_get "$title_all" "stats.total")"
title_count="$(node -e "console.log(JSON.parse(process.argv[1]).candidates.length)" "$title_all")"
[[ "$title_total" == "$title_count" ]] || {
  fail "Expected the title agent's queue total to count only returned rows, got total=$title_total rows=$title_count"
}
expect_absent "title agent's queue excludes keyless rows" "$title_all" "keyless candidate marker"
expect_absent "title agent's queue excludes unsluggable rows" "$title_all" "unsluggable key candidate marker"
expect_absent "title agent's queue excludes the account area's mixed row" "$title_all" "mixedheldmarker"

# /api/candidates/review is the same listing and is filtered the same way.
title_review="$(curl -sS -H "$(auth "$title_token")" "${BASE_URL}/api/candidates/review?include_closed=1&q=mixedheldmarker")"
expect_absent "title agent candidates/review is filtered" "$title_review" "mixedheldmarker"

reviewer_review="$(curl -sS -H "$(auth "$reviewer_token")" "${BASE_URL}/api/candidates/review?include_closed=1&q=mixedheldmarker")"
expect_present "reviewer candidates/review sees its own area" "$reviewer_review" "mixedheldmarker"

# ---------------------------------------------------------------------------
# The MCP adapter's tools keep working.
# skills/rye-source-context-intake/scripts/rye_api_mcp_server.mts calls exactly
# these seven routes and nothing else.
# ---------------------------------------------------------------------------

expect_status "mcp agent/me" 200 -H "$(auth "$candidate_token")" "${BASE_URL}/api/agent/me"
expect_status "mcp context-pack" 200 \
  -H "$(auth "$candidate_token")" \
  "${BASE_URL}/api/context-pack?domain_keys=api-account-updates"
expect_status "mcp domains" 200 -H "$(auth "$candidate_token")" "${BASE_URL}/api/domains"
expect_status "mcp observations" 201 \
  -H "$(auth "$candidate_token")" \
  -H "Content-Type: application/json" \
  -d '{"statement":"Account owner confirmed the renewal date.","domain_keys":["api-account-updates"],"source_scope":"slack:#api-sales"}' \
  "${BASE_URL}/api/observations"
expect_status "mcp candidates" 201 \
  -H "$(auth "$candidate_token")" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: ${IDEM_KEY}-mcp" \
  -d "$candidate_body" \
  "${BASE_URL}/api/candidates"
# Same idempotency key, so this returns the row just created rather than a new
# one. It stays live for the rest of the run and stands in for candidate_id_1,
# which the promotion above archived.
mcp_candidate_json="$(curl -sS \
  -H "$(auth "$candidate_token")" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: ${IDEM_KEY}-mcp" \
  -d "$candidate_body" \
  "${BASE_URL}/api/candidates")"
mcp_candidate_id="$(json_get "$mcp_candidate_json" "id")"
expect_status "mcp review-queue" 200 -H "$(auth "$reviewer_token")" "${BASE_URL}/api/review-queue"
expect_status "mcp audit/actions" 200 -H "$(auth "$reviewer_token")" "${BASE_URL}/api/audit/actions"

# ---------------------------------------------------------------------------
# Every refusal is on the action log.
# ---------------------------------------------------------------------------

expect_status "low-privilege audit read" 403 -H "$(auth "$candidate_token")" "${BASE_URL}/api/audit/actions"

audit_json="$(curl -sS -H "$(auth "$reviewer_token")" "${BASE_URL}/api/audit/actions?limit=200")"
expect_present "audit has the allowed promotion" "$audit_json" "candidate_promote"
expect_present "audit has the deny-route refusal" "$audit_json" "dashboard_read"
expect_present "audit records the deny reason" "$audit_json" "route not available to agent tokens"
expect_present "audit has a capability refusal" "$audit_json" "missing capability grant"

# ---------------------------------------------------------------------------
# Auth mode off: the reviewer's screen is unaffected.
# ---------------------------------------------------------------------------

for route in "/api/dashboard" "/api/knowledge-map" "/api/workspace/crm" "/api/workspace/pm" \
             "/api/catalog" "/api/domains" "/api/review-queue" "/api/gaps" "/api/stale-digests"; do
  expect_status "auth off ${route}" 200 "${OPEN_URL}${route}"
done

open_me="$(curl -sS "${OPEN_URL}/api/agent/me")"
expect_field "auth off agent/me auth_required" "$open_me" "auth_required" "false"
expect_field "auth off agent/me agent" "$open_me" "agent" "null"

open_domains="$(curl -sS "${OPEN_URL}/api/domains")"
expect_present "auth off sees account area" "$open_domains" '"domain_key":"api_account_updates"'
expect_present "auth off sees title area" "$open_domains" '"domain_key":"api_title_diligence"'
expect_present "auth off sees account authority" "$open_domains" "api-account-authority-marker"
expect_present "auth off sees title authority" "$open_domains" "api-title-authority-marker"

open_keyless="$(curl -sS "${OPEN_URL}/api/review-queue?include_closed=1&q=keyless")"
expect_present "auth off sees the keyless candidate" "$open_keyless" "keyless candidate marker"
open_unsluggable="$(curl -sS "${OPEN_URL}/api/review-queue?include_closed=1&q=unsluggable")"
expect_present "auth off sees the unsluggable-key candidate" "$open_unsluggable" "unsluggable key candidate marker"
open_mixed_held="$(curl -sS "${OPEN_URL}/api/review-queue?include_closed=1&q=mixedheldmarker")"
expect_present "auth off sees the mixed held-key candidate" "$open_mixed_held" "mixedheldmarker"
open_mixed_unheld="$(curl -sS "${OPEN_URL}/api/review-queue?include_closed=1&q=mixedunheldmarker")"
expect_present "auth off sees the mixed unheld-key candidate" "$open_mixed_unheld" "mixedunheldmarker"
open_queue="$(curl -sS "${OPEN_URL}/api/review-queue?include_closed=1&q=Brightline")"
expect_present "auth off sees an account-area candidate" "$open_queue" "$mcp_candidate_id"

# ---------------------------------------------------------------------------
# A revoked token is a 401, indistinguishable from unknown and expired.
# ---------------------------------------------------------------------------

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

expect_status "revoked token" 401 -H "$(auth "$candidate_token")" "${BASE_URL}/api/domains"
revoked_body="$(curl -sS -H "$(auth "$candidate_token")" "${BASE_URL}/api/domains")"
expect_field "revoked token error" "$revoked_body" "error" "invalid bearer token"

echo "API security test passed"
