# Contract: SQL surface

Published by **schema**. Consumed by **admin** and **agent-kit**.

The `rye` schema is the only shared state in the system; everything else is a
client of it. This contract says what a client may depend on.

## Shape

- **Objects.** Six core tables, the supporting tables, the read views
  (`current_valid_assertions`, `node_context`, `review_queue`,
  `competing_candidates`, `stale_digests`, `open_gaps`, `assertion_support`,
  `current_assertions_weighted`), and the helper functions. Full inventory in
  `docs/data-dictionary.md`; normative behaviour in
  `design/model/core-contract-and-conformance.md`.
- **Writes go through helpers**: `record_event`, `record_assertion`,
  `accept_assertion`, `reject_candidate`, `supersede_assertion`,
  `record_distillation`, `schedule_assertion_change`, `resolve_knowledge_gap`,
  `record_artifact`, `link_record`, `link_records_batch`, `track_table`,
  `merge_nodes`. A client never inserts into `events` and
  `event_participants` separately, and never updates an assertion's content,
  status, or basis.
- **Reads are views and `SELECT`-returning functions**: `rye_catalog()`,
  `rye_agent_context()`, `rye_categories()`, `rye_settlers()`,
  `agent_node_summary()`, and the views above. `rye_categories()` has its own
  contract, `contracts/category-vocabulary.md`, which governs its jsonb shape;
  `rye_settlers()` is governed by the "Settlement lookup" section below.
  Base-table reads carry no promise beyond the data dictionary's columns.
- **Extension points are values, not DDL.** New `node_type`, `edge_type`,
  `assertion_type`, and property keys need no migration.
- **Authorization is session variables**: `app.current_role`,
  `app.current_user_id`, `app.current_teams`, set in the same statement as
  the query when the connection is pooled. Nothing else authorizes.

## Versioning

Applied migrations are recorded by filename in `public.rye_migrations`. A
client asks `rye_catalog()` what exists rather than assuming a version.
Migrations are forward-only and additive: a new numbered file may add tables,
columns, views, functions, and overloads, and an applied file is never
edited. Removing or renaming an object, narrowing a function signature, or
changing a view's column meaning is breaking and requires a decision record
and an edit here first. There are no down migrations.

## Freshness

Synchronous within the transaction: a helper's effect is visible to the next
statement on the same connection. Two exceptions — profile materialized views
are stale until `refresh_materialized_views()` runs, and CDC events only
exist for tables passed to `track_table()`.

## Failure behavior

- A refused write raises, and clients surface the message rather than
  retrying. Refusals are load-bearing: teams without a classification, an
  assertion without evidence when basis is not `assumed`, a supersession
  across subjects, a term outside the scope's enabled plugins.
- RLS failures are silent by construction: an invisible node yields zero rows,
  not an error, so a client reading zero rows must not conclude the row is
  absent. `INSERT ... RETURNING` on RLS-protected tables fails; use the helper.
- No path in this contract deletes an event or mutates an accepted assertion
  in place.

## Settlement lookup

`rye_settlers()` answers one question: who may settle this claim. It is
read-only and advisory. Nothing in the write path calls it, it grants nothing,
and a caller that ignores it is refused nothing. Published by **schema**,
consumed by **agent-kit** (before an agent records a statement as accepted) and
by **admin**.

```
rye_settlers(
    p_subject_id   uuid,
    p_claim_type   text,
    p_speaker_id   uuid        DEFAULT NULL,
    p_speaker_ref  text        DEFAULT NULL,
    p_domain_key   text        DEFAULT NULL,
    p_speech_act   text        DEFAULT NULL,
    p_as_of        timestamptz DEFAULT now(),
    p_scope_ref    text        DEFAULT NULL
) RETURNS jsonb
```

`SECURITY INVOKER`, never `DEFINER`, so RLS applies to the caller. It declares
its own `SET search_path`. It writes nothing, not even an audit row.

- `p_claim_type` is the kind of claim, and it is the claim's `assertion_type`.
  The same value is matched against `domain_authorities.claim_types`. One
  vocabulary, no mapping table, no new values to register.
