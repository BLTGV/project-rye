# 0009 Who may write

Date: 2026-09-20. Work item: `work/009-who-may-write.md`.
Contract: `contracts/sql-surface.md`, section "Who may write". Areas: schema.
Migration: `0026`.

## The gap

Rye has never said what each role may write. `assertion_insert_policy` gates
assertion types, never roles. `node_insert_policy`, `edge_insert_policy`,
`artifact_insert_policy`, `ep_insert_policy`, and `event_insert_policy` are all
`WITH CHECK (true)`. The only role test anywhere on the core tables is
`NOT LIKE 'agent:%'`, and it appears on `UPDATE` and `DELETE` only. The work/008
Verifier committed the consequences under a non-superuser role: a `viewer`, a
`team_member`, an `agent:t`, and a session with no role set all inserted
assertions; a `viewer` archived an `onboarding_scope` node and a
`scope_governs_subject` edge; an `agent:t` deleted that edge; a `viewer` called
`merge_nodes()`. Each of the middle three turns a `strict` area into an open one
for `record_assertion()` and for raw writes alike, which undoes work/005 and
work/008 from the side. Separately, `merge_nodes()` under an agent role on an
owner that RLS binds failed with `Duplicate node % not found`, because its
`FOR UPDATE` is filtered by `node_update_policy` before any gate opens
(work/006).

## A. The role list is the write list

The rule is a row, not code: `role_classification_access` gains
`may_write boolean NOT NULL DEFAULT true`, and the `viewer` row is set `false`.
One helper, `rye_role_may_write()`, is the whole definition — true when
`app.current_role` is agent-shaped or names a row whose `may_write` is true,
false for `viewer`, for an unknown role name, and for an unset role. Every
`INSERT`, `UPDATE`, and `DELETE` policy on the seven core tables gains that one
conjunct. The matrix is in the contract.

This is the same choice
`docs/decisions/0007-agent-governance-visibility.md` made for reads, applied to
writes, and for the same reasons: that table is already the instance's role
vocabulary, it is already readable by every session for `redact_properties()`,
adding a read-only role stays an insert rather than a migration, and widening a
role later is an `UPDATE`. It is also level 0 in the policy read order, so a
helper that reads it is safe to call from a policy on any table.

Agent-shaped is decided from the session variable alone, without reading
`agent_identities`, because a policy on `nodes` may not depend on a table whose
own policy depends on `nodes`. The cost is that a session can call itself
`agent:` anything and write what an agent may write. That is unchanged from
today — every agent policy in the schema already tests the string — and it is
not what this item closes.

Rejected: spelling `viewer` into each policy, which makes every later read-only
role a migration and puts the role model in fourteen places. Rejected: a new
`role_write_access` table, which carries one column an existing table already
models, against the item's constraint. Rejected:
`current_setting('app.current_role', true) IS NOT NULL`, which makes a typo a
writer and gives the instance no list of who its roles are while its policies
depend on there being one — the same argument that settled the read side.

### Corrected 2026-09-20, after verification: a policy conjunct is not enough

The Verifier reproduced and committed the hole under `SET ROLE` to a
non-superuser on the Docker test database, whose owner is a superuser: as
`viewer`, `accept_assertion()` accepted a candidate and wrote the event,
`reject_candidate()` closed one, and `mark_assertion_outcome()` rewrote `attrs`
— the last also with no role set. All three are `SECURITY DEFINER` owned by that
superuser, so RLS never ran and the conjunct never ran with it. On the
non-superuser owner all three were refused. The work item's criterion says "by
raw SQL or through any helper", and the repository's default test database is
the superuser-owned one, so this counts.

**The rule: the gate is a trigger, and the policy conjunct is the second line.**
One function, `rye_gate_may_write()`, on each of the seven core tables,
`BEFORE INSERT OR UPDATE OR DELETE ... FOR EACH ROW`, raising `42501` when
`rye_role_may_write()` is false. A trigger fires for a superuser, inside a
`SECURITY DEFINER` function, and on a raw write alike. The conjunct stays as the
cheaper refusal where the owner is bound by RLS and because `USING` and
`WITH CHECK` still carry the governance row test.

Rejected: (a), a first-statement refusal in each definer writer —
`accept_assertion`, `reject_candidate`, `mark_assertion_outcome`,
`resolve_knowledge_gap`, `promote_candidate_node_to_assertion`,
`agent_create_candidate`, `agent_submit_observation`, `score_due_predictions`,
and whatever `prosecdef` writers 0016, 0022, 0024 and the profiles hold. It
copies eight-plus function bodies forward for a one-line check, it collides with
`0027`, which replaces `resolve_knowledge_gap()` and sorts later and would
silently drop the gate, and the next definer helper anyone writes forgets it.
The trigger needs no list and cannot be forgotten, which is the same reason
`0007-configuration-writes-need-an-admin` put the settle gate in a trigger
rather than in each helper.

