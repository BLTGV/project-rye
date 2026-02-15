# Cookbook: Product Development

## Issues, Incidents, Releases, and Architectural Decisions

---

## The Problem

An engineering team tracks bugs in Linear, incidents in PagerDuty, architectural decisions in Notion docs, and release notes in GitHub. When a customer reports a regression, nobody can quickly trace: which deploy introduced it, which PR changed the behavior, what the original design decision was, and which other customers are affected.

Rye connects the engineering knowledge graph so an agent (or a human) can follow the chain.

---

## 1. Entity Mapping

| Real-world thing | `node_type` | Key properties |
|---|---|---|
| Bug / Issue | `task` | `title`, `task_type: "bug"`, `severity`, `component` |
| Feature | `task` | `title`, `task_type: "feature"`, `priority` |
| Incident | `incident` | `title`, `severity`, `started_at`, `resolved_at` |
| Release | `release` | `version`, `tag`, `released_at` |
| Architectural Decision Record | `document` | `title`, `status`, `decision_date` |
| Service / Component | `component` | `name`, `repo`, `team` |
| Customer | `org` | `name`, `plan`, `mrr` |

| Relationship | `edge_type` | Direction |
|---|---|---|
| Issue affects component | `affects` | task -> component |
| Incident triggered by release | `triggered_by` | incident -> release |
| Release contains issue | `contains` | release -> task |
| Issue reported by customer | `reported_by` | task -> org |
| ADR applies to component | `applies_to` | document -> component |
| Incident impacted customer | `impacted` | incident -> org |
| Issue blocks issue | `blocks` | task -> task |
| Issue depends on issue | `depends_on` | task -> task |

---

## 2. Modeling Issues and Features

Issues and features use the PM `task` node type with `task_type` to differentiate:

```sql
-- Report a bug
SELECT create_task(
    p_title := 'CSV export fails for reports over 10k rows',
    p_project_id := (SELECT id FROM nodes WHERE properties->>'code' = 'PRJ-2501-0003'),
    p_assigned_to_id := (SELECT id FROM nodes WHERE label = 'Bob Chen'),
    p_properties := '{
        "task_type": "bug",
        "severity": "high",
        "component": "reporting-service",
        "reproduction_steps": "1. Create report with 15k rows\n2. Click Export CSV\n3. Spinner hangs, 504 after 30s"
    }',
    p_teams := ARRAY['engineering'],
    p_regarding_ids := ARRAY[
        (SELECT id FROM nodes WHERE label = 'reporting-service' AND node_type = 'component')
    ],
    p_regarding_roles := ARRAY['affects']
);

-- Track a feature
SELECT create_task(
    p_title := 'Add webhook support for real-time event delivery',
    p_project_id := (SELECT id FROM nodes WHERE properties->>'code' = 'PRJ-2501-0003'),
    p_properties := '{"task_type": "feature", "priority": "high", "estimated_hours": 40}',
    p_teams := ARRAY['engineering']
);
```

---

## 3. Incidents

Incidents are their own node type, linked to the release that triggered them and the customers impacted:

```sql
-- Create an incident
INSERT INTO nodes (node_type, label, properties, attrs) VALUES (
    'incident', 'CSV export timeout in production',
    '{
        "title": "CSV export timeout in production",
        "severity": "sev2",
        "started_at": "2024-03-20T14:30:00Z",
        "detection": "customer_report",
        "status_page_posted": true
    }',
    '{"teams": ["engineering", "support"]}'
);

-- Link incident to the release that caused it
INSERT INTO edges (edge_type, source_id, target_id, properties)
SELECT 'triggered_by', incident.id, release.id, '{"confidence": "confirmed"}'
FROM nodes incident, nodes release
WHERE incident.label = 'CSV export timeout in production'
  AND release.properties->>'version' = '2.4.1';

-- Link incident to impacted customers
INSERT INTO edges (edge_type, source_id, target_id, properties)
SELECT 'impacted', incident.id, customer.id, '{"impact": "degraded_service", "notified": true}'
FROM nodes incident, nodes customer
WHERE incident.label = 'CSV export timeout in production'
  AND customer.label IN ('Acme Corp', 'Globex Inc');

-- Incident timeline events
INSERT INTO events (event_type, occurred_at, summary, properties, actor_system)
VALUES
    ('incident_update', '2024-03-20T14:35:00Z', 'Incident acknowledged, investigating',
     '{"action": "acknowledged"}', 'user:bob'),
    ('incident_update', '2024-03-20T15:10:00Z', 'Root cause identified: unbounded query in export path',
     '{"action": "root_cause_found", "root_cause": "Missing LIMIT on export query for large datasets"}', 'user:bob'),
    ('incident_update', '2024-03-20T16:00:00Z', 'Hotfix deployed (v2.4.2), monitoring',
     '{"action": "fix_deployed", "fix_version": "2.4.2"}', 'user:bob'),
    ('incident_update', '2024-03-20T17:00:00Z', 'Incident resolved, no recurrence',
     '{"action": "resolved"}', 'user:bob');
```

---

## 4. Releases

