# admin

Purpose: The reviewer's screen and the agent's HTTP API, on one Cloudflare Worker. React SPA plus a Hono API that proxies SQL to one of several configured Rye instances. Also holds the demonstration domain surfaces.
Paths: admin/** surfaces/**
Test: cd admin && npm run build

## Learned
Dated entries. What a stranger would need to know and could not read from the code.
- 2026-09-07: no npm test; `npm run build` (tsc -b && vite build) is the only gate and is what CI runs.
