# Scaling human-agent interaction

Status: proposal. Nothing here is implemented or contracted. It follows the
critique of `docs/agent-authorization-strategy.md` and extends it from one
person with one agent to an organization with many of each. It is v0.4
material. The v0.3 brief covers discover, classify, and resolve; this
document assumes those exist.

The people in this document know that Rye is in use. They never learn its
vocabulary. Everything they see is a conversation with an agent.

## The contract that must not change

Whatever the scale, a person can say five things and expect them to work.

| The person says | What happens |
|---|---|
| "Remember this." | The agent records it and echoes one line back. |
| "What do we know about X?" | The agent answers, says where each fact came from, and flags anything disputed or outdated. |
| "That's wrong. It's Y." | The agent replaces the fact, keeps the history, and echoes the new line. |
| "Who said that?" | The agent names the person, the place, and the date. |
| "Ask me if you're unsure." | The agent asks only when the answer changes what happens next, the most important question first, and never the same thing twice. |

The person never chooses a category, a scope, a review policy, a basis, or
a status. They never visit a queue. If a design at any stage requires one
of those, the design is wrong for that stage.

What changes with scale is not what the person says. It is who the
statement binds, who may settle it, where the confirmation happens, and
what the agent does when it cannot settle it.

## Four axes of scale

1. **People.** One person, then a few who trust each other, then teams
   with different authority, then outsiders whose words are evidence but
   never authority.
2. **Agents.** One assistant, then several per person with different jobs,
   then shared agents in channels, then background agents that parse
   documents and conversations with no person present.
3. **Channels.** Direct conversation, then shared spaces, then indirect
   material such as meeting notes, email, and documents.
4. **Areas.** One area of the business, then several with their own
   sources and policies, where a fact from one area matters to another.

## The one rule: acceptance follows authority

Agents never have authority of their own. An agent carries the authority
of the person it is acting for, bounded by the channel it is in. A
background agent acting for no one has no acceptance authority at all. It
can only suggest, and its suggestions are routed to the people who can
settle them.

This replaces the "human-voiced means accepted" default from the earlier
critique, which was too broad. It conflated a person directing their own
agent with a person whose words a channel bot overheard. Trust attaches to
identity and channel, not to being human.

### Speech acts

Every statement an agent hears falls into one of a small set of speech
acts. The agent classifies it. The person never does.

| Speech act | Example | Who can settle it |
|---|---|---|
| Self-commitment | "I'll send the copy by Friday." | The speaker, immediately. |
| Statement about own domain | "Our pricing for the enterprise tier is X." said by the pricing owner | The speaker, if they hold authority for that kind of claim. |
| Statement about someone else | "Dana will have the assets Monday." | Dana, or someone with authority over Dana's commitments. |
| Expectation set on someone | "John needs to log his sales calls." said by John's manager | The person's manager. Not the person. |
| Agreement between parties | "We agreed to ship on the 12th." | Each bound party, or a decider for the area. |
| Decision | "We're going with billing webhooks." | A holder of decision authority for the area. |
| Report from outside | A customer email saying they will renew | Nobody outside. The internal account owner settles what it means. |
| Agent inference | "Based on the notes, the deadline seems to have moved." | Never the agent. Always a person. |

### Who may settle a claim

Whoever would answer for it if it is wrong gets to settle it. That gives
five defaults. They come from relationships in the graph, not from
configuration, so nobody fills in a form to get started.

1. You settle things about yourself: your commitments, your preferences,
   what you saw or heard.
2. Your manager settles what is expected of you. This follows the
   reporting line.
3. The owner of a thing settles facts about it: the account owner, the
   component owner.
4. Anything else goes to the owner of the area.
5. Agents settle nothing.

Rye also has `domain_authorities`, which records who (person, team, role,
system, or source) may perform which speech acts (`confirmed`, `approved`,
`decided`, `policy_set`) for which claim types in which domain. The two
answer different questions. The table is topical: who decides pricing. The
defaults are relational: who decides this about John. The table has no
column for the subject, so it cannot say "Bob may set expectations for
John but not for Mary" without one area per team.

They compose into one lookup, in this order:

