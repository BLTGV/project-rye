# 010 review-policy-holds

- status: done
- opened: 2026-09-20
- areas: schema
- contracts: contracts/sql-surface.md
- base revision: 642a889 on agent-roles

## Goal
An area's review policy holds on every route. Two routes go around it today.
`supersede_assertion()` never consults the review policy: it inserts the
replacement accepted, so any caller lands an accepted row under `strict` by
superseding. And after `merge_nodes()` across two scopes, both scopes govern
the surviving node and `governing_scope()` picks the one with the lowest uuid,
so a node in a strict area can silently become open.

## Intent excerpt (BRIEF.md)
"Agents suggest; people accept. Review policy is per scope." "Accepted stays
accepted until a settler changes it."

## Found by execution
- work/008 Architect and Verifier: supersede_assertion() under strict as agent:t lands the replacement accepted; record_assertion() for the same caller and claim lands a candidate.
- work/008 Verifier, scope ids pinned both ways: duplicate in an open scope with the lower uuid, canonical strict: copy accepted and the canonical's policy reads open after the merge. Higher uuid: candidate, strict.

## Acceptance criteria
- [x] Under a scope where record_assertion() would land a caller's write as a candidate, supersede_assertion() by the same caller does not land an accepted replacement and does not end the accepted incumbent. Nothing said is lost: the replacement lands as a candidate a settler can accept, and accepting it then supersedes the incumbent. The caller is told it is waiting. Same for every helper that reaches supersede_assertion() (the Architect lists them, resolve_knowledge_gap included) and for the raw supersede-and-replace shape work/008's insert exemption allows.
- [x] Where record_assertion() would land accepted, supersede_assertion() behaves as today.
- [x] When more than one scope governs a subject, the answer does not depend on uuid order. The Architect states the rule (the Lead's default: the most restrictive review policy among the governing scopes wins) and what governing_scope()'s other callers see.
- [x] After merge_nodes() across an open and a strict scope, in either id order, the surviving node reads strict and the copied assertions are in review_queue.
- [x] work/008 obligation 11 in test 31 no longer depends on pinned scope id order; the comment saying so is removed. Tests 30 and 31 otherwise pass unmodified in meaning.
- [x] A test covers each case under a non-superuser role and the non-superuser owner, fails without the new migration, and refuses to pass vacuously.
- [x] `./scripts/test-all.sh` passes.

## Constraints
- One new migration, 0027 (work/009 has 0026). No applied migration edited. Function signatures unchanged.
- Session variables only; search_path on every function; no new tables.
- The contract's stated limit "supersede_assertion() and the review policy" is removed once true. work/008's deferred key test must still pass for the legitimate shapes.
- Docker: own COMPOSE_PROJECT_NAME and RYE_POSTGRES_PORT. No /tmp scratch. No push.

## Decided by the human
- 2026-09-20, Casey: fix the remaining items so the branch can be merged.

## Assumed by default
- Demote, do not refuse, so nothing said is lost (as decision 0007 and work/008 did). Overturn: Architect.
- Most restrictive policy wins among several governing scopes. Overturn: Casey, since it changes which areas review what after a merge.
- resolve_knowledge_gap() under strict can produce a candidate accept_assertion() refuses (inferred displacing non-inferred). Disclosed, accept_assertion() not loosened. Overturn: Architect.
- 0025's insert exemption is removed, so a raw supersede-and-replace under a demoting policy is refused at commit. Overturn: Architect.
- Helpers take the stricter of the witness-resolved and witness-free policies. Visible change: a `scope_governs_source` edge from an open scope no longer opens a source on an instance whose DEFAULT_SCOPE is strict or candidates_only; those writes land as suggestions. Remedy: a direct scope_governs_subject edge to the open scope. Overturn: Casey.

## Verified
- Verifier, two passes by execution under both owner types. Second pass PASS: supersede_assertion(), record_assertion(), record_distillation(), and resolve_knowledge_gap() agree with each other and with the insert guard in 108 cells (3 DEFAULT_SCOPE policies by 3 witness-scope policies by 6 helpers by 2 roles), all commit, accepted only when both resolutions are open; under a demoting policy the replacement is a candidate with attrs.review_gate and a NOTICE, the incumbent stays accepted, and accepting the candidate supersedes it under 0025's deferred checks; most restrictive policy wins in both scope id orders on all three branches; merge_nodes() across open and strict leaves the survivor strict with copies in review_queue; 0025's promises hold with the insert exemption removed; carried-forward bodies differ from 0023 and 0018 only in the policy resolution; work/005 behaviors unchanged; pg_proc gains exactly effective_review_policy and scope_review_policy_rank. Suite 33 fails without 0027 and refuses a superuser.
- Lead, integration: merged at 0da28d1; verified again together with 0026 by work/009's third pass; final combined run on b7da6fd exit 0.
- Known and stated: moving DEFAULT_SCOPE off a strict scope is two steps; a DEFAULT_SCOPE with an unsupported review_policy still refuses every write, as before; resolve_knowledge_gap() under strict can file a candidate accept_assertion() refuses (inferred displacing non-inferred).


## Reports
### Architect, 2026-09-20 (commits 7356ce2, 32504b7, 940a5a9)
Decision 0010. supersede_assertion() writes the replacement as a candidate
where record_assertion() would demote, leaves the incumbent accepted, marks
attrs.review_gate with a NOTICE, same return. Most restrictive policy wins
(strict, candidates_only, open), scope.id only as tie-break, through a
never-raising scope_review_policy_rank(). Migration 0027 replaces
supersede_assertion, governing_scope, assertions_insert_review_guard, and
resolve_knowledge_gap; no overlap with 0026.


### Builder schema, 2026-09-20 (branch worktree-agent-af00e77e25c00877a, commit 1d93913)
0027 as decision 0010; new suite; three scoped changes to test 31
(obligation 11b ids and comment, obligation 15's honest half). Negative
control fails at obligation 2. test-all.sh green twice. Raised the witness
and DEFAULT_SCOPE question himself.

### Verifier, 2026-09-20, first pass: FAIL
HIGH, regression: helper resolves an open scope through a witness, the
witness-free guard falls through to a strict DEFAULT_SCOPE, demotes the
helper's replacement, and the commit check refuses the transaction. 30 of 30
other combinations match record_assertion(); strictest wins in both id
orders; constraints pass. Routed for agent-kit: source_context_commit_rye.mts
ignores the returned status; pattern-library common-patterns.md line 64.

### Architect, 2026-09-20 (b5ceea9)
effective_review_policy(): stricter of the two resolutions. 0027 also
replaces record_assertion and record_distillation. Fix attempt 1 sent.

### Builder schema, 2026-09-20, fix attempt 1 (commit 02f4242)
effective_review_policy(); record_assertion() carried from 0023 with 17
changed lines, all in the policy resolution; record_distillation() from
0018. Suite renamed 33.

### Verifier, 2026-09-20, second pass: PASS
108 cells (3 DEFAULT_SCOPE by 3 witness-scope policies by 6 helpers by 2
roles) all commit, accepted only when both resolutions are open. Branch
hunt clean. Bodies differ only in the policy resolution. LOW: the other two
demoting helpers wrote no review_gate marker; closed in work/011 (0030).
INFO: moving DEFAULT_SCOPE off a strict scope is now two steps (suggest,
then accept).

## Close
done 2026-09-20. Merged to agent-roles at 0da28d1; combined suite passed on b7da6fd. One verifier failure (a helper resolving an open scope through a witness under a strict DEFAULT_SCOPE aborted its own transaction), closed by taking the stricter of the two resolutions.
