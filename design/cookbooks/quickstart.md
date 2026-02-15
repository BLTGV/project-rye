# Quickstart

## Model Anything in 5 Minutes

This walkthrough uses generic entities. For domain-specific examples, see the other cookbooks.

---

## 1. Create Nodes

```sql
-- A person
INSERT INTO nodes (node_type, label, properties) VALUES
    ('person', 'Alice Chen', '{"first_name": "Alice", "last_name": "Chen", "email": "alice@example.com"}');

-- A company
INSERT INTO nodes (node_type, label, properties) VALUES
    ('org', 'Acme Corp', '{"name": "Acme Corp", "industry": "SaaS"}');

-- A project
INSERT INTO nodes (node_type, label, properties) VALUES
    ('project', 'Q1 Launch', '{"name": "Q1 Launch", "code": "PRJ-2501-0001"}');
```

## 2. Connect Them with Edges

```sql
-- Alice works at Acme
INSERT INTO edges (edge_type, source_id, target_id, properties, effective_from)
SELECT 'employs', org.id, person.id, '{"title": "Engineering Lead"}', now()
FROM nodes org, nodes person
WHERE org.label = 'Acme Corp' AND person.label = 'Alice Chen';

-- Alice leads the project
INSERT INTO edges (edge_type, source_id, target_id, properties, effective_from)
SELECT 'project_member', person.id, project.id, '{"role": "lead"}', now()
FROM nodes person, nodes project
WHERE person.label = 'Alice Chen' AND project.label = 'Q1 Launch';
```

## 3. Record an Event

```sql
-- Log a meeting
WITH meeting AS (
    INSERT INTO events (event_type, occurred_at, summary, properties, actor_system)
    VALUES (
        'meeting', now(), 'Kickoff meeting for Q1 Launch',
        '{"duration_minutes": 60, "location": "Zoom", "outcome": "Scope agreed"}',
        'user:alice'
    )
    RETURNING id
)
INSERT INTO event_participants (event_id, node_id, role)
SELECT meeting.id, n.id, role
FROM meeting,
(VALUES
    ((SELECT id FROM nodes WHERE label = 'Alice Chen'), 'organizer'),
    ((SELECT id FROM nodes WHERE label = 'Q1 Launch'), 'regarding')
) AS participants(id, role)
CROSS JOIN meeting;
```

## 4. Assert a Fact

```sql
-- Project status assertion
INSERT INTO assertions (assertion_type, subject_node_id, claim, confidence)
SELECT 'project_status', id, '{"status": "active", "health": "on_track"}', 1.0
FROM nodes WHERE label = 'Q1 Launch';
```

## 5. Supersede a Fact

Two weeks later, the project hits a delay:

```sql
SELECT supersede_assertion(
    p_old_assertion_id := (
        SELECT id FROM current_assertions
        WHERE subject_node_id = (SELECT id FROM nodes WHERE label = 'Q1 Launch')
          AND assertion_type = 'project_status'
    ),
    p_new_assertion_type := 'project_status',
    p_new_subject_node_id := (SELECT id FROM nodes WHERE label = 'Q1 Launch'),
    p_new_subject_edge_id := NULL,
    p_new_claim := '{"status": "active", "health": "at_risk", "notes": "Dependency on vendor API delayed"}',
    p_new_confidence := 0.9
);
```

The old assertion now has `superseded_at` set. Both the old belief and the new belief are preserved.

## 6. Query the Graph

```sql
-- Everything about Alice
SELECT * FROM node_context
WHERE label = 'Alice Chen';

-- Current assertions for the project
SELECT assertion_type, claim, asserted_at
FROM current_assertions
WHERE subject_node_id = (SELECT id FROM nodes WHERE label = 'Q1 Launch');

-- Full history (including superseded assertions)
SELECT assertion_type, claim, asserted_at, superseded_at
FROM assertions
WHERE subject_node_id = (SELECT id FROM nodes WHERE label = 'Q1 Launch')
ORDER BY asserted_at;
```

---

## Next Steps

- [SaaS Customer Operations](saas-customer-operations.md) — if you run a SaaS company
- [Product Development](product-development.md) — if you're tracking features, bugs, and releases
- [Recruiting Pipeline](recruiting-pipeline.md) — if you're hiring
- [Mineral Rights Acquisition](mineral-rights.md) — for the domain that started it all
