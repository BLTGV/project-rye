# admin

Purpose: The reviewer's screen and the agent's HTTP API, on one Cloudflare Worker. React SPA plus a Hono API that proxies SQL to one of several configured Rye instances. Also holds the demonstration domain surfaces.
Paths: admin/** surfaces/**
Test: cd admin && npm run build

## Learned
Dated entries. What a stranger would need to know and could not read from the code.
- 2026-09-07: no npm test; `npm run build` (tsc -b && vite build) is the only gate and is what CI runs.
- 2026-09-19: the `/api/*` auth middleware used to authenticate and call `next()`, with gating left to each handler; 14 handlers never checked a capability (GitHub issue 16). Authorization is now one declarative table, `admin/src/server/route-policy.ts`, consulted by the middleware through a pure `routeDecision`. An agent token is refused on any route without a row.
- 2026-09-19: Hono dispatches HEAD to the GET handler and records the route in `app.routes` as `GET`. Any method-keyed authorization table must fold HEAD into GET in both the policy lookup and the registry lookup, or HEAD is an unchecked mirror of every GET route. This was a real bypass, caught by the Verifier.
- 2026-09-19: `withAdminCte()` in `admin/src/server/db.ts` sets `app.current_role = 'admin'` on every statement, so RLS narrows nothing for an agent. Row filtering for agent callers must be explicit in the SQL.
- 2026-09-19: `has_agent_capability` with empty area keys answers "holds it somewhere", and it silently drops keys that `rye_slugify_key` maps to NULL. A filter over suggestion area keys must test sluggability, not array length. "Holds an instance-wide grant" has no schema helper; the API evaluates it from the grant rows `authenticate_agent_token` returns. A schema helper would remove that exception.
- 2026-09-19: `authenticate_agent_token` already returns NULL for unknown, revoked, expired, and deactivated tokens, so every 401 case shares one path. With auth required, an unmatched path returns 401 without a token and 404 with one.
- 2026-09-19: the console SPA sends no `Authorization` header. With `RYE_API_AUTH_MODE=required` the reviewer's screen is fully 401, so today one Worker serves the console or agents, not both. A login in front of the console is its own item.
- 2026-09-19: `npm run check:routes` (`admin/scripts/route-policy-check.ts`) is the only admin test that runs without a database. It asserts every route Hono serves has a policy row and that no method bypasses it, so it fails the day a route is added without a contract entry. `zValidator` registers duplicate entries for the same path and method; dedupe before counting routes.
- 2026-09-19: `npm install` in a fresh admin worktree fails on `sharp` because its install script runs before the `@img/*` optional packages are linked. Run `npm ci --ignore-scripts`, then `npm install`.
- 2026-09-19: review-queue assertions in `21_api_security.sh` must use the `q` filter, not `limit`. The queue caps at 200 and other suites leave rows behind, so a bare listing can page a target row off the end and make an absence check pass vacuously. The script starts two API servers, one with auth required and one with it off.
- 2026-09-19: the `rye.domain.admin` gate on the domains `properties` field does not check grant expiry. Pre-existing, untouched by work/003. Open as its own item.
- 2026-09-19: promotion archives the candidate node (`promote_candidate_node_to_assertion` in 0017 sets `archived_at`), so a promoted suggestion vanishes from the review queue for every caller. Any queue assertion about a suggestion must run before it is promoted. `stats.total` counts area-visible suggestions and `stats.filtered` counts those surviving status, kind, and `q`; they differ legitimately.
