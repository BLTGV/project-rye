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

psql "$DB_URL" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path = rye, public, pg_catalog;

-- Nodes
INSERT INTO nodes (node_type, label, properties)
VALUES
  ('person', 'Alice Chen', '{"first_name": "Alice", "last_name": "Chen", "email": "alice@example.com"}'),
  ('org', 'Acme Corp', '{"name": "Acme Corp", "industry": "SaaS"}'),
  ('project', 'Q1 Launch', '{"name": "Q1 Launch", "code": "PRJ-2501-0001"}')
ON CONFLICT DO NOTHING;

-- Edges
INSERT INTO edges (edge_type, source_id, target_id, properties, effective_from)
SELECT 'employs', org.id, person.id, '{"title": "Engineering Lead"}', now()
FROM nodes org
JOIN nodes person ON true
WHERE org.label = 'Acme Corp'
  AND person.label = 'Alice Chen'
  AND NOT EXISTS (
      SELECT 1
      FROM edges e
      WHERE e.edge_type = 'employs'
        AND e.source_id = org.id
        AND e.target_id = person.id
        AND e.archived_at IS NULL
  );

INSERT INTO edges (edge_type, source_id, target_id, properties, effective_from)
SELECT 'project_member', person.id, project.id, '{"role": "lead"}', now()
FROM nodes person
JOIN nodes project ON true
WHERE person.label = 'Alice Chen'
  AND project.label = 'Q1 Launch'
  AND NOT EXISTS (
      SELECT 1
      FROM edges e
      WHERE e.edge_type = 'project_member'
        AND e.source_id = person.id
        AND e.target_id = project.id
        AND e.archived_at IS NULL
  );

-- Event using record_event()
SELECT record_event(
    p_event_type     := 'meeting',
    p_summary        := 'Kickoff meeting for Q1 Launch',
    p_properties     := '{"duration_minutes": 60, "location": "Zoom", "outcome": "Scope agreed"}',
    p_participant_ids := ARRAY[
        (SELECT id FROM nodes WHERE label = 'Alice Chen' LIMIT 1),
        (SELECT id FROM nodes WHERE label = 'Q1 Launch' LIMIT 1)
    ]::uuid[],
    p_participant_roles := ARRAY['organizer', 'regarding'],
    p_actor          := 'user:alice'
);

-- Initial assertion
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
SELECT
  'project_status',
  'default',
  n.id,
  '{"status": "active", "health": "on_track"}',
  1.0
FROM nodes n
WHERE n.label = 'Q1 Launch'
  AND NOT EXISTS (
      SELECT 1
      FROM current_assertions a
      WHERE a.subject_node_id = n.id
        AND a.assertion_type = 'project_status'
        AND a.assertion_key = 'default'
  );
SQL

echo "Quickstart seed complete"
