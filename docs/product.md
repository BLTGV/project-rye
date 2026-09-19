# Rye Product Definition

Owner: Product role. Source of intent: `BRIEF.md`. Who Rye is for, what
it must do, what it must not do, what "done" means. Never how. Terms are in
`docs/glossary.md`, in the plain register of `docs/vocabulary-contract.md`.

The document has two parts. Part one is v0.3 and is unchanged. Part two, from
"Part two: v0.4" onward, adds the v0.4 users, goals, non-goals, and stories.
Everything in part one still holds in v0.4 unless part two says otherwise.

**Two meanings.** *Classification* in Rye already means sensitivity — who may
see a thing. The business sense, *what type of thing this is*, is a
**category**; choosing one is **categorizing**. Only the loop step keeps the
brief's word "classify".

# Part one: v0.3

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

# Part two: v0.4

Source of intent: `BRIEF.md`, sections "What v0.4 is for", "What done for v0.4
looks like", "Out of scope for v0.4". The reasoning is in
`design/proposals/human-agent-scaling.md`; the decisions dated 2026-09-19 in
its "Decided" section are the human's. Part two covers stages 0 through 2 of
that proposal. Stages 3 and 4 are not v0.4.

## Purpose (v0.4)

v0.3 teaches an agent how to file things. v0.4 is about the person on the other
side of the agent. People know Rye is in use and never learn its vocabulary:
they talk to their own agent, and it remembers, answers, corrects, says who
said what, and asks only when unsure. Underneath, acceptance follows authority.
An agent carries the authority of the person it acts for and none of its own.

## Users (v0.4)

- **The person who never learns Rye.** New in v0.4. Does a job, talks to their
  own agent, and knows Rye is in use without knowing a single one of its words.
  Never picks a category, an area, a policy, or a status, and never opens a
  list. Judges Rye by whether their agent remembers what they said, corrects
  itself when told, names who said what, and asks only when the answer changes
  what happens next.
- **The reviewer.** Changed. In v0.3 the reviewer visits one list of
  suggestions. In v0.4 the reviewer answers a question from their own agent, in
  a conversation they were already having, and answers it in plain words. The
  list stays as the durable backing that nobody has to visit. Who counts as the
  reviewer is decided per claim, by who may settle it, rather than assigned per
  person.
- **The agent.** Changed. Carries the authority of the person it acts for and
  nothing more. Before recording anything as accepted it needs an answer to
  "may this person settle this?", and it needs to know which questions its
  person owes so it can ask them in whatever conversation comes next.
- **The Rye admin.** Changed. Sets up nothing for a lone person working over
  their own area. For a team, records who reports to whom and who owns what,
  and is the one person who still sees the mechanism.
- **The developer adopting Rye.** Unchanged from part one.

## Goals (v0.4)

1. One answer to who may settle a claim, the same for every agent, from one
   lookup: a recorded grant for that kind of claim, then the relationship
   (yourself, your manager, the owner of the thing), then the owner of the
   area.
2. Nothing a person says is refused or lost. If they cannot settle it, it is
   recorded as a suggestion and a settler is asked.
3. An objection to something already accepted is kept as a record and routed by
   its reason. Accepted stays accepted until a settler changes it.
4. Every write is echoed back in one line the person can correct.
5. Any of a person's agents can find out which questions that person owes, most
   important first.
6. Authority is granted in plain words. "Priya decides pricing" is the whole of
   it: no form, no setup step.
7. No fixed caps and no clocks. How often an agent asks, and what happens when
   a settler is silent, follow what matters, and a person changes both by
   saying so.
8. An agent that comes in through the API reaches only the requests and rows
   its grants allow.
9. A lone person over their own area settles everything in it with no setup at
   all.
10. No one but the Rye admin hears a Rye word.

## Non-goals (v0.4)

- Agents that act in shared spaces, connecting a source account to a specific
  person, and rules that accept some writes automatically by condition.
- Objectives, scoring how important something is, and a parked state for
  suggestions nobody needs to see.
- Several Rye databases working together.
- Holding the lookup against people with a direct database connection. They are
  trusted by construction; the boundary applies to callers that come through
  the API.
- Delivering a question to a person. Rye works out who owes what; the agent
  doing the asking delivers it.
