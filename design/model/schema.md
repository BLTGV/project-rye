# Rye — Schema Reference

## Table Definitions, Indexes, and DDL

---

## 1. Prerequisites

**PostgreSQL version:** 15+ recommended. 13+ minimum (for `gen_random_uuid()` and improved JSONB performance).

**Required extensions:**

```sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";    -- UUID generation
CREATE EXTENSION IF NOT EXISTS "btree_gin";     -- Composite GIN indexes
CREATE EXTENSION IF NOT EXISTS "pg_trgm";       -- Trigram fuzzy text search
```

---

## 2. Creation Order

Due to foreign key dependencies, create tables in this order:

1. `nodes`
2. `edges` (depends on `nodes`)
3. `events` (depends on `nodes`)
4. `event_participants` (depends on `events`, `nodes`)
5. `assertions` (depends on `nodes`, `edges`, `events`, self-referencing)
6. `artifacts` (depends on `events`, `nodes`)
7. `access_grants`
8. `field_classifications`
9. `node_source_map` (depends on `nodes`)
10. `node_merges` (depends on `nodes`)
11. `crm_code_counters`
12. Views: `current_assertions`, `node_context`

---

## 3. Table Specifications

### 3.1 `nodes` — Entities

Every trackable entity is a node. People, companies, projects, tickets, documents, parcels — all differentiated by `node_type`.

| Column | Type | Purpose |
|---|---|---|
| `id` | `uuid` | Primary key, auto-generated |
| `node_type` | `text NOT NULL` | Entity type discriminator |
| `label` | `text` | Human-readable display name |
| `external_id` | `text` | Identifier from the source system |
| `external_source` | `text` | Source system identifier |
| `properties` | `jsonb NOT NULL DEFAULT '{}'` | Domain-specific data, GIN-indexed |
| `attrs` | `jsonb NOT NULL DEFAULT '{}'` | System metadata: classification, teams, tags |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | Row creation |
| `updated_at` | `timestamptz NOT NULL DEFAULT now()` | Last modification |
| `archived_at` | `timestamptz` | Soft delete (null = active) |

### 3.2 `edges` — Relationships

Directed relationships between nodes with optional temporal bounds.

| Column | Type | Purpose |
|---|---|---|
| `id` | `uuid` | Primary key |
| `edge_type` | `text NOT NULL` | Relationship type |
| `source_id` | `uuid NOT NULL` | FK to `nodes.id` — the "from" node |
| `target_id` | `uuid NOT NULL` | FK to `nodes.id` — the "to" node |
| `properties` | `jsonb NOT NULL DEFAULT '{}'` | Relationship-specific data, GIN-indexed |
| `effective_from` | `timestamptz` | When the relationship began in reality |
| `effective_to` | `timestamptz` | When it ended (null = still active) |
| `weight` | `numeric DEFAULT 1.0` | Relevance/confidence weight |
| `attrs` | `jsonb NOT NULL DEFAULT '{}'` | System metadata |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | Row creation |
| `archived_at` | `timestamptz` | Soft delete |

### 3.3 `events` — Activity Log

Immutable record of things that happened. Never modified or deleted.

| Column | Type | Purpose |
|---|---|---|
| `id` | `uuid` | Primary key |
| `event_type` | `text NOT NULL` | Activity type |
| `occurred_at` | `timestamptz NOT NULL` | When it actually happened |
| `recorded_at` | `timestamptz NOT NULL DEFAULT now()` | When we logged it |
| `summary` | `text` | Short human-readable description |
| `properties` | `jsonb NOT NULL DEFAULT '{}'` | Rich event payload, GIN-indexed |
| `actor_node_id` | `uuid` | FK to `nodes.id` — who performed the action |
| `actor_system` | `text` | System identifier (e.g., `'user:jane'`, `'agent:triage-bot'`) |
| `attrs` | `jsonb NOT NULL DEFAULT '{}'` | System metadata |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | Row creation |

The distinction between `occurred_at` and `recorded_at` matters. An email was sent Tuesday (`occurred_at`) but imported Friday (`recorded_at`).

