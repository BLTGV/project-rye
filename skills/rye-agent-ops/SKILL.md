---
name: rye-agent-ops
description: Operate Rye data safely for LLM agents. Use when implementing or executing agent read/write flows, connecting domain tables, selecting assertion keys, enforcing provenance, and applying agent-safe SQL patterns for context retrieval and auditable writes.
---

# Rye Agent Ops

## Session Setup (Required)

Before any query, set the session context. On stateless connections (Supabase MCP, serverless, transaction-mode poolers), this must be done in **every call**:

```sql
SELECT set_config('app.current_role', 'agent:sales-intake', false);
SELECT set_config('app.current_user_id', 'user-123', false);
SELECT set_config('app.current_teams', 'engineering', false);
```

State your own role, `agent:<your key>`, and state it before every write. A
session with no role set, and a session set to `viewer`, can read and can write
nothing: every insert, update, and delete on nodes, edges, events, participants,
assertions, evidence, artifacts, and source mappings is refused, through a
helper exactly as by hand. `admin` is a person's role, not yours. Use
`set_config()` (not `SET` syntax) for portability.

## Orient

1. Run `SELECT rye_catalog()` to see what's in the instance — node types, edge types, assertion types, tracked tables, and totals.
2. Find the subject with `find_nodes(query, node_types)`, or send several
   phrasings in one round trip with `find_nodes_batch(queries, node_types)`
   and judge the candidates on `score` and `match_reason` yourself. Semantic
   matching is your job, not the database's; expect to search more than once.
   Property values are never searched, by design: redaction applies to them,
   so matching one would confirm a redacted field to someone who may not read
   it. Search labels and external identity.
3. Walk from there with `find_paths()` and `neighborhood()`. For cause pass
   `p_semantics => ARRAY['causal']`, or an `associative` edge comes back as a
   path and co-occurrence reads as cause.
4. An empty result may mean not visible to you rather than absent. Do not
   report it as "there is none".
5. Use `agent_node_summary(node_id, max_items)` for compact context on a specific node.
6. Run the category discovery below before proposing any node.

## Discover Categories Before You Write

Before proposing any node, ask the database what kinds of things it already
holds. Procedure ships with the skill; vocabulary lives in the graph. The
reply's shape is `contracts/category-vocabulary.md`.

```bash
./scripts/rye categories --scope <uuid-or-key> --json
```

Over SQL or the API this is `rye_categories(p_scope_id)`; omit the argument to
read unscoped. For each entry in `categories`:

- `name` — the node type. Reuse an existing name over a near-synonym.
- `description` — what the type means in this organization's words, or `null`
  when nobody has said. Do not substitute your own reading for `null`.
- `properties.observed` — `[{key, count, frequency}]` present on non-archived
  nodes of the type. Shape your proposal to these keys; low `frequency` means
  optional in practice. `properties.required` is `[]` in v0.3
  (`required_source` `"none"`); honor it if it is ever non-empty.
- `relationships.as_source` / `.as_target` — `[{edge_type, other_types,
  count}]`. Prefer an edge type already used between these types.
- `enabled` — `on`, `off`, or `unscoped`. Treat `off` as not writable here:
  `validate_candidate_against_scope()` refuses it and names the policy that
  blocked it. Off categories are listed, not omitted, so absence never means
  disabled.

At the top level: `empty` `true` means no categories yet — do not invent a
type; raise it as an open question for a person, or record a `knowledge_gap`.
`scope.scope_found` `false` means the scope you named did not resolve, so the
empty reply says nothing about the graph. `scope.type_policy` `missing` means
the scope has no current `allowed_node_types` claim, so every category reads
`off`.

Never create a category. A new node type is a person's decision: propose it and
say why the existing ones do not fit. "Category" is the business sense, what
kind of thing this is; it is not `classification`, which is who may see it.
Ignore reply keys you do not recognize — the shape is additive.

## Ask Who May Settle It Before You Accept

Before you record any statement as accepted, ask who may settle that claim.
One lookup answers it, and every agent gets the same answer: a recorded grant
for that kind of claim, then the relationship (the person themselves, their
manager, the owner of the thing), then the owner of the area. The reply's
shape is the settlement lookup section of `contracts/sql-surface.md`.

```bash
./scripts/rye settlers --subject <uuid> --claim <assertion-type> \
  --speaker <uuid> --speech-act <act> --domain <key> --json
```

Over SQL or the API this is `rye_settlers(p_subject_id, p_claim_type,
p_speaker_id, p_speaker_ref, p_domain_key, p_speech_act, p_as_of,
p_scope_ref)`. Pass `--speaker-ref <source-identity>` instead of `--speaker`
when the speaker is a channel account with no person node. Pass `--as-of` to
reconstruct a past answer.

Always pass both `--claim` and `--speech-act`. They are two different
selectors and the answer depends on both.

`p_claim_type` is the claim's `assertion_type` verbatim. Two sets of claim
types carry meaning of their own, both tested on the **canonical** type, after
alias resolution:

- **Other-set**, a claim one person sets on another. The core set is
  `expectation`.
- **Self-set**, a claim a person settles about themselves. The core set is
  `commitment`, `self_commitment`, `self_report`, plus any type declared as
  self-settled in this instance.

