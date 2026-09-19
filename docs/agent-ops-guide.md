# Rye Agent Operations Guide

## Start a session

All objects live in `rye`.

```sql
SET search_path = rye, public, pg_catalog;
SET LOCAL "app.current_user_id" = 'user:alice';
SET LOCAL "app.current_teams" = 'engineering,sales';
SET LOCAL "app.current_role" = 'team_member';
```

Supabase calls use a fresh connection. Put equivalent `set_config()` calls in
the same request as the query.

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
a claim like any other: `registry_entry` is Rye's own configuration and only a
Rye admin settles it. See "Rye's own setup needs an admin" below. The core
members need no entry.

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

### Rye's own setup needs an admin

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
and key.

Use `schedule_assertion_change()` for future-effective replacements.
Operational views continue returning the current assertion until the cutover.

Use `record_distillation()` for a digest. It requires source assertions,
writes derivation evidence, propagates classification, stores a watermark, and
records a distillation event. It rejects mixed-access source sets.

Use `resolve_knowledge_gap()` to close an accepted `knowledge_gap` with an
answer assertion. It creates a resolved version on the gap's own tuple.

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

## Other safe writes

- Use `link_record()` to connect a domain row to a graph node.
- Use `track_table()` to capture linked domain-row changes.
- Use `update_node_properties()` only when the node itself is the system of
  record. Update the domain table otherwise.
- Use `record_artifact()` for artifacts and optional content-hash deduplication.
- Use `log_agent_query()` to audit agent reads.
- Use `type_vocabulary_report` and the Rye gardener skill to propose aliases or
  merges. The gardener never calls `merge_nodes()` directly.
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