### 3.4 `event_participants` — Event-to-Node Links

| Column | Type | Purpose |
|---|---|---|
| `id` | `uuid` | Primary key |
| `event_id` | `uuid NOT NULL` | FK to `events.id` |
| `node_id` | `uuid NOT NULL` | FK to `nodes.id` |
| `role` | `text NOT NULL` | How the node participated |
| `properties` | `jsonb NOT NULL DEFAULT '{}'` | Role-specific metadata |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | Row creation |

Unique constraint on `(event_id, node_id, role)`. A node can participate in the same event in multiple roles.

### 3.5 `assertions` — Time-Versioned Facts

Append-only claims about nodes or edges. When a newer fact contradicts an older one, the old assertion is superseded — never mutated.

| Column | Type | Purpose |
|---|---|---|
| `id` | `uuid` | Primary key |
| `assertion_type` | `text NOT NULL` | Fact category |
| `subject_node_id` | `uuid` | FK to `nodes.id` |
| `subject_edge_id` | `uuid` | FK to `edges.id` |
| `claim` | `jsonb NOT NULL` | The actual fact content, GIN-indexed |
| `asserted_at` | `timestamptz NOT NULL DEFAULT now()` | When we recorded this belief |
| `effective_at` | `timestamptz` | When it became true in reality |
| `superseded_at` | `timestamptz` | When a newer assertion replaced it |
| `superseded_by` | `uuid` | FK to `assertions.id` |
| `source_event_id` | `uuid` | FK to `events.id` — provenance |
| `confidence` | `numeric CHECK (confidence BETWEEN 0 AND 1)` | Confidence score |
| `attrs` | `jsonb NOT NULL DEFAULT '{}'` | System metadata |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | Row creation |

Check constraint: at least one of `subject_node_id` or `subject_edge_id` must be set.

An immutability trigger prevents updates to any column except `superseded_at` and `superseded_by`. See [Functions Reference](functions.md).

### 3.6 `artifacts` — Extracted Content

Content objects produced by or referenced from events.

| Column | Type | Purpose |
|---|---|---|
| `id` | `uuid` | Primary key |
| `artifact_type` | `text NOT NULL` | Content type |
| `source_event_id` | `uuid` | FK to `events.id` |
| `source_node_id` | `uuid` | FK to `nodes.id` |
| `content` | `jsonb NOT NULL DEFAULT '{}'` | The actual content, GIN-indexed |
| `location` | `jsonb` | Where in the source this came from |
| `related_node_ids` | `uuid[]` | Quick-reference array of related nodes |
| `attrs` | `jsonb NOT NULL DEFAULT '{}'` | System metadata |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | Row creation |

### 3.7 `access_grants` — Permissions

| Column | Type | Purpose |
|---|---|---|
| `id` | `uuid` | Primary key |
| `grantee` | `text NOT NULL` | User ID, role name, or team label |
| `grant_type` | `text NOT NULL` | `'user'`, `'role'`, `'team'` |
| `resource_type` | `text NOT NULL` | `'node'`, `'edge'`, `'event'`, `'assertion'` |
| `access_level` | `text NOT NULL` | `'read'`, `'write'`, `'admin'` |
| `scope` | `jsonb NOT NULL` | What the grant covers, GIN-indexed |
| `active` | `boolean DEFAULT true` | Whether the grant is in effect |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | Row creation |

### 3.8 `field_classifications` — Field-Level Sensitivity

| Column | Type | Purpose |
|---|---|---|
| `id` | `uuid` | Primary key |
| `node_type` | `text NOT NULL` | Which entity type |
| `field_path` | `text NOT NULL` | Path to the field: `'properties.ssn'` |
| `classification` | `text NOT NULL` | `'public'`, `'internal'`, `'confidential'`, `'restricted'` |
| `min_role` | `text NOT NULL` | Minimum role required (checked via session var) |

Unique on `(node_type, field_path)`.

### 3.9 `node_source_map` — Domain Table Integration

Maps graph nodes to source records in domain tables.