```sql
INSERT INTO nodes (node_type, label, properties, attrs) VALUES (
    'release', 'v2.4.1',
    '{"version": "2.4.1", "tag": "v2.4.1", "released_at": "2024-03-19T10:00:00Z", "changelog_ref": "https://github.com/..."}',
    '{"teams": ["engineering"]}'
);

-- Link issues resolved in this release
INSERT INTO edges (edge_type, source_id, target_id)
SELECT 'contains', release.id, task.id
FROM nodes release, nodes task
WHERE release.properties->>'version' = '2.4.1'
  AND task.properties->>'code' IN ('TSK-2403-0150', 'TSK-2403-0155', 'TSK-2403-0160');
```

---

## 5. Architectural Decision Records (ADRs)

ADRs are document nodes with assertions that can be superseded when decisions are revisited:

```sql
-- Create an ADR
INSERT INTO nodes (node_type, label, properties, attrs) VALUES (
    'document', 'ADR-007: Use streaming for large exports',
    '{
        "title": "ADR-007: Use streaming for large exports",
        "adr_number": 7,
        "status": "accepted",
        "decision_date": "2024-03-21",
        "context": "Export timeouts on large datasets",
        "decision": "Stream CSV rows instead of buffering entire result set",
        "consequences": "Requires chunked transfer encoding, client must handle streaming response"
    }',
    '{"teams": ["engineering"]}'
);

-- Link ADR to the component it applies to
INSERT INTO edges (edge_type, source_id, target_id)
SELECT 'applies_to', adr.id, component.id
FROM nodes adr, nodes component
WHERE adr.label LIKE 'ADR-007%' AND component.label = 'reporting-service';

-- Link ADR to the incident that prompted it
INSERT INTO edges (edge_type, source_id, target_id, properties)
SELECT 'originated_from', adr.id, incident.id, '{"context": "post-incident review"}'
FROM nodes adr, nodes incident
WHERE adr.label LIKE 'ADR-007%' AND incident.label = 'CSV export timeout in production';
```

When a decision is revisited, supersede the status assertion:

```sql
-- Decision superseded by new approach
INSERT INTO assertions (assertion_type, subject_node_id, claim, confidence)
VALUES ('decision_status',
    (SELECT id FROM nodes WHERE label LIKE 'ADR-007%'),
    '{"status": "superseded", "superseded_by": "ADR-012", "reason": "Switched to async job queue approach"}',
    1.0);
```

---

## 6. Key Queries

### Incident blast radius: which customers were affected?

```sql
SELECT
    incident.label AS incident,
    incident.properties->>'severity' AS severity,
    customer.label AS customer,
    customer.properties->>'plan' AS plan,
    (customer.properties->>'mrr')::numeric AS mrr,
    e.properties->>'impact' AS impact
FROM nodes incident
JOIN edges e ON e.source_id = incident.id AND e.edge_type = 'impacted' AND e.archived_at IS NULL
JOIN nodes customer ON customer.id = e.target_id
WHERE incident.node_type = 'incident'
ORDER BY incident.properties->>'started_at' DESC, mrr DESC;
```

### What caused the most incidents in the last quarter?

```sql
SELECT
    component.label AS component,
    count(DISTINCT incident.id) AS incident_count,
    array_agg(DISTINCT incident.properties->>'severity') AS severities
FROM nodes incident
JOIN edges triggered ON triggered.source_id = incident.id AND triggered.edge_type = 'triggered_by'
JOIN nodes release ON release.id = triggered.target_id
JOIN edges contains ON contains.source_id = release.id AND contains.edge_type = 'contains'
JOIN nodes task ON task.id = contains.target_id
JOIN edges affects ON affects.source_id = task.id AND affects.edge_type = 'affects'
JOIN nodes component ON component.id = affects.target_id
WHERE incident.node_type = 'incident'
    AND (incident.properties->>'started_at')::timestamptz > now() - interval '90 days'
GROUP BY component.id, component.label
ORDER BY incident_count DESC;
```

### Trace a bug to its root cause and impacted customers

```sql
-- Start from a customer report, follow the chain
SELECT
    bug.properties->>'code' AS bug_code,
    bug.label AS bug_title,
    release.properties->>'version' AS introduced_in,
    incident.label AS caused_incident,
    customer.label AS impacted_customer
FROM nodes bug
JOIN edges contains ON contains.target_id = bug.id AND contains.edge_type = 'contains'
JOIN nodes release ON release.id = contains.source_id AND release.node_type = 'release'
JOIN edges triggered ON triggered.target_id = release.id AND triggered.edge_type = 'triggered_by'
JOIN nodes incident ON incident.id = triggered.source_id
JOIN edges impacted ON impacted.source_id = incident.id AND impacted.edge_type = 'impacted'
JOIN nodes customer ON customer.id = impacted.target_id
WHERE bug.properties->>'code' = 'TSK-2403-0160';
```

---

## 7. Agent Interaction Examples

**Agent:** "What's the status of the CSV export bug?"

Retrieves the task, its current `task_status` assertion, linked incident, linked release, related ADR, and impacted customers. Returns a concise summary.

**Agent:** "Which customers should we proactively notify about the v2.4.1 issues?"

Queries customers linked to incidents triggered by the v2.4.1 release, cross-references with `churn_risk` assertions from the SaaS operations domain, prioritizes by MRR.

**Agent:** "Create a post-mortem task for the CSV export incident."

Creates a task linked to the incident via `originated_from`, assigns to the on-call engineer, adds `regarding` edges to the component and release, sets due date.

**Agent:** "What architectural decisions affect the reporting service?"

Traverses `applies_to` edges from document nodes to the reporting-service component, returns ADRs with their current status assertions.