- **Claim types resolve through aliases first.** When `p_claim_type` is given
  it is resolved with `canonical_type('assertion_type', ...)` before anything
  is tested, and every value in a grant's `claim_types` is resolved the same
  way before it is compared. Rules and grants are therefore written against
  either spelling: where `requirement` is registered as an alias of
  `expectation`, a grant naming `requirement` matches a call passing
  `expectation`, and a call passing `requirement` selects the `expectation`
  rule. This is the alias mechanism the rest of the schema already uses, not a
  second one. A null `p_claim_type` stays null and is not resolved.
- `p_subject_id` may be null for a topical claim with no subject node (pricing,
  brand). The relationship step is then skipped.
- `p_speech_act` is the speaker's classification of the statement. It selects
  which relationship default applies. It is a different vocabulary from
  `domain_authorities.speech_acts`, which lists what a grant holder may do
  (`confirmed`, `approved`, `decided`, `policy_set`) and is returned per settler
  as `settles_acts`.
- `p_speaker_ref` carries a source identity such as `slack:U0123` when the
  speaker has no person node. It is how an unbound channel identity is checked
  against a grant that names it.
- `p_as_of` reconstructs a past answer. It filters effective windows only.

### Answer shape

Top level: `contract_version` (integer, `1`), `step`, `settlers`,
`settler_count`, `speaker`, `subject`, `claim`, `domain`, `as_of`, `advisory`
(boolean, always `true` at this version), `excluded_agents` (integer),
`setup_gap` (boolean), `reason` (text or null).

`step` is `grant`, `relationship`, `area_owner`, or `none`, naming the first
step that produced a settler. `settlers` is empty exactly when `step` is `none`.

`reason` is null when a step produced a settler, and one of the values below
when none did. It is typed `text`, not an enum, and it may gain values
additively. A caller branches on the values it knows and treats an unrecognised
one as "no settler, no further detail".

| `reason` | Returned when |
|---|---|
| `domain_not_found` | `p_domain_key` was supplied and no active area has that key. |
| `domain_not_resolved` | No `p_domain_key` was supplied and none could be inferred, so `mode` is `ambiguous` or `none`. |
| `area_has_no_owner` | The area resolved and its `owner_node_id` is null. |
| `area_owner_not_visible` | The area names an owner and that node is archived or hidden by RLS from this caller. |
| `area_owner_is_agent` | The area names an owner and that owner is an agent identity, which is never a settler. |
| `no_settler_found` | `step` is `none` and no more specific reason applies. Read it as the generic "nobody". |

`setup_gap` is true for exactly two of them, `area_has_no_owner` and
`area_owner_is_agent`. Both say the area exists and its ownership was never
set up properly, which is work for a Rye admin. The two domain reasons are not
setup gaps. `domain_not_found` and `domain_not_resolved` mean the caller
supplied a wrong or ambiguous area key, and the correction belongs to the
caller, not to the instance. `area_owner_not_visible` is neither: the setup may
be complete and this caller simply cannot see it.

Each settler carries `kind`, `node_id`, `ref`, `label`, `via`, `relationship`,
`bound`, and the evidence of where it came from:

- `kind` is `person`, `team`, `role`, `system`, `source`, or `other`. A grant
  settler uses `authority_kind` verbatim. A settler derived from a node maps
  `node_type`: `person` to person, `team`/`department` to team, `role` to role,
  `system` to system, anything else to `other`.
- `node_id` is null when the ref resolves to no node or to a node RLS hides.
  `ref` is `authority_ref` for a grant settler, and for a node-derived settler
  `<external_source>:<external_id>` when both exist, else null. `label` is the
  node's label or null.
- `via` equals `step` for every row in one answer. `relationship` is `self`,
  `manager`, or `owner`, and null unless `via` is `relationship`.
- `bound` is false for `kind` `source` and for any settler whose `node_id` is
  null. A caller must not treat an unbound settler as a person record.
- A grant settler also carries `grant_id`, `claim_types`, `settles_acts`,
  `scope_ref`, `effective_at`, `effective_to`. A relationship settler carries
  `edge_id` and `edge_type`. An area-owner settler carries `domain_id`.

Order: grant settlers by `kind` then `ref`; relationship settlers `self`,
`owner`, `manager`; the area owner is a single row.

