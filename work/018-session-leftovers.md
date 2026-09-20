# 018 session-leftovers

- status: done
- opened: 2026-09-20
- areas: schema, agent-kit, admin, operator
- contracts: contracts/sql-surface.md, contracts/admin-api.md, contracts/category-vocabulary.md
- base revision: 6aabedd on main

## Goal
Nothing from work items 001 to 011 is left as a note. Each item below was recorded as "known, left open" or as a follow-up at a close.

## Acceptance criteria
- [x] schema: an alias recorded BEFORE its type became gated no longer routes a write past the settle gate (work/011). Either gating a type refuses while such an alias stands, or the gate judges the written name as well as the canonical one; Architect chooses.
- [x] schema: a DEFAULT_SCOPE, or any selected scope, whose review_policy holds an unsupported value no longer refuses every write with a raise (work/010 INFO). Fail restrictive instead (treat as strict) and make recording an unsupported review_policy value impossible; say what happens to an instance that already has one.
- [x] schema: the grant-expiry gap on the domains properties gate and a helper for "holds an instance-wide grant" (work/003 follow-ups), if the Architect confirms each is a defect on today's tree; otherwise say why not.
- [x] admin: stats.total and stats.filtered are defined in contracts/admin-api.md and the page-size-dependent total check is robust (work/003).
- [x] agent-kit: tabular_commit_rye.mts reports a waiting count like the source-context commit does (work/011); the agent-role path for a repeat describe_category and the behavior of --scope with an unknown key are stated in the contract and tested (work/001).
- [x] operator: agents/operator.md no longer tells the Operator to keep hosted CI green; it says the gate is ./scripts/test-all.sh run locally and that the repository has no .github/workflows. scripts/gen-agents is rerun and the rendered role files match.
- [x] operator: `npm ci` in admin/ works in a fresh worktree on this machine (sharp builds from source today), or the runbook states exactly why it cannot and bootstrap-worktree.sh remains the way.
- [x] Roadmap-sized follow-ups are NOT built here; each is filed as a GitHub issue by the Lead: a login in front of the reviewer's screen; plugin manifests contributing self-settled types; a replay runner; the agent creating the first area with the person as owner; the v0.4 items (write echo, the questions a person owes, objections, calling the settlement lookup from the acceptance path).
- [x] ./scripts/test-all.sh passes.

## Constraints
- Migration 0036, conformance 42.
- No applied migration is edited: 0001 to 0030 and 0100 to 0124 are applied on main. Every function declares search_path. Authorization is session variables only: no current_user, session_user, or pg_has_role().
- Write gate (work/009): viewer and role-less sessions write nothing; new supporting-table rules call rye_may_write_table(). Review policy holds on every route (work/010). Tests run under a non-superuser role AND under scripts/test-nonsuperuser-owner.sh, fail without the new migration, and refuse to pass vacuously.
- No GitHub Actions and no .github/ files. The gate is ./scripts/test-all.sh run locally with your own COMPOSE_PROJECT_NAME and RYE_POSTGRES_PORT. Run ./scripts/bootstrap-worktree.sh first in a worktree, never in the main checkout. No /tmp scratch. No push; the Lead opens the pull request.
- No customer names. Invented names only.

## Decided by the human
- 2026-09-20, Casey: take all outstanding issues from this session and the others and merge them to main.

## Assumed by default
- Roadmap features become issues, not code, in this pass. Overturn: Casey.
- The July codex/* branches are superseded by Core Model v2 and by work/003 (issue 16 already records closing that stack) and are left alone, as is the uncommitted site work in the Codex worktree, which belongs to a session still in flight. Overturn: Casey.

## Verified
- Verifier on 0036, by execution under both database owner types: PASS. Pre-gate alias: writes under the type's name, the alias name, and padded variants all land as suggestions carrying attrs.settle_gate; record_assertion() differs from 0030's body by 11 added lines. Every unreadable review_policy shape ('lenient', '', JSON null, a number, an object, a wrong key, an empty object) is refused by record_scope_policy() and by the guard at any status for any role; a standing bad row reads strict in scope_review_policy(), its rank, and effective_review_policy(), and stays repairable; a scope with no row still reads open. describe_category()'s repeat path and scripts/rye --scope with an unknown key behave as the contract says. The two work/003 follow-ups were dismissed by the Architect as not defects and pinned as tests 42.7 and 42.8, schema side and HTTP side, all passing on today's tree.
- Closed after that pass: a suggestion demoted because its WRITTEN name is gated is stored under an ungated canonical type, so the excluded role could accept it; the guard now also reads the marker on the row. settle_gate() trims as record_assertion() does.
- Verifier on 0037: PASS. Authorship is stamped from app.current_role on every insert route and cannot be forged or changed. An agent closes only a suggestion it authored; a named writing role closes ordinary suggestions but not a configuration one; admin closes any; through reject_candidate() and through a forged raw UPDATE alike, including as a superuser owner where only the trigger binds. An edge's own classification and teams are enforced with no admin exemption, as nodes; assertions on the edge, find_paths, neighborhood, node_context, and agent_node_summary follow; no seeded row changes visibility. Both pre-0037 defects reproduce on a tree without it.
- Verifier on the assembled branch: PASS. The marker rule holds through helper and raw routes; withdraw plus re-file gets nothing accepted; accept and reject agree on who decides a marked row for every role except the author's stated withdraw; trigger order is identical under C and en_US; scripts/verify.sh is balanced and fails when one object of 0034, 0035, 0036, or 0037 is dropped; gen-agents is idempotent and the role prompts no longer speak of hosted CI.
- Lead, by the builder's before-and-after run rather than a further verifier pass: an admin always clears a marked row (a forged empty allowed_roles used to lock even admin out of accepting or rejecting it); tests 42.11 and 43.17.
- Operator: `npm ci` fails in admin/ and site/ on this machine because a system-wide libvips is visible to pkg-config and sharp then builds from source; SHARP_IGNORE_GLOBAL_LIBVIPS=1 proves it. A machine condition, stated in the runbook; bootstrap-worktree.sh remains the way.
- Roadmap-sized follow-ups filed as issues 33 to 36, not built here.
- Lead, integration: ./scripts/test-all.sh on this branch tip, result in the pull request.


## Reports

## Close
done 2026-09-20. Closes issues 32 and 38.
