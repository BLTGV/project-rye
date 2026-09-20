# 018 session-leftovers

- status: open
- opened: 2026-09-20
- areas: schema, agent-kit, admin, operator
- contracts: contracts/sql-surface.md, contracts/admin-api.md, contracts/category-vocabulary.md
- base revision: 6aabedd on main

## Goal
Nothing from work items 001 to 011 is left as a note. Each item below was recorded as "known, left open" or as a follow-up at a close.

## Acceptance criteria
- [ ] schema: an alias recorded BEFORE its type became gated no longer routes a write past the settle gate (work/011). Either gating a type refuses while such an alias stands, or the gate judges the written name as well as the canonical one; Architect chooses.
- [ ] schema: a DEFAULT_SCOPE, or any selected scope, whose review_policy holds an unsupported value no longer refuses every write with a raise (work/010 INFO). Fail restrictive instead (treat as strict) and make recording an unsupported review_policy value impossible; say what happens to an instance that already has one.
- [ ] schema: the grant-expiry gap on the domains properties gate and a helper for "holds an instance-wide grant" (work/003 follow-ups), if the Architect confirms each is a defect on today's tree; otherwise say why not.
- [ ] admin: stats.total and stats.filtered are defined in contracts/admin-api.md and the page-size-dependent total check is robust (work/003).
- [ ] agent-kit: tabular_commit_rye.mts reports a waiting count like the source-context commit does (work/011); the agent-role path for a repeat describe_category and the behavior of --scope with an unknown key are stated in the contract and tested (work/001).
- [ ] operator: agents/operator.md no longer tells the Operator to keep hosted CI green; it says the gate is ./scripts/test-all.sh run locally and that the repository has no .github/workflows. scripts/gen-agents is rerun and the rendered role files match.
- [ ] operator: `npm ci` in admin/ works in a fresh worktree on this machine (sharp builds from source today), or the runbook states exactly why it cannot and bootstrap-worktree.sh remains the way.
- [ ] Roadmap-sized follow-ups are NOT built here; each is filed as a GitHub issue by the Lead: a login in front of the reviewer's screen; plugin manifests contributing self-settled types; a replay runner; the agent creating the first area with the person as owner; the v0.4 items (write echo, the questions a person owes, objections, calling the settlement lookup from the acceptance path).
- [ ] ./scripts/test-all.sh passes.

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
- filled in at close

## Reports

## Close
status line and date
