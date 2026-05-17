---
name: rye-installer
description: Install, migrate, verify, and test Rye PostgreSQL deployments. Use when a user asks to bootstrap Rye in a database, apply core/profile migrations, run schema verification, seed sample data, or execute conformance checks.
---

# Rye Installer

## Workflow

1. Validate target database connection (`DATABASE_URL`) and target profiles (`crm`, `pm`, or none).
2. Run `./scripts/install.sh --profiles ...` to apply migrations in order.
3. Optionally run `./scripts/install.sh --seed` for quickstart data.
4. Run `./scripts/verify.sh` to validate required objects and policies.
5. Run `./scripts/conformance.sh` for gate checks.

## Commands

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
