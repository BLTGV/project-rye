#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required for CDC runtime role tests}"

is_superuser="$(psql "$DATABASE_URL" -Atqc "SELECT rolsuper FROM pg_roles WHERE rolname = current_user")"
if [[ "$is_superuser" != "t" ]]; then
  echo "SKIP: CDC runtime role privilege test requires role administration"
  exit 0
fi

RUNTIME_ROLE="rye_cdc_boundary_test"
node_id=""
legacy_event_id=""
v2_event_id=""

cleanup() {
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null 2>&1 || true
SELECT set_config('app.current_role', 'admin', false);
DELETE FROM rye.event_participants WHERE event_id IN (
  '${legacy_event_id:-00000000-0000-0000-0000-000000000000}'::uuid,
  '${v2_event_id:-00000000-0000-0000-0000-000000000000}'::uuid
);
DELETE FROM rye.events WHERE id IN (
  '${legacy_event_id:-00000000-0000-0000-0000-000000000000}'::uuid,
  '${v2_event_id:-00000000-0000-0000-0000-000000000000}'::uuid
);
DELETE FROM rye.nodes WHERE id = '${node_id:-00000000-0000-0000-0000-000000000000}'::uuid;
DROP OWNED BY ${RUNTIME_ROLE};
DROP ROLE IF EXISTS ${RUNTIME_ROLE};
SQL
}
trap cleanup EXIT

cleanup
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
CREATE ROLE ${RUNTIME_ROLE};
GRANT USAGE ON SCHEMA rye TO ${RUNTIME_ROLE};
GRANT SELECT ON rye.nodes, rye.events, rye.event_participants, rye.access_grants TO ${RUNTIME_ROLE};
GRANT SELECT ON rye.events_safe TO ${RUNTIME_ROLE};
SQL

seed_output="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<'SQL'
SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false);
WITH inserted AS (
  INSERT INTO nodes (node_type, label, external_source, external_id)
  VALUES ('cdc_runtime_subject', 'CDC Runtime Subject', 'conformance', gen_random_uuid()::text)
  RETURNING id
)
SELECT id FROM inserted;
SQL
)"
node_id="$(tail -n 1 <<<"$seed_output")"

event_output="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq -v node_id="$node_id" <<'SQL'
SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false);
SELECT record_event(
  'domain_change',
  'Legacy CDC runtime boundary event',
  '{"schema":"public","table":"accounts","operation":"update","record_id":"1","old":{"secret":"raw-before"},"new":{"secret":"raw-after"}}'::jsonb,
  ARRAY[:'node_id'::uuid],
  ARRAY['subject'],
  'system:cdc'
);
SELECT record_event(
  'domain_change',
  'Protected CDC runtime boundary event',
  '{"schema":"public","table":"accounts","operation":"update","record_id":"1","cdc_payload_version":2,"old":{"secret":{"redacted":true,"sha256":"before"}},"new":{"secret":{"redacted":true,"sha256":"after"}}}'::jsonb,
  ARRAY[:'node_id'::uuid],
  ARRAY['subject'],
  'system:cdc'
);
SQL
)"
legacy_event_id="$(sed -n '2p' <<<"$event_output")"
v2_event_id="$(sed -n '3p' <<<"$event_output")"

counts="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq \
  -v legacy_event_id="$legacy_event_id" -v v2_event_id="$v2_event_id" <<SQL
SET ROLE ${RUNTIME_ROLE};
SELECT set_config('app.current_role', 'viewer', false);
SELECT count(*) FROM rye.events WHERE id = :'legacy_event_id'::uuid;
SELECT count(*) FROM rye.events WHERE id = :'v2_event_id'::uuid;
SELECT count(*) FROM rye.events_safe WHERE id = :'legacy_event_id'::uuid;
SELECT count(*) FROM rye.events_safe WHERE id = :'v2_event_id'::uuid;
SQL
)"

[[ "$counts" == $'viewer\n0\n1\n0\n1' ]] || {
  echo "CDC runtime role boundary failed: $counts" >&2
  exit 1
}

echo "CDC runtime role boundary test passed"
