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

# Static check that every database call still goes through ryeQuery() in
# admin/src/server/db.ts. Runs standalone as: cd admin && npm run check:db
npm --prefix admin run --silent check:db

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

# expect_value <description> <got> <expected>
expect_value() {
  local desc="$1" got="$2" expected="$3"
  [[ "$got" == "$expected" ]] || fail "$desc — expected '$expected', got '$got'"
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
SELECT rye.create_agent_identity('api-expiry-agent', 'API Expiry Agent', 'conformance');
SELECT rye.create_agent_identity('api-inactive-agent', 'API Inactive Agent', 'conformance');
SELECT rye.create_agent_identity('api-domain-admin-agent', 'API Domain Admin Agent', 'conformance');
SELECT rye.create_agent_identity('api-instancewide-agent', 'API Instance-Wide Agent', 'conformance');

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

-- Decision 0013, obligation 42.7: a token whose only grant for a route's
-- capability is expired, or inactive, reaches nothing. Seeded in the state
-- the test checks first; the test flips each grant live and back to prove
-- the refusal tracks grant state rather than a one-time seed.
SELECT rye.grant_agent_capability(
  'api-expiry-agent', 'rye.context.read', 'api-account-updates', NULL, now() - interval '1 hour'
);
SELECT rye.grant_agent_capability('api-inactive-agent', 'rye.context.read', 'api-account-updates');
UPDATE rye.agent_capability_grants
SET active = false
WHERE agent_id = (SELECT id FROM rye.agent_identities WHERE agent_key = 'api_inactive_agent')
  AND capability = 'rye.context.read';

-- The domains `properties` gate (`rye.domain.admin`) inherits expiry from the
-- same source (authenticate_agent_token) and nothing else pins it. This agent
-- holds a live rye.context.read (so it can see the domain row at all) and an
-- expired rye.domain.admin grant.
SELECT rye.grant_agent_capability('api-domain-admin-agent', 'rye.context.read', 'api-account-updates');
SELECT rye.grant_agent_capability(
  'api-domain-admin-agent', 'rye.domain.admin', 'api-account-updates', NULL, now() - interval '1 hour'
);

-- Decision 0013, obligation 42.8: a grant that names no area is instance-wide
-- and holds every area, including candidates that carry no area keys at all.
SELECT rye.grant_agent_capability('api-instancewide-agent', 'rye.review.read');

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

# The role is set by its own earlier statement in the same psql session, not
# by a CTE or a lateral the planner is free to reorder past the RLS filter on
# the governance tables. `\g /dev/null` keeps its output out of the captured
# token.
issue_token() {
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<SQL
SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false) \g /dev/null
SELECT rye.issue_agent_token('$1', '$2'${3:+, $3});
SQL
}

candidate_token="$(issue_token api-candidate-agent 'api security candidate token')"
reviewer_token="$(issue_token api-reviewer-agent 'api security reviewer token')"
title_token="$(issue_token api-title-agent 'api security title token')"
nogrant_token="$(issue_token api-nograntee-agent 'api security no-grant token')"
expired_token="$(issue_token api-reviewer-agent 'api security expired token' "now() - interval '1 hour'")"
expiry_token="$(issue_token api-expiry-agent 'api security grant-expiry token')"
inactive_token="$(issue_token api-inactive-agent 'api security grant-inactive token')"
domainadmin_token="$(issue_token api-domain-admin-agent 'api security domain-admin token')"
instancewide_token="$(issue_token api-instancewide-agent 'api security instance-wide token')"

# grant_id_for <agent_key> <capability> — the id of that grant, direct from
# the table, so the test can flip it live and back without re-seeding.
grant_id_for() {
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<SQL
SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false) \g /dev/null
SELECT g.id
FROM rye.agent_capability_grants g
JOIN rye.agent_identities a ON a.id = g.agent_id
WHERE a.agent_key = '$1' AND g.capability = '$2'
LIMIT 1;
SQL
}

# set_grant_state <grant_id> <active: true|false> <expires_at SQL expr, e.g. NULL or now() - interval '1 hour'>
set_grant_state() {
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq >/dev/null <<SQL
SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false);
UPDATE rye.agent_capability_grants
SET active = $2, expires_at = $3
WHERE id = '$1'::uuid;
SQL
}

