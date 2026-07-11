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
  IF to_regclass('rye.artifacts') IS NULL THEN v_missing := array_append(v_missing, 'artifacts'); END IF;
  IF to_regclass('rye.node_domain_memberships') IS NULL THEN v_missing := array_append(v_missing, 'node_domain_memberships'); END IF;
  IF to_regclass('rye.process_transition_decisions') IS NULL THEN v_missing := array_append(v_missing, 'process_transition_decisions'); END IF;
  IF to_regclass('rye.read_model_refresh_policies') IS NULL THEN v_missing := array_append(v_missing, 'read_model_refresh_policies'); END IF;
  IF to_regclass('rye.read_model_refresh_state') IS NULL THEN v_missing := array_append(v_missing, 'read_model_refresh_state'); END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'Missing core tables: %', array_to_string(v_missing, ', ');
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = v_schema
        AND table_name = 'assertions'
        AND column_name = 'assertion_key'
  ) THEN
    RAISE EXCEPTION 'assertions.assertion_key missing';
  END IF;

  IF to_regclass('rye.idx_assertions_active_unique') IS NULL
     AND to_regclass('rye.idx_assertions_active_window_unique') IS NULL THEN
    RAISE EXCEPTION 'active assertion uniqueness index missing';
  END IF;

  IF to_regprocedure('rye.supersede_assertion(uuid,text,uuid,uuid,jsonb,text,timestamp with time zone,uuid,numeric)') IS NULL THEN
    RAISE EXCEPTION 'supersede_assertion function signature missing';
  END IF;

  IF to_regprocedure('rye.mark_assertion_superseded(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'mark_assertion_superseded function missing';
  END IF;

  IF to_regprocedure('rye.agent_context_pack_with_token(text,text,text,text[])') IS NULL
     OR to_regprocedure('rye.agent_search_nodes_with_token(text,text,text[],text,integer)') IS NULL
     OR to_regprocedure('rye.agent_node_summary_with_token(text,uuid,text,integer)') IS NULL
     OR to_regprocedure('rye.agent_submit_observation_with_token(text,jsonb)') IS NULL
     OR to_regprocedure('rye.agent_create_candidate_with_token(text,jsonb,text)') IS NULL
     OR to_regprocedure('rye.agent_review_queue_with_token(text,text,text,text,boolean,integer,integer)') IS NULL
     OR to_regprocedure('rye.agent_adjudicate_candidate_with_token(text,uuid,text,text)') IS NULL
     OR to_regprocedure('rye.agent_evaluate_process_transition_with_token(text,uuid,text,uuid,timestamp with time zone,boolean)') IS NULL
     OR to_regprocedure('rye.agent_promote_candidate_with_token(text,uuid,jsonb)') IS NULL
  THEN
    RAISE EXCEPTION 'token-bound agent runtime function signature missing';
  END IF;

  IF to_regprocedure('rye.sync_read_model_registry(text,interval)') IS NULL
     OR to_regprocedure('rye.refresh_read_model(text,text,boolean)') IS NULL
     OR to_regprocedure('rye.ensure_read_model_fresh(text,text)') IS NULL
     OR to_regprocedure('rye.refresh_due_materialized_views()') IS NULL
  THEN
    RAISE EXCEPTION 'read model freshness function signature missing';
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
        AND c.relname = 'node_domain_memberships'
        AND c.relrowsecurity = true
        AND c.relforcerowsecurity = true
  ) THEN
    RAISE EXCEPTION 'node_domain_memberships RLS is not enabled+forced';
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = v_schema
        AND c.relname = 'process_transition_decisions'
        AND c.relrowsecurity = true
        AND c.relforcerowsecurity = true
  ) THEN
    RAISE EXCEPTION 'process_transition_decisions RLS is not enabled+forced';
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM pg_policies
      WHERE schemaname = v_schema
        AND tablename = 'events'
        AND policyname = 'event_read_policy'
        AND coalesce(qual, '') LIKE '%cdc_payload_version%'
  ) THEN
    RAISE EXCEPTION 'event_read_policy does not fail closed for legacy CDC payloads';
  END IF;

  IF EXISTS (
      SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
      WHERE n.nspname = v_schema
        AND p.proname IN (
          'authenticate_agent_token',
          'agent_get_context_pack',
          'agent_submit_observation',
          'agent_create_candidate'
        )
        AND acl.grantee = 0
        AND acl.privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'raw identity-taking agent helper remains executable by PUBLIC';
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM pg_policies
      WHERE schemaname = v_schema
        AND tablename = 'assertions'
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
