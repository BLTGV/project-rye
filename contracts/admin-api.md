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
  grants for the domain keys and scope in the request.
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
unmatched `/api/*` path. Errors are always `{"error": "...", "reason"?: "..."}`.
A `403` is a decision, not a transient failure — clients surface the reason
and stop rather than retrying. RLS invisibility returns empty results with
`200`; a caller must not read that as deletion.
