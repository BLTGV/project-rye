# Contract: Admin API

Published by **admin** (`admin/src/server/worker.ts`). Consumed by
**agent-kit** — `skills/rye-source-context-intake/scripts/rye_api_mcp_server.mts`
is a client, and `tests/conformance/21_api_security.sh` and
`22_secure_mcp_simulation.sh` hold both sides to this contract. The console's
own SPA is a client too, but it ships in the same unit.

## Shape

JSON over HTTP under `/api/*` on one Cloudflare Worker. Everything else on
the origin is the SPA's static assets.

- **Instance selection.** Every request names a Rye instance with
  `?instance=<id>` or the `X-Rye-Instance` header; absent both, the Worker's
  `DEFAULT_INSTANCE` applies. `GET /api/instances` lists the ids a caller may
  use. An unknown id is `400`.
- **Authentication.** When the deployment requires it, every route except
  `/api/health` and `/api/instances` needs `Authorization: Bearer <token>`.
  The token identifies an *agent*, and the API then sets the RLS session
  variables for it. `GET /api/agent/me` reports whether auth is required and
  who the caller is.
- **Authorization.** Each route declares an action and a capability. The
  database decides, not the API: the call is checked against the agent's
  grants for the domain keys and scope in the request. A route that declares
  nothing is closed to agent tokens. See "Authorization" below for the full
  rule and the route table.
- **Reads.** `GET` routes for domains, context pack, catalog, dashboard,
  knowledge map, workspaces, gaps, stale digests, events, audit actions, and
  nodes (`/api/nodes/:id`, `.../knowledge`, `.../graph`). All are projections
  of the views in `contracts/sql-surface.md`.
- **Writes.** `POST /api/observations` and `POST /api/candidates` create
  observations and candidate assertions; the review actions accept, reject,
  and supersede through the schema's helpers. An agent's write is a
  candidate. Nothing an agent posts becomes current without a person.
  `POST /api/candidates` honours an `Idempotency-Key` header; the same key
  returns the same candidate rather than creating a second one.

## Authorization

This section is normative. It applies whenever the deployment sets
`RYE_API_AUTH_MODE=required`. With auth off, none of it applies; see "Auth
mode off" at the end.

### Deny by default

An agent bearer token is refused with `403` on any `/api/*` route that does
not appear in the route table below with a capability. Declaring nothing is
not the same as declaring nothing is needed. A route added to the Worker
without a row in this table is closed to agent tokens on the day it ships,
and it stays closed until someone edits this file. No route becomes readable
to agents by omission.

Two exemptions, and only two:

- `GET /api/health` and `GET /api/instances` take no token at all. They
  return no instance data, only liveness and the ids a caller may name.
- `GET /api/agent/me` takes any valid token and returns only the caller's own
  identity and grants. It carries no instance data and cannot be used to
  learn about another agent.

Any later exemption needs a decision record and an edit here first.

### Route table

`check` says what the capability is tested against:

- `global`: the token must hold the capability on at least one area. The
  response is not filtered by area.
- `global + row filter`: as `global`, and the rows returned are narrowed to
  the areas the token holds. See "Row filtering".
- `domain`: the capability is tested against the area keys named in the
  request or carried by the target. Every named area must be granted.
- `domain + scope`: as `domain`, and the grant must also match the request's
  scope when the grant names one.
- `target`: the capability is tested without an area, and the target id is
  recorded on the action log. The target carries no area keys of its own.
- `none`: open, no token required.
- `self`: any valid token, caller's own record only.
- `deny`: not available to agent tokens. Always `403`.

| Route | Capability | Check |
|---|---|---|
| `GET /api/health` | none | `none` |
| `GET /api/instances` | none | `none` |
| `GET /api/agent/me` | none | `self` |
| `GET /api/catalog` | `rye.context.read` | `global` |
| `GET /api/events` | `rye.context.read` | `global` |
| `GET /api/nodes` | `rye.context.read` | `global` |
| `GET /api/nodes/:id` | `rye.context.read` | `global` |
| `GET /api/nodes/:id/graph` | `rye.context.read` | `global` |
| `GET /api/nodes/:id/knowledge` | `rye.context.read` | `global` |
| `GET /api/domains` | `rye.context.read` | `global + row filter` |
| `GET /api/context-pack` | `rye.context.read` | `domain + scope` |
| `GET /api/review-queue` | `rye.review.read` | `global + row filter` |
| `GET /api/candidates/review` | `rye.review.read` | `global + row filter` |
| `GET /api/review/assertions` | `rye.review.read` | `global` |
| `GET /api/gaps` | `rye.review.read` | `global` |
| `GET /api/stale-digests` | `rye.review.read` | `global` |
| `GET /api/audit/actions` | `rye.audit.read` | `global` |
| `GET /api/dashboard` | none | `deny` |
| `GET /api/knowledge-map` | none | `deny` |
| `GET /api/workspace/crm` | none | `deny` |
| `GET /api/workspace/pm` | none | `deny` |
| `POST /api/observations` | `rye.observation.create` | `domain + scope` |
| `POST /api/candidates` | `rye.candidate.create` | `domain + scope` |
| `POST /api/candidates/:id/status` | `rye.candidate.adjudicate` | `domain + scope` |
| `POST /api/candidates/:id/promote` | `rye.authoritative.promote` | `domain + scope` |
| `POST /api/candidates/:id/accept-source-policy` | `rye.authoritative.promote` | `domain + scope` |
| `POST /api/candidates/:id/accept-crm-stage-plan` | `rye.authoritative.promote` | `domain + scope` |
| `POST /api/candidates/:id/accept-pm-task-plan` | `rye.authoritative.promote` | `domain + scope` |
| `POST /api/candidates/:id/accept-pm-milestone-plan` | `rye.authoritative.promote` | `domain + scope` |
| `POST /api/assertions/:id/accept` | `rye.authoritative.promote` | `target` |
| `POST /api/assertions/:id/reject` | `rye.candidate.adjudicate` | `target` |

