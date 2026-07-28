# PM Conventions

## Task, Project, and Sprint Management on the Knowledge Graph

---

## 1. Relationship to the Core Schema

Like the CRM conventions, PM is implemented on the existing core tables. Tasks are nodes, not a separate system. A task linked to a CRM opportunity, a support ticket, and a customer account participates in the same graph traversals, access control, and event log.

---

## 2. Entity Conventions

### 2.1 Node Types

| `node_type` | Purpose | Required Properties | Optional Properties |
|---|---|---|---|
| `task` | A unit of work | `code`, `title` | `description`, `task_type`, `due_date`, `priority`, `estimated_hours`, `tags` |
| `project` | A collection of related work | `code`, `name` | `description`, `start_date`, `target_date`, `budget_hours` |
| `milestone` | A target deliverable or date | `code`, `name`, `target_date` | `description`, `criteria` |
| `sprint` | A time-boxed iteration | `code`, `name`, `start_date`, `end_date` | `goal`, `capacity_hours` |
| `workflow_template` | A reusable process definition | `name`, `steps` | `description`, `trigger_conditions` |

### 2.2 Edge Types

| `edge_type` | Source -> Target | Properties |
|---|---|---|
| `contains` | project -> task | `added_at` |
| `subtask_of` | task -> task | `order` |
| `blocks` | task -> task | `reason` |
| `depends_on` | task -> task | `dependency_type` |
| `assigned_to` | task -> person | `role` (`'owner'`, `'reviewer'`, `'collaborator'`, `'watcher'`) |
| `milestone_target` | task -> milestone | -- |
| `sprint_member` | task -> sprint | `added_at`, `committed` |
| `project_member` | person -> project | `role` (`'lead'`, `'member'`, `'stakeholder'`) |
| `regarding` | task -> (any node) | `context` |
| `originated_from` | task -> event | -- |

**`blocks` vs `depends_on`:** Use `blocks` for ad-hoc impediments discovered during work. Use `depends_on` for planned structural dependencies.

### 2.3 Assertion Types

| `assertion_type` | Subject | Claim Shape |
|---|---|---|
| `task_status` | task | `{status, moved_from, reason}` |
| `task_priority` | task | `{level, reason, set_by}` |
| `estimate` | task | `{hours, points, basis}` |
| `progress` | task | `{percent, notes}` |
| `project_status` | project | `{status, health, notes}` |
| `sprint_goal_status` | sprint | `{status, notes}` |
| `milestone_status` | milestone | `{status, projected_date, confidence}` |

### 2.4 Event Types

| `event_type` | Purpose | Key Properties |
|---|---|---|
| `status_change` | Task/project status transition | `entity_code`, `from_status`, `to_status` |
| `comment` | Discussion on a task | `body`, `mentions`, `reply_to` |
| `time_log` | Time tracked against a task | `hours`, `description`, `date` |
| `assignment_change` | Task reassigned | `from_user`, `to_user`, `reason` |
| `blocker_added` | New blocking relationship | `blocker_code`, `blocked_code`, `reason` |
| `blocker_resolved` | Blocking resolved | `blocker_code`, `blocked_code`, `resolution` |
| `review_requested` | Task ready for review | `reviewer_id`, `notes` |
| `task_created` | New task logged | `created_by`, `source` |

---

## 3. Codes

Same format as CRM codes (see [CRM Conventions](/docs/layers/crm/)):

| Entity | Prefix | Example |
|---|---|---|
| Task | `TSK` | `TSK-2403-0187` |
| Project | `PRJ` | `PRJ-2401-0005` |
| Milestone | `MIL` | `MIL-2403-0012` |
| Sprint | `SPR` | `SPR-2403-0008` |

**Cross-domain references:** Codes are designed to appear in text. When a comment says "Blocked on TSK-2403-0187" or a task description says "Follow up from OPP-2403-0042", these are parseable references. The code reference pattern for extraction:

```
(?:OPP|TSK|PRJ|CON|MIL|SPR)-\d{4}-\d{4}
```

---

## 4. Task Lifecycle

### 4.1 Status Model

```
backlog -> todo -> in_progress -> in_review -> done
                       |                        |
                    blocked                  cancelled
                       |
                  in_progress (unblocked)
```

