# 0010 Review policy holds on every route

Date: 2026-09-20. Work item: `work/010-review-policy-holds.md`.
Contract: `contracts/sql-surface.md`, section "Review policy holds on every
route". Areas: schema. Migration: `0027`.

## The gap

Two routes went around a scope's review policy.

`supersede_assertion()` never consulted it. It inserts the replacement with
status `accepted`, unconditionally, so any caller landed an accepted row under
`strict` by superseding one — while `record_assertion()` for the same caller and
the same claim landed a candidate. work/008's Architect and Verifier both
reproduced it under `agent:t`, and the contract has carried it as a stated limit
since.

And `governing_scope()` broke ties with `ORDER BY scope.id`. `merge_nodes()`
re-points the duplicate's `scope_governs_subject` edge onto the canonical node,
so after a cross-scope merge two scopes govern it and the lowest uuid won.
work/008's Verifier pinned the ids both ways and committed both answers: with
the open scope lower, the copy is accepted and the canonical reads `open`; with
it higher, candidate and `strict`. A node in a strict area could silently become
open, and `tests/conformance/31_assertion_lifecycle_gate.sql` obligation 11 had
to pin uuids to be deterministic.

## F. Demote, do not refuse, and do not end the incumbent

`supersede_assertion()` resolves the governing scope from the incumbent's own
subject, type, and primary witness — the same witness query
`accept_assertion()` uses, `kind` in `source` or `corroboration`, ordered `source`
first then `recorded_at` then `id` — and applies the same predicate
`record_assertion()` applies: demote when the policy is `strict`, or
`candidates_only` with a replacement basis other than `observed`. Using the same
predicate is not tidiness; it is the acceptance criterion, which is written as
"under a scope where `record_assertion()` would land a caller's write as a
candidate".

When it demotes, it writes the replacement as a **candidate** and **does not**
call `mark_assertion_superseded()`. The incumbent stays accepted and
unsuperseded. Evidence is still appended. The tuple then carries one accepted
row and one candidate, which is what `review_queue` and `competing_candidates`
are for, and `accept_assertion()` on the candidate supersedes the incumbent
then — the ordinary acceptance path, with the ordinary rival check and the
ordinary acceptance event.

Rejected: refusing. The item's default, and `0007`'s and `0008`'s, is that
nothing said is lost. Refusing throws away a correction someone took the trouble
to state.

Rejected: demoting *and* ending the incumbent. That is the erasure `0008` exists
to prevent. It would leave the key with no accepted value and let any caller
delete a fact by proposing a replacement to it — a worse hole than the one being
closed.

Rejected: ending the incumbent and inserting the replacement accepted only for
roles the policy exempts. There is no such exemption; `record_assertion()`
demotes for every role, and inventing a role test here would contradict
`0008`'s rule that no rule permits on the basis of a claimed role.

**How the caller is told.** The signature is unchanged and so is the return
type: the new row's id, whether accepted or candidate. **The return value does
not say what happened; the row does.** The candidate carries
`attrs.review_gate = {pending, requested_status, review_policy, scope_node_id,
incumbent_assertion_id}`, deliberately the same shape as the
`attrs.settle_gate` marker `0023` writes for the other demotion, so a client has
one thing to look for and not two. A `NOTICE` names the incumbent and the
policy, for an interactive caller. Rejected: an `OUT` parameter or a jsonb
return, which are signature changes the item forbids and which every existing
caller would have to be rewritten for. Rejected: telling the caller nothing —
the criterion says the caller is told it is waiting.

**Per helper, derived by grep.** Exactly one in-repo helper calls
`supersede_assertion()`: `resolve_knowledge_gap()` (0017). It files the resolved
gap as a candidate, the `knowledge_gap` assertion stays open and stays in
`open_gaps`, and the `knowledge_gap_resolved` event gains `pending_review` and
`review_policy` in its properties so a reader is not told the gap closed when it
did not. The event type is unchanged, because the act did happen and consumers
match on the type.

