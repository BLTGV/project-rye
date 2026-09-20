# Agent authorization and adoption strategy

People know Rye is in use. They never learn its vocabulary. They talk to an
agent, and the agent does the recording. This document says what a person can
expect, the one rule that decides what counts as accepted, what is built today,
and how a trusted setup becomes an enforced one. The mechanism a Rye admin
operates is at the end.

Behavior was checked against the contracts and the source under
`schema/migrations` and `admin/src/server`. Paths are repository references,
not web links. No live database was queried.

## The human contract

A person can say five things and expect them to work, at any scale.

| The person says | What happens |
|---|---|
| "Remember this." | The agent records it and echoes one line back. |
| "What do we know about X?" | The agent answers, says where each statement came from, and flags anything disputed or out of date. |
| "That's wrong. It's Y." | The agent replaces the statement, keeps the history, and echoes the new line. |
| "Who said that?" | The agent names the person, the place, and the date. |
| "Ask me if you're unsure." | The agent asks only when the answer changes what happens next, most important first, and never the same thing twice. |

The person never chooses a category, an area, a review policy, a basis, or a
status, and never visits a queue. A design that asks an ordinary person for one
of those is wrong for that person. What changes with scale is not what they
say. It is who may settle it, and where the confirmation happens.

## The one rule: acceptance follows authority

An agent carries the authority of the person it acts for and none of its own.
An agent acting for nobody has no acceptance authority at all. It can suggest,
and its suggestions route to people who can settle them. Trust attaches to
identity and channel, not to being human.

### Who may settle a claim

Whoever answers for a statement if it turns out wrong gets to settle it. One
lookup gives that answer, and every agent gets the same one. `rye_settlers()`
(migration 0021) runs three steps, and the first that produces a settler wins:

1. **A recorded grant** in `domain_authorities` for this kind of claim in this
   area. It covers topics with no owner relationship (pricing, legal, brand)
   and non-person authorities such as "the billing system is authoritative for
   invoice status". A grant appears when someone says "Priya decides pricing";
   it is not a setup step.
2. **The relationship.** You settle claims about yourself. Your manager settles
   what is expected of you, along a `reports_to` relationship. The owner of a
   thing settles claims about it, along an `owns` relationship. Both are
   declared by the `rye-org` plugin.
3. **The owner of the area**, for everything else.

As built, the lookup is restrictive wherever it is unsure. Where
`contracts/sql-surface.md` is stricter than the proposal it came from, the
contract wins. **A person settles a claim about themselves only when its kind
is positively known to be a self kind.** The core self kinds are `commitment`,
`self_commitment`, and `self_report`; an organization declares more. A kind
nobody has declared, or a known one spelled a new way, goes to the area owner,
and no classification of the statement makes a person their own settler. An
expectation is set on a person by someone else, so the person it is set on is
never its settler. Agents are never settlers, as speaker, manager, owner of a
thing, or owner of an area. Not being able to see a declaration never widens
the answer.

The lookup reads no standing claim, so it cannot tell a new statement from a
contradiction of an accepted one. The skill carries that guard: before
replacing anything, the agent checks who authorized the standing row, and
records a suggestion when it was somebody else or when nothing was recorded.

The lookup is read-only and advisory. It writes nothing, refuses nothing, and
no write path calls it. It is discipline the skills follow, not a wall the
database holds.

### When the speaker cannot settle it

Nothing a person says is refused or lost. Their statement is recorded as a
suggestion with their words as backing, and their agent checks with someone who
can settle it. They never hear "you lack authority". They hear: "That's Priya's
call. I'll check with her and let you know." Until it is settled, agents show
it as unsettled rather than hiding it.

The hard case is an objection. Bob manages John, and tells his agent that John
needs to log his sales calls. A manager settles what is expected of his report,
so it is accepted. John's agent raises it and John says he does not need to.
John cannot settle what is expected of him, so his reply overwrites nothing. It
is recorded as an objection, and his agent asks one question: why. The reason
picks the route. "The CRM already logs them" is something John witnessed. "Bob
isn't my manager anymore" challenges the reporting line and goes to the area
owner. "I don't think it's useful" goes to Bob as one sentence from his own
agent, and Bob answers once.

That prevents John's "no" winning because it came last, his objection vanishing
because he had no standing, and two agents holding contradictory accepted
statements. Accepted stays accepted until a settler changes it, and an
objection is a record of its own.