1. If an authority row exists for this kind of claim, it wins. This covers
   topics with no owner relationship (pricing, legal, brand) and
   non-person authorities ("the billing system is authoritative for
   invoice status"). A row can also narrow a default.
2. Otherwise the relationship decides: self, manager, owner of the thing.
3. Otherwise the area owner.

The table becomes a short list of exceptions and topical grants. A row
appears when someone says "Priya decides pricing". It is not a setup step.

Two honest notes. The table is advisory today: the only place the schema
reads it is `agent_get_context_pack`, which hands the rows to the agent as
briefing. Nothing in the write path checks it. And the defaults rest on
conventions that do not exist yet: there is no reporting-line or ownership
edge in the schema or the profiles. The reporting line itself is settled
by the area owner, stated once.

### How a claim is settled

For every claim an agent is about to write:

1. Identify the speaker and bind them to a person. In a direct
   conversation this is given. In a shared channel it requires a confirmed
   binding from source identity to person. Unbound speakers produce
   evidence, not authority.
2. Classify the speech act and the claim type.
3. Run the lookup above: authority row, then relationship, then area
   owner.
4. If the speaker is a settler and the channel is bound: record it as
   accepted, with the utterance as evidence, the person as authorizer, and
   the agent as executor. Echo one line.
5. If the speaker is not a settler: record it as a suggestion, and route a
   confirmation to a settler through whatever agent that settler uses.
   The settler sees a question, not a queue item.
6. If the lookup falls through to the area owner for a topical claim, the
   owner settles it and is asked once, in plain language, whether someone
   else should: "Nobody is recorded as deciding pricing. Is that you, or
   someone else?" The answer becomes an authority row. Only an area with
   no owner has no settler, and that is a setup gap raised to the Rye
   admin.

The confirmation in step 5 is the acceptance surface. When Dana's agent
asks "Marcus said you'll have the assets Monday. Right?" and Dana says
"yes", that reply is recorded as an event and used as evidence to accept
the suggestion. Dana is the authorizer, Dana's agent is the executor,
Marcus's statement is the origin. Nobody opened an admin screen.

`review_queue` remains the durable backing for all of this. It is what an
agent reads to find the questions it owes its person. It stops being a
place a person goes.

### When the speaker cannot settle it

Nothing a person says is refused or lost. Their statement is recorded as a
suggestion with their words as evidence, and routed. They never hear "you
lack authority". They hear: "That's Priya's call. I'll check with her and
let you know." Until it is settled, agents show it as unsettled rather
than hiding it: "Marcus said the assets will slip. Dana hasn't confirmed."

The hard case is an objection to something already accepted. Bob manages
John. Bob tells his agent that John needs to log his sales calls. That is
an expectation on John, set by his manager, and it is accepted. John's
agent raises it, and John says he does not need to.

- John cannot settle what is expected of him, so his reply does not
  overwrite anything. It is recorded as an objection to an accepted
  expectation.
- John's agent asks one question: why. The reason decides the route. "The
  CRM already logs them" is something John can witness, so that part is
  accepted as his observation and attached. "Bob isn't my manager anymore"
  challenges the reporting line and goes to the area owner. "I don't think
  it's useful" is an opinion and goes to Bob.
- Bob's agent brings it to Bob as one sentence: John says he doesn't need
  to log calls because the CRM does it. Keep it, change it, or exempt him?
  Bob answers once. Either the expectation is replaced, or the objection
  is declined with Bob's reason and John's agent tells him once.

The model must prevent three failures: John's "no" winning because it was
said last, John's objection vanishing because he lacked standing, and two
agents holding contradictory accepted facts. One rule prevents all three.
Accepted stays accepted until a settler changes it, and an objection is a
first-class record, not an error.

Other cases:

- **Nobody is named for this kind of claim.** It falls to the area owner,
  who is asked once whether someone else should decide it. See step 6.
- **The settler never answers.** Nothing is accepted by timeout. Silence
  is not consent. There is no fixed clock either. An unanswered question
  moves to the area owner when what it blocks becomes important: a linked
  deadline is near, or someone else is now asking about the same thing.
  A settler who wants a clock sets one in plain words: "if I haven't
  answered by end of day, ask Priya."
- **It is urgent.** Importance moves the question to the front of the
  settler's list. It does not lower the bar. If the matter needs action
  now, the person acts in the real system under that system's
  permissions. Rye governs what counts as accepted knowledge, not who may
  open an issue or merge a change.
- **The settler wants to stop being asked.** They delegate in plain words:
  "Dana can confirm copy deadlines for me." That is a policy change, so it
  needs the settler's own bound identity, and it is recorded as an
  authority row with an end date.

An agent must never relabel a statement's basis to get it through, switch
to an identity with wider grants, or ask a more permissive agent to write
it. An agent carries its person's authority and nothing more.

### From trusted to enforced

Rye's authorization is session variables checked by row-level security.
Anyone holding a raw database connection can set their own role, so under
direct access every rule in this document is a discipline the skills
follow, not a boundary the database holds. Enforcement begins when a
trusted layer sets those variables instead of the caller.

1. Attribute before restricting: a distinct user id per person and an
   identity per agent. Nobody is limited yet.
2. Write the rules as data while still trusting everyone. The action log
   shows what would have been denied.
3. Move the people to be restricted onto the API with narrow grants and
   expiring tokens, with the Worker's auth mode set to required.
4. Rotate the database credentials. This is the real enforcement step.
5. Test the denials: missing token, revoked token, denied capability,
   cross-area write. Per-route domain and scope checks must be verified
   first; see GitHub issue 16.

The restricted person's experience does not change. Restricted does not
mean silenced. Their statement still becomes a suggestion and routes to a
settler.

## The stages, with realistic use

Each stage lists who is present, what they say, what the agent does, what
Rye records, what already exists, and what is missing. Names are
invented.

### Stage 0: one person, one agent

**Who.** A founder with a coding agent that has direct database access.
This is Example 2 in the authorization doc.

**They say.** "We decided billing webhooks activate subscriptions. Not
frontend callbacks." Later: "What did we decide about subscriptions?"
Later still: "Actually, webhooks or the admin console. Fix it."

**The agent does.** Records the decision as accepted, echoes "Recorded:
billing webhooks activate subscriptions, not frontend callbacks." Answers
the question with the date it was decided. Supersedes on correction and
echoes the new line.

**Rye records.** One event per utterance, one accepted assertion with
basis `reported` and evidence pointing at the event, one supersession.

**Exists today.** All of it, given an `open` scope.

**Missing.** The scope should not need configuring. One person over one
area is the settler of everything in it by construction. Setup should be
zero. Today Example 2 asks for a setup conversation and a SQL block.

### Stage 1: one person, several agents

**Who.** The same founder, now with a coding agent, a meeting-notes agent
that runs after every call, and an email agent. All act for the same
person.

**They say.** Nothing new. But the meeting-notes agent hears the founder
say on a call: "I'll get the investor update out Thursday."

**The agent does.** The notes agent records a suggestion, not an accepted
fact, because it is inferring from a transcript rather than being told.
The next time the founder talks to any of their agents, that agent asks:
"From Tuesday's call, I think you committed to the investor update by
Thursday. Save it?" One "yes" and it is accepted.

Two agents may hear the same thing. The email agent and the notes agent
both see the Thursday commitment. They must produce one suggestion, not
two.

**Rye records.** Agent identities so provenance says which agent wrote
what. Suggestions with source evidence. One accepted assertion after the
confirmation, with the founder's "yes" as a second evidence row.

**Exists today.** Agent identities, capability grants, action log,
candidate lifecycle, evidence rows, content-hash dedup for artifacts.

**Missing.** Cross-agent dedup on source reference for suggestions. Today
idempotency keys are per agent. A "questions I owe my person" read that
any of the person's agents can use, so the confirmation happens in
whichever conversation comes next. Zero-setup trust for the person's own
agents in their own area.

### Stage 2: a small team, each with their own agent

**Who.** Three people who trust each other, sharing one area. Dana
designs, Marcus builds, Priya leads. Each talks to their own agent. This
is Example 3.

**They say.**

- Dana: "I'll deliver the approved assets on the 25th."
- Marcus, to his agent: "Dana's assets are going to slip. Plan for the
  28th."
- Priya: "We're cutting the testimonials section. Decided."
- Marcus, a week later: "What's the state of the homepage?"

**The agent does.**

- Dana's commitment is accepted immediately. She is the settler of her own
  commitments.
- Marcus's statement about Dana is a suggestion. Dana's agent asks Dana,
  the next time she is talking to it: "Marcus expects your assets to slip
  to the 28th. Is that right?" Dana says "no, the 25th holds." The
  suggestion is declined with her reply as the reason. Marcus's agent
  tells him, without being asked, the next time he raises the homepage.
- Priya's decision is accepted because she holds decision authority for
  the area. Nobody configured that with a policy name. During setup her
  agent asked "who decides scope changes for the launch?" and she said
  "me", and that became an authority row.
- Marcus's question gets an answer that cites each fact: Dana's date and
  when she confirmed it, Priya's cut and when she decided it, and the
  declined slip with Dana's reason.

**Rye records.** Authority rows for the three people. Accepted
self-commitments. A declined suggestion with a reason. An accepted
decision. Events for every confirmation, with authorizer and executor kept
separate.

**Exists today.** Authorities, lifecycle helpers, review queue, evidence.

**Missing.** Routing: which person a suggestion should go to, computed
by the three-step lookup, and exposed so that person's agent can find it.
Edge conventions for reporting and ownership, which the lookup depends on.
Authority rows written only when someone states a topical grant in plain
words. A convention that evidence records authorizer and executor as
distinct fields, so "Dana's agent accepted this on Dana's word" is
reconstructible.

### Stage 3: the team plus shared channels and unattended agents

**Who.** The same team, now with a channel agent watching the launch
channel and a scheduled planning agent that runs nightly. This is Example
1. Two of the three people have their chat identities bound to their
person records. The third, a contractor, has not been bound.

**They say, in the channel.**

- Dana: "Assets are done, uploading now."
- The contractor: "I can probably do the copy pass by Wednesday."
- Priya, replying to a thread: "Yes, let's do that."

**The agent does.**

- Dana's message is a self-report from a bound identity in a subscribed
  channel. It is accepted with the message as evidence. The channel agent
  reacts or replies in-thread with one line so the record is visible where
  it was made.
- The contractor's message is from an unbound identity and is hedged. It
  becomes a suggestion. The channel agent asks in-thread, once: "Should I
  record that you'll finish the copy pass by Wednesday?" If the contractor
  says yes, the suggestion still cannot be accepted on their word, because
  they are unbound. It routes to Priya, who holds authority for the area.
  Priya's agent asks her. She confirms. Accepted, with three evidence rows:
  the original message, the contractor's yes, Priya's confirmation.
- Priya's "yes, let's do that" is an agreement in a thread. The channel
  agent must resolve what "that" refers to. If it can, it records a
  decision. If it cannot, it asks in-thread rather than guessing.
- The nightly planning agent reads accepted commitments, notices that the
  copy pass depends on assets that are now done, and proposes a follow-up.
  It has no authority. Its proposal is a suggestion routed to Marcus, who
  owns the build. He sees it as a sentence from his own agent in the
  morning.

**Rye records.** Channel subscriptions with access levels. Bound and
unbound source identities. Suggestions with thread evidence. Accepted
facts with multi-row evidence. Agent action log entries for every write
attempt, allowed or denied.

**Exists today.** Channel subscriptions, agent tokens and grants, the
observation and candidate submission helpers, the action log.

**Missing.** Source identity binding as a confirmed, recorded step with a
helper. The in-thread echo as a required behavior for channel agents. The
rule that an unbound speaker's confirmation of their own statement is
evidence but not acceptance. The proposed conditional-acceptance rules
from the authorization doc shrink to one narrow case here: a bound
speaker's explicit self-commitment in a subscribed channel. Everything
else is already handled by authority routing.

### Stage 4: an organization with several areas and outsiders

**Who.** Sales, support, and delivery, each an area with its own sources
and its own settlers. Customers and vendors email in. Background agents
parse tickets, call transcripts, and contracts at volume. Most people in
the organization never address an agent directly. They just do their
jobs, and their agents watch.

**They say.**

- A customer emails: "We'll renew if the export feature ships by Q1."
- A support engineer, in a ticket: "Export is blocked on the schema
  migration."
- A sales lead, to their agent: "What's the risk on the renewal?"

**The agent does.**

- The customer's email is a report from outside. It is evidence of what
  the customer said, recorded as a suggestion in the sales area. The
  account owner's agent asks the account owner: "The customer tied their
  renewal to export shipping in Q1. Should I record that as a renewal
  condition?" The account owner confirms. Accepted, authorized by the
  owner, with the email as origin evidence.
- The support engineer's note is a bound self-report in the support area.
  Accepted there.
- The sales lead's question crosses areas. The answer needs the renewal
  condition from sales, the blocker from support, and the migration
  status from delivery. The agent reads all three, subject to what the
  sales lead may see, and answers with sources. If the blocker was
  recorded as visible only to support, the agent says a blocker exists
  and who to ask, without revealing its content.
- The parsing agents produce suggestions at machine volume. Almost all
  of them are unimportant and park silently. The ones linked to an active
  objective with a near deadline, or that contradict an accepted fact,
  are the ones that become questions. There is no fixed cap. A question
  is asked only when its answer changes what happens next, the most
  important first, never twice. A person tunes this in plain words: "ask
  me less", or "save questions for Friday".

**Rye records.** Several areas with distinct authorities and policies.
Sensitivity labels on facts that must not cross areas. Objectives as
nodes, with edges from facts and tasks to the objectives they advance or
threaten. An importance signal over suggestions and gaps.

**Exists today.** Multiple scopes, sensitivity classification, RLS,
`node_salience`, `open_gaps`, distillation and gardening.

**Missing.** Objectives as a convention. Importance computed from
objective links, deadlines, and contradictions rather than from recency.
Asking preferences per person. Cross-area answers that say "ask support"
instead of failing silently. A parked state for low-importance
suggestions that is visible on request and decays without anyone acting.

## Mechanisms, in the order they are needed

Each item names what exists, what is missing, and which stage first needs
it.

| Mechanism | Exists | Missing | First needed |
|---|---|---|---|
| Zero-setup trust for a person's own agents in their own area | `open` policy | Policy derived from "one settler over one area", no configuration step | Stage 0 |
| Write echo | Nothing enforces it | Skill requirement: every write is followed by one line the person can correct | Stage 0 |
| Agent identity on every write | `agent_identities`, action log | Direct-SQL agents rarely set one; make it part of the session contract | Stage 1 |
| Cross-agent dedup of suggestions | Per-agent idempotency keys, artifact content hash | Dedup on source item reference across agents | Stage 1 |
| Questions owed to a person | `review_queue`, `open_gaps` | A read that returns the confirmations and gaps a given person can settle, ranked, so any of their agents can ask | Stage 1 |
| Speech-act classification | `speech_acts` on authorities | Agent procedure and skill guidance; a claim-type convention per speech act | Stage 2 |
| Reporting and ownership edges | `owner_node_id` on knowledge domains only | Two edge conventions, settled by the area owner | Stage 2 |
| Authority routing | `domain_authorities`, advisory, read only by the context pack | One function running the lookup: authority row, then relationship, then area owner | Stage 2 |
| Objections | Competing candidates on the same tuple | An objection to an accepted fact as a first-class record that routes by its reason | Stage 2 |
| Authorizer and executor kept distinct | Free-form actor and evidence | A convention with two named fields in evidence properties | Stage 2 |
| Topical grants in plain language | `grant_domain_authority()` | Agent guidance: "Priya decides pricing" writes one row; no setup form | Stage 2 |
| Enforced settling | Nothing in the write path checks authority | Call the lookup from the acceptance path, for callers that come through the API | Stage 3 |
| Source identity binding | Glossary names it as a confirmed step | A helper that records the binding with evidence, and a rule that unbound speakers never settle | Stage 3 |
| In-thread echo for channel agents | Nothing | Skill requirement for channel runtimes | Stage 3 |
| Narrow auto-accept for bound self-commitments | Proposed rule engine | Shrink the proposal to this one case | Stage 3 |
| Objectives as convention | Nothing | `objective` node type, `advances`, `blocks`, `risks`, `subgoal_of` edges, state in assertions | Stage 4 |
| Importance over salience | `node_salience` | A predicate first, then a score: linked to an active objective, deadline near, or contradicts an accepted fact | Stage 4 |
| Asking preferences | Nothing | No fixed cap or clock. A person's "ask me less" or "if I'm silent, ask Priya" is a preference they settle themselves, stored as an assertion so all their agents respect it | Stage 2 |
| Parked suggestions | Candidates persist | A visible parked state with decay | Stage 4 |
| Cross-area answers under visibility | RLS, classification | Agent behavior that names who to ask when it cannot show a fact | Stage 4 |

## What the person never sees

These words stay in the schema, the API, the audit log, and the admin
surface. They never appear in what an agent says to a person who is not
a Rye admin.

- scope, policy, `open`, `candidates_only`, `strict`
- candidate, accepted, superseded, basis, `reported`, `inferred`, `observed`
- token, capability, grant, identity
- node, edge, assertion, event, artifact
- review queue

The glossary already maps each of these to a plain term. The rule here is
stronger than the glossary: at stages 0 through 3, even the plain terms
should rarely be needed, because the agent asks a question instead of
explaining a state. "Should I record that?" does the work of "this is a
candidate pending review."

The Rye admin is the exception. They see the mechanism. Even so, their
setup conversation should be in business terms: who decides what, which
places to watch, who is on the team. The agent translates.

## Objectives and importance, briefly

The earlier critique established that `node_salience` measures activity,
not importance, and that nothing in the graph represents what a person is
trying to achieve. That holds, and at Stage 4 it becomes the limiting
factor. This document keeps the earlier recommendation with two changes.

First, start with a predicate, not a formula. A suggestion is important if
it is linked to an active objective with a deadline inside a window, or
if it contradicts an accepted fact that is linked to one. Rank by that.
Add a weighted score only when there is enough history to check it
against.

Second, importance decides attention, never truth or permission. An
important suggestion gets to a person sooner. It does not get accepted
more easily. If anything, it deserves more evidence.

One open question the earlier session did not address: the PM profile
already has `project`. Before the objective convention is written, the
difference must be stated in one sentence, or both will be used for the
same thing. A working answer: a project is a container of work with a
lifecycle in a domain table; an objective is a desired state of the world
that lives only in the graph and that projects, tasks, and facts can point
at.

## Decided

- 2026-09-19, Casey: the authority model is the five relationship
  defaults composed with `domain_authorities` as the exceptions and
  topical-grants mechanism, in the three-step lookup above. Objections to
  accepted facts are first-class records.

- 2026-09-19, Casey: this is v0.4. The v0.3 brief is unchanged.
- 2026-09-19, Casey: a lone person settles everything in their own area
  with no setup.
- 2026-09-19, Casey: an unbound channel identity settles nothing, unless
  it has been specifically authorized. The authorization is an authority
  row naming that source identity, granted by a bound settler, with an end
  date.
- 2026-09-19, Casey: an outsider's statement is only ever accepted as
  "they said it", authorized by an internal owner.
- 2026-09-19, Casey: a person's agent neither spies nor hides. It does not
  report on its person unprompted. Absence of records is visible to a
  manager who asks. This is stated openly to the people using it.
- 2026-09-19, Casey: a project is a container of work with a row in a
  domain table. An objective is a desired state that lives only in the
  graph.
- 2026-09-19, Casey: enforcement of the lookup applies to callers that
  come through the API. Direct database users are trusted by
  construction.
- 2026-09-19, Casey: no hard values for how long a settler may stay silent
  or how many questions an agent may ask. Both follow importance, and a
  person adjusts them in plain words.
- 2026-09-19, Casey: the reporting and ownership conventions live in the
  `rye-org` plugin as `reports_to` and `owns`.

## Assumptions taken by default

- Delivery of a question to a person is the agent runtime's job. Rye
  computes who owes what; it does not send messages.
- One person may use several agents and any of them may ask the questions
  that person owes.
- The existing `review_queue` remains the durable backing; no new queue
  table.
- The three-step lookup is the only source of "who may settle". No
  parallel mechanism in skills or prompts.
- The area owner settles reporting lines and ownership.
- v0.4 covers stages 0 through 2. Stages 3 and 4 (channel agents,
  identity binding, objectives, importance) come after. Overturn: Casey.
- Until objectives exist, "what it blocks becomes important" reduces to
  "someone else is now asking about the same thing". Overturn: Architect.

## Proposed order of work

1. Write echo and zero-setup trust for Stage 0. Skill changes only.
2. Questions-owed read and cross-agent dedup for Stage 1. One migration,
   read-only view plus a dedup convention.
3. Reporting and ownership edge conventions, the three-step lookup,
   objections, speech-act guidance, and the authorizer/executor evidence
   convention for Stage 2. Two conventions, one function, one skill
   section.
4. Source identity binding and in-thread echo for Stage 3. One helper,
   one skill requirement. Shrink the rule-engine proposal at the same
   time.
5. Objectives, importance predicate, parked state for
   Stage 4. Conventions first, one view, then measure before scoring.

Each step is checkable by a person with no access to the code: they hold
a conversation with an agent and see whether the contract at the top of
this document held.
