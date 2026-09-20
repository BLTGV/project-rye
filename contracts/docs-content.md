# Contract: Documentation content

Published by **schema** and **agent-kit** — the markdown they own under
`docs/` and `design/`. Consumed by **site**, whose build copies it in through
`site/scripts/sync-content.mjs`.

This contract exists because the site's build reads directories owned by
other areas. It is the only reason a documentation edit can break a deploy.

## Shape

Plain markdown files in fixed directories, mapped to site sections:

| Source | Section |
|---|---|
| `design/getting-started/**`, `docs/onboarding.md` | getting-started |
| `docs/**` (the rest) | reference |
| `design/model/**` | model |
| `design/layers/**` | layers |
| `design/cookbooks/**` | cookbooks |
| `eval/business_replay_scenarios/report.md` | evaluations |

Every file must be readable on its own: an H1 on the first line, no
frontmatter required, and no relative links out of its own tree. Internal
links use site paths (`/docs/model/schema/`), not repository paths, because
the file is served at a different location than it lives.

`site/src/content/docs/` is generated. It is deleted and rewritten on every
build. Nothing is ever authored there.

## Versioning

Adding a file to a mapped directory publishes a new page; that is the normal
case and needs no coordination. Renaming or deleting a file removes or moves
its URL. Adding a new source directory or changing a section mapping is a
change to this contract and to `site/scripts/sync-content.mjs` together.

## Freshness

Build-time only. The site is a static deploy; content is as fresh as the last
`cd site && npm run build`. There is no revalidation and no runtime read of
the repository.

## Failure behavior

The sync step copies what exists and invents nothing. A missing source
directory yields an empty section rather than an error. A file that Astro
cannot parse fails the build loudly, which is the intended behaviour — a
broken page never deploys. A page removed upstream disappears from the site
with no redirect; if a URL must survive, that is a site change, not a
documentation one.

No customer names appear in any published file. This is enforced by review,
not by the build.