Rejected: a statement-level trigger, which is cheaper on bulk paths. A
`BEFORE STATEMENT` trigger fires before every `BEFORE ROW` trigger whatever it
is named, so on `assertions` it would take `trg_assertion_settle_gate`'s message
away from `tests/conformance/30_configuration_gate.sql`, whose
`%is Rye configuration%` assertions are load-bearing. Row-level also keeps one
mechanism rather than two, and `rye_role_may_write()` is one lookup on an
eight-row table.

Trigger names are in the contract. The one that is a decision rather than a
convention is `trg_assertions_gate_may_write`, verified by sorting under both
collations to fall after `trg_assertion_settle_gate` and before
`trg_assertions_immutable` and `trg_assertions_insert_review`, so the settle
gate's message still wins and the shape guards still run after the role is
settled.

**Two shapes of refusal, by owner.** A `BEFORE ROW` trigger only sees rows RLS
admitted, so a refused `UPDATE` or `DELETE` raises where the owner is a
superuser and affects zero rows where the owner is bound by RLS. Both are
refusals. Every test below asserts the row, not the error text.

**The CDC path must not refuse.** `capture_domain_change()` runs inside the
application's own transaction on its own domain table, in a session that may set
no role at all. Refusing its `record_event()` would fail the application's
`INSERT`, and Rye would be getting in the way of the system of record — the
overlay promise, and the one thing that must not break. So
`capture_domain_change()` asks `rye_role_may_write()` and returns without
recording an event when the answer is false, exactly as it already returns
silently for a row that maps to no node. The domain write always succeeds and
the event is not written. Rejected: exempting the CDC insert with a named
`app.write_path`, which any caller can set and which would therefore be a
general bypass of this whole record. Rejected: letting the refusal propagate and
telling operators to set a role on every application connection, which is the
overlay promise traded for a rule about Rye's own bookkeeping. The cost is
stated in the contract: a tracked table written by a session with no role
produces no CDC event.

`refresh_materialized_views()` and `log_agent_query()` write no core table and
need nothing. Migrations set `admin` themselves, as D already required.

Rejected, and worth recording: **no admin exemption on the row rules.** Nothing
here weakens `docs/decisions/0008`. Every rule in this record reads the role in
order to permit, which is what a role model is, and the contract says so in
those words. The rules that read no role stay where they are.

## B. The governance structure is configuration, so it is admin-only

The set was derived from the bodies of `governing_scope()` and
`scope_review_policy()`, not from memory, and it is listed in the contract. Two
kinds of thing:

**Rows.** An `onboarding_scope` node, and an edge of type
`scope_governs_subject` or `scope_governs_source`. `scope_enables_plugin` joins
them: `docs/decisions/0007-configuration-writes-need-an-admin.md` left plugin
enablement out of the settle gate because what is read is the edge and not the
`plugin_policy_binding` assertion, and said an edge gate is a different
mechanism. This is that mechanism, so the sentence can be retired rather than
carried.

The test is row-local — `node_type` and `edge_type` on the row being written —
so the policy reads no table and cannot recurse, and it composes with the
existing `NOT LIKE 'agent:%'` conjuncts instead of replacing them. RLS applies
`USING` to the old row and `WITH CHECK` to the new one, which is what makes one
rule cover archiving, ending, deleting, and re-pointing in both directions. A
non-admin can neither promote an ordinary edge into a governance edge nor demote
a governance edge into an ordinary one.

**Assertions.** `review_policy` and `registry_entry` are already gated by the
settle gate. `0026` adds `scope_status`, `ARRAY['admin']`, which
`0007-configuration-writes-need-an-admin` deliberately left out. Its reason was
that demoting `scope_status` fails open — an inactive scope governs nothing, so
a non-admin onboarding run would leave governance weaker than before. That
reason is gone once creating the scope node is admin-only, because activating a
scope nobody but an admin could create is not a path a non-admin was on. The
gate is an `INSERT` into `assertion_type_access`, as designed.

Rejected: gating `has_step`. Every process step in the PM profile has one, so
gating it would gate ordinary work to protect an inherited scope, which is
weaker than a direct one anyway. The contract states the residual: archiving a
`has_step` edge still drops a step's inherited governance, and a subject that
must stay governed gets its own `scope_governs_subject` edge.

