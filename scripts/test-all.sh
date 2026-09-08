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

# 1. SQL schema: install + conformance + security tests, via the existing
#    docker-compose-managed postgres flow (scripts/docker-test.sh).
run_step "sql (docker-test.sh)" ./scripts/docker-test.sh test --reset --profiles crm,pm

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
