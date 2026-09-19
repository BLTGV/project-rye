/**
 * In-process checks on the deny-by-default decision. Needs no database.
 *
 *   cd admin && npm run check:routes
 *
 * `routeDecision` is pure, so every branch the middleware can take is
 * exercised here: the two open routes, `self`, the capability checks, the
 * deferred checks, the four `deny` rollups, a route the Worker serves that the
 * table does not declare, and a path that matches nothing at all. The
 * conformance suite covers the same ground over HTTP once a database exists;
 * this runs without one, so a regression cannot hide behind an unavailable
 * Docker daemon.
 */
import app, { workerServesApiPath } from "../src/server/worker";
import { ROUTE_POLICIES, matchRoutePolicy, routeDecision } from "../src/server/route-policy";

let failures = 0;

function check(desc: string, got: unknown, want: unknown) {
  const a = JSON.stringify(got);
  const b = JSON.stringify(want);
  if (a !== b) {
    console.log(`FAIL ${desc}\n  got  ${a}\n  want ${b}`);
    failures += 1;
  }
}

function decide(method: string, path: string) {
  const d = routeDecision(method, path, workerServesApiPath);
  return { kind: d.kind, action: d.action ?? d.policy?.action ?? null, check: d.policy?.check ?? null };
}

const NODE = "00000000-0000-0000-0000-000000000000";

// ---------------------------------------------------------------------------
// Every route the Worker serves is declared.
// ---------------------------------------------------------------------------

const served = new Set(
  app.routes
    .filter((r) => r.path.startsWith("/api/") && !r.path.includes("*"))
    .map((r) => `${r.method.toUpperCase()} ${r.path}`)
);
for (const entry of served) {
  const [method, pattern] = entry.split(" ");
  const path = pattern.replace(/:[^/]+/g, NODE);
  if (!matchRoutePolicy(method, path)) {
    console.log(`FAIL undeclared Worker route: ${entry}`);
    failures += 1;
  }
}
check("worker api route count", served.size, ROUTE_POLICIES.length);

const actions = ROUTE_POLICIES.map((r) => r.action);
check("action names are unique", new Set(actions).size, actions.length);

// ---------------------------------------------------------------------------
// The decision for each kind of row.
// ---------------------------------------------------------------------------

check("GET /api/health", decide("GET", "/api/health"), { kind: "open", action: "health_read", check: "none" });
check("GET /api/instances", decide("GET", "/api/instances"), { kind: "open", action: "instances_list", check: "none" });
check("GET /api/agent/me", decide("GET", "/api/agent/me"), { kind: "self", action: "agent_me_read", check: "self" });
check("GET /api/catalog", decide("GET", "/api/catalog"), { kind: "authorize", action: "catalog_read", check: "global" });
check("GET /api/domains", decide("GET", "/api/domains"), { kind: "authorize", action: "domains_list", check: "global + row filter" });
check("GET /api/context-pack", decide("GET", "/api/context-pack"), { kind: "defer", action: "context_pack_read", check: "domain + scope" });
check("POST /api/candidates", decide("POST", "/api/candidates"), { kind: "defer", action: "candidate_create", check: "domain + scope" });
check(`POST /api/assertions/${NODE}/accept`, decide("POST", `/api/assertions/${NODE}/accept`), { kind: "defer", action: "assertion_accept", check: "target" });

for (const path of ["/api/dashboard", "/api/knowledge-map", "/api/workspace/crm", "/api/workspace/pm"]) {
  const d = routeDecision("GET", path, workerServesApiPath);
  check(`GET ${path} is refused`, d.kind, "refuse");
  check(`GET ${path} log reason`, d.logReason, "route not available to agent tokens");
}

// ---------------------------------------------------------------------------
// HEAD. Hono dispatches it to the GET handler, so it must be judged by the GET
// row. Before this was fixed, HEAD found no row, the registry lookup missed it
// too, and the handler ran with no check and no audit row.
// ---------------------------------------------------------------------------