`speaker` is `{speaker_id, speaker_ref, speaker_found, is_settler}`.
`is_settler` is true when a returned settler matches `p_speaker_id` by
`node_id` or `p_speaker_ref` by `ref`. It is the field the agent acts on: true
means record it as accepted, false means record a suggestion and ask the
settlers listed. `subject` is `{subject_id, subject_found, node_type, label}`.
`claim` is `{claim_type, assertion_type, canonical_claim_type, speech_act,
speech_act_recognized}`. `claim_type` and `assertion_type` are the value as
given. `canonical_claim_type` is what it resolved to, and it equals the given
value when no alias applies. It is additive: a caller that ignores it sees no
change.
`domain` is `{requested_domain_key, domain_id, domain_key, domain_found, mode,
has_owner}`, where `mode` is `explicit`, `single_active`, `ambiguous`, or
`none`.

### An unknown area key stops the lookup

When `p_domain_key` is supplied and names no active area, the answer is `step`
`none`, `settlers` `[]`, `domain_found` false, and `reason` `domain_not_found`.
No step runs. The grant step is skipped because there is no area to read grants
from, and the relationship step is skipped too, so even the zero-setup self
default is suppressed.

That is deliberate, and it is the one place the lookup answers less than it
could. A key that names nothing is a caller mistake, and the safe response to a
mistake is to fail closed. The caller sees no settler, `is_settler` false, and
records a suggestion rather than accepting a statement against an area nobody
meant. A caller that wants the relationship defaults passes no area key at all.

### The three steps

**1. Grant.** The domain resolves first, as step 3 describes. When no domain
resolves, no grant can match and the lookup falls to the relationship step.
Rows in `domain_authorities` for the resolved domain where
`active`, `effective_at <= p_as_of`, `effective_to` is null or later, and
`claim_types` is empty (meaning every claim type) or contains the claim type.
That containment is tested on canonical values: every entry in `claim_types` is
resolved through `canonical_type('assertion_type', ...)` and compared with the
resolved `p_claim_type`, so a grant written against an alias and a call passing
the canonical type match each other, in either direction.
Scope matches when the row's `scope_ref` is null, or `p_scope_ref` is null, or
the two are equal. Subject narrowing is expressed in `properties`, never in a
new column: `properties.subjects` (array of node uuids or refs) and
`properties.subject_node_types` (array of node types). When either key is
present and non-empty the row matches only a subject named in it; absent keys
mean the grant covers every subject in the domain. If any row matches, `step`
is `grant` and the relationship step does not run. That is how a grant narrows
a default as well as adds to one: a grant for a claim type displaces self,
manager, and owner for that claim type in that domain, so a grant that should
not displace them names its subjects.

**2. Relationship.** Runs only when no grant matched and the subject node is
visible. Two selectors choose the default, the claim type first and the speech
act second. The rules are tried in this order, and the first that applies wins:

| # | Condition | Relationship default |
|---|---|---|
| 0 | `p_claim_type` is a relationship edge type: `reports_to`, `owns` | none, fall through |
| 1 | The canonical claim type is other-set, or `p_speech_act` is `expectation` | manager only. Self is never returned |
| 2 | `p_speech_act` is recognized | `self_commitment`, `self_report`: self when the canonical claim type is self-set, otherwise none, fall through. `statement_about_other`: the subject's manager, and the subject as well when the canonical claim type is self-set. `statement_about_thing`: owner. `agreement`, `decision`, `outside_report`, `agent_inference`: none, fall through |
| 3 | The canonical claim type is self-set | self only |
| 4 | Otherwise | none, fall through |

**The subject is returned only when the claim type is positively known to be
one a person settles about themselves.** That is the governing rule, and the
table is its consequence. Membership in the self set is the only thing that
makes the subject its own settler. No speech act does it on its own.
`self_commitment` on a claim type nobody has declared self-settled returns
nobody, not the subject. Unknown is restrictive.

*Other-set* claim types are claims one person sets on another. The core set is
`expectation`. *Self-set* claim types are ones a person settles about
themselves. The core set is `commitment`, `self_commitment`, `self_report`.
Both are tested on the canonical claim type, after alias resolution.

The self set is extensible as data, not code. A registry entry with the key
`self_settled_type:<canonical assertion type>` and the jsonb value `true` adds
a member. It is read with `registry_value()`, the same way `type_alias` entries
are read, so it is an accepted assertion of type `registry_entry` and it obeys
scope the same way. Any other value, including `false` and null, is not a
member. The type in the key is the canonical one: an alias is registered as an
alias, not as a second self-settled entry. The core members above need no
registry row, so a fresh instance works with none. Plugin manifests cannot
contribute self-settled types today, because `contributes` in
`plugins/rye-plugin.schema.json` is a closed object; adding them is a manifest
schema change and is not promised here.