Rejected: letting `merge_nodes()` re-point a governance edge on behalf of a
non-admin through a named `app.write_path` gate. Everywhere else the gate is a
guard rail that grants nothing because anyone can set it; here it would grant
exactly the thing this record closes, and a `team_member` who set it by hand
could move a strict scope's governance off a node. So the helper refuses instead
(C).

What an agent or a `team_member` may still do is unchanged and is the point of
keeping the test row-local: every node that is not an `onboarding_scope` and
every edge that is not one of the three types behaves exactly as it did. A
`team_member` inserts, updates, and deletes them; an agent inserts nodes and
edges, updates node properties through `update_node_properties()`, and still
cannot update or delete an edge.

`create_onboarding_scope()`, `activate_onboarding_scope()`,
`enable_plugin_for_scope()`, and `record_scope_policy()` keep their signatures
and bodies and become admin-only because the rows they write are. That is the
arrangement `0007-agent-governance-visibility` chose for the five governance
write helpers, for the same reason: one rule in one place, and no second
authorization model free to drift. Two helpers get an explicit refusal anyway,
and only because RLS would otherwise lie about why —
`update_node_properties()`, whose `FOR UPDATE` is filtered to zero rows and
reports `Node % not found` about a node the caller can see, and `merge_nodes()`.

## C. `merge_nodes()` refuses before it locks

Who may call it: any caller for whom `rye_role_may_write()` is true and whose
role is not agent-shaped. The item's default — `admin` and `team_member` — is
satisfied, because both are named roles that may write, and it is expressed
through the role list rather than by spelling two names into the function. An
agent that finds a duplicate records it and asks a person, which is what
`skills/rye-gardener` already tells it to do. Both refusals raise `42501` with
the sentences in the contract, and both say who can merge. A non-admin merging a
node the governance structure touches is refused separately, because the merge
would have to re-point an admin-only edge and a silent zero-row `UPDATE` would
leave that edge pointing at an archived node.

The ordering is the fix for work/006's misleading message and it follows the
rule recorded for `score_due_predictions()` in `0024`: gate first, then lock.
`SELECT ... FOR UPDATE` applies the `UPDATE` policy's `USING` clause as a silent
filter, so every role test has to be evaluated before the lock or the caller is
told the node is absent. After `0026`, `Duplicate node % not found` means absent
or invisible and nothing else.

Rejected: raising a different message when the lock returns zero rows. It would
be a guess about why, and it would still be wrong for an invisible node.
Rejected: restricting merges to `admin` only. It is the narrower reading of
work/006's queued question, it costs a team member a routine curation act, and
the human's stated default is the wider one.

## D. The blast radius, and why it fits in one migration

Derived by grep over every suite, script, migration, replay load, CLI
subcommand, and the admin Worker, asking two questions: does it write a core
table, and does it set `app.current_role` first.

**Nothing in the repository writes as `viewer`.** Every `viewer` block in
`tests/conformance/25_core_model_v2.sql` and
`tests/conformance/29_settlement_lookup.sql` reads. That half of the rule costs
nothing.

**Nine call sites write with no role set. Eight must start setting one.**

| # | site | what it writes | fix |
|---|---|---|---|
| 1 | `tests/conformance/01_core_contract.sql` | nodes, edges, assertions | set `admin` |
| 2 | `tests/conformance/02_supersession_single_active.sql` | nodes, assertions | set `admin` |
| 3 | `tests/conformance/03_assertion_key_uniqueness.sql` | nodes, assertions | set `admin` |
| 4 | `tests/conformance/04_record_event.sql` | nodes, events, participants | set `admin` |
| 5 | `tests/conformance/05_link_record.sql` | domain table, nodes, `node_source_map` | set `admin` |
| 6 | `tests/conformance/07_domain_integration.sh` | a domain table whose CDC trigger inserts an event | set `admin`; the graph write is the trigger's, not the statement's |
| 7 | `tests/conformance/09_record_artifact.sql` | nodes, events, artifacts | set `admin` |
| 8 | `scripts/seed_quickstart.sh` | nodes, edges, events, assertions | set `admin` |
| 9 | `tests/concurrency/01_code_generation.sh` | `crm_code_counters` through `generate_crm_code()` | confirm only — not one of the seven tables and not covered by this rule |

`conformance.sh` runs each SQL file in its own psql session, so a file that
never sets `app.current_role` runs unset; that is why the first seven are on the
list at all and why setting it once at the top of each file is the whole fix.

