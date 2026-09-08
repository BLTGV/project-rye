# Rye Architecture

Owner: Architect role. What the parts are, how data moves between them, the
decisions that shape everything else, and what is deliberately out of scope.
Why the data model looks the way it does is in `design/model/overview.md`;
this document does not repeat it. Areas and their test commands are in
`docs/areas.md`; interfaces between areas are in `contracts/`.

## Components

Five things ship. Four are areas with owners and tests; the fifth is the
customer's own database, which Rye never owns.

| Component | What it is | How it ships |
|---|---|---|
| **Schema core** | The `rye` schema: tables, views, functions, RLS policies, plus the bash that installs and tests it | SQL files applied by `scripts/migrate.sh`; no build step |
| **Rye CLI** | `scripts/rye` — install, status, doctor, scope creation, catalogs, agent tokens | bash over `psql`; part of the schema core area |
| **Agent kit** | `skills/` (agent procedures), `plugins/` (vocabulary manifests), `eval/` (replay scenarios) | Markdown, JSON manifests, and a few Node scripts, copied or installed into an agent host |
| **Admin console** | React SPA plus a Hono API on one Cloudflare Worker; also serves the agent HTTP API | `wrangler deploy` |
| **Docs site** | Astro site built from `docs/` and `design/` | `wrangler deploy` |
| *Host database* | The organization's existing PostgreSQL 15+ or Supabase instance | not ours |

## Data flow

Three flows matter. All three end in the same place: assertions with basis
and evidence, which people accept.

**In, from systems that already run.** Domain tables stay where they are.
`link_record()` registers a row in `node_source_map` and mints a node;
`track_table()` attaches a CDC trigger so later changes arrive as events.
Nothing in the domain schema is altered and nothing there points at `rye`.

**In, from sources and conversation.** A skill in the agent kit reads a
source or interviews a person, then writes a *candidate* assertion with
evidence rows. Candidates never answer questions. They surface in
`review_queue` (and `competing_candidates` when two disagree), a person calls
`accept_assertion()` or `reject_candidate()`, and only then does the claim
become current. What the agent may write at all is bounded by the scope's
enabled plugins and knowledge policy; a term outside them is refused with the
policy named.

**Out.** Three readers, one truth. Agents read `rye_agent_context()`,
`agent_node_summary()`, and digests — summaries first, then what no summary
covers. The admin console reads the same views over HTTP. A person on the CLI
reads the same JSON. None of them bypass the helper functions, so RLS,
redaction, and evidence rules apply identically to all three.

## Decisions that shape everything

Recorded with their rejected alternatives in `docs/decisions/`.

1. **The SQL surface is the only spine.** Every other component is a client
   of the `rye` schema. No area holds state the schema does not hold, and no
   area reaches around the helper functions into base tables. This is what
   lets the admin console, the CLI, and an agent's raw `psql` session all be
   correct without coordinating.
2. **Overlay, never owner.** The graph points at domain tables through
   `node_source_map`; domain tables never point back. `DROP SCHEMA rye
   CASCADE` leaves every operational system running. This constrains every
   integration: no foreign keys out of `rye`, no columns added to a
   customer's table, no trigger that can fail a customer's write.
3. **Append-only.** Assertions are superseded, never updated. Events are
   never deleted. Corrections are new rows. Storage growth is therefore a
   design constraint in every area now, and there is no cleanup pass.
4. **Suggest by default.** The agent's write path and the person's accept
   path are different code paths with different permissions. The line moves
   per scope, deliberately, and every move is recorded.
5. **Authorization is session variables, one model.** `app.current_role`,
   `app.current_user_id`, `app.current_teams`, set inside the same statement
   as the query (Supabase's pooler gives a fresh connection per call). Never
   `current_user`, never `pg_has_role()`, never a second model in the app
   tier. The admin API's bearer tokens authenticate an *agent* and then map
   to these variables; they are not a parallel authorization system.
6. **No dependency chain in the core.** The schema core has no runtime, ORM,
   framework, or package manager — SQL and bash only. Node and npm exist in
   `admin/`, `site/`, and a few agent-kit scripts, and each is optional to
   running Rye. A test that needs Node skips cleanly where Node is absent.
7. **Vocabulary arrives as plugins.** New node, edge, and assertion types
   need no migration. A plugin manifest declares what it contributes; a scope
   enables it; the schema enforces it. Turning a plugin off never deletes
   knowledge accepted under it.

## Where the seams are

- `contracts/sql-surface.md` — schema core to everything else. The one
  contract a change is most likely to break.
- `contracts/rye-cli.md` — schema core to skills that shell out.
- `contracts/admin-api.md` — admin console to agents (the MCP server in the
  agent kit is a client).
- `contracts/plugin-manifest.md` — agent kit to the schema core, which loads
  manifests into the database as portable metadata.
- `contracts/docs-content.md` — the markdown trees the docs site builds from.

## Out of scope

- **A second store.** No search index, no vector database, no separate graph
  engine. If traversal becomes the bottleneck, Apache AGE inside the same
  PostgreSQL is the escape hatch, not a new system.
- **Being the day-to-day domain UI.** The admin console reviews knowledge.
  Domain applications keep their own screens; `surfaces/` holds demonstration
  screens only.
- **Automatic retention.** Nothing decides on its own that knowledge is stale
  enough to delete. Digests may be marked outdated; rows are not removed.
- **A vendor.** No connector, chat tool, or hosting provider is required.
  Cloudflare is where the console and site happen to deploy, not a dependency
  of the core.
- **A migration engine.** `scripts/migrate.sh` applies numbered files forward
  and records them in `public.rye_migrations`. There is no down migration and
  no dependency resolution.
- **Multi-tenancy inside one schema.** One `rye` schema serves one
  organization. The admin console talks to several instances; the schema does
  not know they exist.
