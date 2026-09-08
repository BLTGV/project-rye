# Areas

Parsed by `scripts/gen-agents` to generate one builder per area. One `##`
heading per area, slug only, then `- key: value` lines. Rerun
`scripts/gen-agents` after editing this file.

Four areas. Each is a separate deploy unit with its own test command and an
interface another area calls. A test file belongs to the area whose behavior
it exercises; the runner scripts that execute the whole suite belong to
`schema`. `scripts/gen-agents`, `agents/`, `work/`, and
the Architect's own files under `docs/` and `contracts/` belong to no area.

## schema

- purpose: The rye schema and the bash that installs, verifies, and tests it. Tables, views, functions, RLS policies, migrations, the profile layers, and the ./scripts/rye CLI. This is the spine every other area is a client of.
- paths: schema/** tests/conformance/*.sql tests/conformance/07_domain_integration.sh tests/conformance/16_cli_smoke.sh tests/conformance/23_cli_agent_security.sh tests/concurrency/** tests/scenarios/** tests/security/** scripts/install.sh scripts/migrate.sh scripts/verify.sh scripts/conformance.sh scripts/docker-test.sh scripts/seed_quickstart.sh scripts/sync_plugin_metadata.sh scripts/rye docker-compose.yml design/model/** design/layers/** design/cookbooks/** docs/data-dictionary.md docs/core-contract.md docs/core-model-v2.md docs/cli.md
- invariants:
  - Assertions are superseded, never updated. Events are never deleted. A correction is a new row.
  - Nothing in rye holds a foreign key into a domain table. DROP SCHEMA rye CASCADE leaves every domain schema working.
  - A migration is a new numbered file under schema/migrations. An applied file is never edited.
  - Authorization is session variables only. Never current_user, never pg_has_role(), never a second model.
  - Every function declares its own SET search_path. RLS is enabled and forced on all core and supporting tables.
  - No runtime, ORM, framework, or package manager. SQL and bash only.
- publishes: contracts/sql-surface.md contracts/rye-cli.md contracts/category-vocabulary.md contracts/docs-content.md
- consumes: contracts/plugin-manifest.md
- test: ./scripts/docker-test.sh test --reset --profiles crm,pm

## agent-kit

- purpose: What an agent is given: skills as procedures, plugins as vocabulary manifests, and replay scenarios that grade whether a clean-room agent can actually do the job. Includes the MCP servers and intake scripts skills shell out to.
- paths: skills/** plugins/** eval/** tests/conformance/22_secure_mcp_simulation.sh docs/onboarding.md docs/agent-ops-guide.md docs/conventions-catalog.md
- invariants:
  - An agent writes candidates. Only a person's accept makes a claim current.
  - A write outside the scope's enabled plugin vocabulary is refused, and the refusal names the policy that blocked it.
  - A helper write carries evidence unless its basis is assumed.
  - Every manifest validates against skills/rye-skill.schema.json or plugins/rye-plugin.schema.json.
  - No customer names in skills, plugins, fixtures, or eval scenarios.
  - A skill reaches the database through the CLI, the admin API, or the helper functions. Never a raw write to a base table.
- publishes: contracts/plugin-manifest.md contracts/docs-content.md
- consumes: contracts/sql-surface.md contracts/rye-cli.md contracts/category-vocabulary.md contracts/admin-api.md
- test: npm --prefix skills/rye-source-context-intake run check && bash tests/conformance/22_secure_mcp_simulation.sh

## admin

- purpose: The reviewer's screen and the agent's HTTP API, on one Cloudflare Worker. React SPA plus a Hono API that proxies SQL to one of several configured Rye instances. Also holds the demonstration domain surfaces.
- paths: admin/** surfaces/** tests/conformance/21_api_security.sh
- invariants:
  - Every query sets the RLS session variables inside the same statement. The pooler rejects the multi-statement form and a bare SELECT under RLS returns zero rows.
  - Every /api/* request resolves exactly one instance and never reads across instances.
  - Lifecycle changes go through the schema's helper functions. The API never updates assertions, events, or their status columns directly.
  - A bearer token authenticates an agent and then maps to session variables. It never widens what RLS would allow.
  - The console reviews knowledge. It is not the day-to-day screen for domain records.
- publishes: contracts/admin-api.md
- consumes: contracts/sql-surface.md contracts/category-vocabulary.md
- test: cd admin && npm run build

## site

- purpose: The public documentation site. Astro on Cloudflare, built from the markdown in docs/ and design/ by a sync step. Read-only; it never touches a database.
- paths: site/**
- invariants:
  - Content is authored in docs/ and design/. site/src/content/docs is generated and clobbered on every build.
  - The site reads no database and holds no secrets.
  - A page that disappears from docs/ or design/ disappears from the site. The sync step never invents content.
  - No customer names in published content.
- publishes: none
- consumes: contracts/docs-content.md
- test: cd site && npm run build