**The confirmation in the conversation is the acceptance surface.** When Dana's
agent asks "Marcus said your assets will slip to the 28th. Is that right?" and
Dana answers, that reply is the event that settles it: Dana authorizer, her
agent executor, Marcus's statement the origin. Nobody opened a screen.
`review_queue` stays the durable backing an agent reads to find the questions
it owes. It stops being a place a person goes.

## What is built today versus proposed

As of 2026-09-19.

| Capability | Status |
|---|---|
| Direct PostgreSQL access through session context and the lifecycle helpers | Built |
| `rye_settlers()`: the three-step lookup, self kinds restricted to known ones, agents excluded, past dates reconstructible | Built, read-only and advisory. No acceptance path calls it |
| `reports_to` and `owns` conventions | Built, declared by the `rye-org` plugin |
| Asking who may settle a statement; the guard against overwriting a standing claim | Built as skill discipline in `skills/rye-agent-ops` |
| `./scripts/rye settlers`, and the same call over SQL or the API | Built |
| Review policies `open`, `candidates_only`, `strict` | Built |
| Agent identities, expiring and revocable tokens, capability grants with area and scope | Built |
| Scoped agent tokens deny by default on the admin API, `HEAD` decided as `GET` | Built (GitHub issue 16, work/003), only while `RYE_API_AUTH_MODE=required` |
| HTTP API for context, observations, candidates, review; stdio MCP adapter for a subset | Built; authenticate deployments explicitly. The adapter is not a full SQL or acceptance interface |
| Routed confirmations: a read returning the questions a person owes, so any of their agents can ask | Proposed |
| Objections as first-class records that route by their reason | Proposed |
| The one-line echo after every write | Proposed as a skill requirement; nothing enforces it |
| Source identity binding as a confirmed, recorded step | Proposed |
| Enforcement of the lookup from the acceptance path, for API callers | Proposed |
| Configuration writes need a Rye admin. A non-admin attempt to record, end, or edit an accepted registry entry or review policy lands as a suggestion waiting for an admin, or is refused on every other route (migration 0023, work/005) | **Built.** Like all of Rye's access rules it binds callers whose session variables are set honestly or by a trusted backend. The same protection for ordinary assertions is still open: a caller can promote or end one by setting the helper-only write-path settings |
| Row-level security on the tables holding areas and grants | Open, work/004, separate. Only `agent_api_tokens` is protected today |
| Conditional auto-accept rules matched against verified source evidence | Proposed, narrowed. See the mechanism section |
| Objectives, and importance computed from them rather than from recency | Proposed |
| Turnkey channel, repository, or scheduled-runner integration | Not established. Configure the runtime and its sources separately |

Implementation: migrations `0016_agent_domain_security.sql`,
`0018_knowledge_governance_salience_gardening.sql`, and
`0021_settlement_lookup.sql`; `admin/src/server/route-policy.ts` and
`worker.ts`; `skills/rye-source-context-intake/scripts/rye_api_mcp_server.mts`;
`docs/agent-ops-guide.md`.

## Three adoption examples

### One person, one agent, direct database access

Dana keeps a repository and an agent that can run `psql` against her own
PostgreSQL 15+ database. No Worker, no API, no channel connector.

**She says.** "We decided billing webhooks activate subscriptions, not frontend
callbacks." Later: "What did we decide about subscriptions?" Later still:
"Actually, webhooks or the admin console. Fix it."

**The agent does.** It reuses the project and vocabulary already in the graph
rather than inventing duplicates, asks the lookup who may settle a decision
here, gets Dana, records it, and echoes one line back. It answers her question
with the date and the source. On the correction it supersedes, keeps the
original, and echoes the new line.

**Recorded.** One event per utterance. One accepted statement with basis
`reported`, the event as backing, Dana as authorizer and the agent as executor.
One supersession.

**Behind the scenes.** Dana is asked nothing. Her agent, using her database
access, makes sure an area exists with her as its owner. One person over one
area settles everything in it by construction, so no review policy needs
choosing. Today that is one step short: the area and owner are still created
deliberately, and the review policy still decides whether an accepted write
stays accepted.

**Enforced versus discipline.** Nothing is enforced. The agent holds Dana's
full database authority and can exceed the working agreement. A skill
instruction is not a sandbox.

### A small trusted team, each with their own agent

Dana designs, Marcus builds, Priya leads. One shared Rye database. Each has
their own agent and their own database credentials from a password manager or
local secret store. No API deployment.

**They say.** Dana: "I'll deliver the approved assets on the 25th." Marcus:
"Dana's assets are going to slip. Plan for the 28th." Priya: "We're cutting the
testimonials section. Decided." Marcus, a week later: "What's the state of the
homepage?"