**Nothing else changes.** Every registry, scope-policy, and governance write in
the repository already runs as `admin`. `scripts/rye` sets `admin` for
`onboard create` and for all six `agents` subcommands, and everything else it
does is a read. `sync_plugin_metadata.sh` sets `admin`. All five replay loads
under `eval/` set `admin`, including `bluebird_bakes`, whose transaction-local
`set_config` is inside an explicit `BEGIN`. The admin Worker's `ryeQuery()`
defaults to `admin` and sets it in its own statement inside the transaction; its
only other `RyeSessionRole` is `reader`, which is used nowhere and which the new
rule makes read-only, as the name says.

**Migrations.** `migrate.sh` runs each file in its own psql session, so `0026`
and anything after it that writes data must set `app.current_role` to `admin`
itself, as `sync_plugin_metadata.sh` does. Migrations `0001`–`0025` are
unaffected on a fresh install because they sort before `0026` and the policies
do not exist yet, and unaffected on an existing database because they are
already applied. The profile migrations sort after `0026` and write no data at
install time — every `INSERT` in them is inside a function body.

**One migration is safe.** Eight files, all in this repository, one line each.
The staged alternative is not needed and would cost more than it buys: because
`may_write` defaults to `true`, the only thing a stage could do is delay seeding
the `viewer` row, which is the half that costs nothing. If a consumer outside
this repository is later found writing with no role, the correction is an
`UPDATE` to one row and not a migration — which is the reason the rule is data.

## E. Test obligations

A conformance suite, `tests/conformance/32_who_may_write.sql`;
`conformance.sh` globs the directory so it needs no registration. Every case
runs under a non-superuser role and is repeated under
`./scripts/test-nonsuperuser-owner.sh`, where there is no `rye_conformance` role
and suites run as `rye_owner` with no `SET ROLE`.

1. Refuse to run vacuously. Raise if `current_setting('is_superuser')` is `on`,
   if `row_security` is `off`, if
   `(SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user)`
   is true, and if `current_setting('app.current_role', true)` does not read
   back the value the case meant to set. `SET app.current_role = ...` is a
   syntax error because `current_role` is reserved; use `set_config()` and
   assert the read-back.
2. As `viewer` and with no role set, each of these is refused and the table is
   unchanged afterwards: `INSERT` into `nodes`, `edges`, `events`,
   `event_participants`, `assertions`, `assertion_evidence`, `artifacts`.
   Assert the raised `42501` for inserts.
3. As `viewer` and with no role set, each of these affects zero rows and the
   row is unchanged afterwards: `UPDATE nodes SET archived_at = now()`,
   `UPDATE edges SET archived_at = now()`, `DELETE FROM edges`,
   `UPDATE event_participants`, `DELETE FROM event_participants`,
   `UPDATE artifacts`, `DELETE FROM artifacts`, and an `UPDATE assertions` with
   `app.write_path` and the matching `app.*_assertion_id` forged. Check
   `ROW_COUNT`, because RLS turns these into zero rows rather than an error.
4. As `viewer` and with no role set, each helper is refused by its effect and
   not only by not raising: `record_event`, `record_assertion`,
   `record_artifact`, `link_record`, `update_node_properties`, `merge_nodes`.
5. Reads are unchanged. As `viewer` and with no role set, a `SELECT` over
   `nodes`, `edges`, `events`, `assertions`, `current_valid_assertions`, and
   `node_context` returns the same row counts as before the migration for the
   same fixture. Anti-vacuity: the fixture must be visible to that role, so
   assert a non-zero count.
6. Governance structure, under `agent:t`, `team_member`, `viewer`, and no role:
   archiving an `onboarding_scope` node, archiving a `scope_governs_subject`
   edge, ending one with `effective_to`, deleting one, re-pointing its
   `source_id` or `target_id`, re-typing an ordinary edge into
   `scope_governs_subject`, and inserting a new governance edge or scope node
   are each refused. `team_member` is the case that proves the rule is not just
   the old `NOT LIKE 'agent:%'` test.
7. After each refusal in 6, `scope_review_policy(governing_scope(subject, ...))`
   still returns `strict`, and an `agent:t` write through `record_assertion()`
   that was a candidate before is still a candidate. Assert both, not the
   refusal alone. This is the acceptance criterion and the only thing that shows
   the refusals mattered.
8. `scope_status` is gated: `record_assertion('scope_status', ...,
   p_status := 'accepted')` under `agent:t` and `team_member` lands `candidate`
   with `attrs->'settle_gate'->>'pending'` true, and the scope's policy is
   unchanged afterwards. Admin still activates a scope.
