# Brief

This is the one document Product reads as Casey's intent. Casey: edit
freely.

## Where Rye is
Rye is not production. Call it v0.3. It is an open source, agent-native
temporal knowledge graph that runs as a schema inside PostgreSQL, with
skills and plugins that tell agents how to use it.

## What v0.3 is for
The opinionated SQL and skills exist to guide agent-driven categorization
and schema validation. Agents should know how to query and find things.
Given an item, an agent should:

1. **Discover** what categories exist in this database: which types are in
   use, what each one means here, what properties and relationships it
   carries, and which are enabled or disabled in the current scope.
2. **Classify** the item against those categories, explain the choice, and
   have the proposed shape checked. A mismatch is reported as something for
   a person to review, not silently rejected.
3. **Resolve** whether the item already exists in the graph before
   proposing to create it, and abstain when the evidence is too thin to
   decide.

Today only the resolve step is built. The catalog reports type names and
counts but not what a type is, and nothing checks whether an item fits a
type. Rye is opinionated about lifecycle and almost unopinionated about
categorization. v0.3 fixes that imbalance.

## Who it is for
- The Rye admin at a small organization who wants agents to work from
  shared, reviewable knowledge without hand-feeding context every session.
- The reviewer who knows the business, not the database, and accepts or
  declines what agents suggest.
- The developer who installs Rye beside an existing database without
  changing it.
- The agent, which needs a compact briefing, safe write paths, and a clear
  answer about what it may record versus what it must suggest.

## What must stay true
- The deliverable is SQL plus skills and plugins. No runtime, framework,
  ORM, or build step for the core.
- Append-only: assertions are superseded, never mutated; events are
  immutable.
- Overlay: domain tables never point at the graph. Dropping the schema
  leaves operational systems intact.
- Agents suggest; people accept. Review policy is per scope.
- Procedure lives in git. Vocabulary lives in the graph. Skill metadata
  is the joint between them.
- Works on plain PostgreSQL 15+ and on Supabase.

## What done for v0.3 looks like
- A freshly started agent, given one item and only the skills, can list
  the categories available here, classify the item with a stated reason,
  have the shape validated, and check for an existing match before it
  proposes a write. Replay cases cover: an existing entity, a new entity,
  an ambiguous match, invalid properties, and no matching category.
- Category descriptions live in the graph and improve through the normal
  review lifecycle, so the skill file stays static while categorization
  gets better.
- The onboarding path from the README still works, and the v2 lifecycle
  (candidates, evidence, gaps, digests) is unchanged.

## Out of scope for v0.3
- Tokens, forecasting, calibration, reputation, and the declared-knowledge
  workflow. They do not serve discover, classify, resolve.
- Write-time alias triggers that silently reinterpret a write. Report
  drift; do not rewrite the insert.
- Being the operational UI for domain applications.
- Storage pruning and garbage collection.

## Constraints
- No customer names in committed examples or fixtures.
- Internals keep canonical vocabulary; only human-facing surfaces use the
  plain-language lexicon.
- CI workflow files under .github/workflows cannot be pushed with the local
  credentials on this machine.
