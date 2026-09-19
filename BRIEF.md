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

## What v0.4 is for
v0.3 teaches an agent how to file things. v0.4 is about the person on the
other side of the agent. People know Rye is in use and never learn its
vocabulary. They talk to their agent and it remembers, answers, corrects,
says who said what, and asks only when unsure. They never pick a category,
an area, a policy, or a status, and they never visit a queue.

The rule underneath is that acceptance follows authority. An agent carries
the authority of the person it acts for and none of its own. Who may settle
a claim comes from one lookup: a recorded grant for that kind of claim,
then the relationship (yourself, your manager, the owner of the thing),
then the owner of the area. Nothing a person says is refused or lost. If
they cannot settle it, it is recorded as a suggestion and their agent
checks with someone who can. An objection to something already accepted is
kept as a record and routed by its reason. Accepted stays accepted until a
settler changes it.

The full reasoning is in `design/proposals/human-agent-scaling.md`.

## What done for v0.4 looks like
- Two people who trust each other, each with their own agent, share one
  area. Neither learns a Rye word. Replay cases cover: a self-commitment
  accepted at once; a statement about the other person routed to them and
  settled by their reply; a manager's expectation objected to by the
  report, routed by the reason, and settled once by the manager; a topical
  grant made in plain words ("Priya decides pricing"); and a claim no one
  is named for, which falls to the area owner.
- Every write is echoed back in one line the person can correct.
- One request tells a person's agent which questions that person owes,
  most important first, so any of their agents can ask.
- No fixed caps or clocks. How often an agent asks and what happens when a
  settler is silent follow importance, and a person adjusts both in plain
  words.
- A scoped agent token can reach only the routes and rows its grants
  allow (GitHub issue 16).

## Out of scope for v0.4
- Channel agents, source identity binding, and conditional auto-accept
  rules.
- Objectives, importance scoring, and parked suggestions.
- Rye databases working together.
- Enforcing the lookup against direct database users. They are trusted by
  construction; enforcement applies to callers that come through the API.

## Constraints
- No customer names in committed examples or fixtures.
- Internals keep canonical vocabulary; only human-facing surfaces use the
  plain-language lexicon.
- CI workflow files under .github/workflows cannot be pushed with the local
  credentials on this machine.