Statuses are conventions, not constraints. Projects can define custom statuses.

### 4.2 Status Transitions

```sql
SELECT advance_task_status('<task_uuid>', 'in_progress', 'Starting work', 'user:jane');
```

---

## 5. Cross-Domain Tasks

Tasks are not siloed. A single task can connect to multiple domains:

```
[Task: TSK-2403-0187 "Investigate churn spike for Acme Corp"]
    |-- regarding --> [Customer: Acme Corp]                (CRM)
    |-- regarding --> [Ticket: Support escalation #1234]   (Support)
    |-- assigned_to --> [Person: Jane]                     (PM)
    |-- contains <-- [Project: Q1 Retention Initiative]    (PM)
    |-- sprint_member --> [Sprint: SPR-2403-0008]          (PM)
```

This task appears in: Jane's workload, the Q1 Retention project board, the Acme Corp customer context, and the sprint board. No duplication, no sync.

---

## 6. Convenience Functions

### 6.1 Create Task

Uses an advisory lock on the project to prevent race conditions in project-local sequence numbering.

```sql
CREATE FUNCTION create_task(
    p_title text,
    p_description text DEFAULT NULL,
    p_project_id uuid DEFAULT NULL,
    p_assigned_to_id uuid DEFAULT NULL,
    p_properties jsonb DEFAULT '{}',
    p_teams text[] DEFAULT '{}',
    p_regarding_ids uuid[] DEFAULT '{}',
    p_regarding_roles text[] DEFAULT '{}'
) RETURNS uuid AS $$
DECLARE
    v_task_id uuid;
    v_code text;
    v_project_seq int;
    i int;
BEGIN
    v_code := generate_crm_code('TSK');

    -- Calculate project-local sequence with advisory lock to prevent races
    IF p_project_id IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtext(p_project_id::text));
        SELECT coalesce(max((t.properties->>'project_seq')::int), 0) + 1
        INTO v_project_seq
        FROM edges c
        JOIN nodes t ON t.id = c.target_id AND t.node_type = 'task'
        WHERE c.source_id = p_project_id AND c.edge_type = 'contains' AND c.archived_at IS NULL;
    END IF;

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES (
        'task', p_title,
        p_properties || jsonb_build_object(
            'code', v_code, 'title', p_title, 'description', p_description
        ) || CASE WHEN v_project_seq IS NOT NULL
            THEN jsonb_build_object('project_seq', v_project_seq)
            ELSE '{}'::jsonb END,
        jsonb_build_object('teams', to_jsonb(p_teams)),
        v_code, 'internal'
    )
    RETURNING id INTO v_task_id;

    INSERT INTO assertions (assertion_type, subject_node_id, claim, confidence)
    VALUES ('task_status', v_task_id, '{"status": "backlog"}', 1.0);

    IF p_project_id IS NOT NULL THEN
        INSERT INTO edges (edge_type, source_id, target_id, properties)
        VALUES ('contains', p_project_id, v_task_id, jsonb_build_object('added_at', now()));
    END IF;

    IF p_assigned_to_id IS NOT NULL THEN
        INSERT INTO edges (edge_type, source_id, target_id, properties, effective_from)
        VALUES ('assigned_to', v_task_id, p_assigned_to_id, '{"role": "owner"}', now());
    END IF;

    FOR i IN 1..coalesce(array_length(p_regarding_ids, 1), 0) LOOP
        INSERT INTO edges (edge_type, source_id, target_id, properties)
        VALUES ('regarding', v_task_id, p_regarding_ids[i],
            jsonb_build_object('context', coalesce(p_regarding_roles[i], 'subject')));
    END LOOP;

    INSERT INTO events (event_type, occurred_at, summary, properties, actor_system)
    VALUES ('task_created', now(),
        format('Created %s: %s', v_code, p_title),
        jsonb_build_object('task_code', v_code, 'project_id', p_project_id),
        current_setting('app.current_user_id', true));

    RETURN v_task_id;
END;
$$ LANGUAGE plpgsql;
```

### 6.2 Advance Task Status

