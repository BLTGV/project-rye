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
  `settle_gate()`, `agent_node_summary()`, `rye_current_agent_key()`,
  `rye_current_agent_id()`, and the views above. `rye_categories()` has its own
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
  across subjects, a term outside the scope's enabled plugins, an accepted
  configuration assertion from a caller who is not a Rye admin.
- RLS failures are silent by construction: an invisible node yields zero rows,
  not an error, so a client reading zero rows must not conclude the row is
  absent. `INSERT ... RETURNING` on RLS-protected tables fails; use the helper.
- No path in this contract deletes an event or mutates an accepted assertion
  in place.
- Some refusals arrive at `COMMIT` rather than at the statement. See "The row
  is the gate, not the route".

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

### Session shapes

`app.current_role` decides. Nothing else decides — not `current_user`, not
`pg_has_role()`, not the bearer token, which only chooses what the API puts in
`app.current_role`.

| shape | matched when `app.current_role` is |
|---|---|
| **admin** | `admin` |
| **named role** | any value equal to a `role_classification_access.role_name`: at install `admin`, `manager`, `deal_manager`, `team_lead`, `hr_admin`, `finance`, `team_member`, `viewer`. `admin` matches here too and always takes the wider branch. |
| **agent-shaped** | `agent:<key>` for any non-empty `<key>`, whether or not an identity by that key exists |
| **bound agent** | `agent:<agent_key>` where `<agent_key>` is the stored key of an `agent_identities` row with `active` true. Every bound agent is agent-shaped. |
| **unknown** | anything else, including unset |

A new role is a row in `role_classification_access`, not an edit to a policy.
That table is already the instance's role list and already readable by every
session, which is why it and not a hardcoded list is the definition here.

The two agent shapes are separate because one of them has to be decidable
without reading `agent_identities`; see "Which policy may read which table".
Only one rule uses **agent-shaped**: reading the roster. Everything else — own
rows, holding an area, what the agent functions answer — uses **bound agent**.
The practical effect is that a session can name itself `agent:` anything and
read the secret-free roster, and gets nothing else anywhere.

Two published read-only helpers are the only definition of the match, so a
verifier can assert it directly:

| helper | returns | reads |
|---|---|---|
| `rye_current_agent_key() RETURNS text` | the part after `agent:` when `app.current_role` has that form, else null. Agent-shaped is `rye_current_agent_key() IS NOT NULL`. | `app.current_role` only. No table. Safe in any policy. |
| `rye_current_agent_id() RETURNS uuid` | the `agent_identities.id` of the `active` row whose `agent_key` equals that key, else null. Bound agent is `rye_current_agent_id() IS NOT NULL`. | `agent_identities`, under that table's own read rule. Usable only in policies on tables below `agent_identities` in the order. |

Both are `STABLE`. **Own rows** below always means
`agent_id = rye_current_agent_id()`, which is null for every shape that is not a
bound agent, so nothing else owns anything.

### `app.current_user_id` is a label, not a binding

Which agent a session **is** comes from `app.current_role` and from nowhere
else. `app.current_user_id` is the actor label that helpers write into events,
`created_by`, and audit payloads; it is free text, it is frequently a human or a
test marker, and no rule in this contract reads it. A session whose
`app.current_user_id` names a different agent than its `app.current_role` is
**not** an error and is **not** denied: the label is ignored, and the session is
the agent its role names, or no agent at all.

One function disagreed and is corrected by the same migration, keeping its
signature: `agent_can_promote_in_scope(uuid)` from `0019` resolved the acting
agent from `app.current_user_id` first and fell back to `app.current_role`. It
now resolves through `rye_current_agent_id()` only. The gate that calls it
already fires on `app.current_role LIKE 'agent:%'` alone, so one variable now
decides both whether the rule applies and who it applies to. The narrowing is
the point: before, a session could declare itself `agent:anything` to trip the
gate and then name a capable agent in the label to pass it.

Every other function that touches the governance tables takes the agent as an
explicit `p_agent_id` argument and is unaffected:

