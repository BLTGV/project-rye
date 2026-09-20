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

  IF to_regprocedure('rye.rye_categories(uuid)') IS NULL THEN
    RAISE EXCEPTION 'rye_categories function missing';
  END IF;
  IF to_regprocedure('rye.describe_category(text,text,uuid,text,text,jsonb[],numeric)') IS NULL THEN
    RAISE EXCEPTION 'describe_category function missing';
  END IF;

  IF to_regprocedure('rye.rye_settlers(uuid,text,uuid,text,text,text,timestamp with time zone,text)') IS NULL THEN
    RAISE EXCEPTION 'rye_settlers function missing';
  END IF;
  IF to_regprocedure('rye.rye_settler_resolve_ref(text)') IS NULL THEN
    RAISE EXCEPTION 'rye_settler_resolve_ref function missing';
  END IF;
  IF to_regprocedure('rye.rye_settler_is_agent(text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'rye_settler_is_agent function missing';
  END IF;

  IF to_regprocedure('rye.mark_assertion_superseded(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'mark_assertion_superseded function missing';
  END IF;

  -- Configuration writes need an admin: the gate is data, one read function,
  -- and one trigger that no SECURITY DEFINER helper escapes.
  IF to_regprocedure('rye.settle_gate(text)') IS NULL THEN
    RAISE EXCEPTION 'settle_gate function missing';
  END IF;
  IF to_regprocedure('rye.assertion_settle_roles(text)') IS NULL THEN
    RAISE EXCEPTION 'assertion_settle_roles function missing';
  END IF;
  IF to_regprocedure('rye.may_settle_assertion_type(text)') IS NULL THEN
    RAISE EXCEPTION 'may_settle_assertion_type function missing';
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = v_schema
        AND c.relname = 'assertions'
        AND t.tgname = 'trg_assertion_settle_gate'
        AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'trg_assertion_settle_gate is missing from assertions';
  END IF;

  IF EXISTS (
      SELECT required.assertion_type
      FROM (VALUES ('registry_entry'), ('review_policy')) required(assertion_type)
      WHERE NOT EXISTS (
          SELECT 1
          FROM rye.assertion_type_access ata
          WHERE ata.assertion_type = required.assertion_type
            AND ata.operation = 'settle'
            AND 'admin' = ANY(ata.allowed_roles)
      )
  ) THEN
    RAISE EXCEPTION 'configuration assertion types are not settle-gated to admin';
  END IF;

  -- The row is the gate, not the route: the shape rules are triggers, so a
  -- missing trigger is a missing rule. The deferred one must stay deferred:
  -- the helpers point an incumbent at a replacement they insert afterwards.
  IF NOT EXISTS (
      SELECT 1
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = v_schema
        AND c.relname = 'assertions'
        AND t.tgname = 'trg_assertions_insert_review'
        AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'trg_assertions_insert_review is missing from assertions';
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = v_schema
        AND c.relname = 'assertions'
        AND t.tgname = 'trg_assertions_transition_complete'
        AND NOT t.tgisinternal
        AND t.tgdeferrable
        AND t.tginitdeferred
  ) THEN
    RAISE EXCEPTION 'trg_assertions_transition_complete is missing or not initially deferred';
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = v_schema
        AND c.relname = 'assertions'
        AND t.tgname = 'trg_assertions_immutable'
        AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'trg_assertions_immutable is missing from assertions';
  END IF;

  IF to_regprocedure('rye.assertion_outcome_values()') IS NULL
     OR to_regprocedure('rye.assertion_outcome_label_keys()') IS NULL
     OR to_regprocedure('rye.assertion_derived_classification(uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'assertion lifecycle gate helper functions are missing';
  END IF;

  -- Review policy holds on every route (0027). Three facts, each checked
  -- where it lives: the ranking helper exists, governing_scope() orders by
  -- it rather than by uuid alone, supersede_assertion() can write the
  -- review_gate marker, and the 0025 insert exemption is gone.
  IF to_regprocedure('rye.scope_review_policy_rank(uuid)') IS NULL THEN
    RAISE EXCEPTION 'scope_review_policy_rank function missing';
  END IF;

  IF to_regprocedure('rye.effective_review_policy(uuid,uuid,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'effective_review_policy function missing';
  END IF;

  -- Every helper that inserts an assertion takes the stricter of its two
  -- scope resolutions, or the insert guard can demote a row the helper meant
  -- to keep accepted and the commit-time check then refuses the transaction.
  IF EXISTS (
      SELECT required.name
      FROM (VALUES ('record_assertion'), ('supersede_assertion'), ('record_distillation'))
           required(name)
      WHERE NOT EXISTS (
          SELECT 1 FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = v_schema
            AND p.proname = required.name
            AND p.prosrc LIKE '%effective_review_policy%'
      )
  ) THEN
    RAISE EXCEPTION 'an assertion-inserting helper does not take the stricter of its two scope resolutions';
  END IF;

  IF NOT EXISTS (
      SELECT 1 FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = v_schema
        AND p.proname = 'governing_scope'
        AND p.prosrc LIKE '%scope_review_policy_rank%'
  ) THEN
    RAISE EXCEPTION 'governing_scope does not order by review policy restrictiveness';
  END IF;

  IF NOT EXISTS (
      SELECT 1 FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = v_schema
        AND p.proname = 'supersede_assertion'
        AND p.prosrc LIKE '%review_gate%'
  ) THEN
    RAISE EXCEPTION 'supersede_assertion does not apply the review policy';
  END IF;

  -- 0030: the other two helpers that demote say so, in the same marker.
  IF EXISTS (
      SELECT required.name
      FROM (VALUES ('record_assertion'), ('record_distillation')) required(name)
      WHERE NOT EXISTS (
          SELECT 1 FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = v_schema
            AND p.proname = required.name
            AND p.prosrc LIKE '%review_gate%'
      )
  ) THEN
    RAISE EXCEPTION 'record_assertion or record_distillation does not mark a review-policy demotion';
  END IF;

  IF EXISTS (
      SELECT 1 FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = v_schema
        AND p.proname = 'assertions_insert_review_guard'
        AND p.prosrc LIKE '%superseded_by = NEW.id%'
  ) THEN
    RAISE EXCEPTION 'the 0025 insert exemption is still present in assertions_insert_review_guard';
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

  -- The last two supporting tables to get RLS (0029). AGENTS.md promises it
  -- on all of them, and these two were the exceptions.
  IF EXISTS (
      SELECT 1
      FROM (VALUES ('crm_code_counters'), ('node_merges')) AS t(relname)
      WHERE NOT EXISTS (
          SELECT 1
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = v_schema
            AND c.relname = t.relname
            AND c.relrowsecurity = true
            AND c.relforcerowsecurity = true
      )
  ) THEN
    RAISE EXCEPTION 'crm_code_counters and node_merges must both have RLS enabled+forced';
  END IF;

  IF to_regprocedure('rye.rye_may_write_table(text)') IS NULL THEN
    RAISE EXCEPTION 'rye_may_write_table function missing';
  END IF;
  IF to_regprocedure('rye.rye_crm_code_counter_gate()') IS NULL THEN
    RAISE EXCEPTION 'rye_crm_code_counter_gate function missing';
  END IF;
  IF to_regprocedure('rye.rye_node_merge_gate()') IS NULL THEN
    RAISE EXCEPTION 'rye_node_merge_gate function missing';
  END IF;
  IF EXISTS (
      SELECT 1
      FROM (VALUES
          ('trg_crm_code_counters_gate', 'crm_code_counters'),
          ('trg_node_merges_gate', 'node_merges')
      ) AS t(tgname, relname)
      WHERE NOT EXISTS (
          SELECT 1
          FROM pg_trigger tg
          JOIN pg_class c ON c.oid = tg.tgrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = v_schema
            AND c.relname = t.relname
            AND tg.tgname = t.tgname
            AND NOT tg.tgisinternal
      )
  ) THEN
    RAISE EXCEPTION 'trg_crm_code_counters_gate or trg_node_merges_gate is missing';
  END IF;

  -- Source-map row identity (0031). The graph points at domain rows through
  -- node_source_map, so the key has to be the source row: keyed by node_id a
  -- merge could not re-point the duplicate's mapping and deleted it, and the
  -- source row lost its graph identity. One node holding several rows of one
  -- table is the shape a merge leaves behind.
  IF (
      SELECT string_agg(a.attname, ',' ORDER BY k.ord)
      FROM pg_constraint c
      JOIN pg_class rel ON rel.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = rel.relnamespace
      JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
      WHERE n.nspname = v_schema AND rel.relname = 'node_source_map' AND c.contype = 'p'
  ) IS DISTINCT FROM 'source_schema,source_table,source_id' THEN
    RAISE EXCEPTION
      'node_source_map is not keyed by (source_schema, source_table, source_id)';
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM pg_index i
      JOIN pg_class idx ON idx.oid = i.indexrelid
      JOIN pg_class rel ON rel.oid = i.indrelid
      JOIN pg_namespace n ON n.oid = rel.relnamespace
      WHERE n.nspname = v_schema
        AND rel.relname = 'node_source_map'
        AND idx.relname = 'idx_nsm_node'
  ) THEN
    RAISE EXCEPTION 'idx_nsm_node is missing: node_source_map.node_id has no index';
  END IF;

  IF to_regprocedure('rye.rye_restore_merged_source_maps()') IS NULL THEN
    RAISE EXCEPTION 'rye_restore_merged_source_maps function missing';
  END IF;

  -- Who may write: the role list is the write list, and the governance
  -- structure is admin-only. One column, one function, and one conjunct on
  -- every write policy of the seven core tables.
  IF to_regprocedure('rye.rye_role_may_write()') IS NULL THEN
    RAISE EXCEPTION 'rye_role_may_write function missing';
  END IF;
  IF to_regprocedure('rye.rye_gate_may_write()') IS NULL THEN
    RAISE EXCEPTION 'rye_gate_may_write function missing';
  END IF;

  -- The gate is a trigger, because an RLS conjunct does not run inside a
  -- SECURITY DEFINER function owned by a superuser. One on each core table.
  IF EXISTS (
      SELECT required.tablename
      FROM (VALUES
          ('nodes', 'trg_nodes_gate_may_write'),
          ('edges', 'trg_edges_gate_may_write'),
          ('events', 'trg_events_gate_may_write'),
          ('event_participants', 'trg_event_participants_gate_may_write'),
          ('assertions', 'trg_assertions_gate_may_write'),
          ('assertion_evidence', 'trg_assertion_evidence_gate_may_write'),
          ('artifacts', 'trg_artifacts_gate_may_write'),
          ('node_source_map', 'trg_node_source_map_gate_may_write')
      ) required(tablename, tgname)
      WHERE NOT EXISTS (
          SELECT 1
          FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
          JOIN pg_namespace ns ON ns.oid = c.relnamespace
          WHERE ns.nspname = v_schema
            AND c.relname = required.tablename
            AND t.tgname = required.tgname
            AND NOT t.tgisinternal
            AND t.tgtype & 1 = 1   -- FOR EACH ROW
            AND t.tgtype & 2 = 2   -- BEFORE
            AND t.tgtype & 28 = 28 -- INSERT, DELETE, UPDATE
      )
  ) THEN
    RAISE EXCEPTION 'one or more who-may-write gate triggers are missing or are not BEFORE INSERT OR UPDATE OR DELETE FOR EACH ROW';
  END IF;

  -- On assertions the order is load-bearing: the settle gate's message is
  -- asserted by tests/conformance/30_configuration_gate.sql, and the shape
  -- guards must run after the role is settled.
  IF NOT (
      (SELECT string_agg(t.tgname, ',' ORDER BY t.tgname)
       FROM pg_trigger t
       JOIN pg_class c ON c.oid = t.tgrelid
       JOIN pg_namespace ns ON ns.oid = c.relnamespace
       WHERE ns.nspname = v_schema
         AND c.relname = 'assertions'
         AND NOT t.tgisinternal
         AND t.tgname IN ('trg_assertion_settle_gate', 'trg_assertions_gate_may_write',
                          'trg_assertions_immutable', 'trg_assertions_insert_review'))
      = 'trg_assertion_settle_gate,trg_assertions_gate_may_write,trg_assertions_immutable,trg_assertions_insert_review'
  ) THEN
    RAISE EXCEPTION 'the assertions triggers do not sort settle gate, may-write gate, immutable, insert review';
  END IF;

  -- The reserved CDC role, so a tracked domain table still records its event
  -- when the application's session sets no Rye role.
  IF NOT EXISTS (
      SELECT 1 FROM rye.role_classification_access
      WHERE role_name = 'system:cdc'
        AND may_write = true
        AND classifications = ARRAY['public']
  ) THEN
    RAISE EXCEPTION 'the system:cdc role row is missing or is not may_write true with public classification only';
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM information_schema.columns c
      WHERE c.table_schema = v_schema
        AND c.table_name = 'role_classification_access'
        AND c.column_name = 'may_write'
  ) THEN
    RAISE EXCEPTION 'role_classification_access.may_write column missing';
  END IF;

  IF NOT EXISTS (
      SELECT 1 FROM rye.role_classification_access
      WHERE role_name = 'viewer' AND may_write = false
  ) THEN
    RAISE EXCEPTION 'the viewer role is not seeded read-only (may_write false)';
  END IF;

  IF EXISTS (
      SELECT required.tablename, required.cmd
      FROM (VALUES
          ('nodes', 'INSERT'), ('nodes', 'UPDATE'), ('nodes', 'DELETE'),
          ('edges', 'INSERT'), ('edges', 'UPDATE'), ('edges', 'DELETE'),
          ('events', 'INSERT'), ('events', 'UPDATE'), ('events', 'DELETE'),
          ('event_participants', 'INSERT'),
          ('event_participants', 'UPDATE'),
          ('event_participants', 'DELETE'),
          ('assertions', 'INSERT'), ('assertions', 'UPDATE'), ('assertions', 'DELETE'),
          ('assertion_evidence', 'INSERT'),
          ('assertion_evidence', 'UPDATE'),
          ('assertion_evidence', 'DELETE'),
          ('artifacts', 'INSERT'), ('artifacts', 'UPDATE'), ('artifacts', 'DELETE'),
          ('node_source_map', 'INSERT'), ('node_source_map', 'UPDATE'), ('node_source_map', 'DELETE')
      ) required(tablename, cmd)
      WHERE NOT EXISTS (
          SELECT 1
          FROM pg_policies p
          WHERE p.schemaname = v_schema
            AND p.tablename = required.tablename
            AND p.cmd = required.cmd
            AND (coalesce(p.qual, '') || coalesce(p.with_check, '')) LIKE '%rye_role_may_write%'
      )
  ) THEN
    RAISE EXCEPTION
      'one or more core write policies do not carry the rye_role_may_write conjunct: %',
      (SELECT string_agg(required.tablename || ' ' || required.cmd, ', ')
       FROM (VALUES
           ('nodes', 'INSERT'), ('nodes', 'UPDATE'), ('nodes', 'DELETE'),
           ('edges', 'INSERT'), ('edges', 'UPDATE'), ('edges', 'DELETE'),
           ('events', 'INSERT'), ('events', 'UPDATE'), ('events', 'DELETE'),
           ('event_participants', 'INSERT'),
           ('event_participants', 'UPDATE'),
           ('event_participants', 'DELETE'),
           ('assertions', 'INSERT'), ('assertions', 'UPDATE'), ('assertions', 'DELETE'),
           ('assertion_evidence', 'INSERT'),
           ('assertion_evidence', 'UPDATE'),
           ('assertion_evidence', 'DELETE'),
           ('artifacts', 'INSERT'), ('artifacts', 'UPDATE'), ('artifacts', 'DELETE'),
           ('node_source_map', 'INSERT'), ('node_source_map', 'UPDATE'), ('node_source_map', 'DELETE')
       ) required(tablename, cmd)
       WHERE NOT EXISTS (
           SELECT 1
           FROM pg_policies p
           WHERE p.schemaname = v_schema
             AND p.tablename = required.tablename
             AND p.cmd = required.cmd
             AND (coalesce(p.qual, '') || coalesce(p.with_check, '')) LIKE '%rye_role_may_write%'
       ));
  END IF;

  -- The governance structure is admin-only, and the test is row-local.
  IF EXISTS (
      SELECT 1
      FROM (VALUES ('INSERT'), ('UPDATE'), ('DELETE')) required(cmd)
      WHERE NOT EXISTS (
          SELECT 1
          FROM pg_policies p
          WHERE p.schemaname = v_schema
            AND p.tablename = 'nodes'
            AND p.cmd = required.cmd
            AND (coalesce(p.qual, '') || coalesce(p.with_check, '')) LIKE '%onboarding_scope%'
      )
  ) THEN
    RAISE EXCEPTION 'the nodes write policies do not gate onboarding_scope rows to an admin';
  END IF;

  IF EXISTS (
      SELECT 1
      FROM (VALUES ('INSERT'), ('UPDATE'), ('DELETE')) required(cmd)
      WHERE NOT EXISTS (
          SELECT 1
          FROM pg_policies p
          WHERE p.schemaname = v_schema
            AND p.tablename = 'edges'
            AND p.cmd = required.cmd
            AND (coalesce(p.qual, '') || coalesce(p.with_check, '')) LIKE '%scope_governs_subject%'
            AND (coalesce(p.qual, '') || coalesce(p.with_check, '')) LIKE '%scope_governs_source%'
            AND (coalesce(p.qual, '') || coalesce(p.with_check, '')) LIKE '%scope_enables_plugin%'
      )
  ) THEN
    RAISE EXCEPTION 'the edges write policies do not gate the three governance edge types to an admin';
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM rye.assertion_type_access ata
      WHERE ata.assertion_type = 'scope_status'
        AND ata.operation = 'settle'
        AND 'admin' = ANY(ata.allowed_roles)
  ) THEN
    RAISE EXCEPTION 'scope_status is not settle-gated to admin';
  END IF;

  IF to_regprocedure('rye.rye_current_agent_key()') IS NULL THEN
    RAISE EXCEPTION 'rye_current_agent_key function missing';
  END IF;
  IF to_regprocedure('rye.rye_current_agent_id()') IS NULL THEN
    RAISE EXCEPTION 'rye_current_agent_id function missing';
  END IF;

  -- The nine governance tables: RLS enabled AND forced on every one.
  IF EXISTS (
      SELECT required.table_name
      FROM (VALUES
          ('knowledge_domains'),
          ('domain_authorities'),
          ('channel_domain_subscriptions'),
          ('domain_claim_policies'),
          ('agent_identities'),
          ('agent_capability_grants'),
          ('agent_action_log'),
          ('api_idempotency_keys'),
          ('agent_api_tokens')
      ) required(table_name)
      WHERE NOT EXISTS (
          SELECT 1
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = v_schema
            AND c.relname = required.table_name
            AND c.relrowsecurity = true
            AND c.relforcerowsecurity = true
      )
  ) THEN
    RAISE EXCEPTION 'one or more governance tables are not RLS enabled+forced: %',
      (SELECT string_agg(required.table_name, ', ')
       FROM (VALUES
           ('knowledge_domains'),
           ('domain_authorities'),
           ('channel_domain_subscriptions'),
           ('domain_claim_policies'),
           ('agent_identities'),
           ('agent_capability_grants'),
           ('agent_action_log'),
           ('api_idempotency_keys'),
           ('agent_api_tokens')
       ) required(table_name)
       WHERE NOT EXISTS (
           SELECT 1
           FROM pg_class c
           JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = v_schema
             AND c.relname = required.table_name
             AND c.relrowsecurity = true
             AND c.relforcerowsecurity = true
       ));
  END IF;

  -- Every governance policy named by contracts/sql-surface.md is installed.
  IF EXISTS (
      SELECT required.policyname
      FROM (VALUES
          ('knowledge_domains', 'knowledge_domains_read_policy'),
          ('knowledge_domains', 'knowledge_domains_insert_policy'),
          ('knowledge_domains', 'knowledge_domains_update_policy'),
          ('knowledge_domains', 'knowledge_domains_delete_policy'),
          ('domain_authorities', 'domain_authorities_read_policy'),
          ('domain_authorities', 'domain_authorities_insert_policy'),
          ('domain_authorities', 'domain_authorities_update_policy'),
          ('domain_authorities', 'domain_authorities_delete_policy'),
          ('channel_domain_subscriptions', 'channel_domain_subscriptions_read_policy'),
          ('channel_domain_subscriptions', 'channel_domain_subscriptions_insert_policy'),
          ('channel_domain_subscriptions', 'channel_domain_subscriptions_update_policy'),
          ('channel_domain_subscriptions', 'channel_domain_subscriptions_delete_policy'),
          ('domain_claim_policies', 'domain_claim_policies_read_policy'),
          ('domain_claim_policies', 'domain_claim_policies_insert_policy'),
          ('domain_claim_policies', 'domain_claim_policies_update_policy'),
          ('domain_claim_policies', 'domain_claim_policies_delete_policy'),
          ('agent_identities', 'agent_identities_read_policy'),
          ('agent_identities', 'agent_identities_insert_policy'),
          ('agent_identities', 'agent_identities_update_policy'),
          ('agent_identities', 'agent_identities_delete_policy'),
          ('agent_capability_grants', 'agent_capability_grants_read_policy'),
          ('agent_capability_grants', 'agent_capability_grants_insert_policy'),
          ('agent_capability_grants', 'agent_capability_grants_update_policy'),
          ('agent_capability_grants', 'agent_capability_grants_delete_policy'),
          ('agent_action_log', 'agent_action_log_read_policy'),
          ('agent_action_log', 'agent_action_log_insert_policy'),
          ('api_idempotency_keys', 'api_idempotency_keys_read_policy'),
          ('api_idempotency_keys', 'api_idempotency_keys_insert_policy'),
          ('api_idempotency_keys', 'api_idempotency_keys_delete_policy'),
          ('agent_api_tokens', 'agent_api_tokens_admin_read'),
          ('agent_api_tokens', 'agent_api_tokens_admin_write')
      ) required(tablename, policyname)
      WHERE NOT EXISTS (
          SELECT 1
          FROM pg_policies p
          WHERE p.schemaname = v_schema
            AND p.tablename = required.tablename
            AND p.policyname = required.policyname
      )
  ) THEN
    RAISE EXCEPTION 'one or more governance RLS policies are missing';
  END IF;

  -- agent_action_log is append-only for everyone, admin included.
  IF EXISTS (
      SELECT 1
      FROM pg_policies
      WHERE schemaname = v_schema
        AND tablename = 'agent_action_log'
        AND cmd IN ('UPDATE', 'DELETE')
  ) THEN
    RAISE EXCEPTION 'agent_action_log has an UPDATE or DELETE policy; it must be append-only';
  END IF;

  -- The two writes made on a non-admin's behalf use the named write_path gate.
  IF NOT EXISTS (
      SELECT 1
      FROM pg_policies
      WHERE schemaname = v_schema
        AND tablename = 'agent_action_log'
        AND policyname = 'agent_action_log_insert_policy'
        AND coalesce(with_check, '') LIKE '%record_agent_action%'
  ) THEN
    RAISE EXCEPTION 'agent_action_log_insert_policy does not admit the record_agent_action gate';
  END IF;

  IF NOT EXISTS (
      SELECT 1
      FROM pg_policies
      WHERE schemaname = v_schema
        AND tablename = 'api_idempotency_keys'
        AND policyname = 'api_idempotency_keys_insert_policy'
        AND coalesce(with_check, '') LIKE '%agent_create_candidate%'
  ) THEN
    RAISE EXCEPTION 'api_idempotency_keys_insert_policy does not admit the agent_create_candidate gate';
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

  -- Graph traversal and entry points (0032). The visibility contract
  -- (design/proposals/rls-visibility-contract.md, D1) is a hard constraint,
  -- so it is checked here as well as in the suites: these five read the
  -- graph as the caller, and a definer or volatile one would be a topology
  -- disclosure or a write.
  IF to_regprocedure('rye.edge_semantics(text,uuid)') IS NULL
     OR to_regprocedure('rye.find_nodes(text,text[],integer,numeric,uuid)') IS NULL
     OR to_regprocedure('rye.find_nodes_batch(text[],text[],integer,numeric,uuid)') IS NULL
     OR to_regprocedure('rye.find_paths(uuid,uuid,integer,text[],text[],timestamptz,text,integer,uuid)') IS NULL
     OR to_regprocedure('rye.neighborhood(uuid,integer,text[],text[],timestamptz,text,integer,integer,uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'graph traversal functions are missing';
  END IF;

  IF EXISTS (
      SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = v_schema
        AND p.proname IN ('find_nodes', 'find_nodes_batch', 'find_paths',
                          'neighborhood', 'edge_semantics')
        AND (p.prosecdef OR p.provolatile = 'v')
  ) THEN
    RAISE EXCEPTION 'a traversal function is SECURITY DEFINER or VOLATILE; it must be neither';
  END IF;

  -- Who may reject a suggestion, and an edge carries its own classification
  -- (0037). Three triggers and one policy; the helper's own refusal is not
  -- the rule, so the triggers are what is checked here.
  IF to_regprocedure('rye.assertion_authorship_stamp()') IS NULL
     OR to_regprocedure('rye.assertion_rejection_authority_guard()') IS NULL
     OR to_regprocedure('rye.enforce_edge_classification_with_teams()') IS NULL
  THEN
    RAISE EXCEPTION
      'one or more of the 0037 trigger functions is missing (assertion_authorship_stamp, assertion_rejection_authority_guard, enforce_edge_classification_with_teams)';
  END IF;

  IF EXISTS (
      SELECT required.tgname
      FROM (VALUES
          ('assertions', 'trg_assertion_authorship_stamp', 4),   -- BEFORE INSERT
          ('assertions', 'trg_assertions_reject_authority', 16), -- BEFORE UPDATE
          ('edges',      'trg_edges_classification_check', 20)   -- BEFORE INSERT OR UPDATE
      ) required(relname, tgname, events)
      WHERE NOT EXISTS (
          SELECT 1
          FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
          JOIN pg_namespace ns ON ns.oid = c.relnamespace
          WHERE ns.nspname = v_schema
            AND c.relname = required.relname
            AND t.tgname = required.tgname
            AND NOT t.tgisinternal
            AND t.tgenabled <> 'D'
            AND t.tgtype & 1 = 1 -- FOR EACH ROW
            AND t.tgtype & 2 = 2 -- BEFORE
            AND t.tgtype & required.events = required.events
      )
  ) THEN
    RAISE EXCEPTION
      'one or more of the 0037 triggers is missing, disabled, or has the wrong timing';
  END IF;

  -- Order, in its own check so that the four-name check above stays where it
  -- is: the stamp never raises and may sort first; the authority guard must
  -- fall after the settle gate, the may-write gate and the immutability guard,
  -- so no existing refusal message moves.
  IF NOT (
      (SELECT array_position(names, 'trg_assertion_settle_gate')
              < array_position(names, 'trg_assertions_reject_authority')
          AND array_position(names, 'trg_assertions_gate_may_write')
              < array_position(names, 'trg_assertions_reject_authority')
          AND array_position(names, 'trg_assertions_immutable')
              < array_position(names, 'trg_assertions_reject_authority')
       FROM (
          SELECT array_agg(t.tgname ORDER BY t.tgname) AS names
          FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
          JOIN pg_namespace ns ON ns.oid = c.relnamespace
          WHERE ns.nspname = v_schema
            AND c.relname = 'assertions'
            AND NOT t.tgisinternal
       ) ordered)
  ) THEN
    RAISE EXCEPTION
      'trg_assertions_reject_authority does not sort after the settle gate, the may-write gate and the immutability guard';
  END IF;

  -- The edge read rule reads the edge's own attrs. CREATE POLICY stores the
  -- expression unfolded, so a pg_policies grep is sound.
  IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = v_schema
        AND tablename = 'edges'
        AND policyname = 'edge_read_policy'
        AND qual LIKE '%classification%'
        AND qual LIKE '%access_grants%'
  ) THEN
    RAISE EXCEPTION
      'edge_read_policy does not read the edge''s own classification, teams and grants';
  END IF;

  -- reject_candidate() keeps its SECURITY DEFINER setting and refuses before
  -- it writes. The trigger is the rule; this is the sentence a caller gets.
  IF NOT EXISTS (
      SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = v_schema
        AND p.proname = 'reject_candidate'
        AND p.prosecdef
        AND p.prosrc LIKE '%may close only its own%'
        AND p.prosrc LIKE '%is Rye configuration%'
  ) THEN
    RAISE EXCEPTION
      'reject_candidate is not SECURITY DEFINER or does not gate the caller before it writes';
  END IF;
END
$$;
SQL

echo "Verification passed"
