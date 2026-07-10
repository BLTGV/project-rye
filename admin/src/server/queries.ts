import type postgres from "postgres";
import { withAdminCte } from "./db";

type Sql = ReturnType<typeof postgres>;

function jsonParam(value: unknown): postgres.JSONValue {
  return value as postgres.JSONValue;
}

export interface AgentCapabilityGrant {
  capability: string;
  domain_key: string | null;
  scope_ref: string | null;
  expires_at: string | null;
}

export interface AgentAuthContext {
  agent_id: string;
  agent_key: string;
  label: string;
  runtime: string;
  default_scope_ref: string | null;
  capabilities: AgentCapabilityGrant[];
}

export interface AgentAuthorizationResult {
  allowed: boolean;
  capability: string;
  domain_keys: string[];
  scope_ref: string | null;
  target_ref: string | null;
  reason: string;
}

export interface CandidateAccessEnvelope {
  domain_keys: string[];
  source_scope: string | null;
  impact_scope: string | null;
  current_or_future: string | null;
}

export async function authenticateAgentToken(sql: Sql, token: string): Promise<AgentAuthContext | null> {
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT rye.authenticate_agent_token($1::text) AS auth
       FROM cfg`,
    [token]
  );
  return (rows[0]?.auth ?? null) as AgentAuthContext | null;
}

export async function authorizeAgentAction(
  sql: Sql,
  input: {
    agentId: string;
    action: string;
    capability: string;
    domainKeys?: string[];
    scopeRef?: string | null;
    targetRef?: string | null;
    request?: Record<string, unknown>;
    result?: Record<string, unknown>;
  }
): Promise<AgentAuthorizationResult> {
  const rows = await sql.unsafe(
    withAdminCte() +
      `, auth AS (
         SELECT rye.authorize_agent_action(
           p_agent_id     := $1::uuid,
           p_capability   := $3::text,
           p_domain_keys  := $4::text[],
           p_scope_ref    := $5::text,
           p_target_ref   := $6::text
         ) AS payload
         FROM cfg
       ),
       audit AS (
         SELECT rye.record_agent_action(
           p_agent_id    := $1::uuid,
           p_action      := $2::text,
           p_capability  := $3::text,
           p_allowed     := (payload->>'allowed')::boolean,
           p_domain_keys := $4::text[],
           p_scope_ref   := $5::text,
           p_target_ref  := $6::text,
           p_reason      := payload->>'reason',
           p_request     := $7::jsonb,
           p_result      := $8::jsonb
         ) AS action_id
         FROM auth
       )
       SELECT payload
       FROM auth, audit`,
    [
      input.agentId,
      input.action,
      input.capability,
      input.domainKeys ?? [],
      input.scopeRef ?? null,
      input.targetRef ?? null,
      jsonParam(input.request ?? {}),
      jsonParam(input.result ?? {}),
    ]
  );
  return rows[0]?.payload as AgentAuthorizationResult;
}

export async function recordAgentActionOutcome(
  sql: Sql,
  input: {
    agentId: string;
    action: string;
    capability: string;
    allowed: boolean;
    domainKeys?: string[];
    scopeRef?: string | null;
    targetRef?: string | null;
    reason?: string | null;
    request?: Record<string, unknown>;
    result?: Record<string, unknown>;
  }
): Promise<void> {
  await sql.unsafe(
    withAdminCte() +
      `SELECT rye.record_agent_action(
         p_agent_id    := $1::uuid,
         p_action      := $2::text,
         p_capability  := $3::text,
         p_allowed     := $4::boolean,
         p_domain_keys := $5::text[],
         p_scope_ref   := $6::text,
         p_target_ref  := $7::text,
         p_reason      := $8::text,
         p_request     := $9::jsonb,
         p_result      := $10::jsonb
       )
       FROM cfg`,
    [
      input.agentId,
      input.action,
      input.capability,
      input.allowed,
      input.domainKeys ?? [],
      input.scopeRef ?? null,
      input.targetRef ?? null,
      input.reason ?? null,
      jsonParam(input.request ?? {}),
      jsonParam(input.result ?? {}),
    ]
  );
}

export async function fetchCandidateAccessEnvelope(
  sql: Sql,
  candidateId: string
): Promise<CandidateAccessEnvelope> {
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT json_build_object(
         'domain_keys',
           COALESCE((
             SELECT json_agg(value ORDER BY value)
             FROM jsonb_array_elements_text(
               CASE
                 WHEN jsonb_typeof(n.properties->'target_payload'->'domain_keys') = 'array'
                   THEN n.properties->'target_payload'->'domain_keys'
                 ELSE '[]'::jsonb
               END
             ) AS value
           ), '[]'::json),
         'source_scope', n.properties->'target_payload'->>'source_scope',
         'impact_scope', n.properties->'target_payload'->>'impact_scope',
         'current_or_future', n.properties->'target_payload'->>'current_or_future'
       ) AS envelope
       FROM rye.nodes n, cfg
       WHERE n.id = $1::uuid
         AND n.node_type = 'knowledge_candidate'
         AND n.archived_at IS NULL`,
    [candidateId]
  );
  return (
    rows[0]?.envelope ?? {
      domain_keys: [],
      source_scope: null,
      impact_scope: null,
      current_or_future: null,
    }
  ) as CandidateAccessEnvelope;
}

export async function fetchDomains(
  sql: Sql,
  opts: { includeProperties?: boolean; agentId?: string | null } = {}
) {
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT COALESCE(json_agg(row_to_json(d) ORDER BY d.domain_key), '[]'::json) AS domains
       FROM (
         SELECT
           kd.id::text AS id,
           kd.domain_key,
           kd.label,
           kd.purpose,
           kd.owner_node_id::text AS owner_node_id,
           CASE
             WHEN $1::boolean
              AND (
                $2::uuid IS NULL
                OR rye.has_agent_capability(
                  $2::uuid,
                  'rye.domain.admin',
                  ARRAY[kd.domain_key],
                  NULL
                )
              )
             THEN kd.properties
             ELSE '{}'::jsonb
           END AS properties,
           kd.created_at,
           kd.updated_at,
           COALESCE((
             SELECT json_agg(json_build_object(
               'authority_kind', da.authority_kind,
               'authority_ref', da.authority_ref,
               'claim_types', da.claim_types,
               'scope_ref', da.scope_ref,
               'speech_acts', da.speech_acts,
               'effective_at', da.effective_at,
               'effective_to', da.effective_to
             ) ORDER BY da.authority_kind, da.authority_ref)
             FROM rye.domain_authorities da
             WHERE da.domain_id = kd.id
               AND da.active = true
           ), '[]'::json) AS authorities,
           COALESCE((
             SELECT json_agg(json_build_object(
               'channel_ref', s.channel_ref,
               'access_level', s.access_level,
               'is_shared', s.is_shared
             ) ORDER BY s.channel_ref)
             FROM rye.channel_domain_subscriptions s
             WHERE s.domain_id = kd.id
           ), '[]'::json) AS channel_subscriptions
         FROM rye.knowledge_domains kd, cfg
         WHERE kd.archived_at IS NULL
           AND (
             $2::uuid IS NULL
             OR rye.has_agent_capability(
               $2::uuid,
               'rye.context.read',
               ARRAY[kd.domain_key],
               NULL
             )
           )
       ) d`,
    [opts.includeProperties ?? false, opts.agentId ?? null]
  );
  return rows[0]?.domains ?? [];
}

export async function fetchAgentContextPack(
  sql: Sql,
  agentId: string,
  opts: { scopeRef?: string | null; channelRef?: string | null; domainKeys?: string[] }
) {
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT rye.agent_get_context_pack(
         p_agent_id    := $1::uuid,
         p_scope_ref   := $2::text,
         p_channel_ref := $3::text,
         p_domain_keys := $4::text[]
       ) AS payload
       FROM cfg`,
    [agentId, opts.scopeRef ?? null, opts.channelRef ?? null, opts.domainKeys ?? []]
  );
  return rows[0]?.payload ?? {};
}