| site | reads an agent from | disposition |
|---|---|---|
| `agent_can_promote_in_scope` (0019) | `app.current_user_id`, then `app.current_role` | replaced from the new migration, `rye_current_agent_id()` only |
| `has_agent_capability`, `authorize_agent_action`, `agent_get_context_pack`, `agent_submit_observation`, `agent_create_candidate`, `record_agent_action` (0016) | `p_agent_id` argument | unchanged; the caller's own grants are visible to a bound agent, and admin sees all |
| `authenticate_agent_token`, `issue_agent_token_record`, `revoke_agent_token` (0016) | the token, or `p_agent_key` | unchanged; admin-only, as above |
| `rye_settlers`, `rye_settler_is_agent` (0021) | the roster, by ref | unchanged; agent-shaped and wider can read the roster |
| `record_assertion`, `create_knowledge_candidate`, `describe_category`, `resolve_knowledge_gap`, and the profile helpers (0002, 0009–0012, 0017, 0020, 0100+) | `app.current_user_id` as an actor label only | unchanged; they never resolve an identity or check a capability with it |

A test or client that sets `app.current_role` to `agent:<key>` must use the
stored key of the identity whose grants it expects. Setting the role to one
agent and the label to another is the inconsistency this section resolves, and
it fails closed.

The key must be the stored slug. `agent:my-agent` is agent-shaped but is not a
bound agent when the stored key is `my_agent` — the same trap as "Area keys and
agent keys are slugs" below, and the same fix: write the ref against the stored
slug.

### Which policy may read which table

No policy may read its own table, directly or through a function, and the rule
is not a style preference. Verified on PostgreSQL 16 against a non-superuser
owner with `FORCE ROW LEVEL SECURITY`: a policy whose expression subqueries its
own table raises `infinite recursion detected in policy for relation "..."` at
rewrite time, and a policy that calls a function reading its own table — including
a `SECURITY DEFINER` one owned by the table owner — recurses at run time until
`stack depth limit exceeded`. Neither is catchable in any useful way, and the
second appears only when the policy fires.

So the nine tables are ordered, and a policy may read only tables strictly below
its own level:

| level | tables | its policies may read |
|---|---|---|
| 0 | `role_classification_access`, `assertion_type_access`, `field_classifications` | nothing; readable to every session, which is what earlier migrations already do for `redact_properties()` |
| 1 | `agent_identities` | level 0 and session variables only |
| 2 | `agent_capability_grants`, `agent_action_log`, `api_idempotency_keys`, `agent_api_tokens` | levels 0–1 |
| 3 | `knowledge_domains`, `domain_authorities`, `channel_domain_subscriptions`, `domain_claim_policies` | levels 0–2 |

Reading the chain downward: an area's policy asks `agent_capability_grants`
whether this agent holds it; the grants policy asks `agent_identities` which
identity this session is; the identity policy asks `role_classification_access`
whether this is a named role and `app.current_role` whether it is agent-shaped;
and that table's policy asks nothing. Four levels, no cycle. A level-3 policy
never reads another level-3 table, so the four area tables are independent of
each other.

This is the whole reason the roster's read rule is row-local and key-only rather
than "names an active identity": at level 1 there is nothing left to ask. The
cost is the agent-shaped hole above, and it is small because
`agent_identities` holds a key, a label, a runtime, a default scope, and
properties — no token, no capability, no area.

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

Every row of this table is decidable at its own level of the order above.

| table | admin | named role | bound agent | agent-shaped only | unknown |
|---|---|---|---|---|---|
| `knowledge_domains` | read all; insert, update, delete | read all | read areas it holds | nothing | nothing |
| `domain_authorities` | read all; insert, update, delete | read all | read rows of areas it holds | nothing | nothing |
| `channel_domain_subscriptions` | read all; insert, update, delete | read all | read rows of areas it holds | nothing | nothing |
| `domain_claim_policies` | read all; insert, update, delete | read all | read rows of areas it holds | nothing | nothing |
| `agent_identities` | read all; insert, update, delete | read all | read all | read all | nothing |
| `agent_capability_grants` | read all; insert, update, delete | nothing | read own rows | nothing | nothing |
| `agent_action_log` | read all; insert only | nothing | read own rows | nothing | nothing |
| `api_idempotency_keys` | read all; insert, delete | nothing | read own rows | nothing | nothing |
| `agent_api_tokens` | read all; insert, update, delete | nothing | nothing | nothing | nothing |

`agent_identities` is the only table whose column differs between the last two
agent columns, and it is the only table whose rule is decided without reading a
table at all. A session with no role set still reads zero rows from all nine.

Four rules sit behind that table and are worth stating in words.

