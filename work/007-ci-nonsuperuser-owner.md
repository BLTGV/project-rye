# 007 ci-nonsuperuser-owner

- status: open
- opened: 2026-09-19
- areas: operator (CI and the all-tests command). No product area.
- contracts: none
- base revision: ebcc368 on claude/funny-tu-65d029 (work/004 and work/006 verified; agent-roles at af232e9 merged)

## Goal
Every pull request is tested the way Supabase runs Rye: with a database owner
that is an ordinary role, so row-level security applies to the owner and to
every function it owns. Today CI tests only with a superuser owner, which
skips those rules. Five bugs found on 2026-09-19 (four in work/004's first
verification, one in work/006) were invisible to CI for that reason. After
this item such a bug fails the pull request.

## Acceptance criteria
- [ ] One command, runnable locally and with no arguments needed, brings up the disposable test database, creates a database owned by a role that is neither superuser nor allowed to bypass row-level security, installs Rye into it as that role with the crm and pm profiles, runs the whole conformance suite as that role, and cleans up. It exits non-zero if any part fails and says which.
- [ ] `./scripts/test-all.sh` runs that command as a named step in addition to the existing superuser-owner step, and names it in the failure summary like the other steps. CI therefore runs it on every pull request with no change to `.github/workflows/test.yml`.
- [ ] The run proves it is not vacuous: it fails, before running any test, if the role it is about to test as is a superuser or may bypass row-level security.
- [ ] Shown to catch a real bug: with `score_due_predictions()` put back to its 0019 body in a throwaway copy (not in the repository), the new step fails at test 27 while the existing superuser-owner step still passes. Both outcomes are in the report.
- [ ] On the base revision the new step passes, and so does the whole of `./scripts/test-all.sh`.
- [ ] The host-run tests (`21_api_security.sh`, `22_secure_mcp_simulation.sh`, `23_cli_agent_security.sh`) execute in the new step where node is available, as they do in the existing step, and are not silently skipped in CI.
- [ ] `docs/runbooks/` says in a few lines what the step is, why it exists, how to run it alone, and how to reproduce a failure by hand.
- [ ] The added CI time is measured and reported.

## Constraints
- Operator paths only: `scripts/test-all.sh`, a new script the Operator owns, `infra/`, `docs/runbooks/`. No product code, no tests, no migrations. `scripts/docker-test.sh`, `scripts/conformance.sh`, and `scripts/install.sh` belong to the schema area: call them, do not edit them. If one of them must change for this to work, stop and report what and why.
- Never edit product code or a test to make CI pass. Report the failure instead.
- Bash only. No new dependency. Must run on `ubuntu-latest` as the workflow is today, and on this Arch machine.
- The port is configurable the way `docker-test.sh`'s is (`RYE_POSTGRES_PORT`), and the step does not collide with the existing step's container when run in sequence.
- The role's password is a fixed throwaway value for a disposable local container; no secret goes in the repository or the workflow.
- `/tmp` is RAM on the development machine; keep scratch output small.
- Do not push.

## Decided by the human
- 2026-09-19, Casey: consider an Operator item so CI runs the suite once under a non-superuser owner.

## Assumed by default
- "Consider" is taken as "do it", because the change is confined to the all-tests command, costs a few CI minutes, and would have caught five bugs in one day. Overturn: Casey.
- The new run is added beside the superuser-owner run, not in place of it. The superuser run still covers the `SET ROLE rye_conformance` path that real self-hosted installs use. Overturn: Casey.
- No change to `.github/workflows/test.yml`, so the known lack of a local credential that can push workflow files does not matter. Overturn: Operator, if the workflow turns out to need one.
- Extensions are created by the superuser before handing the database to the ordinary owner, mirroring Supabase, where they are pre-installed. Overturn: Operator.

## Known from work/004 and work/006
- `scripts/install.sh --profiles crm,pm` runs unmodified as a NOSUPERUSER NOBYPASSRLS owner once pgcrypto, btree_gin, and pg_trgm exist in the database.
- `scripts/conformance.sh` line 36 skips `SET ROLE` when the connecting user is not a superuser, so pointing `DATABASE_URL` at that owner runs the whole suite in the Supabase configuration.
- Run inside the postgres container, the three host tests self-skip because node is absent; run from the host against the mapped port, they execute. They need `admin/node_modules` and `skills/rye-source-context-intake/node_modules`. CI installs the first with `npm ci`; check whether it installs the second.
- The Lead ran exactly this by hand on 46871ad: 41 test files, "Conformance suite passed".

## Verified
- filled in at close

## Reports

## Close
