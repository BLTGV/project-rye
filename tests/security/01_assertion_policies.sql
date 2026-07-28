-- SE-02 / AG-02: direct assertion updates are blocked; supersession must use function path.

SET search_path = rye, public, pg_catalog;

BEGIN;

SET LOCAL "app.current_user_id" = 'user:test';
SET LOCAL "app.current_teams" = 'engineering';
SET LOCAL "app.current_role" = 'team_lead';

WITH seeded_node AS (
  INSERT INTO nodes (node_type, label, properties)
  VALUES ('project', 'Security Test Node', '{"suite": "security"}')
  RETURNING id
)
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence, basis)
SELECT 'project_status', 'default', id, '{"status": "todo"}', 1.0, 'assumed'
FROM seeded_node;

-- Direct update should be blocked even for non-agent roles.
UPDATE assertions
SET superseded_at = now()
WHERE assertion_type = 'project_status'
  AND assertion_key = 'default'
  AND subject_node_id = (
    SELECT id FROM nodes WHERE label = 'Security Test Node' ORDER BY created_at DESC LIMIT 1
  );

DO $$
DECLARE
  v_node uuid;
  v_superseded timestamptz;
BEGIN
  SELECT id INTO v_node
  FROM nodes
  WHERE label = 'Security Test Node'
  ORDER BY created_at DESC
  LIMIT 1;

  SELECT superseded_at INTO v_superseded
  FROM assertions
  WHERE subject_node_id = v_node
    AND assertion_type = 'project_status'
    AND assertion_key = 'default'
  ORDER BY asserted_at DESC
  LIMIT 1;

  IF v_superseded IS NOT NULL THEN
    RAISE EXCEPTION 'Direct update should have been blocked by function-only policy';
  END IF;
END;
$$;

SET LOCAL "app.current_role" = 'agent:triage';

UPDATE assertions
SET superseded_at = now()
WHERE assertion_type = 'project_status'
  AND assertion_key = 'default'
  AND subject_node_id = (
    SELECT id FROM nodes WHERE label = 'Security Test Node' ORDER BY created_at DESC LIMIT 1
  );

DO $$
DECLARE
  v_node uuid;
  v_superseded timestamptz;
BEGIN
  SELECT id INTO v_node
  FROM nodes
  WHERE label = 'Security Test Node'
  ORDER BY created_at DESC
  LIMIT 1;

  SELECT superseded_at INTO v_superseded
  FROM assertions
  WHERE subject_node_id = v_node
    AND assertion_type = 'project_status'
    AND assertion_key = 'default'
  ORDER BY asserted_at DESC
  LIMIT 1;

  IF v_superseded IS NOT NULL THEN
    RAISE EXCEPTION 'Agent direct update should have been blocked';
  END IF;
END;
$$;

INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence, basis)
SELECT
  'project_status_note',
  'agent-note',
  id,
  '{"note": "investigating"}',
  0.6,
  'assumed'
FROM nodes
WHERE label = 'Security Test Node'
ORDER BY created_at DESC
LIMIT 1;

DO $$
DECLARE
  v_count int;
BEGIN
  SELECT count(*) INTO v_count
  FROM assertions
  WHERE assertion_type = 'project_status_note'
    AND assertion_key = 'agent-note'
    AND subject_node_id = (
      SELECT id FROM nodes WHERE label = 'Security Test Node' ORDER BY created_at DESC LIMIT 1
    );

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected agent insert to succeed';
  END IF;
END;
$$;

SELECT supersede_assertion(
  p_old_assertion_id := (
    SELECT id
    FROM current_assertions
    WHERE assertion_type = 'project_status'
      AND assertion_key = 'default'
      AND subject_node_id = (
        SELECT id FROM nodes WHERE label = 'Security Test Node' ORDER BY created_at DESC LIMIT 1
      )
    LIMIT 1
  ),
  p_new_assertion_type := 'project_status',
  p_new_subject_node_id := (
    SELECT id FROM nodes WHERE label = 'Security Test Node' ORDER BY created_at DESC LIMIT 1
  ),
  p_new_subject_edge_id := NULL,
  p_new_claim := '{"status": "in_progress"}',
  p_new_assertion_key := 'default',
  p_new_confidence := 0.95
);

DO $$
DECLARE
  v_node uuid;
  v_active_count int;
  v_latest_status text;
BEGIN
  SELECT id INTO v_node
  FROM nodes
  WHERE label = 'Security Test Node'
  ORDER BY created_at DESC
  LIMIT 1;

  SELECT count(*) INTO v_active_count
  FROM current_assertions
  WHERE subject_node_id = v_node
    AND assertion_type = 'project_status'
    AND assertion_key = 'default';

  IF v_active_count <> 1 THEN
    RAISE EXCEPTION 'Expected one active project_status after supersession, got %', v_active_count;
  END IF;

  SELECT claim->>'status' INTO v_latest_status
  FROM current_assertions
  WHERE subject_node_id = v_node
    AND assertion_type = 'project_status'
    AND assertion_key = 'default'
  LIMIT 1;

  IF v_latest_status <> 'in_progress' THEN
    RAISE EXCEPTION 'Expected supersession to set current status to in_progress, got %', v_latest_status;
  END IF;
END;
$$;

ROLLBACK;
