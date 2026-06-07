#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required for CLI smoke tests}"

ENV_FILE="${TMPDIR:-/tmp}/rye-cli-smoke.env"
rm -f "$ENV_FILE"

rye_cmd=(./scripts/rye --db-url "$DATABASE_URL" --env-file "$ENV_FILE")

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

bash -n ./scripts/rye

status_json="$("${rye_cmd[@]}" status --json)"
require_contains "$status_json" '"catalog"' "status --json"
require_contains "$status_json" '"skills"' "status --json"

plugins_json="$("${rye_cmd[@]}" catalog plugins --json)"
require_contains "$plugins_json" '"plugins"' "catalog plugins --json"
require_contains "$plugins_json" 'rye-source-context' "catalog plugins --json"

skills_json="$("${rye_cmd[@]}" catalog skills --json)"
require_contains "$skills_json" '"skills"' "catalog skills --json"
require_contains "$skills_json" 'rye-onboarding' "catalog skills --json"

capabilities_json="$("${rye_cmd[@]}" catalog capabilities --json)"
require_contains "$capabilities_json" '"capabilities"' "catalog capabilities --json"
require_contains "$capabilities_json" 'read-rye-knowledge' "catalog capabilities --json"

context_json="$("${rye_cmd[@]}" context --json)"
require_contains "$context_json" '"scope_selection"' "context --json"

inventory_json="$("${rye_cmd[@]}" sources inventory --json)"
require_contains "$inventory_json" '[' "sources inventory --json"

pending_json="$("${rye_cmd[@]}" sources pending-context --json)"
require_contains "$pending_json" '[' "sources pending-context --json"

doctor_json="$("${rye_cmd[@]}" doctor --json)"
require_contains "$doctor_json" '"database_reachable": true' "doctor --json"

"${rye_cmd[@]}" plugins list >/dev/null
"${rye_cmd[@]}" status >/dev/null

echo "Rye CLI smoke test passed"
