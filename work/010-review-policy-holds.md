# 010 review-policy-holds

- status: open
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
- [ ] Under a scope where record_assertion() would land a caller's write as a candidate, supersede_assertion() by the same caller does not land an accepted replacement and does not end the accepted incumbent. Nothing said is lost: the replacement lands as a candidate a settler can accept, and accepting it then supersedes the incumbent. The caller is told it is waiting. Same for every helper that reaches supersede_assertion() (the Architect lists them, resolve_knowledge_gap included) and for the raw supersede-and-replace shape work/008's insert exemption allows.
- [ ] Where record_assertion() would land accepted, supersede_assertion() behaves as today.
- [ ] When more than one scope governs a subject, the answer does not depend on uuid order. The Architect states the rule (the Lead's default: the most restrictive review policy among the governing scopes wins) and what governing_scope()'s other callers see.
- [ ] After merge_nodes() across an open and a strict scope, in either id order, the surviving node reads strict and the copied assertions are in review_queue.
- [ ] work/008 obligation 11 in test 31 no longer depends on pinned scope id order; the comment saying so is removed. Tests 30 and 31 otherwise pass unmodified in meaning.
- [ ] A test covers each case under a non-superuser role and the non-superuser owner, fails without the new migration, and refuses to pass vacuously.
- [ ] `./scripts/test-all.sh` passes.

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

## Verified
- filled in at close

## Reports
### Architect, 2026-09-20 (commits 7356ce2, 32504b7, 940a5a9)
Decision 0010. supersede_assertion() writes the replacement as a candidate
where record_assertion() would demote, leaves the incumbent accepted, marks
attrs.review_gate with a NOTICE, same return. Most restrictive policy wins
(strict, candidates_only, open), scope.id only as tie-break, through a
never-raising scope_review_policy_rank(). Migration 0027 replaces
supersede_assertion, governing_scope, assertions_insert_review_guard, and
resolve_knowledge_gap; no overlap with 0026.


## Close
status line and date