**The agents do.** Dana's is a self-commitment of a core self kind, so she
settles it and it is accepted at once, with one line back. Marcus's statement
is about Dana, so he is not its settler: it becomes a suggestion and Dana's
agent asks her the next time she is talking to it. She says the 25th holds, the
suggestion is declined with her reply as the reason, and Marcus's agent tells
him next time he raises the homepage. Priya's decision has no relationship
default, so it falls to the area owner, who is Priya. Marcus's question is
answered with each statement, who said it, and when.

**Recorded.** Accepted self-commitments, a declined suggestion with its reason,
an accepted decision, and an event per confirmation keeping authorizer and
executor apart.

**Behind the scenes.** The Rye admin, one of the three, creates the area with
an owner and gives each person a distinct user id for attribution. A grant is
written only when someone states one in plain words: "Priya decides pricing"
becomes one row. Nobody fills in a form.

**Enforced versus discipline.** All discipline: each of the three holds a raw
connection and can set their own role. Routing depends on every agent running
the same procedure, and the read that tells a person's agent which questions
they owe is proposed, not built, so today the settlers are written onto the
suggestion and the asking depends on cooperation.

### A team with a channel agent and an unattended agent through the API

The same three, plus a channel agent watching the launch channel and a
scheduled runner that proposes follow-ups nightly. Both reach Rye over the HTTP
API, never with database credentials. A contractor is in the channel with no
confirmed link from their chat account to a person record.

**They say, in the channel.** Dana: "Assets are done, uploading now." The
contractor: "I can probably do the copy pass by Wednesday." Priya, in a thread:
"Yes, let's do that."

**The agents do.** The channel agent records what it heard and replies
in-thread with one line, so the record is visible where it was made. The
contractor's message is hedged and comes from an account nobody has linked to a
person, so even their own yes is backing and not acceptance: it routes to
Priya, who holds the area, and her agent asks her. Priya's "let's do that"
needs a referent, so the channel agent asks in-thread rather than guessing. The
nightly runner acts for nobody: it notices the copy pass depends on assets that
are done, and proposes a follow-up Marcus sees as a sentence from his own agent
in the morning.

**Recorded.** Suggestions with the message as backing. Accepted statements with
several rows of backing: the original message, the speaker's confirmation, the
settler's. An action log entry for every write attempt, allowed or refused.

**Behind the scenes.** The Rye admin provisions one identity and token per
runtime with its own grants, sets `RYE_API_AUTH_MODE=required`, and keeps
database credentials away from every runtime. The channel agent gets reading
and suggesting, and no acceptance capability. Nobody on the team names one.

**Enforced versus discipline.** Token scope is enforced: a token is refused on
any route it holds no grant for, and a route that declares nothing is refused
by default, so nothing opens by omission. Authority routing is still
discipline. So is binding a chat account to a person, which is proposed: until
it exists a channel agent treats every speaker as unbound.

## From trusted to enforced

Rye's authorization is session variables checked by row-level security. Anyone
holding a raw database connection can set their own role, so under direct
database access every rule in this document is discipline, not a boundary the
database holds. Enforcement begins when a trusted layer sets those variables
instead of the caller.

1. **Attribute before restricting.** A distinct user id per person and an
   identity per agent. Nobody is limited yet.
2. **Write the rules as data while still trusting everyone.** Grants, areas and
   owners, relationships. The action log shows what would have been refused.
3. **Move the people to be restricted onto the API**, with narrow grants,
   expiring tokens, and `RYE_API_AUTH_MODE=required`.
4. **Rotate the database credentials.** This is the real enforcement step.
   Skipping it leaves every earlier step decorative.
5. **Test the refusals:** missing token, revoked token, expired token, a
   capability not granted, a write to another area.
   `tests/conformance/21_api_security.sh` covers the route checks.

A restricted person's experience does not change. Restricted does not mean
silenced. Their statement still becomes a suggestion and still routes to a
settler.

## Mechanism, for the Rye admin and operators

**Accepted is a lifecycle status**, not a guarantee that a statement is
correct. Read current accepted knowledge through `current_valid_assertions`; a
future-effective accepted assertion is not current yet.

**Review policies** govern what an ordinary `record_assertion()` submission
requesting `accepted` lands as:

| Policy | Behavior |
|---|---|
| `open` | Accepted is permitted, subject to evidence, permissions, and other lifecycle checks. |
| `candidates_only` | Non-observed submissions become candidates. Observed submissions may stay accepted. |
| `strict` | Accepted submissions become candidates. |

