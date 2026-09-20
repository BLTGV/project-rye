# Rye Agent Operations Guide

## Start a session

All objects live in `rye`.

```sql
SET search_path = rye, public, pg_catalog;
SET "app.current_user_id" = 'user:alice';
SET "app.current_teams" = 'engineering,sales';
SET "app.current_role" = 'team_member';
```

Plain `SET` because this block is pasted into a session, not a transaction.
`SET LOCAL` lasts only for the current transaction, and outside a `BEGIN` it
warns "SET LOCAL can only be used in transaction blocks" and sets nothing — a
reader who pastes it runs with no role at all. Use `SET LOCAL` only between a
`BEGIN` and a `COMMIT`.

A pooled connection or a per-call tool gives every statement a fresh session,
so neither form survives to the next call: pass `set_config('app.current_role',
'team_member', false)` in the same call as the query. See the Supabase notes in
`AGENTS.md`, where `SET app.current_role = ...` does not work through the MCP at
all.

The role is not decoration. A session with no role set, and a session whose role
is `viewer`, reads normally and writes nothing at all: every insert, update, and
delete on `nodes`, `edges`, `events`, `event_participants`, `assertions`,
`assertion_evidence`, `artifacts`, and `node_source_map` is refused, inside a
`SECURITY DEFINER` helper as well as outside one. **Check the row count, never
rely on an error.** A refused `INSERT` raises `42501` on every deployment. A
refused `UPDATE` or `DELETE` by an ordinary session — any session that is not
the table owner — shows as zero rows and raises nothing, on a superuser-owned
install as much as anywhere else, because the policy filters the row out before
the trigger ever sees it. An agent session sets
its own key — `agent:<key>` — and never `admin` or `system:cdc`, which is
reserved for Rye's record of a change to a tracked domain table and may insert
nothing but events and participants. The normative table is "Who may write" in
`contracts/sql-surface.md`.

Call `rye_catalog()` first. Use `agent_node_summary(node_id, max_items)` for
bounded context. Read current knowledge from `current_valid_assertions` or
`current_assertions_weighted`, never from a bare `superseded_at IS NULL`
filter.

## Discover categories before a write

`rye_catalog()` reports type names and counts. `rye_categories()` reports what
a type means here. Call it before proposing any node: procedure ships in the
skill, vocabulary lives in the graph. `contracts/category-vocabulary.md` is the
normative shape; it is `STABLE`, computed on read, and never cached, so a
description accepted a moment ago is visible on the next call.

```sql
SELECT rye_categories('<scope_uuid>'::uuid);  -- omit the argument for unscoped
```

```bash
./scripts/rye categories --scope <uuid-or-key> --json
```

Per category: `name` (the node type) and `kind` (`node_type`), plus

| Key | Read it as |
|---|---|
| `description`, `description_source` | The organization's words for the type, or `null` when nobody has said. Sourced from a `category_description` assertion on a `category` node, keyed by scope with a `default` fallback. |
| `properties.observed` | `[{key, count, frequency}]` over non-archived nodes of the type. The keys a proposal should carry; `frequency` is how often each appears. |
| `properties.required`, `required_source` | `[]` and `"none"` in v0.3. Tolerate a non-empty array. |
| `relationships.as_source`, `.as_target` | `[{edge_type, other_types, count}]`. Prefer an edge type already used between these types. |
| `enabled` | `on`, `off`, or `unscoped`. `off` is not writable here — `validate_candidate_against_scope()` refuses it. Off categories are listed, not omitted. |
| `usage_count`, `declared_by` | Non-archived nodes of the type; the plugin ids that declare it. |

Top level: `empty` is `true` exactly when `categories` is empty — an empty area
answers, it does not error, and the right response is an open question for a
person, not an invented type. `scope.scope_found` `false` means the scope did
not resolve; `scope.type_policy` `missing` means the scope has no current
`allowed_node_types` claim, so every category reads `off`. `contract_version`
is `1`; the shape is additive, so ignore keys you do not know.