export async function fetchAgentAuditActions(sql: Sql, limit = 100) {
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT COALESCE(json_agg(row_to_json(a) ORDER BY a.created_at DESC), '[]'::json) AS actions
       FROM (
         SELECT
           l.id::text AS id,
           l.agent_id::text AS agent_id,
           ai.agent_key,
           ai.label AS agent_label,
           l.action,
           l.capability,
           kd.domain_key,
           l.scope_ref,
           l.target_ref,
           l.allowed,
           l.reason,
           l.request,
           l.result,
           l.created_at
         FROM rye.agent_action_log l
         LEFT JOIN rye.agent_identities ai ON ai.id = l.agent_id
         LEFT JOIN rye.knowledge_domains kd ON kd.id = l.domain_id
         ORDER BY l.created_at DESC
         LIMIT $1::int
       ) a, cfg`,
    [Math.max(1, Math.min(limit, 500))]
  );
  return rows[0]?.actions ?? [];
}

export async function submitAgentObservation(
  sql: Sql,
  agentId: string,
  input: {
    statement: string;
    domain_keys?: string[];
    source_scope?: string | null;
    impact_scope?: string | null;
    evidence_refs?: unknown;
    observed_at?: string | null;
    properties?: Record<string, unknown>;
  }
): Promise<{ id: string }> {
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT rye.agent_submit_observation(
         p_agent_id      := $1::uuid,
         p_statement     := $2::text,
         p_domain_keys   := $3::text[],
         p_source_scope  := $4::text,
         p_impact_scope  := $5::text,
         p_evidence_refs := $6::jsonb,
         p_observed_at   := $7::timestamptz,
         p_properties    := $8::jsonb
       )::text AS id
       FROM cfg`,
    [
      agentId,
      input.statement,
      input.domain_keys ?? [],
      input.source_scope ?? null,
      input.impact_scope ?? null,
      jsonParam(input.evidence_refs ?? []),
      input.observed_at ?? null,
      jsonParam(input.properties ?? {}),
    ]
  );
  return { id: rows[0]?.id as string };
}

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
              OR n.external_id ILIKE '%' || $2 || '%'
              OR n.external_source ILIKE '%' || $2 || '%'
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

export interface KnowledgeMapResult {
  generated_at: string;
  scopes: Record<string, unknown>[];
  current_process: Record<string, unknown>[];
  future_process: Record<string, unknown>[];
  historical_process: Record<string, unknown>[];
  candidate_statuses: Record<string, unknown>[];
  candidate_samples: Record<string, unknown>[];
  plugin_bindings: Record<string, unknown>[];
  operational_plans: Record<string, unknown>[];
  warnings: Record<string, unknown>[];
  stats: Record<string, unknown>;
}

