# Cookbook: Mineral Rights Acquisition

## Parcels, Owners, Title Opinions, and Deals

---

## The Problem

A mineral rights acquisition company tracks parcels in a GIS system, contacts in a CRM, documents in Box, title opinions in attorney reports, and deal progress in spreadsheets. A landman asking "What do we know about TMP 45-2-31?" has to cross-reference five systems and hope nothing's outdated.

Rye connects all of it. The same parcel node links to its owners, the documents that reference it, the opportunities targeting it, and the evolving title opinions about it.

---

## 1. Entity Mapping

| Real-world thing | `node_type` | Key properties |
|---|---|---|
| Tax Map Parcel | `parcel` | `tmp`, `tmp_normalized`, `county`, `state`, `acreage` |
| Mineral owner | `person` | `first_name`, `last_name`, `phone`, `address` |
| Operator / Lessee | `org` | `name`, `industry` |
| Title document | `document` | `filename`, `mime_type`, `page_count`, `box_file_id` |
| Acquisition opportunity | `opportunity` | `name`, `code`, `estimated_value`, `estimated_net_acres` |

| Relationship | `edge_type` | Direction |
|---|---|---|
| Person owns interest in parcel | `owns` | person -> parcel |
| Document references parcel | `references` | document -> parcel |
| Opportunity targets parcel | `targets` | opportunity -> parcel |
| Org employs person | `employs` | org -> person |
| Parcels are adjacent | `adjacent_to` | parcel -> parcel |
| Deed conveys interest | `conveyed_to` | person -> person |

---

## 2. Parcel Ingestion

Use the `normalize_tmp` function (see [Functions](../model/functions.md)) to ensure consistent identifiers:

```sql
INSERT INTO nodes (node_type, label, external_id, external_source, properties)
VALUES (
    'parcel',
    'TMP 45-2-31 (Doddridge, WV)',
    '45-2-31',
    'county_gis',
    '{
        "tmp": "45-2-31",
        "tmp_normalized": "45-2-31",
        "county": "Doddridge",
        "state": "WV",
        "acreage": 120.5,
        "tax_district": "Grant"
    }'
)
ON CONFLICT (external_source, external_id)
    WHERE external_id IS NOT NULL AND archived_at IS NULL
DO UPDATE SET properties = nodes.properties || EXCLUDED.properties, updated_at = now();
```

---

## 3. Ownership as Assertions

Ownership is an assertion, not a static property, because it changes over time and history matters:

```sql
-- Record that John Smith owns 1/16 mineral interest
INSERT INTO assertions (assertion_type, subject_node_id, claim, confidence, source_event_id)
VALUES (
    'ownership',
    (SELECT id FROM nodes WHERE properties @> '{"tmp_normalized": "45-2-31"}'),
    '{
        "owner_node_id": "<john_smith_uuid>",
        "fraction": "1/16",
        "decimal": 0.0625,
        "net_acres": 7.5,
        "mineral_type": "oil_gas",
        "basis": "deed_book_123_page_456",
        "type": "mineral"
    }',
    0.95,
    '<title_run_event_uuid>'
);
```

When a later title run reveals the interest was actually conveyed:

```sql
SELECT supersede_assertion(
    p_old_assertion_id := '<original_ownership_assertion>',
    p_new_assertion_type := 'ownership',
    p_new_subject_node_id := (SELECT id FROM nodes WHERE properties @> '{"tmp_normalized": "45-2-31"}'),
    p_new_subject_edge_id := NULL,
    p_new_claim := '{
        "owner_node_id": "<jane_doe_uuid>",
        "fraction": "1/16",
        "decimal": 0.0625,
        "net_acres": 7.5,
        "mineral_type": "oil_gas",
        "basis": "conveyance_deed_book_200_page_300",
        "conveyed_from": "<john_smith_uuid>",
        "conveyance_date": "2019-06-15"
    }',
    p_new_source_event_id := '<new_title_run_event_uuid>',
    p_new_confidence := 0.98
);
```

Both the old belief and the new one are preserved. An agent can show the full ownership history.

---

## 4. Title Opinions

```sql
INSERT INTO assertions (assertion_type, subject_node_id, claim, confidence, source_event_id)
VALUES (
    'title_opinion',
    (SELECT id FROM nodes WHERE properties @> '{"tmp_normalized": "45-2-31"}'),
    '{
        "quality": "marketable",
        "exceptions": ["Outstanding mortgage - Book 200 Page 100"],
        "attorney": "Jane Doe, Esq.",
        "opinion_date": "2024-03-20"
    }',
    0.95,
    '<title_review_event_uuid>'
);
```

---

## 5. CRM Pipeline for Acquisitions

