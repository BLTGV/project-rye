# 016 admin-view-layer

- status: done
- opened: 2026-09-20
- areas: schema, admin
- contracts: contracts/sql-surface.md, contracts/admin-api.md
- base revision: 6aabedd on main
- closes: issue 12

## Goal
The reviewer's screen gets what it needs from Rye's views instead of compensating with correlated subqueries. Issue 12 lists five gaps found while building the review queue.

## Acceptance criteria
- [x] A suggestion shows a projected effective confidence. Today `effective_confidence()` is null for candidates because its view is scoped to current_valid_assertions.
- [x] `review_queue` carries the subject's label, the incumbent it would replace, its evidence summary, its confidence, and (since work/010 and 011) why it is waiting: attrs.review_gate or attrs.settle_gate. Existing columns keep their names and meaning; the admin queries that compensated are simplified and return the same rows.
- [x] `stale_digests` names the culprit: the newer assertion or the overturned source, by id, so a stale badge can link to it.
- [x] Rejected suggestions have a read surface with who rejected, when, and why, without querying events by hand. `reject_candidate()` leaves status candidate with superseded_at set; the surface must not confuse rejected with waiting.
- [x] `opportunities_active` cannot silently serve stale contact data: a staleness marker or a refresh rule, chosen by the Architect with its cost stated.
- [x] Every new or changed view is security invoker, shows a caller nothing it could not read directly, under both owner types, and is tested so. The admin Worker uses them through ryeQuery(); check:db and check:routes pass; the API contract states any new field.
- [x] ./scripts/test-all.sh passes.

## Constraints
- Migration 0035 (and a 01xx-numbered file for the crm profile's matview, because profile migrations apply after core ones), conformance 41.
- No applied migration is edited: 0001 to 0030 and 0100 to 0124 are applied on main. Every function declares search_path. Authorization is session variables only: no current_user, session_user, or pg_has_role().
- Write gate (work/009): viewer and role-less sessions write nothing; new supporting-table rules call rye_may_write_table(). Review policy holds on every route (work/010). Tests run under a non-superuser role AND under scripts/test-nonsuperuser-owner.sh, fail without the new migration, and refuse to pass vacuously.
- No GitHub Actions and no .github/ files. The gate is ./scripts/test-all.sh run locally with your own COMPOSE_PROJECT_NAME and RYE_POSTGRES_PORT. Run ./scripts/bootstrap-worktree.sh first in a worktree, never in the main checkout. No /tmp scratch. No push; the Lead opens the pull request.
- No customer names. Invented names only.

## Decided by the human
- 2026-09-20, Casey: take all outstanding issues and merge them to main through issues and pull requests.

## Assumed by default
- Views change by CREATE OR REPLACE with columns appended, never reordered or renamed. Overturn: Architect.

## Verified
- Verifier, by execution under both database owner types, both halves on one tree: PASS on the first pass. Control databases with and without 0035 and identical fixtures: the pre-existing columns of review_queue, competing_candidates, and stale_digests are byte-identical in name, type, order, and row values; appended columns match the contract exactly. projected_effective_confidence() is non-null for live suggestions (a lone one 0.50, two rivals 0.56 and 0.64, neither zeroing the other) and null for a rejected one. waiting_reason is settle_gate, review_gate, or none, and a row carrying both markers reads settle_gate. rejected_candidates is disjoint from the waiting views by construction and by test; a rival left behind by an acceptance is still waiting, never rejected. stale_digests names the culprit ids, arrays empty never null. opportunities_active carries snapshot_at; unset threshold is 15 minutes; the threshold is settle-gated configuration, so a team member's write is demoted and changes nothing.
- Visibility, five roles by two owners: every view is security invoker and shows nothing the caller could not read directly. A classified incumbent reads as no incumbent; evidence counts differ by caller (2/1 versus 3/2); a team-hidden subject is absent with no label leak. The API's extra join on incumbent_assertion_id cannot widen what the view hid.
- Admin API: all five compensations from decision 0012 section H are gone; old admin versus new admin over matched data differs in exactly the one contract-stated row (an expired accepted incumbent now shown with is_current false); stats.total and stats.filtered hold across pages; page 1 plus page 2 equals the first rows of the full listing for rows written in one transaction (a unique tie-break was added; the old ORDER BY was not a total order); agent tokens without the capability get 403; check:db and check:routes pass; the screen says an unseen incumbent "may mean there is none, or that you may not see it".
- Suite 41 fails without 0035, refuses a superuser; crm-only and pm-only installs verify; its one committed fixture node is not duplicated on re-run.
- Lead, integration: the builder merged main (3a61d5b; scripts/verify.sh needed both sides plus one END IF; checked by dropping one object of each item); ./scripts/test-all.sh on this branch tip, result in the pull request.


## Reports

## Close
done 2026-09-20. Closes issue 12.