Agents never create a category. Adding a node type is a person's decision.
Descriptions change through the ordinary lifecycle — `record_assertion()`,
`accept_assertion()`, `supersede_assertion()` on the `category` node — so a
candidate description stays invisible until someone accepts it.

"Category" is the business sense: what kind of thing this is. It is not
`classification`, which is who may see it.

## Ask who may settle it before you accept

Never record a statement as accepted without asking who may settle that claim.
`rye_settlers()` answers it, and every agent asking the same question gets the
same answer. The settlement lookup section of `contracts/sql-surface.md` is the
normative shape; it is read-only, advisory, computed on read, and never cached.

```sql
SELECT rye_settlers(
    p_subject_id := '<subject_uuid>'::uuid,
    p_claim_type := 'expectation',
    p_speaker_id := '<speaker_uuid>',
    p_speech_act := 'expectation',
    p_domain_key := 'sales-operations'
);
```

```bash
./scripts/rye settlers --subject <uuid> --claim <assertion-type> \
  --speaker <uuid> --speech-act <act> --domain <key> --json
```

Always pass both `--claim` and `--speech-act`. `p_claim_type` is the claim's
`assertion_type` verbatim — one vocabulary, no mapping table. `p_speech_act`
is the caller's classification of what was said; the recognized values are
`self_commitment`, `self_report`, `expectation`, `statement_about_other`,
`statement_about_thing`, `agreement`, `decision`, `outside_report`, and
`agent_inference`. `p_speaker_ref` carries a source identity such as
`slack:U0123` when the speaker has no person node. `p_as_of` reconstructs a
past answer from the grants and relationships in force then.

The relationship step reads the claim type first and the speech act second.
Two claim-type sets are matched on the **canonical** type, after alias
resolution: other-set (`expectation`), a claim one person sets on another, and
self-set (`commitment`, `self_commitment`, `self_report`, plus any type
declared self-settled in this instance), a claim a person settles about
themselves. An expectation is always the manager's call, and the person it is
set on is never returned as its settler, whatever speech act is passed and
whether one is passed at all. A missing or unrecognized speech act selects no
relationship default and falls through to the area owner. Saying less never
widens the answer.

**The subject is returned only when the canonical claim type is positively in
the self set.** No speech act makes a person their own settler on its own:
`self_commitment` on a type nobody has declared self-settled returns nobody
local, not the subject. Unknown is restrictive, and blindness is too — a
caller who cannot see an alias or a declaration gets the stricter answer, never
a wider one, so two roles can classify the same type differently and the
difference only ever costs settlers. Matching is case-sensitive and case is
not folded; the fix for a spelling is a `type_alias` entry, not a second
declaration.

The self set grows as data. A registry entry keyed
`self_settled_type:<canonical assertion type>` with the jsonb value `true`
adds a member, read through `registry_value()`, scope first, then plugin, then
core. Rye has no dedicated registry-writing helper: write it with
`record_assertion()` as a `registry_entry` on the registry or scope node, the
same shape `type_alias` entries use, never by touching a base table. It is not
a claim like any other: `registry_entry` is part of how Rye is set up here, and
only a Rye admin settles it. See "How Rye is set up here needs an admin" below.
The core members need no entry.

An agent choosing a claim type reuses one `rye_categories()` lists. An
invented type, or a known one spelled differently, is in neither set, so a
claim about the speaker routes to the area owner instead of settling on their
word.

`claim.speech_act_recognized` `false` means the value passed was outside the
recognized set. Do not record anything as accepted while it is false:
classify the statement again, pass a recognized speech act, and look again.
That is the caller's mistake to correct, never something the person hears.

| Key | Read it as |
|---|---|
| `speaker.is_settler` | The field you act on. `true`: record accepted. `false`: record a suggestion and ask the listed settlers. |
| `settlers` | Who may settle it. Each carries `kind`, `node_id`, `ref`, `label`, `via`, `relationship`, `bound`. |
| `step` | Which step answered: `grant`, `relationship`, `area_owner`, or `none`. A grant displaces the relationship defaults for that claim type. |
| `bound` | `false` means an unbound source identity or a ref that resolves to no node. Do not treat it as a person record. |
| `reason`, `setup_gap` | Why there is no settler. `setup_gap` `true` is a gap for a Rye admin to fill, not an error, and `reason` says which. |
| `excluded_agents` | Agent identities dropped before a step was chosen. Tells nobody apart from nobody eligible. |

