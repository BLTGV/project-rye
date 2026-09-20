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

categories_json="$("${rye_cmd[@]}" categories --json)"
require_contains "$categories_json" '"contract_version": 1' "categories --json"
require_contains "$categories_json" '"categories"' "categories --json"
require_contains "$categories_json" '"category_count"' "categories --json"
require_contains "$categories_json" '"empty"' "categories --json"

categories_unknown_json="$("${rye_cmd[@]}" categories --scope ffffffff-ffff-4fff-8fff-ffffffffffff --json)"
require_contains "$categories_unknown_json" '"scope_found": false' "categories --scope --json"
require_contains "$categories_unknown_json" '"empty": true' "categories --scope --json"

"${rye_cmd[@]}" categories >/dev/null

# settle-gate is the pre-write lookup for Rye's own configuration. A gated type
# answers gated true with its allowed roles; an unregistered type answers gated
# false with a null allowed_roles. The CLI sets no app.current_role, so
# may_settle is false for a gated type: that is the honest answer for a session
# with no role, and the smoke test pins it rather than leaving it to chance.
settle_gate_json="$("${rye_cmd[@]}" settle-gate registry_entry --json)"
require_contains "$settle_gate_json" '"assertion_type": "registry_entry"' "settle-gate --json"
require_contains "$settle_gate_json" '"gated": true' "settle-gate --json"
require_contains "$settle_gate_json" '"admin"' "settle-gate --json"
require_contains "$settle_gate_json" '"may_settle": false' "settle-gate --json"

settle_gate_policy_json="$("${rye_cmd[@]}" settle-gate review_policy --json)"
require_contains "$settle_gate_policy_json" '"gated": true' "settle-gate review_policy --json"

settle_gate_open_json="$("${rye_cmd[@]}" settle-gate cli_smoke_ungated_type --json)"
require_contains "$settle_gate_open_json" '"gated": false' "settle-gate ungated --json"
require_contains "$settle_gate_open_json" '"allowed_roles": null' "settle-gate ungated --json"
require_contains "$settle_gate_open_json" '"may_settle": true' "settle-gate ungated --json"

settle_gate_table="$("${rye_cmd[@]}" settle-gate registry_entry)"
require_contains "$settle_gate_table" "registry_entry" "settle-gate"
require_contains "$settle_gate_table" "admin" "settle-gate"

if "${rye_cmd[@]}" settle-gate >/dev/null 2>&1; then
  echo "Expected settle-gate with no assertion type to exit non-zero" >&2
  exit 1
fi

inventory_json="$("${rye_cmd[@]}" sources inventory --json)"
require_contains "$inventory_json" '[' "sources inventory --json"

pending_json="$("${rye_cmd[@]}" sources pending-context --json)"
require_contains "$pending_json" '[' "sources pending-context --json"

doctor_json="$("${rye_cmd[@]}" doctor --json)"
require_contains "$doctor_json" '"database_reachable": true' "doctor --json"

"${rye_cmd[@]}" plugins list >/dev/null
"${rye_cmd[@]}" status >/dev/null

echo "Rye CLI smoke test passed"
