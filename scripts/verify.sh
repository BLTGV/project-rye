#!/usr/bin/env bash
set -euo pipefail

DB_URL="${DATABASE_URL:-}"

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

psql "$DB_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF current_setting('server_version_num')::int < 150000 THEN
    RAISE EXCEPTION 'PostgreSQL 15+ is required, got %', current_setting('server_version');
  END IF;

  IF to_regclass('nodes') IS NULL THEN v_missing := array_append(v_missing, 'nodes'); END IF;
  IF to_regclass('edges') IS NULL THEN v_missing := array_append(v_missing, 'edges'); END IF;
  IF to_regclass('events') IS NULL THEN v_missing := array_append(v_missing, 'events'); END IF;
  IF to_regclass('event_participants') IS NULL THEN v_missing := array_append(v_missing, 'event_participants'); END IF;
  IF to_regclass('assertions') IS NULL THEN v_missing := array_append(v_missing, 'assertions'); END IF;
  IF to_regclass('artifacts') IS NULL THEN v_missing := array_append(v_missing, 'artifacts'); END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'Missing core tables: %', array_to_string(v_missing, ', ');
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_name = 'assertions'
        AND column_name = 'assertion_key'
  ) THEN
    RAISE EXCEPTION 'assertions.assertion_key missing';
  END IF;

  IF to_regclass('idx_assertions_active_unique') IS NULL THEN
    RAISE EXCEPTION 'idx_assertions_active_unique index missing';
  END IF;

  IF to_regprocedure('supersede_assertion(uuid,text,uuid,uuid,jsonb,text,timestamp with time zone,uuid,numeric)') IS NULL THEN
    RAISE EXCEPTION 'supersede_assertion function signature missing';
  END IF;

  IF to_regprocedure('mark_assertion_superseded(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'mark_assertion_superseded function missing';
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relname = 'assertions'
        AND c.relrowsecurity = true
        AND c.relforcerowsecurity = true
  ) THEN
    RAISE EXCEPTION 'assertions RLS is not enabled+forced';
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM pg_policies
      WHERE tablename = 'assertions'
        AND policyname = 'assertion_update_policy'
        AND coalesce(qual, '') LIKE '%app.write_path%'
        AND coalesce(qual, '') LIKE '%app.supersede_assertion_id%'
        AND coalesce(with_check, '') LIKE '%app.write_path%'
        AND coalesce(with_check, '') LIKE '%app.supersede_assertion_id%'
  ) THEN
    RAISE EXCEPTION 'assertion_update_policy is not scoped to supersession context';
  END IF;
END
$$;
SQL

echo "Verification passed"
