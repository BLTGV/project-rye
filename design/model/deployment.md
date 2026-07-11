# Deployment Architecture

## Schema Isolation

All Rye objects (tables, functions, views, triggers, indexes) live in a dedicated `rye` schema. Domain tables (CRM records, project data, etc.) remain in `public` or whichever schema the host application uses.

**Why schema over name prefix:**

- `SET search_path` gives unqualified access within functions; no `rye_` prefix on every identifier
- `GRANT ... ON ALL TABLES IN SCHEMA rye` provides clean permission boundaries
- `\dt rye.*` lists all Rye objects without noise from the host database
- Domain tables in `public` are not affected by Rye schema operations

**Exception:** The `rye_migrations` table stays in `public` so the migrator can find it without knowing the schema name.

## Function Search Path

Every PL/pgSQL and SQL function includes a `SET search_path` clause in its definition. This ensures correctness does not depend on session or connection-pool state.

Two tiers:

| Tier | `SET search_path` | Used by |
|------|-------------------|---------|
| Internal | `rye, pg_catalog` | Functions that only reference Rye tables: `record_event`, `supersede_assertion`, `merge_nodes`, `agent_node_summary`, etc. |
| Cross-schema | `rye, pg_catalog, public` | Functions that reference domain tables or create triggers on them: `capture_domain_change`, `track_table`, profile functions (`create_task`, `create_opportunity`, etc.) |

### SECURITY DEFINER Hardening

Security-definer functions lock their search path to `rye, pg_catalog` unless
they explicitly require cross-schema domain access. Agent runtime wrappers use
the internal path, authenticate a Rye token, establish admin RLS context only
inside the function transaction, apply explicit capability and membership
checks, record the action, and restore the prior session value before return.

Raw identity-taking functions and credential or authority administration
helpers are revoked from `PUBLIC`. Restricted database callers receive only the
token-bound wrappers through `scripts/grant_agent_runtime.sh`.

The runtime PostgreSQL role is a transport boundary, not business authority.
It has no Rye table privileges. Rye tokens, capability grants, temporal node
memberships, and domain authorities remain the authorization model.

Tokens must be passed with database parameter binding. They must not appear in
generated SQL, process arguments, audit payloads, or error messages.

### Temporal Node-Domain Membership

`node_domain_memberships` records which domains contain a node over time. An
advisory-lock trigger prevents concurrent overlapping ranges without adding a
new PostgreSQL extension. Token-bound reads require an active membership and a
matching current grant for every active node membership. Unclassified nodes
and unknown candidate domains appear in `node_domain_membership_gaps` and are
never inferred from labels, channel names, or connector metadata.

## Overlay Architecture

Rye is an overlay graph that connects to existing domain data without moving it. Three mechanisms cross the schema boundary by design:

- **`link_record()`** reads and writes `node_source_map` (in `rye`) keyed by `(source_schema, source_table, source_id)`. The source schema/table values point to tables in `public` or other schemas.
- **`track_table()`** creates a trigger on a domain table (e.g., `public.contacts`) that fires `rye.capture_domain_change()`. The dynamic SQL in `track_table` schema-qualifies the trigger function reference.
- **`capture_domain_change()`** fires in the context of the domain table's schema but writes events into `rye.events` via `record_event()`.

CDC payload version 2 never copies classified source values into Rye. It keeps
classification and digest for change detection. Immutable earlier full-row
events are admin-only and reported by `cdc_protection_gaps`.

## Session Variables for Identity

Rye uses PostgreSQL session variables for identity, not database roles:

```sql
SET app.current_user_id = '<uuid>';
SET app.current_teams   = 'team-a,team-b';
SET app.current_role    = 'team_member';
```

These map directly to external identity systems (Directus users, Supabase auth, custom auth). RLS policies read these variables to enforce access control.

## Profile Functions

Profile functions (`create_opportunity`, `create_task`, etc.) use `SET search_path = rye, pg_catalog, public` because they may need to resolve domain tables for cross-references. Profiles can also add supplemental RLS policies to Rye core tables (e.g., a CRM profile could add a policy on `assertions` that gates `financial_terms` by role).

## Configurable Schema Name

The schema name `rye` is hardcoded in v1. The environment variable `RYE_SCHEMA` is accepted by scripts but migration SQL always uses `rye`. Making the schema name fully configurable (for multi-tenant deployments) is deferred to a future version.

## Migration Tracking

The `rye_migrations` table lives in `public`:

```sql
CREATE TABLE IF NOT EXISTS rye_migrations (
    name       text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);
```

Each migration file begins with:

```sql
CREATE SCHEMA IF NOT EXISTS rye;
SET search_path = rye, pg_catalog, public;
```

The `SET search_path` at the file level means all unqualified `CREATE TABLE`, `CREATE INDEX`, etc. statements resolve to `rye` without explicit qualification.
