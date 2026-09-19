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
  `agent_node_summary()`, `rye_current_agent_key()`, `rye_current_agent_id()`,
  and the views above. `rye_categories()` has its own
  contract, `contracts/category-vocabulary.md`, which governs its jsonb shape;
  `rye_settlers()` is governed by the "Settlement lookup" section below.
  Base-table reads carry no promise beyond the data dictionary's columns.
- **Extension points are values, not DDL.** New `node_type`, `edge_type`,
  `assertion_type`, and property keys need no migration.
- **Authorization is session variables**: `app.current_role`,
  `app.current_user_id`, `app.current_teams`, set in the same statement as
  the query when the connection is pooled. Nothing else authorizes. What each
  role may read and write in the governance tables is the section "Governance
  tables: who reads, who writes" below.

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

## Governance tables: who reads, who writes

Nine tables say which areas exist, who holds authority in them, which channels
feed them, which agents exist, what each agent may do, and what each agent did:
`knowledge_domains`, `domain_authorities`, `channel_domain_subscriptions`,
`domain_claim_policies`, `agent_identities`, `agent_capability_grants`,
`agent_action_log`, `api_idempotency_keys`, `agent_api_tokens`. Row-level
security is enabled and forced on all nine. They are the only base tables whose
visibility this contract promises; for every other table "Shape" still stands
and a client reads what the data dictionary lists, filtered by node visibility.

This section narrows what some sessions could read before. It bumps no version:
no object is removed or renamed, no signature narrows, no view column changes
meaning, and `rye_settlers()` stays at `contract_version` 1 because its answer
shape is untouched. It is recorded in `docs/decisions/0007-agent-governance-visibility.md`
because clients that read these tables without setting a role will start reading
zero rows.

### Four session shapes

`app.current_role` decides. Nothing else decides — not `current_user`, not
`pg_has_role()`, not the bearer token, which only chooses what the API puts in
`app.current_role`.

| shape | matched when `app.current_role` is |
|---|---|
| **admin** | `admin` |
| **named role** | any value equal to a `role_classification_access.role_name`: at install `admin`, `manager`, `deal_manager`, `team_lead`, `hr_admin`, `finance`, `team_member`, `viewer`. `admin` matches here too and always takes the wider branch. |
| **agent** | `agent:<agent_key>`, where `<agent_key>` is the stored key of an `agent_identities` row with `active` true |
| **unknown** | anything else, including unset, and `agent:<key>` naming no active identity |

A new role is a row in `role_classification_access`, not an edit to a policy.
That table is already the instance's role list and already readable by every
session, which is why it and not a hardcoded list is the definition here.

Two published read-only helpers are the only definition of the agent match, so
a verifier can assert it directly: `rye_current_agent_key() RETURNS text` gives
the part after `agent:` when `app.current_role` has that form and null
otherwise, and `rye_current_agent_id() RETURNS uuid` gives the `agent_identities.id`
of the active row with that key and null otherwise. Both are `STABLE` and read
`app.current_role` alone. **Own rows** below always means
`agent_id = rye_current_agent_id()`, which is null for every non-agent shape, so
no non-agent session owns anything. `app.current_user_id` carries the same
`agent:<key>` string by convention and is not authoritative for any rule here.

The key must be the stored slug. `agent:my-agent` names no identity whose stored
key is `my_agent`, so that session is **unknown**, not an agent — the same trap
as "Area keys and agent keys are slugs" below, and the same fix: write the ref
against the stored slug.

### Holding an area

An agent **holds** an area when it has a row in `agent_capability_grants` with
`active` true, `expires_at` null or in the future, and `domain_id` either equal
to that area or null. A null `domain_id` is an instance-wide grant and holds
every area, which is what `has_agent_capability()` already means by it. The
capability name is not part of the rule: any grant holds the area for reading
that area's governance rows. This is deliberately wider than the capability
filter the agent functions apply to their own answers, so RLS never subtracts
from what `agent_get_context_pack()` would have returned.

### The rules