`p_speech_act` is your classification of what was said. The recognized values
are `self_commitment`, `self_report`, `expectation`, `statement_about_other`,
`statement_about_thing`, `agreement`, `decision`, `outside_report`, and
`agent_inference`.

**The kind of claim decides first, and the speech act second.** An expectation
is set on a person by someone else, so it is always the manager's call and the
person it is set on is never returned as its settler — whatever speech act you
pass, and whether you pass one at all. Saying less never widens the answer: a
missing or unrecognized speech act selects no relationship default and falls
through to the owner of the area.

**The subject is returned only when the claim type is positively in the self
set.** No speech act makes a person their own settler on its own. Pass
`self_commitment` on a type nobody has declared self-settled and the answer is
nobody local, not the speaker. Unknown is restrictive, and so is blindness: if
you cannot see the alias or the declaration, you get the stricter answer, never
a wider one. Matching is case-sensitive and case is not folded — `Expectation`
with no alias registered is a different type in neither set.

### Prefer a declared type over one you invent

Run the category discovery request before you choose a claim type and reuse a
type it lists. A type you invent, or a known one spelled your way, is in
neither set, so a claim about the speaker routes to the owner of the area
instead of settling on their word. For a lone person that owner is themselves
and it costs nothing. On a team it costs one question.

If a person tells you the type they want is their own call to make, that is a
change to how Rye is set up here, and only a Rye admin settles it. Record what
they said, never assume it. See "How Rye is set up here is an admin's call"
below.

`speech_act_recognized` is false when you passed a value outside the
recognized set. **Do not record anything as accepted while it is false.**
Classify the statement again, pass a recognized speech act, and look again.
That is your mistake to correct. Never mention it to the person.

Read three fields and act on them:

| Field | Act on it |
|---|---|
| `speaker.is_settler` | `true`: run the check below, then ask for accepted and read back what landed. `false`: record a suggestion. |
| `settlers` | Who to check with. `step` says which of `grant`, `relationship`, `area_owner` produced them. |
| `step` = `none` | Nobody settles it here. `reason` says why; `setup_gap` `true` is a gap for a Rye admin, and `reason` says which. |

The lookup is advisory. It writes nothing, refuses nothing, and no write path
calls it. It is your discipline, not a wall the database holds.

### Asking for accepted is not landing accepted

The area's review policy has the last word, and the lookup knows nothing about
it. Where the area is set so that agents suggest and people accept, your
`record_assertion(..., p_status := 'accepted')` lands a suggestion instead, and
so does `supersede_assertion()` — which then leaves the standing statement
exactly where it was, accepted and unreplaced. Neither raises. Both return the
new id either way, so the id tells you nothing. Read the row back before you
say anything:

```sql
SELECT status, attrs ? 'review_gate' AS waiting_for_review
FROM assertions
WHERE id = '<returned_id>'::uuid;
```

`status` `candidate`, or `waiting_for_review` `true`, means a person has to
accept it before it answers anything. Say so in the waiting words under "What a
person hears" and never say it is done. Nothing said is lost: it is in the
review queue, and a settler accepting it there replaces the standing statement
then.

Ask for accepted anyway when the lookup says the speaker settles it. Asking is
what records that they meant it to take effect. Do not lower the status
yourself, and do not try a second route when it lands as a suggestion.

### What the lookup does not tell you

It reads no assertion. It answers who may settle a claim; it does not answer
who may unsettle one. So it cannot tell a new statement from a contradiction
of a standing one, and `is_settler` `true` is not permission to replace
something you never looked for.

The gap has one shape. A person restates or contradicts something already
accepted about themselves, of a self-set type, that somebody else authorized —
a quota their manager set, say. For that claim type they genuinely are a
settler, so the lookup returns them as one, and nothing in the answer mentions
the standing claim.

So before you accept anything on `is_settler` `true`, read
`current_valid_assertions` for an accepted row on the same subject, assertion
type, and assertion key, and read its evidence `attrs.authorizer`:

Compare canonical types on both sides, never raw strings. Rye resolves
synonyms through type aliases, so a standing `expectation` and a new
`requirement` can be the same claim:

```sql
SELECT a.id, e.attrs->>'authorizer' AS authorizer
FROM current_valid_assertions a
LEFT JOIN assertion_evidence e ON e.assertion_id = a.id
WHERE a.subject_node_id = '<subject_uuid>'::uuid
  AND canonical_type('assertion_type', a.assertion_type)
    = canonical_type('assertion_type', '<claim_type>')
  AND a.assertion_key = '<key>';
```

Raw equality misses it. `canonical_type('assertion_type', ...)` follows the
alias chain on both the type you are about to write and the type of every
standing row.

Write the canonical type the lookup reports, not the synonym you were given.
Rye reports the drift; it does not rewrite your insert, so a row written under
an alias keeps that spelling forever and every later reader pays for it.

Type names are case-sensitive. `Expectation` is not `expectation` unless an
alias says so. Use the type exactly as the category discovery request lists
it.

The guard fails closed. One recorded authorizer lets a write through, and it
is the speaker's own:

| What stands | What you do |
|---|---|
| No accepted row | Accept, as below. Nothing is being replaced. |
| A row whose `authorizer` **is the speaker** | Accept. The person is correcting their own earlier words. One line back and you are done. |
| A row whose `authorizer` is **somebody else** | Record a suggestion. Tell the person whose call it is. |
| A row with **no `authorizer` recorded** | Record a suggestion. Do not guess whose call it is. |

The last row is the one to get right. Rows written before the
authorizer/executor convention carry nothing, and an unrecorded authorizer is
not an absent one. Do not read a missing field as permission, and do not
decide for yourself who put the claim there. Run the lookup for that claim and
check with a settler it returns other than the speaker; if it returns no other
settler, check with the owner of the area. Tell the person plainly that you
want to confirm with that person before changing something already on record.

Never accept and never supersede a standing claim on a missing field. Accepted
stays accepted until a settler changes it.

**A cleared guard is not a completed replacement.** The two rows above that say
"Accept" mean you may ask; they do not promise the standing statement was
replaced. Under a review policy that turns your write into a suggestion, both
`record_assertion()` and `supersede_assertion()` file one and leave the standing
statement accepted. Read the returned row's `status` and `attrs.review_gate`, as
in "Asking for accepted is not landing accepted" above, and tell the person it
is waiting rather than that their correction is in.

Routing that objection onward is a later work item. This is only the guard
that keeps a standing claim from being overwritten.

### The speaker is a settler

Record the claim as accepted through `record_assertion(...)`. Keep the person
and the agent distinct in the evidence: the person is the authorizer, you are
the executor, and the utterance is the source event.

```sql
SELECT record_assertion(
    p_assertion_type := 'expectation',
    p_claim          := '{"value": "log sales calls in the CRM"}'::jsonb,
    p_subject_node_id := '<subject_uuid>'::uuid,
    p_assertion_key  := 'sales_call_logging',
    p_status         := 'accepted',
    p_basis          := 'reported',
    p_evidence       := ARRAY[jsonb_build_object(
        'kind', 'source',
        'event_id', '<utterance_event_uuid>',
        'witness_node_id', '<speaker_uuid>',
        'attrs', jsonb_build_object(
            'authorizer', '<speaker_uuid>',
            'executor', '<agent_key>',
            'settled_via', 'relationship',
            'settled_relationship', 'manager'
        )
    )]
);
```

Then say one line back, in the person's own words, so they can correct it on
the spot. See the echo rules under "What a person hears" below.

### The speaker is not a settler

Record the same claim as a suggestion — `p_status := 'candidate'` — on the
same subject, type, and key, with the speaker's words as its backing and the
settlers from the lookup in `p_attrs`. Nothing is refused and nothing is
dropped.

When the suggestion contradicts a claim that is already accepted, keep the
accepted one exactly as it is and record the id of the claim being objected
to in the suggestion's `p_attrs`, with the speaker's reason. Do not supersede,
end, or archive the accepted claim. Then ask the person one question: why.
The reason is what a settler needs to answer.

Then tell the person whose call it is and that you will check with them. Name
the settler. Do not tell them they lack authority and do not name a status.

### An undeclared claim type about the speaker

A person says something about themselves under a claim type nobody has
declared self-settled. The lookup does not return them; `via` is `area_owner`
and the settler is the owner of the area. Handle it exactly as any other
statement the speaker cannot settle: record the suggestion and say you will
check with the owner.

"I've got that down. It's Priya's call, so I'll check with her and let you
know."

Say nothing about types, registries, declarations, or why the answer came out
that way. The person said something ordinary about themselves; the reason it
routed is yours to carry. Do not apologize for it and do not reach for a
different type to make it settle — that is relabelling, and it is forbidden
below.

### How Rye is set up here is an admin's call

A few records are not knowledge about the world. They are **how Rye is set up
here**, and Rye reads them to decide how it treats every other write:

| What it is, in plain words | The record | What reads it |
|---|---|---|
| One word means another | `registry_entry`, key `type_alias:<kind>:<from>` | `canonical_type()` |
| A kind of thing is each person's own call | `registry_entry`, key `self_settled_type:<type>` | `rye_settlers()` |
| Anything else on the registry: default scope, governed types, basis priors, half lives, digest facets | `registry_entry` | `registry_value()` |
| Whether a write lands accepted at all | `review_policy` | `record_assertion()` |

Only a Rye admin settles these. Which types are gated is data, not code, so
ask before you offer to record one:

```sql
SELECT settle_gate('registry_entry');
```

```bash
./scripts/rye settle-gate registry_entry --json
```

The answer is `{assertion_type, gated, allowed_roles, current_role,
may_settle}`. The CLI opens its own session and sets no role, so read `gated`
and `allowed_roles` from it and read `may_settle` in the session you will
write from. It writes nothing and refuses nothing. `gated` `false` means the
type is ordinary knowledge and the settlement lookup alone decides it.
`may_settle` `false` means what you are about to record will land as a
suggestion waiting for a Rye admin — tell the person that before you write it,
not after. The normative shape is "Configuration writes need an admin" in
`contracts/sql-surface.md`.

This gate sits on top of the settlement lookup rather than replacing it. A
statement can clear the lookup and still be an admin's to settle: an area owner
who is not a Rye admin may settle claims all day and still cannot declare a
self-settled type.

