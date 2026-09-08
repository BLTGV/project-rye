# Rye Product Definition

Owner: Product role. Source of intent: `BRIEF.md` (v0.3). Who Rye is for, what
it must do, what it must not do, what "done" means. Never how. Terms are in
`docs/glossary.md`, in the plain register of `docs/vocabulary-contract.md`.

**Two meanings.** *Classification* in Rye already means sensitivity — who may
see a thing. The business sense, *what type of thing this is*, is a
**category**; choosing one is **categorizing**. Only the loop step keeps the
brief's word "classify".

## Purpose

Rye gives one organization a shared, reviewable memory that agents can read
and write without people losing authority over what counts as accepted. In
v0.3 its opinionated SQL and skills exist for one job: telling an agent how to
categorize what it finds — discover what categories exist here, classify the
item and explain the choice, resolve whether it already exists before
proposing to create it.

## Users

- **The Rye admin.** Technical or semi-technical, at a small organization.
  Wants agents working from shared knowledge without hand-feeding context
  every session. Judges Rye by whether agents file things correctly unwatched.
- **The reviewer.** Knows the business, not the database. Accepts or declines
  what agents suggest. Judges Rye by whether each item explains itself: what
  it claims, which category it was put in and why, where it came from, how
  sure Rye is.
- **The developer adopting Rye.** Installs Rye next to an existing application
  database. Judges Rye by whether nothing in their application had to change.
- **The agent.** Needs a compact briefing about the categories in use here,
  safe write paths, and a clear answer about what it may record versus what it
  must suggest.

## Goals

1. An agent that has never seen this database can find out what categories
   exist here, what each one means, and what it carries — from the database,
   not from a hand-written prompt.
2. Every proposed write states which category it chose and why, and has its
   shape checked before it lands.
3. An agent looks for an existing match before proposing to create anything,
   and says "I do not know" when the evidence is too thin.
4. A mismatch is never silently dropped; it becomes something a person sees.
5. Categorization guidance improves in the graph through the normal review
   lifecycle; skill files stay static while the answers get better.
6. Rye stays an overlay: installing or removing it changes nothing already
   running.

## Non-goals

- Tokens, forecasting, calibration, reputation, and the declared-knowledge
  workflow. They do not serve discover, classify, resolve.
- Rewriting a write at write time to match an alias or a preferred name. Rye
  reports the drift; it does not silently reinterpret the insert.
- Being the day-to-day screen where people manage domain records.
- Deciding on its own that knowledge is stale enough to delete. Storage
  pruning and cleanup are out.
- Depending on any one connector vendor, chat tool, or hosting provider, or
  being a general document store or search index over raw content.

## Stories

Each story is checkable from the admin surface or the command line, by someone
with no access to the code.

### S1 — What categories exist here

As an agent with only the skills, I can ask the database what kinds of things
it holds before I try to add one.

- One request returns every category in use in the current area, and for each:
  its name, what it means in this organization's words, the properties it
  carries and which are required, the relationships it takes part in, and
  whether it is on or off here. Categories that are off are listed as off,
  not omitted.
- No part of the reply comes from a file the agent was handed: a person can
  change a category's description in the graph and see the change in the next
  reply.
- Asking in an area with no categories yet returns an empty list and says so,
  not an error.

### S2 — Categorize an item and say why

As an agent, I can put an item into a category and state my reason in terms a
reviewer can check.

- Every proposed write names exactly one category and carries a stated reason
  referring to what was actually in the item.
- The reason is readable by a reviewer who never saw the item's raw form.
- Two agents given the same item and categories propose the same category, or
  the difference shows up as one open disagreement, not two loose proposals.

### S3 — The shape does not fit

As a reviewer, an item that does not match its category's expected shape
reaches me instead of vanishing.

- A proposed write missing a required property, or carrying a property the
  category does not define, is not accepted as-is.
- It appears in the suggestions waiting for a person, naming the category, the
  properties at fault, and what was expected, with the original item readable
  alongside it.
- Nothing about the mismatch is silent: the agent is told what failed and why,
  in the same words the reviewer sees.

### S4 — Nothing here fits

As a reviewer, when an agent finds something no existing category covers, I
find out.

