import { useInstance } from "./instance";
import { useQuery } from "@tanstack/react-query";

const BASE = "/api";

async function get<T>(path: string, instance: string): Promise<T> {
  const url = new URL(path, window.location.origin);
  if (!url.searchParams.has("instance")) url.searchParams.set("instance", instance);
  const r = await fetch(url, { headers: { "x-rye-instance": instance } });
  if (!r.ok) throw new Error(`API ${path}: ${r.status} ${await r.text()}`);
  return (await r.json()) as T;
}

async function post<T>(path: string, instance: string, body: unknown): Promise<T> {
  const url = new URL(path, window.location.origin);
  if (!url.searchParams.has("instance")) url.searchParams.set("instance", instance);
  const r = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-rye-instance": instance },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`API ${path}: ${r.status} ${await r.text()}`);
  return (await r.json()) as T;
}

export function useDashboard() {
  const { current } = useInstance();
  return useQuery({
    queryKey: ["dashboard", current],
    queryFn: () =>
      get<DashboardResponse | ReconDashboardResponse | KnowledgeDashboardResponse>(
        `${BASE}/dashboard`,
        current
      ),
    enabled: !!current,
  });
}

export function useCatalog() {
  const { current } = useInstance();
  return useQuery({
    queryKey: ["catalog", current],
    queryFn: () => get<CatalogResponse>(`${BASE}/catalog`, current),
    enabled: !!current,
  });
}

export function useKnowledgeMap() {
  const { current } = useInstance();
  return useQuery({
    queryKey: ["knowledge-map", current],
    queryFn: () => get<KnowledgeMapResponse>(`${BASE}/knowledge-map`, current),
    enabled: !!current,
  });
}

export function useCrmWorkspace() {
  const { current } = useInstance();
  return useQuery({
    queryKey: ["crm-workspace", current],
    queryFn: () => get<CrmWorkspaceResponse>(`${BASE}/workspace/crm`, current),
    enabled: !!current,
  });
}

export function usePmWorkspace() {
  const { current } = useInstance();
  return useQuery({
    queryKey: ["pm-workspace", current],
    queryFn: () => get<PmWorkspaceResponse>(`${BASE}/workspace/pm`, current),
    enabled: !!current,
  });
}

export interface CandidateReviewQueueOptions {
  status?: string;
  kind?: string;
  q?: string;
  includeClosed?: boolean;
  limit?: number;
  offset?: number;
}

export function useCandidateReviewQueue(opts: CandidateReviewQueueOptions = {}) {
  const { current } = useInstance();
  return useQuery({
    queryKey: ["candidate-review", current, opts],
    queryFn: () => {
      const params = new URLSearchParams();
      if (opts.status && opts.status !== "all") params.set("status", opts.status);
      if (opts.kind && opts.kind !== "all") params.set("kind", opts.kind);
      if (opts.q) params.set("q", opts.q);
      if (opts.includeClosed) params.set("include_closed", "true");
      if (opts.limit) params.set("limit", String(opts.limit));
      if (opts.offset) params.set("offset", String(opts.offset));
      const suffix = params.toString() ? `?${params.toString()}` : "";
      return get<CandidateReviewQueueResponse>(`${BASE}/candidates/review${suffix}`, current);
    },
    enabled: !!current,
  });
}

export function useNodeSearch(q: string, type: string | null, limit = 50) {
  const { current } = useInstance();
  return useQuery({
    queryKey: ["nodes", current, q, type, limit],
    queryFn: () => {
      const params = new URLSearchParams();
      if (q) params.set("q", q);
      if (type) params.set("type", type);
      params.set("limit", String(limit));
      return get<{ rows: NodeRow[]; total: number }>(
        `${BASE}/nodes?${params.toString()}`,
        current
      );
    },
    enabled: !!current,
  });
}

