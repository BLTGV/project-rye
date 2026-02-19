#!/usr/bin/env bash
set -euo pipefail

DB_URL="${DATABASE_URL:-}"
TEST_ROLE="${RYE_TEST_ROLE:-rye_conformance}"
USE_TEST_ROLE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-url)
      DB_URL="${2:-}"
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

export DATABASE_URL="$DB_URL"

./scripts/verify.sh --db-url "$DB_URL"

is_superuser="$(psql "$DB_URL" -Atqc "SELECT rolsuper FROM pg_roles WHERE rolname = current_user")"

if [[ "$is_superuser" == "t" ]]; then
  if [[ ! "$TEST_ROLE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "RYE_TEST_ROLE must be a valid SQL identifier" >&2
    exit 1
  fi

  psql "$DB_URL" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${TEST_ROLE}') THEN
    EXECUTE 'CREATE ROLE ${TEST_ROLE}';
  END IF;
END;
\$\$;

GRANT USAGE ON SCHEMA public TO ${TEST_ROLE};
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${TEST_ROLE};
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${TEST_ROLE};
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO ${TEST_ROLE};
SQL

  USE_TEST_ROLE=1
fi

run_sql_suite_file() {
  local file="$1"

  if [[ "$USE_TEST_ROLE" -eq 1 ]]; then
    psql "$DB_URL" -v ON_ERROR_STOP=1 <<SQL
SET ROLE ${TEST_ROLE};
\\i ${file}
RESET ROLE;
SQL
  else
    psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$file"
  fi
}

for file in $(find tests/conformance -maxdepth 1 -type f -name '*.sql' | sort); do
  echo "Running conformance test: $(basename "$file")"
  run_sql_suite_file "$file"
done

for file in $(find tests/conformance -maxdepth 1 -type f -name '*.sh' | sort); do
  echo "Running conformance test: $(basename "$file")"
  bash "$file"
done

for file in $(find tests/security -maxdepth 1 -type f -name '*.sql' | sort); do
  echo "Running security test: $(basename "$file")"
  run_sql_suite_file "$file"
done

for file in $(find tests/concurrency -maxdepth 1 -type f -name '*.sh' | sort); do
  echo "Running concurrency test: $(basename "$file")"
  if [[ "$USE_TEST_ROLE" -eq 1 ]]; then
    RYE_TEST_ROLE="$TEST_ROLE" bash "$file"
  else
    bash "$file"
  fi
done

# Scenario tests: seed data + per-scenario SQL + shell scripts
if [[ -d tests/scenarios ]]; then
  seed_file="tests/scenarios/00_seed.sql"
  if [[ -f "$seed_file" ]]; then
    echo "Seeding scenario data..."
    run_sql_suite_file "$seed_file"
  fi

  for file in $(find tests/scenarios -maxdepth 1 -type f -name '*.sql' ! -name '00_seed.sql' | sort); do
    echo "Running scenario test: $(basename "$file")"
    run_sql_suite_file "$file"
  done

  for file in $(find tests/scenarios -maxdepth 1 -type f -name '*.sh' | sort); do
    echo "Running scenario test: $(basename "$file")"
    if [[ "$USE_TEST_ROLE" -eq 1 ]]; then
      RYE_TEST_ROLE="$TEST_ROLE" bash "$file"
    else
      bash "$file"
    fi
  done
fi

echo "Conformance suite passed"
