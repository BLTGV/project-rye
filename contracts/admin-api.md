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

### Every method is decided, and HEAD is decided as GET

No method on any path reaches a handler without a policy decision. There is no
method the middleware passes through unjudged.

Any method the framework dispatches to a `GET` handler is authorized as `GET`.
That is `HEAD` today: a `HEAD` request is judged by the `GET` row for the same
path, and it is refused, deferred, or allowed exactly as the `GET` would be.
The route table lists no `HEAD` rows and never will. If the framework ever
dispatches another method to a `GET` handler, that method is authorized as
`GET` too, by this rule and without an edit here.

A method with no row of its own and no handler of its own is undeclared, and
undeclared is refused. A route table row constrains its own method only:
declaring `GET /api/nodes` opens nothing for `POST /api/nodes`.

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

### Rejecting through the API is a capability, not authorship

The schema gained an authorship rule in `0037`: an agent-shaped SQL session may
close only a candidate it recorded, and only an admin closes a suggestion of a
configuration type (`contracts/sql-surface.md`, "Who may reject a suggestion").
That rule does **not** bind this API, and the difference is deliberate rather
than an oversight. The Worker sets `app.current_role = 'admin'` on every query,
so the database sees an admin; what decides here is the route table —
`POST /api/assertions/:id/reject` requires `rye.candidate.adjudicate`, checked
against the target. A token holding that capability may therefore close a
suggestion it did not write, because a person granted it adjudication. A client
must not read the schema rule as covering this route, and a deployment that
wants the narrower rule does not grant `rye.candidate.adjudicate`.

`GET /api/nodes/:id/graph` and the knowledge map return fewer edges from `0037`
onward when an operator marks an edge with `attrs.classification` or
`attrs.teams`, on exactly the same terms that already apply to marked nodes:
there is no admin exemption in the node or edge read rule, only teams and
grants.

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

"Holds an instance-wide grant" is the one authorization question the API
answers itself. Everywhere else the schema decides. Here it cannot:
`has_agent_capability` with no area keys answers "holds this capability
somewhere", which is a different and wider question, and no schema helper
expresses "holds a grant that names no area". The API answers it from the
grant rows `authenticate_agent_token` returned for this token, so it is the
same data and the same authorization model, read one layer out. This is a
known and bounded exception to "checks go through the schema's authorization
helpers", recorded in `docs/decisions/0006-agent-tokens-deny-by-default.md`,
and it is removed when a schema helper expresses the narrower question.
Ruled on 2026-09-20 in `docs/decisions/0013-leftovers-fail-restrictive.md`: no
such helper is planned. It would move the exception rather than remove it — the
API needs the answer for the token it has just authenticated and already holds
that token's grant rows, so a helper would cost a round trip to re-read them.
The sentence above stands as a standing offer, not a plan, and the predicate is
pinned from outside by `tests/conformance/21_api_security.sh` instead.

The grant rows this predicate reads come from `authenticate_agent_token()`,
which already excludes inactive and expired grants. Every capability test in the
API therefore inherits expiry from the schema, including the `rye.domain.admin`
gate on the domains `properties` field, which does not test expiry itself. That
inheritance is the rule, not an accident, and it is pinned by the same test
file.

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

Only keys that survive `rye_slugify_key()` count as area keys here. A blank
string, or a value made entirely of punctuation, slugifies to nothing and is
not an area key. A candidate whose keys are all blank or junk therefore has no
area keys at all, and takes the restrictive branch: it is returned only to a
token holding an instance-wide `rye.review.read` grant. Junk never widens
access.

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
| No or invalid token, path matches no route | `401` | as the two rows above |
| Valid token, path matches no route | `404` | `not found` |

With auth required, a caller holding no valid token gets `401` on every
`/api/*` path, whether or not a route exists there. Authentication comes
first, because the API cannot tell an undeclared route from a nonexistent one
until it knows who is asking, and because an anonymous caller is not told
which paths exist. `404` on an `/api/*` path is a fact about the deployment,
and it is answered only to a caller the API has authenticated. The two exempt
routes, `GET /api/health` and `GET /api/instances`, are unaffected: they take
no token and are matched before authentication runs.

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