- A second list. The existing suggestions list remains the durable backing.
- **Reading of the v0.3 non-goal about "tokens".** In part one that word sits
  beside forecasting, calibration, and reputation, so it is read here as the
  forecasting-era stake concept, not as the credential an agent presents to the
  API. v0.4 needs the credential. Flagged under Open questions (v0.4) rather
  than settled here.

## Stories (v0.4)

Each story is checkable by someone with no access to the code, either by
holding a conversation with an agent or from the admin surface. Unless a
criterion says otherwise, no Rye word appears in anything a person hears.

### S10 — Who may settle this

As an agent, before I record anything as accepted I can ask who may settle the
claim, and every other agent gets the same answer.

- One request, given who is speaking, what the claim is about, what kind of
  claim it is, and the area, returns who may settle it and which of the three
  steps produced the answer: a grant, a relationship, or the owner of the area.
- A person is returned as the settler of claims about themselves with no setup
  beforehand. A lone person over one area settles everything in it, with no
  setup conversation and nothing to fill in.
- With a reporting line recorded, the manager is returned as the settler of an
  expectation on their report, and the report is not. When the reporting line
  ends, the manager is no longer returned.
- With ownership recorded, the owner is returned as the settler of claims about
  the thing they own.
- A recorded grant for a kind of claim wins over the relationship. A grant
  naming a system or a source account is returned as such.
- A kind of claim with no grant and no relationship returns the owner of the
  area. An area with no owner returns no settler and says so; that is a setup
  gap for the Rye admin, not an error.
- No agent is ever returned as a settler.
- Asking as of a past date uses the grants and relationships in force then.
- A person in a conversation sees none of this happening.

### S11 — A statement the speaker cannot settle

As a person, when I say something I am not the one to settle, my words are
still recorded and someone who can settle them is asked.

- The statement is recorded as a suggestion with my words kept as its backing,
  and it is routed to a settler. Nothing is refused and nothing is dropped.
- What I hear back names who will decide and says my agent will check with
  them. I am never told that I lack authority and I never see a status word.
- Until it is settled, an agent asked about the subject says the claim exists,
  says it is unsettled, and names who said it. It is not hidden and it is not
  answered with.
- The settler hears one question from their own agent, in their own
  conversation, and a plain yes or no settles it. They open no list.
- When the settler answers, the person who spoke is told once, including when
  the answer is no, and the settler's reason comes with it.
- Replay: one person states a date for another person's work; the second
  person's agent asks them; their reply settles it; the first person is told
  without having to ask.

### S12 — An objection to something already accepted

As a person who disagrees with something already accepted about me, my
objection is recorded and goes to whoever can act on it.

- A manager states an expectation on their report. It is accepted at once,
  because the manager may settle it. The report saying no does not change it.
- The report's reply is recorded as an objection against that expectation and
  stays readable afterwards with its reason.
- The report's agent asks one question: why. The reason decides where it goes.
  Something the report witnessed is accepted as their own observation and
  attached to the objection. A claim that the reporting line is wrong goes to
  the owner of the area. An opinion goes to the manager.
- The manager hears one sentence from their own agent and answers once. Either
  the expectation is replaced, or the objection is declined with the manager's
  reason and the report is told once.
- Three failures must not happen: the report's "no" winning because it was said
  last; the objection disappearing because the report could not settle it; and
  the two agents answering the same question differently. Until the manager
  answers, both agents say the expectation stands and that it has been
  objected to.
- Nobody involved visits a list, and nobody hears a Rye word.

### S13 — A grant made in plain words

As a person who can settle things in an area, I can say who decides something
and that is the whole of it.

- Saying "Priya decides pricing" in an ordinary conversation records the grant.
  There is no form, no setup step, and no separate admin session.
- The agent echoes it in one line naming the person and the topic, and it can
  be corrected in the same breath.
- Afterwards, claims of that kind from anyone else route to that person, and
  asking who decides it names them, who granted it, and when.
- A grant can be ended in plain words. After it ends, the lookup falls back to
  what it would have been without it.
- When nobody is recorded for a kind of claim, it falls to the owner of the
  area, whose agent asks once, in plain words, whether someone else should
  decide it. Their answer becomes the grant, and they are not asked again.
- Saying who reports to whom, or who owns what, works the same way and is
  settled by the owner of the area.

