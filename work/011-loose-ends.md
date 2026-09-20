# 011 loose-ends

- status: open
- opened: 2026-09-20
- areas: schema, admin, operator; Product and Architect for one line each
- contracts: contracts/sql-surface.md (one sentence), contracts/rye-cli.md
- base revision: 642a889 on agent-roles

## Goal
Close the small follow-ups left by work/004, 005, and 008 so none is carried
past the merge.

## Acceptance criteria
- [ ] schema: `scripts/rye settle-gate <assertion_type>` exists, matches the other pre-write lookups in form and output, is in contracts/rye-cli.md and rye-skill.json, and has a test beside the other CLI tests.
- [ ] schema: a type alias pointing FROM a gated configuration type (registry_entry, review_policy) cannot be recorded, by anyone, so a write under the gated name can never canonicalise away from the settle gate (work/005 Verifier, LOW). Tested. The Architect adds the sentence to the contract.
- [ ] schema: test 31 gains a working fixture for the inferred-displacement search under a hidden rival, so the contract's sixth stated limit is measured instead of "untested"; the contract sentence is updated to what is measured (evidence needs a visible event_id or source_assertion_id).
- [ ] operator: one documented command prepares a fresh worktree for `./scripts/test-all.sh` (admin/ and site/ node_modules, and the intake skill's), without `npm ci` building sharp from source when a usable copy exists; referenced from docs/runbooks and docs/areas.
- [ ] admin: a check that fails when `sql.unsafe`, `set_config`, or a raw query bypasses `ryeQuery()` outside admin/src/server/db.ts, wired into the admin check the suite already runs.
- [ ] product: docs/glossary.md has the plain term for Rye's own configuration ("how Rye is set up here"), and the agent-ops skill uses it.
- [ ] `./scripts/test-all.sh` passes.

## Constraints
- Migration 0028 if the alias rule needs one. No applied migration edited.
- Session variables only; search_path on every function.
- `.github/workflows` is not touched: no local credential can push workflow files.
- Own Docker project name and port. No /tmp scratch. No push.

## Decided by the human
- 2026-09-20, Casey: fix the remaining items so the branch can be merged.

## Assumed by default
- Not included, because they are features and not defects: admin API stats fields, plugin manifests contributing self-settled types, a replay runner, agent-role describe_category (work/001 to 003 follow-ups). Overturn: Casey.
- Not fixable from here: confirming `psql` exists on the GitHub runner (needs a push and the workflow scope).

## Verified
- filled in at close

## Reports

## Close
status line and date