`record_distillation()` does not call it — it supersedes the digest incumbent
through `mark_assertion_superseded()` directly, and it already applies the
policy itself and only supersedes when its own write is accepted.
`schedule_assertion_change()` reaches `record_assertion()`, which already
demotes. Every profile helper reaches `record_assertion()` too.
`accept_assertion()`, `reject_candidate()`, and `merge_nodes()` never call it.
None of them changes.

**One limit, disclosed rather than fixed.** `resolve_knowledge_gap()` writes its
replacement with basis `inferred`, and `accept_assertion()` refuses an inferred
candidate displacing a non-inferred accepted incumbent. So under a demoting
policy, a gap recorded with some other basis produces a candidate no settler can
accept. The ways out are to record gaps with basis `inferred`, which is what a
gap is, or to reject the resolution candidate and record the resolved gap with
`record_assertion()`. Widening `accept_assertion()`'s inferred-displacement rule
to make this case pass was rejected: it is a rule about evidence quality that
work/008 verified and pinned, and loosening it to serve one helper is a bigger
change than the one being made.

## The insert exemption follows the helper, which means it goes

`0025` leaves a row accepted when an assertion on the same `subject_ref`,
`assertion_type`, and `assertion_key` is already superseded, was accepted, and
names this row as its replacement. `0008` justified it in one sentence: what it
leaves open is exactly what `supersede_assertion()` already lets that caller do
on that tuple, so it adds nothing. Once the helper demotes, that sentence is
false, and the exemption is the last accepted-under-`strict` route left.

**The exact new rule: the exemption is removed.** Not narrowed — removed.
Checked against every helper that inserts an assertion, which is the only reason
it existed:

- `supersede_assertion()` under a demoting policy no longer ends the incumbent
  and inserts a candidate, so the guard's demotion branch is never reached.
  Under a non-demoting policy it ends the incumbent and inserts accepted, and
  the guard does not demote either.
- `record_assertion()` applies the policy before it supersedes, so it never ends
  an incumbent for a write it is about to demote.
- `record_distillation()` does the same.
- `merge_nodes()` inserts the copy *before* it marks the duplicate's row, so
  the exemption never applied to it in the first place. The copy is judged by
  the canonical node's policy, which is obligation 11's answer.
- `accept_assertion()` does not insert.

The one direction that could strand a key is the guard being *stricter* than the
helper, and it cannot be: the guard resolves the scope with a null witness while
the helpers pass one, and the witness branch in `governing_scope()` runs only
after the subject, inheritance, and type branches have all produced nothing. So
the guard's scope is the helper's scope or none at all, and its policy is the
helper's policy or `open`. That asymmetry stays and is still a stated limit.

The consequence for the raw supersede-and-replace shape is a refusal rather than
a demotion: the incumbent was ended, the replacement is demoted to candidate,
the tuple carries nothing accepted, and `trg_assertions_transition_complete`
refuses the transaction at commit. Nothing is lost — the incumbent still stands
after the rollback, and `supersede_assertion()` records the same statement as a
suggestion beside it. Under a non-demoting policy the shape still commits
accepted, unchanged.

**The `0008` limit removed** is the second of the six: "`supersede_assertion()`
does not consult the review policy, so a caller who supersedes and replaces an
accepted row still writes an accepted row under `strict`; that is unchanged here
and is its own item." The contract's list is now five, renumbered.

## G. The most restrictive policy wins

When several scopes govern a subject, the governing scope is the one whose
review policy is most restrictive: `strict` over `candidates_only` over `open`,
with `scope.id` still breaking a genuine tie so the answer stays deterministic.

`governing_scope()` keeps its signature and **still returns one scope id**.
Rejected: returning a set or the policy directly. Its callers use the id for
more than the policy — `agent_can_promote_in_scope()` takes it, the explicit
`p_scope_node_id` mismatch test compares against it, `canonical_type_in_scope()`
resolves in it, and `registry_value(..., scope)` reads from it — so changing the
return type changes four functions and the 0025 guard, which is the opposite of
keeping this migration independent of `0026`.