### Declaring a type a person's own call

The self set grows as data. Someone says in plain words that a kind of thing is
each person's own call — "people decide their own availability" — and that
becomes one registry entry. Someone saying that two words mean the same thing —
"a requirement is an expectation here" — becomes a `type_alias` entry the same
way, and is gated the same way.

Rye has no dedicated registry-writing helper. Write it with
`record_assertion()` on the registry or scope node, the same shape `type_alias`
entries use, and never by touching a base table:

```sql
SELECT record_assertion(
    p_assertion_type  := 'registry_entry',
    p_assertion_key   := 'self_settled_type:availability',
    p_subject_node_id := '<registry_or_scope_node_uuid>'::uuid,
    p_claim           := '{"value": true}'::jsonb,
    p_status          := 'accepted',
    p_basis           := 'reported',
    p_evidence        := ARRAY[jsonb_build_object(
        'kind', 'source',
        'event_id', '<utterance_event_uuid>',
        'witness_node_id', '<speaker_uuid>',
        'attrs', jsonb_build_object('authorizer', '<speaker_uuid>',
                                    'executor', '<agent_key>')
    )]
);
```

**One alias can never be recorded, by anyone.** An alias pointing *from* a type
that is part of how Rye is set up here — a `registry_entry` keyed
`type_alias:assertion_type:<T>` where `<T>` is a gated type (`registry_entry`,
`review_policy`, `scope_status` today) — is refused for every caller at every
status, a Rye admin included. Renaming one of those words would turn the gate
off for everything written afterwards. An alias pointing *into* a gated type is
ordinary and still allowed. If a person asks for that rename, do not file it as
a suggestion: say it cannot be done, in their words — that word is how Rye
decides what counts here, so it cannot be renamed — and offer the other
direction if it helps.

The key carries the **canonical** type. An alias is registered as an alias,
never as a second self-settled entry. Any value but `true` is not a member.
`registry_value()` reads it back, scope first, then plugin, then core. The
core members need no entry, so a fresh instance settles a plain commitment with
nothing configured.

Write exactly that, with `p_status := 'accepted'`, in both cases below. Asking
for accepted is what records that the speaker meant it to take effect. Do not
lower the status yourself, and do not decide from the person's job title — read
`may_settle` from `settle_gate('registry_entry')`.

**The speaker is a Rye admin** — `may_settle` `true`. It lands accepted. Echo
one line in their words and stop:

> "Got it — people set their own availability."

Never read the key back to them.

**The speaker is anyone else** — `may_settle` `false`. The same call lands as a
suggestion carrying `attrs.settle_gate`, a Rye admin sees it in the review
queue with everything else, and nothing said is lost. Then say so plainly:

> "I've noted that. A Rye admin needs to confirm it before it takes effect —
> I'll pass it on."

Never tell them they lack permission, never name a status, a key, a type, or
the registry. They said something ordinary about how the team works; the
routing is yours to carry.

**One route, and only once.** `record_assertion()` is the only way you ever
record how Rye is set up here, and a suggestion is the end of the attempt, not
the start of a workaround. Every other route raises, and trying one is a worse
answer than the suggestion you already have:

- No `INSERT INTO assertions` and no `UPDATE` of one, whatever you set
  `app.write_path` to.
- No `accept_assertion()`, `supersede_assertion()`, `record_distillation()`,
  or `schedule_assertion_change()` on a gated type. These refuse instead of
  demoting, on purpose: each marks or displaces the standing entry first, so a
  quiet demotion would leave the key with no accepted value and a proposal
  would erase an alias.
- No second identity, no more permissive agent asked to write it for you, and
  no `rye.authoritative.promote` — that grant does not open this gate.
- Do not set `app.current_role` to `admin`. The role you present is the
  person's, not a setting you choose.

That refusal is this gate and no other. On ordinary knowledge
`supersede_assertion()` does not raise under a review policy that would demote
your write: it files the replacement as a suggestion, leaves the standing
statement accepted, and hands back the new id all the same. Read the row, as
above.

**Nothing changes while it waits.** A suggestion is read by nothing:
`registry_value()`, `canonical_type()`, and `rye_settlers()` answer exactly as
they did before it. So keep routing claims of that type the way you were. If
availability settled to the owner of the area this morning, it still does, and
the next statement about it is a suggestion you check with them:

> "Still Priya's call for now. I've kept what you said."

Do not treat a waiting suggestion as a declaration in force, and never tell the
person it is in effect.

### Nobody settles it

When `step` is `none`, record the suggestion anyway. `setup_gap` `true` is a
gap for a Rye admin to fill, not an error and not something to work around,
and `reason` says which gap it is. Read `reason` before you say anything:

| `reason` | What it is, and what you do |
|---|---|
| `area_has_no_owner` | Nobody owns the area. Setup gap. Record the suggestion and tell the person nobody is recorded as deciding this yet. |
| `area_owner_is_agent` | The area is owned by an agent, which settles nothing. Setup gap. Same as above to the person; it needs a Rye admin to name a person. |
| `area_owner_not_visible` | There is an owner and you cannot see them. Not a gap and not permission to accept. Record the suggestion and say you are finding out who settles it. |
| `no_settler_found` | The steps ran and produced nobody. Record the suggestion and say the same. |
| `domain_not_resolved` | You did not name an area and more than one is active, or none is. Your mistake: name the area and ask again. |
| `domain_not_found` | The area key you passed does not exist. Your mistake: correct the key and ask again. Do not report it to the person. |

