#!/usr/bin/env bash
set -euo pipefail

DB_URL="${DATABASE_URL:-}"
SCHEMA="${RYE_SCHEMA:-rye}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-url)
      DB_URL="${2:-}"
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

psql "$DB_URL" -v ON_ERROR_STOP=1 -v rye_schema="$SCHEMA" <<'SQL'
DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_schema text := 'rye';
BEGIN
  IF current_setting('server_version_num')::int < 150000 THEN
    RAISE EXCEPTION 'PostgreSQL 15+ is required, got %', current_setting('server_version');
  END IF;

  -- Verify schema exists
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = v_schema) THEN
    RAISE EXCEPTION 'Schema "%" does not exist', v_schema;
  END IF;

  IF to_regclass('rye.nodes') IS NULL THEN v_missing := array_append(v_missing, 'nodes'); END IF;
  IF to_regclass('rye.edges') IS NULL THEN v_missing := array_append(v_missing, 'edges'); END IF;
  IF to_regclass('rye.events') IS NULL THEN v_missing := array_append(v_missing, 'events'); END IF;
  IF to_regclass('rye.event_participants') IS NULL THEN v_missing := array_append(v_missing, 'event_participants'); END IF;
  IF to_regclass('rye.assertions') IS NULL THEN v_missing := array_append(v_missing, 'assertions'); END IF;
  IF to_regclass('rye.assertion_evidence') IS NULL THEN v_missing := array_append(v_missing, 'assertion_evidence'); END IF;
  IF to_regclass('rye.artifacts') IS NULL THEN v_missing := array_append(v_missing, 'artifacts'); END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'Missing core tables: %', array_to_string(v_missing, ', ');
  END IF;

  IF EXISTS (
      SELECT required.column_name
      FROM (VALUES
          ('assertion_key'),
          ('status'),
          ('basis'),
          ('classification'),
          ('effective_to')
      ) required(column_name)
      WHERE NOT EXISTS (
          SELECT 1
          FROM information_schema.columns c
          WHERE c.table_schema = v_schema
            AND c.table_name = 'assertions'
            AND c.column_name = required.column_name
      )
  ) THEN
    RAISE EXCEPTION 'one or more Core Model v2 assertion columns are missing';
  END IF;

  IF EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = v_schema
        AND table_name = 'assertions'
        AND column_name = 'source_event_id'
  ) THEN
    RAISE EXCEPTION 'removed assertions.source_event_id column is still present';
  END IF;

  IF to_regclass('rye.idx_assertions_active_unique') IS NULL
     AND to_regclass('rye.idx_assertions_active_window_unique') IS NULL THEN
    RAISE EXCEPTION 'active assertion uniqueness index missing';
  END IF;

  IF to_regprocedure('rye.supersede_assertion(uuid,text,uuid,uuid,jsonb,text,timestamp with time zone,timestamp with time zone,numeric,text,jsonb[],jsonb)') IS NULL THEN
    RAISE EXCEPTION 'supersede_assertion function signature missing';
  END IF;

  IF to_regprocedure('rye.record_assertion(text,jsonb,uuid,uuid,text,timestamp with time zone,timestamp with time zone,numeric,text,text,jsonb[],text,jsonb,uuid)') IS NULL THEN
    RAISE EXCEPTION 'record_assertion knowledge-mechanisms signature missing';
  END IF;
  IF to_regprocedure('rye.accept_assertion(uuid,jsonb[],text,text,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'accept_assertion function missing';
  END IF;
  IF to_regprocedure('rye.reject_candidate(uuid,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'reject_candidate function missing';
  END IF;
  IF to_regprocedure('rye.record_distillation(uuid,uuid,text,jsonb,uuid[],uuid[],text,text,uuid,numeric,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'record_distillation function missing';
  END IF;
  IF to_regprocedure('rye.resolve_knowledge_gap(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'resolve_knowledge_gap function missing';
  END IF;
  IF to_regprocedure('rye.schedule_assertion_change(uuid,uuid,text,text,jsonb,timestamp with time zone,text,text,text,numeric,jsonb[],jsonb)') IS NULL THEN
    RAISE EXCEPTION 'schedule_assertion_change function missing';
  END IF;
  IF to_regprocedure('rye.registry_value(text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'registry_value function missing';
  END IF;
  IF to_regprocedure('rye.effective_confidence(rye.assertions)') IS NULL THEN
    RAISE EXCEPTION 'effective_confidence function missing';
  END IF;
  IF to_regprocedure('rye.governing_scope(uuid,uuid,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'governing_scope function missing';
  END IF;
  IF to_regprocedure('rye.canonical_type(text,text)') IS NULL THEN
    RAISE EXCEPTION 'canonical_type function missing';
  END IF;
  IF to_regprocedure('rye.record_prediction(uuid,uuid,text,text,text,jsonb,numeric,timestamp with time zone,uuid,text,uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'record_prediction function missing';
  END IF;
  IF to_regprocedure('rye.score_due_predictions()') IS NULL THEN
    RAISE EXCEPTION 'score_due_predictions function missing';
  END IF;
  IF to_regprocedure('rye.record_pattern(text,jsonb,uuid[],text,uuid[],uuid[],uuid,numeric,text,uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'record_pattern function missing';
  END IF;

  IF to_regprocedure('rye.mark_assertion_superseded(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'mark_assertion_superseded function missing';
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = v_schema
        AND c.relname = 'assertions'
        AND c.relrowsecurity = true
        AND c.relforcerowsecurity = true
  ) THEN
    RAISE EXCEPTION 'assertions RLS is not enabled+forced';
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = v_schema
        AND c.relname = 'assertion_evidence'
        AND c.relrowsecurity = true
        AND c.relforcerowsecurity = true
  ) THEN
    RAISE EXCEPTION 'assertion_evidence RLS is not enabled+forced';
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM pg_policies
      WHERE schemaname = v_schema
        AND tablename = 'assertions'
        AND policyname = 'assertion_update_policy'
        AND coalesce(qual, '') LIKE '%app.write_path%'
        AND coalesce(qual, '') LIKE '%app.supersede_assertion_id%'
        AND coalesce(qual, '') LIKE '%app.accept_assertion_id%'
        AND coalesce(qual, '') LIKE '%app.classification_assertion_id%'
        AND coalesce(qual, '') LIKE '%app.outcome_assertion_id%'
        AND coalesce(with_check, '') LIKE '%app.write_path%'
        AND coalesce(with_check, '') LIKE '%app.supersede_assertion_id%'
        AND coalesce(with_check, '') LIKE '%app.accept_assertion_id%'
        AND coalesce(with_check, '') LIKE '%app.classification_assertion_id%'
        AND coalesce(with_check, '') LIKE '%app.outcome_assertion_id%'
  ) THEN
    RAISE EXCEPTION 'assertion_update_policy is not scoped to v2 helper contexts';
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM pg_policies
      WHERE schemaname = v_schema
        AND tablename = 'artifacts'
        AND policyname = 'artifact_read_policy'
        AND coalesce(qual, '') LIKE '%classification%'
        AND coalesce(qual, '') LIKE '%role_classification_access%'
  ) THEN
    RAISE EXCEPTION 'artifact_read_policy does not enforce propagated digest classification';
  END IF;

  IF EXISTS (
      SELECT required.view_name
      FROM (VALUES
          ('review_queue'),
          ('stale_digests'),
          ('open_gaps'),
          ('assertion_support'),
          ('competing_candidates'),
          ('current_assertions_weighted'),
          ('node_salience'),
          ('type_vocabulary_report'),
          ('source_reliability'),
          ('calibration_report'),
          ('pattern_support')
      ) required(view_name)
      WHERE NOT EXISTS (
          SELECT 1
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = v_schema
            AND c.relname = required.view_name
            AND 'security_invoker=true' = ANY(coalesce(c.reloptions, '{}'::text[]))
      )
  ) THEN
    RAISE EXCEPTION 'one or more Core Model v2 security_invoker views are missing';
  END IF;

  IF EXISTS (
      SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = v_schema
        AND p.proname IN (
            'contest_assertion',
            'resolve_dispute',
            'promote_candidate_to_assertion'
        )
  ) OR to_regclass('rye.active_disputes') IS NOT NULL THEN
    RAISE EXCEPTION 'removed v1 dispute or fact-promotion surfaces are still installed';
  END IF;
END
$$;
SQL

echo "Verification passed"
