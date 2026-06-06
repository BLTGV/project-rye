import type postgres from "postgres";
import { withAdminCte } from "./db";

type Sql = ReturnType<typeof postgres>;

export interface CatalogResult {
  totals: Record<string, number>;
  node_types: Record<string, number>;
  edge_types: Record<string, number>;
  event_types: Record<string, number>;
  assertion_types: Record<string, number>;
  tracked_tables: string[];
}

export async function fetchCatalog(sql: Sql): Promise<CatalogResult> {
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT rye.rye_catalog() AS c FROM cfg`
  );
  return rows[0]?.c as CatalogResult;
}

export interface DashboardKpis {
  nodes_total: number;
  edges_total: number;
  events_total: number;
  assertions_total: number;
  active_assertions: number;
  disputed_subjects: number;
  unique_clients_90d: number;
  quote_value_90d: number;
  quote_count_90d: number;
}

export async function fetchDashboardKpis(sql: Sql): Promise<DashboardKpis> {
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT
         (SELECT COUNT(*) FROM rye.nodes)::int AS nodes_total,
         (SELECT COUNT(*) FROM rye.edges)::int AS edges_total,
         (SELECT COUNT(*) FROM rye.events)::int AS events_total,
         (SELECT COUNT(*) FROM rye.assertions)::int AS assertions_total,
         (SELECT COUNT(*) FROM rye.assertions WHERE superseded_at IS NULL)::int AS active_assertions,
         (SELECT COUNT(*) FROM rye.active_disputes)::int AS disputed_subjects,
         (SELECT COUNT(DISTINCT properties->>'client') FROM rye.events
          WHERE event_type='quote_created' AND occurred_at > now() - interval '90 days')::int AS unique_clients_90d,
         COALESCE((SELECT SUM((properties->>'total_price')::numeric) FROM rye.events
           WHERE event_type='quote_created' AND occurred_at > now() - interval '90 days'),0)::float AS quote_value_90d,
         (SELECT COUNT(*) FROM rye.events
           WHERE event_type='quote_created' AND occurred_at > now() - interval '90 days')::int AS quote_count_90d
       FROM cfg`
  );
  return rows[0] as unknown as DashboardKpis;
}

export interface QuoteBucket {
  bucket: string;
  count: number;
  value: number;
}

export async function fetchQuoteTimeline(sql: Sql, days = 90): Promise<QuoteBucket[]> {
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT to_char(date_trunc('day', occurred_at), 'YYYY-MM-DD') AS bucket,
              COUNT(*)::int AS count,
              COALESCE(SUM((properties->>'total_price')::numeric),0)::float AS value
       FROM rye.events e, cfg
       WHERE e.event_type='quote_created'
         AND e.occurred_at > now() - ($1 || ' days')::interval
       GROUP BY 1 ORDER BY 1`,
    [String(days)]
  );
  return rows as unknown as QuoteBucket[];
}

export interface TopClient {
  client: string;
  quote_count: number;
  total_value: number;
  last_quote_at: string;
}

export async function fetchTopClients(sql: Sql, limit = 12): Promise<TopClient[]> {
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT properties->>'client' AS client,
              COUNT(*)::int AS quote_count,
              COALESCE(SUM((properties->>'total_price')::numeric),0)::float AS total_value,
              MAX(occurred_at) AS last_quote_at
       FROM rye.events, cfg
       WHERE event_type='quote_created' AND properties ? 'client'
       GROUP BY 1 ORDER BY total_value DESC NULLS LAST LIMIT $1`,
    [limit]
  );
  return rows as unknown as TopClient[];
}

export interface NodeRow {
  id: string;
  node_type: string;
  label: string;
  external_id: string | null;
  external_source: string | null;
  created_at: string;
  archived_at: string | null;
  properties: Record<string, unknown>;
  attrs: Record<string, unknown>;
}