```sql
CREATE FUNCTION advance_task_status(
    p_task_id uuid,
    p_new_status text,
    p_reason text DEFAULT NULL,
    p_actor text DEFAULT NULL
) RETURNS uuid AS $$
DECLARE
    v_old_assertion_id uuid;
    v_old_status text;
    v_new_assertion_id uuid;
    v_event_id uuid;
    v_task_code text;
BEGIN
    SELECT a.id, a.claim->>'status'
    INTO v_old_assertion_id, v_old_status
    FROM current_assertions a
    WHERE a.subject_node_id = p_task_id AND a.assertion_type = 'task_status';

    SELECT properties->>'code' INTO v_task_code FROM nodes WHERE id = p_task_id;

    INSERT INTO events (event_type, occurred_at, summary, properties, actor_system)
    VALUES (
        'status_change', now(),
        format('%s: %s -> %s', v_task_code, coalesce(v_old_status, 'none'), p_new_status),
        jsonb_build_object(
            'entity_code', v_task_code,
            'from_status', v_old_status,
            'to_status', p_new_status,
            'reason', p_reason),
        coalesce(p_actor, current_setting('app.current_user_id', true))
    )
    RETURNING id INTO v_event_id;

    INSERT INTO event_participants (event_id, node_id, role)
    VALUES (v_event_id, p_task_id, 'subject');

    IF v_old_assertion_id IS NOT NULL THEN
        v_new_assertion_id := supersede_assertion(
            p_old_assertion_id := v_old_assertion_id,
            p_new_assertion_type := 'task_status',
            p_new_subject_node_id := p_task_id,
            p_new_subject_edge_id := NULL,
            p_new_claim := jsonb_build_object(
                'status', p_new_status, 'moved_from', v_old_status, 'reason', p_reason),
            p_new_confidence := 1.0,
            p_new_basis := 'reported',
            p_new_evidence := ARRAY[
              jsonb_build_object('kind', 'source', 'event_id', v_event_id)
            ]
        );
    ELSE
        v_new_assertion_id := record_assertion(
            p_assertion_type := 'task_status',
            p_subject_node_id := p_task_id,
            p_claim := jsonb_build_object('status', p_new_status, 'reason', p_reason),
            p_confidence := 1.0,
            p_basis := 'reported',
            p_evidence := ARRAY[
              jsonb_build_object('kind', 'source', 'event_id', v_event_id)
            ]
        );
    END IF;

    RETURN v_new_assertion_id;
END;
$$ LANGUAGE plpgsql;
```

### 6.3 Add Comment

Uses a non-capturing group in the regex so the full code is matched, not just the prefix.

```sql
CREATE FUNCTION add_comment(
    p_task_id uuid,
    p_body text,
    p_actor text DEFAULT NULL,
    p_reply_to_event_id uuid DEFAULT NULL
) RETURNS uuid AS $$
DECLARE
    v_event_id uuid;
    v_task_code text;
    v_code_pattern text := '(?:OPP|TSK|PRJ|CON|MIL|SPR)-\d{4}-\d{4}';
    v_match text;
    v_mentioned_id uuid;
BEGIN
    SELECT properties->>'code' INTO v_task_code FROM nodes WHERE id = p_task_id;

    INSERT INTO events (event_type, occurred_at, summary, properties, actor_system)
    VALUES (
        'comment', now(),
        format('Comment on %s', v_task_code),
        jsonb_build_object('body', p_body, 'reply_to', p_reply_to_event_id),
        coalesce(p_actor, current_setting('app.current_user_id', true))
    )
    RETURNING id INTO v_event_id;

    INSERT INTO event_participants (event_id, node_id, role)
    VALUES (v_event_id, p_task_id, 'subject');

    FOR v_match IN
        SELECT (regexp_matches(p_body, v_code_pattern, 'g'))[1]
    LOOP
        SELECT id INTO v_mentioned_id
        FROM nodes WHERE properties->>'code' = v_match AND archived_at IS NULL;
        IF v_mentioned_id IS NOT NULL AND v_mentioned_id != p_task_id THEN
            INSERT INTO event_participants (event_id, node_id, role)
            VALUES (v_event_id, v_mentioned_id, 'mentioned')
            ON CONFLICT (event_id, node_id, role) DO NOTHING;
        END IF;
    END LOOP;

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;
```

### 6.4 Log Time