`settlers` is empty exactly when `step` is `none`. Because RLS silence applies,
an empty list means nobody is authorized *and visible to you*. Never read it as
permission to accept. `contract_version` is `1` and the shape is additive, so
ignore keys you do not know.

Four outcomes and nothing else:

1. **`speaker.is_settler` is true.** Run the standing-claim check below
   first. If it is clear, record it accepted with
   `record_assertion(..., p_status := 'accepted')`, with the utterance as
   source evidence and the authorizer/executor convention in the evidence
   `attrs`. Echo one line.
2. **It is false.** Record the same claim with `p_status := 'candidate'` on
   the same subject, type, and key, the speaker's words as its backing, and
   the settlers in `p_attrs`. If it contradicts something already accepted,
   put the id of that claim and the speaker's reason in `p_attrs` and leave
   the accepted claim untouched. Ask why, then tell the person whose call it
   is and that you will check with them.
3. **The answer is the area owner.** `via` is `area_owner`. One common cause
   is a claim about the speaker under a type nobody has declared self-settled.
   Treat it as outcome 2 and nothing more: record the suggestion and say you
   will check with the owner. The person hears the same sentence they would
   hear for any statement they cannot settle. Never explain types, registries,
   or declarations to them, and never reach for a different claim type to make
   it settle.
4. **`step` is `none`.** Read `reason` first. `area_has_no_owner` and
   `area_owner_is_agent` are the two setup gaps: record the suggestion and
   tell the person nobody is recorded as deciding this yet.
   `area_owner_not_visible` and `no_settler_found` are not gaps and not
   permission to accept: record the suggestion and say you are finding out
   who settles it. `domain_not_resolved` and `domain_not_found` are your own
   mistake — you named no area or the wrong one. Correct the key and ask
   again. Say nothing to the person about either.

### How Rye is set up here needs an admin

Some assertion types are not knowledge about the world. They are how Rye is set
up here, and Rye reads them to decide how it treats every other write.
`registry_entry` carries the type aliases that `canonical_type()` follows, the
`self_settled_type:*` entries that `rye_settlers()` reads, and the rest of what
`registry_value()` resolves — the default scope, governed types, basis priors,
half lives, digest facets. `review_policy` decides whether a write lands
accepted at all. Only a Rye admin settles either one. The normative shape is
"Configuration writes need an admin" in `contracts/sql-surface.md`.

Which types are gated is data, not code, so ask before offering to record one:

```sql
SELECT settle_gate('registry_entry');
```

```bash
./scripts/rye settle-gate registry_entry --json
```

It answers `{assertion_type, gated, allowed_roles, current_role, may_settle}`,
is `STABLE` and `SECURITY INVOKER`, and writes nothing. `gated` `false` means
the type is ordinary knowledge and the settlement lookup alone decides it.
`may_settle` `false` means an accepted write of that type will be demoted. The
gate sits on top of the settlement lookup rather than replacing it: an area
owner who is not a Rye admin settles claims and still cannot declare a
self-settled type.

Record it the same way either way, with `record_assertion(...,
p_status := 'accepted')` and the speaker as authorizer. Asking for accepted is
what records that the speaker meant it to take effect; the caller never lowers
the status itself.

- `may_settle` `true`: it lands accepted, and the person hears one line in
  their own words.
- `may_settle` `false`: `record_assertion()` demotes it to a candidate carrying
  `attrs.settle_gate` (`pending`, `requested_status`, `allowed_roles`), which a
  Rye admin sees in `review_queue` with every other candidate. Nothing said is
  lost and nothing is refused. The person hears that it is noted and that a Rye
  admin has to confirm it — never that they lack permission, and never in Rye's
  own vocabulary.