The branch order is unchanged and still decides first: direct
`scope_governs_subject` coverage, then inheritance through `has_step`, then type
coverage, then the witness, then `DEFAULT_SCOPE`. Restrictiveness orders the
candidates *within* the branch that matched. For an edge subject the source
endpoint still beats the target endpoint before restrictiveness is consulted,
because that rule chooses which subject is being governed, not which scope
governs it. Type coverage keeps its `Ambiguous governing scope` exception: two
active scopes claiming one type is an administrative error someone has to fix,
and silently picking the stricter one would hide it.

Ranking uses a new read-only helper, `scope_review_policy_rank(uuid) RETURNS
int` — `0` strict, `1` candidates_only, `2` everything else — which **never
raises**. `scope_review_policy()` raises on an unsupported stored value, and
calling it from an `ORDER BY` would let one broken scope refuse every write near
any scope in the same branch. With the rank helper, a broken scope sorts as
`open` and still raises from `scope_review_policy()` if it is the scope
selected, so today's failure surface is exactly where it was.

What the other callers see is in the contract. The two worth naming here:
`accept_assertion()` now requires an `agent:*` caller to hold
`rye.authoritative.promote` for the **strictest** governing scope rather than
for whichever sorted first, which is a narrowing and the intended one; and
`record_assertion()` can now raise `Explicit scope % does not match governing
scope %` for a caller that passes the looser of two governing scopes.
`agent_can_promote_in_scope()` itself is unchanged — it answers about the scope
it is handed — and the witness asymmetry between `accept_assertion()` and the
`0025` insert guard is unchanged, so nobody should read this as having closed
it.

After a cross-scope merge both scopes govern the surviving node, the stricter
wins in either id order, and copies land as candidates in `review_queue`. That
is what lets obligation 11 drop its pinned uuids.

## H. Test obligations

Extend `tests/conformance/31_assertion_lifecycle_gate.sql` where the case
already lives and add `tests/conformance/33_review_policy_routes.sql` for the
rest. Every case runs under a non-superuser role and is repeated under
`./scripts/test-nonsuperuser-owner.sh`, where suites run as `rye_owner` with no
`SET ROLE`.

1. Refuse to run vacuously, as `0008` obligation 1: raise on
   `is_superuser` on, `row_security` off, `rolsuper OR rolbypassrls` true, and a
   role that does not read back.
2. Under `strict`, and under `candidates_only` with a non-`observed` basis, as
   `agent:t`, `team_member`, and `admin`: `supersede_assertion()` returns an id
   whose row is `candidate`, the incumbent is still `accepted` with
   `superseded_at` null, the candidate is in `review_queue`, and
   `attrs->'review_gate'->>'pending'` is true. Assert all four, not the status
   alone. `admin` is in the list because the policy is not a role rule.
3. The same claim through `record_assertion()` for the same caller and scope
   also lands `candidate`. This is the pairing the criterion is written as, and
   a suite that does not assert it cannot show the two agree.
4. Nothing said is lost, end to end: accept the candidate from 2 with
   `accept_assertion()` as a settler, then assert the incumbent is superseded by
   it and `current_valid_assertions` carries the replacement.
5. Under `open`, and under `candidates_only` with basis `observed`,
   `supersede_assertion()` behaves exactly as today: the replacement is
   `accepted`, the incumbent is superseded and names it, and `attrs` carries no
   `review_gate` key.
6. `resolve_knowledge_gap()` under `strict`: the resolution is a candidate, the
   `knowledge_gap` row is still open and still in `open_gaps`, and the
   `knowledge_gap_resolved` event carries `pending_review` true. Under `open` it
   closes the gap exactly as it does today, which
   `tests/conformance/25_core_model_v2.sql` already asserts and must keep
   asserting unmodified.