**The whole agent roster is readable by every session that can see anything
else.** `agent_identities` carries no secret — tokens live in
`agent_api_tokens`, permissions in `agent_capability_grants` — and it is the
deny-list for the one rule the settlement model rests on, that an agent is never
a settler. A deny-list some callers cannot read is a deny-list that fails open.
Its read set is therefore a superset of the read set of `knowledge_domains` and
`domain_authorities` — admin, named role, and every agent-shaped session, which
includes every bound agent — and that superset is the promise: any session that
can see a grant or an area can see the roster that filters agents out of it.

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
`DEFINER` to solve visibility — including `rye_current_agent_id()`, which
returns null rather than a bypass when the caller cannot read the roster.
The agent functions keep working by exactly the
two mechanisms the schema already uses: the rows they must read are readable to
the session that calls them (as `field_classifications`, `assertion_type_access`,
and `role_classification_access` are readable to every session for the sake of
`redact_properties()`), and the rows they must write are admitted by a named
gate. Concretely:

- `has_agent_capability`, `authorize_agent_action`, `agent_get_context_pack`,
  `agent_submit_observation`, and `agent_create_candidate` read the roster and
  the caller's own grants, both of which a bound agent can see, and the area
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

## Configuration writes need an admin

Some assertion types are not knowledge about the world. They are Rye's own
configuration, and Rye reads them to decide how it treats every other write.
`registry_entry` carries the type aliases and the self-settled type list that
`canonical_type()`, `registry_value()`, and `rye_settlers()` read.
`review_policy` decides whether a write lands accepted at all. A caller who
can set either of those can change every later answer, so only a Rye admin
settles them.

**The gate is data.** `assertion_type_access` gains a third `operation`
value, `settle`, beside `read` and `write`. A row
`(assertion_type, 'settle', allowed_roles)` means: only a caller whose
`app.current_role` is in `allowed_roles` may make an assertion of that type
accepted. A type with no `settle` row is ungated. The table is readable by
every role and writable only by `admin`, as it already was, so no caller is
blind to the gate and no caller can widen it. Adding a type to the gate is an
`INSERT`, not a migration.

At this version two rows are seeded, both `ARRAY['admin']`:

| `assertion_type` | Why |
|---|---|
| `registry_entry` | Type aliases, `self_settled_type:*`, `governed_type:*`, `DEFAULT_SCOPE`, basis priors, half lives, digest facets. Every reader of configuration reads this type. |
| `review_policy` | Decides whether other writes land accepted. Ungated, it is the key to every other lock. |

Deliberately not gated yet, each for a stated reason:

- `scope_status`. Demoting it fails open, not closed. An inactive scope is not
  selected by `governing_scope()`, so its review policy stops applying and
  subjects it would have governed fall back to `open`. Gating it would make a
  non-admin onboarding run leave governance weaker than it is today. The fix
  is for scope creation to run as an admin, which is a separate item.
- Plugin enablement. What `registry_value()` and `compile_scope_policy()` read
  is the `scope_enables_plugin` edge. The `plugin_policy_binding` assertion is
  a record of the act, not the act. Gating an assertion would not gate the
  edge, and an edge gate is a different mechanism.
- The other scope policy types written by `record_scope_policy()`
  (`expected_contexts`, `retention_policy`, `source_of_truth`, conventions).
  They shape what agents are told, not what Rye computes. They also all escape
  the review policy today, because `governing_scope()` returns null for a
  scope node's own policy assertions. That leak is its own item, and it is not
  narrowed or widened here.
- `domain_authorities` grants, which also decide who may settle. They are
  table rows, not assertions, and their own RLS is a separate item.

**What a non-admin gets.** `record_assertion()` demotes rather than refuses.
When the type is gated and the caller is not allowed, the requested status
`accepted` becomes `candidate` before anything else happens, so no incumbent
is superseded and nothing said is lost. The row carries
`attrs.settle_gate = {"pending": true, "requested_status": "accepted",
"allowed_roles": [...]}`. It appears in `review_queue` like any other
candidate, with those attrs, and an admin accepts or rejects it there. The
demotion is independent of the review policy: it applies under `open`,
`candidates_only`, `strict`, and when no policy is recorded at all.

**Every other path refuses.** Because `record_assertion()` has already
demoted, an accepted row of a gated type can only reach the table by some
other route, and every other route raises:

- A direct `INSERT INTO assertions` with `status = 'accepted'`.
- Any `UPDATE` that moves a gated row from another status to `accepted`,
  including `accept_assertion()` and including a raw `UPDATE` by a caller who
  sets `app.write_path` itself.
