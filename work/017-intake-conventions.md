# 017 intake-conventions

- status: done
- opened: 2026-09-20
- areas: agent-kit
- contracts: none
- base revision: 6aabedd on main
- closes: issue 13

## Goal
An ingestion agent following Rye's skills does not repeat the four defects blind reconstruction caught: an employment edge left open after a departure was recorded; a digest that claimed more than its sources establish; an assertion's effective date and an edge's window telling two different handoff stories; a derived number that named a different window than its sources.

## Acceptance criteria
- [x] docs/agent-ops-guide.md's intake section and the skills that ingest (rye-agent-ops, rye-source-context-intake, rye-tabular-intake, rye-gardener) each state the four rules in plain words with one executable example each, run against a live install as the role the text names.
- [x] Each rule has a check an agent or gardener can run: a read that lists departed people with an open employs or role edge; digests whose claim keys are not covered by their source assertions where that is decidable; assertions whose effective_at disagrees with the matching edge window; derived numeric claims with no cited source window. Reads only, as queries in the skill or the pattern library; a schema helper only if a query cannot express it, and then say so and stop for the Lead.
- [x] A replay scenario or rubric line grades each rule, consistent with today's schema behavior (agents suggest; review policy may demote; viewer writes nothing).
- [x] Area checks, manifest validation, and conformance 22 and 23 pass.

## Constraints
- Skills, docs, eval only. No schema change in this item.
- No applied migration is edited: 0001 to 0030 and 0100 to 0124 are applied on main. Every function declares search_path. Authorization is session variables only: no current_user, session_user, or pg_has_role().
- Write gate (work/009): viewer and role-less sessions write nothing; new supporting-table rules call rye_may_write_table(). Review policy holds on every route (work/010). Tests run under a non-superuser role AND under scripts/test-nonsuperuser-owner.sh, fail without the new migration, and refuse to pass vacuously.
- No GitHub Actions and no .github/ files. The gate is ./scripts/test-all.sh run locally with your own COMPOSE_PROJECT_NAME and RYE_POSTGRES_PORT. Run ./scripts/bootstrap-worktree.sh first in a worktree, never in the main checkout. No /tmp scratch. No push; the Lead opens the pull request.
- No customer names. Invented names only.

## Decided by the human
- 2026-09-20, Casey: take all outstanding issues and merge them to main through issues and pull requests.

## Assumed by default
- Validation is advisory reads, not write-path gates, following issue 17's principle that the database gates outcomes, not steps. Overturn: Casey.

## Verified
- Verifier, two passes by execution on a fresh install under a non-superuser role; second pass PASS. Every SQL block runs as the role the text names. Fixture: 8 findings across 5 checks before repair, 0 after. Check 4a on a clean crm,pm install with seed data returns 0 rows; without its exclusion list it returns 5, all registry_entry, exactly the documented noise. The role-edge list reproduces from plugins/*/rye-plugin.json when the file's derivation is followed; owns and responsible_for are handoff, not close. The replay scenario keeps candidates_only: check 1 goes quiet there and check 1s finds the waiting departure. Correction advice verified both ways: against an accepted assertion a date-only record_assertion() writes nothing; against a pending suggestion it writes a second one and supersede_assertion() raises. Manifests valid; conformance 22 and 23 pass.
- First pass FAIL on eight findings (a basis filter that let the fixture's own bad number escape; two rubric lines false under the scenario's policy; one rule statement missing its negation; seven plugin edge types missing), all fixed in b6d91ae.
- Found, outside this item: reject_candidate() has no role, settler, or authorship gate; an agent closed another agent's, a person's, and a configuration suggestion. Routed to work/018.
- Lead, integration: ./scripts/test-all.sh on this branch tip, result in the pull request.


## Reports

## Close
done 2026-09-20. Closes issue 13.