A demotion ends the attempt. Every other route to an accepted row of a gated
type raises: a direct `INSERT`, any `UPDATE` to `accepted` including one by a
caller that sets `app.write_path` itself, `accept_assertion()`,
`supersede_assertion()`, `record_distillation()`, and
`schedule_assertion_change()`. The last few refuse rather than demote on
purpose — each marks or displaces the incumbent first, so a quiet demotion
would leave the key with no accepted value and let a proposal erase an alias.
`rye.authoritative.promote` does not open this gate, a second identity is not
an answer, and neither is asking a more permissive agent. An agent does not set
`app.current_role` to `admin`: the role it presents is the person's, not a
setting it chooses.

Those refusals belong to this gate alone. On an ordinary type
`supersede_assertion()` does not raise under a review policy that would demote
the caller's write; it files a suggestion. See "Assertions" below.

One write has no waiting form at all: an alias pointing *from* a gated
configuration type — a `registry_entry` keyed
`type_alias:assertion_type:registry_entry`, `:review_policy`, or
`:scope_status` — is refused for every caller at every status, an admin
included, because renaming the word would turn the gate off for everything
written afterwards. An alias pointing into a gated type is ordinary.

Until an admin accepts it, the suggestion is read by nothing. `registry_value()`,
`canonical_type()`, and `rye_settlers()` return exactly what they returned
before, so claims of the affected type keep routing as they did, and a waiting
suggestion is never spoken of as if it were in force.

Migrations and scripts that seed configuration set `app.current_role` to
`admin` first, as `sync_plugin_metadata.sh` does. An unset role is not an
admin.

### What the lookup does not answer

The lookup reads no assertion. It answers who may settle a claim; it does not
answer who may unsettle one. It cannot see that a claim on this subject is
already accepted, so `is_settler` `true` is not permission to replace
something the caller never looked for.

The gap has one shape: a person restates or contradicts something already
accepted about themselves, of a self-set type, that somebody else authorized —
a quota their manager set, for example. For that claim type they are a
settler, so the lookup returns them as one and says nothing about the standing
claim.

So before accepting on `is_settler` `true`, read `current_valid_assertions`
for an accepted row on the same subject, assertion type, and assertion key,
and read its evidence `attrs.authorizer`.

Match the type with `canonical_type('assertion_type', ...)` on both sides, not
by raw string. Rye resolves synonyms through type aliases, so a standing
`expectation` and a new `requirement` can be the same claim and raw equality
misses it. Then write the canonical type the lookup reports rather than the
synonym: Rye reports the drift, it does not rewrite the insert, so a row
written under an alias keeps that spelling. Type names are case-sensitive —
`Expectation` is not `expectation` unless an alias says so — so use the type
exactly as `rye_categories()` lists it.

The guard fails closed: exactly one recorded authorizer lets the write
through, and it is the speaker's own.

| What stands | What the caller does |
|---|---|
| No accepted row | Accept. Nothing is being replaced. |
| `authorizer` is the speaker | Accept. The person is correcting their own earlier words; one line back. |
| `authorizer` is somebody else | Record a suggestion, as in outcome 2. |
| No `authorizer` recorded | Record a suggestion. Do not guess whose call it is. |

Rows written before the authorizer/executor convention carry no authorizer,
and an unrecorded authorizer is not an absent one. A missing field is never
permission. Run the lookup for that claim, check with a settler it returns
other than the speaker, or with the area owner if it returns no other, and
tell the person plainly that the confirmation comes first. Never supersede a
standing claim on a missing field. Routing that objection onward is a later
work item; this is only the guard.

Accepted stays accepted until a settler changes it. A later statement from
someone who cannot settle a claim does not overwrite it and does not vanish —
it is recorded and routed. Nothing is accepted on silence, and there is no
clock that turns silence into agreement.

An agent carries the authority of the person it acts for and none of its own.
Never relabel a basis or a speech act to get a write through, never switch to
an identity with wider grants, never set `app.current_role` to a wider role,
and never ask a more permissive agent to write it. `rye_settlers()` drops agent identities before choosing a step, so no
lookup ever returns an agent.

