# 003 scoped-token-reads

- status: done
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
- [x] With auth required, an agent token that lacks the matching grant gets a `403` with a `reason` naming the policy that refused, on every route listed in issue 16: `/api/catalog`, `/api/dashboard`, `/api/nodes/:id`, `/api/nodes/:id/graph`, `/api/nodes/:id/knowledge`, `/api/events`, `/api/knowledge-map`, `/api/workspace/crm`, `/api/workspace/pm`, `/api/gaps`, `/api/stale-digests`.
- [x] A route that declares no capability is refused for agent tokens by default. A new route cannot become readable to agents by omission.
- [x] The domains listing returns only the areas the token holds a grant for. Authorities and channel subscriptions of other areas are not returned.
- [x] The review queue listing returns only rows in areas the token holds a grant for.
- [x] A token with the matching grant still succeeds on the routes it is meant to use. The MCP adapter's existing tools keep working.
- [x] Missing token, revoked token, and expired token each get `401`. A valid token used against another area gets `403`.
- [x] `tests/conformance/21_api_security.sh` covers each case above and passes. `cd admin && npm run build` passes.
- [x] The reviewer's screen is unaffected when auth mode is off.

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
- Combined test command `./scripts/test-all.sh` passed on the final merged tree 4701e1a, run by Lead 2026-09-19: Docker flow (install, conformance, security, concurrency, scenarios, host-run 21_api_security.sh, 22_secure_mcp_simulation.sh, 23_cli_agent_security.sh), admin build plus check:routes (31 declared routes), site build. Log: scratchpad suite-4701e1a.log.
- All eight acceptance criteria verified by execution in 21_api_security.sh and check:routes. The Verifier named the assertion covering each (final pass, below) and audited 41 presence and absence assertions: every marker is paired, none was weakened.
- Deny by default additionally verified by the Verifier's independent sweep: 53 registry entries by 10 methods, 0 holes.
- The HEAD bypass and the junk-area-key leak were found by the Verifier before merge, fixed, and rechecked. Three early assertions were vacuous (compared against unslugged stored keys) and one expectation was wrong (promotion archives the suggestion); all corrected before the passing run.
- Not verified here, by design: human login in front of the reviewer's screen; domain-gating reads of individual nodes; grant expiry on the rye.domain.admin gate for the domains `properties` field (pre-existing).

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

### Verifier, 2026-09-19, second pass on befe34c: PASS-STATIC
Both first-pass findings fixed; no regressions. Verified by execution:
build; check:routes (31 routes); an independent sweep of 53 registry
entries by 10 methods including lowercase found 0 holes (no method and path
with a handler decides unmatched); HEAD on all four deny rollups decides
refuse; replaying the pre-fix code makes check:routes fail, so it is not
vacuous; HTTP probes under auth required. Verified by reading: the
sluggable-key SQL handles all-junk, junk plus held key, and junk plus
unheld key correctly, stays parameterised with withAdminCte in the same
statement; the test-time probe route cannot reach production (wrangler
points at src/server/worker.ts). Carried: (1) INFO: contract says 404 for
an unmatched path, code returns 401 without a token; needs an Architect
amendment. (2) LOW: the script seeds only the all-junk case; mixed cases
unpinned. Criterion 2 verified by execution. Criteria 1, 3, 4, 8 verified
by reading; 5, 6 (beyond missing-token 401), and the script run in 7 remain
pending the database. Lead: mixed-case tests requested from builder;
contract amendment queued for Architect.

### Builder admin, 2026-09-19, test addition (commit b4e8b9b)
Result: done. Only tests/conformance/21_api_security.sh touched. Added two
mixed area-key suggestions (junk plus held key must be shown; junk plus
unheld key must be hidden), each asserted from both agents and present on
the auth-off server, via the `q` filter. While adding them the builder
found three of its own earlier assertions compared against unslugged keys
and could never have passed (stored keys are rye_slugify_key of the input),
and one `stats.total == 0` check that the new rows made wrong; all fixed.
Tested: bash -n, build, check:routes pass. The script itself is still
unexecuted, so more errors of this kind may remain until it runs under
Docker.

