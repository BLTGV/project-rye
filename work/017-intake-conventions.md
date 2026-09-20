# 017 intake-conventions

- status: open
- opened: 2026-09-20
- areas: agent-kit
- contracts: none
- base revision: 6aabedd on main
- closes: issue 13

## Goal
An ingestion agent following Rye's skills does not repeat the four defects blind reconstruction caught: an employment edge left open after a departure was recorded; a digest that claimed more than its sources establish; an assertion's effective date and an edge's window telling two different handoff stories; a derived number that named a different window than its sources.

## Acceptance criteria
- [ ] docs/agent-ops-guide.md's intake section and the skills that ingest (rye-agent-ops, rye-source-context-intake, rye-tabular-intake, rye-gardener) each state the four rules in plain words with one executable example each, run against a live install as the role the text names.
- [ ] Each rule has a check an agent or gardener can run: a read that lists departed people with an open employs or role edge; digests whose claim keys are not covered by their source assertions where that is decidable; assertions whose effective_at disagrees with the matching edge window; derived numeric claims with no cited source window. Reads only, as queries in the skill or the pattern library; a schema helper only if a query cannot express it, and then say so and stop for the Lead.
- [ ] A replay scenario or rubric line grades each rule, consistent with today's schema behavior (agents suggest; review policy may demote; viewer writes nothing).
- [ ] Area checks, manifest validation, and conformance 22 and 23 pass.

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
- filled in at close

## Reports

## Close
status line and date