export async function fetchKnowledgeMap(sql: Sql): Promise<KnowledgeMapResult> {
  const rows = await sql.unsafe(
    withAdminCte() +
      `, policy_assertions AS (
         SELECT
           a.id,
           a.id::text AS id_text,
           a.subject_node_id,
           a.subject_node_id::text AS subject_node_id_text,
           n.label AS scope_label,
           n.node_type AS scope_type,
           a.assertion_type,
           a.assertion_key,
           a.claim,
           a.attrs,
           a.effective_at,
           a.effective_to,
           a.created_at,
           a.superseded_at,
           a.superseded_by::text AS superseded_by,
           a.source_event_id::text AS source_event_id,
           COALESCE(a.claim->>'status_domain', a.claim->>'goal', a.claim->>'plugin_id', a.assertion_key) AS domain,
           COALESCE(
             a.claim->>'title',
             a.claim->>'summary',
             a.claim->>'policy',
             a.claim->>'authoritative_source',
             a.claim->>'constraint',
             a.claim->>'current_constraint',
             a.claim->>'Identify',
             a.claim->>'identify',
             a.claim->>'plugin_id',
             a.claim->>'purpose'
           ) AS summary_value,
           COALESCE(
             a.claim->>'current_cases_since',
             a.claim->>'cutover_effective_at',
             a.claim->>'authority_started_at',
             a.claim->>'effective_at'
           ) AS claimed_authority_at
         FROM rye.assertions a
         JOIN rye.nodes n ON n.id = a.subject_node_id
         WHERE a.assertion_type IN (
           'process_document',
           'business_policy',
           'source_of_truth_policy',
           'process_constraint',
           'improvement_cycle',
           'process_improvement_cycle',
           'plugin_policy_binding',
           'accepted_knowledge_policy',
           'candidate_review_policy',
           'candidate_evidence_policy',
           'evidence_policy',
           'review_gate',
           'review_gate_policy',
           'review_policy',
           'scope_status',
           'scope_purpose',
           'scope_owner'
         )
       ),
       scope_ids AS (
         SELECT n.id
         FROM rye.nodes n
         WHERE n.node_type = 'onboarding_scope'
         UNION
         SELECT subject_node_id
         FROM policy_assertions
         WHERE subject_node_id IS NOT NULL
       ),
       scope_rows AS (
         SELECT
           n.id::text AS id,
           n.label,
           n.node_type,
           n.created_at,
           COALESCE(status.claim->>'status', n.properties->>'status') AS status,
           COALESCE(purpose.claim->>'purpose', purpose.claim->>'text') AS purpose,
           COALESCE(owner.claim->>'owner', owner.claim->>'team', owner.claim->>'name') AS owner,
           (
             SELECT COUNT(*)::int
             FROM policy_assertions pa
             WHERE pa.subject_node_id = n.id
               AND pa.superseded_at IS NULL
               AND (pa.effective_at IS NULL OR pa.effective_at <= now())
               AND (pa.effective_to IS NULL OR pa.effective_to > now())
              AND pa.assertion_type IN ('process_document', 'business_policy', 'source_of_truth_policy', 'process_constraint', 'improvement_cycle', 'process_improvement_cycle')
           ) AS active_policy_count,
           (
             SELECT COUNT(*)::int
             FROM policy_assertions pa
             WHERE pa.subject_node_id = n.id
               AND pa.superseded_at IS NOT NULL
           ) AS superseded_policy_count,
           (
             SELECT COUNT(*)::int
             FROM rye.nodes c
             WHERE c.node_type = 'knowledge_candidate'
               AND COALESCE(c.properties->'review_context_ids', '[]'::jsonb) ? n.id::text
           ) AS candidate_count
         FROM rye.nodes n
         LEFT JOIN rye.current_assertions status
           ON status.subject_node_id = n.id
          AND status.assertion_type = 'scope_status'
          AND status.assertion_key = 'default'
         LEFT JOIN rye.current_assertions purpose
           ON purpose.subject_node_id = n.id
          AND purpose.assertion_type = 'scope_purpose'
          AND purpose.assertion_key = 'default'
         LEFT JOIN rye.current_assertions owner
           ON owner.subject_node_id = n.id
          AND owner.assertion_type = 'scope_owner'
          AND owner.assertion_key = 'default'
         WHERE n.id IN (SELECT id FROM scope_ids)
           AND n.archived_at IS NULL
       ),
       current_process AS (
         SELECT
           pa.id_text AS id,
           pa.subject_node_id_text AS subject_node_id,
           pa.scope_label,
           pa.scope_type,
           pa.assertion_type,
           pa.assertion_key,
           pa.domain,
           pa.summary_value,
           pa.claimed_authority_at,
           pa.claim,
           pa.attrs,
           pa.effective_at,
           pa.effective_to,
           pa.created_at,
           pa.source_event_id
         FROM policy_assertions pa
         WHERE pa.superseded_at IS NULL
           AND (pa.effective_at IS NULL OR pa.effective_at <= now())
           AND (pa.effective_to IS NULL OR pa.effective_to > now())
           AND pa.assertion_type IN ('process_document', 'business_policy', 'source_of_truth_policy', 'process_constraint', 'improvement_cycle', 'process_improvement_cycle')
         ORDER BY pa.scope_label, pa.assertion_type, pa.domain, pa.effective_at NULLS FIRST
       ),
       future_process AS (
         SELECT
           pa.id_text AS id,
           pa.subject_node_id_text AS subject_node_id,
           pa.scope_label,
           pa.scope_type,
           pa.assertion_type,
           pa.assertion_key,
           pa.domain,
           pa.summary_value,
           pa.claimed_authority_at,
           pa.claim,
           pa.attrs,
           pa.effective_at,
           pa.effective_to,
           pa.created_at,
           pa.source_event_id
         FROM policy_assertions pa
         WHERE pa.superseded_at IS NULL
           AND pa.effective_at > now()
           AND pa.assertion_type IN ('process_document', 'business_policy', 'source_of_truth_policy', 'process_constraint', 'improvement_cycle', 'process_improvement_cycle')
         ORDER BY pa.effective_at, pa.scope_label, pa.assertion_type, pa.domain
       ),
       historical_process AS (
         SELECT
           pa.id_text AS id,
           pa.subject_node_id_text AS subject_node_id,
           pa.scope_label,
           pa.scope_type,
           pa.assertion_type,
           pa.assertion_key,
           pa.domain,
           pa.summary_value,
           pa.claimed_authority_at,
           pa.claim,
           pa.attrs,
           pa.effective_at,
           pa.effective_to,
           pa.created_at,
           pa.superseded_at,
           pa.superseded_by,
           pa.source_event_id
         FROM policy_assertions pa
         WHERE (
             pa.superseded_at IS NOT NULL
             OR (pa.effective_to IS NOT NULL AND pa.effective_to <= now())
           )
           AND pa.assertion_type IN ('process_document', 'business_policy', 'source_of_truth_policy', 'process_constraint', 'improvement_cycle', 'process_improvement_cycle')
         ORDER BY pa.scope_label, pa.effective_at DESC NULLS LAST, pa.created_at DESC
         LIMIT 80
       ),
       candidate_base AS (
         SELECT
           n.id,
           n.id::text AS id_text,
           n.label,
           n.properties,
           n.attrs,
           n.created_at,
           COALESCE(status.claim->>'status', 'proposed') AS status,
           status.claim AS status_claim
         FROM rye.nodes n
         LEFT JOIN rye.current_assertions status
           ON status.subject_node_id = n.id
          AND status.assertion_type = 'candidate_status'
          AND status.assertion_key = 'default'
         WHERE n.node_type = 'knowledge_candidate'
           AND n.archived_at IS NULL
       ),
       candidate_statuses AS (
         SELECT status, COUNT(*)::int AS count
         FROM candidate_base
         GROUP BY status
         ORDER BY count DESC, status
       ),
       candidate_samples AS (
         SELECT
           cb.id_text AS id,
           cb.label,
           cb.status,
           cb.properties->>'candidate_kind' AS candidate_kind,
           cb.properties->>'statement' AS statement,
           cb.properties->'target_payload' AS target_payload,
           cb.properties->'review_context_ids' AS review_context_ids,
           cb.properties->>'confidence' AS confidence,
           cb.created_at,
           COALESCE((
             SELECT json_agg(json_build_object(
               'id', source.id::text,
               'label', source.label,
               'node_type', source.node_type,
               'edge_type', e.edge_type
             ) ORDER BY e.edge_type, source.label)
             FROM rye.edges e
             JOIN rye.nodes source ON source.id = e.target_id
             WHERE e.source_id = cb.id
               AND e.edge_type IN ('supported_by', 'derived_from')
               AND e.archived_at IS NULL
           ), '[]'::json) AS supporting_sources
         FROM candidate_base cb
         ORDER BY cb.created_at DESC
         LIMIT 20
       ),
       plugin_bindings AS (
         SELECT
           pa.id_text AS assertion_id,
           pa.subject_node_id_text AS scope_id,
           pa.scope_label,
           pa.claim->>'plugin_id' AS plugin_id,
           pa.claim->>'plugin_node_id' AS plugin_node_id,
           COALESCE(pa.claim->'manifest'->>'label', pa.claim->>'plugin_id') AS plugin_label,
           COALESCE(pa.claim->'manifest'->>'description', '') AS description,
           (pa.claim->>'plugin_id') LIKE 'rye-%' AS is_expected_plugin,
           pa.effective_at,
           pa.created_at,
           pa.claim
         FROM policy_assertions pa
         WHERE pa.assertion_type = 'plugin_policy_binding'
           AND pa.superseded_at IS NULL
         ORDER BY pa.scope_label, plugin_id
       ),
       operational_plans AS (
         SELECT
           a.id::text AS id,
           n.id::text AS subject_node_id,
           n.label AS subject_label,
           n.node_type AS subject_type,
           a.assertion_type,
           a.assertion_key,
           a.claim,
           a.attrs,
           a.effective_at,
           a.effective_to,
           a.created_at,
           a.source_event_id::text AS source_event_id,
           CASE
             WHEN nullif(a.claim->>'effective_at', '') IS NULL THEN a.effective_at
             ELSE (a.claim->>'effective_at')::timestamptz
           END AS planned_for
         FROM rye.current_valid_assertions a
         JOIN rye.nodes n ON n.id = a.subject_node_id
         WHERE a.assertion_type IN ('deal_stage_plan', 'task_status_plan', 'milestone_status_plan')
           AND n.archived_at IS NULL
         ORDER BY planned_for NULLS LAST, n.label, a.assertion_type
       ),
       authority_date_warnings AS (
         SELECT json_build_object(
           'severity', 'attention',
           'kind', 'authority_date_mismatch',
           'subject_node_id', pa.subject_node_id_text,
           'scope_label', pa.scope_label,
           'assertion_id', pa.id_text,
           'assertion_type', pa.assertion_type,
           'assertion_key', pa.assertion_key,
           'domain', pa.domain,
           'effective_at', pa.effective_at,
           'claimed_authority_at', pa.claimed_authority_at,
           'summary', 'Assertion effective date differs from the authority date stated in the claim.'
         ) AS warning
         FROM policy_assertions pa
         WHERE pa.assertion_type = 'source_of_truth_policy'
           AND pa.superseded_at IS NULL
           AND pa.effective_at IS NOT NULL
           AND pa.claimed_authority_at IS NOT NULL
           AND substring(pa.claimed_authority_at from 1 for 10) <> to_char(pa.effective_at, 'YYYY-MM-DD')
       ),
       duplicate_truth_warnings AS (
         SELECT json_build_object(
           'severity', 'high',
           'kind', 'duplicate_current_authority',
           'subject_node_id', subject_node_id_text,
           'scope_label', scope_label,
           'domain', domain,
           'count', COUNT(*)::int,
           'summary', 'More than one current source-of-truth policy exists for the same status domain.'
         ) AS warning
         FROM policy_assertions
         WHERE assertion_type = 'source_of_truth_policy'
           AND superseded_at IS NULL
           AND (effective_at IS NULL OR effective_at <= now())
           AND (effective_to IS NULL OR effective_to > now())
         GROUP BY subject_node_id_text, scope_label, domain
         HAVING COUNT(*) > 1
       ),
       duplicate_plugin_warnings AS (
         SELECT json_build_object(
           'severity', 'attention',
           'kind', 'duplicate_plugin_binding',
           'subject_node_id', subject_node_id_text,
           'scope_label', scope_label,
           'domain', assertion_key,
           'count', COUNT(*)::int,
           'summary', 'More than one current plugin_policy_binding exists for the same plugin on this scope.'
         ) AS warning
         FROM policy_assertions
         WHERE assertion_type = 'plugin_policy_binding'
           AND superseded_at IS NULL
           AND (effective_at IS NULL OR effective_at <= now())
           AND (effective_to IS NULL OR effective_to > now())
         GROUP BY subject_node_id_text, scope_label, assertion_key
         HAVING COUNT(*) > 1
       ),
       duplicate_constraint_warnings AS (
         SELECT json_build_object(
           'severity', 'high',
           'kind', 'multiple_current_constraints',
           'subject_node_id', subject_node_id_text,
           'scope_label', scope_label,
           'count', COUNT(*)::int,
           'summary', 'More than one current process_constraint exists for this scope.'
         ) AS warning
         FROM policy_assertions
         WHERE assertion_type = 'process_constraint'
           AND superseded_at IS NULL
           AND (effective_at IS NULL OR effective_at <= now())
           AND (effective_to IS NULL OR effective_to > now())
         GROUP BY subject_node_id_text, scope_label
         HAVING COUNT(*) > 1
       ),
       duplicate_improvement_warnings AS (
         SELECT json_build_object(
           'severity', 'high',
           'kind', 'multiple_current_improvement_cycles',
           'subject_node_id', subject_node_id_text,
           'scope_label', scope_label,
           'count', COUNT(*)::int,
           'summary', 'More than one current improvement cycle exists for this scope.'
         ) AS warning
         FROM policy_assertions
         WHERE assertion_type IN ('improvement_cycle', 'process_improvement_cycle')
           AND superseded_at IS NULL
           AND (effective_at IS NULL OR effective_at <= now())
           AND (effective_to IS NULL OR effective_to > now())
         GROUP BY subject_node_id_text, scope_label
         HAVING COUNT(*) > 1
       ),
       unexpected_plugin_warnings AS (
         SELECT json_build_object(
           'severity', 'attention',
           'kind', 'unexpected_plugin_binding',
           'subject_node_id', pb.scope_id,
           'scope_label', pb.scope_label,
           'assertion_id', pb.assertion_id,
           'domain', pb.plugin_id,
           'summary', 'Current plugin binding does not look like a Rye plugin ID. Review gates and source policies should be normal assertions, not pseudo-plugin bindings.'
         ) AS warning
         FROM plugin_bindings pb
         WHERE NOT pb.is_expected_plugin
       ),
       future_effective_warnings AS (
         SELECT json_build_object(
           'severity', 'attention',
           'kind', 'future_effective_policy',
           'subject_node_id', pa.subject_node_id_text,
           'scope_label', pa.scope_label,
           'assertion_id', pa.id_text,
           'assertion_type', pa.assertion_type,
           'assertion_key', pa.assertion_key,
           'effective_at', pa.effective_at,
           'summary', 'A non-superseded policy has a future effective date.'
         ) AS warning
         FROM policy_assertions pa
         WHERE pa.superseded_at IS NULL
           AND pa.effective_at > now()
           AND coalesce(pa.attrs->>'scheduled_future', 'false') <> 'true'
       ),
       missing_plugin_warnings AS (
         SELECT json_build_object(
           'severity', 'attention',
           'kind', 'missing_source_context_plugin',
           'subject_node_id', sr.id,
           'scope_label', sr.label,
           'summary', 'Scope has source-of-truth policy but no current rye-source-context plugin binding.'
         ) AS warning
         FROM scope_rows sr
         WHERE EXISTS (
           SELECT 1 FROM policy_assertions pa
           WHERE pa.subject_node_id::text = sr.id
             AND pa.assertion_type = 'source_of_truth_policy'
             AND pa.superseded_at IS NULL
             AND (pa.effective_at IS NULL OR pa.effective_at <= now())
         )
         AND NOT EXISTS (
           SELECT 1 FROM policy_assertions pa
           WHERE pa.subject_node_id::text = sr.id
             AND pa.assertion_type = 'plugin_policy_binding'
             AND pa.assertion_key = 'rye-source-context'
             AND pa.superseded_at IS NULL
         )
       ),
       empty_candidate_policy_warnings AS (
         SELECT json_build_object(
           'severity', 'attention',
           'kind', 'candidate_policy_without_candidates',
           'subject_node_id', sr.id,
           'scope_label', sr.label,
           'summary', 'Scope has current candidate/review policy, but no knowledge_candidate rows exist for review.'
         ) AS warning
         FROM scope_rows sr
         WHERE NOT EXISTS (SELECT 1 FROM candidate_base)
           AND EXISTS (
             SELECT 1
             FROM policy_assertions pa
             WHERE pa.subject_node_id::text = sr.id
               AND pa.superseded_at IS NULL
               AND pa.assertion_type IN (
                 'accepted_knowledge_policy',
                 'candidate_review_policy',
                 'candidate_evidence_policy',
                 'review_policy',
                 'review_gate',
                 'review_gate_policy',
                 'evidence_policy'
               )
               AND pa.claim::text ILIKE '%candidate%'
               AND (
                 pa.claim::text ILIKE '%patient%'
                 OR pa.claim::text ILIKE '%case%'
                 OR pa.claim::text ILIKE '%shipment%'
                 OR pa.claim::text ILIKE '%order%'
               )
           )
       ),
       warnings AS (
         SELECT warning FROM authority_date_warnings
         UNION ALL SELECT warning FROM duplicate_truth_warnings
         UNION ALL SELECT warning FROM duplicate_plugin_warnings
         UNION ALL SELECT warning FROM duplicate_constraint_warnings
         UNION ALL SELECT warning FROM duplicate_improvement_warnings
         UNION ALL SELECT warning FROM unexpected_plugin_warnings
         UNION ALL SELECT warning FROM future_effective_warnings
         UNION ALL SELECT warning FROM missing_plugin_warnings
         UNION ALL SELECT warning FROM empty_candidate_policy_warnings
       )
       SELECT json_build_object(
         'generated_at', now(),
         'scopes', COALESCE((SELECT json_agg(sr ORDER BY sr.label) FROM scope_rows sr), '[]'::json),
         'current_process', COALESCE((SELECT json_agg(cp) FROM current_process cp), '[]'::json),
         'future_process', COALESCE((SELECT json_agg(fp) FROM future_process fp), '[]'::json),
         'historical_process', COALESCE((SELECT json_agg(hp) FROM historical_process hp), '[]'::json),
         'candidate_statuses', COALESCE((SELECT json_agg(cs) FROM candidate_statuses cs), '[]'::json),
         'candidate_samples', COALESCE((SELECT json_agg(c) FROM candidate_samples c), '[]'::json),
         'plugin_bindings', COALESCE((SELECT json_agg(pb) FROM plugin_bindings pb), '[]'::json),
         'operational_plans', COALESCE((SELECT json_agg(op) FROM operational_plans op), '[]'::json),
         'warnings', COALESCE((SELECT json_agg(w.warning) FROM warnings w), '[]'::json),
         'stats', json_build_object(
           'scope_count', (SELECT COUNT(*)::int FROM scope_rows),
           'current_process_count', (SELECT COUNT(*)::int FROM current_process),
           'future_process_count', (SELECT COUNT(*)::int FROM future_process),
           'historical_process_count', (SELECT COUNT(*)::int FROM historical_process),
           'candidate_count', (SELECT COUNT(*)::int FROM candidate_base),
           'plugin_binding_count', (SELECT COUNT(*)::int FROM plugin_bindings),
           'operational_plan_count', (SELECT COUNT(*)::int FROM operational_plans),
           'warning_count', (SELECT COUNT(*)::int FROM warnings)
         )
       ) AS payload
       FROM cfg`
  );
  return rows[0]?.payload as KnowledgeMapResult;
}

