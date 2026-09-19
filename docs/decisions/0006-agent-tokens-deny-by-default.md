# 0006. Agent tokens are refused by default

Date: 2026-09-19. Status: accepted. Decided by: Architect, for work item 003.

**A route is closed to agent tokens until `contracts/admin-api.md` lists it
with a capability.** Today the Worker's auth middleware authenticates the
bearer token and then calls `next()`, and only the routes whose handlers
happen to call `enforceCapability` are gated. Roughly half do not, so any
valid token reads the catalog, the dashboard, every node, the whole event
log, and both workspaces in full. The fix is to invert the default: the
middleware, not the handler, decides, and it refuses anything it cannot find
in a table of declared routes. That makes the contract's route table the only
place agent access is granted, and it makes the dangerous case, a new route
added without thinking about authorization, fail closed instead of open. The
alternative was to keep the per-handler `enforceCapability` call and simply
add the missing ones. It is a smaller diff and it keeps the declaration next
to the code that uses it, which reads well. It was rejected because it fixes
the eleven routes named in issue 16 and nothing about the twelfth route
someone writes next month. A convention that every handler must remember to
call is a convention that will be forgotten, and the failure mode is silent
and invisible in review.

**Four console rollups are refused to every agent token rather than gated by
a capability.** `/api/dashboard`, `/api/knowledge-map`, `/api/workspace/crm`,
and `/api/workspace/pm` are whole-instance aggregates built for the
reviewer's screen. They have no area dimension, so there is nothing to check
a grant against and no row to filter. The default assumed in the work item
was `rye.context.read` for every read route, but applying it here would mean
an agent holding one area's grant reads every area's rollup, which is the
leak issue 16 exists to close, one level up. No agent client calls them: the
MCP adapter uses `/api/agent/me`, `/api/context-pack`, `/api/domains`,
`/api/observations`, `/api/candidates`, `/api/review-queue`, and
`/api/audit/actions`, and nothing else does. The rejected alternative was to
gate them on `rye.context.read` like the other reads, which would have
satisfied the acceptance criteria literally while leaving the console's
entire rollup readable to any scoped agent. If a real agent use case for
these appears, the answer is an area-filtered variant of the route, not a
grant on the unfiltered one.

**Row filtering happens in the query, and `global` is named as the weaker
check it is.** Every admin API statement runs with `app.current_role` set to
`admin` inside the same statement, so RLS does not narrow anything for an
agent. The area invariant "a bearer token never widens what RLS would allow"
is true only because RLS is already wide open to the API's role. Filtering
therefore has to be explicit in the SQL, using the same
`has_agent_capability` predicate the schema already applies inside
`agent_get_context_pack`, and this item does it for the two listings that
carry area keys: the domains listing and the review queue. Everything else
gets a `global` check, which asks whether the token holds the capability
anywhere and not whether it holds it here. The contract says so out loud
rather than implying isolation it does not deliver, because the honest
statement is that a `global` route refuses an agent without the capability
and is not an area boundary. The rejected alternative was to domain-gate node
and event reads too. That needs a node-to-area mapping which does not exist,
the work item puts it out of scope, and inventing one here would have meant a
schema migration this item forbids.

**Unrecognised, revoked, and expired tokens are one indistinguishable `401`,
and every refusal carries a closed set of `reason` strings.** The schema's
`authenticate_agent_token` already returns null for all three and for a
deactivated identity, so the API cannot tell them apart without a second
query, and it should not want to: telling a caller which of the three it
holds tells an attacker where to push. A `403` carries `reason` from a fixed
two-value set, `missing capability grant` or `route not available to agent
tokens`, with an additive `policy` object naming the action, capability,
check, area keys, and scope. Tests and clients branch on `reason`; `policy`
is for the human reading the response. The rejected alternative was a free
text reason assembled per route, which reads better once and is impossible to
assert on twice. No new capability name is introduced anywhere in this item,
so no migration is required.