- `supersede_assertion()` and `record_distillation()`, which insert accepted
  rows directly. Refusing rather than demoting is deliberate: both mark or
  displace an incumbent first, and a silent demotion there would leave the key
  with no accepted value at all.

A refusal here loses nothing, because the statement can be recorded with
`record_assertion()` and become a suggestion. The check lives in one place, a
trigger on `assertions`, so a `SECURITY DEFINER` helper does not escape it and
neither does a direct write. An agent capability grant
(`rye.authoritative.promote`) does not open this gate.

**The gated type is the stored spelling.** The trigger compares
`assertion_type` as written, with no alias resolution, because every reader of
configuration does the same: `registry_value()` and `governing_scope()` match
the stored literal. A row stored under another spelling is not read as
configuration, so it does not need to be gated as configuration.
`record_assertion()` canonicalizes before it inserts, so an alias of a gated
type is gated.

**Asking first.** `settle_gate(p_assertion_type text) RETURNS jsonb` answers
`{assertion_type, gated, allowed_roles, current_role, may_settle}`. It is
`STABLE`, `SECURITY INVOKER`, and writes nothing. A client calls it before
offering to record configuration, so it can tell the person what will happen.
The schema returns facts only. The sentence a person hears is the client's, not
the database's.

**Installing and seeding.** The gate treats an unset `app.current_role` as not
allowed. A migration or script that seeds configuration must set
`app.current_role` to `admin` first, as `sync_plugin_metadata.sh` does.
Migrations applied before the gate existed are unaffected, and on a fresh
install the core registry seeds run before the gate is created.

## The row is the gate, not the route

An assertion becomes accepted, ends, narrows, gains an outcome label, or
changes classification only in a shape Rye's rules allow. This section says
what those shapes are.

**The session settings promise nothing.** `app.write_path` and the per-path
row id settings (`app.accept_assertion_id`, `app.supersede_assertion_id`,
`app.effective_window_assertion_id`, `app.classification_assertion_id`,
`app.outcome_assertion_id`) are set by the helpers and read by
`assertion_update_policy`. They are a pre-filter that stops a stray `UPDATE`,
and nothing more. Any caller can set them with `set_config()`, so no rule that
matters may depend on them. A client never sets them and never reads them as a
permission. Every rule below is enforced by triggers, which fire inside a
`SECURITY DEFINER` helper, on a raw write, and for a superuser alike, and which
re-derive their answer from the row, from rows that exist, and from
`app.current_role`.

**The guard reads `app.current_role` to refuse, never to permit.** A rule that
lets a caller through because of the role it claims is worth exactly as much as
the deployment's control of session variables. A rule that refuses regardless
of role holds against anyone. Both kinds appear below, and the difference is
stated each time. There is no admin exemption: an exemption keyed on a role is
produced by the same `set_config()` this section closes.

**Per column, on `UPDATE`.**

| Column | May change |
|---|---|
| `status` | `candidate` to `accepted` only. Never back. The row must be a live candidate; no accepted, unsuperseded assertion on the same subject, type, and key may cover the instant the promoted row takes effect, which is `greatest(coalesce(effective_at, now()), now())`; and the acceptance must be accompanied by an `assertion_accepted` event naming the row. An `agent:*` caller under `candidates_only` or `strict`, or on a `pattern_claim`, additionally needs `rye.authoritative.promote` for the governing scope, which is the rule `accept_assertion()` already applied. |
| `superseded_at` | Null to non-null once, and never back. On a row that was `accepted`, only when `superseded_by` is set in the same statement. **An accepted assertion ends only when something readable holds its place.** A candidate may still be closed with `superseded_by` null, which is how `reject_candidate()` records a rejection. |
| `superseded_by` | Null to non-null once, together with `superseded_at`, never to the row itself. The replacement must carry the same `assertion_type` and `assertion_key` and, when the ended row was `accepted`, be a row this caller can read at commit. The subject may differ, because `merge_nodes()` replaces a duplicate's assertion with the canonical node's; a replacement on another subject must also be live at commit, and it may be a candidate. |
| `effective_to` | Narrowing only, to a non-null instant after `effective_at`, before the previous `effective_to`, and in the future. A successor accepted assertion on the same subject, type, and key must start where the window now ends. |
| `attrs` | Only as an outcome label: the result must name an `outcome` in the recorded set, and no existing key may be dropped or have its value changed except the keys an outcome labelling writes. |
| `classification` | Only on a row that has derivation evidence, and only to the value `derived_assertion_classification()` computes for that evidence. Nothing else, for anyone. Propagation is the only writer, and it runs when derivation evidence is recorded. |
| everything else | Never. `claim`, `assertion_type`, `assertion_key`, the subject columns, `asserted_at`, `effective_at`, `basis`, `confidence`, `created_at` stay as written. |