export interface CandidateReviewQueueOptions {
  status?: string | null;
  kind?: string | null;
  q?: string | null;
  includeClosed?: boolean;
  limit?: number;
  offset?: number;
  agentId?: string | null;
}

export async function fetchCandidateReviewQueue(
  sql: Sql,
  opts: CandidateReviewQueueOptions = {}
) {
  const rows = await sql.unsafe(
    withAdminCte() +
      `, candidate_source AS (
         SELECT
           n.id,
           n.id::text AS id_text,
           n.label,
           n.properties,
           n.attrs,
           n.created_at,
           COALESCE(status.claim->>'status', 'proposed') AS status,
           status.claim AS status_claim,
           n.properties->>'candidate_kind' AS candidate_kind,
           n.properties->>'statement' AS statement,
           n.properties->>'normalized_key' AS normalized_key,
           n.properties->>'created_by' AS created_by,
           n.properties->>'confidence' AS confidence_text,
           ARRAY(
             SELECT DISTINCT rye.rye_slugify_key(value)
             FROM jsonb_array_elements_text(
               CASE
                 WHEN jsonb_typeof(n.properties->'target_payload'->'domain_keys') = 'array'
                   THEN n.properties->'target_payload'->'domain_keys'
                 ELSE '[]'::jsonb
               END
             ) AS value
             WHERE rye.rye_slugify_key(value) IS NOT NULL
           ) AS domain_keys,
           nullif(trim(n.properties->'target_payload'->>'source_scope'), '') AS source_scope
         FROM rye.nodes n
         LEFT JOIN rye.current_valid_assertions status
           ON status.subject_node_id = n.id
          AND status.assertion_type = 'candidate_status'
          AND status.assertion_key = 'default'
         WHERE n.node_type = 'knowledge_candidate'
           AND n.archived_at IS NULL
       ),
       candidate_base AS (
         SELECT *
         FROM candidate_source cs
         WHERE $7::uuid IS NULL
            OR (
              cardinality(cs.domain_keys) > 0
              AND rye.has_agent_capability(
                $7::uuid,
                'rye.review.read',
                cs.domain_keys,
                cs.source_scope
              )
            )
       ),
       filtered AS (
         SELECT *
         FROM candidate_base cb
         WHERE ($1::text IS NULL OR cb.status = $1::text)
           AND ($2::text IS NULL OR cb.candidate_kind = $2::text)
           AND (
             $5::boolean
             OR cb.status NOT IN ('accepted', 'rejected', 'duplicate', 'superseded')
           )
           AND (
             nullif(trim(coalesce($3::text, '')), '') IS NULL
             OR cb.statement ILIKE '%' || $3::text || '%'
             OR cb.label ILIKE '%' || $3::text || '%'
             OR cb.normalized_key ILIKE '%' || $3::text || '%'
             OR cb.properties::text ILIKE '%' || $3::text || '%'
           )
       ),
       candidate_rows AS (
         SELECT
           f.id_text AS id,
           f.label,
           f.properties,
           f.attrs,
           f.created_at,
           f.status,
           f.status_claim,
           COALESCE((
             SELECT json_agg(json_build_object(
               'id', ctx.id::text,
               'label', ctx.label,
               'node_type', ctx.node_type
             ) ORDER BY ctx.label)
             FROM jsonb_array_elements_text(coalesce(f.properties->'review_context_ids', '[]'::jsonb)) ctx_ids(id_text)
             JOIN rye.nodes ctx ON ctx.id::text = ctx_ids.id_text
             WHERE ctx.archived_at IS NULL
           ), '[]'::json) AS review_contexts,
           COALESCE((
             SELECT json_agg(json_build_object(
               'id', n.id::text,
               'label', n.label,
               'node_type', n.node_type,
               'edge_type', e.edge_type
             ) ORDER BY e.edge_type, n.label)
             FROM rye.edges e
             JOIN rye.nodes n ON n.id = e.target_id
             WHERE e.source_id = f.id
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
             WHERE e.source_id = f.id
               AND e.edge_type = 'promoted_to'
               AND e.archived_at IS NULL
           ), '[]'::json) AS promoted_targets,
           COALESCE((
             SELECT json_agg(json_build_object(
               'status', a.claim->>'status',
               'reason', a.claim->>'reason',
               'actor', a.claim->>'actor',
               'status_at', a.claim->>'status_at',
               'assertion_id', a.id::text
             ) ORDER BY a.created_at DESC)
             FROM rye.assertions a
             WHERE a.subject_node_id = f.id
               AND a.assertion_type = 'candidate_status'
           ), '[]'::json) AS status_history
         FROM filtered f
         ORDER BY
           CASE f.status
             WHEN 'needs_review' THEN 0
             WHEN 'proposed' THEN 1
             ELSE 2
           END,
           f.created_at DESC
         LIMIT $4::int
         OFFSET $6::int
       ),
       status_counts AS (
         SELECT status, COUNT(*)::int AS count
         FROM candidate_base
         GROUP BY status
       ),
       kind_counts AS (
         SELECT candidate_kind AS kind, COUNT(*)::int AS count
         FROM candidate_base
         GROUP BY candidate_kind
       )
       SELECT json_build_object(
         'candidates', COALESCE((SELECT json_agg(cr ORDER BY cr.created_at DESC) FROM candidate_rows cr), '[]'::json),
         'statuses', COALESCE((SELECT json_agg(sc ORDER BY sc.count DESC, sc.status) FROM status_counts sc), '[]'::json),
         'kinds', COALESCE((SELECT json_agg(kc ORDER BY kc.count DESC, kc.kind) FROM kind_counts kc), '[]'::json),
         'stats', json_build_object(
           'total', (SELECT COUNT(*)::int FROM candidate_base),
           'filtered', (SELECT COUNT(*)::int FROM filtered),
           'open', (SELECT COUNT(*)::int FROM candidate_base WHERE status IN ('proposed', 'needs_review')),
           'accepted', (SELECT COUNT(*)::int FROM candidate_base WHERE status = 'accepted'),
           'rejected', (SELECT COUNT(*)::int FROM candidate_base WHERE status IN ('rejected', 'duplicate', 'superseded'))
         )
       ) AS payload
       FROM cfg`,
    [
      opts.status && opts.status !== "all" ? opts.status : null,
      opts.kind && opts.kind !== "all" ? opts.kind : null,
      opts.q ?? null,
      opts.limit ?? 80,
      opts.includeClosed ?? false,
      opts.offset ?? 0,
      opts.agentId ?? null,
    ]
  );
  return rows[0]?.payload ?? {
    candidates: [],
    statuses: [],
    kinds: [],
    stats: { total: 0, filtered: 0, open: 0, accepted: 0, rejected: 0 },
  };
}