`reports_to` and `owns` are the relationships the lookup reads, declared by the
`rye-org` plugin and pinned in `contracts/plugin-manifest.md`. `reports_to`
runs from the report to the manager. `owns` runs from the owner to the thing
owned. Both are temporal and never deleted: end one with `effective_to`, and
archive only a line recorded in error. Neither is settled by the people it
connects — a claim whose type is `reports_to` or `owns` has no relationship
default and falls through to the owner of the area.

Anything a person hears uses `docs/glossary.md` words. Internal identifiers —
uuids, assertion types, step names, agent keys — stay canonical in what is
stored and stay out of what is said.

## Events

Always create events through `record_event()`. It creates participants
atomically and avoids the event RLS visibility cycle.

```sql
SELECT record_event(
    p_event_type := 'meeting',
    p_summary := 'Quarterly review with Acme',
    p_properties := '{"location":"zoom"}',
    p_participant_ids := ARRAY['<node_uuid>']::uuid[],
    p_participant_roles := ARRAY['customer']
);
```

Do not insert into `events` and `event_participants` separately.

## Assertions

`record_assertion()` is the normal write path. Evidence is a `jsonb[]`; each
item contains `kind` and either `event_id` or `source_assertion_id`. A
`witness_node_id` is optional.

```sql
SELECT record_assertion(
    p_assertion_type := 'task_status',
    p_claim := '{"status":"in_progress"}',
    p_subject_node_id := '<task_uuid>',
    p_assertion_key := 'default',
    p_status := 'accepted',
    p_basis := 'reported',
    p_evidence := ARRAY[
      jsonb_build_object(
        'kind', 'source',
        'event_id', '<event_uuid>',
        'witness_node_id', '<person_uuid>'
      )
    ]
);
```

Evidence is required for helper-created assertions unless `basis = 'assumed'`.
Use `assumed` only for configuration or an explicit operator assumption.

When an active scope governs the subject, assertion type, or primary witness,
`record_assertion()` resolves it automatically. Pass `p_scope_node_id` only
when the caller already knows the scope; a mismatch with durable coverage
raises. `candidates_only` forces non-observed writes to candidates. `strict`
forces all writes to candidates. Agent promotion under either policy requires
`rye.authoritative.promote`.

Three things about that policy are worth knowing before reading a helper's
answer:

- **It holds on every route.** `supersede_assertion()` no longer lands an
  accepted replacement under a policy that would demote the caller's write. It
  writes the replacement as a candidate carrying `attrs.review_gate`, leaves the
  incumbent accepted and unsuperseded, raises a `NOTICE`, and returns the new
  id exactly as before. The return value says nothing; read `status` or
  `attrs->'review_gate'` from the returned id, or find the row in
  `review_queue`. A settler accepting the candidate supersedes the incumbent
  then. `resolve_knowledge_gap()` follows the same rule: the gap stays in
  `open_gaps` and the `knowledge_gap_resolved` event carries `pending_review`.
- **The most restrictive policy wins.** When more than one scope governs a
  subject — what a cross-scope `merge_nodes()` leaves behind — the governing
  scope is the one whose policy is strictest, ordering `strict` above
  `candidates_only` above `open`, with `scope.id` only as a tie-break.
- **A helper takes the stricter of two resolutions.** It resolves the scope
  with the witness and again without one, and applies the stricter policy, so a
  `scope_governs_source` edge from an `open` scope no longer opens a source on
  an instance whose `DEFAULT_SCOPE` is `strict` or `candidates_only`. Those
  writes land as candidates. To keep the exception, a Rye admin gives those
  subjects their own `scope_governs_subject` edge to the open scope.

To represent uncertainty, write one or more `candidate` rows on the same
tuple. Review them through `review_queue` or `competing_candidates`.

```sql
SELECT accept_assertion(
    p_assertion_id := '<candidate_uuid>',
    p_reason := 'Confirmed by owner',
    p_actor := 'user:alice'
);

SELECT reject_candidate(
    p_assertion_id := '<other_candidate_uuid>',
    p_reason := 'Superseded source document',
    p_actor := 'user:alice'
);
```

