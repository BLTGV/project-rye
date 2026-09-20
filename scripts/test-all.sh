#!/usr/bin/env bash
# Runs every test suite this repo already defines, in one command.
# Does not invent new tests: it only orchestrates scripts/docker-test.sh
# (SQL schema install + conformance + security tests against a disposable
# docker-compose postgres) and the admin/site build commands.
# Exits non-zero and names every failed part if anything fails.
set -uo pipefail

cd "$(dirname "$0")/.."

FAILED=()

run_step() {
  local name="$1"
  shift
  echo
  echo "=== ${name} ==="
  if "$@"; then
    echo "=== ${name}: OK ==="
  else
    echo "=== ${name}: FAILED ==="
    FAILED+=("$name")
  fi
}

# The node-dependent conformance tests (21/22/23) run from the host and need
# this skill's own npm deps; CI only runs `npm ci` for admin/ and site/, so
# install them here once, ahead of any step that runs the suite. Skipped
# when node_modules already exists (e.g. a local symlink into a sibling
# checkout).
if [[ -f skills/rye-source-context-intake/package.json && ! -d skills/rye-source-context-intake/node_modules ]]; then
  echo
  echo "=== installing skills/rye-source-context-intake dependencies ==="
  npm ci --prefix skills/rye-source-context-intake
fi

# 1. SQL schema: install + conformance + security tests, via the existing
#    docker-compose-managed postgres flow (scripts/docker-test.sh). This
#    owner is a superuser, so it bypasses row-level security for itself and
#    every SECURITY DEFINER function it owns — the same shape as a local
#    Postgres superuser, not Supabase.
run_step "sql (docker-test.sh)" ./scripts/docker-test.sh test --reset --profiles crm,pm

# 1b. Same suite, owned by an ordinary NOSUPERUSER NOBYPASSRLS role — the
#     shape Supabase actually runs in production. Row-level security and
#     SECURITY DEFINER functions are exercised for real here; step 1 alone
#     cannot catch bugs that only RLS enforcement would surface.
run_step "sql (nonsuperuser owner)" ./scripts/test-nonsuperuser-owner.sh

# 2. Admin app (Cloudflare Worker + Vite/React): typecheck + build.
if [[ -f admin/package.json ]]; then
  run_step "admin build" bash -c "cd admin && npm run build"
else
  echo "admin/package.json not found; skipping admin build"
fi

# 3. Site (Astro on Cloudflare): build.
if [[ -f site/package.json ]]; then
  run_step "site build" bash -c "cd site && npm run build"
else
  echo "site/package.json not found; skipping site build"
fi

echo
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "FAILED: ${FAILED[*]}"
  exit 1
fi

echo "All test-all.sh steps passed."
