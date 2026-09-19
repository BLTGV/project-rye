# 003 scoped-token-reads

- status: open
- opened: 2026-09-19
- areas: admin
- contracts: contracts/admin-api.md

## Goal
An agent holding a scoped token can reach only what its grants allow. Today
any valid agent token can read most of the admin API in full, and the
domains listing returns every area with its authorities and channel
subscriptions to any authenticated caller. This is GitHub issue 16
(BLTGV/project-rye). It must hold before anyone relies on the API as the
boundary between people with different authority, which v0.4 does.

## Intent excerpt (BRIEF.md)
"A scoped agent token can reach only the routes and rows its grants allow
(GitHub issue 16)." And from the admin area's invariants: "A bearer token
authenticates an agent and then maps to session variables. It never widens
what RLS would allow."

## Acceptance criteria
- [ ] With auth required, an agent token that lacks the matching grant gets a `403` with a `reason` naming the policy that refused, on every route listed in issue 16: `/api/catalog`, `/api/dashboard`, `/api/nodes/:id`, `/api/nodes/:id/graph`, `/api/nodes/:id/knowledge`, `/api/events`, `/api/knowledge-map`, `/api/workspace/crm`, `/api/workspace/pm`, `/api/gaps`, `/api/stale-digests`.
- [ ] A route that declares no capability is refused for agent tokens by default. A new route cannot become readable to agents by omission.
- [ ] The domains listing returns only the areas the token holds a grant for. Authorities and channel subscriptions of other areas are not returned.
- [ ] The review queue listing returns only rows in areas the token holds a grant for.
- [ ] A token with the matching grant still succeeds on the routes it is meant to use. The MCP adapter's existing tools keep working.
- [ ] Missing token, revoked token, and expired token each get `401`. A valid token used against another area gets `403`.
- [ ] `tests/conformance/21_api_security.sh` covers each case above and passes. `cd admin && npm run build` passes.
- [ ] The reviewer's screen is unaffected when auth mode is off.

## Constraints
- Reimplement fresh against current `admin/src/server/worker.ts`. Do not rebase the stale draft PRs named in the issue.
- Checks go through the schema's existing authorization helpers. No second authorization model, no direct database role approach.
- Every query still sets the RLS session variables inside the same statement.
- No schema migration in this item. If one turns out to be needed, stop and report.
- Domain-gating reads of individual existing nodes (the `node_domain_memberships` idea in the issue) is out of scope.

## Decided by the human
- 2026-09-19, Casey: fix issue 16 now ("do it").

## Assumed by default
- Deny by default for agent tokens on undeclared routes, as an allowlist. Overturn: Architect.
- Which capability each read route requires is the Architect's call in the contract; `rye.context.read` unless there is a reason otherwise. Overturn: Architect.
- Human access to the reviewer's screen is not changed here; putting a login in front of it is a separate item. Overturn: Casey.

## Verified
- filled in at close

## Reports
Paste each role's report here as it arrives.