export async function searchNodes(
  sql: Sql,
  opts: { q?: string; type?: string; limit?: number; offset?: number }
): Promise<{ rows: NodeRow[]; total: number }> {
  const limit = Math.min(opts.limit ?? 50, 200);
  const offset = opts.offset ?? 0;
  const q = (opts.q ?? "").trim();
  const type = opts.type ?? null;

  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT n.*, COUNT(*) OVER() AS _total
       FROM rye.nodes n, cfg
       WHERE n.archived_at IS NULL
         AND ($1::text IS NULL OR n.node_type = $1)
         AND ($2::text = '' OR n.label ILIKE '%' || $2 || '%'
              OR n.properties::text ILIKE '%' || $2 || '%')
       ORDER BY similarity(n.label, $2) DESC NULLS LAST, n.created_at DESC
       LIMIT $3 OFFSET $4`,
    [type, q, limit, offset]
  );
  const total = rows[0]?._total ? Number(rows[0]._total) : 0;
  // strip the window helper
  const cleaned = rows.map((r) => {
    const { _total, ...rest } = r as Record<string, unknown>;
    return rest as unknown as NodeRow;
  });
  return { rows: cleaned, total };
}

export interface GraphNode {
  id: string;
  node_type: string;
  label: string;
}
export interface GraphEdge {
  id: string;
  source: string;
  target: string;
  edge_type: string;
}

export async function fetchNeighborhood(
  sql: Sql,
  nodeId: string,
  hops: number = 1
): Promise<{ nodes: GraphNode[]; edges: GraphEdge[] }> {
  const maxHops = Math.max(1, Math.min(hops, 3));
  // Single WITH RECURSIVE so the rye admin CTE and the walk CTE share one
  // header. Two separate WITH clauses are a syntax error in Postgres.
  const rows = await sql.unsafe(
    `WITH RECURSIVE cfg AS (
       SELECT set_config('app.current_role','admin',false)
     ),
       focus AS (
         SELECT id::text AS node_id, node_type FROM rye.nodes, cfg WHERE id = $1::uuid
       ),
       walk AS (
         SELECT node_id, 0 AS depth FROM focus
         UNION
         SELECT other.id::text,
                w.depth + 1
         FROM walk w
         JOIN rye.edges e ON (e.source_id::text = w.node_id OR e.target_id::text = w.node_id)
         JOIN rye.nodes other ON other.id = CASE
           WHEN e.source_id::text = w.node_id THEN e.target_id
           ELSE e.source_id
         END
         CROSS JOIN focus f
         WHERE w.depth < $2 AND e.archived_at IS NULL
           AND NOT (
             f.node_type IN ('source_account', 'source_container')
             AND other.node_type = 'source_item'
           )
       ),
     reached AS (SELECT DISTINCT node_id FROM walk),
     node_set AS (
       SELECT n.id::text AS id, n.node_type, n.label
       FROM rye.nodes n JOIN reached r ON r.node_id = n.id::text
     ),
     edge_set AS (
       SELECT e.id::text AS id,
              e.source_id::text AS source,
              e.target_id::text AS target,
              e.edge_type,
              e.properties
         FROM rye.edges e
         JOIN rye.nodes source_node ON source_node.id = e.source_id
         JOIN rye.nodes target_node ON target_node.id = e.target_id
         CROSS JOIN focus f
         WHERE e.source_id::text IN (SELECT node_id FROM reached)
           AND e.target_id::text IN (SELECT node_id FROM reached)
           AND e.archived_at IS NULL
           AND NOT (
             f.node_type IN ('source_account', 'source_container')
             AND (source_node.node_type = 'source_item' OR target_node.node_type = 'source_item')
           )
       )
     SELECT json_build_object(
       'nodes', COALESCE((SELECT json_agg(n) FROM node_set n), '[]'::json),
       'edges', COALESCE((SELECT json_agg(e) FROM edge_set e), '[]'::json)
     ) AS payload`,
    [nodeId, maxHops]
  );
  return rows[0]?.payload as { nodes: GraphNode[]; edges: GraphEdge[] };
}

export async function fetchNodeDetail(sql: Sql, nodeId: string) {
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT json_build_object(
         'node', (SELECT row_to_json(n) FROM (
            SELECT id, node_type, label, properties, attrs, external_id, external_source,
                   created_at, archived_at FROM rye.nodes WHERE id = $1::uuid) n),
         'assertions', COALESCE((SELECT json_agg(a ORDER BY a.created_at DESC) FROM (
            SELECT id, assertion_type, assertion_key, claim, confidence,
                   effective_at, effective_to, source_event_id, attrs,
                   created_at, superseded_at, superseded_by
            FROM rye.assertions WHERE subject_node_id = $1::uuid) a), '[]'::json),
         'events', COALESCE((SELECT json_agg(ev ORDER BY ev.occurred_at DESC) FROM (
            SELECT e.id, e.event_type, e.summary, e.occurred_at, e.properties, e.actor_system, ep.role
            FROM rye.events e JOIN rye.event_participants ep ON ep.event_id = e.id
            WHERE ep.node_id = $1::uuid LIMIT 50) ev), '[]'::json),
         'artifacts', COALESCE((SELECT json_agg(ar ORDER BY ar.created_at DESC) FROM (
            SELECT id::text AS id,
                   artifact_type,
                   source_event_id::text AS source_event_id,
                   source_node_id::text AS source_node_id,
                   content,
                   location,
                   COALESCE(ARRAY(SELECT x::text FROM unnest(related_node_ids) AS x), ARRAY[]::text[]) AS related_node_ids,
                   attrs,
                   created_at
            FROM rye.artifacts
            WHERE source_node_id = $1::uuid
               OR $1::uuid = ANY(COALESCE(related_node_ids, ARRAY[]::uuid[]))
            ORDER BY created_at DESC
            LIMIT 12) ar), '[]'::json),
         'edges_out', COALESCE((SELECT json_agg(eo) FROM (
            SELECT e.id, e.edge_type, e.target_id, e.properties, n.label, n.node_type
            FROM rye.edges e JOIN rye.nodes n ON n.id = e.target_id
            WHERE e.source_id = $1::uuid AND e.archived_at IS NULL) eo), '[]'::json),
         'edges_in', COALESCE((SELECT json_agg(ei) FROM (
            SELECT e.id, e.edge_type, e.source_id, e.properties, n.label, n.node_type
            FROM rye.edges e JOIN rye.nodes n ON n.id = e.source_id
            WHERE e.target_id = $1::uuid AND e.archived_at IS NULL) ei), '[]'::json)
       ) AS payload
       FROM cfg`,
    [nodeId]
  );
  const payload = rows[0]?.payload as Record<string, unknown>;
  const node = payload?.node as { node_type?: string } | undefined;
  if (node?.node_type === "source_account" || node?.node_type === "source_container") {
    payload.source_summary = await fetchSourceSummary(sql, nodeId);
  }
  if (node?.node_type === "review_context") {
    payload.context_scope = await fetchReviewContextScope(sql, nodeId);
  }
  payload.provenance_summary = await fetchNodeProvenanceSummary(sql, nodeId);
  return payload;
}

async function fetchNodeProvenanceSummary(sql: Sql, nodeId: string) {
  const rows = await sql.unsafe(
    withAdminCte() +
      `, assertion_events AS (
         SELECT DISTINCT a.source_event_id
         FROM rye.assertions a
         WHERE a.subject_node_id = $1::uuid
           AND a.source_event_id IS NOT NULL
       ),
       event_rows AS (
         SELECT e.id,
                e.event_type,
                e.summary,
                e.occurred_at,
                e.actor_system,
                e.properties
         FROM rye.events e
         JOIN assertion_events ae ON ae.source_event_id = e.id
         ORDER BY e.occurred_at DESC NULLS LAST, e.id
         LIMIT 8
       ),
       event_payload AS (
         SELECT er.id::text AS id,
                er.event_type,
                er.summary,
                er.occurred_at,
                er.actor_system,
                er.properties,
                COALESCE((
                  SELECT json_agg(json_build_object(
                    'id', n.id::text,
                    'label', n.label,
                    'node_type', n.node_type,
                    'role', ep.role
                  ) ORDER BY n.label)
                  FROM rye.event_participants ep
                  JOIN rye.nodes n ON n.id = ep.node_id
                  WHERE ep.event_id = er.id
                    AND ep.role = 'source_item'
                ), '[]'::json) AS source_items,
                COALESCE((
                  SELECT json_agg(json_build_object(
                    'id', n.id::text,
                    'label', n.label,
                    'node_type', n.node_type,
                    'role', ep.role
                  ) ORDER BY n.label)
                  FROM rye.event_participants ep
                  JOIN rye.nodes n ON n.id = ep.node_id
                  WHERE ep.event_id = er.id
                    AND ep.role = 'review_context'
                ), '[]'::json) AS review_contexts,
                COALESCE((
                  SELECT json_agg(json_build_object(
                    'id', n.id::text,
                    'label', n.label,
                    'node_type', n.node_type,
                    'role', ep.role
                  ) ORDER BY ep.role, n.label)
                  FROM rye.event_participants ep
                  JOIN rye.nodes n ON n.id = ep.node_id
                  WHERE ep.event_id = er.id
                    AND ep.role NOT IN ('source_item', 'review_context')
                ), '[]'::json) AS participants
         FROM event_rows er
       )
       SELECT json_build_object(
         'status', CASE
           WHEN (SELECT COUNT(*) FROM assertion_events) = 0 THEN 'none'
           ELSE 'derived_from_assertion_sources'
         END,
         'source_events_count', (SELECT COUNT(*)::int FROM assertion_events),
         'source_events', COALESCE((SELECT json_agg(ep ORDER BY ep.occurred_at DESC NULLS LAST, ep.id) FROM event_payload ep), '[]'::json)
       ) AS provenance
       FROM cfg`,
    [nodeId]
  );
  return rows[0]?.provenance;
}

