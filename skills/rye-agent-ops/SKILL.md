---
name: rye-agent-ops
description: Operate Rye data safely for LLM agents. Use when implementing or executing agent read/write flows, connecting domain tables, selecting assertion keys, enforcing provenance, and applying agent-safe SQL patterns for context retrieval and auditable writes.
---

# Rye Agent Ops

## Session Setup (Required)

Before any query, set the session context. On stateless connections (Supabase MCP, serverless, transaction-mode poolers), this must be done in **every call**:

```sql
SELECT set_config('app.current_role', 'admin', false);
SELECT set_config('app.current_user_id', 'user-123', false);
SELECT set_config('app.current_teams', 'engineering', false);
```

Without this, RLS will block access. Use `set_config()` (not `SET` syntax) for portability.

## Orient

1. Run `SELECT rye_catalog()` to see what's in the instance — node types, edge types, assertion types, tracked tables, and totals.
2. Use `agent_node_summary(node_id, max_items)` for compact context on a specific node.
3. Run the category discovery below before proposing any node.

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

`p_claim_type` is the claim's `assertion_type` verbatim — there is no separate
vocabulary and nothing to register. Two small sets of claim types carry
meaning of their own, matched on the exact string:

- **Other-set**, a claim one person sets on another: `expectation`.
- **Self-set**, a person's own commitment or report about themselves:
  `commitment`, `self_commitment`, `self_report`.

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

`speech_act_recognized` is false when you passed a value outside the
recognized set. **Do not record anything as accepted while it is false.**
Classify the statement again, pass a recognized speech act, and look again.
That is your mistake to correct. Never mention it to the person.

Read three fields and act on them:

| Field | Act on it |
|---|---|
| `speaker.is_settler` | `true`: run the check below, then record it as accepted. `false`: record a suggestion. |
| `settlers` | Who to check with. `step` says which of `grant`, `relationship`, `area_owner` produced them. |
| `step` = `none` | Nobody settles it here. `reason` says why; `setup_gap` `true` is a gap for a Rye admin, and `reason` says which. |

The lookup is advisory. It writes nothing, refuses nothing, and no write path
calls it. It is your discipline, not a wall the database holds.

### What the lookup does not tell you

It reads no assertion. It answers who may settle a claim; it does not answer
who may unsettle one. So it cannot tell a new statement from a contradiction
of a standing one, and `is_settler` `true` is not permission to replace
something you never looked for.

The gap has one shape. A person restates or contradicts something already
accepted about themselves that somebody else authorized, under a claim type
outside the other-set list — a quota their manager set, say. For that claim
type they genuinely are a settler, so the lookup returns them as one, and
nothing in the answer mentions the standing claim.

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
- Something already on record, and you cannot tell who put it there: "There's
  already something on record for that. I've kept your version and I'll
  confirm with Priya before I change it."
- Correcting their own earlier words: accept it and echo one line. Do not
  make them explain themselves.
- Asked about an unsettled claim: say the claim exists, say it is unsettled,
  and say who said it. Do not hide it and do not answer with it.

### What you must never do

- Never relabel a statement's basis or speech act to get it through.
- Never switch to an identity with wider grants, and never ask a more
  permissive agent to write it for you.
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

## Safety

- Keep reads scoped and ranked.
- Avoid dumping full history to the model by default.
- Gate high-risk actions behind explicit user confirmation.
