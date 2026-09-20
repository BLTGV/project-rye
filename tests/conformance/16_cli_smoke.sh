#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required for CLI smoke tests}"

ENV_FILE="${TMPDIR:-/tmp}/rye-cli-smoke.env"
rm -f "$ENV_FILE"

rye_cmd=(./scripts/rye --db-url "$DATABASE_URL" --env-file "$ENV_FILE")

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

# Obligation 42.9 (docs/decisions/0013-leftovers-fail-restrictive.md): an
# unknown --scope is answered, never substituted. A key that names nothing and
# a uuid that names nothing take the identical path -- the documented empty
# answer with scope_found false -- and both exit non-zero, because the caller
# asked about something that does not exist. Before migration 0036 an unknown
# KEY resolved to NULL and the function answered with automatic scope
# selection, so an agent got another scope's vocabulary without a word.
categories_unknown_json="$("${rye_cmd[@]}" categories --scope ffffffff-ffff-4fff-8fff-ffffffffffff --json 2>/dev/null || true)"
require_contains "$categories_unknown_json" '"scope_found": false' "categories --scope uuid --json"
require_contains "$categories_unknown_json" '"empty": true' "categories --scope uuid --json"

if "${rye_cmd[@]}" categories --scope ffffffff-ffff-4fff-8fff-ffffffffffff --json >/dev/null 2>&1; then
  echo "Expected categories --scope <unknown uuid> --json to exit non-zero" >&2
  exit 1
fi

categories_unknown_key_json="$("${rye_cmd[@]}" categories --scope no-such-scope-key --json 2>/dev/null || true)"
require_contains "$categories_unknown_key_json" '"scope_found": false' "categories --scope key --json"
require_contains "$categories_unknown_key_json" '"empty": true' "categories --scope key --json"
require_contains "$categories_unknown_key_json" '"categories": []' "categories --scope key --json"
require_contains "$categories_unknown_key_json" '"mode": "explicit"' "categories --scope key --json"

if "${rye_cmd[@]}" categories --scope no-such-scope-key --json >/dev/null 2>&1; then
  echo "Expected categories --scope <unknown key> --json to exit non-zero" >&2
  exit 1
fi

categories_unknown_key_text="$("${rye_cmd[@]}" categories --scope no-such-scope-key 2>&1 || true)"
require_contains "$categories_unknown_key_text" "scope not found: no-such-scope-key" "categories --scope key"

# Anti-vacuity: the unscoped call answers, exits zero, and differs from the
# empty answer above. An unknown scope that returned what the unscoped call
# returns would pass every check above and still be the bug.
categories_all_json="$("${rye_cmd[@]}" categories --json)"
require_contains "$categories_all_json" '"category_count"' "categories --json"
if [[ "$categories_all_json" == *'"categories": []'* ]]; then
  echo "Expected the unscoped categories answer to list at least one category" >&2
  echo "$categories_all_json" >&2
  exit 1
fi
if [[ "$categories_all_json" == "$categories_unknown_key_json" ]]; then
  echo "An unknown --scope key returned the same answer as no --scope at all" >&2
  exit 1
fi

# The same rule governs context --scope.
context_unknown_key_json="$("${rye_cmd[@]}" context --scope no-such-scope-key --json 2>/dev/null || true)"
require_contains "$context_unknown_key_json" '"selected_scope_found": false' "context --scope key --json"
require_contains "$context_unknown_key_json" '"mode": "explicit"' "context --scope key --json"

if "${rye_cmd[@]}" context --scope no-such-scope-key --json >/dev/null 2>&1; then
  echo "Expected context --scope <unknown key> --json to exit non-zero" >&2
  exit 1
fi

context_unknown_key_text="$("${rye_cmd[@]}" context --scope no-such-scope-key 2>&1 || true)"
require_contains "$context_unknown_key_text" "scope not found: no-such-scope-key" "context --scope key"

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

# gated_as names the OTHER spelling and is null when the spelling given is
# itself the gated one, which is the case for both seeded configuration types.
require_contains "$settle_gate_json" '"gated_as": null' "settle-gate --json"

settle_gate_policy_json="$("${rye_cmd[@]}" settle-gate review_policy --json)"
require_contains "$settle_gate_policy_json" '"gated": true' "settle-gate review_policy --json"
require_contains "$settle_gate_policy_json" '"gated_as": null' "settle-gate review_policy --json"

settle_gate_open_json="$("${rye_cmd[@]}" settle-gate cli_smoke_ungated_type --json)"
require_contains "$settle_gate_open_json" '"gated": false' "settle-gate ungated --json"
require_contains "$settle_gate_open_json" '"gated_as": null' "settle-gate ungated --json"
require_contains "$settle_gate_open_json" '"allowed_roles": null' "settle-gate ungated --json"
require_contains "$settle_gate_open_json" '"may_settle": true' "settle-gate ungated --json"

settle_gate_table="$("${rye_cmd[@]}" settle-gate registry_entry)"
require_contains "$settle_gate_table" "registry_entry" "settle-gate"
require_contains "$settle_gate_table" "admin" "settle-gate"
# The table headers are the JSON field names, so the two forms cannot drift
# into two names for one value.
for field in assertion_type gated gated_as allowed_roles current_role may_settle; do
  require_contains "$settle_gate_table" "$field" "settle-gate header"
done
require_not_contains "$settle_gate_table" "session_role" "settle-gate header"

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
