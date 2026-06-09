# Project Rye Site

Astro-based documentation site generated from this repository's Markdown sources.

Rye is an open source, agent-native temporal knowledge graph data model for PostgreSQL. The site presents Rye as a SQL schema that overlays existing domain tables, preserves temporal assertions and provenance, and supports scope-first agent onboarding through plugin policy.

## What it does

- Syncs docs from `../docs` and `../design/{getting-started,model,layers,cookbooks}` into `src/content/docs`
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