## Review fields and counts

The review routes project the views in `contracts/sql-surface.md`, section
"Review surfaces". Everything below is additive: new response fields and one
new optional query parameter. Clients ignore fields they do not know.

**`GET /api/review/assertions`** gains, per group: `incumbent.effective_confidence`
(now populated from the view rather than recomputed), `incumbent.is_current`,
`waiting_reason` (`settle_gate`, `review_gate`, or `none`), and
`waiting_detail`. Per candidate: `projected_effective_confidence`,
`evidence_count`, `witness_count`, `evidence_kinds`, `latest_evidence_at`. The
`basis_prior` field stays for one release as the chip's fallback and is
deprecated by `projected_effective_confidence`.

`incumbent` changes meaning in one direction and the change is stated: it is now
the accepted, unsuperseded assertion an acceptance would supersede, which may be
one that is not currently effective. `incumbent.is_current` carries the old
distinction, so a client that wants the previous behaviour reads
`is_current === true`.

**`?state=`** is a new optional parameter on `GET /api/review/assertions`:
`waiting` (the default, today's behaviour) or `rejected`, which returns
`rejected_candidates` rows with `rejected_at`, `rejected_by`,
`rejected_reason`, `rejected_outcome`, and `rejection_event_id`. It is the same
route, the same capability, and the same row filtering; rejected suggestions are
never mixed into the waiting list.

**`GET /api/stale-digests`** gains `newer_assertion_ids`,
`newer_latest_asserted_at`, and `overturned_source_assertion_ids`, so a stale
badge can link to what made it stale.

**`GET /api/workspace/crm`** gains `freshness`:
`{snapshot_at, age_seconds, stale_after_seconds, stale, row_count}` for
`opportunities_active`. It is an age marker, not change detection: `stale` false
does not promise the underlying rows are unchanged. The route stays `deny` for
agent tokens.

Every candidate recorded from `0037` onward carries its author at
`attrs.recorded_by` — the `app.current_role` of the session that wrote it — and
the review routes already return `attrs`, so "suggested by" needs no new field.
Rows written earlier carry no author, and absence means unknown, never "a
person".

A null `incumbent`, a null field, or an empty list is RLS silence, not absence.
A caller that cannot read an incumbent sees no incumbent, and must not conclude
there is none.

### `stats.total` and `stats.filtered`

Both appear on `GET /api/candidates/review` and `GET /api/review/assertions`,
and they mean the same thing on both:

- **`total`** counts every row the caller is entitled to see on this route,
  after RLS and after the area row filter in "Row filtering", and **before** the
  request's own `status`, `kind`, `assertion_type`, `competingOnly`, and `q`
  filters. It never counts a row that was withheld.
- **`filtered`** counts the rows that survive those request filters, still
  before `limit` and `offset`.

Three consequences a client may rely on: `filtered <= total`; neither depends on
`limit` or `offset`, so paging does not move them; and the returned array's
length is at most `min(filtered, limit)` and is less than `filtered` whenever
paging applies. A test that compares a total against a page's length is testing
the page size, not the count — compare against `filtered`, and compare `total`
only with no request filters set. The facet counts (`statuses`, `kinds`,
`types`) are computed on the same population as `total`, which is why a facet
can exceed `filtered`.

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
token, on any `/api/*` path including one that matches no route. `403` with a
`reason` naming the policy that refused. `404` for an unmatched `/api/*` path,
to an authenticated caller. Errors are always
`{"error": "...", "reason"?: "...", "policy"?: {...}}`. The full `401` and
`403` rules and the shape of `reason` are in "Authorization" above.
A `403` is a decision, not a transient failure — clients surface the reason
and stop rather than retrying. RLS invisibility returns empty results with
`200`; a caller must not read that as deletion.
