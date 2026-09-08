# Contract: Category vocabulary

Published by **schema**. Consumed by **agent-kit** and **admin**.

What kinds of things are here and what each means, asked before an agent writes.
A category is a node type; edge and assertion types appear only as the
relationships a node type takes part in.

## Shape

`rye_categories(p_scope_id uuid DEFAULT NULL) RETURNS jsonb`, `STABLE`.

Top level: `contract_version` (integer, `1`); `categories`; `category_count`;
`empty` (boolean, always present, `true` exactly when `categories` is empty);
`scope` = `{requested_scope_id, scope_id, scope_found, scope_key, label, mode,
type_policy}`. `mode` is `explicit`, `single_active`, `none`, or
`multiple_active`, resolved as `rye_agent_context()` resolves it. `type_policy`
is `present` or `missing`: has the scope a current `allowed_node_types` claim.

Each category has `name` (the node type) and `kind` (always `node_type`),
ordered by `usage_count` descending then `name`, plus:

- `description` — the organization's words, or `null`; `description_source` —
  `{category_node_id, assertion_id, assertion_key, asserted_at}` or `null`.
- `properties.observed` — `[{key, count, frequency}]` over non-archived nodes of
  this type, `frequency` = `count / usage_count` to 3 places, by count then key.
- `properties.required`, `.required_source` — `[]` and `"none"` in v0.3: no
  schema or manifest declares a required key yet. Tolerate a non-empty array.
- `relationships.as_source`, `.as_target` — `[{edge_type, other_types, count}]`
  over non-archived edges, `other_types` the far end's types, by count.
- `enabled` — `on` when the scope's `allowed_node_types` lists `name`, `off`
  otherwise, `unscoped` when no scope resolved. Off categories are listed, not
  omitted; where `type_policy` is `missing` all read `off`, matching what
  `validate_candidate_against_scope()` refuses.
- `usage_count` — non-archived nodes of this type; `declared_by` — ordered
  plugin ids whose `contributes.node_types` names it, `[]` when none.

Membership, with a scope: types on non-archived nodes, types the scope's enabled
plugins declare, and names in its `allowed_node_types`. Unscoped: present types
plus every catalogued plugin's. A declared type with no rows counts 0.

## Where the description lives

A node of type `category`, `external_source` `rye_category`, `external_id` the
node type; one per type. The description is an assertion on it: `assertion_type`
`category_description`, `assertion_key` the scope's uuid as text, `claim`
`{"description": text}`; key `default` is the org-wide fallback. Resolution is
scope key, then `default`, then `null`, over `current_valid_assertions` only,
so a candidate stays invisible until accepted. Descriptions change through the
ordinary lifecycle (`record_assertion`, `accept_assertion`,
`supersede_assertion`), so the next call shows the new words. No new table and
no file; the function never creates the `category` node.

## Versioning

Additive: new top-level and per-category keys may appear at any time, and
callers must ignore keys they do not know. Removing or renaming a key, changing
its meaning, or changing the values of `enabled`, `mode`, `type_policy`, or
`required_source` is breaking: decision record and an edit here first, and
`contract_version` increments only then.

## Freshness

Computed on read from live rows: no cache, no materialized view, no snapshot; a
description accepted earlier in the transaction is visible to the next call.

## Failure behavior

An unknown or archived `p_scope_id` does not raise: `scope_found` is `false`,
`mode` is `explicit`, `categories` is `[]`, `empty` is `true`. A scope with
nothing in it gives that same empty answer, never an error. A non-uuid argument
fails at cast time. Rows RLS hides are absent from counts, not reported.

## CLI

`./scripts/rye categories [--scope <uuid-or-key>] [--json]`. Top level rather
than a `catalog` topic, which reports installation metadata; it sits beside the
later classify and resolve steps. `--scope` takes a uuid or a scope key as
`context --scope` does; `--json` emits `rye_categories()` verbatim.
