#!/usr/bin/env bash
set -euo pipefail

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

tmp_file="$(mktemp)"

query="SET search_path = rye, public, pg_catalog; SELECT generate_crm_code('TST');"
if [[ -n "$TEST_ROLE" ]]; then
  query="SET ROLE ${TEST_ROLE}; ${query}"
fi

seq 1 40 | xargs -P10 -I{} psql "$DB_URL" -Atqc "$query" >> "$tmp_file"

line_count="$(wc -l < "$tmp_file" | tr -d ' ')"
unique_count="$(sort "$tmp_file" | uniq | wc -l | tr -d ' ')"

rm -f "$tmp_file"

if [[ "$line_count" != "40" || "$unique_count" != "40" ]]; then
  echo "Code generation is not unique under concurrency (lines=$line_count unique=$unique_count)" >&2
  exit 1
fi

echo "Code generation concurrency test passed"