export function useNodeDetail(id: string | undefined) {
  const { current } = useInstance();
  return useQuery({
    queryKey: ["node-detail", current, id],
    queryFn: () => get<NodeDetail>(`${BASE}/nodes/${id}`, current),
    enabled: !!current && !!id,
  });
}

export interface NodeKnowledgeQueryOptions {
  asOf?: string | null;
  includeStale?: boolean;
  includeSuperseded?: boolean;
  includeRejected?: boolean;
  includeRawEvidence?: boolean;
}

export function useNodeKnowledge(id: string | undefined, opts: NodeKnowledgeQueryOptions = {}) {
  const { current } = useInstance();
  return useQuery({
    queryKey: ["node-knowledge", current, id, opts],
    queryFn: () => {
      const params = new URLSearchParams();
      if (opts.asOf) params.set("as_of", opts.asOf);
      if (opts.includeStale) params.set("include_stale", "true");
      if (opts.includeSuperseded) params.set("include_superseded", "true");
      if (opts.includeRejected) params.set("include_rejected", "true");
      if (opts.includeRawEvidence) params.set("include_raw_evidence", "true");
      const suffix = params.toString() ? `?${params.toString()}` : "";
      return get<NodeKnowledge>(`${BASE}/nodes/${id}/knowledge${suffix}`, current);
    },
    enabled: !!current && !!id,
  });
}

export function useNeighborhood(id: string | undefined, hops = 1) {
  const { current } = useInstance();
  return useQuery({
    queryKey: ["graph", current, id, hops],
    queryFn: () => get<GraphPayload>(`${BASE}/nodes/${id}/graph?hops=${hops}`, current),
    enabled: !!current && !!id,
  });
}

export interface CreateKnowledgeCandidateInput {
  candidate_kind: KnowledgeCandidateKind;
  statement: string;
  target_payload?: Record<string, unknown>;
  review_context_ids?: string[];
  normalized_key?: string | null;
  created_by?: string | null;
  source_node_ids?: string[];
  derived_from_node_ids?: string[];
  confidence?: number | null;
}

export function createKnowledgeCandidate(instance: string, input: CreateKnowledgeCandidateInput) {
  return post<{ id: string }>(`${BASE}/candidates`, instance, input);
}

