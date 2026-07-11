#!/usr/bin/env bash
set -euo pipefail

DB_URL="${DATABASE_URL:-}"
RUNTIME_ROLE=""
SCHEMA="${RYE_SCHEMA:-rye}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-url)
      DB_URL="${2:-}"
      shift 2
      ;;
    --role)
      RUNTIME_ROLE="${2:-}"
      shift 2
      ;;
    --schema)
      SCHEMA="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$DB_URL" ]]; then
  echo "DATABASE_URL or --db-url is required" >&2
  exit 1
fi

if [[ ! "$RUNTIME_ROLE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "--role must name an existing PostgreSQL role" >&2
  exit 1
fi

if [[ ! "$SCHEMA" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "--schema must be a valid SQL identifier" >&2
  exit 1
fi

role_exists="$(psql "$DB_URL" -Atq -v runtime_role="$RUNTIME_ROLE" <<'SQL'
SELECT 1 FROM pg_roles WHERE rolname = :'runtime_role';
SQL
)"

if [[ "$role_exists" != "1" ]]; then
  echo "PostgreSQL role ${RUNTIME_ROLE} does not exist" >&2
  exit 1
fi

psql "$DB_URL" -v ON_ERROR_STOP=1 -q \
  -v runtime_role="$RUNTIME_ROLE" \
  -v rye_schema="$SCHEMA" <<'SQL'
SELECT format(
  'GRANT CONNECT ON DATABASE %I TO %I',
  current_database(),
  :'runtime_role'
) \gexec

SELECT format(
  'GRANT USAGE ON SCHEMA %I TO %I',
  :'rye_schema',
  :'runtime_role'
) \gexec

SELECT format(
  'GRANT EXECUTE ON FUNCTION %I.agent_context_pack_with_token(text,text,text,text[]) TO %I',
  :'rye_schema',
  :'runtime_role'
) \gexec

SELECT format(
  'GRANT EXECUTE ON FUNCTION %I.agent_search_nodes_with_token(text,text,text[],text,integer) TO %I',
  :'rye_schema',
  :'runtime_role'
) \gexec

SELECT format(
  'GRANT EXECUTE ON FUNCTION %I.agent_node_summary_with_token(text,uuid,text,integer) TO %I',
  :'rye_schema',
  :'runtime_role'
) \gexec

SELECT format(
  'GRANT EXECUTE ON FUNCTION %I.agent_submit_observation_with_token(text,jsonb) TO %I',
  :'rye_schema',
  :'runtime_role'
) \gexec

SELECT format(
  'GRANT EXECUTE ON FUNCTION %I.agent_create_candidate_with_token(text,jsonb,text) TO %I',
  :'rye_schema',
  :'runtime_role'
) \gexec
SQL

echo "Granted token-bound Rye agent runtime functions to ${RUNTIME_ROLE}"
