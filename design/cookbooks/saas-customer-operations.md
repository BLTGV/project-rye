# Cookbook: SaaS Customer Operations

## Connecting Customers, Subscriptions, Support, and Feature Requests

---

## The Problem

A 20-person SaaS company has customer data scattered across Stripe (billing), Intercom (support), Linear (product), and a CRM spreadsheet. When a customer churns, nobody can quickly answer: "What support tickets did they have? What features did they request? Who was their primary contact? What changed in the last 90 days?"

Rye connects all of it in one graph without replacing any of those tools.

---

## 1. Entity Mapping

| Real-world thing | `node_type` | Key properties |
|---|---|---|
| Customer account | `org` | `name`, `plan`, `mrr`, `stripe_id` |
| Contact person | `person` | `first_name`, `last_name`, `email`, `role` |
| Support ticket | `ticket` | `title`, `channel`, `priority` |
| Feature request | `feature_request` | `title`, `description`, `votes` |
| Subscription | `subscription` | `plan`, `amount`, `interval` |

| Relationship | `edge_type` | Direction |
|---|---|---|
| Contact works at company | `employs` | org -> person |
| Customer filed ticket | `filed` | person -> ticket |
| Ticket is about customer | `regarding` | ticket -> org |
| Customer requested feature | `requested` | org -> feature_request |
| Contact upvoted feature | `upvoted` | person -> feature_request |
| Subscription belongs to customer | `subscription_for` | subscription -> org |

---

## 2. Ingestion from Existing Tools

The graph overlays your existing systems. Stripe, Intercom, and Linear remain the systems of record.

```sql
-- Import a Stripe customer as a graph node
SELECT link_record(
    p_source_schema := 'stripe',
    p_source_table  := 'customers',
    p_source_id     := 'cus_abc123',
    p_node_type     := 'org',
    p_label         := 'Acme Corp',
    p_properties    := '{"name": "Acme Corp", "plan": "growth", "mrr": 299, "stripe_id": "cus_abc123"}'
);

-- Import a support ticket from Intercom
SELECT link_record(
    p_source_schema := 'intercom',
    p_source_table  := 'conversations',
    p_source_id     := 'conv_789',
    p_node_type     := 'ticket',
    p_label         := 'Cannot export CSV reports',
    p_properties    := '{"title": "Cannot export CSV reports", "channel": "chat", "priority": "high"}'
);
```

`link_record()` creates the node and the `node_source_map` entry in one call. Each distinct `source_id` creates a new node. Calling it again with the same `(schema, table, source_id)` updates the existing node instead of creating a duplicate.

---

## 3. Key Assertions

```sql
-- Customer health score (updated monthly by an agent or script)
INSERT INTO assertions (assertion_type, subject_node_id, claim, confidence)
SELECT 'health_score', id, '{"score": 72, "trend": "declining", "factors": ["3 open tickets", "no login 14d"]}', 0.8
FROM nodes WHERE label = 'Acme Corp' AND node_type = 'org';

-- Churn risk
INSERT INTO assertions (assertion_type, subject_node_id, claim, confidence)
SELECT 'churn_risk', id, '{"level": "high", "signals": ["declining_usage", "open_tickets", "contract_renewal_30d"]}', 0.75
FROM nodes WHERE label = 'Acme Corp' AND node_type = 'org';

-- Ticket status (using assertion supersession for full history)
INSERT INTO assertions (assertion_type, subject_node_id, claim, confidence)
SELECT 'ticket_status', id, '{"status": "open", "assigned_to": "support-team"}', 1.0
FROM nodes WHERE label = 'Cannot export CSV reports' AND node_type = 'ticket';
```

---

## 4. Cross-Domain Queries

### Which churned customers had open tickets when they cancelled?

```sql
SELECT
    cust.label AS customer,
    cust.properties->>'plan' AS plan,
    (cust.properties->>'mrr')::numeric AS mrr,
    ticket.label AS open_ticket,
    churn_evt.occurred_at AS churn_date
FROM nodes cust
JOIN events churn_evt ON churn_evt.event_type = 'domain_change'
    AND churn_evt.properties->>'table' = 'subscriptions'
    AND churn_evt.properties->'new'->>'status' = 'cancelled'
JOIN event_participants ep ON ep.event_id = churn_evt.id AND ep.node_id = cust.id
JOIN edges filed ON filed.target_id = cust.id AND filed.edge_type = 'regarding' AND filed.archived_at IS NULL
JOIN nodes ticket ON ticket.id = filed.source_id AND ticket.node_type = 'ticket'
JOIN current_assertions ts ON ts.subject_node_id = ticket.id
    AND ts.assertion_type = 'ticket_status'
    AND ts.claim->>'status' NOT IN ('resolved', 'closed')
WHERE cust.node_type = 'org'
    AND churn_evt.occurred_at > now() - interval '90 days';
```

### What features are most requested by high-MRR customers?

```sql
SELECT
    fr.label AS feature,
    count(DISTINCT cust.id) AS requesting_customers,
    sum((cust.properties->>'mrr')::numeric) AS total_mrr
FROM nodes fr
JOIN edges req ON req.target_id = fr.id AND req.edge_type = 'requested' AND req.archived_at IS NULL
JOIN nodes cust ON cust.id = req.source_id AND cust.node_type = 'org'
WHERE fr.node_type = 'feature_request' AND fr.archived_at IS NULL
    AND (cust.properties->>'mrr')::numeric > 100
GROUP BY fr.id, fr.label
ORDER BY total_mrr DESC;
```

### Full context for a customer (agent-ready)

```sql
SELECT agent_node_summary(
    (SELECT id FROM nodes WHERE label = 'Acme Corp' AND node_type = 'org'),
    15  -- top 15 items per category
);
```

---

## 5. Agent Interaction Examples

**Agent:** "What's going on with Acme Corp?"

The agent calls `agent_node_summary` and gets back: the customer node, their top relationships (contacts, tickets, feature requests, subscription), current assertions (health score, churn risk), and recent activity (support chats, plan changes).

**Agent:** "Draft a retention plan for high-risk customers above $200 MRR."

The agent queries:
1. Customers where `churn_risk` assertion has `level = 'high'` and `mrr > 200`
2. For each: aggregate open tickets, requested features, last login event
3. Output a structured list the CS team can act on

**Agent:** "Log that I spoke with Alice at Acme about their export issue."

The agent calls `record_event()` with:
1. Event type `phone_call` and summary
2. Alice, Acme, and the export ticket as participants
3. Optionally supersedes the `sentiment` assertion with updated stance

---

## 6. Pipeline Example

A SaaS sales pipeline using the CRM conventions:

```sql
INSERT INTO nodes (node_type, label, properties) VALUES (
    'pipeline', 'SaaS Sales',
    '{
        "name": "SaaS Sales",
        "code": "PL-SALES",
        "stages": [
            {"key": "lead", "label": "Lead", "order": 1},
            {"key": "demo", "label": "Demo Scheduled", "order": 2},
            {"key": "trial", "label": "In Trial", "order": 3},
            {"key": "negotiation", "label": "Negotiation", "order": 4},
            {"key": "closed_won", "label": "Closed Won", "order": 5, "terminal": true},
            {"key": "closed_lost", "label": "Closed Lost", "order": 6, "terminal": true}
        ],
        "default_stage": "lead"
    }'
);
```