| Column | Type | Purpose |
|---|---|---|
| `node_id` | `uuid NOT NULL` | FK to `nodes.id` |
| `source_schema` | `text NOT NULL` | Database schema |
| `source_table` | `text NOT NULL` | Table name |
| `source_id` | `text NOT NULL` | Primary key in the source table |
| `source_id_type` | `text DEFAULT 'int'` | Type hint for casting |
| `synced_at` | `timestamptz DEFAULT now()` | Last sync |

Primary key: `(node_id, source_schema, source_table)`.

### 3.10 `node_merges` — Deduplication Tracking

| Column | Type | Purpose |
|---|---|---|
| `id` | `uuid` | Primary key |
| `duplicate_id` | `uuid NOT NULL` | FK to `nodes.id` — the absorbed node |
| `canonical_id` | `uuid NOT NULL` | FK to `nodes.id` — the surviving node |
| `merged_at` | `timestamptz NOT NULL DEFAULT now()` | When the merge happened |
| `merged_by` | `text` | Who confirmed it |
| `confidence` | `numeric` | Confidence score if auto-detected |
| `properties` | `jsonb DEFAULT '{}'` | Merge notes |

### 3.11 `crm_code_counters` — Human-Readable Code Generation

| Column | Type | Purpose |
|---|---|---|
| `prefix` | `text NOT NULL` | Code prefix (`'OPP'`, `'TSK'`, `'CON'`, etc.) |
| `year_month` | `text NOT NULL` | YYMM period |
| `next_val` | `int NOT NULL DEFAULT 1` | Next sequence value |

Primary key: `(prefix, year_month)`. Concurrency-safe via `INSERT ... ON CONFLICT DO UPDATE`.

---

## 4. DDL

