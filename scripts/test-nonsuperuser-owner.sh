#!/usr/bin/env bash
# Runs install.sh + conformance.sh (and the security suite) against a
# database owned by an ordinary role: NOSUPERUSER, NOBYPASSRLS. Superuser
# owners bypass row-level security for themselves and for every SECURITY
# DEFINER function they own, so a CI run that only ever tests as a
# superuser owner never exercises the RLS path that Supabase (and any
# other managed Postgres) actually runs in production. This script brings
# up its own disposable postgres via scripts/docker-test.sh, provisions the
# ordinary owner the way Supabase pre-provisions one (extensions installed
# by the superuser, then handed to the owner), refuses to continue if that
# role turns out to be a superuser or may bypass RLS, and runs the whole
# suite from the host as that role so the node-dependent tests
# (21/22/23) execute instead of self-skipping.
#
# Calls scripts/docker-test.sh, scripts/install.sh, scripts/conformance.sh
# unmodified. Does not touch any other running container.
set -uo pipefail

cd "$(dirname "$0")/.."

# --- container lifecycle (delegates to docker-test.sh; own port/project) ---
export RYE_POSTGRES_PORT="${RYE_POSTGRES_PORT:-54351}"
POSTGRES_USER="${POSTGRES_USER:-rye}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-rye}"
POSTGRES_DB="${POSTGRES_DB:-rye}"

# --- ordinary owner role/database this step tests as ---
OWNER_ROLE="${RYE_OWNER_ROLE:-rye_owner}"
OWNER_PASSWORD="${RYE_OWNER_PASSWORD:-rye_owner_throwaway_pw}"
OWNER_DB="${RYE_OWNER_DB:-rye_nonsuperuser}"
PROFILES="${RYE_PROFILES:-crm,pm}"
SCHEMA="${RYE_SCHEMA:-rye}"
KEEP_RUNNING="${RYE_NONSUPERUSER_KEEP_RUNNING:-0}"

START_TS=$(date +%s)

fail() {
  echo "test-nonsuperuser-owner.sh: FAILED: $1" >&2
  exit 1
}

for ident in "$OWNER_ROLE" "$OWNER_DB"; do
  [[ "$ident" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "invalid identifier: $ident"
done

cleanup() {
  if [[ "$KEEP_RUNNING" -eq 0 ]]; then
    ./scripts/docker-test.sh down --volumes >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "=== bringing up disposable postgres (port ${RYE_POSTGRES_PORT}) ==="
./scripts/docker-test.sh up --reset || fail "could not start disposable postgres"

SUPERUSER_DSN="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:${RYE_POSTGRES_PORT}/${POSTGRES_DB}"
OWNER_DB_DSN="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:${RYE_POSTGRES_PORT}/${OWNER_DB}"
OWNER_DSN="postgresql://${OWNER_ROLE}:${OWNER_PASSWORD}@127.0.0.1:${RYE_POSTGRES_PORT}/${OWNER_DB}"

echo "=== provisioning ordinary owner role '${OWNER_ROLE}' (NOSUPERUSER NOBYPASSRLS) ==="
# psql variable interpolation (:'var') does not reach inside a dollar-quoted
# DO $$ ... $$ block, so the role/password are interpolated by bash here.
# OWNER_ROLE is already regex-validated above; the password is SQL-escaped.
OWNER_PASSWORD_ESCAPED="${OWNER_PASSWORD//\'/\'\'}"
psql "$SUPERUSER_DSN" -v ON_ERROR_STOP=1 <<EOF || fail "could not create owner role"
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${OWNER_ROLE}') THEN
    EXECUTE format(
      'CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',
      '${OWNER_ROLE}', '${OWNER_PASSWORD_ESCAPED}'
    );
  END IF;
END
\$\$;
EOF

echo "=== provisioning database '${OWNER_DB}' owned by '${OWNER_ROLE}' ==="
db_exists="$(psql "$SUPERUSER_DSN" -Atqc "SELECT 1 FROM pg_database WHERE datname = '${OWNER_DB}'")"
if [[ "$db_exists" != "1" ]]; then
  psql "$SUPERUSER_DSN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${OWNER_DB} OWNER ${OWNER_ROLE}" \
    || fail "could not create owner database"
fi

echo "=== creating extensions as superuser (mirrors Supabase pre-installed extensions) ==="
psql "$OWNER_DB_DSN" -v ON_ERROR_STOP=1 <<'SQL' || fail "could not create extensions"
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "btree_gin";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
SQL

echo "=== vacuity guard: refusing to test as a superuser or BYPASSRLS role ==="
role_flags="$(psql "$OWNER_DSN" -Atqc "SELECT rolsuper || ',' || rolbypassrls FROM pg_roles WHERE rolname = current_user" 2>&1)" \
  || fail "could not connect as ${OWNER_ROLE} to check its privileges: ${role_flags:-connection failed}"
is_super="${role_flags%%,*}"
is_bypass="${role_flags##*,}"
if [[ "$is_super" == "true" || "$is_bypass" == "true" ]]; then
  fail "role '${OWNER_ROLE}' has rolsuper=${is_super} rolbypassrls=${is_bypass}; this step exists to test as an ordinary, non-bypass-RLS owner (Supabase's configuration). Refusing before running any test."
fi
echo "role '${OWNER_ROLE}': rolsuper=${is_super} rolbypassrls=${is_bypass} — proceeding"

# The MCP simulation test (tests/conformance/22) needs this skill's own npm
# deps; CI only installs admin/ and site/, so install them here if absent.
# Skipped when the symlink/directory already exists (local dev checkouts).
if [[ -f skills/rye-source-context-intake/package.json && ! -d skills/rye-source-context-intake/node_modules ]]; then
  echo "=== installing skills/rye-source-context-intake dependencies (needed for host test 22) ==="
  npm ci --prefix skills/rye-source-context-intake || fail "npm ci for skills/rye-source-context-intake failed"
fi

echo "=== installing Rye (profiles: ${PROFILES}) as '${OWNER_ROLE}' ==="
DATABASE_URL="$OWNER_DSN" ./scripts/install.sh --profiles "$PROFILES" --schema "$SCHEMA" \
  || fail "install.sh failed as non-superuser owner"

echo "=== running conformance suite as '${OWNER_ROLE}' (from host, so tests 21/22/23 run) ==="
DATABASE_URL="$OWNER_DSN" ./scripts/conformance.sh --schema "$SCHEMA" \
  || fail "conformance.sh failed as non-superuser owner"

ELAPSED=$(( $(date +%s) - START_TS ))
echo "=== test-nonsuperuser-owner.sh passed in ${ELAPSED}s ==="

if [[ "$KEEP_RUNNING" -eq 1 ]]; then
  echo "Container kept running. Owner DSN: ${OWNER_DSN}"
fi
