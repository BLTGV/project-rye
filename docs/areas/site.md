# site

Purpose: The public documentation site. Astro on Cloudflare, built from the markdown in docs/ and design/ by a sync step. Read-only; it never touches a database.
Paths: site/**
Test: cd site && npm run build

## Learned
Dated entries. What a stranger would need to know and could not read from the code.
- 2026-09-07: the build sync step picks up new files under docs/ automatically (confirmed with docs/runbooks/deploy.md).
- 2026-09-19: three places enumerate cookbooks and need a manual addition for each new page: the `cookbooks` array in `site/src/lib/docs.ts`, `outcomeDescriptionsBySourcePath` in `site/scripts/sync-content.mjs`, and the hand-maintained `site/public/llm.txt`, which no script generates.
- 2026-09-19: the sync step publishes everything under `docs/` recursively as "reference", excluding only `docs/onboarding.md`. That includes `docs/areas/*`, `docs/decisions/*`, `docs/runbooks/*`, `docs/product.md`, `docs/architecture.md`, and `docs/agent-authorization-strategy.md`. `design/proposals/` is not in the sources list and is not published. A doc that should stay internal needs an explicit exclude.
- 2026-09-19: `npm ci` in `site/` fails building `sharp` from source; `npm ci --ignore-scripts` followed by the build works and leaves the lockfile unchanged.
