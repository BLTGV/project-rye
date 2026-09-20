# 014 identity-resolution

- status: done
- opened: 2026-09-20
- areas: schema
- contracts: contracts/sql-surface.md
- base revision: 6aabedd on main
- supersedes: pull request 20 (branch retrieval/identity-resolution). Part of issue 17.

## Goal
An intake agent can ask "does this thing already exist?" and get a verdict with the candidates behind it, and a stale reference to a merged-away node resolves to the node it became. Pull request 20 adds `resolve_node_identity()` (advisory: match, ambiguous, new; fuzzy label matching never produces match; writes nothing; no write helper calls it) and a merge-chain lookup over `node_merges`. It predates main's migrations 0020 to 0030; in particular `node_merges` now has forced RLS and is insert-only (0029), and the settlement lookup took the name space pull request 20's numbers assumed.

## Acceptance criteria
- [x] The functions land as migration 0033 with conformance 39 and security 04, behaving as pull request 20 describes, including the conformance check that no write helper calls the resolver.
- [x] The merge-chain lookup works under 0029's RLS on `node_merges` for every role that can see the nodes involved, under both owner types, and follows chains of merges to the live node; what a caller sees when it cannot read a node in the chain is what pull request 18's visibility contract says, and is tested.
- [x] The split-brain case the visibility contract worries about (a caller that cannot see an existing node is told "new") is handled exactly as that contract decides, with a test pinning what leaks and what does not. If the contract's answer is a narrow SECURITY DEFINER probe, it follows design/model/deployment.md's hardening rules and returns ids only.
- [x] Pure reads: they work for viewer and role-less sessions as far as RLS allows and write nothing.
- [x] Docs from pull request 20 merged with today's text. ./scripts/test-all.sh passes.

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
- Verifier, three passes by execution under both database owner types; third pass PASS on 8085f73. The four functions from pull request 20 differ from its file only in comments. Verdicts as described; fuzzy label matching never produces `match`, including on exact equality with a former name. The merge-chain lookup works under 0029's RLS on node_merges for every role that can see the nodes (a 60-link chain), terminates on cycles, and follows a row only when its duplicate is archived, earliest row first. A caller learns nothing about a node it cannot read: hidden and absent are indistinguishable for team_member, viewer, agent, and role-less sessions, and former_label_count never counts unreadable nodes. The split-brain `new` case is stated exactly as the visibility contract decides (D3 unimplemented) and no more. Pure reads: 14 tables by 5 roles unchanged; not definer; own search_path. Suites 39 and security 04 fail without 0033 and refuse a superuser.
- First pass FAIL: node_merges accepted forged rows from any writing role with a caller-chosen merged_at, and the new lookup followed them, so an agent got the redirect merge_nodes() refuses it; merge_nodes(A,B) then merge_nodes(B,A) built a cycle; a label only a merged-away node carried returned `new`. Second pass FAIL: the raw route let a team_member merge a node a scope governs, which merge_nodes() refuses; and the new guard broke main's suite 37. Fixed: a BEFORE INSERT guard on node_merges makes every refusal merge_nodes() makes, from the same predicates in the same order, plus its own four rules (merged_at is now(), one record per duplicate, no cycle, canonical unarchived); a deferred check requires the duplicate archived and a node_merge event at commit. What remains reachable by raw SQL is only what merge_nodes() would have done for the same caller. Suite 37 plants its forged rows as the table owner; its assertions are unchanged.
- Tested and dismissed: a team_member archiving a governed subject loosens nothing. governing_scope() still returns the scope, link_record() returns the same governed node, and writes still land as suggestions.
- Known: SET CONSTRAINTS ALL IMMEDIATE before merge_nodes() makes it fail, because it inserts the merge record before archiving; documented in the data dictionary.
- Lead, integration: the builder merged main (3dbcf7e; four keep-both conflicts, verify.sh checked by dropping one object of each item); ./scripts/test-all.sh on this branch tip, result in the pull request.


## Reports

## Close
done 2026-09-20. Supersedes pull request 20. Part of issue 17.
