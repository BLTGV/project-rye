#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_URL="${DATABASE_URL:-}"
SCHEMA="${RYE_SCHEMA:-rye}"
PLUGINS_DIR="${RYE_PLUGINS_DIR:-${ROOT_DIR}/plugins}"
SKILLS_DIR="${RYE_SKILLS_DIR:-${ROOT_DIR}/skills}"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/sync_plugin_metadata.sh --db-url <postgresql://...> [--schema rye] [--plugins-dir plugins] [--skills-dir skills]

Synchronize Rye plugin and skill manifests into the database as portable
metadata nodes and current manifest/capability assertions.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

sql_literal() {
  local value="${1//\'/\'\'}"
  printf "'%s'" "$value"
}

sql_identifier() {
  local value="${1//\"/\"\"}"
  printf '"%s"' "$value"
}

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
    --plugins-dir)
      PLUGINS_DIR="${2:-}"
      shift 2
      ;;
    --skills-dir)
      SKILLS_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$DB_URL" ]] || die "DATABASE_URL or --db-url is required."
[[ -d "$PLUGINS_DIR" ]] || die "Plugins directory not found: $PLUGINS_DIR"
[[ -d "$SKILLS_DIR" ]] || die "Skills directory not found: $SKILLS_DIR"
if [[ ! "$SCHEMA" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  die "Schema must be a valid SQL identifier."
fi

metadata_sync_sql() {
  local schema_ident
  local sql
  local plugins_found=0
  local skills_found=0
  schema_ident="$(sql_identifier "$SCHEMA")"
  sql="SET search_path = ${schema_ident}, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false);
SELECT set_config('app.current_user_id', 'rye:plugin-sync', false);
SELECT set_config('app.current_teams', 'system', false);
"

  local file
  for file in "$PLUGINS_DIR"/*/rye-plugin.json; do
    [[ -f "$file" ]] || continue
    plugins_found=1

    local manifest manifest_sql source_path source_path_sql
    manifest="$(cat "$file")"
    manifest_sql="$(sql_literal "$manifest")"
    source_path="${file#"$ROOT_DIR"/}"
    source_path_sql="$(sql_literal "$source_path")"

    sql+="
WITH manifest AS (
    SELECT ${manifest_sql}::jsonb AS data,
           ${source_path_sql}::text AS source_path
),
upserted AS (
    INSERT INTO nodes (node_type, label, external_source, external_id, properties, attrs)
    SELECT
        'plugin',
        coalesce(nullif(data->>'label', ''), data->>'id'),
        'rye_plugin',
        data->>'id',
        jsonb_build_object(
            'plugin_id', data->>'id',
            'version', data->>'version',
            'description', data->>'description',
            'manifest', data,
            'contributes', coalesce(data->'contributes', '{}'::jsonb),
            'capabilities', coalesce(data->'capabilities', '[]'::jsonb),
            'onboarding', coalesce(data->'onboarding', '{}'::jsonb),
            'validation', coalesce(data->'validation', '{}'::jsonb),
            'admin', coalesce(data->'admin', '{}'::jsonb),
            'metadata_source', source_path
        ),
        jsonb_build_object('created_by', 'rye:plugin-sync', 'metadata_source', source_path)
    FROM manifest
    ON CONFLICT (external_source, external_id)
        WHERE external_id IS NOT NULL AND archived_at IS NULL
    DO UPDATE
        SET label = EXCLUDED.label,
            properties = nodes.properties || EXCLUDED.properties,
            updated_at = now()
    RETURNING id
),
manifest_assertion AS (
    SELECT record_assertion(
        p_assertion_type  := 'plugin_manifest',
        p_claim           := jsonb_build_object(
            'plugin_id', manifest.data->>'id',
            'version', manifest.data->>'version',
            'manifest', manifest.data,
            'metadata_source', manifest.source_path
        ),
        p_subject_node_id := upserted.id,
        p_assertion_key   := 'default',
        p_confidence      := 1.0,
        p_mode            := 'current',
        p_attrs           := jsonb_build_object('metadata_source', manifest.source_path, 'installer', './scripts/sync_plugin_metadata.sh')
    ) AS id
    FROM manifest, upserted
)
SELECT record_assertion(
    p_assertion_type  := 'plugin_contributes',
    p_claim           := coalesce(manifest.data->'contributes', '{}'::jsonb),
    p_subject_node_id := upserted.id,
    p_assertion_key   := 'default',
    p_confidence      := 1.0,
    p_mode            := 'current',
    p_attrs           := jsonb_build_object('metadata_source', manifest.source_path, 'installer', './scripts/sync_plugin_metadata.sh')
)
FROM manifest, upserted, manifest_assertion;
"
  done

  local skill_file
  for skill_file in "$SKILLS_DIR"/*/rye-skill.json; do
    [[ -f "$skill_file" ]] || continue
    skills_found=1

    local skill_manifest skill_manifest_sql skill_source_path skill_source_path_sql
    skill_manifest="$(cat "$skill_file")"
    skill_manifest_sql="$(sql_literal "$skill_manifest")"
    skill_source_path="${skill_file#"$ROOT_DIR"/}"
    skill_source_path_sql="$(sql_literal "$skill_source_path")"

    sql+="
WITH manifest AS (
    SELECT ${skill_manifest_sql}::jsonb AS data,
           ${skill_source_path_sql}::text AS source_path
),
upserted AS (
    INSERT INTO nodes (node_type, label, external_source, external_id, properties, attrs)
    SELECT
        'skill',
        coalesce(nullif(data->>'label', ''), data->>'id'),
        'rye_skill',
        data->>'id',
        jsonb_build_object(
            'skill_id', data->>'id',
            'version', data->>'version',
            'description', data->>'description',
            'manifest', data,
            'source', coalesce(data->'source', '{}'::jsonb),
            'install', coalesce(data->'install', '{}'::jsonb),
            'requires', coalesce(data->'requires', '{}'::jsonb),
            'capabilities', coalesce(data->'capabilities', '[]'::jsonb),
            'metadata_source', source_path
        ),
        jsonb_build_object('created_by', 'rye:plugin-sync', 'metadata_source', source_path)
    FROM manifest
    ON CONFLICT (external_source, external_id)
        WHERE external_id IS NOT NULL AND archived_at IS NULL
    DO UPDATE
        SET label = EXCLUDED.label,
            properties = nodes.properties || EXCLUDED.properties,
            updated_at = now()
    RETURNING id
),
manifest_assertion AS (
    SELECT record_assertion(
        p_assertion_type  := 'skill_manifest',
        p_claim           := jsonb_build_object(
            'skill_id', manifest.data->>'id',
            'version', manifest.data->>'version',
            'manifest', manifest.data,
            'metadata_source', manifest.source_path
        ),
        p_subject_node_id := upserted.id,
        p_assertion_key   := 'default',
        p_confidence      := 1.0,
        p_mode            := 'current',
        p_attrs           := jsonb_build_object('metadata_source', manifest.source_path, 'installer', './scripts/sync_plugin_metadata.sh')
    ) AS id
    FROM manifest, upserted
)
SELECT record_assertion(
    p_assertion_type  := 'skill_capabilities',
    p_claim           := jsonb_build_object(
        'skill_id', manifest.data->>'id',
        'requires', coalesce(manifest.data->'requires', '{}'::jsonb),
        'capabilities', coalesce(manifest.data->'capabilities', '[]'::jsonb)
    ),
    p_subject_node_id := upserted.id,
    p_assertion_key   := 'default',
    p_confidence      := 1.0,
    p_mode            := 'current',
    p_attrs           := jsonb_build_object('metadata_source', manifest.source_path, 'installer', './scripts/sync_plugin_metadata.sh')
)
FROM manifest, upserted, manifest_assertion;
"
  done

  [[ "$plugins_found" -eq 1 ]] || die "No plugin manifests found under $PLUGINS_DIR"
  [[ "$skills_found" -eq 1 ]] || die "No skill manifests found under $SKILLS_DIR"
  printf '%s\n' "$sql"
}

psql "$DB_URL" -v ON_ERROR_STOP=1 <<<"$(metadata_sync_sql)" >/dev/null
echo "Rye metadata synced"