export async function fetchReviewContextScope(sql: Sql, nodeId: string) {
  const rows = await sql.unsafe(
    withAdminCte() +
      `, context_items AS (
         SELECT si.id AS source_item_id
         FROM rye.edges reviewed
         JOIN rye.nodes si ON si.id = reviewed.source_id
         WHERE reviewed.target_id = $1::uuid
           AND reviewed.edge_type = 'reviewed_under'
           AND reviewed.archived_at IS NULL
           AND si.node_type = 'source_item'
       ),
       container_item_links AS (
         SELECT c.id, c.label, ci.source_item_id
         FROM context_items ci
         JOIN rye.edges contains_item ON contains_item.target_id = ci.source_item_id
           AND contains_item.archived_at IS NULL
         JOIN rye.nodes c ON c.id = contains_item.source_id
           AND c.node_type = 'source_container'
       ),
       container_rollup AS (
         SELECT id::text AS id, label, COUNT(DISTINCT source_item_id)::int AS item_count
         FROM container_item_links
         GROUP BY id, label
         ORDER BY item_count DESC, label
       ),
       account_item_links AS (
         SELECT a.id, a.label, cil.source_item_id
         FROM container_item_links cil
         JOIN rye.edges account_contains_container ON account_contains_container.target_id = cil.id
           AND account_contains_container.archived_at IS NULL
         JOIN rye.nodes a ON a.id = account_contains_container.source_id
           AND a.node_type = 'source_account'
         UNION
         SELECT a.id, a.label, ci.source_item_id
         FROM context_items ci
         JOIN rye.edges account_contains_item ON account_contains_item.target_id = ci.source_item_id
           AND account_contains_item.archived_at IS NULL
         JOIN rye.nodes a ON a.id = account_contains_item.source_id
           AND a.node_type = 'source_account'
       ),
       account_rollup AS (
         SELECT id::text AS id, label, COUNT(DISTINCT source_item_id)::int AS item_count
         FROM account_item_links
         GROUP BY id, label
         ORDER BY item_count DESC, label
       )
       SELECT json_build_object(
         'status', CASE
           WHEN (SELECT COUNT(*) FROM context_items) = 0 THEN 'no_routed_source_items'
           WHEN (SELECT COUNT(*) FROM container_rollup) = 0
             AND (SELECT COUNT(*) FROM account_rollup) = 0 THEN 'derived_without_source_container'
           ELSE 'derived_from_routed_source_items'
         END,
         'source_items_count', (SELECT COUNT(*)::int FROM context_items),
         'source_containers', COALESCE((SELECT json_agg(c) FROM container_rollup c), '[]'::json),
         'source_accounts', COALESCE((SELECT json_agg(a) FROM account_rollup a), '[]'::json)
       ) AS scope
       FROM cfg`,
    [nodeId]
  );
  return rows[0]?.scope;
}

export interface SourceSummary {
  item_count: number;
  container_count: number;
  containers: { id: string; label: string }[];
  contexts: { id: string; label: string; item_count: number }[];
  recent_items: {
    id: string;
    label: string;
    created_at: string;
    source_key: string | null;
    contexts: string[];
  }[];
}

async function fetchSourceSummary(sql: Sql, nodeId: string): Promise<SourceSummary> {
  const rows = await sql.unsafe(
    withAdminCte() +
      `, focus AS (
         SELECT id, node_type FROM rye.nodes WHERE id = $1::uuid
       ),
       containers AS (
         SELECT n.id, n.label
         FROM rye.nodes n, focus f
         WHERE f.node_type = 'source_container' AND n.id = f.id
         UNION
         SELECT c.id, c.label
         FROM focus f
         JOIN rye.edges e ON e.source_id = f.id
         JOIN rye.nodes c ON c.id = e.target_id
         WHERE f.node_type = 'source_account'
           AND e.edge_type = 'contains_item'
           AND e.archived_at IS NULL
           AND c.node_type = 'source_container'
       ),
       items AS (
         SELECT i.id, i.label, i.properties, i.attrs, i.created_at
         FROM containers c
         JOIN rye.edges e ON e.source_id = c.id
         JOIN rye.nodes i ON i.id = e.target_id
         WHERE e.edge_type = 'contains_item'
           AND e.archived_at IS NULL
           AND i.node_type = 'source_item'
       ),
       context_counts AS (
         SELECT rc.id, rc.label, COUNT(DISTINCT i.id)::int AS item_count
         FROM items i
         JOIN rye.edges e ON e.source_id = i.id
         JOIN rye.nodes rc ON rc.id = e.target_id
         WHERE e.edge_type = 'reviewed_under'
           AND e.archived_at IS NULL
           AND rc.node_type = 'review_context'
         GROUP BY rc.id, rc.label
       ),
       recent_items AS (
         SELECT i.id::text AS id,
                i.label,
                i.created_at,
                COALESCE(i.attrs->>'source_item_key', i.properties->>'recording_id') AS source_key,
                COALESCE((
                  SELECT json_agg(rc.label ORDER BY rc.label)
                  FROM rye.edges e
                  JOIN rye.nodes rc ON rc.id = e.target_id
                  WHERE e.source_id = i.id
                    AND e.edge_type = 'reviewed_under'
                    AND e.archived_at IS NULL
                    AND rc.node_type = 'review_context'
                ), '[]'::json) AS contexts
         FROM items i
         ORDER BY i.created_at DESC, i.label
         LIMIT 12
       )
       SELECT json_build_object(
         'item_count', (SELECT COUNT(*)::int FROM items),
         'container_count', (SELECT COUNT(*)::int FROM containers),
         'containers', COALESCE((SELECT json_agg(c ORDER BY c.label) FROM (
            SELECT id::text AS id, label FROM containers
          ) c), '[]'::json),
         'contexts', COALESCE((SELECT json_agg(cc ORDER BY cc.item_count DESC, cc.label) FROM (
            SELECT id::text AS id, label, item_count FROM context_counts
          ) cc), '[]'::json),
         'recent_items', COALESCE((SELECT json_agg(ri) FROM recent_items ri), '[]'::json)
       ) AS payload
       FROM cfg`,
    [nodeId]
  );
  return rows[0]?.payload as SourceSummary;
}