Every capability in that table already exists in the schema. Nothing here
needs a migration.

Four routes are `deny`. `/api/dashboard`, `/api/knowledge-map`,
`/api/workspace/crm`, and `/api/workspace/pm` are whole-instance rollups
built for the reviewer's screen. They have no area dimension to check and no
sensible way to narrow their rows, so handing them to any holder of a
single-area grant would reopen the leak this contract closes. No agent client
calls them. They are console surfaces, and they are reachable only with auth
mode off.

A `global` check is weaker than it looks. It asks whether the token holds the
capability anywhere, not whether it holds it here. `global` routes return
whole-instance data to any agent that holds the capability for one area.
That is deliberate for now: gating reads of individual existing nodes by area
needs a node-to-area mapping that does not exist yet. A `global` row in this
table is a promise that an agent without the capability is refused, not a
promise of area isolation. Do not build an area boundary on a `global` route.

### Row filtering

An area is *held* by a token when the token has an active, unexpired grant
for the route's capability that either names that area or names no area at
all. A grant that names no area is instance-wide and holds every area. This
is the same predicate the schema's `has_agent_capability` applies, called
once per area.

**`GET /api/domains`.** The listing returns only areas the token holds for
`rye.context.read`. Areas it does not hold are absent from the array
entirely, not present with emptied fields. In particular the `authorities`
and `channel_subscriptions` of an area the token does not hold are never
returned, in any shape, on this route or any other. The existing
`rye.domain.admin` gate on the `properties` field is unchanged and applies on
top of this.

**`GET /api/review-queue` and `GET /api/candidates/review`.** The listing
returns only candidates whose area keys include at least one area the token
holds for `rye.review.read`. A candidate that carries no area keys is
returned only to a token whose `rye.review.read` grant names no area. The
total or count a listing reports counts the rows it returned, not the rows it
filtered out.

Filtering removes rows. It never returns a placeholder, a redacted stub, or a
count of what was withheld. A caller cannot tell an area it does not hold
from an area that does not exist, and must not read an absent row as a
deletion.

### 401 versus 403

`401` means the API does not know who is calling. `403` means it knows and
the answer is no.

| Condition | Status | `error` |
|---|---|---|
| No `Authorization` header | `401` | `missing bearer token` |
| Token not recognised | `401` | `invalid bearer token` |
| Token revoked | `401` | `invalid bearer token` |
| Token expired | `401` | `invalid bearer token` |
| Agent identity deactivated | `401` | `invalid bearer token` |
| Valid token, capability not held | `403` | `forbidden` |
| Valid token, capability held for another area or scope | `403` | `forbidden` |
| Valid token, route is `deny` or undeclared | `403` | `forbidden` |
| Path matches no route | `404` | `not found` |

Unrecognised, revoked, and expired tokens are deliberately indistinguishable
to the caller. The API does not tell an attacker which of the three it holds.
A client that needs the difference reads the audit log with an authorised
token.

A `401` may be worth retrying after re-authenticating. A `403` never is. It
is a decision about a grant, and a client surfaces the reason and stops.

### Shape of a 403

```json
{
  "error": "forbidden",
  "reason": "missing capability grant",
  "policy": {
    "action": "domains_list",
    "capability": "rye.context.read",
    "check": "global",
    "domain_keys": ["title-diligence"],
    "scope_ref": null
  }
}
```

`reason` is one of a closed set of strings, so a client can branch on it:

- `missing capability grant`: the route declares a capability and the token
  does not hold it for what was asked.
- `route not available to agent tokens`: the route is `deny` or declares
  nothing. `policy.capability` is `null` and `policy.check` is `deny`.

`policy` names what refused: the action, the capability that was required,
the check that was applied, and the area keys and scope that were tested.
`domain_keys` is `[]` on a `global` or `target` check. `policy` is additive
detail; `reason` is the stable field.

Every `403` is written to the agent action log with `allowed = false` before
the response is sent, on `deny` routes as well as capability failures.

### Auth mode off

With `RYE_API_AUTH_MODE` unset or `off`, nothing in this section applies.
There is no token, no `401`, no `403`, and no row filtering. Every route
including the four `deny` rows answers in full, and `GET /api/agent/me`
reports `auth_required: false` with a null agent. The reviewer's screen is
unaffected by anything in this contract.

That is not a temporary convenience, it is the current shape of the product.
The console SPA sends no bearer token, so with auth required every one of its
calls is a `401` and the screen does not work at all. One Worker today serves
either the reviewer's screen or scoped agents, not both. Putting a human
login in front of the console is separate work and is not promised here.

## Versioning

Unversioned path, additive change only. New routes, new optional query
parameters, and new fields in a response are not breaking. Removing a route
or a response field, making an optional parameter required, or changing what
a capability check permits requires a decision record and an edit here
first. Clients ignore unknown fields.

## Freshness

Every request reads the database live; there is no cache in the API layer.
The Postgres client is reused for the Worker's lifetime, but no result is.
Values sourced from profile materialized views are as fresh as the last
`refresh_materialized_views()`.

## Failure behavior

`400` unknown instance or invalid body. `401` missing or invalid bearer
token. `403` with a `reason` naming the policy that refused. `404` for an
unmatched `/api/*` path. Errors are always
`{"error": "...", "reason"?: "...", "policy"?: {...}}`. The full `401` and
`403` rules and the shape of `reason` are in "Authorization" above.
A `403` is a decision, not a transient failure — clients surface the reason
and stop rather than retrying. RLS invisibility returns empty results with
`200`; a caller must not read that as deletion.
