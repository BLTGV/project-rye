# Rye Product Definition

Owner: Product role. Source of intent: `BRIEF.md`. This document says who Rye
is for, what it must do, what it must not do, and what "done" means. It never
says how. Terms used here are defined in `docs/glossary.md` and follow the
plain register in `docs/vocabulary-contract.md`.

## Purpose

Rye gives one organization a single, shared, reviewable memory: the things
that happened, the things that are true, when they were true, and where each
of those came from. It lives inside the organization's existing database as an
overlay, so adopting it changes nothing that already runs and dropping it
leaves everything intact. It exists so that AI agents can read and write
organizational knowledge without people losing authority over what counts as
accepted.

## Users

- **The Rye admin.** Usually a technical or semi-technical person at a small
  organization. Wants to point agents at their real work without hand-feeding
  context every session. Judges Rye by whether the first useful scope exists
  quickly and whether they trust what is in it.
- **The reviewer.** A person who knows the business but not the database. Sees
  suggestions waiting for a person, accepts or declines them, and settles open
  disagreements. Judges Rye by whether each item explains itself: what is
  claimed, where it came from, how sure Rye is.
- **The developer adopting Rye.** Installs Rye next to an existing application
  database and connects domain tables to it. Judges Rye by whether nothing in
  their application had to change.
- **The agent.** Needs a compact briefing about an area of the business, a
  short list of safe write paths, and a clear answer about what it may record
  itself versus what it must suggest.

## Goals

1. A new organization goes from nothing to a first scope with real reviewed
   knowledge in it in under an hour, guided by an agent.
2. Every accepted fact can answer three questions on demand: where it came
   from, how sure Rye is, and when it is true.
3. Agents suggest by default; people accept. The line moves per area of the
   business, deliberately, and never by accident.
4. Rye stays small. Everything specific to an industry, a tool, or a workflow
   arrives as a plugin and can be checked against the area's policy before an
   agent writes anything.
5. Rye is an overlay. Installing or removing it never changes operational
   systems.

## Non-goals

- Being the day-to-day screen where people manage domain records. Domain
  applications keep that job; Rye's surface is for reviewing knowledge.
- Deciding on its own that knowledge is stale enough to delete. Retention is
  designed for now; automatic cleanup comes later.
- Depending on any one connector vendor, chat tool, or hosting provider.
- Inferring what a source means from its name. An unlabelled source stays an
  open question until a person answers it.
- Being a general document store or a search index over raw content.

## Stories

Each story is checkable by someone with the admin surface, the command line,
and no access to the code.

### S1 — First hour
As a Rye admin, I can install Rye and stand up my first scope without reading
the design docs.

- Following only the README fast start, install completes and reports success
  against a fresh local database and against an existing remote database.
- Installing into a database that already has application tables leaves every
  one of those tables byte-identical, and the application still starts.
- After install, one command reports status: installed, version, active
  scopes, enabled plugins.
- An agent given only the onboarding skill can take an admin from install to
  an active scope, and refuses to create the scope until purpose, boundary,
  owner, and review policy are answered.
- Whole path, timed by a first-time admin, finishes in under an hour.

### S2 — Scope is named after the work, not the tool
As a Rye admin, my first scope describes the business function Rye is helping
with, and what is deliberately out of scope.

- Creating a scope records its purpose, what is in scope, what is out of
  scope, its owner, and what would signal the purpose has changed.
- A scope named after a source or connector is challenged by the agent, with
  the reason, before it is created.
- The scope's stated boundary is visible on the admin surface and readable by
  a person who was not there when it was written.

### S3 — Suggest by default
As a reviewer, agents cannot quietly write accepted knowledge into my area.

- Each scope carries one of three settings: agents may record accepted
  knowledge here; agents suggest and people accept; everything waits for a
  person.
- With the middle or strictest setting, anything an agent writes appears as a
  suggestion and never in an answer to a normal question.
- Changing the setting is recorded with who changed it and when, and the prior
  setting remains readable.

