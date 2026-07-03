#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required for CLI agent security tests}"

# json_get needs node; inside the postgres test container there is no
# node/npm, so skip there — docker-test.sh re-runs this test from the host.
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "SKIP: node/npm not available; skipping CLI agent security test"
  exit 0
fi

ENV_FILE="${TMPDIR:-/tmp}/rye-cli-agent-security.env"
rm -f "$ENV_FILE"

rye_cmd=(./scripts/rye --db-url "$DATABASE_URL" --env-file "$ENV_FILE")

json_get() {
  node -e "const obj = JSON.parse(process.argv[1]); const path = process.argv[2].split('.'); let cur = obj; for (const key of path) cur = cur?.[key]; if (cur === undefined || cur === null) process.exit(2); if (typeof cur === 'object') console.log(JSON.stringify(cur)); else console.log(cur);" "$1" "$2"
}

require_contains() {
  local value="$1"
  local needle="$2"
  local label="$3"

  if [[ "$value" != *"$needle"* ]]; then
    echo "Expected $label output to contain $needle" >&2
    echo "$value" >&2
    exit 1
  fi
}

require_not_contains() {
  local value="$1"
  local needle="$2"
  local label="$3"

  if [[ "$value" == *"$needle"* ]]; then
    echo "Expected $label output not to contain $needle" >&2
    echo "$value" >&2
    exit 1
  fi
}

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
SET search_path = rye, public, pg_catalog;
SELECT rye.ensure_knowledge_domain('cli-account-updates', 'CLI Account Updates', 'CLI agent security test domain.');
SQL

bash -n ./scripts/rye

create_json="$("${rye_cmd[@]}" agents create --key cli-agent-security --label "CLI Agent Security" --runtime cli-test --json)"
require_contains "$create_json" '"agent_key": "cli_agent_security"' "agents create --json"

grant_json="$("${rye_cmd[@]}" agents grant --key cli-agent-security --capability rye.context.read --domain cli-account-updates --json)"
require_contains "$grant_json" '"capability": "rye.context.read"' "agents grant --json"

issue_json="$("${rye_cmd[@]}" agents issue-token --key cli-agent-security --label "cli conformance" --json)"
token="$(json_get "$issue_json" "token")"
token_id="$(json_get "$issue_json" "token_id")"
require_contains "$issue_json" '"warning": "Token is shown once' "agents issue-token --json"
require_contains "$token" "rye_" "issued token"

auth_before="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<SQL
SET search_path = rye, public, pg_catalog;
SELECT rye.authenticate_agent_token('${token}') IS NOT NULL;
SQL
)"
[[ "$auth_before" == "t" ]] || {
  echo "Expected issued token to authenticate before revocation" >&2
  exit 1
}

list_json="$("${rye_cmd[@]}" agents list --json)"
require_contains "$list_json" "cli_agent_security" "agents list --json"
require_contains "$list_json" "rye.context.read" "agents list --json"
require_not_contains "$list_json" "token_hash" "agents list --json"
require_not_contains "$list_json" "$token" "agents list --json"

revoke_json="$("${rye_cmd[@]}" agents revoke-token --token-id "$token_id" --json)"
require_contains "$revoke_json" '"revoked": true' "agents revoke-token --json"

auth_after="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<SQL
SET search_path = rye, public, pg_catalog;
SELECT rye.authenticate_agent_token('${token}') IS NULL;
SQL
)"
[[ "$auth_after" == "t" ]] || {
  echo "Expected revoked token to fail authentication" >&2
  exit 1
}

audit_json="$("${rye_cmd[@]}" agents audit --limit 20 --json)"
require_contains "$audit_json" "agent_token_revoke" "agents audit --json"
require_not_contains "$audit_json" "token_hash" "agents audit --json"
require_not_contains "$audit_json" "$token" "agents audit --json"

echo "CLI agent security test passed"