expiry_grant_id="$(grant_id_for api_expiry_agent rye.context.read)"
inactive_grant_id="$(grant_id_for api_inactive_agent rye.context.read)"
domainadmin_grant_id="$(grant_id_for api_domain_admin_agent rye.domain.admin)"

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
# Decision 0013, obligation 42.7: expired and inactive grants reach nothing.
# authenticate_agent_token() already filters both out of `auth.capabilities`,
# so every capability test in the Worker inherits the refusal; this pins that
# from the HTTP side. Each grant is flipped live and back, so the check is
# not proving a one-time seed.
# ---------------------------------------------------------------------------

expect_status "expired grant reaches nothing" 403 -H "$(auth "$expiry_token")" "${BASE_URL}/api/catalog"
set_grant_state "$expiry_grant_id" true "NULL"
expect_status "live grant restores access" 200 -H "$(auth "$expiry_token")" "${BASE_URL}/api/catalog"
set_grant_state "$expiry_grant_id" true "now() - interval '1 hour'"
expect_status "expiring the grant again refuses again" 403 -H "$(auth "$expiry_token")" "${BASE_URL}/api/catalog"

expect_status "inactive grant reaches nothing" 403 -H "$(auth "$inactive_token")" "${BASE_URL}/api/catalog"
set_grant_state "$inactive_grant_id" true "NULL"
expect_status "reactivating the grant restores access" 200 -H "$(auth "$inactive_token")" "${BASE_URL}/api/catalog"
set_grant_state "$inactive_grant_id" false "NULL"
expect_status "deactivating the grant again refuses again" 403 -H "$(auth "$inactive_token")" "${BASE_URL}/api/catalog"

# The domains `properties` gate follows the same grant's expiry, not its own
# check (docs/decisions/0013-leftovers-fail-restrictive.md, section C).
domainadmin_expired_json="$(curl -sS -H "$(auth "$domainadmin_token")" "${BASE_URL}/api/domains")"
expect_absent "expired rye.domain.admin grant hides properties" \
  "$domainadmin_expired_json" "secret_internal_note"
set_grant_state "$domainadmin_grant_id" true "NULL"
domainadmin_live_json="$(curl -sS -H "$(auth "$domainadmin_token")" "${BASE_URL}/api/domains")"
expect_present "live rye.domain.admin grant reveals properties" \
  "$domainadmin_live_json" "secret_internal_note"
set_grant_state "$domainadmin_grant_id" true "now() - interval '1 hour'"
domainadmin_reexpired_json="$(curl -sS -H "$(auth "$domainadmin_token")" "${BASE_URL}/api/domains")"
expect_absent "re-expiring the rye.domain.admin grant hides properties again" \
  "$domainadmin_reexpired_json" "secret_internal_note"

# ---------------------------------------------------------------------------
# Decision 0013, obligation 42.8: the instance-wide grant predicate is pinned
# from outside (contracts/admin-api.md, "Row filtering"). A grant that names
# no area holds every area, including candidates that carry no area keys.
# ---------------------------------------------------------------------------

instancewide_keyless="$(curl -sS -H "$(auth "$instancewide_token")" "${BASE_URL}/api/review-queue?include_closed=1&q=keyless")"
expect_present "instance-wide grant sees the keyless candidate" \
  "$instancewide_keyless" "keyless candidate marker"

# Anti-vacuity: an area-named grant does not see it (already the rule for
# reviewer_token/title_token below), and the instance-wide grant sees an
# area-keyed candidate too, the same as an area-named token does.
instancewide_mixed="$(curl -sS -H "$(auth "$instancewide_token")" "${BASE_URL}/api/review-queue?include_closed=1&q=mixedheldmarker")"
expect_present "instance-wide grant also sees an area-keyed candidate" \
  "$instancewide_mixed" "mixedheldmarker"

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
# Review fields and counts: contracts/admin-api.md, "Review fields and counts".
# The route projects the views from migration 0035 rather than recomputing
# them, so every field below must arrive populated, and the two states must
# stay disjoint.
# ---------------------------------------------------------------------------

# One subject carrying: an accepted incumbent with evidence, a live suggestion
# on the same tuple, a settle-gated suggestion, and a declined one. The marker
# is in the subject label, which the route's `q` filter matches, so none of
# these assertions depends on how many rows other suites left behind.
review_fixture="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<'SQL' | tail -n 1
SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false) \g /dev/null
CREATE TEMP TABLE t_api_review (k text PRIMARY KEY, v uuid);
DO $$
DECLARE
  v_node uuid;
  v_witness uuid;
  v_event uuid;
  v_incumbent uuid;
  v_candidate uuid;
  v_gated uuid;
  v_declined uuid;
  v_project uuid;
  v_source uuid;
  v_digest uuid;
  v_newer uuid;
  v_noise_node uuid;