### S14 — One line back after every write

As a person, every time my agent records something I see one line I can
correct.

- Each write is followed by a single sentence stating what was recorded, in the
  person's own words, with no Rye vocabulary in it.
- Correcting it in the next breath replaces what was recorded and produces a
  new line. The earlier version stays readable in the history.
- The echo appears for a correction and for a withdrawal, not only for a first
  record.
- Nothing an agent records is silent. Reading the conversation alone is enough
  to know everything that agent wrote.

### S15 — The questions a person owes

As any one of a person's agents, I can find out what that person owes an answer
on, so the asking happens in whatever conversation comes next.

- One request returns the questions a named person can settle, most important
  first, with enough detail for an agent to ask each one in plain words.
- Any of that person's agents gets the same list, and a question answered in
  one conversation does not come up again in another.
- Two agents that heard the same thing produce one question, not two.
- Questions that person cannot settle are not in their list.
- The list is never a screen a person visits. It is what their agent reads
  before it asks.

### S16 — No fixed caps or clocks

As a person, how often my agent asks and what happens when I stay silent follow
what matters, and I change both by saying so.

- Nothing is ever accepted because a settler stayed silent. Silence is not
  consent.
- No published number caps how many questions an agent may ask, and no deadline
  is set for answering one. The documentation and the skill guidance state
  none, and a reader can confirm that by searching them.
- An unanswered question moves to the owner of the area when what it holds up
  starts to matter, for example when someone else is now asking about the same
  thing, and not because a timer ran out.
- A person saying "ask me less", or "if I have not answered by end of day, ask
  Priya", changes how all of their agents behave, and is echoed back in one
  line like any other write.
- When something is urgent, the question goes to the front of the settler's
  list. It is not accepted on weaker grounds, and it does not skip the settler.

### S17 — An agent reaches only what it was granted

As a Rye admin, an agent coming in through the API reaches only the areas and
requests its grants allow.

- An agent credential without the matching grant is refused on every request
  that returns knowledge, and the refusal names the rule that refused it.
- A request that declares nothing is refused for agents by default. A newly
  added request cannot become readable to agents by omission.
- Listings of areas, of who decides what in them, and of the places they watch,
  return only the areas the credential is granted.
- The list of suggestions waiting for a person returns only the areas the
  credential is granted.
- A missing, revoked, or expired credential is refused as unrecognized. A valid
  credential used against another area is refused as not permitted.
- A credential holding the right grant still works, and the reviewer's screen is
  unchanged when the API is not requiring credentials.
- People with a direct database connection are outside this story. They are
  trusted by construction.

## Constraints (v0.4)

Everything under Constraints in part one still holds. In addition:

- Five things a person can say must keep working at every scale: remember this;
  what do we know about X; that is wrong, it is Y; who said that; ask me if you
  are unsure.
- A person never chooses a category, an area, a review policy, how Rye knows
  something, or a status, and never visits a list. A design that needs one of
  those is wrong for v0.4.
- An agent carries its person's authority and nothing more. It never restates
  how it knows something in order to get a write through, never switches to an
  identity with wider grants, and never asks a more permissive agent to write
  for it.
- Rye works out who owes what. Delivering the question is the job of whatever
  runs the agent.
- Who may settle a claim comes from the one lookup. No parallel answer in a
  skill or a prompt.
- An agent acting for nobody settles nothing.
- A person's agent neither spies nor hides. It does not report on its person
  unprompted, and the absence of a record is visible to a manager who asks.
  This is stated openly to the people using it.

## Open questions (v0.4)

- The v0.3 non-goal lists "tokens" beside forecasting, calibration, and
  reputation. v0.4 requires a credential an agent presents to the API, which
  uses the same English word. Assumed unless the human says otherwise: the
  non-goal covers only the forecasting-era stake concept, and the API
  credential is in scope for v0.4.
- Who settles the reporting line when the owner of the area is the person the
  line is about.
- Whether a person's asking preferences bind only their own agents, or also an
  agent acting for someone else who wants to ask them something.
- What "what it holds up starts to matter" means before objectives exist.
  Assumed: it reduces to someone else now asking about the same thing.
- Whether an objection that nobody settles ever expires, given that no clocks
  are allowed.