An explicitly requested candidate stays one. Missing or unresolved scope policy
resolves to `open`, so configure the scope rather than relying on that default.
Policy governs the initial write only: lifecycle helpers can accept candidates
afterwards, so `strict` is not proof that only a person ever accepts.
`observed` is not a trust credential either. Reading a message proves the
message exists, not the claim inside it. Testimony is `reported`, agent
interpretation is `inferred`, and relabelling either to get a write through is
forbidden.

Configuring a scope policy, for an admin who already holds the access. This
grants no new database authority, and `admin` is the fully authorized owner of
the instance, not a default for unattended agents:

```sql
BEGIN;
SET LOCAL search_path = rye, public, pg_catalog;
SET LOCAL "app.current_role" = 'admin';
SET LOCAL "app.current_user_id" = 'user:owner';
SELECT record_scope_policy(
    '<scope_uuid>'::uuid,
    'review_policy',
    '{"review_policy":"open"}'::jsonb,
    'default',
    'user:owner'
);
SELECT scope_review_policy('<scope_uuid>'::uuid);
COMMIT;
```

**Identities, tokens, capabilities** (migration 0016). One identity and token
per runtime; never share a reviewer's token with a channel agent. Reading is
`rye.context.read`, suggestions `rye.candidate.create`, observations
`rye.observation.create`, acceptance `rye.authoritative.promote`, and
`rye.review.read` shows the review queue without granting acceptance. Keep
tokens in runtime secret stores, never in prompts, repository instructions, or
committed MCP configuration.

**The API.** `RYE_API_AUTH_MODE` defaults to `off`, and none of the
authorization contract applies until it is `required`. Set it before exposing
the API. The route table in `contracts/admin-api.md` is normative: agent tokens
are refused on any route with no row, `HEAD` is authorized by the `GET` row for
the same path, and four whole-instance rollups are closed to agent tokens. A
`global` check asks whether a token holds a capability anywhere, not whether it
holds it here, so do not build an area boundary on a `global` route.

**One Worker serves the reviewer's screen or agents, not both.** The console
sends no `Authorization` header, so with auth required it is refused on every
call. Bearer authentication is not a person-login system; provision human
access separately.

**The MCP adapter** (`skills/rye-source-context-intake/scripts/`) expects
`RYE_API_URL` and `RYE_AGENT_TOKEN`, covers context reads, observations,
suggestion submission, review-queue reads, and audit reads, and exposes no
acceptance tool even to an identity holding a promotion grant.

**Session and connection discipline.** Use a transaction so context and
operations share a connection, with `SET LOCAL` or transaction-local
`set_config()`. With per-call SQL tools such as Supabase MCP, set context and
run the operation in the same call; context does not survive to the next one.
Do not let pooled-session state leak between people. Session values are
caller-supplied context, not proof of identity, and a caller-supplied `actor`
label proves nothing on its own. Keep the human authorizer and the agent
executor in separate evidence fields, and use lifecycle helpers even when fully
authorized: authority to act is not a reason to destroy history.

**What is left of the conditional-rule proposal.** One narrow case: a speaker
whose source identity is confirmed and bound to a person makes an explicit
commitment about themselves in a subscribed channel. That may be accepted
without a separate confirmation. Everything else is decided by the lookup. If
the narrow case is built it records the rule revision that matched, the
verified source, the acting agent, and the authorizing person; an authenticated
admin activates the rule, never the agent that drafted it; ordinary channel
content cannot change it; and a missing rule never falls back to acceptance.
Verified source identity is the hard part, and configuration alone does not
establish it.

## Adoption order

1. One person, or a team that trusts itself: direct SQL, the skills, an area
   with an owner, and the lookup as discipline. Prove one write and read loop
   before adding infrastructure.
2. Apply migration 0023 before treating the lookup as meaningful on a shared
   instance. It stops a non-admin from recording or ending the configuration
   that decides who settles what. The same protection for ordinary
   assertions is not built yet.
3. Channel agents and unattended runners: separate API identities, narrow
   grants, `RYE_API_AUTH_MODE=required`, and refusal tests for the routes
   used. Rotate database credentials once restricted people are on the API.
4. Enforcement of the lookup, for API callers only. Direct database users stay
   trusted by construction.
5. Conditional rules last, only for the one narrow case above, shipped with
   identity verification, evidence checks, and refusal tests together. Do not
   describe a prompt-only promise as enforcement.

Adoption has worked when a fresh agent can retrieve a statement recorded weeks
ago, say who settled it and when, propose a change, route it to whoever may
settle it, and keep the history when they do.