An inferred candidate cannot displace accepted observed, reported, assumed, or
unknown knowledge. Do not update assertion content or lifecycle columns
directly. Public `supersede_assertion()` only replaces the same subject, type,
and key, and only where the caller's write would land accepted.

Use `schedule_assertion_change()` for future-effective replacements.
Operational views continue returning the current assertion until the cutover.

Use `record_distillation()` for a digest. It requires source assertions,
writes derivation evidence, propagates classification, stores a watermark, and
records a distillation event. It rejects mixed-access source sets.

Use `resolve_knowledge_gap()` to close an accepted `knowledge_gap` with an
answer assertion. It creates a resolved version on the gap's own tuple. Under a
demoting review policy the resolved version is a candidate, the gap stays open
and stays in `open_gaps`, and the event says `pending_review`. Because that
version is written with basis `inferred`, `accept_assertion()` will not let it
displace a gap recorded with another basis; record gaps with basis `inferred`,
or reject the candidate and record the resolved gap with `record_assertion()`.

## Intake consistency

Four rules for an agent reading source material into the graph. Each one closed
a defect a clean-room agent produced from realistic sources: an employment edge
left open after a departure was recorded, a digest that claimed more than its
sources establish, an effective date and an edge window telling two different
handoff stories, and a derived number that named a different window than its
sources.

The reads that find each one after the fact are in
`skills/rye-pattern-library/references/intake-consistency-checks.md`, with a
fixture and an executable copy in `eval/intake_consistency/`. They are advisory
reads. The database does not refuse a write for breaking one of these rules.

The examples below run against `eval/intake_consistency/fixture_violations.sql`
and repair it. Each one names the role it needs.

### Recording a departure closes the edges it contradicts

When you record that someone departed, their `employs` edge and their role
edges end on the same date. An open edge and an accepted departure contradict
each other, and a reader gets a different answer depending on which one it
reaches.

An agent cannot do this part. An agent-shaped session has no `UPDATE` on
`edges`: the row is outside its policy, so the statement reports `UPDATE 0`,
changes nothing, and raises nothing. Record the departure, then name the open
edges to a person who can close them. Under a review policy your departure
write is a suggestion waiting in `review_queue`, so say that too.

**Get the date.** The repair below closes each edge on the departure's
`effective_at`. A departure recorded without one is reported by the check
forever and no statement can clear it, because there is no date to close the
edge on. When the source does not give a last day, ask the person for it before
recording the departure, and say plainly that you cannot record the end of
anything until you have it.

**Close and handoff are different.** Membership and assignment end when the
person leaves. Something they *own* does not: closing an `owns` or
`responsible_for` edge leaves the thing unowned, which is a worse record than a
stale one. Those need a successor named by a person first; then the new edge
opens and the old one ends on the same date. The edge list below is the `close`
set, derived from `plugins/*/rye-plugin.json`; the check reports both sets with
a `disposition` column.

```sql
-- As team_member. Ends every open employs or role edge on the date the
-- current accepted departure gives.
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

### A digest asserts nothing its sources do not establish

Every key in a digest claim comes from a source assertion the digest cites.
`record_distillation()` requires at least one source and writes one
`derivation` evidence row per source, so the check is a join. If the material
supports a detail but no accepted assertion states it, record the assertion
first and then distil. Do not carry the detail into the digest alone.

```sql
-- As an agent. Every claim key is established by one of the two sources.
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
and the digest already accepted stays current until a person accepts the new
one. Read `status` from the returned id rather than assuming.

### An effective date and an edge window tell one story

A claim about a relationship takes its `effective_at` from the edge it is
about. Backdating the claim without moving the edge, or moving the edge without
the claim, produces two answers to one question about who owned what in June.

Point the claim at the edge — as `subject_edge_id`, or with `attrs.edge_id`
when the subject has to be a node. A claim about a relationship that names no
edge cannot be checked against anything. On the first write, read
`effective_at` off the edge instead of guessing it.

Correcting one already recorded depends on what the incumbent is now. Both
halves matter, and the second is the one under a review policy.