| table | admin | named role | agent session | unknown |
|---|---|---|---|---|
| `knowledge_domains` | read all; insert, update, delete | read all | read areas it holds | nothing |
| `domain_authorities` | read all; insert, update, delete | read all | read rows of areas it holds | nothing |
| `channel_domain_subscriptions` | read all; insert, update, delete | read all | read rows of areas it holds | nothing |
| `domain_claim_policies` | read all; insert, update, delete | read all | read rows of areas it holds | nothing |
| `agent_identities` | read all; insert, update, delete | read all | read all | nothing |
| `agent_capability_grants` | read all; insert, update, delete | nothing | read own rows | nothing |
| `agent_action_log` | read all; insert only | nothing | read own rows | nothing |
| `api_idempotency_keys` | read all; insert, delete | nothing | read own rows | nothing |
| `agent_api_tokens` | read all; insert, update, delete | nothing | nothing | nothing |

Four rules sit behind that table and are worth stating in words.

**The whole agent roster is readable by every session that can see anything
else.** `agent_identities` carries no secret — tokens live in
`agent_api_tokens`, permissions in `agent_capability_grants` — and it is the
deny-list for the one rule the settlement model rests on, that an agent is never
a settler. A deny-list some callers cannot read is a deny-list that fails open.
Its read set is therefore a superset of the read set of `knowledge_domains` and
`domain_authorities`, and that superset is the promise: any session that can see
a grant or an area can see the roster that filters agents out of it.

**Capability grants, tokens, and the action log are admin-only for reads other
than an agent's own.** They are the instance's security configuration and its
audit trail; a `team_lead` has no more business reading which capabilities an
agent holds than reading `access_grants` it is not party to. An agent reads its
own grants and its own log rows so it can see what it may do and what it did,
and reads no other agent's.

**`agent_action_log` is append-only for everyone, admin included.** No session
updates or deletes a row, exactly as `events` and `assertion_evidence` are
treated. An admin who could edit the log could erase the record of its own
grants. There is no pruning path today; adding one is a new migration and an
edit here first.

**`api_idempotency_keys` is a cache, not a record**, so admin may delete expired
rows. An agent reads its own rows because `agent_create_candidate()` must find
its own prior response; if it could not, a retried call would silently create a
second candidate instead of returning the first.

### Writes go through the helpers, and the policies are what enforce it

`ensure_knowledge_domain`, `subscribe_channel_to_domain`, `grant_domain_authority`,
`create_agent_identity`, and `grant_agent_capability` keep their signatures and
stay `SECURITY INVOKER` with no role check in the body. What makes them
admin-only is the admin-only write policy on the table each one writes, which is
the same rule that governs a direct `INSERT`, so there is one rule in one place
and no second authorization model to drift. An admin may equally write these
tables directly, and should not: the helpers slugify keys, and a row inserted
with a hyphenated key is unreachable by every lookup.

Two writes are made on behalf of a caller who is not an admin, and both use the
established named-gate mechanism — `app.write_path` set transaction-locally by
the function, immediately around its own statement, and cleared after, because a
nested helper clears it:

| write | gate the policy admits |
|---|---|
| `record_agent_action()` inserting into `agent_action_log` | `app.write_path = 'record_agent_action'` |
| `agent_create_candidate()` inserting into `api_idempotency_keys` | `app.write_path = 'agent_create_candidate'` |

As everywhere else the gate is used, it is a guard rail and a seam for trusted
layers, not a boundary: a session with direct SQL can set it itself. It grants
nothing if it does — nothing reads the action log to authorize anything, and an
idempotency row only ever returns a response to the agent that owns it.

### SECURITY DEFINER does not bypass these policies

Under `FORCE ROW LEVEL SECURITY` with an owner that is not a superuser, which is
the Supabase case and the one that must hold, a `SECURITY DEFINER` function is
still subject to every policy, evaluated with the caller's session variables,
because `app.current_role` is session state and the function does not change it.
So marking a function `DEFINER` buys nothing here and no function is made
`DEFINER` to solve visibility. The agent functions keep working by exactly the
two mechanisms the schema already uses: the rows they must read are readable to
the session that calls them (as `field_classifications`, `assertion_type_access`,
and `role_classification_access` are readable to every session for the sake of
`redact_properties()`), and the rows they must write are admitted by a named
gate. Concretely:

- `has_agent_capability`, `authorize_agent_action`, `agent_get_context_pack`,
  `agent_submit_observation`, and `agent_create_candidate` read the roster and
  the caller's own grants, both of which an agent session can see, and the area
  tables for areas it holds, which is wider than their own capability filter.
  For a valid agent asking about itself the answers are unchanged.
