/**
 * The route-to-capability table from `contracts/admin-api.md`.
 *
 * This file is the only place an `/api/*` route becomes reachable by an agent
 * bearer token. The auth middleware consults it and refuses anything it cannot
 * find here, so a route added to the Worker without a row below ships closed.
 * Keep it in step with the route table in the contract; the contract is
 * normative and this is its executable copy.
 */

export type RouteCheck =
  | "none"
  | "self"
  | "global"
  | "global + row filter"
  | "domain"
  | "domain + scope"
  | "target"
  | "deny";

export interface RoutePolicy {
  /** HTTP method, uppercase. */
  method: string;
  /** Hono path pattern, `:name` for a parameter segment. */
  pattern: string;
  /** Stable name written to the agent action log. */
  action: string;
  /** Capability the check tests, or null when the route is `none`/`self`/`deny`. */
  capability: string | null;
  check: RouteCheck;
}

/**
 * The checks the middleware cannot complete on its own: the area keys and
 * scope live in the request body or the target row, so the handler runs the
 * authorization call. The middleware still fails the request closed if the
 * handler does not.
 */
export const DEFERRED_CHECKS: ReadonlySet<RouteCheck> = new Set<RouteCheck>([
  "domain",
  "domain + scope",
  "target",
]);

export const ROUTE_POLICIES: readonly RoutePolicy[] = [
  // Open: no token at all.
  { method: "GET", pattern: "/api/health", action: "health_read", capability: null, check: "none" },
  { method: "GET", pattern: "/api/instances", action: "instances_list", capability: null, check: "none" },

  // Any valid token, caller's own record only.
  { method: "GET", pattern: "/api/agent/me", action: "agent_me_read", capability: null, check: "self" },

  // Reads.
  { method: "GET", pattern: "/api/catalog", action: "catalog_read", capability: "rye.context.read", check: "global" },
  { method: "GET", pattern: "/api/events", action: "events_read", capability: "rye.context.read", check: "global" },
  { method: "GET", pattern: "/api/nodes", action: "nodes_search", capability: "rye.context.read", check: "global" },
  { method: "GET", pattern: "/api/nodes/:id", action: "node_detail_read", capability: "rye.context.read", check: "global" },
  { method: "GET", pattern: "/api/nodes/:id/graph", action: "node_graph_read", capability: "rye.context.read", check: "global" },
  { method: "GET", pattern: "/api/nodes/:id/knowledge", action: "node_knowledge_read", capability: "rye.context.read", check: "global" },
  { method: "GET", pattern: "/api/domains", action: "domains_list", capability: "rye.context.read", check: "global + row filter" },
  { method: "GET", pattern: "/api/context-pack", action: "context_pack_read", capability: "rye.context.read", check: "domain + scope" },
  { method: "GET", pattern: "/api/review-queue", action: "review_queue_read", capability: "rye.review.read", check: "global + row filter" },
  { method: "GET", pattern: "/api/candidates/review", action: "candidate_review_read", capability: "rye.review.read", check: "global + row filter" },
  { method: "GET", pattern: "/api/review/assertions", action: "assertion_review_read", capability: "rye.review.read", check: "global" },
  { method: "GET", pattern: "/api/gaps", action: "open_gaps_read", capability: "rye.review.read", check: "global" },
  { method: "GET", pattern: "/api/stale-digests", action: "stale_digests_read", capability: "rye.review.read", check: "global" },
  { method: "GET", pattern: "/api/audit/actions", action: "audit_actions_read", capability: "rye.audit.read", check: "global" },

  // Console rollups. No area dimension to check and no row to filter, so no
  // agent token reaches them. See docs/decisions/0006.
  { method: "GET", pattern: "/api/dashboard", action: "dashboard_read", capability: null, check: "deny" },
  { method: "GET", pattern: "/api/knowledge-map", action: "knowledge_map_read", capability: null, check: "deny" },
  { method: "GET", pattern: "/api/workspace/crm", action: "crm_workspace_read", capability: null, check: "deny" },
  { method: "GET", pattern: "/api/workspace/pm", action: "pm_workspace_read", capability: null, check: "deny" },

  // Writes.
  { method: "POST", pattern: "/api/observations", action: "observation_create", capability: "rye.observation.create", check: "domain + scope" },
  { method: "POST", pattern: "/api/candidates", action: "candidate_create", capability: "rye.candidate.create", check: "domain + scope" },
  { method: "POST", pattern: "/api/candidates/:id/status", action: "candidate_status_set", capability: "rye.candidate.adjudicate", check: "domain + scope" },
  { method: "POST", pattern: "/api/candidates/:id/promote", action: "candidate_promote", capability: "rye.authoritative.promote", check: "domain + scope" },
  { method: "POST", pattern: "/api/candidates/:id/accept-source-policy", action: "source_policy_accept", capability: "rye.authoritative.promote", check: "domain + scope" },
  { method: "POST", pattern: "/api/candidates/:id/accept-crm-stage-plan", action: "crm_stage_plan_accept", capability: "rye.authoritative.promote", check: "domain + scope" },
  { method: "POST", pattern: "/api/candidates/:id/accept-pm-task-plan", action: "pm_task_plan_accept", capability: "rye.authoritative.promote", check: "domain + scope" },
  { method: "POST", pattern: "/api/candidates/:id/accept-pm-milestone-plan", action: "pm_milestone_plan_accept", capability: "rye.authoritative.promote", check: "domain + scope" },
  { method: "POST", pattern: "/api/assertions/:id/accept", action: "assertion_accept", capability: "rye.authoritative.promote", check: "target" },
  { method: "POST", pattern: "/api/assertions/:id/reject", action: "assertion_reject", capability: "rye.candidate.adjudicate", check: "target" },
];

function segmentsOf(path: string): string[] {
  return path.split("/").filter((part) => part.length > 0);
}

/**
 * Matches a concrete request path against a Hono pattern. Returns the number
 * of literal segments that matched, or -1 when the pattern does not apply.
 * More literal segments means a more specific pattern.
 */
function patternSpecificity(pattern: string, path: string): number {
  const patternParts = segmentsOf(pattern);
  const pathParts = segmentsOf(path);
  if (patternParts.length !== pathParts.length) return -1;
  let literals = 0;
  for (let i = 0; i < patternParts.length; i += 1) {
    const expected = patternParts[i];
    if (expected.startsWith(":")) continue;
    if (expected !== pathParts[i]) return -1;
    literals += 1;
  }
  return literals;
}

export function matchesPattern(pattern: string, path: string): boolean {
  return patternSpecificity(pattern, path) >= 0;
}

/**
 * The declared policy for a request, or null when the contract's table does
 * not list the route. Null means refuse; it never means allow.
 */
export function matchRoutePolicy(method: string, path: string): RoutePolicy | null {
  const wanted = method.toUpperCase();
  let best: RoutePolicy | null = null;
  let bestScore = -1;
  for (const policy of ROUTE_POLICIES) {
    if (policy.method !== wanted) continue;
    const score = patternSpecificity(policy.pattern, path);
    if (score > bestScore) {
      best = policy;
      bestScore = score;
    }
  }
  return best;
}