export async function fetchActiveDisputes(sql: Sql, limit = 50) {
  // Use the canonical rye.active_disputes view (single source of truth): it
  // surfaces genuine contested assertions (attrs->'dispute', stamped by
  // contest_assertion) and excludes append-only multi-valued logs.
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT d.subject_node_id::text AS subject_node_id,
              n.label, n.node_type, d.assertion_type,
              d.competing_assertions::int AS competing_claims,
              (SELECT json_agg(json_build_object(
                  'id', x->>'assertion_id', 'claim', x->'claim',
                  'source_event_id', x->>'source_event_id', 'confidence', x->'confidence'))
               FROM jsonb_array_elements(d.assertions) x) AS claims
       FROM rye.active_disputes d
       JOIN rye.nodes n ON n.id = d.subject_node_id, cfg
       ORDER BY competing_claims DESC LIMIT $1`,
    [limit]
  );
  return rows;
}

export async function fetchRecentEvents(sql: Sql, limit = 50) {
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT e.id,
              e.event_type,
              e.summary,
              e.occurred_at,
              e.actor_system,
              e.properties,
              COALESCE((
                SELECT json_agg(
                  json_build_object(
                    'node_id', ep.node_id::text,
                    'role', ep.role,
                    'node_type', n.node_type,
                    'label', n.label
                  )
                  ORDER BY ep.role, n.label
                )
                FROM rye.event_participants ep
                JOIN rye.nodes n ON n.id = ep.node_id
                WHERE ep.event_id = e.id
                  AND n.archived_at IS NULL
              ), '[]'::json) AS participants
       FROM rye.events e, cfg
       ORDER BY e.occurred_at DESC LIMIT $1`,
    [limit]
  );
  return rows;
}

// ---------------------------------------------------------------------------
// Generic knowledge-graph dashboard (any Rye instance: people, events, facts)
// ---------------------------------------------------------------------------