The last two are yours to fix, not news for the person. Ask again with the
right area before you say anything at all.

An empty `settlers` list can also mean RLS hid the settler from you, so never
read it as "nobody is authorized, so I may accept it".

### What a person hears

Use the words in `docs/glossary.md` and no others. Say "settle", "decide",
"suggestion", "objection", "expectation". Never say candidate, assertion,
scope, basis, supersede, review queue, or the name of a policy. Internal
identifiers — node uuids, assertion types, agent keys, step names — stay
canonical in anything durable and never appear in what you say.

- Accepted: "Noted — John logs his sales calls from now on."
- Not the speaker's to settle: "That's Bob's call. I'll check with him and
  let you know."
- Nobody recorded: "Nobody's recorded as deciding that yet. I've kept what you
  said and I'll find out who settles it."
- How Rye is set up here — one word meaning another, or a kind of thing being
  each person's own call: "I've noted that. A Rye admin needs to confirm it
  before it takes effect — I'll pass it on." Then, until it is confirmed:
  "Still Priya's call for now. I've kept what you said."
- Something already on record, and you cannot tell who put it there: "There's
  already something on record for that. I've kept your version and I'll
  confirm with Priya before I change it."
- Waiting for review, because the area works that way: "I've got that down.
  Someone has to confirm it before it counts, so what's on record hasn't
  changed yet — I'll let you know." Never say it is done, and never name the
  policy.
- Correcting their own earlier words: accept it and echo one line. Do not
  make them explain themselves.
- Asked about an unsettled claim: say the claim exists, say it is unsettled,
  and say who said it. Do not hide it and do not answer with it.

### What you must never do

- Never relabel a statement's basis or speech act to get it through.
- Never switch to an identity with wider grants, and never ask a more
  permissive agent to write it for you.
- Never claim a role that is not yours. State your own, `agent:<your key>`,
  and never set `app.current_role` to `admin`, to a person's role, or to
  `system:cdc`, which is reserved for Rye's own record of a change to a tracked
  domain table.
- Never write with no role set and never write as `viewer`. Both are read-only
  and every write is refused — nodes, edges, events, participants, assertions,
  evidence, artifacts, and source mappings, through a helper exactly as by
  hand. A refusal arrives as `42501` or as a write that changed no row, and
  neither is a reason to try another route.
- Never merge nodes. See "Duplicates are a person's call" below.
- Never treat your own inference as a settled claim. You carry the authority
  of the person you act for and none of your own; no lookup ever returns an
  agent as a settler.
- Never accept a claim on silence. A settler who has not answered has not
  agreed, and there is no clock that turns silence into a yes.
- Never overwrite an accepted claim with a later statement from someone who
  cannot settle it. Accepted stays accepted until a settler changes it.

`reports_to` and `owns` are the relationships the lookup reads, declared by
the `rye-org` plugin and pinned in `contracts/plugin-manifest.md`:
`reports_to` runs from the report to the manager, `owns` from the owner to
the thing owned. Neither is settled by the people it connects — a claim about
either falls through to the owner of the area. Propose them; never settle
them. End one with `effective_to`, never by deleting the edge.

## Duplicates Are a Person's Call

You may not merge nodes. `merge_nodes()` refuses every agent-shaped session with
`42501` and names who can: a Rye admin or a team member. A merge is
irreversible, it moves one subject's history onto another, and it crosses review
policies, so it is not yours to run. Do not retry it under another role.

When two records look like the same thing, record what you saw and hand it to
your person. Write it as a structural proposal with
`create_knowledge_candidate(...)`. The kind is `decision` — `duplicate_node` is
not a candidate kind and raises:

```sql
SELECT create_knowledge_candidate(
    p_candidate_kind  := 'decision',
    p_statement       := 'Possible duplicate: two records look like the same supplier',
    p_target_payload  := jsonb_build_object(
        'action', 'merge_nodes',
        'duplicate_id', '<duplicate_uuid>'::uuid,
        'canonical_id', '<canonical_uuid>'::uuid,
        'supporting_evidence', 'Same legal name and the same two contacts.',
        'conflicts', 'Different mailing addresses.'
    ),
    p_source_node_ids := ARRAY['<duplicate_uuid>', '<canonical_uuid>']::uuid[],
    p_created_by      := '<agent_key>'
);
```

Then say one line:

> "I think that supplier is in here twice. Want me to flag it for someone to
> merge?"

Say nothing about functions, roles, or refusals. `skills/rye-gardener` is the
procedure for preparing a merge proposal for review.

## Why Rye Uses SQL Helpers

Rye's durable contract lives in PostgreSQL because the database is the shared
boundary used by humans, agents, admin UI, plugins, and import tools. Agents
should not reimplement assertion lifecycle rules in prompts or application
code. Use Rye SQL helper functions because they enforce the same behavior for
every caller:

- RLS and team/classification boundaries
- append-only events
- immutable assertion content
- candidate review and supersession semantics
- current versus historical versus future-effective truth
- candidate provenance and promotion traceability

