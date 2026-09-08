# site

Purpose: The public documentation site. Astro on Cloudflare, built from the markdown in docs/ and design/ by a sync step. Read-only; it never touches a database.
Paths: site/**
Test: cd site && npm run build

## Learned
Dated entries. What a stranger would need to know and could not read from the code.
- 2026-09-07: the build sync step picks up new files under docs/ automatically (confirmed with docs/runbooks/deploy.md).