BEGIN
  -- A live assertion candidate that never matches "apireviewmarker". Without
  -- it, stats.total for a q-narrowed request could equal stats.filtered by
  -- coincidence when this suite runs standalone, and the total-versus-filtered
  -- check below would pass vacuously.
  INSERT INTO nodes (node_type, label) VALUES ('account', 'API apisecuritynoise Account')
  RETURNING id INTO v_noise_node;
  PERFORM record_assertion(
      'account_health', '{"health":"amber"}', v_noise_node,
      p_confidence := 0.5, p_status := 'candidate', p_basis := 'assumed');

  INSERT INTO nodes (node_type, label) VALUES ('account', 'API apireviewmarker Account')
  RETURNING id INTO v_node;
  INSERT INTO nodes (node_type, label) VALUES ('person', 'API apireviewmarker Witness')
  RETURNING id INTO v_witness;

  v_event := record_event('call', 'API apireviewmarker evidence call', '{}'::jsonb,
                          ARRAY[v_node], ARRAY['subject'], 'user:api-security');

  v_incumbent := record_assertion(
      'account_health', '{"health":"amber"}', v_node,
      p_confidence := 0.6, p_basis := 'reported',
      p_evidence := ARRAY[jsonb_build_object('kind', 'source', 'event_id', v_event,
                                             'witness_node_id', v_witness)]);
  v_candidate := record_assertion(
      'account_health', '{"health":"green"}', v_node,
      p_confidence := 0.8, p_status := 'candidate', p_basis := 'reported',
      p_evidence := ARRAY[jsonb_build_object('kind', 'source', 'event_id', v_event,
                                             'witness_node_id', v_witness)]);

  -- A team_member may not settle a configuration type, so record_assertion()
  -- demotes this one and marks it. That is waiting_reason = settle_gate.
  PERFORM set_config('app.current_role', 'team_member', true);
  v_gated := record_assertion(
      'registry_entry', '{"value":"apireviewmarker"}', v_node,
      p_assertion_key := 'apireviewmarker:settle', p_basis := 'assumed');
  PERFORM set_config('app.current_role', 'admin', true);

  v_declined := record_assertion(
      'service_tier', '{"tier":"platinum"}', v_node,
      p_assertion_key := 'apireviewmarker:declined', p_confidence := 0.5,
      p_status := 'candidate', p_basis := 'assumed');
  PERFORM reject_candidate(v_declined, 'Duplicate of the signed order',
                           'user:api-security', 'duplicate');

  -- A stale summary with its culprit: a digest carrying a watermark, and a
  -- fact newer than that watermark. now() is frozen inside this block, so the
  -- newer row outruns the watermark by hand. Seeded here rather than borrowed
  -- from another suite, so the check below can never pass vacuously.
  INSERT INTO nodes (node_type, label) VALUES ('project', 'API apireviewmarker Rollout')
  RETURNING id INTO v_project;
  v_source := record_assertion('project_status', '{"status":"active"}', v_project,
                               p_assertion_key := 'default', p_basis := 'assumed');
  v_digest := record_distillation(
      p_subject_node_id := v_project, p_subject_edge_id := NULL,
      p_assertion_key := 'apireviewmarker:digest',
      p_claim := '{"summary":"rollout is on track"}',
      p_source_assertion_ids := ARRAY[v_source], p_source_event_ids := '{}'::uuid[],
      p_agent := 'test:api-security');
  INSERT INTO assertions (assertion_type, assertion_key, subject_node_id,
                          claim, asserted_at, basis)
  VALUES ('project_update', 'apireviewmarker:after-digest', v_project,
          '{"value":"newer"}', clock_timestamp() + interval '1 millisecond', 'assumed')
  RETURNING id INTO v_newer;

  INSERT INTO t_api_review (k, v) VALUES
    ('a_candidate', v_candidate),
    ('b_declined', v_declined),
    ('c_gated', v_gated),
    ('d_incumbent', v_incumbent),
    ('e_digest', v_digest),
    ('f_newer', v_newer);
