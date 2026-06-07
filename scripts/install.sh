#!/usr/bin/env bash
set -euo pipefail

DB_URL="${DATABASE_URL:-}"
PROFILES="${RYE_PROFILES:-crm,pm}"
SCHEMA="${RYE_SCHEMA:-rye}"
SEED=0
VERIFY=1

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
    --seed)
      SEED=1
      shift
      ;;
    --no-verify)
      VERIFY=0
      shift
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

echo "Installing Rye schema (profiles: ${PROFILES})"
./scripts/migrate.sh --db-url "$DB_URL" --profiles "$PROFILES" --schema "$SCHEMA"

echo "Syncing Rye plugin metadata"
./scripts/sync_plugin_metadata.sh --db-url "$DB_URL" --schema "$SCHEMA"

if [[ "$SEED" -eq 1 ]]; then
  echo "Seeding quickstart data"
  ./scripts/seed_quickstart.sh --db-url "$DB_URL" --schema "$SCHEMA"
fi

if [[ "$VERIFY" -eq 1 ]]; then
  echo "Running verification"
  ./scripts/verify.sh --db-url "$DB_URL" --schema "$SCHEMA"
fi

echo "Install complete"
