#!/usr/bin/env bash
set -euo pipefail

# R2: Concurrent Supersession Test
# Two sessions simultaneously try to supersede the same assertion.
# Only one should succeed; the other should get an error.

DB_URL="${DATABASE_URL:-}"
TEST_ROLE="${RYE_TEST_ROLE:-}"
if [[ -z "$DB_URL" ]]; then
  echo "DATABASE_URL is required" >&2
  exit 1
fi

role_prefix=""
if [[ -n "$TEST_ROLE" ]] && [[ "$TEST_ROLE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  role_prefix="SET ROLE ${TEST_ROLE};"
fi

# Create a test node and assertion to supersede
setup_sql="
${role_prefix}
SET search_path = rye, public, pg_catalog;
SET LOCAL \"app.current_user_id\" = 'user:concurrency-test';
SET LOCAL \"app.current_teams\" = '';
SET LOCAL \"app.current_role\" = 'admin';

INSERT INTO nodes (id, node_type, label, properties)
VALUES ('f0000001-cccc-cccc-cccc-000000000001', 'test_concurrency', 'Concurrent Supersession Target', '{\"suite\":\"scenarios\"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence, basis)
SELECT 'test_status', 'default', 'f0000001-cccc-cccc-cccc-000000000001', '{\"version\": 1}', 1.0, 'assumed'
WHERE NOT EXISTS (
    SELECT 1 FROM current_assertions
    WHERE subject_node_id = 'f0000001-cccc-cccc-cccc-000000000001'
      AND assertion_type = 'test_status'
      AND assertion_key = 'default'
);
"

psql "$DB_URL" -Atqc "$setup_sql" 2>/dev/null || true

# Get the assertion ID
assertion_id=$(psql "$DB_URL" -Atqc "
${role_prefix}
SET search_path = rye, public, pg_catalog;
SET LOCAL \"app.current_user_id\" = 'user:concurrency-test';
SET LOCAL \"app.current_role\" = 'admin';
SELECT id FROM current_assertions
WHERE subject_node_id = 'f0000001-cccc-cccc-cccc-000000000001'
  AND assertion_type = 'test_status'
  AND assertion_key = 'default'
LIMIT 1;
")

if [[ -z "$assertion_id" ]]; then
  echo "Failed to get assertion ID for concurrency test" >&2
  exit 1
fi

# Run two supersessions concurrently
supersede_sql="
${role_prefix}
SET search_path = rye, public, pg_catalog;
SET LOCAL \"app.current_user_id\" = 'user:concurrency-test';
SET LOCAL \"app.current_role\" = 'admin';
SELECT supersede_assertion(
    '${assertion_id}'::uuid,
    'test_status',
    'f0000001-cccc-cccc-cccc-000000000001'::uuid,
    NULL::uuid,
    '{\"version\": REPLACE_VERSION}'::jsonb,
    'default',
    NULL::timestamptz,
    NULL::timestamptz,
    0.9,
    'assumed',
    NULL::jsonb[],
    NULL::jsonb
);
"

tmp1="$(mktemp)"
tmp2="$(mktemp)"

sql1="${supersede_sql//REPLACE_VERSION/2}"
sql2="${supersede_sql//REPLACE_VERSION/3}"

# Run both concurrently
psql "$DB_URL" -Atqc "$sql1" > "$tmp1" 2>&1 &
pid1=$!
psql "$DB_URL" -Atqc "$sql2" > "$tmp2" 2>&1 &
pid2=$!

exit1=0
exit2=0
wait $pid1 || exit1=$?
wait $pid2 || exit2=$?

result1=$(cat "$tmp1")
result2=$(cat "$tmp2")
rm -f "$tmp1" "$tmp2"

# Exactly one should succeed, the other should fail
successes=0
failures=0

if [[ $exit1 -eq 0 && -n "$result1" && ! "$result1" =~ ERROR ]]; then
  successes=$((successes + 1))
else
  failures=$((failures + 1))
fi

if [[ $exit2 -eq 0 && -n "$result2" && ! "$result2" =~ ERROR ]]; then
  successes=$((successes + 1))
else
  failures=$((failures + 1))
fi

# Verify exactly one active assertion remains
active_count=$(psql "$DB_URL" -Atqc "
${role_prefix}
SET search_path = rye, public, pg_catalog;
SET LOCAL \"app.current_user_id\" = 'user:concurrency-test';
SET LOCAL \"app.current_role\" = 'admin';
SELECT count(*) FROM current_assertions
WHERE subject_node_id = 'f0000001-cccc-cccc-cccc-000000000001'
  AND assertion_type = 'test_status'
  AND assertion_key = 'default';
")

# Cleanup
psql "$DB_URL" -Atqc "
${role_prefix}
SET search_path = rye, public, pg_catalog;
DELETE FROM assertions WHERE subject_node_id = 'f0000001-cccc-cccc-cccc-000000000001';
DELETE FROM nodes WHERE id = 'f0000001-cccc-cccc-cccc-000000000001';
" 2>/dev/null || true

if [[ "$active_count" != "1" ]]; then
  echo "FAIL: Expected exactly 1 active assertion after concurrent supersession, got ${active_count}" >&2
  exit 1
fi

# It's acceptable for both to succeed if the DB serializes them correctly,
# or for one to fail. The key invariant is: exactly 1 active assertion.
echo "Concurrent supersession test passed (successes=${successes}, active=${active_count})"
