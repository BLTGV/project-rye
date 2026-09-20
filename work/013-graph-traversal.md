# 013 graph-traversal

- status: done
- opened: 2026-09-20
- areas: schema, agent-kit (skill text only if the functions change what an agent is told)
- contracts: contracts/sql-surface.md
- base revision: 6aabedd on main
- supersedes: pull requests 18 (design/proposals/rls-visibility-contract.md, docs/roadmap.md) and 19 (branch retrieval/graph-traversal). Part of issue 17.

## Goal
An agent can find a starting node from text and walk more than one hop, without learning anything it may not read. Pull request 19 adds `find_nodes()`, `find_nodes_batch()`, `find_paths()`, and a neighborhood read, all SECURITY INVOKER, pruning silently under RLS as pull request 18's visibility contract decides. Both predate migrations 0020 to 0030 on main and claim numbers that are taken.

## Acceptance criteria
- [x] Pull request 18's design document and roadmap change land as written, corrected only where main has since made a sentence false.
- [x] The traversal and entry-point functions from pull request 19 land as migration 0032 with their conformance (38) and security (03) suites, behaving as its description says: ranked entry point with match_reason; no search over property values, so a redacted field cannot be confirmed by matching; bounded typed paths; nothing auto-logs.
- [x] Under the write gate: every one of these functions is a pure read and works for viewer and role-less sessions exactly as far as RLS lets them see; none writes, and the suite proves it (no row in any core table changes; the functions are not SECURITY DEFINER).
- [x] Visibility: a caller never receives a node, edge, label, or path segment it could not read directly, under both database owner types; a path through an invisible node is pruned, not reported; candidates and superseded rows are treated as the description says.
- [x] AGENTS.md, docs/agent-ops-guide.md, docs/conventions-catalog.md, docs/core-contract.md, docs/data-dictionary.md carry pull request 19's additions merged with today's text, not overwriting it.
- [x] ./scripts/test-all.sh passes.

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
- Verifier, by execution under both database owner types on 087d0f8: PASS. Faithful port: no change inside any of the five function bodies; only explicit STABLE SECURITY INVOKER, the seeding block (sets the admin role itself; NOTICEs if a strict DEFAULT_SCOPE demotes the seeded defaults, and the functions then fall back safely: depth still capped at 3, threshold 0.35, unknown edge types associative), and numbering. Ranking tiers, batch, bounded paths, cycle guard, as_of and direction confirmed. Visibility for admin, team_member, agent:t, viewer, and role-less under both owners: nothing pruned is reported and no completeness signal distinguishes pruned from absent; find_nodes does not search property values, so a redacted field cannot be confirmed by matching, including through trigram near-misses and node_source_map. Pure reads: prosecdef false, not volatile, own search_path, the call graph writes nothing, row counts of 14 tables unchanged for five roles. Docs: zero deleted lines across seven files; every SQL example executes. Suites 38 and security 03 fail without 0032 and refuse a superuser.
- Measured, stated: max_paths bounds output, not work; a 2,000-edge hub at 3 hops takes 0.9 to 1.8 seconds; max_path_depth is the real cost bound. A value redacted in properties is still matchable if it also appears in the node's label.
- Lead, by diff and the builder's before-and-after runs, not a further verifier pass: b26e79d fixes two defects inherited verbatim from pull request 19. LIKE metacharacters in the query are now literal (rye_like_literal(); '%' and '_' matched every label before). An unrecognized direction or edge-semantics value is refused with 22023 by two STABLE plpgsql validators instead of silently widening to `any`.
- Found, outside this item: edge_read_policy ignores an edge's own classification attrs (issue 38, routed to work/018).
- Lead, integration: ./scripts/test-all.sh on this branch tip, result in the pull request.


## Reports

## Close
done 2026-09-20. Supersedes pull requests 18 and 19. Part of issue 17.