- **Against an accepted assertion**, a date-only or attrs-only correction
  through `record_assertion()` writes nothing: when claim, basis and confidence
  match, it appends your evidence, returns the incumbent's id and inserts no
  row, whatever you pass for `p_effective_at` or `p_attrs`. Use
  `supersede_assertion()`.
- **Against your own suggestion** — what a demoting review policy leaves you —
  `supersede_assertion()` raises `Only accepted assertions may be superseded;
  reject candidates instead`. `record_assertion()` with a different date does
  not replace it either: it writes a *second* suggestion and returns a new id,
  so both dates then sit in `review_queue`. Close the wrong one with
  `reject_candidate()` and file the corrected one.

An agent may call `reject_candidate()`. Verified as `agent:<key>` on a full
install: it closed the agent's own suggestion. Rejecting your own suggestion is
housekeeping, not settling. Rejecting someone else's is a person's call — say
what you closed and why, and leave a claim you did not write alone.

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
is what changes, and changing it is a person's write. Say which one you believe
and why.

### A derived number cites the window it was computed from

A count, a rate, a peak, an average: whatever period it was computed over goes
in `attrs.source_window` as `{"from": ..., "to": ...}`, ISO 8601, and the
window contains the sources cited as evidence. Without it nobody can recompute
the number or tell whether it is stale.

Write the number as a number. A measurement rendered as text is invisible to
the check.

The rule binds whatever the basis is. A count read off an export is `observed`
and still needs its week — basis says how Rye came to know a number, not
whether it was computed over a period.

Adding a window to a number already recorded follows the same two cases as a
date correction above: `supersede_assertion()` against an accepted assertion,
`reject_candidate()` plus a new suggestion against your own pending one.

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

## Predictions and future knowledge

Use `record_prediction()` for a probabilistic forecast. The prediction stays on
an `assertion_type = 'prediction'` tuple and names the outcome tuple in
`claim.outcome_key`. Call `score_due_predictions()` from an operator-selected
scheduler or maintenance run. Read calibration from `calibration_report`.

Do not score accepted future-effective assertions. They are future truth Rye
should return at their effective time, not forecasts. Use
`schedule_assertion_change()` for future-effective truth and
`record_prediction()` only when a probability and later calibration are
intended.

## Pattern write path

Use `record_pattern()` for induction. Supply at least three current accepted
source assertions from distinct subjects. The helper creates a `pattern` node,
writes a candidate `pattern_claim`, and stores support and counter-evidence in
`assertion_evidence`. It never writes an accepted pattern directly.

Review `pattern_support`, then use `accept_assertion()` as a human reviewer or
capability-granted agent. Inferences may cite an accepted pattern as derivation
evidence. Their effective confidence is capped at the pattern's confidence for
one hop; do not assume deeper propagation.

## Classification and evidence

Assertions have their own `classification`. Derivations inherit the maximum
source classification. A derivation is rejected if no one access population
can see all sources.

`assertion_evidence` is append-only. A row is visible only when the caller can
see both the target assertion and the referenced event or source assertion.
Corroboration from a repeated witness is retained for audit but marked
`attrs.independent = false`.

Nodes with non-empty `attrs.teams` must also set `attrs.classification`.
Digest narrative artifacts inherit the digest assertion classification.

## Before creating a node

Call `resolve_node_identity()` before minting an entity you expect might
already exist.

```sql
SELECT resolve_node_identity(
    p_node_type := 'org',
    p_label := 'Northwind Trading',
    p_identity := '{"email":"ops@northwind.example"}'
);
```

It returns a verdict and the candidates behind it:

| Verdict | What it means | What to do |
|---|---|---|
| `match` | One node matches on external identity or a declared identity key | Reuse that node |
| `ambiguous` | Several exact matches, or a plausible label match only | Do not guess — record a structural candidate for review |
| `new` | Nothing matched | Create the node |

A similar label never returns `match`. Similar names are not evidence of
identity, so they arrive as `ambiguous` for a person to settle.

