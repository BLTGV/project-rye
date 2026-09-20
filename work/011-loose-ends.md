# 011 loose-ends

- status: done
- opened: 2026-09-20
- areas: schema, admin, operator; Product and Architect for one line each
- contracts: contracts/sql-surface.md (one sentence), contracts/rye-cli.md
- base revision: 642a889 on agent-roles

## Goal
Close the small follow-ups left by work/004, 005, and 008 so none is carried
past the merge.

## Acceptance criteria
- [x] schema: `scripts/rye settle-gate <assertion_type>` exists, matches the other pre-write lookups in form and output, is in contracts/rye-cli.md and rye-skill.json, and has a test beside the other CLI tests.
- [x] schema: a type alias pointing FROM a gated configuration type (registry_entry, review_policy) cannot be recorded, by anyone, so a write under the gated name can never canonicalise away from the settle gate (work/005 Verifier, LOW). Tested. The Architect adds the sentence to the contract.
- [x] schema: test 31 gains a working fixture for the inferred-displacement search under a hidden rival, so the contract's sixth stated limit is measured instead of "untested"; the contract sentence is updated to what is measured (evidence needs a visible event_id or source_assertion_id).
- [x] operator: one documented command prepares a fresh worktree for `./scripts/test-all.sh` (admin/ and site/ node_modules, and the intake skill's), without `npm ci` building sharp from source when a usable copy exists; referenced from docs/runbooks and docs/areas.
- [x] admin: a check that fails when `sql.unsafe`, `set_config`, or a raw query bypasses `ryeQuery()` outside admin/src/server/db.ts, wired into the admin check the suite already runs.
- [x] product: docs/glossary.md has the plain term for Rye's own configuration ("how Rye is set up here"), and the agent-ops skill uses it.
- [x] `./scripts/test-all.sh` passes.

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
- Migration numbers used: 0028, 0029, 0030, 0124. Overturn: Lead.
- Mention-linking in add_comment() starts working (it never did). No in-repo caller exists, so no output changed. Overturn: Casey.
- node_merges has no update or delete for anyone, admin included: a wrong merge is answered by a new merge and its event. Overturn: Casey.

## Verified
- Verifier, three passes; all seven criteria PASS by execution under both owner types: settle-gate CLI (form, exit codes, JSON equals settle_gate(), test fails when the subcommand is removed); alias FROM a gated type refused for every role and route, two-hop chains and spelling variants harmless, 0028's guard differs from 0023's only by the new rule; test 31 obligation 20 measures the inferred-displacement case per owner type and the contract says what was measured; bootstrap-worktree.sh safe in the main checkout, hard-link and --copy, --dry-run, failed npm ci restores, 60 runs with no non-zero exit, referenced from the runbook and three area records; check:db catches the patterns and the honest evasions; glossary term consistent with no dangling references; test-all.sh green. Also verified: 0029 (counters only step by one through the generator's shape, first row only as the generator writes it, no delete; node_merges insert-only; system:cdc kept out), codes widen past 9999 (TSK-<yymm>-10000 then 10001), 0030 markers with every attrs reader and 0025's guard unaffected, crm-only install verifies.
- Agent-kit Verifier, two passes, second PASS: every behavioral claim in the changed skills and guides is true by execution; both intake commits are rerun-safe under review (rejected candidates refile, accepted-between-runs is a no-op); the tabular step requires a person's role.
- Checked by the Lead by diff, not by a further verifier pass: the add_comment() regex fix (e7cf9ec; one line plus suite 36, negative control shown by the builder), the settle-gate header rename (a3785c5), the agent-kit last round (28a8fbc). All ran in the final combined suite on b7da6fd, exit 0.
- Known, low, left: an alias recorded BEFORE its type became gated still routes past the gate (needs two admin actions); the allowed hand insert of a first counter row skips code 0001; review_gate.pending stays true after acceptance (status is the truth); deliberate obfuscation defeats check:db's text scan; tabular_commit reports skipped writes but no waiting count.


## Reports
### Builder admin, 2026-09-20 (commit 4b28c57, merged ed7b9d0 lineage)
admin/scripts/db-usage-check.ts and `check:db`, run beside check:routes from
tests/conformance/21_api_security.sh. Gates `.unsafe(`, `set_config(`,
`withAdminCte`, a runtime import of postgres, and a tagged-template sql call,
outside db.ts. Passes on the tree; each probe failed with file and line.

### Operator, 2026-09-20 (commit fd95e17)
scripts/bootstrap-worktree.sh: hard-links or copies node_modules for admin/,
site/, and the intake skill from the main checkout when the lock hash
matches, else npm ci. Fresh worktree then passed test-all.sh; second run a
no-op; no containers left. Lead's note for the Verifier: hard links share
inodes with the main checkout.

### Architect, 2026-09-20 (commit 7356ce2)
Contract sentence: no alias FROM a gated configuration type. rye-cli
contract line for `settle-gate <assertion_type>`.

### Later rounds, 2026-09-20
Builder schema: 0028 alias guard, settle-gate CLI, test 31 obligation 20
(13437a7, aace681, 7b71ab0). Verifier pass one: PASS. Added from work/009's
Verifier: 0029 RLS on crm_code_counters and node_merges (9a9a156). Verifier
pass two: FAIL, a writing role could start a counter anywhere and lpad
truncated past 9999; bootstrap not referenced from area records. Builder
61f9fa9, f5529c8: first-row rule, widening, rye_may_write_table() keeps
system:cdc out, 0030 review_gate marker for record_assertion and
record_distillation, 0124 for the pm profile. Verifier pass three: all
criteria pass; FAIL on add_comment()'s regex, which had never matched
(doubled backslash in a dollar-quoted body, carried from 0110). Builder
e7cf9ec: fixed, suite 36 measures participants; Lead checked the diff and
merged without a fourth pass. Operator: bootstrap v2 exited 141 (SIGPIPE);
v3 refuses the main checkout after the Lead ran v2 there and npm ci wiped
admin/ and site/ node_modules (restored from a worktree's hard links);
v4 closes the empty-install edge. Admin: check:db closes require, dynamic
import, subpath import, aliased client (882eb88). Agent-kit 0d70c5a,
4156e97: skills, guides, rubrics, both intake commits rerun-safe, tabular
step requires a person's role. Verifier: FAIL then PASS.

## Close
done 2026-09-20. Merged to agent-roles; combined suite passed on b7da6fd and again on the final tree c0254ac under both owner types, with the manifest validation and check:db both running inside it. Grew past its first six criteria by taking in what the 009, 010, and agent-kit verifiers found: RLS on the last two unprotected tables, the code-width defect, the review_gate marker for new claims, a mention-linking regex that had never matched, two intake commits that duplicated suggestions on rerun, and ten manifests that failed their own schema.
