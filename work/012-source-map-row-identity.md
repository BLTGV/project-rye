# 012 source-map-row-identity

- status: done
- opened: 2026-09-20
- areas: schema
- contracts: contracts/sql-surface.md (read; changed only if the Architect is asked)
- base revision: 6aabedd on main
- supersedes: pull request 6 (branch fix/node-source-map-row-identity, written against a main that predates migrations 0020 to 0030)

## Goal
Merging a duplicate node into a canonical one keeps every source row pointing at the graph. Today `node_source_map` allows one mapping per source table per node, so when both nodes map rows of the same table, the common dedup case, `merge_nodes()` deletes the duplicate's mapping. The next `link_record()` for that source row finds nothing and inserts a fresh, empty node: the merged duplicate comes back without its edges, assertions, or history. Pull request 6 fixes this by keying the map on the source row. It cannot land as written: its migration number (0020) and test number (28) are taken, and it re-derives `merge_nodes()` and `link_record()` from definitions that migration 0026 has since replaced.

## Acceptance criteria
- [x] `node_source_map` is keyed by source row (source_schema, source_table, source_id), so one node can hold several rows of one table, and the backfill is safe on an instance with existing mappings, including colliding ones; what happens to each collision is stated and tested.
- [x] After `merge_nodes(duplicate, canonical)` where both map rows of the same table, every mapping points at the canonical node, none is deleted, and `link_record()` for the duplicate's source row returns the canonical node and creates nothing.
- [x] Everything migration 0026 added still holds, verified by execution: `merge_nodes()` refuses agents, viewer, unset, and system:cdc before any lock, and a non-admin on a governed node; the write gate and policies on `node_source_map` keep every conjunct; suite 32 passes unmodified. `merge_nodes()` and `link_record()` are carried forward from their LIVE definitions (0026 and whichever migration last defined link_record), changing only the source-map handling; the report gives the diff size of each.
- [x] Change capture still resolves the node for a tracked row after the key change (tests/conformance/07 passes; a merged row's later domain write records an event on the canonical node).
- [x] link_records_batch, the tabular intake scripts, and scripts/rye subcommands that read or write mappings still work.
- [x] A conformance suite (37) covers the above; ./scripts/test-all.sh passes.

## Constraints
- Migration 0031, conformance 37. Port pull request 6's work; do not rewrite what still applies.
- No applied migration is edited: 0001 to 0030 and 0100 to 0124 are applied on main. Every function declares search_path. Authorization is session variables only: no current_user, session_user, or pg_has_role().
- Write gate (work/009): viewer and role-less sessions write nothing; new supporting-table rules call rye_may_write_table(). Review policy holds on every route (work/010). Tests run under a non-superuser role AND under scripts/test-nonsuperuser-owner.sh, fail without the new migration, and refuse to pass vacuously.
- No GitHub Actions and no .github/ files. The gate is ./scripts/test-all.sh run locally with your own COMPOSE_PROJECT_NAME and RYE_POSTGRES_PORT. Run ./scripts/bootstrap-worktree.sh first in a worktree, never in the main checkout. No /tmp scratch. No push; the Lead opens the pull request.
- No customer names. Invented names only.

## Decided by the human
- 2026-09-20, Casey: take all outstanding issues from this session and the others and merge them to main, through issues and pull requests, without GitHub Actions.

## Assumed by default
- The old branch is not force-pushed; a new pull request supersedes 6 and 6 is closed with a pointer. Overturn: Casey.

## Verified
- Verifier, by execution under both database owner types on 4072495: PASS. Upgrade from main's state (0001 to 0030 plus profiles): 10 mappings before, none lost, none re-pointed wrongly, 2 restored onto the terminal canonical of an A to B to C chain; all five backfill outcomes exercised (restored, already_mapped, occupied, ambiguous, unresolved); with the old unique index dropped and genuine duplicates present, 0031 aborts and deletes nothing. After merge_nodes() every mapping points at the canonical node; link_record() and link_records_batch() return the canonical and create nothing; a later domain write on a tracked row records its event on the canonical under system:cdc. merge_nodes() differs from 0026's body only by the removed colliding-mapping DELETE, link_record() only by the ON CONFLICT target and set list; every 0026 refusal, the three nsm policies, and the write-gate trigger survive the key swap; suites 32, 35, 07 unchanged and passing. Suite 37 fails without 0031, where the original defect reproduces.
- Where RLS hides a mapping and its node, link_record() is refused by the update policy instead of the old unique violation: equally restrictive, nothing written, hidden id not disclosed.
- Lead, by diff and the builder's run, not a further verifier pass: the post-pass round 4ae58f8 (full-DDL doc block corrected; the migration clears the admin role it set; rye_restore_merged_source_maps() treats node_merges as untrusted: archived duplicates only, earliest row, cycles reported unresolved; new suite 37 case with forged rows).
- Lead, integration: ./scripts/test-all.sh on this branch tip, result recorded in the pull request.


## Reports
### Builder schema, 2026-09-20 (commits 4072495, 4ae58f8)
0031: primary key promoted from idx_nsm_source_unique, which 0005 has enforced
since, so the swap cannot collide. Backfill as a named admin-only function,
rye_restore_merged_source_maps(), so each collision class is testable.
capture_domain_change() already looked rows up by the new key.

### Verifier, 2026-09-20: PASS
One MEDIUM (design/model/schema.md full DDL block stale), fixed in 4ae58f8.

## Close
done 2026-09-20. Supersedes pull request 6.