This call is advisory. It writes nothing and blocks nothing, and no write
helper consults it — the decision is yours. Route `ambiguous` to
`create_knowledge_candidate()` and batch review by resolved cluster rather
than by row, or a large import will stall on individual near-misses. Do not
try to clean up an `ambiguous` verdict yourself. Merging is for people, and
the rule is about the row, not the route: `merge_nodes()` refuses an
agent-shaped session by name, and a direct write to `node_merges` is refused
the same way — along with any row that is not the shape a real merge leaves.
Record the duplicate and ask a person.

`new` means nothing matched *that you can see*. A node hidden from you by
classification is not matched, so a duplicate is possible across an access
boundary. Where that matters, run intake under a role that can see the whole
population for the node type.

Searching an old name still works. When a node was merged away, its label went
with it, so a similar former name surfaces the node's **live survivor** as a
candidate with `match_reason` `former_label_similarity` and the old name in
`matched_former_label`. Like any label match, it is `ambiguous`, never `match`.

Hold an id that may be stale? `resolve_merged_node(id)` follows `node_merges`
to the surviving node. It reads under your own visibility: if a node in the
chain is hidden from you, the answer is the last link you can see, not an
error. A merge cycle answers too — it stops rather than raising.

## Other safe writes

- Use `link_record()` to connect a domain row to a graph node. Writing or
  re-pointing a `node_source_map` row needs a role that may write, as the core
  tables do; deleting one still needs an admin or a manager.
- Use `track_table()` to capture linked domain-row changes. The CDC trigger
  records its event under the reserved role `system:cdc`, so a tracked table
  still produces its event when the application's session sets no Rye role at
  all, and the event's `properties.session_role` keeps whatever role that
  session did have. Never set `system:cdc` by hand: it may insert events and
  participants and nothing else, anywhere.
- Use `update_node_properties()` only when the node itself is the system of
  record. Update the domain table otherwise. It refuses a session that may not
  write, and refuses a non-admin editing an `onboarding_scope` node, with a
  sentence rather than a silent miss.
- Use `record_artifact()` for artifacts and optional content-hash deduplication.
- Use `log_agent_query()` to audit agent reads.
- Use `type_vocabulary_report` and the Rye gardener skill to propose aliases or
  merges. No agent merges: `merge_nodes()` refuses every agent-shaped session
  with `42501` and names who can, a Rye admin or a team member. It also refuses
  a non-admin merging a node the governance structure touches. An agent that
  finds a duplicate records the evidence and tells its person.
- Creating, activating, archiving, ending, deleting, or re-pointing the
  governance structure — `onboarding_scope` nodes and `scope_governs_subject`,
  `scope_governs_source`, and `scope_enables_plugin` edges — needs
  `app.current_role = 'admin'`, and so do the `scope_status`, `review_policy`,
  and `registry_entry` assertions that go with it. That covers
  `create_onboarding_scope()`, `activate_onboarding_scope()`,
  `enable_plugin_for_scope()`, and `record_scope_policy()`.
- Use the tabular intake skill for CSV/XLSX staging and duplicate-run checks.

## Review and operational views

All views are security invokers.

| View | Purpose |
|---|---|
| `current_valid_assertions` | Accepted, current, effective-now assertions |
| `current_assertions_weighted` | Current assertions plus effective confidence |
| `review_queue` | Live candidate rows grouped by tuple |
| `competing_candidates` | Tuples with more than one live candidate |
| `stale_digests` | Digests invalidated by newer knowledge or displaced sources |
| `node_salience` | Advisory attention from cooperative query logging |
| `type_vocabulary_report` | Historical type vocabulary and canonical aliases |
| `source_reliability` | Labeled witness outcomes and sample size |
| `calibration_report` | Resolvable prediction Brier score and hit rate |
| `pattern_support` | Pattern support and contradiction counts |
| `open_gaps` | Accepted unresolved knowledge gaps |
| `assertion_support` | Visible evidence bundle in both directions |
| `node_context` | Node, relationships, and current accepted assertions |
| `nodes_secure` | Nodes with field-level redaction |

`node_salience` is incomplete by design because only `log_agent_query()` reads
count. It may order distillation or review work. Never use it to filter access,
retention, deletion, or operational visibility.