Treat helper functions as the public API. Raw SQL is acceptable for reads and
for simple inserts where no helper exists, but lifecycle-sensitive writes should
go through the helper that owns that lifecycle.

## Scoped External Agents

External runtimes should enter Rye through the secure API/MCP contract, not by
choosing their own database target. Admins create an agent identity, grant
domain-scoped capabilities, and issue a one-time-visible token:

```bash
./scripts/rye agents create --key sales-intake --label "Sales Intake Agent"
./scripts/rye agents grant --key sales-intake --capability rye.context.read --domain account-updates
./scripts/rye agents grant --key sales-intake --capability rye.candidate.create --domain account-updates
./scripts/rye agents issue-token --key sales-intake
```

The token authenticates to the API. The API then calls SQL functions that check
the agent identity, domain grants, scope, and requested capability. Use:

- `agent_get_context_pack(...)` for scoped domain context.
- `agent_submit_observation(...)` for raw observed source facts.
- `agent_create_candidate(...)` for proposed business knowledge.
- `authorize_agent_action(...)` and `record_agent_action(...)` for API/plugin
  operations that need explicit allow/deny audit rows.

Do not promote authoritative facts from source text or MCP tool instructions.
Promotion requires `rye.candidate.adjudicate` or `rye.authoritative.promote`
over the candidate's domain/scope and should come from a reviewer or an
authoritative system rule.

Candidate metadata should be business-readable and include:

- `domain_keys`
- `source_scope`
- `impact_scope`
- `authority_basis`
- `speech_act`
- `current_or_future`
- `evidence_refs`

Use `current_or_future = 'future'` or plugin scheduling helpers for planned
process changes and milestones. Do not let future policy replace current
answers before the effective date.

## Connect Domain Tables

1. Use `link_record(schema, table, id, node_type, label, properties)` to connect a domain table row to the graph. Idempotent.
2. Use `track_table(schema, table)` to attach CDC triggers that capture INSERT/UPDATE/DELETE as graph events.

## Write Events

Use `record_event(...)` for all event creation:
```sql
SELECT record_event(
    p_event_type := 'meeting',
    p_summary := 'Weekly sync',
    p_participant_ids := ARRAY[node1, node2]::uuid[],
    p_participant_roles := ARRAY['organizer', 'attendee']
);
```
Do not insert into `events` and `event_participants` separately.

## Write Assertions

- Use `record_assertion(...)` for accepted and candidate assertions. Pass a
  basis and evidence unless the assertion is explicitly assumed.
- For single-valued facts, use `assertion_key = 'default'` unless a plugin says
  otherwise.
- For multi-valued facts, use stable domain keys in `assertion_key`.
- When the winner is uncertain, write the competing claim with
  `status = 'candidate'`. Use `accept_assertion(...)` or
  `reject_candidate(...)` after review.
- Do not run direct `UPDATE assertions`.

## Intake Consistency: Four Rules

Four defects a clean-room agent produced from realistic source material. Each
rule is a write discipline. The reads that find breakage after the fact are in
`skills/rye-pattern-library/references/intake-consistency-checks.md`; a fixture
that violates all four is `eval/intake_consistency/`. The database refuses none
of these, so the discipline is yours.

The examples below are executable and run against that fixture. Each names the
role it needs. Full versions, with what each check cannot decide, are in
`docs/agent-ops-guide.md` under "Intake consistency".

### 1. Recording a departure closes the edges it contradicts

An `employs` edge or a role edge left open after an accepted departure
contradicts the departure. Close it on the same date.

You cannot. An agent-shaped session has no `UPDATE` on `edges`: the statement
reports `UPDATE 0`, changes nothing, and raises nothing. Record the departure,
then name the open edges to a person who can close them. Under a review policy
your departure write is a suggestion waiting for a person, so say that too.

Two things decide whether a repair is possible at all. **Get the date**: the
repair closes each edge on the departure's `effective_at`, so a departure with
no date is reported forever and nothing can clear it — ask the person for a
last day before recording it. **Close and handoff are different**: membership
and assignment end when the person leaves, but closing an `owns` or
`responsible_for` edge leaves the thing unowned. Those need a successor named
by a person. The list below is the `close` set, derived from
`plugins/*/rye-plugin.json`.

```sql
-- As team_member, not as an agent.
SELECT set_config('app.current_role', 'team_member', false);

UPDATE edges e
SET effective_to = d.departed_at
FROM (
    SELECT a.subject_node_id AS person_id,
           a.effective_at    AS departed_at
    FROM current_valid_assertions a
    WHERE a.assertion_type = 'employment_status'
      AND a.claim->>'status' = 'departed'
      AND a.effective_at IS NOT NULL
) d
WHERE (e.source_id = d.person_id OR e.target_id = d.person_id)
  AND e.edge_type IN ('employs', 'affiliated_with', 'reports_to', 'member_of',
                      'assigned_to', 'project_member', 'sprint_member',
                      'pipeline_member', 'territory_member',
                      'primary_contact', 'secondary_contact')
  AND e.archived_at IS NULL
  AND e.effective_to IS NULL;
```

Edges end with `effective_to`. Never delete one.

