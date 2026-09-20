#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required for secure MCP simulation tests}"

# The MCP server is a Node app; inside the postgres test container there is
# no node/npm, so skip there — docker-test.sh re-runs this test from the host.
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "SKIP: node/npm not available; skipping secure MCP simulation test"
  exit 0
fi

# Every skill and plugin manifest against the schema beside it.
# contracts/plugin-manifest.md calls a manifest that fails its schema a build
# failure, so it fails the suite here. Needs no database and no server, which
# is why it runs before either is set up. Runs standalone as:
# node skills/validate_manifests.mjs
npm --prefix skills/rye-source-context-intake run --silent check

pick_port() {
  node -e "const net = require('node:net'); const server = net.createServer(); server.listen(0, '127.0.0.1', () => { console.log(server.address().port); server.close(); });"
}

# grep with three outcomes, not two: found (0), not found (1), and broken.
# grep exits 2 on an error and bash returns 127 when the command is missing,
# and either of those must fail the test. The checks below used ripgrep, which
# a GitHub runner does not have: `if rg ...; then fail` then read as "not
# found" and passed vacuously. POSIX ERE only, no \( or \. — literal
# parentheses and dots are bracketed, which every grep reads the same way.
grep_text() {
  local pattern="$1" file="$2" status=0
  grep -nE -- "$pattern" "$file" >/dev/null || status=$?
  if (( status > 1 )); then
    echo "grep exited ${status} while checking ${file} for /${pattern}/" >&2
    exit 1
  fi
  return "$status"
}

PORT="${RYE_MCP_SECURITY_TEST_PORT:-$(pick_port)}"
BASE_URL="http://127.0.0.1:${PORT}"
LOG_FILE="${TMPDIR:-/tmp}/rye-mcp-security-${PORT}.log"
MCP_SCRIPT="skills/rye-source-context-intake/scripts/rye_api_mcp_server.mts"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

status_code() {
  curl -s -o /dev/null -w "%{http_code}" "$@"
}

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false);
SELECT rye.ensure_knowledge_domain('mcp-account-updates', 'MCP Account Updates', 'MCP security simulation domain.');
SELECT rye.create_agent_identity('mcp-read-agent', 'MCP Read Agent', 'conformance');
SELECT rye.create_agent_identity('mcp-candidate-agent', 'MCP Candidate Agent', 'conformance');
SELECT rye.grant_agent_capability('mcp-read-agent', 'rye.context.read', 'mcp-account-updates');
SELECT rye.grant_agent_capability('mcp-candidate-agent', 'rye.context.read', 'mcp-account-updates');
SELECT rye.grant_agent_capability('mcp-candidate-agent', 'rye.observation.create', 'mcp-account-updates');
SELECT rye.grant_agent_capability('mcp-candidate-agent', 'rye.candidate.create', 'mcp-account-updates');
SQL

read_token="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<'SQL'
SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false) \gset
SELECT rye.issue_agent_token('mcp-read-agent', 'mcp read token');
SQL
)"
candidate_token="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<'SQL'
SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false) \gset
SELECT rye.issue_agent_token('mcp-candidate-agent', 'mcp candidate token');
SQL
)"

RYE_INSTANCES="[{\"id\":\"mcp-security\",\"label\":\"MCP Security\",\"databaseUrl\":\"${DATABASE_URL}\"}]" \
DEFAULT_INSTANCE="mcp-security" \
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

node --check "$MCP_SCRIPT"

if grep_text 'db_url|docker_container|docker_user|docker_db' "$MCP_SCRIPT"; then
  echo "Secure MCP server must not accept DB or Docker target override fields" >&2
  exit 1
fi

read_tools="$(RYE_API_URL="$BASE_URL" RYE_AGENT_TOKEN="$read_token" RYE_MCP_PRINT_TOOLS=1 node "$MCP_SCRIPT")"
candidate_tools="$(RYE_API_URL="$BASE_URL" RYE_AGENT_TOKEN="$candidate_token" RYE_MCP_PRINT_TOOLS=1 node "$MCP_SCRIPT")"

if [[ "$read_tools" != *"rye.get_context_pack"* || "$read_tools" != *"rye.list_domains"* ]]; then
  echo "Read-only MCP agent did not expose expected read tools" >&2
  echo "$read_tools" >&2
  exit 1
fi

if [[ "$read_tools" == *"rye.propose_structural_candidate"* || "$read_tools" == *"rye.submit_observation"* ]]; then
  echo "Read-only MCP agent exposed write tools" >&2
  echo "$read_tools" >&2
  exit 1
fi

if [[ "$candidate_tools" != *"rye.propose_structural_candidate"* || "$candidate_tools" != *"rye.submit_observation"* ]]; then
  echo "Candidate MCP agent did not expose expected candidate tools" >&2
  echo "$candidate_tools" >&2
  exit 1
fi

if [[ "$candidate_tools" == *"promote"* || "$read_tools" == *"promote"* ]]; then
  echo "Secure MCP server must not expose promotion tools" >&2
  echo "$candidate_tools" >&2
  exit 1
fi

if ! grep_text 'maxPayloadBytes|ensurePayloadSize|statement: z[.]string[(][)][.]min[(]1[)][.]max[(]4000[)]' "$MCP_SCRIPT"; then
  echo "Secure MCP server is missing oversized or invalid payload guards" >&2
  exit 1
fi

echo "Secure MCP simulation test passed"
