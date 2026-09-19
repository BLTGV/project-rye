# Contract: Plugin and skill manifests

Published by **agent-kit**. Consumed by **schema** —
`scripts/sync_plugin_metadata.sh` loads manifests into the database, and
`./scripts/rye catalog plugins|skills|capabilities` reads them back out. The
admin console reads the same rows through the API.

## Shape

Two file kinds, each with a JSON Schema in the repository that is normative:

- `plugins/<id>/rye-plugin.json` against `plugins/rye-plugin.schema.json`.
  Required: `id`, `version`, `label`, `contributes`. `contributes` declares
  the `node_types`, `edge_types`, `assertion_types`, `event_types`, and
  `artifact_types` the plugin adds. Optional `dependencies`, `supersedes`,
  `conflicts`, `capabilities`. No additional top-level properties.
- `skills/<id>/rye-skill.json` against `skills/rye-skill.schema.json`.
  Required: `id`, `version`, `label`, `description`, `source`, `install`,
  `requires`, `capabilities`. `requires` names the plugins, database
  functions, database views, and CLI commands the skill depends on — this is
  what makes a skill checkable against an instance before it runs.

A capability in either file declares `id`, `label`, `kind`, `description`,
`read_only`, and `entrypoints`. `read_only` is the load-bearing field: it is
what lets a scope's policy decide whether a capability may run at all.

The `id` is the identity. It appears in the database as the plugin or skill
node's `external_id` and must not change once published.

## Declared relationships the schema reads

`contributes.edge_types` is a list of names. The manifest carries no direction,
no temporal rule, and no settler, so where the schema reads an edge type by
name the meaning is pinned here. Two are pinned today, both contributed by
`rye-org`, both read by `rye_settlers()` in `contracts/sql-surface.md`:

- `reports_to`: source is the person reporting, target is the manager. One
  person may have more than one, and every one in effect is returned.
- `owns`: source is the owner (a person, team, or system node), target is the
  thing owned. Ownership of a thing, not of a policy; `owns_policy` stays what
  it is.

Both are temporal, never deleted. A line that ends gets `effective_to` set; the
row stays and an `as_of` before that time still sees it. Archiving an edge
removes it from every answer at every `as_of`, so archive is for a line that
was recorded in error, and `effective_to` is for one that ended.

Neither edge is settled by the people it connects. The owner of the knowledge
domain settles that a reporting line or an ownership exists, which is what
`rye_settlers()` answers when asked with `reports_to` or `owns` as the claim
type. An agent proposes these edges; it does not settle them.

Renaming either name, or reversing either direction, is breaking in the sense
below: the schema's answer changes silently for knowledge already recorded.
Category discovery reports these edge types as relationships on the `person`
category once rows exist, from `rye_categories()`. A name declared in a
manifest with no rows behind it does not appear there, which is expected and is
not a sync failure.

## Versioning

Every manifest carries its own `version`. Adding a type to `contributes`,
adding a capability, or adding an optional field is additive. Removing a
contributed type, removing a capability, renaming an `id`, or flipping
`read_only` from true to false is breaking: knowledge already accepted under
the old vocabulary must keep working, so removals need a decision record and
an edit here first. The schema files themselves are versioned by the
repository; a change to either is a change to this contract.

## Freshness

Manifests are files; the database's copy is a snapshot taken the last time
`sync_plugin_metadata.sh` ran. It is not automatic. A manifest edited without
a sync is invisible to `./scripts/rye catalog` and to the console, and an
agent will be refused vocabulary its manifest already declares. Sync is
idempotent and safe to re-run.

## Failure behavior

A manifest that fails its schema is a build failure, not a warning — an
invalid manifest is never synced. Sync refuses rather than partially applies:
an unresolvable `dependencies` entry or a `conflicts` collision stops that
manifest and reports which one. Disabling a plugin for a scope removes the
vocabulary going forward and never deletes knowledge accepted under it.