- The agent does not force the item into the nearest category; an open
  question is recorded naming the item and why nothing matched.
- The open question can be answered by adding or describing a category, and
  the answer is linked to the question afterwards.
- The agent never creates a new category on its own.

### S5 — Does this already exist

As an agent, I check the graph for an existing match before proposing to
create anything, and I abstain when I cannot tell.

- **Existing thing.** A confident single match proposes an update to that
  thing and names it, rather than a new one.
- **New thing.** No match proposes a creation, and states what it searched
  for and did not find.
- **Ambiguous.** Two or more plausible matches produce one item for a person
  showing the candidates side by side; the agent picks none of them.
- **Too thin to tell.** When the evidence supports none of the above, the
  agent abstains: it records that it could not decide and why, and writes
  nothing else. Abstaining is a recorded outcome, not silence.
- Each of these four outcomes, and the two in S3 and S4, is reproducible: the
  same starting database and item give the same outcome every time.

### S6 — Who accepts the write

As a reviewer, I decide what an agent's proposal becomes, unless my area's
owner deliberately chose otherwise.

- Agents suggest; people accept. **The one exception is per-area and
  deliberate: in an area whose review policy is set to "agents may record
  accepted knowledge here", an agent's write is accepted the moment it is
  made, under that policy.** In every other area an agent's write stays a
  suggestion, answers no questions, and appears in no summary until a person
  accepts it.
- The area's current policy is visible on the admin surface next to its name,
  and changing it records who changed it and when; the previous setting stays
  readable.
- One list shows every suggestion waiting for a person, with what it claims,
  which category it chose and why, where it came from, and how sure Rye is.
- Accepting makes a suggestion answer questions immediately and marks what it
  replaced as replaced, not deleted. Declining requires a reason; the declined
  item stays readable. Nothing is ever edited in place.

### S7 — Categorization gets better without a code change

As a Rye admin, the descriptions agents categorize against live in the graph
and improve the same way any other knowledge does.

- A category's description can be proposed, reviewed, accepted, and later
  superseded, using the same review path as any other suggestion.
- Improving a description requires no change to any skill or plugin file, and
  the improved text appears in the next discovery reply.
- Previous descriptions stay readable, so a past categorization can be judged
  against the description in force when it was made.

### S8 — Install path still works

As a developer, I can install Rye beside an existing database without
changing that database.

- Following only the README fast start, install completes and reports success
  against a fresh local database and against an existing remote database.
- Every pre-existing application table is unchanged afterwards, and the
  application still starts.
- One command reports status: installed, version, active areas, plugins.
- An agent given only the onboarding skill takes an admin from install to a
  working area with at least one category in it.

### S9 — Where it came from, and what was true when

As a reviewer or an agent, anything Rye answers with can show its backing and
its history.

- Every accepted fact records how Rye knows it, what it came from, and what
  backs it up; two supports tracing to one original witness count once.
- A fact built from restricted material is never shown to someone who could
  not see that material.
- Asking about a past date returns what was true then, including facts since
  replaced; asking what Rye believed then excludes anything learned later.

## Constraints

- Plain PostgreSQL 15 or newer, and Supabase. No runtime, framework, ORM, or
  build step for the core.
- Nothing is edited in place; records of what happened never change.
- Overlay only. Operational tables never point at Rye.
- Procedure lives in git; vocabulary lives in the graph.
- Internals keep the canonical vocabulary; only human-facing surfaces use the
  plain register.
- No customer names in committed examples, fixtures, or documentation.
- The v2 lifecycle — suggestions, evidence, open questions, summaries — must
  still behave as it does today.
- Continuous-integration workflow files cannot be pushed with the credentials
  currently available; changes there need the repository owner.

## Open questions

Listed for the record; the ones needing a decision are in the accompanying
report.

- Whether a category's description is one accepted fact per area, or one
  shared description that areas may override.
- What counts as "confident" versus "ambiguous" for an existing match, and
  whether that line is set per area or globally.
- Whether an abstention is a first-class item a reviewer works, or only a
  recorded outcome nobody is asked to act on.
- Whether an agent may propose a new category as a suggestion, or only raise
  an open question about the gap.
