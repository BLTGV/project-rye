# Cookbook: Recruiting Pipeline

## Candidates, Interviews, Offers, and Hires

---

## The Problem

A growing tech company tracks candidates in a spreadsheet, interview feedback in Slack threads, and offer details in email. When a hiring manager asks "Where are we on the senior engineer search?", someone spends 20 minutes piecing it together. When a candidate reapplies a year later, nobody remembers the previous interaction.

Rye models the entire pipeline as a graph with full history.

---

## 1. Entity Mapping

| Real-world thing | `node_type` | Key properties |
|---|---|---|
| Candidate | `person` | `first_name`, `last_name`, `email`, `linkedin_url` |
| Open role | `opportunity` | `name`, `code`, `department`, `level`, `location` |
| Interview | `event_type: interview` | `round`, `format`, `duration` |
| Referral source | `person` or `org` | Standard properties |

| Relationship | `edge_type` | Direction |
|---|---|---|
| Candidate applied to role | `applied_to` | person -> opportunity |
| Interviewer assessed candidate | `interviewed` | person -> person |
| Employee referred candidate | `referral` | person -> person |
| Role belongs to team | `assigned_to` | opportunity -> org |
| Hiring manager owns role | `assigned_to` | opportunity -> person |

---

## 2. Pipeline as a CRM Opportunity

Recruiting reuses the CRM pipeline model. An open role is an opportunity with its own pipeline stages:

```sql
INSERT INTO nodes (node_type, label, properties) VALUES (
    'pipeline', 'Recruiting Pipeline',
    '{
        "name": "Recruiting Pipeline",
        "code": "PL-RECRUIT",
        "stages": [
            {"key": "applied", "label": "Applied", "order": 1},
            {"key": "phone_screen", "label": "Phone Screen", "order": 2},
            {"key": "technical", "label": "Technical Interview", "order": 3},
            {"key": "onsite", "label": "Onsite / Final", "order": 4},
            {"key": "offer", "label": "Offer Extended", "order": 5},
            {"key": "hired", "label": "Hired", "order": 6, "terminal": true},
            {"key": "rejected", "label": "Rejected", "order": 7, "terminal": true},
            {"key": "withdrawn", "label": "Withdrawn", "order": 8, "terminal": true}
        ],
        "default_stage": "applied"
    }'
);
```

### Creating a role and a candidate

```sql
-- Open role
SELECT create_opportunity(
    'Senior Backend Engineer',
    'PL-RECRUIT',
    (SELECT id FROM nodes WHERE label = 'Jane Smith' AND node_type = 'person'),
    '{"department": "Engineering", "level": "senior", "location": "remote", "salary_range": "150k-180k"}',
    ARRAY['engineering', 'recruiting']
);

-- Candidate
INSERT INTO nodes (node_type, label, properties, attrs) VALUES (
    'person', 'Alex Rivera',
    '{"first_name": "Alex", "last_name": "Rivera", "email": "alex@example.com", "source": "referral"}',
    '{"teams": ["recruiting"]}'
);

-- Link candidate to role
INSERT INTO edges (edge_type, source_id, target_id, properties)
SELECT 'applied_to', candidate.id, role.id,
    '{"applied_date": "2024-03-15", "source": "referral", "resume_ref": "s3://resumes/alex-rivera.pdf"}'
FROM nodes candidate, nodes role
WHERE candidate.label = 'Alex Rivera'
  AND role.properties->>'code' LIKE 'OPP-%'
  AND role.label = 'Senior Backend Engineer';
```

---

## 3. Interview Tracking

Each interview is an event with structured feedback as an assertion:

```sql
-- Log a phone screen
WITH interview AS (
    INSERT INTO events (event_type, occurred_at, summary, properties, actor_system)
    VALUES (
        'interview', '2024-03-20T14:00:00Z',
        'Phone screen with Alex Rivera for Senior Backend Engineer',
        '{"round": "phone_screen", "format": "video", "duration_minutes": 45}',
        'user:jane'
    )
    RETURNING id
)
INSERT INTO event_participants (event_id, node_id, role)
SELECT interview.id, node_id, role
FROM interview,
(VALUES
    ((SELECT id FROM nodes WHERE label = 'Alex Rivera'), 'candidate'),
    ((SELECT id FROM nodes WHERE label = 'Jane Smith'), 'interviewer'),
    ((SELECT id FROM nodes WHERE label = 'Senior Backend Engineer' AND node_type = 'opportunity'), 'regarding')
) AS participants(node_id, role);

-- Record interviewer feedback as an assertion
INSERT INTO assertions (assertion_type, subject_node_id, claim, source_event_id, confidence)
VALUES (
    'interview_feedback',
    (SELECT id FROM nodes WHERE label = 'Alex Rivera'),
    '{
        "round": "phone_screen",
        "decision": "advance",
        "strengths": ["distributed systems experience", "clear communication"],
        "concerns": ["limited Go experience"],
        "notes": "Strong candidate. Recommend technical round.",
        "interviewer": "Jane Smith"
    }',
    (SELECT id FROM events WHERE summary LIKE '%Phone screen with Alex Rivera%' ORDER BY created_at DESC LIMIT 1),
    0.85
);
```

