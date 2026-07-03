#!/usr/bin/env bash
set -euo pipefail

DB_URL="${DATABASE_URL:-}"
PROFILES="${RYE_PROFILES:-crm,pm}"
SCHEMA="${RYE_SCHEMA:-rye}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-url)
      DB_URL="${2:-}"
      shift 2
      ;;
    --profiles)
      PROFILES="${2:-}"
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

profile_enabled() {
  local needle="$1"
  local list=",${PROFILES},"
  [[ "$list" == *",${needle},"* ]]
}

# rye_migrations stays in public so the migrator can find it without knowing the schema.
# Schema-qualified everywhere: if the DB role name matches an existing schema (e.g. role
# "rye" + schema "rye"), the default search_path would otherwise resolve unqualified
# references to a shadow table in that schema, hiding public.rye_migrations.
psql "$DB_URL" -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.rye_migrations (
  name text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
SQL

for file in $(find schema/migrations -maxdepth 1 -type f -name '*.sql' | sort); do
  base="$(basename "$file")"

  if [[ "$base" == *profile_crm*.sql ]] && ! profile_enabled "crm"; then
    echo "Skipping $base (crm profile disabled)"
    continue
  fi

  if [[ "$base" == *profile_pm*.sql ]] && ! profile_enabled "pm"; then
    echo "Skipping $base (pm profile disabled)"
    continue
  fi

  applied="$(psql "$DB_URL" -Atqc "SELECT 1 FROM public.rye_migrations WHERE name = '$base' LIMIT 1")"
  if [[ "$applied" == "1" ]]; then
    echo "Already applied: $base"
    continue
  fi

  echo "Applying $base"
  psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$file"
  psql "$DB_URL" -v ON_ERROR_STOP=1 -c "INSERT INTO public.rye_migrations(name) VALUES ('$base')"
done

echo "Migrations complete"