### Lead, 2026-09-19, integration
Base revision 8fcf382. Merged worktree-agent-a81777e8089113486 (5b8e608,
befe34c, b4e8b9b) into agent-roles with no conflicts. From the merged tree:
`cd admin && npm run build` passes; `npm run check:routes` passes (31
declared routes); `bash -n tests/conformance/21_api_security.sh` passes.
NOT run: tests/conformance/21_api_security.sh and the combined suite.
Docker refuses this user (not in the docker group, service inactive, sudo
needs a password). The item stays open until they run.

### Architect, 2026-09-19, contract amendments
Result: done. Changed: contracts/admin-api.md (new normative "Every method
is decided, and HEAD is decided as GET"; 401/403/404 table now says no or
invalid token is 401 on any /api path and 404 only for an authenticated
caller; row filtering states the rye_slugify_key() rule; "holds an
instance-wide grant" recorded as a named exception to schema-helper
checks), docs/decisions/0006 ("Amendments after implementation"),
docs/areas.md (admin test is now `cd admin && npm run build && npm run
check:routes`). Lead reran scripts/gen-agents after the areas edit.

### Lead, 2026-09-19, first execution of 21_api_security.sh: FAIL
Docker access restored by Casey. From tree 1749342 the conformance suite
passed; the host-run 21_api_security.sh then failed at line 452:
"reviewer sees its own area's candidate": GET /api/review-queue?
include_closed=1&q=Brightline with the reviewer token returned zero
candidates, stats total 1 filtered 0, only facet proposed count 1, right
after the reviewer promoted that candidate with a 200. Cause unknown:
product filter or test expectation. Sent to the builder with sole use of
the Docker port, to find the cause by execution and run the script to the
end. This is a newly observed problem, not a repeat of an earlier finding.

### Builder admin, 2026-09-19, first executed run (commit ee6aaeb)
Result: done. Only tests/conformance/21_api_security.sh changed; no
production code change. Cause of the failure: wrong test expectation,
product correct. promote_candidate_node_to_assertion (0017) ends by
setting archived_at on the candidate node, and the queue lists only
archived_at IS NULL, so a promoted suggestion leaves every caller's queue.
Shown by execution: the promoted candidate had archived = t. stats.total
counts area-visible rows and stats.filtered counts those surviving status,
kind, and q, so total 1 / filtered 0 was the filter working. Lead confirmed
the archive step at 0017 line 1103 and that ee6aaeb touches only the
script. Fix: the two assertions moved ahead of the promotion; later checks
use never-promoted markers. Tested: `./scripts/docker-test.sh test --reset
--profiles crm,pm` passes end to end including 21, 22, and 23 from the
host; build and check:routes pass; database torn down. Builder reports
every acceptance criterion now verified by execution.

### Verifier, 2026-09-19, final pass on b4e8b9b and ee6aaeb: PASS, conditional on the suite (which passed)
Diagnosis confirmed against 0017 lines 1102-1104: promotion archives the
candidate, so moving the assertions ahead of the promotion is the right
fix, not a weakening. No assertion weakened; every absence paired with a
presence on the same marker; mixed-key cases assert both directions from
both agents; both commits test-only. Assertion named for each of the eight
criteria. Findings, both low: (1) the contract does not define stats.total
versus stats.filtered; the code counts area-visible live rows and rows
surviving status, kind, and q. For the Architect. (2) The title agent's
`stats.total == candidates.length` check holds only while its visible rows
fit one page of 80; true today, backed by four paired absence checks.

## Close
done 2026-09-19. Merged to agent-roles at 4701e1a; combined suite passed. GitHub issue 16 can be closed when this branch reaches main. Follow-ups raised separately: define stats.total and stats.filtered in the admin API contract (Architect); make the page-size-dependent total check robust; grant expiry on the domains `properties` gate; a schema helper for "holds an instance-wide grant"; a login in front of the reviewer's screen, since one Worker cannot serve the console and agents with auth required.