check("HEAD /api/dashboard", decide("HEAD", "/api/dashboard"), { kind: "refuse", action: "dashboard_read", check: "deny" });
check("HEAD /api/knowledge-map", decide("HEAD", "/api/knowledge-map"), { kind: "refuse", action: "knowledge_map_read", check: "deny" });
check("HEAD /api/workspace/crm", decide("HEAD", "/api/workspace/crm"), { kind: "refuse", action: "crm_workspace_read", check: "deny" });
check("HEAD /api/workspace/pm", decide("HEAD", "/api/workspace/pm"), { kind: "refuse", action: "pm_workspace_read", check: "deny" });
check("HEAD /api/catalog", decide("HEAD", "/api/catalog"), { kind: "authorize", action: "catalog_read", check: "global" });
check("HEAD /api/domains", decide("HEAD", "/api/domains"), { kind: "authorize", action: "domains_list", check: "global + row filter" });
check("HEAD /api/events", decide("HEAD", "/api/events"), { kind: "authorize", action: "events_read", check: "global" });
check(`HEAD /api/nodes/:id/knowledge`, decide("HEAD", `/api/nodes/${NODE}/knowledge`), { kind: "authorize", action: "node_knowledge_read", check: "global" });
check("HEAD /api/health", decide("HEAD", "/api/health"), { kind: "open", action: "health_read", check: "none" });
check("HEAD /api/agent/me", decide("HEAD", "/api/agent/me"), { kind: "self", action: "agent_me_read", check: "self" });

// No GET row must ever decide by omission under HEAD.
for (const policy of ROUTE_POLICIES.filter((r) => r.method === "GET")) {
  const path = policy.pattern.replace(/:[^/]+/g, NODE);
  const asGet = routeDecision("GET", path, workerServesApiPath);
  const asHead = routeDecision("HEAD", path, workerServesApiPath);
  check(`HEAD matches GET for ${policy.pattern}`, asHead.kind, asGet.kind);
}

// ---------------------------------------------------------------------------
// Every other method. None of them reaches a handler, so each is `unmatched`
// and falls through to the 404; none is allowed through without a decision.
// ---------------------------------------------------------------------------

for (const method of ["PUT", "PATCH", "DELETE", "OPTIONS", "TRACE"]) {
  for (const path of ["/api/catalog", "/api/dashboard", "/api/domains", `/api/nodes/${NODE}`, "/api/candidates"]) {
    const d = routeDecision(method, path, workerServesApiPath);
    if (d.kind !== "unmatched" && d.kind !== "refuse") {
      console.log(`FAIL ${method} ${path} reached a handler with kind=${d.kind}`);
      failures += 1;
    }
  }
}

// ---------------------------------------------------------------------------
// A path that matches nothing at all falls through to the 404.
// ---------------------------------------------------------------------------

check("GET /api/not-a-route", decide("GET", "/api/not-a-route"), { kind: "unmatched", action: null, check: null });
check("HEAD /api/not-a-route", decide("HEAD", "/api/not-a-route"), { kind: "unmatched", action: null, check: null });
check("GET /api/nodes/a/b/c", decide("GET", `/api/nodes/${NODE}/b/c`), { kind: "unmatched", action: null, check: null });

// ---------------------------------------------------------------------------
// A route the Worker serves that the table does not declare is refused. This
// is the case that matters: it is what happens the day someone adds a route
// and forgets the contract. Registered here at test time so no production
// route has to exist for it.
// ---------------------------------------------------------------------------

check(
  "undeclared route before registration",
  decide("GET", "/api/undeclared-probe"),
  { kind: "unmatched", action: null, check: null }
);

app.get("/api/undeclared-probe", (c) => c.json({ leaked: true }));
app.post("/api/undeclared-probe/:id", (c) => c.json({ leaked: true }));

check("worker now serves the probe route", workerServesApiPath("GET", "/api/undeclared-probe"), true);

for (const [method, path] of [
  ["GET", "/api/undeclared-probe"],
  ["HEAD", "/api/undeclared-probe"],
  ["POST", `/api/undeclared-probe/${NODE}`],
] as [string, string][]) {
  const d = routeDecision(method, path, workerServesApiPath);
  check(`${method} ${path} is refused`, d.kind, "refuse");
  check(`${method} ${path} action`, d.action, "route_undeclared");
  check(`${method} ${path} log reason`, d.logReason, "route declares no capability");
  check(`${method} ${path} carries no policy`, d.policy, null);
}

console.log(failures === 0 ? `route-policy check passed (${ROUTE_POLICIES.length} declared routes)` : `${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