export async function fetchCrmWorkspace(sql: Sql) {
  const rows = await sql.unsafe(
    withAdminCte() +
      `, opportunities AS (
         SELECT
           oa.node_id::text AS id,
           oa.label,
           oa.code,
           oa.name,
           oa.stage,
           oa.pipeline,
           oa.assigned_to_name,
           oa.primary_contact_name,
           oa.current_value,
           oa.win_probability,
           COALESCE(next_action.claim->>'next_action', next_action.claim->>'action') AS next_action,
           COALESCE(related.related_items, '[]'::json) AS related_items,
           oa.created_at
         FROM rye.opportunities_active oa
         LEFT JOIN rye.current_valid_assertions next_action
           ON next_action.subject_node_id = oa.node_id
          AND next_action.assertion_type = 'next_sales_action'
          AND next_action.assertion_key = 'default'
         LEFT JOIN LATERAL (
           SELECT json_agg(json_build_object(
             'id', item.id,
             'label', item.label,
             'node_type', item.node_type,
             'relation', item.edge_type,
             'direction', item.direction,
             'role', item.properties->>'role',
             'relationship', item.properties->>'relationship',
             'context', item.properties->>'context',
             'reason', item.properties->>'reason'
           ) ORDER BY item.sort_order, item.label) AS related_items
           FROM (
             SELECT
               n.id::text AS id,
               n.label,
               n.node_type,
               e.edge_type,
               e.properties,
               'out' AS direction,
               1 AS sort_order
             FROM rye.edges e
             JOIN rye.nodes n ON n.id = e.target_id
             WHERE e.source_id = oa.node_id
               AND e.archived_at IS NULL
               AND n.archived_at IS NULL
               AND e.edge_type IN ('primary_contact', 'customer_account', 'venue_under_review', 'agency_review', 'assigned_to', 'regarding', 'depends_on')
             UNION ALL
             SELECT
               n.id::text AS id,
               n.label,
               n.node_type,
               e.edge_type,
               e.properties,
               'in' AS direction,
               2 AS sort_order
             FROM rye.edges e
             JOIN rye.nodes n ON n.id = e.source_id
             WHERE e.target_id = oa.node_id
               AND e.archived_at IS NULL
               AND n.archived_at IS NULL
               AND e.edge_type IN ('regarding', 'depends_on', 'blocks')
           ) item
         ) related ON true
         CROSS JOIN cfg
         ORDER BY
           CASE oa.stage
             WHEN 'prospecting' THEN 1
             WHEN 'qualification' THEN 2
             WHEN 'site_survey_completed' THEN 3
             WHEN 'proposal_sent' THEN 4
             WHEN 'contract_review' THEN 5
             WHEN 'negotiation' THEN 6
             ELSE 20
           END,
           oa.created_at DESC
       ),
       plans AS (
         SELECT
           a.id::text AS id,
           a.subject_node_id::text AS subject_id,
           a.assertion_type,
           a.assertion_key,
           a.claim,
           a.effective_at,
           a.created_at
         FROM rye.current_valid_assertions a
         WHERE a.assertion_type = 'deal_stage_plan'
       ),
       source_policies AS (
         SELECT
           a.id::text AS id,
           a.subject_node_id::text AS scope_id,
           n.label AS scope_label,
           a.assertion_key,
           a.claim,
           a.effective_at,
           a.created_at
         FROM rye.assertions a
         JOIN rye.nodes n ON n.id = a.subject_node_id
         WHERE a.assertion_type = 'source_of_truth_policy'
           AND a.superseded_at IS NULL
           AND a.claim->>'status_domain' IN ('deal_stage', 'sales_next_action')
         ORDER BY a.effective_at NULLS FIRST, a.created_at DESC
       ),
       candidate_base AS (
         SELECT
           c.id,
           c.id::text AS id_text,
           c.label,
           c.properties,
           c.created_at,
           COALESCE(status.claim->>'status', 'proposed') AS status
         FROM rye.nodes c
         LEFT JOIN rye.current_valid_assertions status
           ON status.subject_node_id = c.id
          AND status.assertion_type = 'candidate_status'
          AND status.assertion_key = 'default'
         WHERE c.node_type = 'knowledge_candidate'
           AND c.archived_at IS NULL
       ),
       candidates AS (
         SELECT
           cb.id_text AS id,
           cb.label,
           cb.properties,
           cb.created_at,
           cb.status,
           COALESCE((
             SELECT json_agg(json_build_object(
               'id', src.id::text,
               'label', src.label,
               'node_type', src.node_type,
               'source_type', src.properties->>'source_type'
             ) ORDER BY src.label)
             FROM rye.edges support
             JOIN rye.nodes src ON src.id = support.target_id
             WHERE support.source_id = cb.id
               AND support.edge_type = 'supported_by'
               AND support.archived_at IS NULL
               AND src.archived_at IS NULL
           ), '[]'::json) AS sources,
           COALESCE((
             SELECT json_agg(json_build_object(
               'id', ctx.id::text,
               'label', ctx.label,
               'node_type', ctx.node_type
             ) ORDER BY ctx.label)
             FROM jsonb_array_elements_text(coalesce(cb.properties->'review_context_ids', '[]'::jsonb)) ctx_ids(id_text)
             JOIN rye.nodes ctx ON ctx.id::text = ctx_ids.id_text
             WHERE ctx.archived_at IS NULL
           ), '[]'::json) AS review_contexts
         FROM candidate_base cb
         WHERE cb.status IN ('proposed', 'needs_review')
           AND (
             coalesce(cb.properties->'target_payload', '{}'::jsonb) ? 'opportunity_id'
             OR coalesce(cb.properties->'target_payload', '{}'::jsonb) ? 'opportunityId'
             OR coalesce(cb.properties->'target_payload'->'target_payload', '{}'::jsonb) ? 'opportunity_id'
             OR coalesce(cb.properties->'target_payload'->'target_payload', '{}'::jsonb) ? 'opportunityId'
             OR coalesce(cb.properties->'target_payload', '{}'::jsonb)->>'record_type' = 'opportunity'
             OR coalesce(cb.properties->'target_payload', '{}'::jsonb)->>'record_type' = 'decision'
             OR cb.properties->>'statement' ILIKE '%opportunity%'
             OR cb.properties->>'statement' ILIKE '%deal_stage%'
             OR cb.properties->>'statement' ILIKE '%sales_next_action%'
             OR cb.properties->>'statement' ILIKE '%CRM%'
             OR cb.properties::text ILIKE '%BW-OPP-%'
             OR cb.properties::text ILIKE '%PipelinePro%'
             OR cb.properties::text ILIKE '%HearthCRM%'
           )
         ORDER BY cb.created_at DESC
         LIMIT 40
       )
       SELECT json_build_object(
         'generated_at', now(),
         'opportunities', COALESCE((SELECT json_agg(o) FROM opportunities o), '[]'::json),
         'plans', COALESCE((SELECT json_agg(p ORDER BY p.effective_at NULLS LAST, p.created_at DESC) FROM plans p), '[]'::json),
         'source_policies', COALESCE((SELECT json_agg(sp) FROM source_policies sp), '[]'::json),
         'candidates', COALESCE((SELECT json_agg(c) FROM candidates c), '[]'::json)
       ) AS payload
       FROM cfg`
  );
  return rows[0]?.payload ?? { opportunities: [], plans: [], source_policies: [], candidates: [] };
}