### Architect, 2026-09-19
Result: done. Changed: contracts/admin-api.md (new normative "Authorization"
section: deny-by-default rule, 31-row route table, row filtering, 401/403
table, 403 shape, auth-mode-off), docs/decisions/0006-agent-tokens-deny-by-default.md.
No migration needed; every capability used already exists. Tested: none.
Learned: the gap is structural: the /api/* middleware authenticates and
calls next(), and 14 handlers never call enforceCapability. withAdminCte()
in admin/src/server/db.ts sets app.current_role = 'admin' on every
statement, so RLS narrows nothing for an agent and row filtering must be
explicit in the SQL. has_agent_capability with empty domain keys means
"holds it somewhere", not an area check. authenticate_agent_token already
returns NULL for unknown, revoked, expired, deactivated. The console SPA
sends no Authorization header, so with auth required the reviewer's screen
is already fully 401: one Worker serves the console or agents, not both.
21_api_security.sh needs a third agent holding no rye.context.read to prove
a 403. Question: should the four console rollups be deny or
rye.context.read global? Assumed deny (decision 0006); Lead accepts.

### Builder admin, 2026-09-19
Result: done. Branch worktree-agent-a81777e8089113486, commit 5b8e608 (base
f10c201). Changed: admin/src/server/route-policy.ts (new: the contract's
31-row route table, matchRoutePolicy), admin/src/server/worker.ts
(deny-by-default middleware, enforceRoutePolicy, contract 403 shape,
fail-closed guard, row-filter wiring), admin/src/server/queries.ts
(recordAgentDenial; area filters in fetchDomains and
fetchCandidateReviewQueue), tests/conformance/21_api_security.sh. Tested:
admin build passes; route matcher exercised for 18 probes and 4 undeclared
paths; Hono's registry shows 31 concrete /api routes, 0 undeclared; Worker
booted against a dummy DSN gives 401s under auth required and unchanged
behavior with auth off. NOT executed: 21_api_security.sh and every
database-backed case (401 variants, deny-by-default 403s, rollup denies,
403 reason shape, row filtering, cross-area 403, granted-token and MCP
successes, audit-log assertions, auth-off comparison). Environment: Docker
refuses this user; port was free, so not worktree contention. Learned: see
docs/areas/admin.md entries dated 2026-09-19. Questions: `self` route never
403s so writes no audit row (Lead: accepted as correct); audit read is
global across agents (Lead: accepted per contract; per-agent audit would be
its own item); the rye.domain.admin gate on domain `properties` does not
check grant expiry, pre-existing and untouched (Lead: out of scope here,
to be raised as its own item).

### Verifier, 2026-09-19, static pass on 5b8e608: FAIL
Findings: (1) HIGH: HEAD requests bypass deny-by-default; Hono dispatches
HEAD to GET handlers, the policy table and workerServesApiPath know only
GET, so `HEAD /api/dashboard` with any agent token runs the handler and
returns 200 with no audit row. Verified by execution. (2) MEDIUM: in the
review-queue filter an area-key array with no sluggable key ([""], ["--"])
collapses to "holds it somewhere" and is shown to every rye.review.read
holder. (3) LOW: holdsInstanceWide evaluates grant semantics in TypeScript
because no schema helper expresses "grant names no area". (4) LOW: the test
script probes only GET and POST and never exercises the undeclared-route
branch. (5) INFO: an unmatched path with no token returns 401 where the
contract says 404. Clean otherwise: 31 rows match the contract exactly, all
31 Worker routes have a row, matching cannot be shadowed by registration
order, encoded paths resolve to the same policy, filters are parameterised
and keep withAdminCte in the same statement, no migration, diff stays in
the area. Build passes. All database-backed criteria unverified pending
Docker. Lead: findings 1, 2, 4 sent to builder as fix attempt 1; 3 kept
with a comment; 5 goes to Architect as a contract amendment.

### Builder admin, 2026-09-19, fix attempt 1 (commit befe34c)
Result: done. Changed: route-policy.ts (normalizeMethod folds HEAD into
GET; pure routeDecision returning open|self|authorize|defer|refuse|
unmatched), worker.ts (middleware drives off routeDecision;
workerServesApiPath normalizes HEAD and recomputes when the registry grows;
holdsInstanceWide comment), queries.ts (review-queue filter counts only
sluggable keys), admin/scripts/route-policy-check.ts (new) with
`npm run check:routes` in admin/package.json, 21_api_security.sh (HEAD and
other-method probes, unsluggable-key assertions). Tested: build passes;
check:routes passes on 31 routes covering HEAD on every GET row, PUT/PATCH/
DELETE/OPTIONS/TRACE, the four deny rollups, unmatched paths, and
route_undeclared via a route registered at test time; live probes against a
booted Worker. NOT executed: 21_api_security.sh and the two SQL filters,
pending Docker. Learned: see docs/areas/admin.md entries dated 2026-09-19.
Questions: 401-before-404 left as is, needs an Architect contract
amendment (Lead: agreed); whether the area test command should become
`npm run build && npm run check:routes` (Lead: yes, route to Architect, who
owns docs/areas.md).

## Close