export function setKnowledgeCandidateStatus(
  instance: string,
  id: string,
  input: { status: KnowledgeCandidateStatus; reason?: string | null; actor?: string | null }
) {
  return post<{ assertion_id: string }>(`${BASE}/candidates/${id}/status`, instance, input);
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

export function promoteKnowledgeCandidate(
  instance: string,
  id: string,
  input: PromoteKnowledgeCandidateInput
) {
  return post<{ target_type: string; id: string }>(`${BASE}/candidates/${id}/promote`, instance, input);
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

export function acceptSourcePolicyCandidate(
  instance: string,
  id: string,
  input: AcceptSourcePolicyCandidateInput
) {
  return post<{ target_type: "source_policy"; ids: string[]; subject_node_id: string }>(
    `${BASE}/candidates/${id}/accept-source-policy`,
    instance,
    input
  );
}

export interface AcceptCrmStagePlanCandidateInput {
  opportunity_id: string;
  stage: string;
  effective_at: string;
  reason?: string | null;
  actor?: string | null;
  plan_properties?: Record<string, unknown>;
}

export function acceptCrmStagePlanCandidate(
  instance: string,
  id: string,
  input: AcceptCrmStagePlanCandidateInput
) {
  return post<{ target_type: "crm_stage_plan"; id: string; subject_node_id: string }>(
    `${BASE}/candidates/${id}/accept-crm-stage-plan`,
    instance,
    input
  );
}

export interface AcceptPmTaskPlanCandidateInput {
  task_id: string;
  status: string;
  effective_at: string;
  reason?: string | null;
  actor?: string | null;
  plan_properties?: Record<string, unknown>;
}

export function acceptPmTaskPlanCandidate(
  instance: string,
  id: string,
  input: AcceptPmTaskPlanCandidateInput
) {
  return post<{ target_type: "pm_task_plan"; id: string; subject_node_id: string }>(
    `${BASE}/candidates/${id}/accept-pm-task-plan`,
    instance,
    input
  );
}

export interface AcceptPmMilestonePlanCandidateInput {
  milestone_id: string;
  status: string;
  effective_at: string;
  reason?: string | null;
  actor?: string | null;
  plan_properties?: Record<string, unknown>;
}

export function acceptPmMilestonePlanCandidate(
  instance: string,
  id: string,
  input: AcceptPmMilestonePlanCandidateInput
) {
  return post<{ target_type: "pm_milestone_plan"; id: string; subject_node_id: string }>(
    `${BASE}/candidates/${id}/accept-pm-milestone-plan`,
    instance,
    input
  );
}

export function useDisputes() {
  const { current } = useInstance();
  return useQuery({
    queryKey: ["disputes", current],
    queryFn: () => get<DisputeRow[]>(`${BASE}/disputes`, current),
    enabled: !!current,
  });
}

export function useEvents(limit = 200) {
  const { current } = useInstance();
  return useQuery({
    queryKey: ["events", current, limit],
    queryFn: () => get<EventRow[]>(`${BASE}/events?limit=${limit}`, current),
    enabled: !!current,
  });
}

// --- response types ---
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

export interface CatalogResponse {
  totals: Record<string, number>;
  node_types: Record<string, number>;
  edge_types: Record<string, number>;
  event_types: Record<string, number>;
  assertion_types: Record<string, number>;
  tracked_tables: string[];
}

export interface DashboardResponse {
  kind: "quotes";
  catalog: CatalogResponse;
  kpis: {
    nodes_total: number;
    edges_total: number;
    events_total: number;
    assertions_total: number;
    active_assertions: number;
    disputed_subjects: number;
    unique_clients_90d: number;
    quote_value_90d: number;
    quote_count_90d: number;
  };
  timeline: { bucket: string; count: number; value: number }[];
  topClients: { client: string; quote_count: number; total_value: number; last_quote_at: string }[];
  recent: EventRow[];
}

export interface ReconDashboardResponse {
  kind: "recon";
  catalog: CatalogResponse;
  kpis: {
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
  };
  topOwners: { owner: string; claims: number; net_acres: number }[];
  topLessees: { lessee: string; leases: number; avg_royalty: number | null }[];
  counties: { county: string; parcels: number }[];
  extraction: {
    bucket: string;
    runs: number;
    rows_extracted: number;
    owners_extracted: number;
    parcels_created: number;
  }[];
  recent: EventRow[];
}

export interface KnowledgeDashboardResponse {
  kind: "knowledge";
  catalog: CatalogResponse;
  kpis: {
    nodes_total: number;
    edges_total: number;
    events_total: number;
    assertions_total: number;
    active_assertions: number;
    superseded_assertions: number;
    disputed_subjects: number;
    people_total: number;
    subjects_total: number;
    artifacts_total: number;
  };
  topParticipants: { id: string; label: string; node_type: string; events: number }[];
  timeline: { bucket: string; count: number }[];
  composition: { assertion_type: string; active: number; superseded: number; total: number }[];
  topSubjects: { id: string; label: string; node_type: string; facts: number; active: number }[];
  supersessions: {
    subject_node_id: string;
    label: string;
    node_type: string;
    assertion_type: string;
    old_claim: Record<string, unknown>;
    new_claim: Record<string, unknown>;
    old_at: string | null;
    new_at: string | null;
  }[];
  disputes: DisputeRow[];
  recent: EventRow[];
}

export interface KnowledgeMapScope {
  id: string;
  label: string;
  node_type: string;
  created_at: string;
  status: string | null;
  purpose: string | null;
  owner: string | null;
  active_policy_count: number;
  superseded_policy_count: number;
  candidate_count: number;
}

export interface KnowledgeMapPolicyRow {
  id: string;
  subject_node_id: string;
  scope_label: string;
  scope_type: string;
  assertion_type: string;
  assertion_key: string;
  domain: string | null;
  summary_value: string | null;
  claimed_authority_at: string | null;
  claim: Record<string, unknown>;
  attrs?: Record<string, unknown>;
  effective_at: string | null;
  effective_to: string | null;
  created_at: string;
  superseded_at?: string | null;
  superseded_by?: string | null;
  source_event_id: string | null;
}

export interface KnowledgeMapCandidateStatus {
  status: string;
  count: number;
}

export interface KnowledgeMapCandidateSample {
  id: string;
  label: string | null;
  status: string;
  candidate_kind: string | null;
  statement: string | null;
  target_payload: Record<string, unknown> | null;
  review_context_ids: string[] | null;
  confidence: string | null;
  created_at: string;
  supporting_sources: {
    id: string;
    label: string | null;
    node_type: string;
    edge_type: string;
  }[];
}

export interface KnowledgeMapPluginBinding {
  assertion_id: string;
  scope_id: string;
  scope_label: string;
  plugin_id: string;
  plugin_node_id: string | null;
  plugin_label: string | null;
  description: string;
  is_expected_plugin: boolean;
  effective_at: string | null;
  created_at: string;
  claim: Record<string, unknown>;
}

export interface KnowledgeMapOperationalPlan {
  id: string;
  subject_node_id: string;
  subject_label: string;
  subject_type: string;
  assertion_type: string;
  assertion_key: string;
  claim: Record<string, unknown>;
  attrs: Record<string, unknown>;
  effective_at: string | null;
  effective_to: string | null;
  planned_for: string | null;
  created_at: string;
  source_event_id: string | null;
}

export interface KnowledgeMapWarning {
  severity: "high" | "attention" | string;
  kind: string;
  subject_node_id?: string | null;
  scope_label?: string | null;
  assertion_id?: string | null;
  assertion_type?: string | null;
  assertion_key?: string | null;
  domain?: string | null;
  count?: number;
  effective_at?: string | null;
  claimed_authority_at?: string | null;
  summary: string;
}

export interface KnowledgeMapResponse {
  generated_at: string;
  scopes: KnowledgeMapScope[];
  current_process: KnowledgeMapPolicyRow[];
  future_process: KnowledgeMapPolicyRow[];
  historical_process: KnowledgeMapPolicyRow[];
  candidate_statuses: KnowledgeMapCandidateStatus[];
  candidate_samples: KnowledgeMapCandidateSample[];
  plugin_bindings: KnowledgeMapPluginBinding[];
  operational_plans: KnowledgeMapOperationalPlan[];
  warnings: KnowledgeMapWarning[];
  stats: {
    scope_count: number;
    current_process_count: number;
    future_process_count: number;
    historical_process_count: number;
    candidate_count: number;
    plugin_binding_count: number;
    operational_plan_count: number;
    warning_count: number;
  };
}

export interface WorkspaceRelatedItem {
  id: string;
  label: string | null;
  node_type: string;
  relation: string;
  direction: "in" | "out" | string;
  role?: string | null;
  relationship?: string | null;
  context?: string | null;
  dependency_type?: string | null;
  reason?: string | null;
}

export interface WorkspacePlan {
  id: string;
  subject_id: string;
  assertion_type: string;
  assertion_key: string;
  claim: Record<string, unknown>;
  effective_at: string | null;
  created_at: string;
}

export interface WorkspaceSourcePolicy {
  id: string;
  scope_id: string;
  scope_label: string;
  assertion_key: string;
  claim: Record<string, unknown>;
  effective_at: string | null;
  created_at: string;
}

export interface WorkspaceCandidate {
  id: string;
  label: string | null;
  properties: {
    statement?: string;
    candidate_kind?: KnowledgeCandidateKind;
    target_payload?: Record<string, unknown>;
    confidence?: number | null;
  } & Record<string, unknown>;
  created_at: string;
  status: KnowledgeCandidateStatus | string;
  sources: {
    id: string;
    label: string | null;
    node_type: string;
    source_type?: string | null;
  }[];
  review_contexts: {
    id: string;
    label: string | null;
    node_type: string;
  }[];
}

export interface CrmOpportunity {
  id: string;
  label: string;
  code: string | null;
  name: string | null;
  stage: string | null;
  pipeline: string | null;
  assigned_to_name: string | null;
  primary_contact_name: string | null;
  current_value: number | null;
  win_probability: number | null;
  next_action: string | null;
  related_items: WorkspaceRelatedItem[];
  created_at: string;
}

export interface CrmWorkspaceResponse {
  generated_at: string;
  opportunities: CrmOpportunity[];
  plans: WorkspacePlan[];
  source_policies: WorkspaceSourcePolicy[];
  candidates: WorkspaceCandidate[];
}

export interface PmTask {
  id: string;
  title: string;
  code: string | null;
  task_type: string | null;
  due_date: string | null;
  priority: string | null;
  status: string | null;
  owner_name: string | null;
  reviewer_name: string | null;
  project_name: string | null;
  project_code: string | null;
  sprint_name: string | null;
  blocker_count: number;
  subtask_count: number;
  related_items: WorkspaceRelatedItem[];
  created_at: string;
}

export interface PmMilestone {
  id: string;
  label: string;
  code: string | null;
  name: string | null;
  target_date: string | null;
  priority: string | null;
  status: string | null;
  status_claim: Record<string, unknown> | null;
  owner_name: string | null;
  owner_id: string | null;
  related_items: WorkspaceRelatedItem[];
  created_at: string;
}

export interface PmWorkspaceResponse {
  generated_at: string;
  tasks: PmTask[];
  milestones: PmMilestone[];
  plans: WorkspacePlan[];
  source_policies: WorkspaceSourcePolicy[];
  candidates: WorkspaceCandidate[];
}

export interface EventRow {
  id: string;
  event_type: string;
  summary: string | null;
  occurred_at: string;
  actor_system: string | null;
  properties: Record<string, unknown>;
  role?: string;
  participants?: {
    node_id: string;
    role: string;
    node_type: string;
    label: string | null;
  }[];
}

export interface NodeDetail {
  node: NodeRow;
  assertions: AssertionRow[];
  events: EventRow[];
  artifacts: ArtifactRow[];
  edges_out: EdgeNeighbor[];
  edges_in: EdgeNeighbor[];
  source_summary?: SourceSummary | null;
  context_scope?: ReviewContextScope | null;
  provenance_summary?: NodeProvenanceSummary | null;
}

export type KnowledgeCandidateKind =
  | "fact"
  | "task"
  | "edge"
  | "decision"
  | "procedure"
  | "preference"
  | "risk";

export type KnowledgeCandidateStatus =
  | "proposed"
  | "accepted"
  | "rejected"
  | "needs_review"
  | "duplicate"
  | "superseded";

export interface NodeKnowledge {
  evidence: {
    source_items_count: number;
    artifacts_count: number;
    source_events_count: number;
    recent_evidence: {
      kind: string;
      id: string;
      title: string | null;
      occurred_at: string | null;
      payload: Record<string, unknown>;
    }[];
  };
  candidates: KnowledgeCandidateRow[];
  accepted_knowledge: AcceptedKnowledgeRow[];
  actions: KnowledgeActionRow[];
  history: {
    events_count: number;
    assertions_count: number;
    superseded_assertions_count: number;
    candidates_count: number;
    recent_events: EventRow[];
  };
  what_was_learned: {
    topics: string[];
    entities: string[];
    actions: string[];
    decisions: string[];
    open_questions: string[];
  };
}

export interface KnowledgeCandidateRow {
  id: string;
  label: string | null;
  properties: {
    candidate_kind?: KnowledgeCandidateKind;
    statement?: string;
    target_payload?: Record<string, unknown>;
    review_context_ids?: string[];
    normalized_key?: string | null;
    created_by?: string | null;
    confidence?: number | null;
  } & Record<string, unknown>;
  attrs: Record<string, unknown>;
  created_at: string;
  status: KnowledgeCandidateStatus;
  status_claim: Record<string, unknown> | null;
  supporting_sources: {
    id: string;
    label: string | null;
    node_type: string;
    edge_type: string;
  }[];
  promoted_targets: {
    id: string;
    label: string | null;
    node_type: string;
    edge_type: string;
  }[];
}

export interface CandidateReviewRow extends KnowledgeCandidateRow {
  review_contexts: {
    id: string;
    label: string | null;
    node_type: string;
  }[];
  status_history: {
    status: string | null;
    reason: string | null;
    actor: string | null;
    status_at: string | null;
    assertion_id: string;
  }[];
}

export interface CandidateReviewQueueResponse {
  candidates: CandidateReviewRow[];
  statuses: { status: KnowledgeCandidateStatus | string; count: number }[];
  kinds: { kind: KnowledgeCandidateKind | string | null; count: number }[];
  stats: {
    total: number;
    filtered: number;
    open: number;
    accepted: number;
    rejected: number;
  };
}

export interface AcceptedKnowledgeRow extends AssertionRow {
  source_event_type: string | null;
  source_event_summary: string | null;
  candidate_id: string | null;
  candidate_label: string | null;
  candidate_properties: Record<string, unknown> | null;
}

export interface KnowledgeActionRow {
  id: string;
  label: string | null;
  properties: Record<string, unknown>;
  attrs: Record<string, unknown>;
  created_at: string;
  status: string | null;
  status_claim: Record<string, unknown> | null;
  source_candidate_ids: string[];
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

export interface ReviewContextScope {
  status: "derived_from_routed_source_items" | "derived_without_source_container" | "no_routed_source_items";
  source_items_count: number;
  source_containers: { id: string; label: string; item_count: number }[];
  source_accounts: { id: string; label: string; item_count: number }[];
}

export interface NodeProvenanceParticipant {
  id: string;
  label: string;
  node_type: string;
  role: string;
}

export interface NodeProvenanceSummary {
  status: "derived_from_assertion_sources" | "none";
  source_events_count: number;
  source_events: {
    id: string;
    event_type: string;
    summary: string | null;
    occurred_at: string;
    actor_system: string | null;
    properties: Record<string, unknown>;
    source_items: NodeProvenanceParticipant[];
    review_contexts: NodeProvenanceParticipant[];
    participants: NodeProvenanceParticipant[];
  }[];
}

export interface AssertionRow {
  id: string;
  assertion_type: string;
  assertion_key: string;
  claim: unknown;
  confidence: number | null;
  effective_at: string | null;
  effective_to: string | null;
  source_event_id: string | null;
  attrs: Record<string, unknown>;
  created_at: string;
  superseded_at: string | null;
  superseded_by: string | null;
}

export interface ArtifactRow {
  id: string;
  artifact_type: string;
  source_event_id: string | null;
  source_node_id: string | null;
  content: Record<string, unknown>;
  location: Record<string, unknown> | null;
  related_node_ids: string[];
  attrs: Record<string, unknown>;
  created_at: string;
}

export interface EdgeNeighbor {
  id: string;
  edge_type: string;
  source_id?: string;
  target_id?: string;
  properties: Record<string, unknown>;
  label: string;
  node_type: string;
}

export interface GraphPayload {
  nodes: { id: string; node_type: string; label: string }[];
  edges: {
    id: string;
    source: string;
    target: string;
    edge_type: string;
    properties?: Record<string, unknown>;
  }[];
}

export interface DisputeRow {
  subject_node_id: string;
  label: string;
  node_type: string;
  assertion_type: string;
  assertion_key: string;
  competing_claims: number;
  claims: { id: string; claim: unknown; source_event_id: string | null; confidence: number | null }[];
}
