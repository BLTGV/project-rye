# 0008 The row is the gate for the assertion lifecycle

Date: 2026-09-19. Work item: `work/007-assertion-lifecycle-gate.md`.
Contract: `contracts/sql-surface.md`, section "The row is the gate, not the
route". Areas: schema. Migration: `0025`.

## The gap

`assertion_update_policy` and the 0019 immutability guard both decide what an
`UPDATE` may do by reading `app.write_path` and a per-path row id setting. The
helpers set those. So can anyone, with `set_config()`. The Lead reproduced it
on af232e9 under `agent:t`, `viewer`, `team_member`, and with no role set: a
candidate promoted to accepted, an accepted row ended with `superseded_by`
still null, a window narrowed, `attrs` rewritten, and `classification` set to
`public`. A direct `INSERT` of an accepted row landed accepted. work/005
closed this for `registry_entry` and `review_policy`. This is the rest.

## There is no unforgeable "a helper did this" signal

This was the first thing to settle, because the item asks for one. Under
session-variable-only authorization, with no privilege boundary available, a
signal the helper can produce is a signal the caller can produce.

A per-call secret does not survive the question "where is the verifier's
copy?". The helper mints a nonce and the trigger checks it — against what? A
second setting the caller can also write. A table, and the caller can write it
too, since RLS conditions read the same forgeable settings and grants do not
bind the owner. A key held out of the caller's reach, and a `SECURITY INVOKER`
helper cannot read it either, while a `SECURITY DEFINER` accessor that can is
callable by the caller. Every arrangement closes the loop back to a value both
sides can write.

Rejected for the record, each with its reason. **Table privileges**: `REVOKE
UPDATE ON assertions` with `SECURITY DEFINER` helpers is the standard answer
and it is a no-op where Rye actually runs, because on Supabase the application
connects as the owner and in the Docker test database the `rye` login is a
superuser; the defence would be invisible in the environments it is written
for, and it would force every updating helper to `SECURITY DEFINER` against
`design/model/deployment.md`. **`GET DIAGNOSTICS ... PG_CONTEXT`**: the call
stack is not forgeable by `set_config`, but its text is undocumented, and a
caller who can create a function — including in `pg_temp`, which every
connection can — may be able to produce a frame that matches; deciding
otherwise would rest on how PostgreSQL formats a stack frame, which is not a
promise this project can hold across versions. **`current_query()`**: text
matching, defeated by a wrapper function or a `DO` block. **Advisory locks and
sequences**: the caller can take the lock and draw the number.

So the design stops asking who wrote the row and asks whether the row is one
Rye's rules allow. `app.write_path` stays, the helpers keep setting it, and
`assertion_update_policy` keeps reading it as a cheap pre-filter that stops a
stray `UPDATE` and keeps `tests/security/01_assertion_policies.sql` and
`tests/scenarios/06_recommendations.sql` passing as written. It grants nothing.

## A. What replaces it

Two triggers, because two kinds of fact are needed and they become true at
different times.

**A `BEFORE` guard for shape and authority.** `assertions_immutable_guard()` is
replaced in place, keeping its trigger `trg_assertions_immutable`. Per column
it decides from `OLD`, `NEW`, rows that already exist, and `app.current_role`.
The per-column rules are in the contract. The two that carry the weight:
`superseded_at` may be set on a row that was accepted only when `superseded_by`
is set with it, and `classification` may change only to the value
`derived_assertion_classification()` computes for the row's current derivation
evidence. Neither reads a role, so neither can be forged around.

**A deferred constraint trigger for the consequences.**
`trg_assertions_transition_complete`, `AFTER INSERT OR UPDATE ... DEFERRABLE
INITIALLY DEFERRED`, alongside the existing `trg_assertion_evidence_required`,
which is the precedent. It checks three things the helper makes true after the
statement that needs them: a promotion has an `assertion_accepted` event naming
the row; a `superseded_by` names a row that exists with the same
`assertion_type` and `assertion_key`; a narrowed `effective_to` has a successor
accepted assertion on the same subject, type, and key starting where the window
now ends. Deferral is not a preference. `supersede_assertion()` must mark the
incumbent before inserting the replacement or the partial unique index on
accepted unsuperseded rows rejects the pair, which is why `superseded_by`'s
foreign key is already `DEFERRABLE INITIALLY DEFERRED`.