END
$$;
SELECT string_agg(v::text, ' ' ORDER BY k) FROM t_api_review;
SQL
)"
read -r suggestion_id declined_id gated_id incumbent_id digest_id newer_id <<<"$review_fixture"
for fixture_id in "$suggestion_id" "$declined_id" "$gated_id" "$incumbent_id" "$digest_id" "$newer_id"; do
  [[ -n "$fixture_id" ]] || fail "review fixture is incomplete, got '$review_fixture'"
done

# suggestion_field <json> <assertion id> <field>
suggestion_field() {
  node -e "const d = JSON.parse(process.argv[1]); const id = process.argv[2]; const f = process.argv[3];
    for (const g of d.groups ?? []) for (const c of g.candidates ?? []) if (c.id === id) {
      const v = c[f];
      if (v === undefined) process.exit(2);
      console.log(v === null ? 'null' : typeof v === 'object' ? JSON.stringify(v) : String(v));
      process.exit(0);
    }
    process.exit(3);" "$1" "$2" "$3"
}

# group_field <json> <assertion id> <field> — the group that holds it
group_field() {
  node -e "const d = JSON.parse(process.argv[1]); const id = process.argv[2]; const f = process.argv[3];
    for (const g of d.groups ?? []) for (const c of g.candidates ?? []) if (c.id === id) {
      const v = f.split('.').reduce((cur, k) => cur?.[k], g);
      if (v === undefined) process.exit(2);
      console.log(v === null ? 'null' : typeof v === 'object' ? JSON.stringify(v) : String(v));
      process.exit(0);
    }
    process.exit(3);" "$1" "$2" "$3"
}

# declined_field <json> <assertion id> <field>
declined_field() {
  node -e "const d = JSON.parse(process.argv[1]); const id = process.argv[2]; const f = process.argv[3];
    for (const r of d.rejected ?? []) if (r.id === id) {
      const v = r[f];
      if (v === undefined) process.exit(2);
      console.log(v === null ? 'null' : typeof v === 'object' ? JSON.stringify(v) : String(v));
      process.exit(0);
    }
    process.exit(3);" "$1" "$2" "$3"
}

# expect_suggestion <description> <json> <id> <field> <expected>
expect_suggestion() {
  local desc="$1" body="$2" id="$3" field="$4" expected="$5"
  local got
  got="$(suggestion_field "$body" "$id" "$field" || true)"
  [[ "$got" == "$expected" ]] || fail "$desc — expected $field = '$expected', got '$got'"
}

waiting_json="$(curl -sS -H "$(auth "$reviewer_token")" "${BASE_URL}/api/review/assertions?q=apireviewmarker")"
expect_field "review state defaults to waiting" "$waiting_json" "state" "waiting"

# A suggestion projects a number. effective_confidence() stays null for it.
projected="$(suggestion_field "$waiting_json" "$suggestion_id" "projected_effective_confidence" || true)"
[[ -n "$projected" && "$projected" != "null" ]] || {
  fail "projected_effective_confidence is '$projected' for a live suggestion"
}
node -e "const v = Number(process.argv[1]); if (!(v > 0 && v <= 1)) { console.error('projected_effective_confidence out of range: ' + process.argv[1]); process.exit(1); }" "$projected"
expect_suggestion "effective_confidence stays null for a suggestion" \
  "$waiting_json" "$suggestion_id" "effective_confidence" "null"

# The evidence summary comes from the view, not from a client-side count.
expect_suggestion "evidence_count" "$waiting_json" "$suggestion_id" "evidence_count" "1"
expect_suggestion "witness_count" "$waiting_json" "$suggestion_id" "witness_count" "1"
expect_suggestion "evidence_kinds" "$waiting_json" "$suggestion_id" "evidence_kinds" '["source"]'
latest_evidence="$(suggestion_field "$waiting_json" "$suggestion_id" "latest_evidence_at" || true)"
[[ -n "$latest_evidence" && "$latest_evidence" != "null" ]] || {
  fail "latest_evidence_at is '$latest_evidence' for a suggestion with evidence"
}

# The incumbent is the row an acceptance would supersede, and it says whether
# it is also the answer Rye gives today.
expect_field "incumbent id comes from the view" \
  "$(group_field "$waiting_json" "$suggestion_id" "incumbent" || true)" "id" "$incumbent_id"
expect_field "incumbent is_current" \
  "$(group_field "$waiting_json" "$suggestion_id" "incumbent" || true)" "is_current" "true"
