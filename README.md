# Project Rye Implementation Scaffold

This repo includes an executable Rye implementation scaffold based on the design docs.

## Fast Start

Use the hosted onboarding script to choose where Rye should live.

### Try Rye Locally

This starts PostgreSQL in Docker, installs Rye, writes `.rye.env` (the local
connection config — created for you, no need to write it by hand), and leaves
the database running. It is the fastest way to try Rye before migrating to a
remote database later.

```bash
curl -fsSL https://projectrye.dev/onboard | sh
```

The bootstrap installs the Rye schema and syncs portable Rye metadata for
plugins, skills, capabilities, and contributed node, edge, assertion, event,
and artifact types. It does not add example data unless you pass `--seed`.

### Install Into A Remote Database

Use an existing PostgreSQL 15+ database. Rye installs its schema alongside
existing tables and does not reset remote data.

```bash
curl -fsSL https://projectrye.dev/onboard | sh -s -- --remote "$DATABASE_URL"
```

### Agent-Led Onboarding

Install the Rye onboarding skill with the `skills` CLI — an npm tool that adds
reusable instruction packs ("skills") to a project so coding agents like Codex
or Claude Code can follow them. Run it via `npx` (no global install needed) in
the project folder where your agent will work:

```bash
npx skills add BLTGV/project-rye --skill rye-onboarding
```

The onboarding skill will install `rye-installer` on demand if the agent needs
installation, migration, verification, or conformance guidance.

Then open Codex in that same folder and start with:

```text
Use the Rye onboarding skill. Check whether Rye is installed, run
./scripts/rye status, then help me create the first onboarding scope.

Start by asking what limited workflow or organizational purpose Rye should
assist first. Do not ingest sources or promote facts until the scope, boundary,
expected contexts, and review policy exist.
```

The scope should be named after the organizational purpose or workflow, not the
source or retrieval channel.

### Repo-Local Commands

If you already cloned the repo:

```bash
./scripts/rye init local --fresh
./scripts/rye init remote --db-url "$DATABASE_URL"
./scripts/rye catalog plugins
./scripts/rye catalog skills
./scripts/rye catalog capabilities --json
./scripts/rye context --json
./scripts/rye onboard create --label "First Scope" --purpose "Describe the limited workflow Rye should assist first."
./scripts/rye status
```

The older aliases still work: `local`, `remote`, `plugins list`, and
`onboard --label ...`.

## Requirements

- PostgreSQL 15+
- Either:
  - `psql` CLI available in PATH, or
  - Docker + Docker Compose (`docker compose` or `docker-compose`)

## Lower-Level Install

```bash
export DATABASE_URL='postgresql://user:pass@host:5432/dbname'
./scripts/install.sh --profiles crm,pm
```

## Optional seed

Seed means quickstart example data, not Rye vocabulary or skill metadata.
Portable plugin, skill, and capability metadata is installed automatically by
the fast-start commands.

```bash
./scripts/install.sh --profiles crm,pm --seed
```

## Verify

```bash
./scripts/verify.sh
```

## Design Docs

- `docs/onboarding.md` describes onboarding scopes, source/channel/context
  separation, expected contexts, context gaps, and plugin policy helpers.
- `docs/roadmap.md` records the undated improvement roadmap.
- `docs/conventions-catalog.md` lists graph conventions and type vocabulary.
- `docs/vocabulary-contract.md` fixes the internal/plain-language boundary for
  agents addressing non-technical people.
- `docs/observed-authoritative-process.md` is the design contract for future
  process governance: observed and authoritative process as parallel temporal
  lineages with derived divergence.

## Conformance tests

```bash
./scripts/conformance.sh
```

Conformance security tests must run with RLS enforcement. If `DATABASE_URL` connects as a superuser, `conformance.sh` automatically:

- creates/uses a non-superuser test role (`rye_conformance` by default),
- grants required schema/table/sequence/function privileges,
- runs SQL suites with `SET ROLE`.

Override the role name with:

```bash
RYE_TEST_ROLE=my_test_role ./scripts/conformance.sh
```

## Docker Test Flow

This path is for full install and conformance testing. New users should prefer
`./scripts/rye local --fresh`.

```bash
# Full reset + install + seed + conformance
./scripts/docker-test.sh test --reset --profiles crm,pm
```

Useful Docker commands:

```bash
# Start only
./scripts/docker-test.sh up

# Stop containers
./scripts/docker-test.sh down

# Stop and remove data volume
./scripts/docker-test.sh down --volumes
```

Defaults:

- Postgres image: `postgres:15` (multi-arch, works on Apple Silicon)
- Host port: `54329`
- User/password/db: `rye` / `rye` / `rye`

If you already use `54329`, set `RYE_POSTGRES_PORT` before running.

## Assertion write model

- Direct `INSERT` into `assertions` is allowed (subject to RLS).
- Direct `UPDATE` on `assertions` is blocked by policy.
- Use `supersede_assertion(...)` to change single-valued active facts.

## Profile toggles

- Core only: `./scripts/install.sh --profiles ''`
- Core + CRM: `./scripts/install.sh --profiles crm`
- Core + PM: `./scripts/install.sh --profiles pm`
- Core + CRM + PM: `./scripts/install.sh --profiles crm,pm`

## Skills

Skill folders are under `skills/`:

- `rye-installer`
- `rye-agent-ops`
- `rye-domain-onboarding`
- `rye-import-inspector`
- `rye-knowledge-reader`
- `rye-onboarding`
- `rye-pattern-library`
- `rye-source-context-intake`
- `rye-tabular-intake`