export async function fetchPmWorkspace(sql: Sql) {
  const rows = await sql.unsafe(
    withAdminCte() +
      `, tasks AS (
         SELECT
           tb.node_id::text AS id,
           tb.title,
           tb.code,
           tb.task_type,
           tb.due_date,
           tb.priority,
           tb.status,
           tb.owner_name,
           tb.reviewer_name,
           tb.project_name,
           tb.project_code,
           tb.sprint_name,
           tb.blocker_count,
           tb.subtask_count,
           COALESCE(related.related_items, '[]'::json) AS related_items,
           tb.created_at
         FROM rye.task_board tb
         LEFT JOIN LATERAL (
           SELECT json_agg(json_build_object(
             'id', item.id,
             'label', item.label,
             'node_type', item.node_type,
             'relation', item.edge_type,
             'direction', item.direction,
             'role', item.properties->>'role',
             'relationship', item.properties->>'relationship',
             'context', item.properties->>'context',
             'dependency_type', item.properties->>'dependency_type',
             'reason', item.properties->>'reason'
           ) ORDER BY item.sort_order, item.label) AS related_items
           FROM (
             SELECT
               n.id::text AS id,
               n.label,
               n.node_type,
               e.edge_type,
               e.properties,
               'out' AS direction,
               1 AS sort_order
             FROM rye.edges e
             JOIN rye.nodes n ON n.id = e.target_id
             WHERE e.source_id = tb.node_id
               AND e.archived_at IS NULL
               AND n.archived_at IS NULL
               AND e.edge_type IN ('assigned_to', 'regarding', 'depends_on', 'blocks', 'collaborates_on')
             UNION ALL
             SELECT
               n.id::text AS id,
               n.label,
               n.node_type,
               e.edge_type,
               e.properties,
               'in' AS direction,
               2 AS sort_order
             FROM rye.edges e
             JOIN rye.nodes n ON n.id = e.source_id
             WHERE e.target_id = tb.node_id
               AND e.archived_at IS NULL
               AND n.archived_at IS NULL
               AND e.edge_type IN ('contains', 'depends_on', 'blocks', 'regarding', 'collaborates_on', 'vendor_for', 'reviewed_by')
           ) item
         ) related ON true
         CROSS JOIN cfg
         WHERE COALESCE(tb.task_type, '') NOT IN ('evidence_review', 'source_verification')
         ORDER BY
           CASE tb.status
             WHEN 'blocked' THEN 0
             WHEN 'backlog' THEN 1
             WHEN 'todo' THEN 2
             WHEN 'in_progress' THEN 3
             WHEN 'ready_for_install' THEN 4
             WHEN 'in_review' THEN 5
             WHEN 'done' THEN 6
             ELSE 20
           END,
           tb.due_date NULLS LAST,
           tb.created_at DESC
       ),
       milestones AS (
         SELECT
           n.id::text AS id,
           n.label,
           n.properties->>'code' AS code,
           COALESCE(n.properties->>'name', n.properties->>'title', n.label) AS name,
           n.properties->>'target_date' AS target_date,
           n.properties->>'priority' AS priority,
           status.claim->>'status' AS status,
           status.claim AS status_claim,
           owner.label AS owner_name,
           owner.id AS owner_id,
           COALESCE(related.related_items, '[]'::json) AS related_items,
           n.created_at
         FROM rye.nodes n
         LEFT JOIN rye.current_valid_assertions status
           ON status.subject_node_id = n.id
          AND status.assertion_type = 'milestone_status'
          AND status.assertion_key = 'default'
         LEFT JOIN LATERAL (
           SELECT own_n.id, own_n.label
           FROM rye.edges own_e
           JOIN rye.nodes own_n ON own_n.id = own_e.target_id
           WHERE own_e.source_id = n.id
             AND own_e.edge_type = 'assigned_to'
             AND own_e.properties->>'role' = 'owner'
             AND own_e.archived_at IS NULL
             AND (own_e.effective_from IS NULL OR own_e.effective_from <= now())
             AND (own_e.effective_to IS NULL OR own_e.effective_to > now())
           ORDER BY own_e.effective_from DESC NULLS LAST, own_e.created_at DESC
           LIMIT 1
         ) owner ON true
         LEFT JOIN LATERAL (
           SELECT json_agg(json_build_object(
             'id', item.id,
             'label', item.label,
             'node_type', item.node_type,
             'relation', item.edge_type,
             'direction', item.direction,
             'role', item.properties->>'role',
             'relationship', item.properties->>'relationship',
             'context', item.properties->>'context',
             'dependency_type', item.properties->>'dependency_type',
             'reason', item.properties->>'reason'
           ) ORDER BY item.sort_order, item.label) AS related_items
           FROM (
             SELECT
               related_node.id::text AS id,
               related_node.label,
               related_node.node_type,
               e.edge_type,
               e.properties,
               'out' AS direction,
               1 AS sort_order
             FROM rye.edges e
             JOIN rye.nodes related_node ON related_node.id = e.target_id
             WHERE e.source_id = n.id
               AND e.archived_at IS NULL
               AND related_node.archived_at IS NULL
               AND e.edge_type IN ('assigned_to', 'regarding', 'depends_on', 'blocks')
             UNION ALL
             SELECT
               related_node.id::text AS id,
               related_node.label,
               related_node.node_type,
               e.edge_type,
               e.properties,
               'in' AS direction,
               2 AS sort_order
             FROM rye.edges e
             JOIN rye.nodes related_node ON related_node.id = e.source_id
             WHERE e.target_id = n.id
               AND e.archived_at IS NULL
               AND related_node.archived_at IS NULL
               AND e.edge_type IN ('contains', 'depends_on', 'blocks', 'regarding', 'reviewed_by')
           ) item
         ) related ON true
         WHERE n.node_type = 'milestone'
           AND n.archived_at IS NULL
         ORDER BY target_date NULLS LAST, n.created_at DESC
       ),
       plans AS (
         SELECT
           a.id::text AS id,
           a.subject_node_id::text AS subject_id,
           n.label AS subject_label,
           n.node_type AS subject_type,
           a.assertion_type,
           a.assertion_key,
           a.claim,
           a.effective_at,
           a.created_at
         FROM rye.current_valid_assertions a
         JOIN rye.nodes n ON n.id = a.subject_node_id
         WHERE a.assertion_type IN ('task_status_plan', 'milestone_status_plan')
           AND n.archived_at IS NULL
       ),
       source_policies AS (
         SELECT
           a.id::text AS id,
           a.subject_node_id::text AS scope_id,
           n.label AS scope_label,
           a.assertion_key,
           a.claim,
           a.effective_at,
           a.created_at
         FROM rye.assertions a
         JOIN rye.nodes n ON n.id = a.subject_node_id
         WHERE a.assertion_type = 'source_of_truth_policy'
           AND a.superseded_at IS NULL
           AND a.claim->>'status_domain' IN ('project_task_status', 'project_milestone_status')
         ORDER BY a.effective_at NULLS FIRST, a.created_at DESC
       ),
       candidate_base AS (
         SELECT
           c.id,
           c.id::text AS id_text,
           c.label,
           c.properties,
           c.created_at,
           COALESCE(status.claim->>'status', 'proposed') AS status
         FROM rye.nodes c
         LEFT JOIN rye.current_valid_assertions status
           ON status.subject_node_id = c.id
          AND status.assertion_type = 'candidate_status'
          AND status.assertion_key = 'default'
         WHERE c.node_type = 'knowledge_candidate'
           AND c.archived_at IS NULL
       ),
       candidates AS (
         SELECT
           cb.id_text AS id,
           cb.label,
           cb.properties,
           cb.created_at,
           cb.status,
           COALESCE((
             SELECT json_agg(json_build_object(
               'id', src.id::text,
               'label', src.label,
               'node_type', src.node_type,
               'source_type', src.properties->>'source_type'
             ) ORDER BY src.label)
             FROM rye.edges support
             JOIN rye.nodes src ON src.id = support.target_id
             WHERE support.source_id = cb.id
               AND support.edge_type = 'supported_by'
               AND support.archived_at IS NULL
               AND src.archived_at IS NULL
           ), '[]'::json) AS sources,
           COALESCE((
             SELECT json_agg(json_build_object(
               'id', ctx.id::text,
               'label', ctx.label,
               'node_type', ctx.node_type
             ) ORDER BY ctx.label)
             FROM jsonb_array_elements_text(coalesce(cb.properties->'review_context_ids', '[]'::jsonb)) ctx_ids(id_text)
             JOIN rye.nodes ctx ON ctx.id::text = ctx_ids.id_text
             WHERE ctx.archived_at IS NULL
           ), '[]'::json) AS review_contexts
         FROM candidate_base cb
         WHERE cb.status IN ('proposed', 'needs_review')
           AND (
             coalesce(cb.properties->'target_payload', '{}'::jsonb) ? 'task_id'
             OR coalesce(cb.properties->'target_payload', '{}'::jsonb) ? 'taskId'
             OR coalesce(cb.properties->'target_payload', '{}'::jsonb) ? 'milestone_id'
             OR coalesce(cb.properties->'target_payload', '{}'::jsonb) ? 'milestoneId'
             OR coalesce(cb.properties->'target_payload'->'target_payload', '{}'::jsonb) ? 'task_id'
             OR coalesce(cb.properties->'target_payload'->'target_payload', '{}'::jsonb) ? 'taskId'
             OR coalesce(cb.properties->'target_payload'->'target_payload', '{}'::jsonb) ? 'milestone_id'
             OR coalesce(cb.properties->'target_payload'->'target_payload', '{}'::jsonb) ? 'milestoneId'
             OR coalesce(cb.properties->'target_payload', '{}'::jsonb)->>'record_type' IN ('task', 'milestone', 'decision')
             OR cb.properties->>'statement' ILIKE '%task%'
             OR cb.properties->>'statement' ILIKE '%milestone%'
             OR cb.properties->>'statement' ILIKE '%project_task_status%'
             OR cb.properties->>'statement' ILIKE '%project_milestone_status%'
             OR cb.properties::text ILIKE '%BW-TSK-%'
             OR cb.properties::text ILIKE '%BW-MIL-%'
             OR cb.properties::text ILIKE '%BuildBoard%'
             OR cb.properties::text ILIKE '%JobBoardPM%'
           )
         ORDER BY cb.created_at DESC
         LIMIT 50
       )
       SELECT json_build_object(
         'generated_at', now(),
         'tasks', COALESCE((SELECT json_agg(t) FROM tasks t), '[]'::json),
         'milestones', COALESCE((SELECT json_agg(m) FROM milestones m), '[]'::json),
         'plans', COALESCE((SELECT json_agg(p ORDER BY p.effective_at NULLS LAST, p.created_at DESC) FROM plans p), '[]'::json),
         'source_policies', COALESCE((SELECT json_agg(sp) FROM source_policies sp), '[]'::json),
         'candidates', COALESCE((SELECT json_agg(c) FROM candidates c), '[]'::json)
       ) AS payload
       FROM cfg`
  );
  return rows[0]?.payload ?? { tasks: [], milestones: [], plans: [], source_policies: [], candidates: [] };
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
  domain_keys?: string[];
  source_scope?: string | null;
  impact_scope?: string | null;
  authority_basis?: string | null;
  speech_act?: string | null;
  current_or_future?: string | null;
  evidence_refs?: unknown;
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
      jsonParam(input.target_payload ?? {}),
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

export async function createAgentKnowledgeCandidate(
  sql: Sql,
  agentId: string,
  input: CreateKnowledgeCandidateInput,
  idempotencyKey?: string | null
): Promise<{ id: string }> {
  const targetPayload = input.target_payload ?? {};
  const domainKeys = input.domain_keys ?? (
    Array.isArray(targetPayload.domain_keys) ? (targetPayload.domain_keys as string[]) : []
  );
  const rows = await sql.unsafe(
    withAdminCte() +
      `SELECT rye.agent_create_candidate(
         p_agent_id               := $1::uuid,
         p_candidate_kind         := $2::text,
         p_statement              := $3::text,
         p_target_payload         := $4::jsonb,
         p_domain_keys            := $5::text[],
         p_source_scope           := $6::text,
         p_impact_scope           := $7::text,
         p_authority_basis        := $8::text,
         p_speech_act             := $9::text,
         p_current_or_future      := $10::text,
         p_evidence_refs          := $11::jsonb,
         p_review_context_ids     := $12::uuid[],
         p_normalized_key         := $13::text,
         p_source_node_ids        := $14::uuid[],
         p_derived_from_node_ids  := $15::uuid[],
         p_confidence             := $16::numeric,
         p_idempotency_key        := $17::text
       )::text AS id
       FROM cfg`,
    [
      agentId,
      input.candidate_kind,
      input.statement,
      jsonParam(targetPayload),
      domainKeys,
      input.source_scope ?? (typeof targetPayload.source_scope === "string" ? targetPayload.source_scope : null),
      input.impact_scope ?? (typeof targetPayload.impact_scope === "string" ? targetPayload.impact_scope : null),
      input.authority_basis ?? (typeof targetPayload.authority_basis === "string" ? targetPayload.authority_basis : null),
      input.speech_act ?? (typeof targetPayload.speech_act === "string" ? targetPayload.speech_act : null),
      input.current_or_future ??
        (typeof targetPayload.current_or_future === "string" ? targetPayload.current_or_future : "current"),
      jsonParam(input.evidence_refs ?? targetPayload.evidence_refs ?? []),
      input.review_context_ids ?? [],
      input.normalized_key ?? null,
      input.source_node_ids ?? [],
      input.derived_from_node_ids ?? [],
      input.confidence ?? null,
      idempotencyKey ?? null,
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
        jsonParam(input.claim),
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
      [candidateId, input.label, jsonParam(input.properties ?? {}), input.actor ?? null]
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
      jsonParam(input.properties ?? {}),
      input.effective_from ?? null,
      input.effective_to ?? null,
      input.actor ?? null,
    ]
  );
  return { target_type: "edge", id: rows[0]?.id as string };
}

export interface AcceptSourcePolicyCandidateInput {
  scope_id: string;
  status_domains: string[];
  authoritative_source: string;
  effective_at?: string | null;
  review_gate?: string | null;
  evidence_allowed?: string[];
  supersedes?: string | null;
  notes?: string | null;
  actor?: string | null;
}

export async function acceptSourcePolicyCandidate(
  sql: Sql,
  candidateId: string,
  input: AcceptSourcePolicyCandidateInput
): Promise<{ target_type: "source_policy"; ids: string[]; subject_node_id: string }> {
  const domains = Array.from(
    new Set(input.status_domains.map((domain) => domain.trim()).filter(Boolean))
  );
  if (domains.length === 0) throw new Error("At least one status domain is required");

  const rows = await sql.unsafe(
    withAdminCte() +
      `, domains AS MATERIALIZED (
         SELECT DISTINCT nullif(trim(value), '') AS domain
         FROM unnest($3::text[]) AS value
         WHERE nullif(trim(value), '') IS NOT NULL
       ),
       policies AS MATERIALIZED (
         SELECT
           d.domain,
           rye.record_source_of_truth_policy(
             p_scope_id              := $2::uuid,
             p_status_domain         := d.domain,
             p_authoritative_source  := $4::text,
             p_effective_at          := $5::timestamptz,
             p_review_gate           := $6::text,
             p_evidence_allowed      := $7::text[],
             p_supersedes            := $8::text,
             p_notes                 := $9::text,
             p_actor                 := $10::text
           ) AS assertion_id
         FROM cfg, domains d
       ),
       status_update AS (
         SELECT rye.set_candidate_status(
           p_candidate_id := $1::uuid,
           p_status       := 'accepted',
           p_reason       := format(
             'Accepted as %s source-of-truth polic%s: %s',
             COUNT(*)::int,
             CASE WHEN COUNT(*) = 1 THEN 'y' ELSE 'ies' END,
             string_agg(assertion_id::text, ', ' ORDER BY domain)
           ),
           p_actor        := $10::text
         ) AS status_assertion_id
         FROM policies
       ),
       link AS (
         INSERT INTO rye.edges (edge_type, source_id, target_id, properties, attrs)
         SELECT
           'promoted_to',
           $1::uuid,
           $2::uuid,
           jsonb_build_object(
             'target_type', 'source_of_truth_policy',
             'assertion_ids', p.assertion_ids,
             'status_domains', p.status_domains
           ),
           jsonb_build_object('candidate_id', $1::uuid)
         FROM (
           SELECT
             jsonb_agg(assertion_id::text ORDER BY domain) AS assertion_ids,
             jsonb_agg(domain ORDER BY domain) AS status_domains
           FROM policies
         ) p
         WHERE p.assertion_ids IS NOT NULL
           AND NOT EXISTS (
             SELECT 1 FROM rye.edges e
             WHERE e.source_id = $1::uuid
               AND e.target_id = $2::uuid
               AND e.edge_type = 'promoted_to'
               AND e.archived_at IS NULL
           )
         RETURNING id
       )
       SELECT COALESCE(json_agg(p.assertion_id::text ORDER BY p.domain), '[]'::json) AS ids,
              (SELECT COUNT(*)::int FROM link) AS link_count
       FROM policies p
       CROSS JOIN status_update`,
    [
      candidateId,
      input.scope_id,
      domains,
      input.authoritative_source,
      input.effective_at ?? null,
      input.review_gate ?? null,
      input.evidence_allowed ?? [],
      input.supersedes ?? null,
      input.notes ?? null,
      input.actor ?? null,
    ]
  );
  return {
    target_type: "source_policy",
    ids: (rows[0]?.ids ?? []) as string[],
    subject_node_id: input.scope_id,
  };
}

export interface AcceptCrmStagePlanCandidateInput {
  opportunity_id: string;
  stage: string;
  effective_at: string;
  reason?: string | null;
  actor?: string | null;
  plan_properties?: Record<string, unknown>;
}

export async function acceptCrmStagePlanCandidate(
  sql: Sql,
  candidateId: string,
  input: AcceptCrmStagePlanCandidateInput
): Promise<{ target_type: "crm_stage_plan"; id: string; subject_node_id: string }> {
  const rows = await sql.unsafe(
    withAdminCte() +
      `, scheduled AS (
         SELECT rye.schedule_deal_stage_change(
           p_opp_id          := $2::uuid,
           p_stage           := $3::text,
           p_effective_at    := $4::timestamptz,
           p_reason          := $5::text,
           p_actor           := $6::text,
           p_plan_properties := $7::jsonb
         ) AS assertion_id
         FROM cfg
       ),
       status_update AS (
         SELECT rye.set_candidate_status(
           p_candidate_id := $1::uuid,
           p_status       := 'accepted',
           p_reason       := 'Accepted as scheduled CRM stage change ' || assertion_id::text,
           p_actor        := $6::text
         ) AS status_assertion_id
         FROM scheduled
       ),
       link AS (
         INSERT INTO rye.edges (edge_type, source_id, target_id, properties, attrs)
         SELECT
           'promoted_to',
           $1::uuid,
           $2::uuid,
           jsonb_build_object(
             'target_type', 'crm_stage_plan',
             'scheduled_assertion_id', assertion_id,
             'stage', $3::text,
             'effective_at', $4::timestamptz
           ),
           jsonb_build_object('candidate_id', $1::uuid)
         FROM scheduled
         WHERE NOT EXISTS (
           SELECT 1 FROM rye.edges e
           WHERE e.source_id = $1::uuid
             AND e.target_id = $2::uuid
             AND e.edge_type = 'promoted_to'
             AND e.archived_at IS NULL
         )
         RETURNING id
       )
       SELECT scheduled.assertion_id::text AS id,
              (SELECT COUNT(*)::int FROM link) AS link_count
       FROM scheduled
       CROSS JOIN status_update`,
    [
      candidateId,
      input.opportunity_id,
      input.stage,
      input.effective_at,
      input.reason ?? null,
      input.actor ?? null,
      jsonParam(input.plan_properties ?? {}),
    ]
  );
  return { target_type: "crm_stage_plan", id: rows[0]?.id as string, subject_node_id: input.opportunity_id };
}

export interface AcceptPmTaskPlanCandidateInput {
  task_id: string;
  status: string;
  effective_at: string;
  reason?: string | null;
  actor?: string | null;
  plan_properties?: Record<string, unknown>;
}

export async function acceptPmTaskPlanCandidate(
  sql: Sql,
  candidateId: string,
  input: AcceptPmTaskPlanCandidateInput
): Promise<{ target_type: "pm_task_plan"; id: string; subject_node_id: string }> {
  const rows = await sql.unsafe(
    withAdminCte() +
      `, scheduled AS (
         SELECT rye.schedule_task_status_change(
           p_task_id         := $2::uuid,
           p_status          := $3::text,
           p_effective_at    := $4::timestamptz,
           p_reason          := $5::text,
           p_actor           := $6::text,
           p_plan_properties := $7::jsonb
         ) AS assertion_id
         FROM cfg
       ),
       status_update AS (
         SELECT rye.set_candidate_status(
           p_candidate_id := $1::uuid,
           p_status       := 'accepted',
           p_reason       := 'Accepted as scheduled PM task status change ' || assertion_id::text,
           p_actor        := $6::text
         ) AS status_assertion_id
         FROM scheduled
       ),
       link AS (
         INSERT INTO rye.edges (edge_type, source_id, target_id, properties, attrs)
         SELECT
           'promoted_to',
           $1::uuid,
           $2::uuid,
           jsonb_build_object(
             'target_type', 'pm_task_plan',
             'scheduled_assertion_id', assertion_id,
             'status', $3::text,
             'effective_at', $4::timestamptz
           ),
           jsonb_build_object('candidate_id', $1::uuid)
         FROM scheduled
         WHERE NOT EXISTS (
           SELECT 1 FROM rye.edges e
           WHERE e.source_id = $1::uuid
             AND e.target_id = $2::uuid
             AND e.edge_type = 'promoted_to'
             AND e.archived_at IS NULL
         )
         RETURNING id
       )
       SELECT scheduled.assertion_id::text AS id,
              (SELECT COUNT(*)::int FROM link) AS link_count
       FROM scheduled
       CROSS JOIN status_update`,
    [
      candidateId,
      input.task_id,
      input.status,
      input.effective_at,
      input.reason ?? null,
      input.actor ?? null,
      jsonParam(input.plan_properties ?? {}),
    ]
  );
  return { target_type: "pm_task_plan", id: rows[0]?.id as string, subject_node_id: input.task_id };
}

export interface AcceptPmMilestonePlanCandidateInput {
  milestone_id: string;
  status: string;
  effective_at: string;
  reason?: string | null;
  actor?: string | null;
  plan_properties?: Record<string, unknown>;
}

export async function acceptPmMilestonePlanCandidate(
  sql: Sql,
  candidateId: string,
  input: AcceptPmMilestonePlanCandidateInput
): Promise<{ target_type: "pm_milestone_plan"; id: string; subject_node_id: string }> {
  const rows = await sql.unsafe(
    withAdminCte() +
      `, scheduled AS (
         SELECT rye.schedule_milestone_status_change(
           p_milestone_id    := $2::uuid,
           p_status          := $3::text,
           p_effective_at    := $4::timestamptz,
           p_reason          := $5::text,
           p_actor           := $6::text,
           p_plan_properties := $7::jsonb
         ) AS assertion_id
         FROM cfg
       ),
       status_update AS (
         SELECT rye.set_candidate_status(
           p_candidate_id := $1::uuid,
           p_status       := 'accepted',
           p_reason       := 'Accepted as scheduled PM milestone status change ' || assertion_id::text,
           p_actor        := $6::text
         ) AS status_assertion_id
         FROM scheduled
       ),
       link AS (
         INSERT INTO rye.edges (edge_type, source_id, target_id, properties, attrs)
         SELECT
           'promoted_to',
           $1::uuid,
           $2::uuid,
           jsonb_build_object(
             'target_type', 'pm_milestone_plan',
             'scheduled_assertion_id', assertion_id,
             'status', $3::text,
             'effective_at', $4::timestamptz
           ),
           jsonb_build_object('candidate_id', $1::uuid)
         FROM scheduled
         WHERE NOT EXISTS (
           SELECT 1 FROM rye.edges e
           WHERE e.source_id = $1::uuid
             AND e.target_id = $2::uuid
             AND e.edge_type = 'promoted_to'
             AND e.archived_at IS NULL
         )
         RETURNING id
       )
       SELECT scheduled.assertion_id::text AS id,
              (SELECT COUNT(*)::int FROM link) AS link_count
       FROM scheduled
       CROSS JOIN status_update`,
    [
      candidateId,
      input.milestone_id,
      input.status,
      input.effective_at,
      input.reason ?? null,
      input.actor ?? null,
      jsonParam(input.plan_properties ?? {}),
    ]
  );
  return { target_type: "pm_milestone_plan", id: rows[0]?.id as string, subject_node_id: input.milestone_id };
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
