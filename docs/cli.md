# Rye CLI Reference

The `./scripts/rye` command is the fastest repo-local path for installing Rye,
checking an instance, creating the first onboarding scope, and giving agents a
portable context bundle.

It writes local connection state to `.rye.env` by default. Pass
`--env-file <path>` if you want a separate config file.

## Fast Install

Use local Docker when you want a fresh PostgreSQL instance:

```bash
./scripts/rye init local --fresh
```

Use an existing PostgreSQL 15+ database when Rye should live beside current
application tables:

```bash
./scripts/rye init remote --db-url "$DATABASE_URL"
```

Both commands install the Rye schema and sync portable metadata for plugins,
skills, capabilities, and contributed node, edge, assertion, event, and artifact
types.

The older aliases still work:

```bash
./scripts/rye local --fresh
./scripts/rye remote --db-url "$DATABASE_URL"
```

## Health and Status

Check database reachability and metadata totals:

```bash
./scripts/rye doctor
./scripts/rye doctor --json
```

Inspect installed node types, active scopes, plugins, and skills:

```bash
./scripts/rye status
./scripts/rye status --json
```

`status --json` returns `rye_agent_context()`, which is the same portable bundle
agents should use to orient themselves.

## Catalog Commands

List installed plugin metadata:

```bash
./scripts/rye catalog plugins
./scripts/rye catalog plugins --json
```

List synced Rye skill manifests:

```bash
./scripts/rye catalog skills
./scripts/rye catalog skills --json
```

List capabilities contributed by plugins and skills:

```bash
./scripts/rye catalog capabilities
./scripts/rye catalog capabilities --json
```

These commands call the portable catalog functions:

- `rye_plugin_catalog()`
- `rye_skill_catalog()`
- `rye_capability_catalog()`

## Onboarding Scope

Create and activate the first onboarding scope:

```bash
./scripts/rye onboard create \
  --label "First Scope" \
  --purpose "Describe the limited workflow Rye should assist first."
```

The command records default policies for expected contexts, holding context,
unexpected context handling, retention, evidence review, allowed types, and
enabled plugins. It activates the scope so agents can request a compiled context
bundle.

The older alias still works:

```bash
./scripts/rye onboard --label "First Scope" --purpose "..."
```

## Agent Context

Return catalog, plugin, skill, capability, source, scope, and policy context:

```bash
./scripts/rye context
./scripts/rye context --json
```

Select a specific scope by UUID or scope key:

```bash
./scripts/rye context --scope first-scope --json
```

This calls `rye_agent_context(scope_id)`. If exactly one scope is active, Rye
selects it automatically. If multiple scopes are active, pass `--scope`.

### Grant a direct-database runtime role

After an operator creates a restricted PostgreSQL login role, grant only the
token-bound Rye runtime functions:

```bash
./scripts/grant_agent_runtime.sh \
  --db-url "$DATABASE_URL" \
  --role rye_agent_runtime
```

This does not create the role or manage its password. It grants no Rye table
access and no raw identity-taking or administrative helpers. Direct database
agents call the `*_with_token` functions with parameter binding; bearer tokens
must never appear in generated SQL or process arguments.

The grant includes scoped context, search, summary, observation, candidate,
review queue, adjudication, promotion, and governed process evaluation. The
token's Rye capability rows still decide which of those calls are allowed.

## Source Commands

Review known source accounts and containers:

```bash
./scripts/rye sources inventory
./scripts/rye sources inventory --json
```

Find source accounts and containers that still need context confirmation:

```bash
./scripts/rye sources pending-context
./scripts/rye sources pending-context --json
```

These commands call:

- `rye_source_inventory()`
- `rye_pending_context_confirmations()`

## Global Options

Use a database without relying on `.rye.env`:

```bash
./scripts/rye --db-url "$DATABASE_URL" status
```

Use a non-default Rye schema:

```bash
./scripts/rye --schema rye status
```

Return JSON where supported:

```bash
./scripts/rye --json context
```

Use quiet mode for scripts:

```bash
./scripts/rye --quiet doctor
```
