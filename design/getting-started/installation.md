# Installation

## Get Rye running with the CLI

The fastest path is the hosted onboarding script. It asks where Rye should live
and then runs the same repo-local install flow described below.

```bash
curl -fsSL https://projectrye.dev/onboard | sh
```

For a remote PostgreSQL 15+ database:

```bash
curl -fsSL https://projectrye.dev/onboard | sh -s -- --remote "$DATABASE_URL"
```

The bootstrap installs the Rye schema and syncs portable metadata for plugins,
skills, capabilities, and contributed node, edge, assertion, event, and artifact
types. It does not add example data unless you pass `--seed`.

## Requirements

- PostgreSQL 15+
- Docker plus Docker Compose for local installs
- `psql` for remote database installs
- `bash`

## Repo-Local Install

Clone the repo if you want to run commands directly:

```bash
git clone https://github.com/BLTGV/project-rye.git
cd project-rye
```

Start a fresh local PostgreSQL container and install Rye:

```bash
./scripts/rye init local --fresh
```

Install into an existing database:

```bash
./scripts/rye init remote --db-url "$DATABASE_URL"
```

Both commands write connection state to `.rye.env` so later commands can find
the same instance.

## Verify the Install

Check database reachability and synced metadata totals:

```bash
./scripts/rye doctor
```

Inspect the current instance:

```bash
./scripts/rye status
```

List portable metadata:

```bash
./scripts/rye catalog plugins
./scripts/rye catalog skills
./scripts/rye catalog capabilities
```

Use JSON when an agent or script needs machine-readable context:

```bash
./scripts/rye status --json
./scripts/rye context --json
```

## Create the First Scope

Before agents ingest sources or promote assertions, create an onboarding scope:

```bash
./scripts/rye onboard create \
  --label "First Scope" \
  --purpose "Describe the limited workflow Rye should assist first."
```

The command records purpose, boundaries, default review policies, allowed types,
and enabled plugins. It then activates the scope.

## Agent-Led Onboarding

Install the Rye onboarding skill with the `skills` CLI — an npm tool that adds
reusable instruction packs ("skills") to a project so coding agents can follow
them. Run it via `npx` in the project folder where your agent will work:

```bash
npx skills add BLTGV/project-rye --skill rye-onboarding
```

Then ask your agent:

```text
Use the Rye onboarding skill. Check whether Rye is installed, run
./scripts/rye status, then help me create the first onboarding scope.

Start by asking what limited workflow or organizational purpose Rye should
assist first. Do not ingest sources or promote facts until the scope, boundary,
expected contexts, and review policy exist.
```

Name the scope after the organizational purpose or workflow, not the source or
retrieval channel.

## Lower-Level Install

Use the install script directly when you need a smaller building block:

```bash
export DATABASE_URL='postgresql://user:pass@host:5432/dbname'
./scripts/install.sh --profiles crm,pm
```

Seed example data only when you need quickstart records:

```bash
./scripts/install.sh --profiles crm,pm --seed
```

Portable plugin, skill, and capability metadata is installed automatically by
the fast-start commands.

## SQL Session Context

Most direct SQL examples assume this search path:

```sql
SET search_path = rye, public, pg_catalog;
```

Rye enforces row-level security through session variables:

```sql
SET LOCAL "app.current_user_id" = 'your-user-id';
SET LOCAL "app.current_teams" = 'team-a,team-b';
SET LOCAL "app.current_role" = 'operator';
```

The CLI sets the admin context inside the statements it runs. Applications and
custom SQL sessions must set their own context before reading or writing
RLS-protected Rye objects.

## Next Steps

Continue with the [Quickstart](/docs/getting-started/quickstart/) to create a
scope, inspect portable catalogs, return agent context, and then connect domain
records when you are ready. Then review [Onboarding Scopes](/docs/getting-started/onboarding/)
before source intake or fact promotion.
