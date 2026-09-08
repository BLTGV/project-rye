# 001 discover-categories

- status: open
- opened: 2026-09-08
- areas: schema, agent-kit
- contracts: contracts/category-vocabulary.md (new), contracts/sql-surface.md, contracts/rye-cli.md

## Goal
An agent that knows only the skills can ask the database what kinds of things
it holds before trying to add one. This is the discover step of the v0.3
loop (BRIEF.md) and story S1 in docs/product.md. It does not cover
categorize, validate, or resolve; those are later items.

## Intent excerpt (BRIEF.md)
"Discover what categories exist in this database: which types are in use,
what each one means here, what properties and relationships it carries, and
which are enabled or disabled in the current scope." Today the catalog
reports type names and counts only. "Procedure lives in git. Vocabulary
lives in the graph."

## Acceptance criteria (from S1)
- [ ] One request returns every category in use in the current area, and for each: its name, what it means in this organization's words, the properties it carries and which are required, the relationships it takes part in, and whether it is on or off here. Categories that are off are listed as off, not omitted.
- [ ] No part of the reply comes from a file the agent was handed: a person can change a category's description in the graph and see the change in the next reply.
- [ ] Asking in an area with no categories yet returns an empty list and says so, not an error.
- [ ] The request is reachable from the CLI, and the skill an agent is handed tells it to make this request before proposing any write.
- [ ] A conformance test covers: a type in use with observed properties, a type declared by an enabled plugin but with no instances, a type disabled in the scope, and an empty scope.

## Constraints
- SQL and bash only in schema; no new tables if an existing structure serves (descriptions can be assertions on a node that stands for the category).
- Additive: a new numbered migration; no edits to applied migrations; existing functions keep their signatures.
- "Category" is the business sense. Never reuse "classification", which means who may see it.
- No customer names in fixtures.

## Decided by the human
- 2026-09-08: v0.3 is the discover, classify, resolve loop (Casey, "yes. commit. proceed").

## Assumed by default
- A category's description is per scope, so an area can say what a type means locally. Overturn: Casey.
- "Properties it carries" is observed from data (keys and how often they appear) plus any declared required keys; there is no separate schema registry. Overturn: Architect via contract.
- Categories are node types for this item. Edge and assertion types appear only as the relationships a node type takes part in. Overturn: Architect.

## Verified
- filled in at close

## Reports

### Architect (2026-09-08)
Result: done. New contracts/category-vocabulary.md: rye_categories(p_scope_id
uuid DEFAULT NULL) RETURNS jsonb, STABLE. Per category: name, description
plus description_source, properties.observed/required/required_source,
relationships.as_source/as_target, enabled (on/off/unscoped), usage_count,
declared_by. Descriptions live on a category node (external_source
rye_category, external_id = type name) as category_description assertions
keyed by scope uuid with a default fallback, read from
current_valid_assertions. sql-surface and rye-cli contracts updated;
decision 0004 recorded; areas.md updated (schema publishes, agent-kit and
admin consume).
Learned: plugin manifests declare node_types as bare strings, so nothing
declares required keys; allowed_node_types is only read by
validate_candidate_against_scope; rye_agent_context() returns
selected_scope_found: false on unknown scope, and the new function copies
that.
Questions: subcommand is top-level `categories` (default stands). Nothing
creates the category node today; Lead decision: the schema builder adds a
describe_category() helper in the same migration. All three defaults
confirmed.

## Close