### 2. A digest asserts nothing its sources do not establish

Every key in a digest claim comes from a source assertion the digest cites. If
the material supports a detail that no accepted assertion states, record the
assertion first, then distil. Do not carry the detail into the digest alone.

```sql
-- As an agent. Both claim keys are established by the two cited sources.
SELECT set_config('app.current_role', 'agent:intake-fixture', false);

SELECT record_distillation(
    p_subject_node_id := (SELECT id FROM nodes WHERE label = 'Line 3 Retool'),
    p_subject_edge_id := NULL,
    p_assertion_key := 'status',
    p_claim := '{"status":"blocked","blocked_on":"gearbox",
                 "message_count":214,"peak_hour_utc":10}'::jsonb,
    p_source_assertion_ids := ARRAY(
        SELECT a.id FROM current_valid_assertions a
        WHERE a.subject_node_id = (SELECT id FROM nodes WHERE label = 'Line 3 Retool')
          AND a.assertion_type IN ('task_status', 'message_volume')
    ),
    p_source_event_ids := '{}'::uuid[],
    p_status := 'accepted',
    p_agent := 'agent:intake-fixture',
    p_attrs := '{"source_window":{"from":"2026-09-01T00:00:00Z",
                                  "to":"2026-09-30T00:00:00Z"}}'::jsonb
);
```

Under a review policy this lands as a suggestion carrying `attrs.review_gate`,
and the accepted digest stays current until a person accepts the new one. Read
`status` from the returned id rather than assuming.

### 3. An effective date and an edge window tell one story

A claim about a relationship takes its `effective_at` from the edge it is
about. Point it at the edge: `subject_edge_id`, or `attrs.edge_id` when the
subject has to be a node. A relationship claim naming no edge checks against
nothing.

Correcting one already recorded depends on what the incumbent is now.

- **Against an accepted assertion**, a date-only or attrs-only correction
  through `record_assertion()` writes nothing: when claim, basis and confidence
  match, it appends your evidence, returns the incumbent's id and inserts no
  row. Use `supersede_assertion()`.
- **Against your own suggestion** — what a demoting review policy leaves you —
  `supersede_assertion()` raises `Only accepted assertions may be superseded;
  reject candidates instead`, and `record_assertion()` with a different date
  writes a *second* suggestion instead of replacing the first. Close the wrong
  one with `reject_candidate()` and file the corrected one.

An agent may call `reject_candidate()`: verified as `agent:<key>` on a full
install, it closed the agent's own suggestion. Rejecting your own suggestion is
housekeeping. Rejecting someone else's is a person's call.

```sql
-- As an agent. Replaces the misdated claim with one dated off the edge.
SELECT set_config('app.current_role', 'agent:intake-fixture', false);

SELECT supersede_assertion(
    p_old_assertion_id := a.id,
    p_new_assertion_type := a.assertion_type,
    p_new_subject_node_id := NULL,
    p_new_subject_edge_id := e.id,
    p_new_claim := a.claim,
    p_new_assertion_key := a.assertion_key,
    p_new_effective_at := e.effective_from,
    p_new_basis := a.basis,
    p_new_evidence := ARRAY[jsonb_build_object(
        'kind', 'source',
        'event_id', (SELECT id FROM events
                     WHERE summary LIKE 'Staffing channel:%' LIMIT 1)
    )]
)
FROM assertions a
JOIN edges e ON e.id = a.subject_edge_id
WHERE a.assertion_type = 'assignment_status'
  AND a.superseded_at IS NULL
  AND a.effective_at < e.effective_from;
```

If the source says the handoff happened earlier than the edge shows, the edge
is what changes, and that is a person's write. Say which one you believe.

### 4. A derived number cites the window it was computed from

A count, a rate, a peak, an average: the period it was computed over goes in
`attrs.source_window` as `{"from": ..., "to": ...}`, ISO 8601, and that window
contains the sources cited as evidence. Write the number as a number; a
measurement rendered as text is invisible to the check.

The rule binds whatever the basis is. A count read off an export is `observed`
and still needs its week. Basis says how Rye came to know a number, not
whether it was computed over a period.

```sql
-- As an agent. The replacement cites the window containing its source.
SELECT set_config('app.current_role', 'agent:intake-fixture', false);

SELECT supersede_assertion(
    p_old_assertion_id := a.id,
    p_new_assertion_type := a.assertion_type,
    p_new_subject_node_id := a.subject_node_id,
    p_new_subject_edge_id := NULL,
    p_new_claim := a.claim,
    p_new_assertion_key := a.assertion_key,
    p_new_effective_at := a.effective_at,
    p_new_basis := a.basis,
    p_new_evidence := ARRAY[jsonb_build_object(
        'kind', 'derivation',
        'source_assertion_id', (SELECT s.id FROM current_valid_assertions s
                                WHERE s.assertion_type = 'task_status'
                                LIMIT 1)
    )],
    p_new_attrs := '{"source_window":{"from":"2026-09-01T00:00:00Z",
                                      "to":"2026-09-30T00:00:00Z"}}'::jsonb
)
FROM assertions a
WHERE a.assertion_type = 'throughput_estimate'
  AND a.superseded_at IS NULL;
```

## Plans and Future Assertions