```sql
CREATE FUNCTION log_time(
    p_task_id uuid,
    p_hours numeric,
    p_description text DEFAULT NULL,
    p_date date DEFAULT current_date,
    p_actor text DEFAULT NULL
) RETURNS uuid AS $$
DECLARE
    v_event_id uuid;
    v_task_code text;
BEGIN
    SELECT properties->>'code' INTO v_task_code FROM nodes WHERE id = p_task_id;

    INSERT INTO events (event_type, occurred_at, summary, properties, actor_system)
    VALUES (
        'time_log', p_date::timestamptz,
        format('%s: %s hours', v_task_code, p_hours),
        jsonb_build_object('hours', p_hours, 'description', p_description, 'date', p_date),
        coalesce(p_actor, current_setting('app.current_user_id', true))
    )
    RETURNING id INTO v_event_id;

    INSERT INTO event_participants (event_id, node_id, role)
    VALUES (v_event_id, p_task_id, 'subject');

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;
```

### 6.5 Instantiate Workflow

Handles empty `p_regarding_ids` safely.

```sql
CREATE FUNCTION instantiate_workflow(
    p_template_id uuid,
    p_project_id uuid,
    p_context jsonb,
    p_regarding_ids uuid[] DEFAULT '{}',
    p_teams text[] DEFAULT '{}'
) RETURNS uuid[] AS $$
DECLARE
    v_steps jsonb;
    v_step jsonb;
    v_task_ids uuid[] := '{}';
    v_task_id uuid;
    v_title text;
    v_key text;
    v_value text;
    v_regarding_roles text[];
BEGIN
    SELECT properties->'steps' INTO v_steps FROM nodes WHERE id = p_template_id;

    -- Build regarding roles array safely
    IF p_regarding_ids IS NOT NULL AND array_length(p_regarding_ids, 1) > 0 THEN
        v_regarding_roles := array_fill('subject'::text, ARRAY[array_length(p_regarding_ids, 1)]);
    ELSE
        v_regarding_roles := '{}'::text[];
    END IF;

    FOR v_step IN SELECT * FROM jsonb_array_elements(v_steps) ORDER BY (value->>'order')::int
    LOOP
        v_title := v_step->>'title_template';
        FOR v_key, v_value IN SELECT * FROM jsonb_each_text(p_context)
        LOOP
            v_title := replace(v_title, '{' || v_key || '}', v_value);
        END LOOP;

        v_task_id := create_task(
            p_title := v_title,
            p_project_id := p_project_id,
            p_properties := jsonb_build_object(
                'task_type', v_step->>'task_type',
                'estimated_hours', (v_step->>'estimated_hours')::numeric,
                'workflow_step', (v_step->>'order')::int),
            p_teams := p_teams,
            p_regarding_ids := p_regarding_ids,
            p_regarding_roles := v_regarding_roles
        );

        v_task_ids := v_task_ids || v_task_id;

        IF v_step->'depends_on' IS NOT NULL THEN
            INSERT INTO edges (edge_type, source_id, target_id, properties)
            SELECT 'depends_on', v_task_id, v_task_ids[(dep_idx)::int],
                   '{"dependency_type": "finish_to_start"}'
            FROM jsonb_array_elements_text(v_step->'depends_on') AS dep_idx;
        END IF;
    END LOOP;

    RETURN v_task_ids;
END;
$$ LANGUAGE plpgsql;
```

---

## 7. Materialized Views

### 7.1 Task Board

Uses `LATERAL` joins to pick one owner/reviewer per task, preventing fan-out.

