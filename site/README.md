# Project Rye Site

Astro-based documentation site generated from this repository's Markdown sources.

Rye is an opinionated pattern implemented in PostgreSQL for technical operators who need AI-agent-compatible persistence quickly. It works with existing data, persists context immediately, and supports evolving the target domain model over time.

## What it does

- Syncs docs from `../docs` and `../design/{model,layers,cookbooks}` into `src/content/docs`
- Builds navigable docs pages at `/docs/<section>/<slug>/`
- Generates client-side search from a prebuilt JSON index
- Uses DaisyUI components with Rye color-theme customization
- Includes light, dark, and system theme modes
- Targets Cloudflare Workers deployment via `@astrojs/cloudflare`
- Includes `favicon.svg` and `llm.txt`

## Run locally

```bash
cd site
npm install
npm run dev
```

## Build

```bash
cd site
npm run build
```

## Deploy to Cloudflare Workers

```bash
cd site
npm run deploy
```

`wrangler.jsonc` is preconfigured for Astro Worker output (`dist/_worker.js`) and static assets (`dist`). `public/.assetsignore` excludes `_worker.js` and `_routes.json` from the uploaded asset bundle.

If your deploy reports `Invalid binding "SESSION"`, add a Cloudflare KV namespace for Astro sessions:

```jsonc
"kv_namespaces": [
  { "binding": "SESSION", "id": "<your-kv-namespace-id>" }
]
```
