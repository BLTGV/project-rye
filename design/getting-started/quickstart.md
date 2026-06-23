# Quickstart

## Start Rye in a few commands

Rye is a PostgreSQL schema with a CLI for first-run setup and agent discovery.
The quickstart path installs Rye, syncs portable metadata, creates an onboarding
scope, and returns the context bundle agents should read before they act.

## 1. Install Rye

Use the hosted bootstrap:

```bash
curl -fsSL https://projectrye.dev/onboard | sh
```

Or run the repo-local CLI:

```bash
./scripts/rye init local --fresh
```

For an existing PostgreSQL 15+ database:

```bash
./scripts/rye init remote --db-url "$DATABASE_URL"
```

These commands install the Rye schema, sync plugin manifests, sync skill
manifests, sync capability metadata, and write `.rye.env`.

## 2. Check the Instance

```bash
./scripts/rye doctor
./scripts/rye status
```

Use JSON for scripts or agents:

```bash
./scripts/rye doctor --json
./scripts/rye status --json
```

`status --json` returns `rye_agent_context()`.

## 3. Inspect Portable Catalogs

```bash
./scripts/rye catalog plugins
./scripts/rye catalog skills
./scripts/rye catalog capabilities
```

These commands show which plugin contracts, skill manifests, and capabilities
are available in the instance. Use `--json` to hand the result to an agent.

```bash
./scripts/rye catalog capabilities --json
```

## 4. Create the First Onboarding Scope

Create one limited scope before source intake or assertion promotion:

```bash
./scripts/rye onboard create \
  --label "Lead Follow-Up" \
  --purpose "Track follow-up for a limited lead workflow."
```

The command creates and activates an `onboarding_scope` node. It records default
policies for expected contexts, holding context, unexpected context handling,
retention, evidence review, allowed types, and enabled plugins.

Use a scope name that describes the organizational purpose. Avoid naming the
scope after a source, channel, connector, or trial phase unless that is the real
purpose.

## 5. Get Agent Context

```bash
./scripts/rye context
./scripts/rye context --json
```

The context bundle includes:

- core `rye_catalog()` output
- plugin, skill, and capability catalogs
- source inventory
- pending source context confirmations
- active scopes
- selected scope status
- compiled scope policy when a scope is selected

If multiple scopes are active, select one by key or UUID:

```bash
./scripts/rye context --scope lead-follow-up --json
```

## 6. Review Sources Before Promoting Facts

Check registered source accounts and containers:

```bash
./scripts/rye sources inventory
```

Find sources that still need context confirmation:

```bash
./scripts/rye sources pending-context
```

New source metadata is provenance, not business truth. Confirm context before
agents route source material or promote assertions.

## 7. Connect Existing Domain Records

When you are ready to connect operational data, use `link_record()` from SQL.
Domain tables remain the system of record.

```sql
SET search_path = rye, public, pg_catalog;
SET LOCAL "app.current_user_id" = 'quickstart-user';
SET LOCAL "app.current_teams" = 'default';
SET LOCAL "app.current_role" = 'operator';

SELECT link_record(
    p_source_schema := 'public',
    p_source_table  := 'customers',
    p_source_id     := '42',
    p_node_type     := 'org',
    p_label         := 'Acme Corp',
    p_properties    := '{"plan": "growth", "mrr": 299}'
);
```

`link_record()` creates a graph node and maps it back to the source table through
`node_source_map`. Calling it again with the same source row updates the linked
node properties instead of creating a duplicate.

## 8. Track Source Table Changes

Attach CDC triggers when linked source rows should produce graph events:

```sql
SELECT track_table('public', 'customers');
```

Only linked rows produce `domain_change` events. Unlinked rows are ignored.

## 9. Query Rye

Use the CLI for broad instance context:

```bash
./scripts/rye context --json
```

Use SQL for graph-level details:

```sql
SELECT *
FROM node_context
WHERE label = 'Acme Corp';
```

For compact agent context on a specific node:

```sql
SELECT agent_node_summary(
  (SELECT id FROM nodes WHERE label = 'Acme Corp' LIMIT 1),
  8
);
```

## What You Did Not Have To Do

- Replace PostgreSQL
- Add a runtime or ORM
- Add foreign keys from domain tables to Rye
- Seed example data
- Promote source metadata as accepted business truth

## Next Steps

- [CLI Reference](/docs/reference/cli/) for every `./scripts/rye` command
- [Onboarding Scopes](/docs/getting-started/onboarding/) for scope and source policy
- [Integration Guide](/docs/model/integration/) for domain table overlay and CDC
- [Agent Operations](/docs/reference/agent-ops-guide/) for safe read/write patterns
