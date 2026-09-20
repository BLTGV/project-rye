# 014 identity-resolution

- status: open
- opened: 2026-09-20
- areas: schema
- contracts: contracts/sql-surface.md
- base revision: 6aabedd on main
- supersedes: pull request 20 (branch retrieval/identity-resolution). Part of issue 17.

## Goal
An intake agent can ask "does this thing already exist?" and get a verdict with the candidates behind it, and a stale reference to a merged-away node resolves to the node it became. Pull request 20 adds `resolve_node_identity()` (advisory: match, ambiguous, new; fuzzy label matching never produces match; writes nothing; no write helper calls it) and a merge-chain lookup over `node_merges`. It predates main's migrations 0020 to 0030; in particular `node_merges` now has forced RLS and is insert-only (0029), and the settlement lookup took the name space pull request 20's numbers assumed.

## Acceptance criteria
- [ ] The functions land as migration 0033 with conformance 39 and security 04, behaving as pull request 20 describes, including the conformance check that no write helper calls the resolver.
- [ ] The merge-chain lookup works under 0029's RLS on `node_merges` for every role that can see the nodes involved, under both owner types, and follows chains of merges to the live node; what a caller sees when it cannot read a node in the chain is what pull request 18's visibility contract says, and is tested.
- [ ] The split-brain case the visibility contract worries about (a caller that cannot see an existing node is told "new") is handled exactly as that contract decides, with a test pinning what leaks and what does not. If the contract's answer is a narrow SECURITY DEFINER probe, it follows design/model/deployment.md's hardening rules and returns ids only.
- [ ] Pure reads: they work for viewer and role-less sessions as far as RLS allows and write nothing.
- [ ] Docs from pull request 20 merged with today's text. ./scripts/test-all.sh passes.

## Constraints
- Migration 0033, conformance 39, security 04. Port; do not redesign. If work/012 changes node_source_map's key and the resolver reads mappings, read by (source_schema, source_table, source_id), which is valid before and after 012.
- No applied migration is edited: 0001 to 0030 and 0100 to 0124 are applied on main. Every function declares search_path. Authorization is session variables only: no current_user, session_user, or pg_has_role().
- Write gate (work/009): viewer and role-less sessions write nothing; new supporting-table rules call rye_may_write_table(). Review policy holds on every route (work/010). Tests run under a non-superuser role AND under scripts/test-nonsuperuser-owner.sh, fail without the new migration, and refuse to pass vacuously.
- No GitHub Actions and no .github/ files. The gate is ./scripts/test-all.sh run locally with your own COMPOSE_PROJECT_NAME and RYE_POSTGRES_PORT. Run ./scripts/bootstrap-worktree.sh first in a worktree, never in the main checkout. No /tmp scratch. No push; the Lead opens the pull request.
- No customer names. Invented names only.

## Decided by the human
- 2026-09-20, Casey: take all outstanding issues and merge them to main through issues and pull requests.

## Assumed by default
- New pull request supersedes 20. Overturn: Casey.

## Verified
- filled in at close

## Reports

## Close
status line and date