- The same four asked about **another** agent's id answer as if that agent held
  nothing: `has_agent_capability` and `authorize_agent_action` return false
  rather than raising, and the three that check a capability first raise
  `42501` and log the denial. An admin session still gets the true answer for
  any agent id, which is the path the Worker uses.
- `record_agent_action` works from any session through its gate, so a denial is
  logged even when the caller was impersonating. The audit trail is never
  suppressed by the thing it audits.
- `authenticate_agent_token`, `issue_agent_token_record`, `issue_agent_token`,
  and `revoke_agent_token` require an **admin** session, because
  `agent_api_tokens` is admin-only. A non-admin gets null from
  `authenticate_agent_token` and false from `revoke_agent_token`, not an error.
  Exchanging a token is the trusted layer's job; the Worker already sets
  `app.current_role` to `admin` in the same statement.

### What a refusal looks like

Refusals here are not uniform, and a test that asserts the wrong one passes for
the wrong reason:

- A refused `INSERT` **raises** `42501`, `new row violates row-level security policy`.
- A refused `UPDATE` or `DELETE` **raises nothing** and affects zero rows. Assert
  the row count, not an exception.
- A refused `SELECT` returns zero rows. RLS silence applies as everywhere else:
  zero rows never means the row is absent.
- A helper that looks a row up before writing it may refuse first with its own
  message — `subscribe_channel_to_domain` raises `Knowledge domain % not found`
  for an area the session cannot see. Either refusal is a refusal; the message
  is not part of this contract.

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

### Who may call it, and what each caller sees

It stays `SECURITY INVOKER`, so the session shapes in "Governance tables" decide
what it can find. The signature and the answer shape are the same for all of
them; the content is not.

| caller | what it gets |
|---|---|
| admin | every answer this document describes |
| named role | the same answers: it reads every area and every grant, and node-derived settlers are filtered by node visibility as they always were |
| agent | narrowed to the areas it holds. An area it holds no grant on is invisible, so the answer is `step` `none`, `settlers` `[]`, `domain_found` false, `reason` `domain_not_found` — the same answer as for an area key that names nothing, and deliberately indistinguishable from it. An area is not a thing an agent gets told exists. |
| unknown | no area resolves and no grant is visible, so only the relationship step can produce anything, from nodes it can see |

**The agent exclusion cannot fail open where it can matter.** The ref half of
the check reads `agent_identities`, and the roster is readable by every shape
that can read `knowledge_domains` or `domain_authorities`. So any caller that
can produce a grant settler or an area-owner settler — the two kinds whose ref
comes from a governance table — can also evaluate the ref against the roster. A
session that cannot read the roster is a session for which no area resolves and
no grant is visible, so it reaches neither step. The node half of the check
(`node_type` `agent`, `attrs->>'actor_kind'` `agent`) needs no governance read at
all and applies to every caller, which is what covers relationship settlers. An
agent that exists as a node is expected to carry one of those two markings; an
agent node carrying neither and holding no matching `agent_key` is not excluded,
for any caller including admin, exactly as before.

`excluded_agents` counts what this caller dropped, so two callers can see
different counts for the same claim. That is visibility, not disagreement.

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
| `domain_not_found` | `p_domain_key` was supplied and no active area has that key, or this caller cannot see the one that does. The two are not distinguishable, on purpose. |
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
`claim` is `{claim_type, assertion_type, speech_act, speech_act_recognized}`.
`domain` is `{requested_domain_key, domain_id, domain_key, domain_found, mode,
has_owner}`, where `mode` is `explicit`, `single_active`, `ambiguous`, or
`none`.

### An unknown area key stops the lookup

When `p_domain_key` is supplied and names no active area this caller can see,
the answer is `step` `none`, `settlers` `[]`, `domain_found` false, and `reason`
`domain_not_found`. No step runs. The grant step is skipped because there is no area to read grants
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
resolves from `p_domain_key`, slugified (`mode` `explicit`); when `p_domain_key` is null
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

The same rule governs agent keys. `create_agent_identity()` slugifies
`agent_key`, so the stored key for `my-agent` is `my_agent`. A grant whose
`authority_ref` is `agent:my-agent` therefore matches no agent identity. It is
not recognised as an agent, it is not counted in `excluded_agents`, and it is
returned as an ordinary settler. Write refs against the stored slug.

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