**Blindness is always restrictive.** A caller who cannot see an alias, a
self-settled registry entry, or the assertion that carries one gets the answer
for a claim type it cannot classify. That answer is never the subject. RLS
hides a configuration row from one role and not another, and a candidate
registry entry is invisible until it is accepted, so two callers can classify
the same claim type differently. The difference can only ever cost a caller
settlers, never grant them. An authority answer never widens because a
configuration row happened to be visible.

Matching is case-sensitive, and resolution does not fold case. `Expectation`
with no alias registered for it is a different type and is in neither set, so
it takes the restrictive branch and falls through to the area owner. The fix is
an alias, the same fix the rest of the schema uses for a spelling: register
`type_alias:assertion_type:Expectation` and it resolves like any other.

An alias cycle raises, exactly as `canonical_type()` raises. The lookup does
not swallow it and does not fall back to the raw string. A cycle is a broken
registry, not a missing answer, and it is the one input to this read that
produces an error rather than an answer.

Rule 1 is the point of the ordering. An expectation is set on a person by
someone else, so the person it is set on is never its settler, whatever the
speech act says. A missing speech act cannot open that door, and neither can a
wrong one.

Rule 4 is the other point. A null or unrecognized speech act never widens who
may settle. It selects no relationship default at all, exactly as `agreement`
does, and the lookup falls through to the area owner. The union of self, owner,
and manager is not returned, and the caller gets a smaller answer for saying
less, not a larger one.

What this costs is worth stating. A person whose agent invents a claim type
about them, or spells a known one differently, no longer settles it themselves.
It goes to the area owner. For a lone person that owner is themselves once
their first area exists, so the cost is nothing. On a team it is one question
to the area owner, and the answer is a `self_settled_type` registry entry that
settles every later claim of that type. A claim of a core self type still
settles with no registry rows and no area at all.

`speech_act_recognized` is false for a value outside the recognized set, and no
error is raised. A caller must not record a statement as accepted while
`speech_act_recognized` is false. Classify the statement first, pass the speech
act, and look again. The same obligation applies when the answer falls through
to the area owner because rule 4 applied: that answer says nobody local was
selected, not that the speaker may proceed.

Self means the subject is a person node and is its own settler. Manager is the target of a `reports_to` edge whose source is
the subject. Owner is the source of an `owns` edge whose target is the subject.
Both edges are read as `contracts/plugin-manifest.md` declares them, and in
effect at `p_as_of` means `archived_at` is null, `effective_from` is null or at
or before it, and `effective_to` is null or after it. A claim type that names a
relationship edge type (`reports_to`, `owns`) has no relationship default and
falls through: the reporting line is settled by the owner of the area, not by
either end of it.

### What the lookup does not answer

It reads no standing claim. It cannot see that a claim on this subject is
already accepted, so it cannot tell a new statement from a contradiction of an
old one. One case follows, and it is not solved here. A person restates or
contradicts an accepted claim about themselves of a self-set type that somebody
else authorized. The lookup returns that person as a settler, correctly, and
nothing in the answer says an accepted claim is already standing.

That is the objection path, and it is a later work item. Accepted stays
accepted until a settler changes it, and an objection is a record of its own,
not an overwrite. Until that work exists, a caller must not read `is_settler`
true as permission to replace an accepted claim it did not check for. This
lookup answers who may settle a claim. It does not answer who may unsettle one.

A caller that does check for a standing accepted claim before replacing one
compares canonical types, not raw strings. Resolve both sides with
`canonical_type('assertion_type', ...)` and compare those. An assertion stored
under `requirement` and a claim passed as `expectation` are the same claim when
one is an alias of the other, and a caller comparing the spellings would miss
it and overwrite silently.

**3. Area owner.** `knowledge_domains.owner_node_id` for the resolved domain,
returned as a single settler with `via` `area_owner`. When `owner_node_id` is
null the answer is `settlers: []`, `step` `none`, `reason` `area_has_no_owner`,
`setup_gap` true. That is a setup gap for a Rye admin, not an error. The domain
resolves from `p_domain_key`, slugified (`mode` `explicit`); when `p_domain_key` is null
and exactly one active knowledge domain exists, from that one (`single_active`);
otherwise `mode` is `ambiguous` or `none` and `reason` is
`domain_not_resolved`.

