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

## Categories

Ask what kinds of things this database holds before proposing a write:

```bash
./scripts/rye categories
./scripts/rye categories --json
```

Ask within one scope, by UUID or scope key:

```bash
./scripts/rye categories --scope first-scope --json
```

This calls `rye_categories(scope_id)`. For every category it returns the node
type name, what it means in this organization's words, the properties observed
on its rows and which are required, the relationships it takes part in, whether
it is on or off in the scope, its usage count, and the plugins that declare it.
Categories that are off are listed as off, not omitted. Scope selection works as
it does for `context`: one active scope is selected automatically, otherwise pass
`--scope`. An unknown scope returns an empty list rather than an error, and
`--json` emits the function's output verbatim
(see `contracts/category-vocabulary.md`).

Descriptions live in the graph, not in a file. Record one with
`describe_category()`:

```sql
SELECT rye.describe_category(
    p_node_type   := 'opportunity',
    p_description := 'A deal we are actively working, from qualified to closed.',
    p_scope_id    := '00000000-0000-0000-0000-000000000000',
    p_actor       := 'person:casey'
);
```

Pass `p_scope_id := NULL` for the organization-wide fallback. If the scope
reviews new knowledge, the words wait as a candidate until someone accepts them,
and `categories` keeps showing the previous description until then.

## Settlers

Before recording a statement as accepted, ask who may settle it:

```bash
./scripts/rye settlers \
  --subject 8f2a... \
  --claim expectation \
  --speaker 1c9d... \
  --speech-act expectation \
  --domain operations
```

This calls `rye_settlers()`. The answer comes from one lookup in three steps: a
recorded grant for that kind of claim, then the relationship between the speaker
and the subject (yourself, your manager, the owner of the thing), then the owner
of the area. `step` names the step that produced the answer, and
`speaker.is_settler` is the field to act on: true means record the statement as
accepted, false means record a suggestion and ask the people listed.

`--claim` is the assertion type, verbatim, and it is the first selector of the
relationship step. A claim one person sets on another — `expectation` today — is
settled by the manager and never by the person it is set on, whatever
`--speech-act` says. A claim a person makes about themselves — `commitment`,
`self_commitment`, `self_report` — is settled by that person, with no setup and
no flag. Any other claim type needs a recognized `--speech-act` to select a
relationship; without one the answer falls through to the area owner. Omitting
the flag narrows the answer, it never widens it, and `speech_act_recognized`
false means classify the statement and ask again rather than record it as
accepted.

The lookup reads no assertion, so it cannot tell a new statement from a
contradiction of one already accepted. `is_settler` true is not permission to
replace an accepted claim you did not check for.

`--subject` is optional: omit it for a topical claim with no subject node.
`--speaker-ref` carries a source identity such as `chat:U0123` for a speaker
with no person node. `--as-of` reconstructs a past answer from the relationships
and grants in effect then:

```bash
./scripts/rye settlers --subject 8f2a... --claim expectation \
  --speech-act expectation --as-of '2026-03-01' --json
```

The lookup is advisory. It reports, it never refuses, and it writes nothing. An
agent identity is never returned as a settler: an agent carries the authority of
the person it acts for and none of its own. Finding no settler is an answer, not
a failure, so the command exits zero with `step` `none` and a `reason` such as
`area_has_no_owner` — that is a setup gap for an admin to close. An empty list
never means nobody is authorized; it means nobody is authorized and visible to
this caller. `--json` emits the function's output verbatim (see the "Settlement
lookup" section of `contracts/sql-surface.md`).

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
