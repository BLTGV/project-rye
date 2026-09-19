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

- `p_claim_type` is the kind of claim, and it is the claim's `assertion_type`
  verbatim. The same string is matched against `domain_authorities.claim_types`.
  One vocabulary, no mapping table, no new values to register.
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
`claim` is `{claim_type, assertion_type, speech_act, speech_act_recognized}`.
`domain` is `{requested_domain_key, domain_id, domain_key, domain_found, mode,
has_owner}`, where `mode` is `explicit`, `single_active`, `ambiguous`, or
`none`.

### The three steps

**1. Grant.** The domain resolves first, as step 3 describes. When no domain
resolves, no grant can match and the lookup falls to the relationship step.
Rows in `domain_authorities` for the resolved domain where
`active`, `effective_at <= p_as_of`, `effective_to` is null or later, and
`claim_types` is empty (meaning every claim type) or contains `p_claim_type`.
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
visible. The speech act selects the default:

| `p_speech_act` | relationship default |
|---|---|
| `self_commitment`, `self_report` | self |
| `expectation` | manager |
| `statement_about_other` | the subject, then the subject's manager |
| `statement_about_thing` | owner |
| `agreement`, `decision`, `outside_report`, `agent_inference` | none, fall through |
| null or unrecognized | the union of self, owner, and manager, whichever apply |

`speech_act_recognized` is false for a value outside that set, and the union is
returned rather than an error. Self means the subject is a person node and is
its own settler. Manager is the target of a `reports_to` edge whose source is
the subject. Owner is the source of an `owns` edge whose target is the subject.
Both edges are read as `contracts/plugin-manifest.md` declares them, and in
effect at `p_as_of` means `archived_at` is null, `effective_from` is null or at
or before it, and `effective_to` is null or after it. A claim type that names a
relationship edge type (`reports_to`, `owns`) has no relationship default and
falls through: the reporting line is settled by the owner of the area, not by
either end of it.

**3. Area owner.** `knowledge_domains.owner_node_id` for the resolved domain,
returned as a single settler with `via` `area_owner`. When `owner_node_id` is
null the answer is `settlers: []`, `step` `none`, `reason` `area_has_no_owner`,
`setup_gap` true. That is a setup gap for a Rye admin, not an error. The domain
resolves from `p_domain_key` (`mode` `explicit`); when `p_domain_key` is null
and exactly one active knowledge domain exists, from that one (`single_active`);
otherwise `mode` is `ambiguous` or `none` and `reason` is
`domain_not_resolved`.

**Agents are never settlers.** Before any step selects a winner, candidate
settlers are dropped when the ref equals an `agent_identities.agent_key` or is
`agent:<agent_key>` of one, or the node's `node_type` is `agent` or its
`attrs->>'actor_kind'` is `agent`. A grant whose only holder is an agent is
therefore not a match, and the lookup proceeds to the relationship step.
`excluded_agents` counts what was dropped, so a caller can tell the difference
between nobody and nobody eligible.

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
`subject_found` false with the relationship step skipped. An unknown domain key
gives `domain_found` false, `step` `none`, `reason` `domain_not_found`. A
non-uuid argument fails at cast time. Because RLS silence applies, an empty
`settlers` never means nobody is authorized; it means nobody is authorized and
visible to this caller, and a caller must not record a claim as accepted on
that basis.
