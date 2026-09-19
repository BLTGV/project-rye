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

/**
 * Hono dispatches a HEAD request to the GET handler, so HEAD must be judged by
 * the GET route's policy. Without this a HEAD request finds no row, looks
 * undeclared, and — if the registry lookup also misses it — runs the handler
 * with no capability check at all.
 */
export function normalizeMethod(method: string): string {
  const upper = method.toUpperCase();
  return upper === "HEAD" ? "GET" : upper;
}

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
  const wanted = normalizeMethod(method);
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

/**
 * What the middleware must do with a request, decided from the table alone.
 *
 * - `open`: no token, no check. The two exempt routes.
 * - `self`: any valid token, caller's own record. No capability.
 * - `authorize`: the middleware runs the capability call itself.
 * - `defer`: the handler runs it, because only the handler knows the area keys
 *   or the target. The middleware fails the request closed if it does not.
 * - `refuse`: `403`. A `deny` row, or a route the Worker serves with no row.
 * - `unmatched`: no row and no handler. Falls through to the `404`.
 *
 * Pure, and separated from the middleware so every branch can be exercised
 * without a database. `servesPath` answers whether the Worker has a handler.
 */
export interface RouteDecision {
  kind: "open" | "self" | "authorize" | "defer" | "refuse" | "unmatched";
  policy: RoutePolicy | null;
  /** Action name for the audit row, on `refuse` only. */
  action?: string;
  /** Free-text reason written to the audit row, on `refuse` only. */
  logReason?: string;
}

export function routeDecision(
  method: string,
  path: string,
  servesPath: (method: string, path: string) => boolean
): RouteDecision {
  const policy = matchRoutePolicy(method, path);
  if (!policy) {
    if (!servesPath(method, path)) return { kind: "unmatched", policy: null };
    return {
      kind: "refuse",
      policy: null,
      action: "route_undeclared",
      logReason: "route declares no capability",
    };
  }
  if (policy.check === "none") return { kind: "open", policy };
  if (policy.check === "self") return { kind: "self", policy };
  if (policy.check === "deny") {
    return {
      kind: "refuse",
      policy,
      action: policy.action,
      logReason: "route not available to agent tokens",
    };
  }
  if (DEFERRED_CHECKS.has(policy.check)) return { kind: "defer", policy };
  return { kind: "authorize", policy };
}