---

## 4. Advancing Through the Pipeline

```sql
-- Move candidate's application from phone_screen to technical
-- (Uses the same CRM pipeline stage mechanism)
SELECT advance_deal_stage(
    (SELECT id FROM nodes WHERE label = 'Senior Backend Engineer' AND node_type = 'opportunity'),
    'technical',
    'Alex Rivera passed phone screen, scheduling technical',
    'user:jane'
);
```

For per-candidate stage tracking (multiple candidates per role), use a `candidate_stage` assertion on the candidate node instead of the role node:

```sql
INSERT INTO assertions (assertion_type, subject_node_id, claim, confidence)
VALUES (
    'candidate_stage',
    (SELECT id FROM nodes WHERE label = 'Alex Rivera'),
    '{"stage": "technical", "role_code": "OPP-2403-0042", "moved_from": "phone_screen"}',
    1.0
);
```

---

## 5. Key Queries

### Pipeline funnel for a role

```sql
SELECT
    ca.claim->>'stage' AS stage,
    count(*) AS candidates
FROM edges app
JOIN nodes candidate ON candidate.id = app.source_id AND candidate.node_type = 'person'
JOIN current_assertions ca ON ca.subject_node_id = candidate.id AND ca.assertion_type = 'candidate_stage'
WHERE app.target_id = (SELECT id FROM nodes WHERE label = 'Senior Backend Engineer' AND node_type = 'opportunity')
  AND app.edge_type = 'applied_to' AND app.archived_at IS NULL
  AND ca.claim->>'role_code' = 'OPP-2403-0042'
GROUP BY ca.claim->>'stage'
ORDER BY min(
    CASE ca.claim->>'stage'
        WHEN 'applied' THEN 1 WHEN 'phone_screen' THEN 2
        WHEN 'technical' THEN 3 WHEN 'onsite' THEN 4
        WHEN 'offer' THEN 5 WHEN 'hired' THEN 6 ELSE 7
    END
);
```

### Candidate's full history (for reapplication)

```sql
-- All events involving this candidate
SELECT
    e.occurred_at, e.event_type, e.summary, ep.role, e.properties
FROM events e
JOIN event_participants ep ON ep.event_id = e.id
WHERE ep.node_id = (SELECT id FROM nodes WHERE label = 'Alex Rivera')
ORDER BY e.occurred_at DESC;

-- All assertions (current and superseded)
SELECT assertion_type, claim, asserted_at, superseded_at
FROM assertions
WHERE subject_node_id = (SELECT id FROM nodes WHERE label = 'Alex Rivera')
ORDER BY asserted_at DESC;
```

### Time-to-hire metrics

```sql
SELECT
    role.label AS role_name,
    candidate.label AS candidate_name,
    app.properties->>'applied_date' AS applied,
    hire_a.asserted_at AS hired_date,
    hire_a.asserted_at::date - (app.properties->>'applied_date')::date AS days_to_hire
FROM edges app
JOIN nodes candidate ON candidate.id = app.source_id
JOIN nodes role ON role.id = app.target_id
JOIN current_assertions hire_a ON hire_a.subject_node_id = candidate.id
    AND hire_a.assertion_type = 'candidate_stage'
    AND hire_a.claim->>'stage' = 'hired'
WHERE app.edge_type = 'applied_to' AND app.archived_at IS NULL;
```

---

## 6. Agent Interaction Examples

**Agent:** "Where are we on the senior backend engineer search?"

Queries the role's pipeline funnel, lists candidates by stage, surfaces any blocked interviews or overdue feedback.

**Agent:** "Alex Rivera just applied again. What happened last time?"

Retrieves Alex's full assertion and event history, including previous interview feedback, the stage they reached, and why they didn't advance (e.g., a `candidate_stage` assertion with `stage = 'rejected'`).

**Agent:** "Schedule a technical interview for Alex with two backend engineers."

Creates interview event placeholders, links participants, creates a task ("Conduct technical interview for Alex Rivera") assigned to the interviewers.