incumbent_effective="$(group_field "$waiting_json" "$suggestion_id" "incumbent.effective_confidence" || true)"
[[ -n "$incumbent_effective" && "$incumbent_effective" != "null" ]] || {
  fail "incumbent.effective_confidence is '$incumbent_effective'"
}

# Why it is waiting. Never null: the view writes "none".
expect_value "a plainly recorded suggestion is not gated" \
  "$(group_field "$waiting_json" "$suggestion_id" "waiting_reason" || true)" "none"
expect_value "a settle-gated suggestion says so" \
  "$(group_field "$waiting_json" "$gated_id" "waiting_reason" || true)" "settle_gate"
expect_suggestion "the suggestion carries its own reason" \
  "$waiting_json" "$gated_id" "waiting_reason" "settle_gate"
gated_detail="$(group_field "$waiting_json" "$gated_id" "waiting_detail" || true)"
[[ "$gated_detail" != "null" && -n "$gated_detail" ]] || {
  fail "waiting_detail is '$gated_detail' on a settle-gated tuple"
}

# total and filtered mean what contracts/admin-api.md says: neither depends on
# limit or offset, and the returned array is at most a page of filtered.
counts_json="$(curl -sS -H "$(auth "$reviewer_token")" "${BASE_URL}/api/review/assertions?limit=1")"
node -e "const d = JSON.parse(process.argv[1]);
  const s = d.stats;
  if (typeof s.total !== 'number' || typeof s.filtered !== 'number') {
    console.error('stats.total/filtered missing: ' + JSON.stringify(s)); process.exit(1);
  }
  if (s.filtered > s.total) { console.error('filtered > total: ' + JSON.stringify(s)); process.exit(1); }
  if (d.groups.length > 1) { console.error('limit=1 returned ' + d.groups.length + ' groups'); process.exit(1); }
  if (s.filtered < d.groups.length) { console.error('filtered under-counts the page'); process.exit(1); }
  if (s.filtered <= 1) { console.error('anti-vacuity: filtered is ' + s.filtered + ', paging is untested'); process.exit(1); }
" "$counts_json"

# total counts every tuple before the request's own q/assertion_type/
# competingOnly filters; filtered counts what survives them. Narrowing the
# request with q must not move total, and must move filtered — otherwise a
# test could pass by comparing two numbers that happen to be equal.
marker_counts_json="$(curl -sS -H "$(auth "$reviewer_token")" "${BASE_URL}/api/review/assertions?q=apireviewmarker")"
unfiltered_total="$(json_get "$counts_json" "stats.total")"
marker_total="$(json_get "$marker_counts_json" "stats.total")"
marker_filtered="$(json_get "$marker_counts_json" "stats.filtered")"
[[ "$unfiltered_total" == "$marker_total" ]] || {
  fail "stats.total moved when q narrowed the request: unfiltered=$unfiltered_total, q=apireviewmarker=$marker_total"
}
node -e "const total = Number(process.argv[1]); const filtered = Number(process.argv[2]);
  if (!(filtered < total)) { console.error('anti-vacuity: q=apireviewmarker did not narrow filtered (' + filtered + ') below total (' + total + ')'); process.exit(1); }
" "$marker_total" "$marker_filtered"

# ?state=rejected is the same route, and the two sets never mix.
rejected_json="$(curl -sS -H "$(auth "$reviewer_token")" "${BASE_URL}/api/review/assertions?state=rejected&q=apireviewmarker")"
expect_field "rejected state echoes itself" "$rejected_json" "state" "rejected"
expect_field "rejected state returns no waiting groups" "$rejected_json" "groups" "[]"
expect_value "declined by" "$(declined_field "$rejected_json" "$declined_id" "rejected_by" || true)" "user:api-security"
expect_value "declined reason" "$(declined_field "$rejected_json" "$declined_id" "rejected_reason" || true)" "Duplicate of the signed order"
expect_value "declined outcome" "$(declined_field "$rejected_json" "$declined_id" "rejected_outcome" || true)" "duplicate"
declined_at="$(declined_field "$rejected_json" "$declined_id" "rejected_at" || true)"
[[ -n "$declined_at" && "$declined_at" != "null" ]] || fail "rejected_at is '$declined_at'"
declined_event="$(declined_field "$rejected_json" "$declined_id" "rejection_event_id" || true)"
[[ -n "$declined_event" && "$declined_event" != "null" ]] || fail "rejection_event_id is '$declined_event'"