9. `merge_nodes()` refusals, on both owner types: as `agent:t` and as `viewer`
   the message matches the contract's text and is **not** `%not found%`; as
   `admin` and as `team_member` a merge of two ordinary nodes still succeeds,
   asserted by the duplicate being archived and its assertion standing on the
   canonical node. As `team_member`, merging a node a live
   `scope_governs_subject` edge touches is refused with the admin sentence; as
   `admin` the same merge succeeds.
10. An admin is not exempt from the row rules. A raw
    `UPDATE assertions SET superseded_at = now()` as `admin` is still refused by
    `0025`, proving `0026` added a role model and did not open a bypass.
11. **Every `SECURITY DEFINER` writer is refused for `viewer` and for an unset
    role, under both owner types.** This is the case the first verification
    missed, so it is asserted by effect and not by an error text: for each of
    `accept_assertion`, `reject_candidate`, `mark_assertion_outcome`,
    `resolve_knowledge_gap`, `promote_candidate_node_to_assertion`,
    `agent_create_candidate`, `agent_submit_observation`, and
    `score_due_predictions`, the target row is unchanged afterwards. Derive the
    list for the suite by
    `SELECT proname FROM pg_proc WHERE prosecdef` in the `rye` schema rather
    than from this paragraph, and cover every one of them that writes a core
    table, including any in 0016, 0022, 0024 and the profiles. Anti-vacuity:
    the same calls as `admin` must succeed, on the same fixture, in the same
    run.
12. **Coverage that tests 30 and 31 used to get from `viewer` and an unset
    role** moves here as refusals, because those two can no longer write at
    all: `accept_assertion`, `supersede_assertion`, `schedule_assertion_change`,
    `record_scope_policy`, `mark_assertion_outcome`, and a raw `UPDATE` with
    each of the five forged write paths — `accept_assertion`,
    `supersede_assertion`, `assertion_effective_window`,
    `assertion_classification`, `assertion_outcome` — with the matching
    `app.*_assertion_id` set to the target row. Each refused, each row unchanged
    afterwards, under both owner types. Tests 30 and 31 keep their `agent:t` and
    `team_member` cases unmodified, and test 30's `%is Rye configuration%`
    assertions still pass for `viewer` because the settle gate sorts first.
13. **The CDC path under an unset application session.** `track_table()` a
    domain table, then write it with `app.current_role` unset: the domain
    `INSERT`, `UPDATE`, and `DELETE` all succeed, and no `domain_change` event
    is written. Then set `admin` and repeat: the domain write succeeds and the
    event is written. Anti-vacuity is the second half — a suite that only
    asserts "no event" passes on a broken trigger that never fires.
    `tests/conformance/07_domain_integration.sh` is the file, and this replaces
    the plain "set `admin`" fix listed for it in D.
14. Every existing suite passes unmodified except the eight files in D, and each
    of those changes is one added `set_config` line. The report lists them.
15. The suite fails on a tree without `0026`. Run it once against the previous
    migration set and record that it fails, before running it against the new
    one, under both owner types. Obligation 11 in particular must fail on the
    superuser-owned database without `0026`, because that is the case the
    policy-only version passed.
16. `./scripts/test-all.sh` passes, on the builder's own `COMPOSE_PROJECT_NAME`
    and an unused `RYE_POSTGRES_PORT`.

## What `0026` replaces, and what it must not touch

Replaces: the `INSERT`, `UPDATE`, and `DELETE` policies on `nodes`, `edges`,
`events`, `event_participants`, `assertions`, `assertion_evidence`, and
`artifacts` — taking the live definition of each as the last one in migration
order — plus `merge_nodes()` (0005), `update_node_properties()` (0007), and
`capture_domain_change()` (0002). Adds `rye_role_may_write()`,
`rye_gate_may_write()` and its seven triggers, the `may_write` column, and the
`scope_status` settle row. It replaces no `SECURITY DEFINER` helper, which is
the point of the trigger.

Must not touch, because `0027` replaces them for work/010: `governing_scope()`,
`supersede_assertion()`, `assertions_insert_review_guard()`, and
`resolve_knowledge_gap()`. `merge_nodes()` belongs to `0026` alone; work/010's
merge behaviour changes as a consequence of `governing_scope()` and needs no
edit to the helper.

## Cost

A client that wrote without setting `app.current_role` is refused. Eight files
in this repository did; the contract and this record are the notice. An area
owner who is not a Rye admin can no longer create or activate a scope, enable a
plugin for one, or connect a subject to one — which is the same cost
`0007-configuration-writes-need-an-admin` accepted for registry entries, and the
same overturn: Casey. A `team_member` can no longer merge a node a scope
governs. And the protection is exactly as strong as the deployment's control of
session variables, because every rule here reads the role in order to permit.