export async function fetchKnowledgeKpis(sql: Sql) {
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT
         (SELECT COUNT(*) FROM rye.nodes)::int AS nodes_total,
         (SELECT COUNT(*) FROM rye.edges)::int AS edges_total,
         (SELECT COUNT(*) FROM rye.events)::int AS events_total,
         (SELECT COUNT(*) FROM rye.assertions)::int AS assertions_total,
         (SELECT COUNT(*) FROM rye.assertions WHERE superseded_at IS NULL)::int AS active_assertions,
         (SELECT COUNT(*) FROM rye.assertions WHERE superseded_at IS NOT NULL)::int AS superseded_assertions,
         (SELECT COUNT(*) FROM rye.active_disputes)::int AS disputed_subjects,
         (SELECT COUNT(*) FROM rye.nodes WHERE node_type='person')::int AS people_total,
         (SELECT COUNT(DISTINCT subject_node_id) FROM rye.assertions)::int AS subjects_total,
         (SELECT COUNT(*) FROM rye.artifacts)::int AS artifacts_total
       FROM cfg`
  );
  return rows[0];
}

// Who/what is connected to the most activity (people↔events).
export async function fetchTopParticipants(sql: Sql, limit = 10) {
  return sql.unsafe(
    withAdminCte() +
      `SELECT n.id::text AS id, n.label, n.node_type, COUNT(*)::int AS events
       FROM rye.event_participants ep JOIN rye.nodes n ON n.id = ep.node_id, cfg
       GROUP BY 1,2,3 ORDER BY events DESC, n.label LIMIT $1`,
    [limit]
  );
}

// Activity over time — events per month (knowledge accumulating).
export async function fetchActivityTimeline(sql: Sql) {
  return sql.unsafe(
    withAdminCte() +
      `SELECT to_char(date_trunc('month', occurred_at),'YYYY-MM') AS bucket,
              COUNT(*)::int AS count
       FROM rye.events, cfg
       WHERE occurred_at IS NOT NULL
       GROUP BY 1 ORDER BY 1`
  );
}

// Assertion composition by type, split active vs superseded.
export async function fetchAssertionComposition(sql: Sql) {
  return sql.unsafe(
    withAdminCte() +
      `SELECT assertion_type,
              COUNT(*) FILTER (WHERE superseded_at IS NULL)::int AS active,
              COUNT(*) FILTER (WHERE superseded_at IS NOT NULL)::int AS superseded,
              COUNT(*)::int AS total
       FROM rye.assertions, cfg
       GROUP BY 1 ORDER BY total DESC`
  );
}

// Subjects with the most accumulated knowledge.
export async function fetchTopSubjects(sql: Sql, limit = 10) {
  return sql.unsafe(
    withAdminCte() +
      `SELECT n.id::text AS id, n.label, n.node_type,
              COUNT(*)::int AS facts,
              COUNT(*) FILTER (WHERE a.superseded_at IS NULL)::int AS active
       FROM rye.assertions a JOIN rye.nodes n ON n.id = a.subject_node_id, cfg
       GROUP BY 1,2,3 ORDER BY facts DESC, n.label LIMIT $1`,
    [limit]
  );
}

// Recent supersessions: a fact's previous claim → the claim that replaced it.
export async function fetchSupersessions(sql: Sql, limit = 8) {
  return sql.unsafe(
    withAdminCte() +
      `SELECT old.subject_node_id::text AS subject_node_id, n.label, n.node_type,
              old.assertion_type,
              old.claim AS old_claim, nw.claim AS new_claim,
              old.effective_at AS old_at, nw.effective_at AS new_at
       FROM rye.assertions old
       JOIN rye.assertions nw ON nw.id = old.superseded_by
       JOIN rye.nodes n ON n.id = old.subject_node_id, cfg
       WHERE old.subject_node_id IS NOT NULL
       ORDER BY nw.effective_at DESC NULLS LAST, old.superseded_at DESC LIMIT $1`,
    [limit]
  );
}

// ---------------------------------------------------------------------------
// Knowledge promotion: evidence -> candidate -> accepted knowledge
// ---------------------------------------------------------------------------

export interface NodeKnowledgeOptions {
  asOf?: string | null;
  includeStale?: boolean;
  includeSuperseded?: boolean;
  includeRejected?: boolean;
  includeRawEvidence?: boolean;
}

export async function fetchNodeKnowledge(
  sql: Sql,
  nodeId: string,
  opts: NodeKnowledgeOptions = {}
) {
  const rows = await sql.unsafe(
    withAdminCte() +
      `, focus AS (
         SELECT id, node_type, label
         FROM rye.nodes
         WHERE id = $1::uuid
       ),
       evidence_nodes AS (
         SELECT id FROM focus
         UNION
         SELECT e.target_id
         FROM focus f
         JOIN rye.edges e ON e.source_id = f.id
         JOIN rye.nodes n ON n.id = e.target_id
         WHERE f.node_type IN ('source_account', 'source_container')
           AND e.edge_type = 'contains_item'
           AND e.archived_at IS NULL
           AND n.node_type = 'source_item'
         UNION
         SELECT item.target_id
         FROM focus f
         JOIN rye.edges container_edge ON container_edge.source_id = f.id
         JOIN rye.nodes container ON container.id = container_edge.target_id
         JOIN rye.edges item ON item.source_id = container.id
         JOIN rye.nodes source_item ON source_item.id = item.target_id
         WHERE f.node_type = 'source_account'
           AND container_edge.edge_type = 'contains_item'
           AND container_edge.archived_at IS NULL
           AND container.node_type = 'source_container'
           AND item.edge_type = 'contains_item'
           AND item.archived_at IS NULL
           AND source_item.node_type = 'source_item'
         UNION
         SELECT e.source_id
         FROM focus f
         JOIN rye.edges e ON e.target_id = f.id
         JOIN rye.nodes source_item ON source_item.id = e.source_id
         WHERE f.node_type = 'review_context'
           AND e.edge_type = 'reviewed_under'
           AND e.archived_at IS NULL
           AND source_item.node_type = 'source_item'
       ),
       event_scope AS (
         SELECT DISTINCT ep.event_id
         FROM rye.event_participants ep
         WHERE ep.node_id IN (SELECT id FROM evidence_nodes)
       ),
       artifact_scope AS (
         SELECT DISTINCT ar.id
         FROM rye.artifacts ar
         WHERE ar.source_node_id IN (SELECT id FROM evidence_nodes)
            OR $1::uuid = ANY(COALESCE(ar.related_node_ids, ARRAY[]::uuid[]))
       ),
       recent_evidence AS (
         SELECT *
         FROM (
           SELECT
             'source_item'::text AS kind,
             n.id::text AS id,
             n.label AS title,
             n.created_at AS occurred_at,
             jsonb_build_object(
               'node_type', n.node_type,
               'properties', CASE WHEN $5::boolean THEN n.properties ELSE '{}'::jsonb END,
               'attrs', CASE WHEN $5::boolean THEN n.attrs ELSE '{}'::jsonb END
             ) AS payload
           FROM rye.nodes n
           WHERE n.id IN (SELECT id FROM evidence_nodes)
             AND n.node_type = 'source_item'

           UNION ALL

           SELECT
             'artifact'::text AS kind,
             ar.id::text AS id,
             ar.artifact_type AS title,
             ar.created_at AS occurred_at,
             CASE
               WHEN $5::boolean THEN ar.content
               ELSE jsonb_build_object('artifact_type', ar.artifact_type)
             END AS payload
           FROM rye.artifacts ar
           WHERE ar.id IN (SELECT id FROM artifact_scope)

           UNION ALL

           SELECT
             'event'::text AS kind,
             e.id::text AS id,
             e.event_type AS title,
             e.occurred_at,
             jsonb_build_object(
               'summary', e.summary,
               'actor_system', e.actor_system,
               'properties', CASE WHEN $5::boolean THEN e.properties ELSE '{}'::jsonb END
             ) AS payload
           FROM rye.events e
           WHERE e.id IN (SELECT event_id FROM event_scope)
         ) evidence
         ORDER BY occurred_at DESC NULLS LAST
         LIMIT 24
       ),
       candidate_ids AS (
         SELECT f.id
         FROM focus f
         WHERE f.node_type = 'knowledge_candidate'

         UNION

         SELECT e.source_id
         FROM rye.edges e
         JOIN rye.nodes candidate ON candidate.id = e.source_id
         WHERE e.edge_type IN ('supported_by', 'derived_from')
           AND e.target_id IN (SELECT id FROM evidence_nodes)
           AND e.archived_at IS NULL
           AND candidate.node_type = 'knowledge_candidate'
           AND candidate.archived_at IS NULL

         UNION

         SELECT e.source_id
         FROM rye.edges e
         JOIN rye.nodes candidate ON candidate.id = e.source_id
         WHERE e.edge_type = 'promoted_to'
           AND e.target_id = $1::uuid
           AND e.archived_at IS NULL
           AND candidate.node_type = 'knowledge_candidate'
           AND candidate.archived_at IS NULL

         UNION

         SELECT candidate.id
         FROM rye.assertions a
         JOIN rye.nodes candidate ON candidate.id::text = a.attrs->>'candidate_id'
         WHERE a.subject_node_id = $1::uuid
           AND candidate.node_type = 'knowledge_candidate'
           AND candidate.archived_at IS NULL
       ),
       candidate_rows AS (
         SELECT
           candidate.id::text AS id,
           candidate.label,
           candidate.properties,
           candidate.attrs,
           candidate.created_at,
           COALESCE(status_assertion.claim->>'status', 'proposed') AS status,
           status_assertion.claim AS status_claim,
           COALESCE((
             SELECT json_agg(json_build_object(
               'id', n.id::text,
               'label', n.label,
               'node_type', n.node_type,
               'edge_type', e.edge_type
             ) ORDER BY e.edge_type, n.label)
             FROM rye.edges e
             JOIN rye.nodes n ON n.id = e.target_id
             WHERE e.source_id = candidate.id
               AND e.edge_type IN ('supported_by', 'derived_from')
               AND e.archived_at IS NULL
           ), '[]'::json) AS supporting_sources,
           COALESCE((
             SELECT json_agg(json_build_object(
               'id', n.id::text,
               'label', n.label,
               'node_type', n.node_type,
               'edge_type', e.edge_type
             ) ORDER BY n.label)
             FROM rye.edges e
             JOIN rye.nodes n ON n.id = e.target_id
             WHERE e.source_id = candidate.id
               AND e.edge_type = 'promoted_to'
               AND e.archived_at IS NULL
           ), '[]'::json) AS promoted_targets
         FROM rye.nodes candidate
         LEFT JOIN rye.current_assertions status_assertion
           ON status_assertion.subject_node_id = candidate.id
          AND status_assertion.assertion_type = 'candidate_status'
          AND status_assertion.assertion_key = 'default'
         WHERE candidate.id IN (SELECT id FROM candidate_ids)
           AND (
             $4::boolean
             OR COALESCE(status_assertion.claim->>'status', 'proposed')
                NOT IN ('rejected', 'duplicate', 'superseded')
           )
       ),
       accepted_rows AS (
         SELECT
           a.id::text AS id,
           a.assertion_type,
           a.assertion_key,
           a.claim,
           a.confidence,
           a.effective_at,
           a.effective_to,
           a.source_event_id::text AS source_event_id,
           a.attrs,
           a.created_at,
           a.superseded_at,
           a.superseded_by::text AS superseded_by,
           source_event.event_type AS source_event_type,
           source_event.summary AS source_event_summary,
           candidate.id::text AS candidate_id,
           candidate.label AS candidate_label,
           candidate.properties AS candidate_properties
         FROM rye.assertions a
         LEFT JOIN rye.events source_event ON source_event.id = a.source_event_id
         LEFT JOIN rye.nodes candidate ON candidate.id::text = a.attrs->>'candidate_id'
         WHERE a.subject_node_id = $1::uuid
           AND a.assertion_type <> 'candidate_status'
           AND COALESCE(a.attrs->>'record_mode', '') <> 'candidate'
           AND ($3::boolean OR a.superseded_at IS NULL)
           AND ($6::boolean OR (
             (
               $2::timestamptz IS NULL
               AND (a.effective_at IS NULL OR a.effective_at <= now())
               AND (a.effective_to IS NULL OR a.effective_to > now())
             )
             OR
             (
               $2::timestamptz IS NOT NULL
               AND (a.effective_at IS NULL OR a.effective_at <= $2::timestamptz)
               AND (a.effective_to IS NULL OR a.effective_to > $2::timestamptz)
             )
           ))
       ),
       task_ids AS (
         SELECT other.id
         FROM rye.edges e
         JOIN rye.nodes other ON other.id = CASE
           WHEN e.source_id = $1::uuid THEN e.target_id
           ELSE e.source_id
         END
         WHERE (e.source_id = $1::uuid OR e.target_id = $1::uuid)
           AND e.archived_at IS NULL
           AND other.node_type = 'task'

         UNION

         SELECT e.target_id
         FROM rye.edges e
         JOIN rye.nodes task ON task.id = e.target_id
         WHERE e.source_id IN (SELECT id FROM candidate_ids)
           AND e.edge_type = 'promoted_to'
           AND e.archived_at IS NULL
           AND task.node_type = 'task'
       ),
       task_rows AS (
         SELECT
           task.id::text AS id,
           task.label,
           task.properties,
           task.attrs,
           task.created_at,
           status_assertion.claim->>'status' AS status,
           status_assertion.claim AS status_claim,
           COALESCE((
             SELECT json_agg(e.source_id::text ORDER BY e.created_at)
             FROM rye.edges e
             WHERE e.edge_type = 'promoted_to'
               AND e.target_id = task.id
               AND e.source_id IN (SELECT id FROM candidate_ids)
               AND e.archived_at IS NULL
           ), '[]'::json) AS source_candidate_ids
         FROM rye.nodes task
         LEFT JOIN rye.current_assertions status_assertion
           ON status_assertion.subject_node_id = task.id
          AND status_assertion.assertion_type = 'task_status'
          AND status_assertion.assertion_key = 'default'
         WHERE task.id IN (SELECT id FROM task_ids)
           AND task.archived_at IS NULL
       ),
       history AS (
         SELECT json_build_object(
           'events_count', (SELECT COUNT(*)::int FROM event_scope),
           'assertions_count', (
             SELECT COUNT(*)::int FROM rye.assertions WHERE subject_node_id = $1::uuid
           ),
           'superseded_assertions_count', (
             SELECT COUNT(*)::int FROM rye.assertions
             WHERE subject_node_id = $1::uuid AND superseded_at IS NOT NULL
           ),
           'candidates_count', (SELECT COUNT(*)::int FROM candidate_rows),
           'recent_events', COALESCE((
             SELECT json_agg(ev ORDER BY ev.occurred_at DESC)
             FROM (
               SELECT e.id::text AS id,
                      e.event_type,
                      e.summary,
                      e.occurred_at,
                      e.actor_system,
                      e.properties
               FROM rye.events e
               WHERE e.id IN (SELECT event_id FROM event_scope)
               ORDER BY e.occurred_at DESC NULLS LAST
               LIMIT 12
             ) ev
           ), '[]'::json)
         ) AS payload
       )
       SELECT json_build_object(
         'evidence', json_build_object(
           'source_items_count', (
             SELECT COUNT(*)::int
             FROM rye.nodes n
             WHERE n.id IN (SELECT id FROM evidence_nodes)
               AND n.node_type = 'source_item'
           ),
           'artifacts_count', (SELECT COUNT(*)::int FROM artifact_scope),
           'source_events_count', (SELECT COUNT(*)::int FROM event_scope),
           'recent_evidence', COALESCE((SELECT json_agg(re ORDER BY re.occurred_at DESC) FROM recent_evidence re), '[]'::json)
         ),
         'candidates', COALESCE((SELECT json_agg(cr ORDER BY cr.created_at DESC) FROM candidate_rows cr), '[]'::json),
         'accepted_knowledge', COALESCE((SELECT json_agg(ar ORDER BY ar.created_at DESC) FROM accepted_rows ar), '[]'::json),
         'actions', COALESCE((SELECT json_agg(tr ORDER BY tr.created_at DESC) FROM task_rows tr), '[]'::json),
         'history', (SELECT payload FROM history),
         'what_was_learned', json_build_object(
           'topics', COALESCE((
             SELECT json_agg(DISTINCT topic ORDER BY topic)
             FROM (
               SELECT assertion_type AS topic FROM accepted_rows
               UNION
               SELECT properties->>'candidate_kind' AS topic FROM candidate_rows
             ) topics
             WHERE topic IS NOT NULL
           ), '[]'::json),
           'entities', COALESCE((
             SELECT json_agg(DISTINCT label ORDER BY label)
             FROM (
               SELECT label FROM rye.nodes WHERE id = $1::uuid
               UNION
               SELECT n.label
               FROM rye.edges e
               JOIN rye.nodes n ON n.id = CASE
                 WHEN e.source_id = $1::uuid THEN e.target_id
                 ELSE e.source_id
               END
               WHERE (e.source_id = $1::uuid OR e.target_id = $1::uuid)
                 AND e.archived_at IS NULL
             ) entities
             WHERE label IS NOT NULL
             LIMIT 20
           ), '[]'::json),
           'actions', COALESCE((
             SELECT json_agg(label ORDER BY created_at DESC)
             FROM task_rows
           ), '[]'::json),
           'decisions', COALESCE((
             SELECT json_agg(statement ORDER BY created_at DESC)
             FROM (
               SELECT properties->>'statement' AS statement, created_at
               FROM candidate_rows
               WHERE properties->>'candidate_kind' = 'decision'
               UNION ALL
               SELECT claim->>'text' AS statement, created_at
               FROM accepted_rows
               WHERE assertion_type = 'decision'
             ) decisions
             WHERE statement IS NOT NULL
             LIMIT 12
           ), '[]'::json),
           'open_questions', COALESCE((
             SELECT json_agg(properties->>'statement' ORDER BY created_at DESC)
             FROM candidate_rows
             WHERE status = 'needs_review'
           ), '[]'::json)
         )
       ) AS payload
       FROM cfg`,
    [
      nodeId,
      opts.asOf ?? null,
      opts.includeSuperseded ?? false,
      opts.includeRejected ?? false,
      opts.includeRawEvidence ?? false,
      opts.includeStale ?? false,
    ]
  );
  return rows[0]?.payload ?? {
    evidence: { source_items_count: 0, artifacts_count: 0, source_events_count: 0, recent_evidence: [] },
    candidates: [],
    accepted_knowledge: [],
    actions: [],
    history: { events_count: 0, assertions_count: 0, superseded_assertions_count: 0, candidates_count: 0, recent_events: [] },
    what_was_learned: { topics: [], entities: [], actions: [], decisions: [], open_questions: [] },
  };
}

export interface CreateKnowledgeCandidateInput {
  candidate_kind: string;
  statement: string;
  target_payload?: Record<string, unknown>;
  review_context_ids?: string[];
  normalized_key?: string | null;
  created_by?: string | null;
  source_node_ids?: string[];
  derived_from_node_ids?: string[];
  confidence?: number | null;
}

export async function createKnowledgeCandidate(
  sql: Sql,
  input: CreateKnowledgeCandidateInput
): Promise<{ id: string }> {
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT rye.create_knowledge_candidate(
         p_candidate_kind        := $1::text,
         p_statement             := $2::text,
         p_target_payload        := $3::jsonb,
         p_review_context_ids    := $4::uuid[],
         p_normalized_key        := $5::text,
         p_created_by            := $6::text,
         p_source_node_ids       := $7::uuid[],
         p_derived_from_node_ids := $8::uuid[],
         p_confidence            := $9::numeric
       )::text AS id
       FROM cfg`,
    [
      input.candidate_kind,
      input.statement,
      JSON.stringify(input.target_payload ?? {}),
      input.review_context_ids ?? [],
      input.normalized_key ?? null,
      input.created_by ?? null,
      input.source_node_ids ?? [],
      input.derived_from_node_ids ?? [],
      input.confidence ?? null,
    ]
  );
  return { id: rows[0]?.id as string };
}