```sql
CREATE MATERIALIZED VIEW task_board AS
SELECT
    t.id AS node_id,
    t.label AS title,
    t.properties->>'code' AS code,
    t.properties->>'task_type' AS task_type,
    t.properties->>'due_date' AS due_date,
    t.properties->>'priority' AS priority,
    t.attrs->'teams' AS teams,
    stg.claim->>'status' AS status,
    stg.asserted_at AS status_since,
    est.claim->>'hours' AS estimated_hours,
    est.claim->>'points' AS story_points,
    prg.claim->>'percent' AS progress_percent,
    owner.label AS owner_name,
    owner.id AS owner_id,
    reviewer.label AS reviewer_name,
    reviewer.id AS reviewer_id,
    proj.label AS project_name,
    proj.properties->>'code' AS project_code,
    sprint.label AS sprint_name,
    sprint.properties->>'code' AS sprint_code,
    parent.label AS parent_task,
    parent.properties->>'code' AS parent_code,
    (SELECT count(*) FROM edges sub
        WHERE sub.edge_type = 'subtask_of' AND sub.target_id = t.id
        AND sub.archived_at IS NULL) AS subtask_count,
    (SELECT count(*) FROM edges blk
        WHERE blk.edge_type = 'blocks' AND blk.target_id = t.id
        AND blk.archived_at IS NULL) AS blocker_count,
    t.created_at
FROM nodes t
LEFT JOIN current_assertions stg ON stg.subject_node_id = t.id AND stg.assertion_type = 'task_status'
LEFT JOIN current_assertions est ON est.subject_node_id = t.id AND est.assertion_type = 'estimate'
LEFT JOIN current_assertions prg ON prg.subject_node_id = t.id AND prg.assertion_type = 'progress'
LEFT JOIN LATERAL (
    SELECT n.id, n.label FROM edges e
    JOIN nodes n ON n.id = e.target_id
    WHERE e.source_id = t.id AND e.edge_type = 'assigned_to'
      AND e.properties->>'role' = 'owner'
      AND e.effective_to IS NULL AND e.archived_at IS NULL
    LIMIT 1
) owner ON true
LEFT JOIN LATERAL (
    SELECT n.id, n.label FROM edges e
    JOIN nodes n ON n.id = e.target_id
    WHERE e.source_id = t.id AND e.edge_type = 'assigned_to'
      AND e.properties->>'role' = 'reviewer'
      AND e.effective_to IS NULL AND e.archived_at IS NULL
    LIMIT 1
) reviewer ON true
LEFT JOIN LATERAL (
    SELECT n.id, n.label, n.properties FROM edges e
    JOIN nodes n ON n.id = e.source_id AND n.node_type = 'project'
    WHERE e.target_id = t.id AND e.edge_type = 'contains' AND e.archived_at IS NULL
    LIMIT 1
) proj ON true
LEFT JOIN LATERAL (
    SELECT n.id, n.label, n.properties FROM edges e
    JOIN nodes n ON n.id = e.target_id
    WHERE e.source_id = t.id AND e.edge_type = 'sprint_member' AND e.archived_at IS NULL
    LIMIT 1
) sprint ON true
LEFT JOIN LATERAL (
    SELECT n.id, n.label, n.properties FROM edges e
    JOIN nodes n ON n.id = e.target_id
    WHERE e.source_id = t.id AND e.edge_type = 'subtask_of' AND e.archived_at IS NULL
    LIMIT 1
) parent ON true
WHERE t.node_type = 'task' AND t.archived_at IS NULL;

CREATE UNIQUE INDEX idx_tb_node ON task_board (node_id);
CREATE INDEX idx_tb_code ON task_board (code);
CREATE INDEX idx_tb_status ON task_board (status);
CREATE INDEX idx_tb_owner ON task_board (owner_id);
CREATE INDEX idx_tb_project ON task_board (project_code);
CREATE INDEX idx_tb_sprint ON task_board (sprint_code);
CREATE INDEX idx_tb_due ON task_board (due_date);
```

### 7.2 Common Queries

```sql
-- My open tasks, prioritized
SELECT * FROM task_board
WHERE owner_id = '<my_uuid>' AND status NOT IN ('done', 'cancelled')
ORDER BY
    CASE priority WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 ELSE 4 END,
    due_date NULLS LAST;

-- Sprint board
SELECT * FROM task_board
WHERE sprint_code = 'SPR-2403-0008'
ORDER BY
    CASE status WHEN 'in_progress' THEN 1 WHEN 'in_review' THEN 2 WHEN 'todo' THEN 3 ELSE 4 END;

-- Overdue tasks
SELECT * FROM task_board
WHERE due_date::date < current_date AND status NOT IN ('done', 'cancelled')
ORDER BY due_date;
```

---

## 8. Access Control

Task access builds on the core RLS infrastructure. See [Security](/docs/model/security/).

1. **Task visibility follows team membership.** A task tagged with `{"teams": ["engineering"]}` is visible to engineering team members.
2. **Project membership grants task visibility.** If you're a `project_member`, you see all tasks in that project.
3. **Cross-team tasks are visible to all tagged teams.**