**A direct `INSERT` lands as a candidate, it is not refused.** A raw insert of
an `accepted` row is judged by the same review policy `record_assertion()`
applies: under `strict`, and under `candidates_only` when the basis is not
`observed`, the row lands `candidate`. Nothing said is lost, which is the same
answer the settle gate gives, and refusing instead would break `merge_nodes()`
and every other helper that inserts a row directly. Rye does not tell
`record_assertion()`'s insert from a raw one and does not try: there is no
signal a helper can produce that a caller cannot, so the row is judged rather
than the route. `record_assertion()` has already applied the policy, so the
check is a no-op on its own writes.

One exemption: a row is left accepted when an assertion **on the same subject,
`assertion_type`, and `assertion_key`** is already superseded, was accepted,
and names this row as its replacement. `supersede_assertion()`,
`record_distillation()` and `record_assertion()` all mark the incumbent before
inserting its replacement, and demoting the replacement would leave that key
with no accepted value at all — the erasure this section exists to prevent. The
exemption is a fact in the table, not a setting, and it is confined to the
tuple whose value would otherwise be stranded. It does not carry across
subjects: a `merge_nodes()` copy is judged by the canonical node's review
policy, not the duplicate's, and under `strict` the copy lands as a candidate.

What is left open by the exemption is what `supersede_assertion()` already
lets the same caller do on that same tuple, so it adds nothing. There is no
"the incumbent pre-dates the transaction" test, because nothing in the row
records when it was written that a caller could not also write.

**Refusals, and when they arrive.** Most arrive at the statement, as a raised
error a client surfaces. Three arrive at `COMMIT`, because the fact that makes
the transition true is written after it: the acceptance event, the existence
and type of a replacement, and the successor of a narrowed window. A client
that wraps several writes in one transaction may therefore see a refusal at
commit that names a statement it ran earlier. `superseded_by` already behaves
this way: its foreign key is `DEFERRABLE INITIALLY DEFERRED` so a helper can
point an incumbent at a replacement it has not inserted yet.

**Ending an accepted assertion leaves the key standing.** The named replacement
is not the whole test, because a caller can name a row and then write it closed,
or close it in the next transaction. So at commit, when the ended row was
`accepted` and the replacement is **on the same subject**, that subject, type,
and key must still carry a readable assertion that is `accepted` and not
superseded. The named replacement itself need not be the one: two writes to the
same key in one transaction leave a chain, and what matters is that the chain
ends on a row that is `accepted` and not superseded. The test does not read the
window: that row may be effective only in the past or only in the future, so
`current_valid_assertions` can be empty for the key afterwards. That is what
`supersede_assertion()` with a future effective date already does, and a rule
promising a current value would have to refuse the helper.

**A merge is the one shape that moves the value to another subject.** When the
replacement is on a **different** subject, it must be readable, of the same
type and key, and live at commit, and it may be a candidate: a merge into a
subject under `strict` routes the copy to `review_queue`, and refusing that
would refuse the merge. The residual is worth naming. That copy can be rejected
later, and then the duplicate's key has ended and the canonical's holds
nothing. That is exactly what `merge_nodes()` followed by `reject_candidate()`
already allows through the helpers, so the raw path grants nothing new.

**Blindness is restrictive here too.** The commit-time checks run under the
caller's own visibility. A replacement or a successor the caller cannot read is
not one: the write is refused, exactly as if the row were absent. A caller
cannot end an accepted assertion by pointing it at something RLS hides, and it
cannot narrow a window by pointing at a successor nobody can see. The cost is
a caller that writes a row it cannot read back — an assertion classified above
its own level — and then supersedes with it. That is refused, and the fix is to
write at a level the caller can read, or to record the statement as a
suggestion. Every helper survives this, because each takes the replacement's
classification from the row it replaces or from evidence the caller can already
see. The conflict searches are the other way round and stay that way: an
invisible accepted rival does not block a promotion, and inverting that would
refuse every promotion to every caller who cannot see the whole tuple. What it
costs is the sixth limit below.