export async function setKnowledgeCandidateStatus(
  sql: Sql,
  candidateId: string,
  input: { status: string; reason?: string | null; actor?: string | null }
): Promise<{ assertion_id: string }> {
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT rye.set_candidate_status(
         p_candidate_id := $1::uuid,
         p_status       := $2::text,
         p_reason       := $3::text,
         p_actor        := $4::text
       )::text AS assertion_id
       FROM cfg`,
    [candidateId, input.status, input.reason ?? null, input.actor ?? null]
  );
  return { assertion_id: rows[0]?.assertion_id as string };
}

export type PromoteKnowledgeCandidateInput =
  | {
      target_type: "assertion";
      subject_node_id: string;
      assertion_type: string;
      assertion_key?: string | null;
      claim: Record<string, unknown>;
      effective_at?: string | null;
      effective_to?: string | null;
      confidence?: number | null;
      actor?: string | null;
    }
  | {
      target_type: "task";
      label: string;
      properties?: Record<string, unknown>;
      actor?: string | null;
    }
  | {
      target_type: "edge";
      source_id: string;
      target_id: string;
      edge_type: string;
      properties?: Record<string, unknown>;
      effective_from?: string | null;
      effective_to?: string | null;
      actor?: string | null;
    };

export async function promoteKnowledgeCandidate(
  sql: Sql,
  candidateId: string,
  input: PromoteKnowledgeCandidateInput
): Promise<{ target_type: string; id: string }> {
  if (input.target_type === "assertion") {
    const rows = await sql.unsafe(
      withAdminCte() +
        `SELECT rye.promote_candidate_to_assertion(
           p_candidate_id    := $1::uuid,
           p_subject_node_id := $2::uuid,
           p_assertion_type  := $3::text,
           p_assertion_key   := $4::text,
           p_claim           := $5::jsonb,
           p_effective_at    := $6::timestamptz,
           p_effective_to    := $7::timestamptz,
           p_confidence      := $8::numeric,
           p_actor           := $9::text
         )::text AS id
         FROM cfg`,
      [
        candidateId,
        input.subject_node_id,
        input.assertion_type,
        input.assertion_key ?? "default",
        JSON.stringify(input.claim),
        input.effective_at ?? null,
        input.effective_to ?? null,
        input.confidence ?? null,
        input.actor ?? null,
      ]
    );
    return { target_type: "assertion", id: rows[0]?.id as string };
  }

  if (input.target_type === "task") {
    const rows = await sql.unsafe(
      withAdminCte() +
        `SELECT rye.promote_candidate_to_task(
           p_candidate_id := $1::uuid,
           p_label        := $2::text,
           p_properties   := $3::jsonb,
           p_actor        := $4::text
         )::text AS id
         FROM cfg`,
      [candidateId, input.label, JSON.stringify(input.properties ?? {}), input.actor ?? null]
    );
    return { target_type: "task", id: rows[0]?.id as string };
  }

  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT rye.promote_candidate_to_edge(
         p_candidate_id   := $1::uuid,
         p_source_id      := $2::uuid,
         p_target_id      := $3::uuid,
         p_edge_type      := $4::text,
         p_properties     := $5::jsonb,
         p_effective_from := $6::timestamptz,
         p_effective_to   := $7::timestamptz,
         p_actor          := $8::text
       )::text AS id
       FROM cfg`,
    [
      candidateId,
      input.source_id,
      input.target_id,
      input.edge_type,
      JSON.stringify(input.properties ?? {}),
      input.effective_from ?? null,
      input.effective_to ?? null,
      input.actor ?? null,
    ]
  );
  return { target_type: "edge", id: rows[0]?.id as string };
}