The deferred checks run at commit as the caller, under RLS, outside any
`SECURITY DEFINER` frame. The acceptance event is visible because
`accept_assertion()` records the subject (or the edge's endpoints) as
participants, and a caller who can see the assertion can see those nodes. The
replacement and the successor are rows the caller just wrote; if the caller
classified one above its own read level it cannot see it, so those two checks
refuse only when the row is visible and wrong, and pass when it is invisible.
That is the one place this design fails open, and it is stated in the contract.

**Cost to `SECURITY INVOKER` versus `SECURITY DEFINER` helpers: none, and that
is the point.** No helper changes. All five functions that update `assertions`
keep their bodies, their security setting, and their `write_path` calls. A
trigger reads `app.current_role`, which `SECURITY DEFINER` does not change, and
every RLS policy in Rye is written against session variables rather than the
database role, so a `DEFINER` helper and a raw write get the same answer from
the guard. The one asymmetry is the test database, where the owner is a
superuser and RLS is bypassed inside a `DEFINER` helper: the guard then sees
more rows than the caller would, which can only make it refuse more, never
less.

The new cost is work per write. A promotion resolves `governing_scope()` and
`scope_review_policy()` a second time, which is acceptable because promotions
are rare. An accepted `INSERT` resolves them once where it did not before,
which is the hot path, so both guards return immediately unless a non-archived
`onboarding_scope` node exists: every branch of `governing_scope()` returns
such a node, so with none the policy is `open` and there is nothing to decide.

**What a caller who forges every setting except `app.current_role` can and
cannot do.** Cannot: end an accepted assertion without a replacement of the
same type and key; narrow a window with no successor; rewrite `claim`,
`basis`, `confidence`, `asserted_at`, `effective_at`, or the subject; delete
`attrs` keys; set `classification` to anything but the derived value; un-set
`superseded_at`; move an accepted row back to candidate; promote a candidate
that is already superseded, or one with an accepted rival standing on its
tuple, or one with no acceptance event. Can: label an outcome by hand; promote
a candidate that no rule refuses, if it also writes the acceptance event; land
a candidate; supersede an accepted row by writing a genuine replacement. That
last one is not a hole but the shape of the rule: the fact is replaced, not
erased.

## B. A direct INSERT lands as a candidate

Refusing would break `merge_nodes()`, which inserts the duplicate's assertions
onto the canonical node directly, and it would throw away what a caller said,
which is the opposite of what the settle gate decided in 0007. So the guard
demotes exactly where `record_assertion()` demotes: `strict`, or
`candidates_only` with a basis other than `observed`.

`record_assertion()`'s insert is not told apart from a raw one, because it
cannot be. It does not need to be: it has already applied the same rule, so the
guard is a no-op on its own writes. The exemption for a row an already
superseded assertion names as its replacement is what keeps
`supersede_assertion()`, `record_distillation()` and `record_assertion()`'s own
supersede-then-insert from stranding a key with no accepted value, and it is
narrowed to an incumbent that was accepted, so a caller cannot manufacture it
by superseding a candidate it just wrote.

**Correction, 2026-09-19, after verification.** As first written the exemption
tested only that some superseded accepted row named `NEW.id`. The Verifier
reproduced the consequence: supersede a row in an `open` scope, name a new id,
then insert that id as accepted on a subject in a `strict` scope, and it
commits accepted. `merge_nodes()` hits the same path by accident when the
duplicate is in an open scope and the canonical in a strict one, which is
obligation 11 failing. The exemption now also requires the incumbent to carry
the same `subject_ref`, `assertion_type`, and `assertion_key` as the row being
inserted. It is confined to the one tuple whose value would otherwise be
stranded, which is the only thing it was ever for.

Checked against every helper that inserts. `record_assertion()` supersedes
`v_existing` on the same subject, type, and key and inserts on that tuple.
`supersede_assertion()` refuses cross-tuple supersession outright, so its pair
always matches. `record_distillation()` supersedes the `digest` incumbent at
the same `subject_ref` and key. `accept_assertion()` does not insert, so the
exemption never applies to it. `merge_nodes()` inserts the copy before it marks
the duplicate's row, so the exemption cannot apply to it in either form, and
with the tuple test the copy is judged by the canonical node's scope policy —
which is the answer obligation 11 asks for.

The Lead also proposed dropping the "incumbent pre-dates the transaction"
requirement. Confirmed, and it was never expressible: nothing in the row
records when it was written that a caller could not also write, and with the
tuple test what remains open is exactly what `supersede_assertion()` already
lets that caller do on that tuple, which is the separate gap recorded below.

Two consequences to accept. A merge under a strict scope moves the copied
assertions into review instead of carrying them across accepted; the content is
preserved and an admin accepts it from `review_queue`. And the guard resolves
the governing scope without a witness, because evidence is written after the
assertion, so a scope reached only through `scope_governs_source` does not
demote a raw insert. Both are in the contract.

## C. status and superseded_at, exactly

- `status`: `candidate` to `accepted` only, on a row with `superseded_at` null,
  with no accepted rival on the same `subject_ref`, `assertion_type`,
  `assertion_key` covering the instant the promoted row takes effect, and with
  an `assertion_accepted` event naming the row (deferred). An `agent:*` caller
  under `candidates_only` or `strict`, or on `pattern_claim`, additionally
  needs `agent_can_promote_in_scope()`, re-deriving the scope from the same
  witness query `accept_assertion()` uses. Any other change to `status` is
  refused, including `accepted` to `candidate`. `record_assertion()` demotes
  before it inserts, so no helper needs the reverse.
- **The rival instant, corrected 2026-09-19 after verification.** "Any
  overlapping window" was wrong, and the builder was right to avoid it:
  `accept_assertion()` legitimately promotes a candidate covering now while a
  future-effective accepted row stands. Skipping the test for a
  future-effective candidate, as the builder then did, let a raw promotion
  leave two accepted rows overlapping on one tuple where `accept_assertion()`
  leaves one. The rule is the Lead's: refuse when an assertion other than this
  one, on the same `subject_ref`, `assertion_type` and `assertion_key`, with
  `status = 'accepted'` and `superseded_at` null, covers
  `greatest(coalesce(NEW.effective_at, now()), now())`, where a row covers an
  instant `T` when `(effective_at IS NULL OR effective_at <= T)` and
  `(effective_to IS NULL OR effective_to > T)`.

  Checked against what `accept_assertion()` really does: it takes its incumbent
  from `current_valid_assertions`, which is accepted, unsuperseded, and
  covering now, and supersedes it before the promotion, whatever the
  candidate's own `effective_at`. A candidate effective now passes, because
  that incumbent is already superseded. A future-effective candidate passes
  too, because an incumbent with an open `effective_to` covers the future
  instant as well and was superseded. What it now refuses is a promotion into
  an instant held by a *scheduled* accepted row that `accept_assertion()` does
  not supersede, which today leaves two overlapping accepted rows. That is a
  deliberate narrowing of the helper, not a regression: the partial unique
  index already refuses the same pair when the windows are identical, and this
  closes the case where they merely overlap. A raw promotion of an expired
  candidate while an unrelated current row stands is also refused, which is
  stricter than overlap requires and matches what `accept_assertion()` would
  have done to that row.
- `classification`: tighter than first written, on the builder's finding and
  verified safe. The row must have derivation evidence, and the new value must
  equal `derived_assertion_classification()` of that evidence. The propagation
  trigger fires only on a `derivation` evidence insert, so evidence always
  exists on the one legitimate path, and requiring it removes the case where an
  empty source set makes the derived value null and a hand-written null passes.
- Only `agent:*` callers are policy-gated on promotion. Every other role is
  tested for shape and for the settle gate and not for the review policy,
  because `accept_assertion()` applies the policy to agent roles only and this
  guard re-derives that rule rather than inventing a wider one. Said plainly in
  the contract so nobody reads the guard as a role model.
- `superseded_at`: null to non-null once, never back, never re-stamped. When
  `OLD.status = 'accepted'`, `NEW.superseded_by` must be non-null. This was
  checked against what the code does, not against what it looks like it does:
  the only two `mark_assertion_superseded(x, NULL)` call sites are
  `reject_candidate()` in 0017 and 0019, and both refuse unless the row is a
  live candidate first. `merge_nodes()`, `accept_assertion()`,
  `record_assertion()`, `record_distillation()`, `supersede_assertion()` and
  `resolve_knowledge_gap()` all pass a replacement id. So **superseded_at may
  be set with superseded_by null only on a candidate**, and never on a row that
  was accepted.
- `superseded_by`: set once, with `superseded_at`, never the row's own id. The
  named row must carry the same `assertion_type` and `assertion_key`; the
  subject may differ, because `merge_nodes()` points a duplicate's assertion at
  the canonical node's. Checked in the `BEFORE` guard when the row already
  exists, which is the decoy case, and again at commit when it is visible,
  which is the forward-reference case the helpers use.

## D. Every function that updates an assertion

Derived by grep, not memory: `grep -n "UPDATE assertions" schema/migrations/*.sql`
for the direct writers, then the callers of each, taking the last
`CREATE OR REPLACE` of a name as the live definition.

Five functions issue an `UPDATE` against `assertions`. That is the whole set.

| Function | Live in | Columns | Security | Must do under 0025 |
|---|---|---|---|---|
| `mark_assertion_superseded(uuid,uuid)` | 0002 | `superseded_at`, `superseded_by` | INVOKER | nothing |
| `propagate_assertion_classification_from_evidence()` (trigger on `assertion_evidence`) | 0009 | `classification` | INVOKER | nothing; the guard recomputes the same expression in the same session |
| `record_assertion(...)` | 0023 | `effective_to` on the incumbent it narrows | INVOKER | nothing; the row it then inserts is the successor the deferred check wants |
| `mark_assertion_outcome(uuid,text,jsonb)` | 0019 | `attrs` | DEFINER, `REVOKE ALL FROM PUBLIC` | nothing; its merges are additive apart from the outcome keys |
| `accept_assertion(...)` | 0019 | `status` | DEFINER | nothing; it supersedes the incumbent before the update and records the event in the same transaction |

Reaching an update through those five, and therefore in scope for "still works
for a caller it worked for before". Through `mark_assertion_superseded`:
`supersede_assertion` (0017, INVOKER), `record_distillation` (0018, INVOKER),
`reject_candidate` (0019, DEFINER), `merge_nodes` (0005, INVOKER),
`accept_assertion`, `record_assertion`. Through `mark_assertion_outcome`:
`accept_assertion`, `reject_candidate`, `score_due_predictions` (0019,
DEFINER). Through `record_assertion`, and so through its narrowing update:
`schedule_assertion_change` (0014), `record_scope_policy` and
`record_source_of_truth_policy` (0015), `register_scope_convention` and
`record_improvement_cycle` (0013), `create_knowledge_candidate`,
`create_onboarding_scope`, `enable_plugin_for_scope`,
`activate_onboarding_scope`, `create_context_gap_candidate` (0010),
`create_declared_knowledge_series`, `record_declared_knowledge_instance`,
`record_declared_statement`, `promote_declared_statement_to_assertion` (0012),
`set_candidate_status`, `promote_candidate_to_task`, `promote_candidate_to_edge`
(0009), `promote_candidate_node_to_assertion` (0017, DEFINER),
`agent_create_candidate` (0016), `record_prediction`, `record_pattern` (0019),
`describe_category` (0020), `resolve_knowledge_gap` (0017, via
`supersede_assertion`), `instantiate_workflow` (0110), `advance_deal_stage` and
`schedule_deal_stage_change` (0120), `advance_task_status`,
`schedule_task_status_change`, `schedule_milestone_status_change` (0121),
`create_opportunity` (0122), `create_task` (0123). None of them changes.

Not in the set, though a grep for `write_path` finds them:
`update_node_properties` (0007) and `promote_candidate_node_to_assertion`
(0017) use the `update_node_properties` path on `nodes`, not on `assertions`;
`rye_settlers()` (0021) is `STABLE` and writes nothing.

## E. Trigger order

Triggers on `assertions`, with the two 0025 adds:

| Name | Timing | From |
|---|---|---|
| `trg_assertion_evidence_required` | AFTER INSERT OR UPDATE OF status, basis, deferred | 0009 |
| `trg_assertion_settle_gate` | BEFORE INSERT OR UPDATE | 0023 |
| `trg_assertions_immutable` | BEFORE UPDATE | 0002, function replaced by 0025 |
| `trg_assertions_insert_review` | BEFORE INSERT | 0025 |
| `trg_assertions_transition_complete` | AFTER INSERT OR UPDATE, deferred | 0025 |

`BEFORE` row triggers fire alphabetically. `trg_assertion_settle_gate` sorts
first against both new names, in the C collation because `_` (0x5F) precedes
`s`, and in `en_US.UTF-8` because punctuation drops out and `settle` precedes
`insertreview` and `immutable` at the first differing letter. Both collations
agree, which is what makes the order safe to rely on.

It has to be first. `tests/conformance/30_configuration_gate.sql` matches the
message `%is Rye configuration%` on a direct accepted `INSERT` and on raw
`UPDATE`s of `status`, `superseded_at`, `effective_to`, `claim`, and `attrs`.
Run the other way on `INSERT`, `trg_assertions_insert_review` could demote a
gated row to `candidate` under a strict scope, the settle gate would then see
nothing becoming accepted and return, and the suite would pass only because
the core registry node happens not to be governed by a strict scope today. Run
the other way on `UPDATE`, the rewritten immutability guard would refuse the
same writes with its own message and those assertions would fail. With the
settle gate first, both orders of concern disappear: a gated type is refused
before anything else looks at it, and a caller allowed to settle it falls
through to the ordinary rules, which is right, because the review policy
applies to admins too.

`trg_assertions_insert_review` is `INSERT`-only and `trg_assertions_immutable`
is `UPDATE`-only, so they never sort against each other. The two deferred
triggers fire at commit, after every `BEFORE` and `AFTER` trigger of every
statement; both only read and each raises on its own, so their relative order
does not exist as a question.

## F. A viewer inserting assertions at all is a separate gap

Not the same mechanism. `assertion_insert_policy` gates types, never roles; it
says nothing about who may write, and no session-variable forgery is involved.
Whether `viewer` and an unset role may write assertions at all is a question
about Rye's role model, which nothing in the schema states today. It needs a
decision about what each role may do, not a repair to a guard. 0025 reduces the
harm — under a governed strict scope their insert now lands as a candidate —
and leaves the question open. The Lead opens an item.

## G. An admin gets no exemption

An admin may do by helper everything it could do before, and by raw `UPDATE`
nothing a helper does. No rule below the settle gate reads the role in order to
permit. The reason is not tidiness: an exemption keyed on
`app.current_role = 'admin'` is produced by the same `set_config()` this
decision exists to close, so writing one would reopen the hole completely and
for everyone. The cost is real and small. An admin's raw
`UPDATE assertions SET superseded_at = now()` succeeds today and will fail;
`supersede_assertion()` and `reject_candidate()` remain.

## H. Test obligations

A conformance suite, `tests/conformance/31_assertion_lifecycle_gate.sql`;
`conformance.sh` globs the directory so it needs no registration. Every case
runs under a non-superuser role and forges every helper-owned setting first:
`app.write_path` at each of `accept_assertion`, `supersede_assertion`,
`assertion_effective_window`, `assertion_classification`, `assertion_outcome`,
with the matching `app.*_assertion_id` set to the target row.

1. Refuse to run vacuously: raise if `current_setting('is_superuser')` is `on`,
   if `row_security` is `off`, and if
   `current_setting('app.current_role', true)` does not read back the value the
   case meant to set. `SET app.current_role = ...` is a syntax error because
   `current_role` is reserved; use `set_config()`, and assert the read-back.
2. Under `agent:t`, `viewer`, `team_member`, and no role: a direct `INSERT` of
   an accepted ordinary assertion under a scope whose review policy is `strict`
   lands `candidate`; under `open` it lands `accepted`, which is what
   `record_assertion()` would have done for the same caller.
3. Under the same four: a raw `UPDATE ... SET status = 'accepted'` on a live
   candidate is refused with every setting forged. Check `ROW_COUNT` after the
   update, because RLS turns a refusal into zero rows rather than an error, and
   check that the row is still `candidate` afterwards.
4. Under the same four: a raw `UPDATE ... SET superseded_at = now()` on an
   accepted row is refused and `superseded_at` is still null.
5. Under the same four: a raw narrowing of `effective_to`, a raw `attrs`
   rewrite that drops or changes a key, and a raw `classification` change to
   `public` are each refused, and each row is unchanged afterwards.
6. A decoy replacement: a raw `UPDATE` setting `superseded_at` and
   `superseded_by` to an existing assertion of a different type or key is
   refused at the statement.
7. A deferred refusal is a refusal: a case that only the commit-time check
   catches must force it with `SET CONSTRAINTS trg_assertions_transition_complete
   IMMEDIATE` inside the block, or assert that the transaction fails. A plpgsql
   `EXCEPTION` block does not see a deferred trigger otherwise. Then assert the
   row is unchanged after rollback.
8. Every helper still works for a caller it worked for before, each asserted by
   its effect and not only by not raising: `record_assertion`,
   `accept_assertion`, `reject_candidate`, `supersede_assertion`,
   `schedule_assertion_change`, `record_distillation`, `resolve_knowledge_gap`,
   `mark_assertion_outcome`, `score_due_predictions`, `merge_nodes`, window
   narrowing inside `record_assertion` (a future-effective write closes the
   incumbent's window at the new `effective_at`), classification propagation
   (a derivation evidence row sets the derived classification), and the profile
   helpers `advance_deal_stage`, `schedule_deal_stage_change`,
   `advance_task_status`, `schedule_task_status_change`,
   `schedule_milestone_status_change`, `create_opportunity`, `create_task`,
   `instantiate_workflow`.
9. A helper still refuses what it refused before: an `agent:*` caller under a
   `strict` policy cannot accept through `accept_assertion()`, and the same
   caller cannot reach the same end by raw `UPDATE`.
10. `reject_candidate()` still closes a candidate with `superseded_by` null,
    proving the accepted-row rule did not swallow the candidate case.
11. `merge_nodes()` with the duplicate's subject in an `open` scope and the
    canonical's in a `strict` one: the copied assertion lands as a candidate on
    the canonical node and appears in `review_queue`. The duplicate's policy
    must not carry across. Run the same-scope strict case too. If either does
    anything else, the exemption is too wide.
12. work/005 is unchanged: `tests/conformance/30_configuration_gate.sql` passes
    unmodified, including its `%is Rye configuration%` message assertions,
    which is the trigger-order check.
13. The suite fails on a tree without 0025. Run it once against the previous
    migration set and record that it fails, before running it against the new
    one.
14. `./scripts/docker-test.sh test --reset --profiles crm,pm` passes from an
    empty volume, on an unused `RYE_POSTGRES_PORT` and the builder's own
    `COMPOSE_PROJECT_NAME`.
15. The cross-scope exemption attack, which is obligation 11's cause and must
    be tested directly. As `agent:t`: take an accepted row on a subject in an
    `open` scope, `UPDATE` it setting `superseded_at` and `superseded_by` to a
    fresh uuid, then `INSERT` that uuid as an accepted assertion on a subject
    in a `strict` scope. It must not commit accepted. Then run the honest
    version — same subject, type, and key on both sides — and assert it does
    commit accepted, because that is `supersede_assertion()`'s own shape and
    refusing it would strand the key.
16. Future-effective promotion. On one tuple, stand an accepted row and a
    scheduled accepted row starting at `F`, then raw-promote a candidate whose
    `effective_at` is `F`. It must be refused, and afterwards exactly one
    accepted unsuperseded row may cover `F`. Assert the count, not the error
    alone. Then show `accept_assertion()` still promotes a candidate covering
    now while the scheduled row stands.

## I. The protection boundary

The migration header, the contract, and the trigger comments say the same
thing and no more. Rye's authorization is session variables. A caller with a
raw connection can set `app.current_role` to `admin`, and this changes nothing
about that. What is protected is a deployment where a trusted backend sets the
session variables and callers cannot, and a well-behaved agent that states its
role honestly and must not skip review by accident or by following bad
instructions. It is not a defence against a hostile caller with a raw
connection.

Inside that, three claims hold for any caller at all, forged role included,
because they read no role: an accepted assertion cannot be ended without a
replacement of the same type and key; a window cannot be narrowed without a
successor; and an assertion's claim, basis, confidence, and subject cannot be
rewritten. Nothing anywhere may claim more than that.

## Cost

No helper signature changes and no caller-visible message changes on the paths
agents use, so no agent-kit item: `skills/rye-agent-ops` already tells agents
not to run a direct `UPDATE`. New refusals a client may now see are listed in
the contract, including that three of them arrive at `COMMIT`. An admin loses
the raw-`UPDATE` shortcuts described in G. A merge under a strict scope now
routes through review. The insert path pays one scope resolution on instances
that have an active onboarding scope, and nothing on instances that do not.