**What this protects and what it does not.** Rye's authorization is session
variables. A caller holding a raw connection can set `app.current_role` to
`admin`, and nothing here changes that. Two things are protected. Deployments
where a trusted backend sets the session variables and callers cannot. And
well-behaved agents that state their role honestly and must not be able to skip
review by accident or by following bad instructions. It is not a defence
against a hostile caller with a raw connection.

Inside that boundary, three claims hold for every caller, forged role included,
because they do not read a role at all: an accepted assertion is ended only
when its own subject, type, and key still carry a readable accepted assertion,
or, in a merge, when a readable live assertion of the same type and key stands
on the other subject; a window cannot be narrowed without a
successor; and `claim`, `basis`, `confidence`, and the subject of an assertion
cannot be rewritten. Everything else is as strong as the deployment's control
of the session.

**Only `agent:*` callers are policy-gated on promotion.** A `viewer`, a
`team_member`, and an unset role are tested for the shape of the transition and
for the settle gate, and not for the review policy. That is not an oversight
here: `accept_assertion()` applies the review policy to agent roles only, and
this section re-derives that rule rather than inventing a wider one. Who may
accept, for every other role, is the settlement question, and `rye_settlers()`
is advisory by contract.

Six limits are stated rather than hidden. An outcome label is
shape-constrained, not role-constrained, so a caller may still label an outcome
by hand. `supersede_assertion()` does not consult the review policy, so a
caller who supersedes and replaces an accepted row still writes an accepted
row under `strict`; that is unchanged here and is its own item. The insert
check resolves the governing scope without a witness, because evidence is
written after the assertion, so a scope reached only through
`scope_governs_source` does not demote a raw insert. And a caller who may
accept through `accept_assertion()` under an `open` policy is a caller whose
raw promotion is refused only by the missing acceptance event, which is a
record, not a lock. The rival test for a promotion is taken at one instant,
the one the promoted row takes effect at, so two accepted rows may still
overlap earlier in history; `current_valid_assertions` is protected, a
reconstruction of a past moment is not.

The sixth is the one a client is most likely to meet. **A rival the caller
cannot read does not stop a raw promotion.** A caller whose role hides an
accepted assertion — classified above its read level — can promote a visible
candidate on the same subject, type, and key and leave two accepted rows
covering the same instant. The inferred-displacement test has the same cause
and the same gap, and no fixture exercises it. Where the two paths differ is
worth knowing: `accept_assertion()` is `SECURITY DEFINER`, so in a deployment
whose table owner is a superuser — the Docker reference install — it reads past
RLS and ends the hidden incumbent, leaving one row, while the raw path leaves
two; where the owner is bound by RLS, as on Supabase, the helper sees no more
than the caller and the two paths agree. Reading past RLS in the guard was
rejected: it would tell a caller that a row it may not see exists, it does
nothing at all where the owner is bound by RLS, and it is the kind of route
`design/model/deployment.md` refuses. The consequence is a duplicate, not an
erasure, and an admin sees both rows.

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

### Who may call it, and what each caller sees

It stays `SECURITY INVOKER`, so the session shapes in "Governance tables" decide
what it can find. The signature and the answer shape are the same for all of
them; the content is not.

| caller | what it gets |
|---|---|
| admin | every answer this document describes |
| named role | the same answers: it reads every area and every grant, and node-derived settlers are filtered by node visibility as they always were |
| bound agent | narrowed to the areas it holds. An area it holds no grant on is invisible, so the answer is `step` `none`, `settlers` `[]`, `domain_found` false, `reason` `domain_not_found` — the same answer as for an area key that names nothing, and deliberately indistinguishable from it. An area is not a thing an agent gets told exists. |
| agent-shaped but not bound, or unknown | no area resolves and no grant is visible, so only the relationship step can produce anything, from nodes it can see |

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
`claim` is `{claim_type, assertion_type, canonical_claim_type, speech_act,
speech_act_recognized}`. `claim_type` and `assertion_type` are the value as
given. `canonical_claim_type` is what it resolved to, and it equals the given
value when no alias applies. It is additive: a caller that ignores it sees no
change.
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
alias, not as a second self-settled entry. Only a Rye admin settles that entry,
and only a Rye admin settles an alias. Anyone may propose one, and a proposal
is a candidate with no effect on this lookup until an admin accepts it. See
"Configuration writes need an admin". The core members above need no
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
