# 013 graph-traversal

- status: open
- opened: 2026-09-20
- areas: schema, agent-kit (skill text only if the functions change what an agent is told)
- contracts: contracts/sql-surface.md
- base revision: 6aabedd on main
- supersedes: pull requests 18 (design/proposals/rls-visibility-contract.md, docs/roadmap.md) and 19 (branch retrieval/graph-traversal). Part of issue 17.

## Goal
An agent can find a starting node from text and walk more than one hop, without learning anything it may not read. Pull request 19 adds `find_nodes()`, `find_nodes_batch()`, `find_paths()`, and a neighborhood read, all SECURITY INVOKER, pruning silently under RLS as pull request 18's visibility contract decides. Both predate migrations 0020 to 0030 on main and claim numbers that are taken.

## Acceptance criteria
- [ ] Pull request 18's design document and roadmap change land as written, corrected only where main has since made a sentence false.
- [ ] The traversal and entry-point functions from pull request 19 land as migration 0032 with their conformance (38) and security (03) suites, behaving as its description says: ranked entry point with match_reason; no search over property values, so a redacted field cannot be confirmed by matching; bounded typed paths; nothing auto-logs.
- [ ] Under the write gate: every one of these functions is a pure read and works for viewer and role-less sessions exactly as far as RLS lets them see; none writes, and the suite proves it (no row in any core table changes; the functions are not SECURITY DEFINER).
- [ ] Visibility: a caller never receives a node, edge, label, or path segment it could not read directly, under both database owner types; a path through an invisible node is pruned, not reported; candidates and superseded rows are treated as the description says.
- [ ] AGENTS.md, docs/agent-ops-guide.md, docs/conventions-catalog.md, docs/core-contract.md, docs/data-dictionary.md carry pull request 19's additions merged with today's text, not overwriting it.
- [ ] ./scripts/test-all.sh passes.

## Constraints
- Migration 0032, conformance 38, security 03 (tests/security/02 is taken). Port; do not redesign.
- No applied migration is edited: 0001 to 0030 and 0100 to 0124 are applied on main. Every function declares search_path. Authorization is session variables only: no current_user, session_user, or pg_has_role().
- Write gate (work/009): viewer and role-less sessions write nothing; new supporting-table rules call rye_may_write_table(). Review policy holds on every route (work/010). Tests run under a non-superuser role AND under scripts/test-nonsuperuser-owner.sh, fail without the new migration, and refuse to pass vacuously.
- No GitHub Actions and no .github/ files. The gate is ./scripts/test-all.sh run locally with your own COMPOSE_PROJECT_NAME and RYE_POSTGRES_PORT. Run ./scripts/bootstrap-worktree.sh first in a worktree, never in the main checkout. No /tmp scratch. No push; the Lead opens the pull request.
- No customer names. Invented names only.

## Decided by the human
- 2026-09-20, Casey: take all outstanding issues and merge them to main through issues and pull requests.
- Issue 17, decided in review: agents perform graph inserts; the database gates outcomes, not steps.

## Assumed by default
- New pull request supersedes 18 and 19; the old ones are closed with a pointer. Overturn: Casey.
- The "bounded vocabulary visibility" candidate in issue 17's comment is not built here; it stays on issue 17. Overturn: Casey.

## Verified
- filled in at close

## Reports

## Close
status line and date
