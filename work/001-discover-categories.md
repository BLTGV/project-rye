# 001 discover-categories

- status: done
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
- [x] One request returns every category in use in the current area, and for each: its name, what it means in this organization's words, the properties it carries and which are required, the relationships it takes part in, and whether it is on or off here. Categories that are off are listed as off, not omitted.
- [x] No part of the reply comes from a file the agent was handed: a person can change a category's description in the graph and see the change in the next reply.
- [x] Asking in an area with no categories yet returns an empty list and says so, not an error.
- [x] The request is reachable from the CLI, and the skill an agent is handed tells it to make this request before proposing any write.
- [x] A conformance test covers: a type in use with observed properties, a type declared by an enabled plugin but with no instances, a type disabled in the scope, and an empty scope.

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
- Combined suite (./scripts/test-all.sh) on merged branch 8e323f2: all steps passed, including tests/conformance/28_category_vocabulary.sql and the CLI smoke test. Run by Lead 2026-09-08; log cited by Verifier.
- Verifier read the diff 43917c6..HEAD against the work item, contract, and area invariants: PASS.
- Not verified: describe_category called by an agent role (test runs as admin only).

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

### builder-agent-kit (2026-09-08)
Result: done. Changed skills/rye-agent-ops/SKILL.md (38-line "Discover
Categories Before You Write" section), skills/rye-domain-onboarding/SKILL.md
(discovery as workflow step 2, guardrail: a new category is a person's
decision), skills/rye-knowledge-reader/SKILL.md (rye_categories in Orient),
docs/agent-ops-guide.md (section with per-key table referencing the
contract), and the three rye-skill.json manifests (rye_categories in
requires.db_functions and capability requires; categories CLI command;
entrypoints).
Tested: all ten manifests parse; the three edited checked structurally
against skills/rye-skill.schema.json by hand (jsonschema not installed).
Docker and MCP tests deferred to integration by dispatch.
Learned: entrypoint types in use are skill_install, cli_command,
db_function, bootstrap_script; sync_plugin_metadata.sh copies the whole
requires and capabilities blobs into a skill_capabilities assertion, so new
manifest keys reach the graph with no script change; every manifest carries
a $schema key that the schema's additionalProperties:false forbids, so any
future validator must allow it.
Questions: discover step in docs/onboarding.md and conventions-catalog.md
too? Default no. Contract cited by repo path from skills that ship without
the repo? Default acceptable, matches existing practice.
Worktree: .claude/worktrees/agent-a1ff64b757ca2a61b, branch
worktree-agent-a1ff64b757ca2a61b.

### builder-schema (2026-09-08)
Result: done. Changed schema/migrations/0020_category_vocabulary.sql
(rye_categories, describe_category, comments, partial index on the category
node lookup), tests/conformance/28_category_vocabulary.sql (seven cases),
scripts/rye (categories subcommand), scripts/verify.sh, 
tests/conformance/16_cli_smoke.sh, docs/cli.md, docs/data-dictionary.md.
Tested: ./scripts/docker-test.sh test --reset --profiles crm,pm passed,
including the new test and CLI smoke; eyeballed scoped and unscoped CLI
output against a live container.
Learned: an isolated worktree lacks admin and intake node_modules, so
docker-test.sh fails at tests 21 and 22 until npm ci runs in both;
record_event's p_participant_roles is text[] and appending a bare literal
raises "malformed array literal", cast to ::text; record_scope_policy's own
assertions land accepted even under strict policy because governing_scope()
returns NULL for a scope node's own policy assertions;
enable_plugin_for_scope stores the manifest at properties.manifest while
sync_plugin_metadata.sh stores properties.contributes, read both.
Questions: empty:true with scope_found:true is unreachable because the scope
node is itself a live node whose type is always a member; test covers the
empty answer via unknown scope and emptied graph. Default: acceptable,
contract edit is the Architect's call. declared_by lists only plugins in
play for the answer. Default: correct.

### Lead integration (2026-09-08)
Base revision 43917c6. Merged worktree-agent-a7cd2eb513368240a (schema) and
worktree-agent-a1ff64b757ca2a61b (agent-kit); no conflicts. Combined suite
run follows.

### Verifier (2026-09-08)
PASS. Every acceptance criterion met with file:line evidence; contract
implemented field by field with no missing, renamed, or extra keys; all
schema and agent-kit invariants hold; describe_category goes through
record_event and record_assertion, never a raw insert; all 14 files inside
owned paths; "classification" used only in the prohibitive sense.
Non-blocking: describe_category upserts the category node with ON CONFLICT
DO UPDATE, so an agent role without the update write path would error on a
second describe of an existing type. Test 28 runs as admin only. Matches
pre-existing practice in 0010 and 0012.
Builder's concern (empty with scope_found) judged acceptable; no contract
edit needed.
Learned: `--scope <unknown key>` silently falls back to automatic scope
selection rather than reporting scope_found:false (same as `context`);
jsonschema not installed, manifest validation is by hand; test 28 passes by
absence of exception and emits no notice.
Questions: test the agent-role path for repeat describe_category? Default:
separate item.

## Close
- status: done 2026-09-08. Follow-ups: agent-role path for repeat describe_category (new item if agents will call it); `--scope <unknown key>` fallback behaviour is worth a contract note.
