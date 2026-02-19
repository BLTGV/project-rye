# Project Rye — Scaling Considerations

## Performance Characteristics, Thresholds, and Upgrade Paths

---

## Table of Contents

1. [Baseline Performance Profile](#1-baseline-performance-profile)
2. [Scale Thresholds](#2-scale-thresholds)
3. [GIN Index Management](#3-gin-index-management)
4. [Row-Level Security at Scale](#4-row-level-security-at-scale)
5. [Graph Traversal Performance](#5-graph-traversal-performance)
6. [Agent-Specific Considerations](#6-agent-specific-considerations)
7. [Write Path Optimization](#7-write-path-optimization)
8. [Partitioning Strategy](#8-partitioning-strategy)
9. [Materialized Views and Denormalization](#9-materialized-views-and-denormalization)
10. [Connection and Concurrency Management](#10-connection-and-concurrency-management)
11. [Monitoring and Instrumentation](#11-monitoring-and-instrumentation)
12. [Upgrade Paths at Each Threshold](#12-upgrade-paths-at-each-threshold)
13. [What Not to Worry About Yet](#13-what-not-to-worry-about-yet)

---

## 1. Baseline Performance Profile

Rye is a PostgreSQL schema. Its performance characteristics are PostgreSQL's performance characteristics, shaped by the specific index and query patterns the schema uses. Here is what to expect under normal operating conditions before any optimization.

### 1.1 Read Performance

**Point lookups on nodes by JSONB property:**

```sql
SELECT * FROM nodes WHERE properties @> '{"tmp_normalized": "45-2-31"}';
```

This query hits the GIN index on `properties`. At 1 million nodes, expect sub-5ms response times. At 10 million nodes, expect 5-15ms. The GIN index scales logarithmically with row count, so doubling the table size does not double the query time.

**Edge traversal (single hop):**

```sql
SELECT * FROM edges WHERE source_id = '<uuid>' AND edge_type = 'owns';
```

This hits the composite B-tree index `(source_id, edge_type)`. Sub-millisecond at any reasonable scale. B-tree lookups are O(log n) and edges are indexed on both endpoints.

**Current assertions for a node:**

```sql
SELECT * FROM current_assertions WHERE subject_node_id = '<uuid>';
```

The partial index `idx_assertions_active` covers only rows where `superseded_at IS NULL`. This means the index only contains the active assertion set, regardless of how much history exists. At 20 million total assertions with 2 million active, the index is sized for 2 million rows, not 20 million.

**Full context query (node + edges + assertions):**

The `node_context` view joins across nodes, edges, and current_assertions with aggregation. For a node with 50 edges and 20 active assertions, expect 10-30ms. For a node with 500 edges and 100 assertions, expect 50-150ms. The bottleneck is the aggregation, not the joins.

### 1.2 Write Performance

**Single node insert:** Sub-millisecond for the row itself. GIN index maintenance adds 1-5ms per insert depending on the size of the JSONB `properties` payload. Total: 2-6ms.

**Single event insert with participant links:** The event insert plus 2-3 `event_participants` inserts, typically within a single transaction. Total: 5-15ms.

**Single assertion insert:** Similar to node insert. The GIN index on `claim` is the primary overhead. Total: 2-8ms.

**Assertion supersession (old assertion update + new assertion insert):** Two operations in a transaction. The update to `superseded_at` on the old assertion is a B-tree index update (fast). The insert of the new assertion is the same as above. Total: 5-15ms.

### 1.3 Baseline Resource Usage

For a working set of 1 million nodes, 5 million edges, 10 million events, and 5 million assertions:

- **Disk:** Approximately 15-30 GB for tables and indexes, depending on average JSONB payload size. GIN indexes on JSONB are typically 2-4x the size of the underlying data.
- **Memory:** PostgreSQL's `shared_buffers` should be set to 25% of available RAM. For this working set, 4-8 GB of shared buffers provides a high cache hit ratio.
- **CPU:** Read-heavy workloads are I/O-bound, not CPU-bound. Write-heavy workloads are CPU-bound due to GIN index maintenance.

---

## 2. Scale Thresholds

These are approximate inflection points where you should begin monitoring and planning, not hard limits where things break.

### 2.1 Comfortable Operating Range

The schema works with default PostgreSQL configuration and no special optimization.

| Metric | Threshold |
|---|---|
| Total nodes | < 5 million |
| Total edges | < 10 million |
| Total events | < 50 million |
| Total assertions | < 20 million |
| Active (non-superseded) assertions | < 5 million |
| Concurrent agents | < 50 |
| Concurrent human users | < 200 |
| Event writes per second | < 500 |
| Assertion writes per second | < 200 |
| Graph traversal depth | ≤ 3 hops |
| Average JSONB properties size | < 2 KB |
| RLS policy evaluation | < 10% of query time |

Within this range, the primary work is ensuring proper PostgreSQL tuning (`shared_buffers`, `work_mem`, `effective_cache_size`, `random_page_cost`) and connection pooling.

### 2.2 Attention Range

Performance remains good but requires monitoring, targeted indexes, and possibly partitioning.

| Metric | Threshold |
|---|---|
| Total nodes | 5-20 million |
| Total edges | 10-50 million |
| Total events | 50-200 million |
| Total assertions | 20-100 million |
| Active assertions | 5-20 million |
| Concurrent agents | 50-200 |
| Event writes per second | 500-2,000 |
| Graph traversal depth | 4 hops |
| RLS policy evaluation | 10-40% of query time |

At this range, you should be partitioning events and assertions by time, using materialized views for frequent query patterns, and potentially denormalizing access control for RLS performance.

### 2.3 Redesign Range

The PostgreSQL-only approach is still viable but requires significant architecture work: heavy partitioning, read replicas, query routing, and possibly a complementary graph engine.

| Metric | Threshold |
|---|---|
| Total nodes | > 20 million |
| Total edges | > 50 million |
| Total events | > 200 million |
| Concurrent agents | > 200 |
| Event writes per second | > 2,000 |
| Graph traversal depth | ≥ 5 hops |
| RLS policy evaluation | > 40% of query time |

At this range, consider Apache AGE for graph traversal, dedicated read replicas for agent queries, event streaming (Kafka/NATS) to decouple write ingestion from the primary database, and potentially a time-series store for high-volume event data.

---

## 3. GIN Index Management

GIN (Generalized Inverted Index) indexes are the backbone of Rye's JSONB queryability. They enable containment queries (`@>`), key existence checks (`?`), and key-array operations (`?|`, `?&`) to use indexes instead of sequential scans. They are the first component that requires attention at scale.

### 3.1 How GIN Indexes Work

A GIN index decomposes each JSONB document into its individual key-value pairs and indexes each pair separately. A query like `properties @> '{"county": "Doddridge"}'` looks up the key-value pair `county: Doddridge` in the inverted index and returns matching row IDs.

The cost is on write. When a new row is inserted or a JSONB column is updated, the GIN index must be updated with every key-value pair in the document. A JSONB object with 10 keys produces 10 index entries. This is more expensive than a B-tree insert, which produces one entry.

### 3.2 The Pending List

PostgreSQL mitigates GIN write cost with a **pending list** — new index entries are batched in a temporary unordered list and merged into the main index structure periodically or when the list reaches a configurable size.

```sql
-- Default is 4MB. Increase for write-heavy workloads.
ALTER INDEX idx_events_properties SET (gin_pending_list_limit = '16MB');
ALTER INDEX idx_assertions_claim SET (gin_pending_list_limit = '16MB');
```

A larger pending list reduces write latency (entries are batched more aggressively) but increases read latency slightly (the pending list must be scanned linearly during queries). For agent workloads where writes are frequent but reads are not latency-critical to the millisecond, a 16-64MB pending list is a good tradeoff.

### 3.3 Monitoring GIN Health

```sql
-- Check GIN index sizes relative to table sizes
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexname::regclass)) AS index_size,
    pg_size_pretty(pg_relation_size(tablename::regclass)) AS table_size
FROM pg_indexes
WHERE indexname LIKE 'idx_%properties%' OR indexname LIKE 'idx_%claim%' OR indexname LIKE 'idx_%content%'
ORDER BY pg_relation_size(indexname::regclass) DESC;
```

If a GIN index is more than 4x the size of its table, consider whether all the JSONB keys need to be indexed. You can use `jsonb_path_ops` instead of the default `jsonb_ops` operator class to index only containment queries (not key existence), which reduces index size by roughly 2-3x:

```sql
-- Smaller index, but only supports @> queries (not ? or ?| operators)
CREATE INDEX idx_events_properties_path ON events USING gin (properties jsonb_path_ops);
```

### 3.4 When to Remove or Replace GIN Indexes

If agent workloads consistently query specific known keys rather than arbitrary JSONB paths, targeted B-tree indexes on extracted values outperform GIN:

```sql
-- Instead of relying on the full GIN index for TMP lookups:
CREATE INDEX idx_nodes_tmp ON nodes ((properties->>'tmp_normalized'))
    WHERE node_type = 'parcel';

-- Instead of GIN for event type + specific property:
CREATE INDEX idx_events_status ON events ((properties->>'status'))
    WHERE event_type = 'domain_change';
```

These expression indexes are smaller, faster to maintain, and faster to query than a full GIN index — but they only cover the specific access pattern. The strategy is to start with GIN (covers everything) and add targeted expression indexes as dominant query patterns emerge, eventually dropping the GIN index if it's no longer pulling its weight.

---

## 4. Row-Level Security at Scale

RLS is enforced at the PostgreSQL engine level, which makes it highly secure but adds evaluation cost to every row returned. The Rye schema uses a cascading RLS model where edge visibility depends on node visibility, which can compound at scale.

### 4.1 The Cascading Cost

Consider the edge read policy:

```sql
CREATE POLICY edge_read_policy ON edges
    FOR SELECT
    USING (
        EXISTS (SELECT 1 FROM nodes WHERE id = edges.source_id)
        AND EXISTS (SELECT 1 FROM nodes WHERE id = edges.target_id)
    );
```

For each edge row considered, PostgreSQL executes two correlated subqueries against the nodes table, each of which is itself subject to the node RLS policy. If the node RLS policy checks the `access_grants` table, that's a third table involved per endpoint check.

For a query that returns 100 edges, this is 200 node lookups and potentially 200 access_grants checks. At the comfortable scale range, PostgreSQL caches these lookups efficiently (the same node is referenced by many edges, so the second lookup is a cache hit). At the attention range, the evaluation time becomes measurable.

### 4.2 Measuring RLS Overhead

```sql
-- Run the same query with and without RLS to measure the overhead
-- As a superuser (bypasses RLS by default unless FORCE is set):
SET row_security = off;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM edges WHERE source_id = '<uuid>';

SET row_security = on;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM edges WHERE source_id = '<uuid>';
```

Compare the execution times. If the RLS-on query is more than 2x the RLS-off query, the policy evaluation is becoming a significant cost.

### 4.3 Denormalized Access Control

When RLS overhead exceeds 20-30% of query time, denormalize the access check into a pre-computed table:

```sql
-- Pre-computed: which users can see which nodes
CREATE TABLE node_visibility (
    node_id     uuid NOT NULL REFERENCES nodes(id),
    user_id     text NOT NULL,
    PRIMARY KEY (node_id, user_id)
);

CREATE INDEX idx_nv_user ON node_visibility (user_id);

-- Simplified RLS policy — just a join, no subquery
CREATE POLICY node_read_fast ON nodes
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM node_visibility nv
            WHERE nv.node_id = nodes.id
              AND nv.user_id = current_setting('app.current_user_id', true)
        )
    );
```

The `node_visibility` table is refreshed when access grants change (not on every query). For most systems, grants change infrequently compared to data access, so this is a large win. The refresh can be triggered by a notification from the `access_grants` table:

```sql
CREATE FUNCTION refresh_node_visibility() RETURNS trigger AS $$
BEGIN
    -- Rebuild visibility for the affected grantee
    DELETE FROM node_visibility WHERE user_id = COALESCE(NEW.grantee, OLD.grantee);
    
    INSERT INTO node_visibility (node_id, user_id)
    SELECT n.id, ag.grantee
    FROM nodes n
    CROSS JOIN access_grants ag
    WHERE ag.active = true
      AND ag.grantee = COALESCE(NEW.grantee, OLD.grantee)
      AND ag.resource_type = 'node'
      AND (
          ag.scope->>'node_type' = n.node_type
          OR ag.scope->>'node_id' = n.id::text
          OR ag.scope->>'classification' = n.attrs->>'classification'
      );

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_refresh_visibility
    AFTER INSERT OR UPDATE OR DELETE ON access_grants
    FOR EACH ROW EXECUTE FUNCTION refresh_node_visibility();
```

### 4.4 Session-Scoped Temp Tables

An alternative to a persistent visibility table is to compute the user's visible node set once at session start and store it in a temporary table:

```sql
-- At session/transaction start
CREATE TEMP TABLE my_visible_nodes AS
SELECT n.id AS node_id
FROM nodes n
JOIN access_grants ag ON ag.active = true
    AND ag.grantee = current_setting('app.current_user_id', true)
    AND ag.resource_type = 'node'
    AND (
        ag.scope->>'node_type' = n.node_type
        OR ag.scope->>'classification' = n.attrs->>'classification'
    );

CREATE INDEX ON my_visible_nodes (node_id);

-- RLS policy references the temp table
CREATE POLICY node_read_session ON nodes
    FOR SELECT
    USING (
        EXISTS (SELECT 1 FROM my_visible_nodes WHERE node_id = nodes.id)
    );
```

This avoids maintaining a persistent denormalized table but requires the application to create the temp table at the start of each session. It works well with connection poolers that execute a setup script per transaction.

---

## 5. Graph Traversal Performance

Recursive CTEs are PostgreSQL's tool for graph traversal. They work well for shallow traversals but have predictable performance degradation as depth increases.

### 5.1 Traversal Cost Model

For a graph with average out-degree `d` (average number of outbound edges per node), a traversal to depth `n` explores up to `d^n` paths.

| Average Out-Degree | 2 Hops | 3 Hops | 4 Hops | 5 Hops |
|---|---|---|---|---|
| 5 | 25 | 125 | 625 | 3,125 |
| 10 | 100 | 1,000 | 10,000 | 100,000 |
| 20 | 400 | 8,000 | 160,000 | 3,200,000 |
| 50 | 2,500 | 125,000 | 6,250,000 | — |

The cycle prevention check (`NOT target_id = ANY(path)`) adds array scanning cost per row. At 3 hops with degree 10, this is manageable. At 5 hops with degree 20, the intermediate result set overwhelms `work_mem`.

### 5.2 Constraining Traversals

The most effective optimization is reducing the number of paths explored by filtering on edge type, node type, or temporal bounds:

```sql
WITH RECURSIVE graph AS (
    SELECT target_id AS node_id, 1 AS depth, ARRAY[source_id, target_id] AS path
    FROM edges
    WHERE source_id = '<start_uuid>'
      AND archived_at IS NULL
      -- Only traverse specific relationship types
      AND edge_type IN ('owns', 'references', 'targets')
      -- Only currently active relationships
      AND (effective_to IS NULL OR effective_to > now())
    
    UNION ALL
    
    SELECT e.target_id, g.depth + 1, g.path || e.target_id
    FROM graph g
    JOIN edges e ON e.source_id = g.node_id
    WHERE g.depth < 3
      AND NOT e.target_id = ANY(g.path)
      AND e.archived_at IS NULL
      AND e.edge_type IN ('owns', 'references', 'targets')
      AND (e.effective_to IS NULL OR e.effective_to > now())
)
SELECT DISTINCT n.* FROM graph g JOIN nodes n ON n.id = g.node_id;
```

Filtering by 3 edge types instead of all edge types on a graph with 10 total edge types reduces the traversal space by roughly 70%.

### 5.3 Pre-Computed Transitive Closures

For frequently traversed relationship chains (e.g., "all parcels transitively connected to this person through ownership and conveyance"), pre-compute the results as materialized edges:

```sql
-- Materialized view: transitive ownership connections
CREATE MATERIALIZED VIEW transitive_ownership AS
WITH RECURSIVE chain AS (
    SELECT source_id AS origin_id, target_id, 1 AS depth, ARRAY[source_id, target_id] AS path
    FROM edges
    WHERE edge_type IN ('owns', 'conveyed_to') AND archived_at IS NULL
    
    UNION ALL
    
    SELECT c.origin_id, e.target_id, c.depth + 1, c.path || e.target_id
    FROM chain c
    JOIN edges e ON e.source_id = c.target_id
    WHERE c.depth < 5
      AND e.edge_type IN ('owns', 'conveyed_to')
      AND e.archived_at IS NULL
      AND NOT e.target_id = ANY(c.path)
)
SELECT DISTINCT origin_id, target_id, min(depth) AS min_depth
FROM chain
GROUP BY origin_id, target_id;

CREATE INDEX idx_to_origin ON transitive_ownership (origin_id);
CREATE INDEX idx_to_target ON transitive_ownership (target_id);
```

Refresh this on a schedule (e.g., every 15 minutes or after bulk ingestion). Agent queries use the materialized view for fast transitive lookups and fall back to the recursive CTE only when real-time accuracy is needed.

### 5.4 Apache AGE as an Upgrade Path

If graph traversal becomes the dominant workload and recursive CTEs are insufficient, Apache AGE adds native graph query support to PostgreSQL:

```sql
-- Apache AGE: Cypher queries on the same PostgreSQL instance
SELECT * FROM cypher('rye_graph', $$
    MATCH (p:person)-[:owns]->(i:interest)-[:in]->(parcel:parcel)
    WHERE parcel.tmp_normalized = '45-2-31'
    RETURN p.label, i.fraction
$$) AS (owner_name agtype, fraction agtype);
```

AGE stores graph data in its own optimized format while coexisting with relational tables in the same database. This preserves the single-database advantage while providing native graph traversal performance. The migration path is to create an AGE graph that mirrors the Rye nodes and edges tables, either through dual-write or periodic sync.

---

## 6. Agent-Specific Considerations

When LLM agents are the primary consumers of the data model, the performance bottleneck shifts from database throughput to context window management.

### 6.1 The Context Window Problem

An agent querying "tell me everything about TMP 45-2-31" might receive:

- 1 node (the parcel)
- 47 edges (ownership, references, adjacency, targets)
- 23 active assertions (ownership, sentiment, title opinions, valuations)
- 312 events (emails, calls, title runs, status changes)
- 15 artifacts (extracted table rows, document references)

Serialized as JSON, this could be 50-100KB of text — consuming a significant portion of the agent's context window without the agent being able to usefully process all of it.

### 6.2 Agent-Facing Query Functions

Build query functions that return summarized, ranked, and paginated results tailored for agent consumption:

```sql
-- Agent-optimized: get the most relevant context for a node
CREATE FUNCTION agent_node_summary(p_node_id uuid, p_max_items int DEFAULT 10)
RETURNS jsonb AS $$
SELECT jsonb_build_object(
    'node', (SELECT row_to_json(n) FROM nodes n WHERE n.id = p_node_id),
    
    'top_relationships', (
        SELECT json_agg(r) FROM (
            SELECT e.edge_type, e.properties, e.weight, nt.label AS target_label, nt.node_type AS target_type
            FROM edges e
            JOIN nodes nt ON nt.id = e.target_id
            WHERE e.source_id = p_node_id AND e.archived_at IS NULL
            ORDER BY e.weight DESC NULLS LAST, e.created_at DESC
            LIMIT p_max_items
        ) r
    ),
    
    'current_facts', (
        SELECT json_agg(a) FROM (
            SELECT a.assertion_type, a.claim, a.confidence, a.asserted_at
            FROM current_assertions a
            WHERE a.subject_node_id = p_node_id
            ORDER BY a.confidence DESC NULLS LAST, a.asserted_at DESC
            LIMIT p_max_items
        ) a
    ),
    
    'recent_activity', (
        SELECT json_agg(ev) FROM (
            SELECT e.event_type, e.summary, e.occurred_at, ep.role
            FROM events e
            JOIN event_participants ep ON ep.event_id = e.id
            WHERE ep.node_id = p_node_id
            ORDER BY e.occurred_at DESC
            LIMIT p_max_items
        ) ev
    )
);
$$ LANGUAGE sql STABLE;
```

This returns a compact summary that fits comfortably in a context window while covering the most important information. The agent can then ask follow-up questions to drill into specific areas.

### 6.3 Ranked Retrieval

Use the `weight` column on edges and `confidence` on assertions to prioritize what the agent sees:

- **Edge weight:** Set higher weights for primary relationships (direct ownership) and lower weights for secondary ones (mentioned in a footnote). Default is 1.0.
- **Assertion confidence:** Set based on provenance. A fact from a recorded deed gets 0.95. A fact from a phone conversation gets 0.6. A fact from an automated extraction gets the extraction model's confidence score.
- **Event recency:** For activity timelines, recency is the primary ranking factor. Agents rarely need events from two years ago as top-level context.

### 6.4 Write Safety for Agents

The append-only model provides intrinsic safety for agent writes:

- **Agents cannot corrupt existing data through direct DML.** Direct `UPDATE`/`DELETE` on assertions are blocked by policy. Supersession updates are function-scoped.
- **Every agent write has provenance.** The `actor_system` field on events and the `source_event_id` on assertions trace every piece of data back to the agent and the interaction that produced it.
- **Contradictions are explicit.** When an agent writes a new assertion that contradicts an existing one, the supersession is visible. A human or another agent can review supersession chains to validate agent decisions.

Enforce this at the database level:

```sql
-- Assertion inserts remain role-gated by assertion type rules
CREATE POLICY assertion_insert_policy ON assertions
    FOR INSERT
    WITH CHECK (
        CASE assertion_type
            WHEN 'financial_terms' THEN current_setting('app.current_role', true) IN ('deal_manager', 'admin')
            WHEN 'compensation'    THEN current_setting('app.current_role', true) IN ('hr_admin', 'admin')
            ELSE true
        END
    );

-- Function-scoped supersession update path
CREATE POLICY assertion_update_policy ON assertions
    FOR UPDATE
    USING (
        current_setting('app.write_path', true) = 'supersede_assertion'
        AND id::text = current_setting('app.supersede_assertion_id', true)
    );

-- No direct assertion deletes
CREATE POLICY assertion_no_delete ON assertions
    FOR DELETE
    USING (false);
```

### 6.5 Agent Query Logging

Every agent interaction should produce an event for auditability:

```sql
-- Log every agent query as an event
CREATE FUNCTION log_agent_query(
    p_agent_id text,
    p_query_text text,
    p_result_summary text,
    p_nodes_referenced uuid[]
) RETURNS uuid AS $$
DECLARE
    v_event_id uuid;
BEGIN
    INSERT INTO events (event_type, occurred_at, summary, properties, actor_system)
    VALUES (
        'agent_query',
        now(),
        p_result_summary,
        jsonb_build_object('query', p_query_text, 'agent_id', p_agent_id),
        'agent:' || p_agent_id
    )
    RETURNING id INTO v_event_id;

    -- Link to referenced nodes
    INSERT INTO event_participants (event_id, node_id, role)
    SELECT v_event_id, unnest(p_nodes_referenced), 'queried';

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;
```

This creates a complete audit trail of what agents asked, what they were shown, and which nodes were involved. It also enables analysis of agent query patterns to inform index and view optimization.

---

## 7. Write Path Optimization

### 7.1 Bulk Ingestion

During bulk imports (initial data load, batch ETL from a CRM, document extraction pipeline), individual inserts with GIN index maintenance become the bottleneck. Use these techniques:

**Drop and rebuild indexes:**

```sql
-- Before bulk load
DROP INDEX idx_events_properties;
DROP INDEX idx_assertions_claim;

-- Perform bulk insert using COPY
COPY events (id, event_type, occurred_at, summary, properties, actor_system)
FROM '/path/to/events.csv' WITH (FORMAT csv);

-- Rebuild indexes (happens once, in parallel on PG 13+)
CREATE INDEX CONCURRENTLY idx_events_properties ON events USING gin (properties);
CREATE INDEX CONCURRENTLY idx_assertions_claim ON assertions USING gin (claim);
```

**Use COPY instead of INSERT:**

`COPY` is 5-10x faster than individual `INSERT` statements for bulk loads because it bypasses per-row overhead. For programmatic use, most PostgreSQL client libraries support a COPY protocol.

**Batch in transactions:**

```sql
-- Instead of autocommit per row, batch 1000-5000 rows per transaction
BEGIN;
INSERT INTO nodes ... ;  -- row 1
INSERT INTO nodes ... ;  -- row 2
-- ... rows 3-999 ...
INSERT INTO nodes ... ;  -- row 1000
COMMIT;
```

This reduces WAL (Write-Ahead Log) overhead significantly.

### 7.2 CDC Trigger Performance

The `capture_domain_change` trigger adds overhead to every INSERT, UPDATE, and DELETE on domain tables. For tables with high write volume, this overhead can become noticeable.

**Measure the overhead:**

```sql
-- Time a batch of updates with and without the trigger
ALTER TABLE crm.contacts DISABLE TRIGGER cdc_contacts;
-- Run benchmark
ALTER TABLE crm.contacts ENABLE TRIGGER cdc_contacts;
-- Run benchmark again, compare
```

**Mitigation strategies:**

- **Async CDC:** Instead of a synchronous trigger, write to a lightweight staging table and have a background worker process it into events. This decouples domain table write latency from graph ingestion.
- **Debounced CDC:** If a domain record is updated multiple times in rapid succession (e.g., a CRM bulk update), batch the changes into a single event rather than one event per update.
- **Selective CDC:** Only capture changes to columns that matter for the graph. Ignore purely operational columns (e.g., `last_login_at`) that don't carry domain meaning.

```sql
-- Selective CDC: only fire when meaningful columns change
CREATE TRIGGER cdc_contacts_selective
    AFTER UPDATE ON crm.contacts
    FOR EACH ROW
    WHEN (
        OLD.first_name IS DISTINCT FROM NEW.first_name
        OR OLD.last_name IS DISTINCT FROM NEW.last_name
        OR OLD.email IS DISTINCT FROM NEW.email
        OR OLD.phone IS DISTINCT FROM NEW.phone
        OR OLD.status IS DISTINCT FROM NEW.status
    )
    EXECUTE FUNCTION capture_domain_change();
```

---

## 8. Partitioning Strategy

Events and assertions are append-only and time-ordered. As they accumulate, partitioning by time range keeps queries fast and enables efficient archival.

### 8.1 Events Partitioning

```sql
-- Convert events to a partitioned table
CREATE TABLE events_partitioned (
    LIKE events INCLUDING ALL
) PARTITION BY RANGE (occurred_at);

-- Create partitions by quarter
CREATE TABLE events_2024_q1 PARTITION OF events_partitioned
    FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');
CREATE TABLE events_2024_q2 PARTITION OF events_partitioned
    FOR VALUES FROM ('2024-04-01') TO ('2024-07-01');
CREATE TABLE events_2024_q3 PARTITION OF events_partitioned
    FOR VALUES FROM ('2024-07-01') TO ('2024-10-01');
CREATE TABLE events_2024_q4 PARTITION OF events_partitioned
    FOR VALUES FROM ('2024-10-01') TO ('2025-01-01');

-- Auto-create future partitions with pg_partman or a cron job
```

**Partition granularity guidance:**

| Event volume | Suggested partition size |
|---|---|
| < 10K events/day | Yearly |
| 10K-100K events/day | Quarterly |
| 100K-1M events/day | Monthly |
| > 1M events/day | Weekly |

### 8.2 Assertions Partitioning

Assertions are trickier because the most common query pattern (`current_assertions WHERE superseded_at IS NULL`) crosses all partitions. Two approaches:

**Option A: Partition by `asserted_at`.** Matches the append-only write pattern. Current assertions are mostly in recent partitions but not exclusively.

**Option B: Partition by status.** Create two partitions: `active` (superseded_at IS NULL) and `historical` (superseded_at IS NOT NULL). The active partition stays small and fast. When an assertion is superseded, it moves to the historical partition.

```sql
CREATE TABLE assertions_partitioned (
    LIKE assertions INCLUDING ALL
) PARTITION BY LIST ((superseded_at IS NULL));

CREATE TABLE assertions_active PARTITION OF assertions_partitioned
    FOR VALUES IN (true);
CREATE TABLE assertions_historical PARTITION OF assertions_partitioned
    FOR VALUES IN (false);
```

Option B is conceptually clean but PostgreSQL doesn't natively move rows between partitions on UPDATE. You'd need a trigger to DELETE from active and INSERT into historical on supersession. Option A is simpler operationally.

### 8.3 Archival

Old partitions can be detached and archived without affecting the live system:

```sql
-- Detach a partition (instant, no data movement)
ALTER TABLE events_partitioned DETACH PARTITION events_2023_q1;

-- Archive it (dump to compressed file)
pg_dump -t events_2023_q1 --compress=9 -f events_2023_q1.dump

-- Or move to a separate tablespace on cheaper storage
ALTER TABLE events_2023_q1 SET TABLESPACE archive_storage;
```

---

## 9. Materialized Views and Denormalization

### 9.1 When to Materialize

Create a materialized view when:

- A query joins 3+ tables and is executed frequently (>100 times/day)
- The underlying data changes much less frequently than it's read
- Agent response latency requirements are tighter than the raw query can deliver

### 9.2 Common Materialized Views

**Flattened parcels (frequently queried node type):**

```sql
CREATE MATERIALIZED VIEW parcels_flat AS
SELECT
    n.id AS node_id,
    n.properties->>'tmp_normalized' AS tmp,
    n.properties->>'county' AS county,
    n.properties->>'state' AS state,
    (n.properties->>'acreage')::numeric AS acreage,
    n.label,
    n.created_at
FROM nodes n
WHERE n.node_type = 'parcel' AND n.archived_at IS NULL;

CREATE UNIQUE INDEX ON parcels_flat (node_id);
CREATE INDEX ON parcels_flat (tmp);
```

**Ownership summary (common agent query):**

```sql
CREATE MATERIALIZED VIEW ownership_summary AS
SELECT
    p.id AS parcel_node_id,
    p.properties->>'tmp_normalized' AS tmp,
    o.id AS owner_node_id,
    o.label AS owner_name,
    o.node_type AS owner_type,
    e.properties->>'fraction' AS fraction,
    (e.properties->>'decimal')::numeric AS decimal_interest,
    ca.claim->>'stance' AS seller_stance,
    ca.confidence AS stance_confidence
FROM nodes p
JOIN edges e ON e.target_id = p.id AND e.edge_type = 'owns' AND e.archived_at IS NULL
JOIN nodes o ON o.id = e.source_id AND o.archived_at IS NULL
LEFT JOIN current_assertions ca ON ca.subject_node_id = o.id AND ca.assertion_type = 'sentiment'
WHERE p.node_type = 'parcel' AND p.archived_at IS NULL;

CREATE INDEX ON ownership_summary (tmp);
CREATE INDEX ON ownership_summary (owner_node_id);
```

### 9.3 Refresh Strategy

```sql
-- Concurrent refresh (allows reads during rebuild, requires unique index)
REFRESH MATERIALIZED VIEW CONCURRENTLY parcels_flat;
REFRESH MATERIALIZED VIEW CONCURRENTLY ownership_summary;
```

**Refresh triggers:**

| Trigger | Frequency |
|---|---|
| After bulk import/extraction | Immediately |
| Background schedule | Every 5-15 minutes |
| After assertion supersession | If the materialized view includes assertion data |
| On agent cache miss | Agent queries the mat view first; if stale, triggers refresh and retries |

---

## 10. Connection and Concurrency Management

### 10.1 Connection Pooling

PostgreSQL creates a new process for each connection. At 200+ connections, the overhead of process context switching degrades performance. Use a connection pooler.

**PgBouncer** in transaction mode is the standard:

```ini
[databases]
rye = host=localhost dbname=rye

[pgbouncer]
pool_mode = transaction
default_pool_size = 20
max_client_conn = 300
```

The session variable pattern for RLS works with transaction mode — set the variables at the start of each transaction:

```sql
BEGIN;
SET LOCAL "app.current_user_id" = 'user-456';
SET LOCAL "app.current_teams" = 'appalachia_team,legal_team';
SET LOCAL "app.current_role" = 'land_manager';
-- ... queries ...
COMMIT;
```

`SET LOCAL` scopes the variables to the current transaction and automatically resets them, which is safe for connection reuse.

### 10.2 Agent Connection Management

Agents should use dedicated connection pool slots to prevent agent workloads from starving human user queries:

```ini
# Separate pools for agents and humans
[databases]
rye_agents = host=localhost dbname=rye pool_size=10
rye_users = host=localhost dbname=rye pool_size=20
```

### 10.3 Read Replicas

At the attention range, add a streaming replica for read-heavy agent workloads:

```
                    ┌──────────────────┐
  Agents (reads) ──>│  Read Replica    │
                    └──────────────────┘
                              ↑ streaming replication
                    ┌──────────────────┐
  Agents (writes) ─>│  Primary         │<── Human users
  Human writes ────>│                  │
                    └──────────────────┘
```

Agent reads tolerate a few seconds of replication lag. Writes always go to the primary. This doubles read throughput with minimal operational complexity.

---

## 11. Monitoring and Instrumentation

### 11.1 Essential Metrics

Track these from day one:

```sql
-- Table sizes (run weekly, track trend)
SELECT
    relname AS table_name,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    pg_size_pretty(pg_relation_size(relid)) AS data_size,
    pg_size_pretty(pg_total_relation_size(relid) - pg_relation_size(relid)) AS index_size,
    n_live_tup AS row_count
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(relid) DESC;

-- Index usage (which indexes are actually used?)
SELECT
    schemaname, tablename, indexname,
    idx_scan AS times_used,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
ORDER BY idx_scan ASC;  -- unused indexes at top — candidates for removal

-- Slow queries (requires pg_stat_statements extension)
SELECT
    query,
    calls,
    mean_exec_time AS avg_ms,
    max_exec_time AS max_ms,
    rows / calls AS avg_rows
FROM pg_stat_statements
WHERE mean_exec_time > 100  -- queries averaging over 100ms
ORDER BY mean_exec_time DESC
LIMIT 20;
```

### 11.2 Rye-Specific Metrics

```sql
-- Active vs historical assertions ratio
SELECT
    count(*) FILTER (WHERE superseded_at IS NULL) AS active,
    count(*) FILTER (WHERE superseded_at IS NOT NULL) AS superseded,
    round(
        count(*) FILTER (WHERE superseded_at IS NULL)::numeric /
        NULLIF(count(*), 0) * 100, 1
    ) AS active_pct
FROM assertions;

-- Events per day (growth rate)
SELECT
    date_trunc('day', occurred_at)::date AS day,
    count(*) AS events,
    count(DISTINCT (properties->>'table')) AS tables_changed
FROM events
WHERE event_type = 'domain_change'
GROUP BY 1
ORDER BY 1 DESC
LIMIT 30;

-- Agent query volume and latency (if using agent query logging)
SELECT
    date_trunc('hour', occurred_at) AS hour,
    count(*) AS agent_queries,
    avg((properties->>'execution_ms')::numeric) AS avg_latency_ms
FROM events
WHERE event_type = 'agent_query'
GROUP BY 1
ORDER BY 1 DESC
LIMIT 48;

-- Node type distribution
SELECT node_type, count(*), pg_size_pretty(sum(pg_column_size(properties))) AS properties_size
FROM nodes
WHERE archived_at IS NULL
GROUP BY node_type
ORDER BY count(*) DESC;

-- Edge type distribution and average degree
SELECT
    edge_type,
    count(*) AS edge_count,
    count(DISTINCT source_id) AS unique_sources,
    round(count(*)::numeric / NULLIF(count(DISTINCT source_id), 0), 1) AS avg_out_degree
FROM edges
WHERE archived_at IS NULL
GROUP BY edge_type
ORDER BY count(*) DESC;
```

### 11.3 Alerting Thresholds

| Metric | Warning | Critical |
|---|---|---|
| Query p99 latency | > 500ms | > 2s |
| GIN index size / table size ratio | > 4x | > 8x |
| Active connections | > 70% of pool | > 90% of pool |
| Events table size | > 10 GB unpartitioned | > 50 GB unpartitioned |
| Replication lag (if using replicas) | > 10s | > 60s |
| RLS overhead (% of query time) | > 20% | > 40% |
| Unused indexes | Any index with 0 scans for 30 days | — |

---

## 12. Upgrade Paths at Each Threshold

### 12.1 Comfortable → Attention Range

| Action | Effort | Impact |
|---|---|---|
| Partition events by quarter | Low | Keeps event queries fast as history grows |
| Add expression indexes for dominant query patterns | Low | 2-5x faster than GIN for specific lookups |
| Switch GIN to `jsonb_path_ops` where only `@>` is needed | Low | 2-3x smaller GIN indexes |
| Create agent-facing summary functions | Medium | Reduces context window waste, improves agent response quality |
| Increase `gin_pending_list_limit` | Low | Reduces write latency on high-ingest tables |
| Add materialized views for common joins | Medium | Eliminates repeated expensive joins |

### 12.2 Attention → Redesign Range

| Action | Effort | Impact |
|---|---|---|
| Denormalize RLS into node_visibility table | Medium | Eliminates cascading subquery cost |
| Add read replica for agent queries | Medium | Doubles read throughput |
| Pre-compute transitive closures as materialized views | Medium | Eliminates deep recursive CTEs |
| Partition assertions by status (active/historical) | Medium | Keeps active assertion set fast |
| Implement async CDC (staging table + worker) | High | Decouples domain table write performance from graph ingestion |
| Evaluate Apache AGE for graph traversal | High | Native graph query performance without leaving PostgreSQL |

### 12.3 Beyond Redesign Range

| Action | Effort | Impact |
|---|---|---|
| Event streaming (Kafka/NATS) for write ingestion | High | Handles > 5K events/sec with backpressure |
| Dedicated graph engine for traversal (AGE, Neo4j, or Neptune) | High | Handles 5+ hop traversals at scale |
| Time-series store for high-volume event data | High | Optimized storage and querying for time-ordered data |
| Sharding nodes/edges by domain partition | Very High | Horizontal scale for > 100M nodes |

---

## 13. What Not to Worry About Yet

For a system in early deployment with LLM agents in the mineral rights domain (or similar B2B operational context), the following are not yet concerns:

- **Sharding.** PostgreSQL on a single machine with proper indexing handles tens of millions of rows. You'll know you need sharding years before it becomes urgent.
- **JSONB storage efficiency.** JSONB is larger than normalized columns, but storage is cheap. The flexibility benefit far outweighs the storage cost until you're at hundreds of millions of rows.
- **Index bloat from append-only tables.** PostgreSQL's autovacuum handles this. Monitor dead tuple counts and adjust vacuum settings if needed, but don't preoptimize.
- **Recursive CTE depth limits.** If agents are constrained to 2-3 hop traversals by their query functions, this never becomes a problem.
- **Write contention on the events table.** Append-only tables have minimal write contention by nature — no row locks since nothing is updated. Multiple agents can insert concurrently without blocking each other.

The most productive early investment is **agent query design** — ensuring agents ask focused questions, receive compact answers, and log their interactions for analysis. The database will handle whatever you throw at it within the comfortable range. The agent's effective use of the data model is where quality comes from.