// ---------------------------------------------------------------------------
// Recon (mineral-rights) specific aggregates
// ---------------------------------------------------------------------------

export interface ReconKpis {
  parcels_total: number;
  documents_total: number;
  pages_total: number;
  parcel_refs_total: number;
  resolved_refs: number;
  unresolved_refs: number;
  active_leases: number;
  active_ownership_claims: number;
  tracked_owners: number;
  net_acres_under_mgmt: number;
}

export async function fetchReconKpis(sql: Sql): Promise<ReconKpis> {
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT
         (SELECT COUNT(*) FROM rye.nodes WHERE node_type='parcel')::int AS parcels_total,
         (SELECT COUNT(*) FROM rye.nodes WHERE node_type='document')::int AS documents_total,
         (SELECT COUNT(*) FROM rye.nodes WHERE node_type='page')::int AS pages_total,
         (SELECT COUNT(*) FROM rye.nodes WHERE node_type='parcel_reference')::int AS parcel_refs_total,
         (SELECT COUNT(DISTINCT source_id) FROM rye.edges WHERE edge_type='resolves_to')::int AS resolved_refs,
         (SELECT COUNT(*) FROM rye.nodes n WHERE n.node_type='parcel_reference'
            AND NOT EXISTS (SELECT 1 FROM rye.edges e WHERE e.source_id = n.id AND e.edge_type='resolves_to'))::int AS unresolved_refs,
         (SELECT COUNT(*) FROM rye.assertions WHERE assertion_type='lease' AND superseded_at IS NULL)::int AS active_leases,
         (SELECT COUNT(*) FROM rye.assertions WHERE assertion_type='mineral_ownership' AND superseded_at IS NULL)::int AS active_ownership_claims,
         (SELECT COUNT(DISTINCT claim->>'owner') FROM rye.assertions
           WHERE assertion_type='mineral_ownership' AND superseded_at IS NULL AND claim ? 'owner')::int AS tracked_owners,
         COALESCE((SELECT SUM(
            CASE WHEN (claim->>'net_mineral_acres') ~ '^[0-9.]+$'
                 THEN (claim->>'net_mineral_acres')::numeric ELSE 0 END)
           FROM rye.assertions
           WHERE assertion_type='mineral_ownership' AND superseded_at IS NULL),0)::float AS net_acres_under_mgmt
       FROM cfg`
  );
  return rows[0] as unknown as ReconKpis;
}

export async function fetchTopOwners(sql: Sql, limit = 10) {
  return sql.unsafe(
    withAdminCte() +
      `SELECT claim->>'owner' AS owner,
              COUNT(*)::int AS claims,
              SUM(CASE WHEN (claim->>'net_mineral_acres') ~ '^[0-9.]+$'
                       THEN (claim->>'net_mineral_acres')::numeric ELSE 0 END)::float AS net_acres
       FROM rye.assertions, cfg
       WHERE assertion_type='mineral_ownership' AND superseded_at IS NULL AND claim ? 'owner'
       GROUP BY 1 ORDER BY net_acres DESC NULLS LAST LIMIT $1`,
    [limit]
  );
}

export async function fetchTopLessees(sql: Sql, limit = 10) {
  return sql.unsafe(
    withAdminCte() +
      `SELECT claim->>'lessee' AS lessee,
              COUNT(*)::int AS leases,
              AVG(CASE WHEN (claim->>'royalty') ~ '^[0-9.]+$'
                       THEN (claim->>'royalty')::numeric ELSE NULL END)::float AS avg_royalty
       FROM rye.assertions, cfg
       WHERE assertion_type='lease' AND superseded_at IS NULL AND claim ? 'lessee'
       GROUP BY 1 ORDER BY leases DESC LIMIT $1`,
    [limit]
  );
}

export async function fetchCountyRollup(sql: Sql, limit = 12) {
  return sql.unsafe(
    withAdminCte() +
      `SELECT COALESCE(properties->>'county','(unknown)') AS county,
              COUNT(*)::int AS parcels
       FROM rye.nodes, cfg
       WHERE node_type='parcel'
       GROUP BY 1 ORDER BY parcels DESC LIMIT $1`,
    [limit]
  );
}

export async function fetchExtractionTimeline(sql: Sql) {
  return sql.unsafe(
    withAdminCte() +
      `SELECT date_trunc('day', occurred_at)::date AS bucket,
              COUNT(*)::int AS runs,
              COALESCE(SUM((properties->>'rows_extracted')::int),0)::int AS rows_extracted,
              COALESCE(SUM((properties->>'mineral_owners')::int),0)::int AS owners_extracted,
              COALESCE(SUM((properties->>'parcels_created')::int),0)::int AS parcels_created
       FROM rye.events, cfg
       WHERE event_type='extraction'
       GROUP BY 1 ORDER BY 1`
  );
}
