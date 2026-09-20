# 016 admin-view-layer

- status: open
- opened: 2026-09-20
- areas: schema, admin
- contracts: contracts/sql-surface.md, contracts/admin-api.md
- base revision: 6aabedd on main
- closes: issue 12

## Goal
The reviewer's screen gets what it needs from Rye's views instead of compensating with correlated subqueries. Issue 12 lists five gaps found while building the review queue.

## Acceptance criteria
- [ ] A suggestion shows a projected effective confidence. Today `effective_confidence()` is null for candidates because its view is scoped to current_valid_assertions.
- [ ] `review_queue` carries the subject's label, the incumbent it would replace, its evidence summary, its confidence, and (since work/010 and 011) why it is waiting: attrs.review_gate or attrs.settle_gate. Existing columns keep their names and meaning; the admin queries that compensated are simplified and return the same rows.
- [ ] `stale_digests` names the culprit: the newer assertion or the overturned source, by id, so a stale badge can link to it.
- [ ] Rejected suggestions have a read surface with who rejected, when, and why, without querying events by hand. `reject_candidate()` leaves status candidate with superseded_at set; the surface must not confuse rejected with waiting.
- [ ] `opportunities_active` cannot silently serve stale contact data: a staleness marker or a refresh rule, chosen by the Architect with its cost stated.
- [ ] Every new or changed view is security invoker, shows a caller nothing it could not read directly, under both owner types, and is tested so. The admin Worker uses them through ryeQuery(); check:db and check:routes pass; the API contract states any new field.
- [ ] ./scripts/test-all.sh passes.

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
- filled in at close

## Reports

## Close
status line and date