### S4 — The review queue
As a reviewer, I can work a single list of suggestions waiting for a person.

- One list shows every pending suggestion, with what it claims, where it came
  from, and how sure Rye is.
- Accepting a suggestion makes it answer questions immediately, and marks the
  fact it replaced as replaced rather than deleting it.
- Declining a suggestion requires a reason, and the declined item stays
  readable afterwards.
- Nothing in the list can be edited in place; a correction is a new entry.

### S5 — Open disagreements
As a reviewer, when two sources disagree I see one disagreement, not two
unrelated items.

- Two competing suggestions about the same thing appear together as one open
  disagreement.
- Accepting one leaves the other untouched and still declinable.
- While a disagreement is open, Rye reports lower certainty about that fact.
- A worked-out or assumed suggestion cannot displace something a person or a
  direct observation established.

### S6 — Where it came from
As a reviewer or an agent, every accepted fact can show its backing.

- Every fact records how Rye knows it: seen directly, heard from someone,
  worked out, taken on faith, or unclear.
- Every fact lists what it came from and what independently backs it up.
- Two supports that trace to the same original witness are not counted as two.
- A fact built from restricted material is never shown to someone who could
  not see the material it was built from.

### S7 — Summaries that admit when they are outdated
As an agent, I get a short briefing about a subject rather than a raw pile.

- Asking about a subject returns summaries first, each stating what it was
  built from and as of when, then anything not yet covered by a summary.
- When newer accepted knowledge arrives, or a fact a summary rests on is
  overturned, that summary is listed as outdated.
- A summary never quietly includes suggestions that nobody accepted.

### S8 — Open questions
As a reviewer, the things Rye does not know are visible, not silent.

- When material arrives that does not fit the scope's expectations, Rye
  records an open question instead of guessing or discarding it.
- Open questions are listed with the reason they were raised.
- Answering an open question closes it and links the answer; the closed
  question stays readable.
- The same question recurring can be raised as a proposal to revisit the
  scope, and never changes the scope on its own.

### S9 — History
As anyone, I can ask what was true at a past date and what Rye believed then.

- Asking about a past date returns what was true then, including facts since
  replaced.
- Asking what Rye believed at a past date excludes anything learned later.
- Suggestions never appear in either answer.
- A change scheduled for a future date does not affect today's answers, and
  does affect answers on and after that date.

### S10 — Plugins carry the vocabulary
As a Rye admin, industry and workflow vocabulary arrives as plugins I can turn
on per scope, and agents are blocked from writing outside them.

- A catalog lists installed plugins, skills, and permissions.
- Enabling a plugin for a scope makes only that scope's vocabulary available
  there.
- An agent attempting to write a term the scope has not enabled is refused,
  and the refusal names the policy that blocked it.
- Turning a plugin off does not delete knowledge already accepted under it.

## Constraints

- Plain PostgreSQL 15 or newer, and Supabase. No runtime, framework, ORM, or
  build step for the core.
- Nothing is edited in place. Corrections replace; records of what happened
  never change.
- Overlay only. Operational tables never point at Rye; removing Rye leaves
  them working.
- Internals keep the canonical vocabulary; only human-facing surfaces use the
  plain register in `docs/vocabulary-contract.md`.
- No customer names in committed examples, fixtures, or documentation.
- Storage growth is a design constraint everywhere now; automatic cleanup is
  deferred.
- Continuous-integration workflow files cannot be pushed with the credentials
  currently available; changes there need the repository owner.

## Open questions

Listed here for the record; the ones needing a human decision are in the
report that accompanies this document.

- Whether a scope owns its subjects durably, or whether an agent must name the
  scope on every write.
- What the reviewer's smallest useful surface is: whether the review queue
  must ship as a screen, or whether the command line is enough for the next
  stage.
- Whether "under an hour" is measured against a local database only, or must
  hold for a remote database with existing application data.
- Which plugins must exist before the first scope is genuinely useful, given
  that people, teams, and goals are foundational but not core.
- How much of a source may be sampled during discovery before a person has
  confirmed what that source means.