```sql
-- ============================================================================
-- EXTENSIONS
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "btree_gin";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";


-- ============================================================================
-- 1. NODES
-- ============================================================================

CREATE TABLE nodes (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    node_type       text NOT NULL,
    label           text,
    external_id     text,
    external_source text,
    properties      jsonb NOT NULL DEFAULT '{}',
    attrs           jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    archived_at     timestamptz
);

CREATE INDEX idx_nodes_type          ON nodes (node_type);
CREATE INDEX idx_nodes_external      ON nodes (external_source, external_id);
CREATE INDEX idx_nodes_label         ON nodes USING gin (label gin_trgm_ops);
CREATE INDEX idx_nodes_properties    ON nodes USING gin (properties);
CREATE INDEX idx_nodes_attrs         ON nodes USING gin (attrs);
CREATE INDEX idx_nodes_created       ON nodes (created_at);
CREATE INDEX idx_nodes_active        ON nodes (node_type) WHERE archived_at IS NULL;

-- Partial unique index for external ID deduplication.
-- Referenced in ON CONFLICT clauses as:
--   ON CONFLICT (external_source, external_id)
--     WHERE external_id IS NOT NULL AND archived_at IS NULL
CREATE UNIQUE INDEX idx_nodes_external_unique
    ON nodes (external_source, external_id)
    WHERE external_id IS NOT NULL AND archived_at IS NULL;


-- ============================================================================
-- 2. EDGES
-- ============================================================================

CREATE TABLE edges (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    edge_type       text NOT NULL,
    source_id       uuid NOT NULL REFERENCES nodes(id),
    target_id       uuid NOT NULL REFERENCES nodes(id),
    properties      jsonb NOT NULL DEFAULT '{}',
    effective_from  timestamptz,
    effective_to    timestamptz,
    weight          numeric DEFAULT 1.0,
    attrs           jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    archived_at     timestamptz
);

CREATE INDEX idx_edges_type          ON edges (edge_type);
CREATE INDEX idx_edges_source        ON edges (source_id);
CREATE INDEX idx_edges_target        ON edges (target_id);
CREATE INDEX idx_edges_source_type   ON edges (source_id, edge_type);
CREATE INDEX idx_edges_target_type   ON edges (target_id, edge_type);
CREATE INDEX idx_edges_properties    ON edges USING gin (properties);
CREATE INDEX idx_edges_effective     ON edges (effective_from, effective_to);
CREATE INDEX idx_edges_active        ON edges (edge_type) WHERE archived_at IS NULL;


-- ============================================================================
-- 3. EVENTS
-- ============================================================================

CREATE TABLE events (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type      text NOT NULL,
    occurred_at     timestamptz NOT NULL,
    recorded_at     timestamptz NOT NULL DEFAULT now(),
    summary         text,
    properties      jsonb NOT NULL DEFAULT '{}',
    actor_node_id   uuid REFERENCES nodes(id),
    actor_system    text,
    attrs           jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_events_type         ON events (event_type);
CREATE INDEX idx_events_occurred     ON events (occurred_at);
CREATE INDEX idx_events_recorded     ON events (recorded_at);
CREATE INDEX idx_events_actor        ON events (actor_node_id);
CREATE INDEX idx_events_properties   ON events USING gin (properties);


-- ============================================================================
-- 4. EVENT PARTICIPANTS
-- ============================================================================

CREATE TABLE event_participants (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id        uuid NOT NULL REFERENCES events(id),
    node_id         uuid NOT NULL REFERENCES nodes(id),
    role            text NOT NULL,
    properties      jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_ep_event  ON event_participants (event_id);
CREATE INDEX idx_ep_node   ON event_participants (node_id);
CREATE INDEX idx_ep_role   ON event_participants (role);
CREATE UNIQUE INDEX idx_ep_unique ON event_participants (event_id, node_id, role);


-- ============================================================================
-- 5. ASSERTIONS
-- ============================================================================

CREATE TABLE assertions (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    assertion_type  text NOT NULL,
    subject_node_id uuid REFERENCES nodes(id),
    subject_edge_id uuid REFERENCES edges(id),
    claim           jsonb NOT NULL,
    asserted_at     timestamptz NOT NULL DEFAULT now(),
    effective_at    timestamptz,
    superseded_at   timestamptz,
    superseded_by   uuid REFERENCES assertions(id),
    source_event_id uuid REFERENCES events(id),
    confidence      numeric CHECK (confidence BETWEEN 0 AND 1),
    attrs           jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT assertion_has_subject CHECK (
        subject_node_id IS NOT NULL OR subject_edge_id IS NOT NULL
    )
);

CREATE INDEX idx_assertions_type       ON assertions (assertion_type);
CREATE INDEX idx_assertions_node       ON assertions (subject_node_id)
                                        WHERE subject_node_id IS NOT NULL;
CREATE INDEX idx_assertions_edge       ON assertions (subject_edge_id)
                                        WHERE subject_edge_id IS NOT NULL;
CREATE INDEX idx_assertions_claim      ON assertions USING gin (claim);
CREATE INDEX idx_assertions_asserted   ON assertions (asserted_at);
CREATE INDEX idx_assertions_effective  ON assertions (effective_at);
CREATE INDEX idx_assertions_active     ON assertions (subject_node_id, assertion_type)
                                        WHERE superseded_at IS NULL;


-- ============================================================================
-- 6. ARTIFACTS
-- ============================================================================

CREATE TABLE artifacts (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    artifact_type   text NOT NULL,
    source_event_id uuid REFERENCES events(id),
    source_node_id  uuid REFERENCES nodes(id),
    content         jsonb NOT NULL DEFAULT '{}',
    location        jsonb,
    related_node_ids uuid[],
    attrs           jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_artifacts_type      ON artifacts (artifact_type);
CREATE INDEX idx_artifacts_source_ev ON artifacts (source_event_id);
CREATE INDEX idx_artifacts_source_nd ON artifacts (source_node_id);
CREATE INDEX idx_artifacts_content   ON artifacts USING gin (content);
CREATE INDEX idx_artifacts_related   ON artifacts USING gin (related_node_ids);


-- ============================================================================
-- 7. ACCESS GRANTS
-- ============================================================================

CREATE TABLE access_grants (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    grantee         text NOT NULL,
    grant_type      text NOT NULL,
    resource_type   text NOT NULL,
    access_level    text NOT NULL,
    scope           jsonb NOT NULL,
    active          boolean DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_ag_grantee ON access_grants (grantee, resource_type);
CREATE INDEX idx_ag_scope   ON access_grants USING gin (scope);


-- ============================================================================
-- 8. FIELD CLASSIFICATIONS
-- ============================================================================

CREATE TABLE field_classifications (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    node_type       text NOT NULL,
    field_path      text NOT NULL,
    classification  text NOT NULL,
    min_role        text NOT NULL,
    UNIQUE (node_type, field_path)
);


-- ============================================================================
-- 9. NODE SOURCE MAP
-- ============================================================================

CREATE TABLE node_source_map (
    node_id         uuid NOT NULL REFERENCES nodes(id),
    source_schema   text NOT NULL,
    source_table    text NOT NULL,
    source_id       text NOT NULL,
    source_id_type  text DEFAULT 'int',
    synced_at       timestamptz DEFAULT now(),
    PRIMARY KEY (node_id, source_schema, source_table)
);

CREATE INDEX idx_nsm_source ON node_source_map (source_schema, source_table, source_id);


-- ============================================================================
-- 10. NODE MERGES
-- ============================================================================

CREATE TABLE node_merges (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    duplicate_id    uuid NOT NULL REFERENCES nodes(id),
    canonical_id    uuid NOT NULL REFERENCES nodes(id),
    merged_at       timestamptz NOT NULL DEFAULT now(),
    merged_by       text,
    confidence      numeric,
    properties      jsonb DEFAULT '{}'
);

CREATE INDEX idx_merges_dup ON node_merges (duplicate_id);
CREATE INDEX idx_merges_can ON node_merges (canonical_id);


-- ============================================================================
-- 11. CRM CODE COUNTERS
-- ============================================================================

CREATE TABLE crm_code_counters (
    prefix      text NOT NULL,
    year_month  text NOT NULL,
    next_val    int NOT NULL DEFAULT 1,
    PRIMARY KEY (prefix, year_month)
);


-- ============================================================================
-- 12. VIEWS
-- ============================================================================

CREATE VIEW current_assertions AS
SELECT *
FROM assertions
WHERE superseded_at IS NULL;

CREATE VIEW node_context AS
SELECT
    n.id AS node_id,
    n.node_type,
    n.label,
    n.properties,
    json_agg(DISTINCT jsonb_build_object(
        'edge_id', eo.id, 'edge_type', eo.edge_type,
        'target_id', eo.target_id, 'properties', eo.properties
    )) FILTER (WHERE eo.id IS NOT NULL) AS outbound_edges,
    json_agg(DISTINCT jsonb_build_object(
        'edge_id', ei.id, 'edge_type', ei.edge_type,
        'source_id', ei.source_id, 'properties', ei.properties
    )) FILTER (WHERE ei.id IS NOT NULL) AS inbound_edges,
    json_agg(DISTINCT jsonb_build_object(
        'assertion_id', a.id, 'type', a.assertion_type,
        'claim', a.claim, 'asserted_at', a.asserted_at
    )) FILTER (WHERE a.id IS NOT NULL) AS current_assertions
FROM nodes n
LEFT JOIN edges eo ON eo.source_id = n.id AND eo.archived_at IS NULL
LEFT JOIN edges ei ON ei.target_id = n.id AND ei.archived_at IS NULL
LEFT JOIN current_assertions a ON a.subject_node_id = n.id
WHERE n.archived_at IS NULL
GROUP BY n.id, n.node_type, n.label, n.properties;
```

---

## 5. Upsert Pattern

When ingesting data from external systems, use the partial unique index for deduplication:

```sql
INSERT INTO nodes (node_type, label, external_id, external_source, properties)
VALUES ('person', 'Jane Doe', 'CRM-003456', 'salesforce', '{"email": "jane@example.com"}')
ON CONFLICT (external_source, external_id)
    WHERE external_id IS NOT NULL AND archived_at IS NULL
DO UPDATE SET
    properties = nodes.properties || EXCLUDED.properties,
    updated_at = now();
```

Note: the `ON CONFLICT` clause must match the partial index predicate exactly.