**Agents are never settlers.** Before any step selects a winner, every
candidate is tested and an agent is dropped. The test applies to grant settlers
and to node-derived settlers alike: self, the owner of a thing, the manager,
and the area owner. A candidate is an agent when its ref says so, when its ref
names a stored agent identity, when the grant's `authority_kind` is `agent`, or
when the node's `node_type` is `agent` or its `attrs->>'actor_kind'` is `agent`.
A grant whose only holder is an agent is therefore not a match, and the lookup
proceeds to the relationship step. `excluded_agents` counts what was dropped, so
a caller can tell the difference between nobody and nobody eligible. When the
area owner is the one dropped, the answer is `step` `none`, `reason`
`area_owner_is_agent`, `setup_gap` true. Ref matching is spelled out under
"Area keys and agent keys are slugs".

### Area keys and agent keys are slugs

`rye_slugify_key()` defines both. It lowercases the value, replaces every run
of characters outside `a-z0-9` with a single underscore, strips leading and
trailing underscores, and yields null for an empty result.

`ensure_knowledge_domain()` stores the slug, and `rye_settlers()` slugifies
`p_domain_key` before looking the area up. So `sales-operations`,
`Sales Operations`, and `sales_operations` are one key, and either form works
as an argument. The consequence is that a `knowledge_domains` row written
directly with a hyphenated key is invisible to this lookup: no argument
slugifies to `sales-operations`, so that row can never be found and every call
naming it answers `domain_not_found`. Create areas with
`ensure_knowledge_domain()`, never by direct insert.

The same rule governs agent keys, and the agent test is written to survive it.
`create_agent_identity()` slugifies `agent_key`, so the stored key for
`my-agent` is `my_agent`. Two promises follow.

First, a ref that says it is an agent never settles. A ref is an agent prefix
when, reading from the start, it has only whitespace, then the letters `agent`
in any case, then only whitespace, then a colon. Whatever follows the colon is
irrelevant, and no `agent_identities` row need exist. `agent:my-agent`,
`Agent:my_agent`, ` agent :x`, and `agent:deleted-last-year` are all dropped. A
typo or a removed identity produces no settler rather than an accidental one.

Whitespace here is wider than SQL `trim()`, which strips the plain space only.
Space, tab, CR, LF, form feed, vertical tab, and the non-breaking space U+00A0
are stripped from both ends of every ref and ignored on either side of the
colon. `agent` is read as a whole word before the colon, so `person:my-agent`
is not an agent prefix. Unicode lookalike letters are out of scope: a ref whose
`a` is Cyrillic is not an agent prefix, and it comes back as an unbound settler
like any other unrecognised ref. The same test runs on node-derived refs, not
only on grant refs.

Second, any other ref is an agent when `rye_slugify_key()` of the ref equals a
stored `agent_key`. So `my-agent`, `My Agent`, and `my_agent` are one agent,
and a ref in any spelling is excluded. An inactive agent identity is still an
agent: the `active` flag is not consulted, and a retired agent does not become
a settler by being retired.

Every candidate dropped by either rule is counted in `excluded_agents`, and the
lookup continues to the next step rather than stopping. Write refs against the
stored slug anyway; the matching is forgiving, the rest of the schema is not.

### Versioning, freshness, failure

Additive: new top-level keys, new settler keys, and new `p_speech_act` values
may appear at any time, and callers ignore keys they do not know. Removing or
renaming a key, changing the meaning of `step`, `via`, `kind`, or `mode`, or
making the lookup enforcing rather than advisory is breaking: decision record
and an edit here first, and `contract_version` increments only then.

Computed on read from live rows. No cache, no snapshot, no materialized view. A
grant written earlier in the transaction is visible to the next call. `p_as_of`
filters effective windows only, so a row inserted today with today's
`effective_at` is invisible to an earlier `as_of`, and an archived node or edge
is excluded at every `as_of`.

Nothing here raises for a missing answer. An unknown or invisible subject gives
`subject_found` false with the relationship step skipped. An unknown area key
gives `domain_found` false, `step` `none`, `reason` `domain_not_found`, and no
step runs at all, as above. A
non-uuid argument fails at cast time. Because RLS silence applies, an empty
`settlers` never means nobody is authorized; it means nobody is authorized and
visible to this caller, and a caller must not record a claim as accepted on
that basis.
