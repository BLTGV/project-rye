---
name: rye-installer
description: Install, migrate, verify, and test Rye PostgreSQL deployments. Use when a user asks to bootstrap Rye in a database, apply core/profile migrations, run schema verification, seed sample data, or execute conformance checks.
---

# Rye Installer

## Workflow

1. For a new local trial, run `curl -fsSL https://projectrye.dev/onboard | sh`.
2. For a remote PostgreSQL database, run
   `curl -fsSL https://projectrye.dev/onboard | sh -s -- --remote "$DATABASE_URL"`.
3. Install the agent onboarding skill with
   `npx skills add BLTGV/project-rye --skill rye-onboarding`.
4. Start the first adoption unit with `./scripts/rye onboard --label ... --purpose ...`.
5. Use `./scripts/rye status` to confirm the selected database and active
   onboarding scope.
6. Use the lower-level install/conformance commands only when debugging
   migrations or release gates.

The first-run path writes `.rye.env` so later commands use the same database
without the user re-entering the connection string.

Install always applies schema migrations and syncs plugin metadata from
`plugins/*/rye-plugin.json`. That metadata includes contributed node, edge,
assertion, event, and artifact types plus onboarding questions, never-infer
defaults, validation hooks, and admin hooks. `--seed` is only for quickstart
example data.

## Commands

- Local trial: `curl -fsSL https://projectrye.dev/onboard | sh`
- Remote install: `curl -fsSL https://projectrye.dev/onboard | sh -s -- --remote "$DATABASE_URL"`
- Agent skill: `npx skills add BLTGV/project-rye --skill rye-onboarding`
- Repo-local trial: `./scripts/rye local --fresh`
- Repo-local remote install: `./scripts/rye remote --db-url "$DATABASE_URL"`
- Plugin metadata: `./scripts/rye plugins list`
- First scope: `./scripts/rye onboard --label "First Scope" --purpose "..."`
- Status: `./scripts/rye status`
- Core only: `./scripts/install.sh --profiles ''`
- Core + CRM: `./scripts/install.sh --profiles crm`
- Core + PM: `./scripts/install.sh --profiles pm`
- Core + CRM + PM: `./scripts/install.sh --profiles crm,pm`
- Full checks: `./scripts/conformance.sh`

## Post-Install

After install, run `SELECT rye_catalog()` to confirm the instance is ready and see what's connected.

## Supabase Deployment

Rye can be deployed to Supabase via its MCP `apply_migration` or `execute_sql` tools:

1. Create missing extensions: `btree_gin`, `pg_trgm` (pgcrypto is pre-installed).
2. Apply each migration file (0001 through 0007, plus profiles) via `apply_migration`.
3. Verify with `SELECT rye.rye_catalog()`.

Key differences from self-hosted:
- `postgres` is not a superuser — RLS applies to all queries. Always set session vars.
- Session variables reset per call. Prefix every query with `set_config()` calls.
- `SET app.current_role = 'admin'` syntax fails through the MCP. Use `set_config('app.current_role', 'admin', false)` instead.

## Notes

- Target PostgreSQL 15+.
- Rye installs alongside existing tables. It does not modify them.
- Use `link_record()` to connect existing domain table rows to the graph.
- Use `track_table()` to attach CDC triggers for change tracking.
- Assertion updates are function-only; verify this via `./scripts/verify.sh` and security tests.
- Do not edit migration order in `schema/migrations` without versioning and tests.
- If migrations fail partway, fix the root cause and re-run `./scripts/migrate.sh`.