```sql
INSERT INTO nodes (node_type, label, properties) VALUES (
    'pipeline', 'Mineral Acquisition',
    '{
        "name": "Mineral Acquisition",
        "code": "PL-MINACQ",
        "stages": [
            {"key": "prospecting", "label": "Prospecting", "order": 1},
            {"key": "outreach", "label": "Initial Outreach", "order": 2},
            {"key": "title_review", "label": "Title Review", "order": 3},
            {"key": "negotiation", "label": "Negotiation", "order": 4},
            {"key": "due_diligence", "label": "Due Diligence", "order": 5},
            {"key": "closing", "label": "Closing", "order": 6},
            {"key": "closed_won", "label": "Closed Won", "order": 7, "terminal": true},
            {"key": "closed_lost", "label": "Closed Lost", "order": 8, "terminal": true}
        ],
        "default_stage": "prospecting"
    }'
);

-- Create an acquisition opportunity targeting the parcel
SELECT create_opportunity(
    'Smith Tract Acquisition',
    'PL-MINACQ',
    (SELECT id FROM nodes WHERE label = 'Jane Landman'),
    '{"estimated_value": 250000, "estimated_net_acres": 45.0, "county": "Doddridge", "state": "WV"}',
    ARRAY['appalachia_team']
);
```

---

## 6. Key Queries

### Everything about a parcel

```sql
SELECT agent_node_summary(
    (SELECT id FROM nodes WHERE properties @> '{"tmp_normalized": "45-2-31"}'),
    20
);
```

### Current ownership of a parcel

```sql
SELECT
    owner.label AS owner_name,
    a.claim->>'fraction' AS fraction,
    (a.claim->>'decimal')::numeric AS decimal_interest,
    a.confidence,
    a.asserted_at
FROM current_assertions a
JOIN nodes owner ON owner.id = (a.claim->>'owner_node_id')::uuid
WHERE a.subject_node_id = (SELECT id FROM nodes WHERE properties @> '{"tmp_normalized": "45-2-31"}')
  AND a.assertion_type = 'ownership'
ORDER BY (a.claim->>'decimal')::numeric DESC;
```

### Documents referencing parcels in an opportunity

```sql
SELECT DISTINCT
    d.label AS document_name,
    d.properties->>'filename' AS filename,
    p.properties->>'tmp' AS parcel_tmp,
    ref.properties->>'page' AS reference_page
FROM nodes opp
JOIN edges tgt ON tgt.source_id = opp.id AND tgt.edge_type = 'targets' AND tgt.archived_at IS NULL
JOIN nodes p ON p.id = tgt.target_id AND p.node_type = 'parcel'
JOIN edges ref ON ref.target_id = p.id AND ref.edge_type = 'references' AND ref.archived_at IS NULL
JOIN nodes d ON d.id = ref.source_id AND d.node_type = 'document'
WHERE opp.properties @> '{"code": "OPP-2403-0042"}';
```

### Contacts we haven't reached in 30 days on active deals

```sql
SELECT
    con.label AS contact_name,
    opp.properties->>'code' AS opp_code,
    max(e.occurred_at) AS last_touch,
    now() - max(e.occurred_at) AS days_since
FROM nodes opp
JOIN edges pc ON pc.source_id = opp.id
    AND pc.edge_type IN ('primary_contact', 'secondary_contact')
    AND pc.archived_at IS NULL
JOIN nodes con ON con.id = pc.target_id
LEFT JOIN event_participants ep ON ep.node_id = con.id
LEFT JOIN events e ON e.id = ep.event_id
    AND e.event_type IN ('phone_call', 'email', 'meeting', 'site_visit')
JOIN current_assertions stg ON stg.subject_node_id = opp.id
    AND stg.assertion_type = 'deal_stage'
WHERE opp.node_type = 'opportunity' AND opp.archived_at IS NULL
    AND stg.claim->>'stage' NOT IN ('closed_won', 'closed_lost', 'dead')
GROUP BY con.id, con.label, opp.properties->>'code'
HAVING max(e.occurred_at) < now() - interval '30 days'
    OR max(e.occurred_at) IS NULL
ORDER BY days_since DESC NULLS FIRST;
```

---

## 7. Agent Interaction Examples

**Agent:** "What do we know about TMP 45-2-31?"

Calls `agent_node_summary` — returns the parcel, current ownership assertions, title opinions, linked opportunities, recent activity (site visits, calls with owners).

**Agent:** "Who should we contact next on the Smith Tract deal?"

Queries opportunity contacts, checks last touchpoint dates, surfaces `sentiment` and `do_not_contact` assertions, recommends next actions.

**Agent:** "Record that I called John Smith about the Smith Tract. He's interested but wants above-market pricing."

Inserts a `phone_call` event, links participants, supersedes `sentiment` assertion with `{stance: "willing_to_sell", price_expectation: "above_market"}`.