7. The helpers that must not change, each asserted by effect:
   `record_distillation()` under `strict` still lands a candidate and still
   leaves the digest incumbent standing; `schedule_assertion_change()` under
   `strict` still lands a candidate; one profile helper —
   `advance_task_status()` — still works.
8. The raw route. Under `strict`, with every supersede setting forged: end an
   accepted row naming a fresh id, insert that id accepted on the same tuple,
   and `COMMIT`. The transaction must fail, and afterwards
   `current_valid_assertions` must still hold the incumbent. Force the deferred
   check with `SET CONSTRAINTS trg_assertions_transition_complete IMMEDIATE`
   inside the block or assert the transaction fails, because a plpgsql
   `EXCEPTION` block does not see a deferred trigger.
9. `0008` obligation 15's honest half still holds under a non-demoting policy:
   the same raw shape under `open` commits accepted. Obligation 15 is amended
   rather than deleted, and the amendment is exactly that the strict half now
   refuses instead of demoting.
10. Several scopes, both id orders, with no pinned uuids: two active scopes,
    one `open` and one `strict`, both with a live `scope_governs_subject` edge
    onto one subject. `scope_review_policy(governing_scope(subject, ...))` is
    `strict` whichever scope has the lower id. Run the fixture twice with the
    ids generated, not pinned, and assert the same answer both times.
11. `merge_nodes()` across an open and a strict scope, in **both** id orders:
    afterwards the surviving node reads `strict`, and the copied assertion is a
    candidate in `review_queue` on the canonical node. Anti-vacuity: assert
    before the merge that the duplicate's side really reads `open` and the
    canonical's really reads `strict`, as the current fixture does.
12. `0008` obligation 11 in test 31 no longer pins scope ids, and the comment
    saying the result depends on the pinned order is removed. Tests 30 and 31
    otherwise pass unmodified in meaning.
13. `scope_review_policy_rank()` never raises: a scope carrying an unsupported
    `review_policy` value ranks as `open` and does not break a write on a
    neighbouring subject, while `scope_review_policy()` on that scope still
    raises.
14. The agent promotion gate follows the strictest scope: an agent holding
    `rye.authoritative.promote` for the open scope only cannot accept on a
    subject the strict scope also governs, and one holding it for the strict
    scope can.
15. The suite fails on a tree without `0027`, under both owner types. Run it
    once against the previous migration set and record that it fails.
16. `./scripts/test-all.sh` passes, on the builder's own
    `COMPOSE_PROJECT_NAME` and an unused `RYE_POSTGRES_PORT`.

## What `0027` replaces, and what it must not touch

Replaces: `supersede_assertion()` (live in 0017), `governing_scope()` (0018),
`assertions_insert_review_guard()` (0025), and `resolve_knowledge_gap()` (0017).
Adds `scope_review_policy_rank()`.

Must not touch, because `0026` replaces them for work/009: every `INSERT`,
`UPDATE`, and `DELETE` policy on the seven core tables, `merge_nodes()` (0005),
and `update_node_properties()` (0007). `merge_nodes()` in particular: the merge
behaviour this record promises comes entirely from `governing_scope()`, and the
helper needs no edit. Both items edit
`tests/conformance/31_assertion_lifecycle_gate.sql`, in different regions —
work/009 only where a call must run under an allowed role, work/010 at
obligations 11 and 15.

## Cost

A caller that used `supersede_assertion()` to land an accepted row under
`strict` now lands a candidate, which is the point. A caller that used the raw
supersede-and-replace shape there is refused at commit. A resolved knowledge gap
under `strict` waits for a settler, and one recorded with a non-inferred basis
waits in a way `accept_assertion()` will not resolve, which is disclosed.
`governing_scope()` costs one `scope_review_policy_rank()` call per candidate
scope in the branch that matched, on instances that have more than one active
scope; on instances with none it is unchanged, because the branches return
nothing to order.