Separate **plans** from **future-effective truth**.

- A future assertion is the state Rye should answer on or after a future date.
  Store it through `schedule_assertion_change(...)`.

Use current reads for "what is true now":

```sql
SELECT *
FROM rye.current_valid_assertions
WHERE subject_node_id = '<node_uuid>'::uuid;
```

Use as-of reads for "what will be true after the cutover":

```sql
SELECT *
FROM rye.assertions_as_of('2026-10-16T00:00:00Z'::timestamptz)
WHERE subject_node_id = '<node_uuid>'::uuid;
```

CRM/PM schedulers are retained only as thin compatibility wrappers around the
generic helper.

## Knowledge Candidates and Promotion

Assertion candidates own uncertain claims. Structural candidate nodes remain
for proposed tasks, edges, decisions, risks, procedures, preferences, context
gaps, policy changes, scope changes, and plugin changes.

1. Create uncertain claims with `record_assertion(..., p_status := 'candidate')`.
2. Review assertion candidates through `review_queue`.
3. Accept or reject with `accept_assertion(...)` and
   `reject_candidate(...)`.
4. Create structural proposals with `create_knowledge_candidate(...)`.
5. Link structural candidates to source evidence with `supported_by` and to import/run
   context with `derived_from` using the helper function parameters.
6. Keep structural candidate status as `proposed` or `needs_review` until a user or trusted
   reviewer accepts, rejects, marks duplicate, or asks for promotion.
7. Promote accepted structural candidates only through:
   - `promote_candidate_to_task(...)`
   - `promote_candidate_to_edge(...)`
8. Store candidate provenance in promoted edge/task attrs. The helper
   functions already preserve candidate and source refs.
9. If source accounts or containers are still `needs_confirmation`, do not rely
   on their default context to promote knowledge. Use only item-level evidence
   and explicit reviewer decisions.

Candidate statuses are:

- `proposed`
- `accepted`
- `rejected`
- `needs_review`
- `duplicate`
- `superseded`

Do not bulk-promote a candidate queue just because a parser generated it. A bulk
promotion must have an explicit approval decision, target shape, and provenance
policy.

## Provenance

- Log agent queries with `log_agent_query(agent_id, query, summary, node_ids)`.
- Put assertion provenance in `assertion_evidence`.

### Tracing a search loop

Finding a thing usually takes several tries, and the answer you end up with
cannot say which try found it. A trace can. It is optional, you decide per
call, and nothing logs on your behalf: `find_nodes`, `find_nodes_batch`,
`find_paths`, `neighborhood`, `agent_node_summary()`, and `node_context` write
nothing at all. Trace the loops someone will read — the ones that went wrong, a
sample, an eval week — and not every read: events are immutable and there is no
way to delete one later.

Pass a fifth argument to the call you already know. Four arguments still work
and write no trace.

- `trace_id` — your own id for this one loop, the same on every step. Required.
- `seq` — 1, 2, 3 within the loop. Required, and it is what orders the steps:
  every call inside one transaction carries the same timestamp, so time cannot.
- `tool`, `intent`, `args` — what you called, why you phrased it that way, and
  what you passed. `intent` is the one a database log could never record.
- `results` — the candidates that came back, each with `used` true or false.
  Record the ones you passed over: the node returned third and ignored is a
  different problem from the node that never came back. Cap the list at about
  ten.
- `selected` — which step's phrasing produced the candidate you used:
  `{node_id, from_seq, from_phrasing}`.

```sql
SELECT set_config('app.current_role', 'agent:harbor-analyst', false);
SELECT rye.log_agent_query(
    'harbor-analyst',
    'the fence company',                 -- this step's phrasing
    '0 candidates',
    ARRAY[]::uuid[],
    jsonb_build_object(
        'trace_id', 'loop-7f3a',
        'seq',      1,
        'tool',     'find_nodes_batch',
        'intent',   'the question names no company, try what it describes',
        'args',     jsonb_build_object(
                        'p_queries', jsonb_build_array('the fence company', 'fence company'),
                        'p_node_types', jsonb_build_array('org')),
        'results',  jsonb_build_array()));
```

The next step carries `'seq', 2` under the same `trace_id`, and the step that
settles it adds `selected`. Read the loop back in order:

```sql
SELECT seq, tool, intent, query, selected
FROM rye.agent_query_trace
WHERE trace_id = 'loop-7f3a'
ORDER BY seq;
```

Pass the nodes the step touched as the fourth argument whenever it touched
any, including the ones you rejected. An event is visible to you through its
participants, so a step recorded with an empty array is readable only by an
admin — and that is the step that found nothing, the one worth reading. The
loop above returns `seq` 2 for you and both steps for an admin. When a step
truly matched nothing, say so in `intent` and expect a person to be the one
who reads it.

A trace with no `trace_id` or no `seq` is refused: it could not be grouped or
ordered, and an ungroupable trace looks like data. Tracing is a write like any
other, so a `viewer` and a role-less session are refused `42501` whether they
pass a trace or not — a read-only agent does not trace, and
`rye-knowledge-reader` forbids this call outright.

## Safety

- Keep reads scoped and ranked.
- Avoid dumping full history to the model by default.
- Gate high-risk actions behind explicit user confirmation.
