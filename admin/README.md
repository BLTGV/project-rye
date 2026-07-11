# Rye Admin Console

A Cloudflare-deployable admin interface for one or many Rye-on-Postgres
instances. Single Worker that ships the React SPA plus a Hono API that proxies
SQL to each configured instance with the rye RLS admin context set per query.

## Stack

| Concern | Choice |
|---|---|
| Edge runtime | Cloudflare Workers (`nodejs_compat`) |
| HTTP routing | Hono |
| Postgres client | `postgres` (postgres.js) over the Supabase pooled connection |
| Frontend | React 19, React Router 7, TanStack Query, Tailwind v4 |
| Charts | Recharts |
| Graph | Cytoscape.js |
| Command palette | cmdk |
| Multi-instance | JSON config in the `RYE_INSTANCES` secret |

## Architecture

- Every `/api/*` request reads `?instance=<id>` or `X-Rye-Instance` and picks
  a connection from `RYE_INSTANCES`. The matching `postgres` client is cached
  for the worker's lifetime.
- Every query is wrapped with
  `WITH cfg AS (SELECT set_config('app.current_role','admin',false)) …, cfg`
  so the rye RLS session variable is set within the same statement.
  (Supabase's pooler rejects the multi-statement form, and a bare `SELECT`
  under RLS returns zero rows.)
- The static SPA is served from the Worker's asset binding with SPA fallback,
  so client-side routing works out of the box.

### Admin and agent access modes

The Worker has two deployment postures:

- With `RYE_API_AUTH_MODE=off` (the default), it is a trusted administrative
  surface. Use this only for local development or behind an authenticated
  boundary such as Cloudflare Access.
- With `RYE_API_AUTH_MODE=required`, it is a scoped agent API. Bearer tokens are
  authenticated as Rye agent identities. Only explicitly allowlisted agent
  routes are reachable, and those routes apply capability and domain checks.
  Agent tokens can use scoped context, domain, redacted node search/summary,
  candidate, review, adjudication, promotion, and governed-process routes.
  They cannot call dashboard, catalog, workspace, raw node, graph, event, or
  dispute routes backed by administrative queries.

Do not expose the admin SPA by enabling agent-token authentication on the same
public route. Deploy the trusted admin surface behind human authentication and
the scoped agent API on a separate route or Worker deployment.

## Configure

```bash
cd admin
npm install
# Local secrets for dev — never commit:
cat > .dev.vars <<'EOF'
DEFAULT_INSTANCE=local
RYE_INSTANCES='[{"id":"local","label":"Local Rye","blurb":"Local PostgreSQL instance","databaseUrl":"postgresql://user:<password>@host:5432/dbname"}]'
EOF
```

## Local Development

Use the fixed local ports below so browser links, proxying, and screenshots do
not drift between sessions:

| Process | Command | URL |
|---|---|---|
| API | `npm run dev:api` | `http://127.0.0.1:8799` |
| UI | `npm run dev` or `npm run dev:ui` | `http://omarchy:5180` |

The Vite UI proxies `/api` to `127.0.0.1:8799`. Override only when that port is
truly unavailable:

```bash
RYE_ADMIN_API_PORT=8899 npm run dev:api
RYE_ADMIN_API_PORT=8899 npm run dev
```

Keep both commands on the same `RYE_ADMIN_API_PORT` if you override it.

For Worker-runtime testing instead of the Node API runner:

```bash
wrangler dev
```

## Deploy

```bash
wrangler secret put RYE_INSTANCES   # paste the JSON config
npm run deploy
```

The same Worker handles every configured instance — switch between them in the
sidebar.

If `DEFAULT_INSTANCE` is blank, the API uses the first configured instance unless
the request supplies `?instance=<id>` or `X-Rye-Instance`.

## What's implemented

| Route | Purpose |
|---|---|
| `/` | Operating-picture dashboard: KPIs, 90-day quote flow, node composition, top clients by revenue, live activity, edge-type breakdown |
| `/search` | Trigram-ranked record browser with type filters |
| `/nodes/:id` | Node deep-dive: properties, neighborhood graph (1–3 hops), assertions, edges, activity |
| `/graph` and `/graph/:id` | Free-form graph explorer with anchor switcher |
| `/events` | Activity log with quick filter and property chips |
| `/disputes` | Subjects with multiple active assertions of the same type |

The scoped agent deployment also exposes:

| API route | Capability |
|---|---|
| `GET /api/nodes/search` and `GET /api/nodes/:id/summary` | `rye.context.read` with complete temporal domain coverage |
| `GET /api/review-queue` | `rye.review.read` in every candidate domain |
| `POST /api/candidates/:id/status` | `rye.candidate.adjudicate` |
| `POST /api/candidates/:id/promote` | `rye.authoritative.promote`; process candidates cannot bypass evaluation |
| `POST /api/candidates/:id/process-transition/evaluate` | adjudicate for preview, authoritative promotion for apply |

`GET /api/read-models/freshness` is admin-only. CRM and PM workspace routes
enforce their configured read-model freshness policy before returning data.

Command palette: `⌘K` opens a fuzzy node finder anywhere in the app.

## Remaining deployment work

- **Vector search.** `pgvector` is available on Supabase but not yet installed
  on the production instance. Enable with `CREATE EXTENSION vector;`, add a
  `claim_embedding vector(1536)` column to `rye.assertions`, then we can swap
  the trigram ORDER BY for an ANN search.
- **Human admin authentication.** The admin SPA still relies on its deployment
  boundary for human authentication. Put Cloudflare Access or an equivalent
  identity-aware proxy in front of it before exposing it publicly.

## Multi-instance config shape

```jsonc
[
  {
    "id": "local",
    "label": "Local Rye",
    "blurb": "Local PostgreSQL instance",
    "databaseUrl": "postgresql://user:****@host:5432/dbname"
  },
  {
    "id": "staging",
    "label": "Staging Rye",
    "databaseUrl": "postgresql://user:****@db.<project-ref>.supabase.co:5432/postgres"
  }
]
```