expect_absent "a declined suggestion is never waiting" "$waiting_json" "$declined_id"
expect_absent "a waiting suggestion is never declined" "$rejected_json" "$suggestion_id"

# A stale digest names what made it stale.
stale_json="$(curl -sS -H "$(auth "$reviewer_token")" "${BASE_URL}/api/stale-digests?limit=500")"
node -e "const rows = JSON.parse(process.argv[1]);
  const digestId = process.argv[2];
  const newerId = process.argv[3];
  const seeded = rows.find((r) => r.id === digestId);
  if (!seeded) { console.error('anti-vacuity: the seeded stale digest is not listed'); process.exit(1); }
  if (!seeded.newer_assertion_ids.includes(newerId)) {
    console.error('the stale digest does not name what made it stale: ' + JSON.stringify(seeded.newer_assertion_ids));
    process.exit(1);
  }
  if (!seeded.newer_latest_asserted_at) { console.error('newer_latest_asserted_at is null'); process.exit(1); }
  for (const r of rows) {
    for (const f of ['newer_assertion_ids', 'overturned_source_assertion_ids']) {
      if (!Array.isArray(r[f])) { console.error(f + ' is not an array: ' + JSON.stringify(r[f])); process.exit(1); }
    }
    if (r.newer_subject_assertion !== (r.newer_assertion_ids.length > 0)) {
      console.error('newer_subject_assertion disagrees with newer_assertion_ids'); process.exit(1);
    }
    if (r.overturned_source !== (r.overturned_source_assertion_ids.length > 0)) {
      console.error('overturned_source disagrees with overturned_source_assertion_ids'); process.exit(1);
    }
  }
" "$stale_json" "$digest_id" "$newer_id"

# Deny by default still holds on both states. A token without rye.review.read
# is refused whichever state it names; a token that holds it in another area
# reaches the route, because the route table declares a global check.
expect_status "no-grant token on the rejected state" 403 \
  -H "$(auth "$nogrant_token")" "${BASE_URL}/api/review/assertions?state=rejected"
expect_status "context-read-only token on the waiting state" 403 \
  -H "$(auth "$candidate_token")" "${BASE_URL}/api/review/assertions"
expect_status "context-read-only token on the rejected state" 403 \
  -H "$(auth "$candidate_token")" "${BASE_URL}/api/review/assertions?state=rejected"
expect_status "scoped review token on the waiting state" 200 \
  -H "$(auth "$title_token")" "${BASE_URL}/api/review/assertions"
expect_status "scoped review token on the rejected state" 200 \
  -H "$(auth "$title_token")" "${BASE_URL}/api/review/assertions?state=rejected"

# The same fields arrive for a token whose rye.review.read names one area.
title_waiting="$(curl -sS -H "$(auth "$title_token")" "${BASE_URL}/api/review/assertions?q=apireviewmarker")"
expect_suggestion "scoped token sees the evidence summary" \
  "$title_waiting" "$suggestion_id" "evidence_count" "1"
title_projected="$(suggestion_field "$title_waiting" "$suggestion_id" "projected_effective_confidence" || true)"
[[ -n "$title_projected" && "$title_projected" != "null" ]] || {
  fail "scoped token got projected_effective_confidence '$title_projected'"
}
title_rejected="$(curl -sS -H "$(auth "$title_token")" "${BASE_URL}/api/review/assertions?state=rejected&q=apireviewmarker")"
expect_value "scoped token declined by" \
  "$(declined_field "$title_rejected" "$declined_id" "rejected_by" || true)" "user:api-security"

# An unknown state is rejected by validation rather than silently ignored.
expect_status "unknown review state" 400 \
  -H "$(auth "$reviewer_token")" "${BASE_URL}/api/review/assertions?state=banana"

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
SELECT set_config('app.current_role', 'admin', false) \g /dev/null
SELECT id
FROM rye.agent_api_tokens
WHERE token_hash = encode(digest('${candidate_token}', 'sha256'), 'hex')
LIMIT 1;
SQL
)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<SQL >/dev/null
SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false);
SELECT rye.revoke_agent_token('${candidate_token_id}'::uuid, 'api-security-test');
SQL

expect_status "revoked token" 401 -H "$(auth "$candidate_token")" "${BASE_URL}/api/domains"
revoked_body="$(curl -sS -H "$(auth "$candidate_token")" "${BASE_URL}/api/domains")"
expect_field "revoked token error" "$revoked_body" "error" "invalid bearer token"

echo "API security test passed"
