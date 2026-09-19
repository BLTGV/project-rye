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

## Close
