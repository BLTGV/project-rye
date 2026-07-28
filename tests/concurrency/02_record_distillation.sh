#!/usr/bin/env bash
set -euo pipefail
export PGOPTIONS="-c app.current_role=admin"

DB_URL="${DATABASE_URL:-}"
TEST_ROLE="${RYE_TEST_ROLE:-}"

if [[ -z "$DB_URL" ]]; then
  echo "DATABASE_URL is required" >&2
  exit 1
fi
if [[ -n "$TEST_ROLE" ]] && [[ ! "$TEST_ROLE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "RYE_TEST_ROLE must be a valid SQL identifier" >&2
  exit 1
fi

role_sql=""
if [[ -n "$TEST_ROLE" ]]; then
  role_sql="SET ROLE ${TEST_ROLE};"
fi

node_id="$(psql "$DB_URL" -Atqc "SELECT gen_random_uuid()")"

psql "$DB_URL" -v ON_ERROR_STOP=1 -qc "
${role_sql}
SET search_path = rye, public, pg_catalog;
SET "app.current_user_id" = 'conformance:distillation-concurrency';
SET "app.current_teams" = '';
INSERT INTO nodes (id, node_type, label, properties)
VALUES ('${node_id}', 'project', 'Distillation Concurrency', '{\"suite\":\"core-model-v2\"}');
"

source_id="$(psql "$DB_URL" -Atqc "
${role_sql}
SET search_path = rye, public, pg_catalog;
SET "app.current_user_id" = 'conformance:distillation-concurrency';
SELECT record_assertion(
    p_assertion_type := 'concurrency_source',
    p_assertion_key := 'default',
    p_subject_node_id := '${node_id}'::uuid,
    p_claim := '{\"version\":1}',
    p_basis := 'assumed'
);
")"

psql "$DB_URL" -v ON_ERROR_STOP=1 -qc "
${role_sql}
SET search_path = rye, public, pg_catalog;
SET "app.current_user_id" = 'conformance:distillation-concurrency';
SELECT record_distillation(
    p_subject_node_id := '${node_id}'::uuid,
    p_subject_edge_id := NULL,
    p_assertion_key := 'overview',
    p_claim := '{\"version\":0}',
    p_source_assertion_ids := ARRAY['${source_id}'::uuid],
    p_source_event_ids := '{}'::uuid[],
    p_agent := 'conformance:distillation-concurrency'
);
"

tmp_one="$(mktemp)"
tmp_two="$(mktemp)"
trap 'rm -f "$tmp_one" "$tmp_two"' EXIT

call_distillation() {
  local version="$1"
  local output="$2"
  psql "$DB_URL" -v ON_ERROR_STOP=1 -Atqc "
${role_sql}
SET search_path = rye, public, pg_catalog;
SET "app.current_user_id" = 'conformance:distillation-concurrency';
SELECT record_distillation(
    p_subject_node_id := '${node_id}'::uuid,
    p_subject_edge_id := NULL,
    p_assertion_key := 'overview',
    p_claim := jsonb_build_object('version', ${version}),
    p_source_assertion_ids := ARRAY['${source_id}'::uuid],
    p_source_event_ids := '{}'::uuid[],
    p_agent := 'conformance:distillation-concurrency'
);
" >"$output"
}

call_distillation 1 "$tmp_one" &
pid_one=$!
call_distillation 2 "$tmp_two" &
pid_two=$!

wait "$pid_one"
wait "$pid_two"

active_count="$(psql "$DB_URL" -Atqc "
${role_sql}
SET search_path = rye, public, pg_catalog;
SELECT count(*)
FROM current_valid_assertions
WHERE subject_node_id = '${node_id}'::uuid
  AND assertion_type = 'digest'
  AND assertion_key = 'overview';
")"

total_count="$(psql "$DB_URL" -Atqc "
${role_sql}
SET search_path = rye, public, pg_catalog;
SELECT count(*)
FROM assertions
WHERE subject_node_id = '${node_id}'::uuid
  AND assertion_type = 'digest'
  AND assertion_key = 'overview';
")"

if [[ "$active_count" != "1" || "$total_count" != "3" ]]; then
  echo "record_distillation concurrency ordering failed (active=${active_count} total=${total_count})" >&2
  exit 1
fi

echo "record_distillation concurrency test passed"
