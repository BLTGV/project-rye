# 006 calibration-nonsuperuser-owner

- status: verified, not pushed
- opened: 2026-09-19
- areas: schema
- contracts: contracts/sql-surface.md (read; changed only if the cause turns out to be a visibility rule, in which case the Architect goes first)
- base revision: 86719c9 on claude/funny-tu-65d029 (work/004 plus agent-roles at af232e9, which carries work/005 and migration 0023)

## Goal
Rye's record of how well predictions turned out gives the same answer on
every supported deployment. Today the calibration check in the conformance
suite fails when the database owner is an ordinary role rather than a
superuser, which is how Supabase runs. The Docker test database hides this
because its owner is a superuser. After this item the whole conformance
suite passes under an ordinary owner, and the project has a standing way to
notice this kind of bug.

## Finding (verified 2026-09-19 during work/004, by the Verifier and by builder-schema independently)
`tests/conformance/27_outcomes_predictions_patterns.sql` fails at about line
397 with `ERROR: calibration report brier/hit-rate fixture failed` when Rye
is installed into a database owned by a NOSUPERUSER NOBYPASSRLS role and the
suite runs as that role. It fails with and without migration 0022, and the
Verifier saw it fail with governance RLS toggled off, so work/004 did not
cause it. It passes under `./scripts/docker-test.sh` because the Docker owner
`rye` is a superuser and bypasses RLS, including inside SECURITY DEFINER
functions.

Not yet verified: the cause. The likely one is a function or view from
`schema/migrations/0019_knowledge_outcomes_predictions_patterns.sql` that
relies on definer visibility, which FORCE ROW LEVEL SECURITY removes for a
non-superuser owner. It could also be the test's own session setup. The
finding was made before agent-roles (work/005, migration 0023) was merged
into this branch; the builder re-establishes it on the base revision first.

How to reproduce: `RYE_POSTGRES_PORT=<free port> ./scripts/docker-test.sh up`;
as superuser create a database, the extensions pgcrypto, btree_gin, pg_trgm,
and a NOSUPERUSER NOBYPASSRLS login role that owns the database; run
`./scripts/install.sh --profiles crm,pm` with DATABASE_URL as that role (works
unmodified); then `./scripts/conformance.sh` with the same DATABASE_URL.
`scripts/conformance.sh` line 36 skips SET ROLE for a non-superuser, so the
whole suite runs in that configuration. `docs/areas/schema.md`, entries dated
2026-09-19, describe the two mechanisms the schema uses instead of definer
visibility.

## Acceptance criteria
- [x] The cause is stated in one paragraph a stranger can check: which object returns what, under which session, and why a superuser owner hides it.
- [x] On an install owned by a NOSUPERUSER NOBYPASSRLS role, `./scripts/conformance.sh` run as that role passes with every test file present, including 27. No test is held aside.
- [x] `./scripts/docker-test.sh test --reset --profiles crm,pm` gives the same result it gives on the base revision apart from this fix: the conformance suite passes. (Written expecting host test `21_api_security.sh` to fail as it did before agent-roles was merged; on the base revision it passes, so nothing is excepted.)
- [x] A test exists that fails on a non-superuser owner before the fix and passes after it. The builder shows both runs.
- [x] The calibration figures a session sees are computed only from predictions and outcomes that session may see. The fix does not make any row visible to a session that could not see it before, unless the Architect has written that rule into the contract first.
- [x] If the same cause affects other objects from 0017 to 0021 (salience, source reliability, pattern support, review queue, stale digests, weighted assertions), each is listed with its disposition: fixed here, not affected and why, or left open.
- [x] Migrations 0022 and 0023, which met for the first time on the base revision, install together and the suite passes with both.

## Constraints
- A new numbered migration, 0024. No applied migration is edited; 0019 is not touched. Functions and views are replaced from the new file with unchanged signatures and column lists.
- If the defect is in the test and not in the schema, fix the test, say so, and add no migration.
- Authorization is session variables only. No `current_user`, no `pg_has_role()`. No second model.
- SECURITY DEFINER is not a visibility fix: under FORCE RLS with a non-superuser owner, policies still evaluate the caller's session variables. Use the two existing mechanisms: rows readable to the calling session, and a transaction-local `app.write_path` gate set around the statement.
- Views stay `security_invoker`. Test 27 asserts it.
- Every function declares its own `SET search_path`. SQL and bash only.
- A superuser run proves nothing here. Evidence comes from a non-superuser owner.
- Do not push.

## Decided by the human
- 2026-09-19, Casey: find the cause and fix it in a new numbered migration, never an applied one, with a test that fails on a non-superuser owner before the fix; then Verifier.
- 2026-09-19, Casey: consider an Operator item so CI runs the suite once under a non-superuser owner.

## Assumed by default
- The item number is 006 and the migration is 0024, because another session closed work/005 with migration 0023 on agent-roles while work/004 was in progress. Overturn: Lead.
- Work happens on claude/funny-tu-65d029, which now contains agent-roles. Overturn: Casey.
- The fix preserves who can see what. If the only correct fix widens visibility, the builder stops and the Architect decides. Overturn: Architect.
- The Operator item is opened separately, as 007, after this one verifies, so its new CI run starts green. It is scoped to running the existing suite once under a non-superuser owner; no local credential can create or update files under `.github/workflows`, so the Operator delivers the script and the workflow change as a patch for Casey to apply if that is where CI lives. Overturn: Casey.
- `21_api_security.sh` stays with work/003. Overturn: Lead.

## Found during the item
- 2026-09-19, builder-schema: the cause of the test 27 failure is `score_due_predictions()` (0019, about line 529). It takes `SELECT ... FOR UPDATE` on due predictions before opening the `assertion_outcome` write-path gate. `FOR UPDATE` applies the UPDATE policy's USING clause as a filter, not an error, so under a non-superuser owner the cursor matches nothing, the function scores 0 predictions, and calibration reporting is silently empty. A superuser owner bypasses the policy and hides it. It is the only `FOR UPDATE` in the schema with this ordering. Fix: migration 0024 opens the gate first, then locks.
- 2026-09-19, Lead: on the base revision, migration 0022 (work/004) and test 30 (work/005) collide. Test 30 compares every role's `rye_settlers()` answer with an admin baseline; under the work/004 contract a session that cannot see the area (`agent:t`, which names no identity, and the unset role) correctly gets `domain_not_found`. Reproduced in Docker at `30_configuration_gate.sql:995`. Answered from the contract: the policy stands, the test's comparison changes to same-role before and after, with a bound agent that holds the area added so the agent case stays meaningful. No visibility is widened, so the Architect is not needed. In scope here under the criterion that 0022 and 0023 install together and the suite passes.

## Verified
All on 2026-09-19. Evidence is from databases owned by a NOSUPERUSER NOBYPASSRLS role unless marked Docker, whose owner is a superuser.
- builder-schema: reproduced on the base revision before changing anything. Before the fix `score_due_predictions()` returned 0, a `FOR UPDATE` count was 0 against a plain count of 1, and test 27 failed; the sharpened test 27 failed with `score_due_predictions scored 0 of 3 due predictions`; after 0024 it passes. Fresh install, full `conformance.sh`, every file present: exit 0. Docker: "Conformance suite passed", "Docker test flow passed". Reworked test 30 shown to fail when an erase is made to succeed, for the admin arm and the bound-agent arm.
- Lead, integration on 46871ad: fresh install, `conformance.sh` run from the host as the owner so 21, 22, and 23 execute: exit 0, 41 test files, none held aside. After the last test 30 change (bbae3d3): test 30 passes on that install.
- Verifier: PASS, first attempt. Cause confirmed with observed values (plain SELECT 2 rows; `FOR UPDATE` with no gate 0 rows; with the gate 2 rows; 0019 body scores 0 and `calibration_report` is empty; 0024 body scores 2 with bucket 0.70, count 2, brier 0.29, hit rate 0.50; a second call scores 0). Mutation: 0019 body restored makes test 27 fail at the new assertion, line 406. Signature, return type, volatility, SECURITY DEFINER, and `SET search_path` identical to 0019. Both session variables are empty after a normal return and after a forced lock-timeout error inside the gated statement. Visibility unchanged: for admin, admin with a team, viewer, team_member, agent, and unset sessions, predictions scored equals predictions visible, and `calibration_report` per role is identical before and after. Two concurrent calls: one scores 2, the other blocks then scores 0; one `prediction_scored` event per prediction. Test 30: no refusal-message or accepted-configuration assertion removed or loosened; one arm was looser for viewer and team_member, since tightened by the builder. Data dictionary text accurate.
- Dispositions for the sweep: `score_due_predictions()` fixed here. All 15 views in `rye` are security invoker reads and are not affected. No row locks in 0020 to 0023 or the profile migrations; no `UPDATE ... RETURNING` anywhere. `merge_nodes` (0005) has the same lock-before-gate ordering for agent sessions: left open, see below. The builder's claim that every other `FOR UPDATE` opens its gate first was therefore wrong in one case; the Verifier found it.
- Not verified: any deployed instance. Nothing was applied to a real database. The test 30 mutation was run for the self-type arm only.

## Open, not part of this item
- `merge_nodes` under an `agent:` role on a non-superuser owner raises a misleading `Duplicate node <uuid> not found`. Needs a decision on whether agents may merge nodes at all. Queued as a separate task for Casey to start.
- CI still runs only the superuser-owner configuration until work/007 lands.

## Reports
Condensed; commits in order.
- builder-schema, 4e232ea: cause found; migration 0024; test 27 sharpened (it had passed three unlabeled predictions because `<>` on NULL is not true); data dictionary. Stopped at test 30 rather than widen visibility, and asked.
- Lead: answered from the contract; the policy stands and test 30's comparison changes.
- builder-schema, defed6d: test 30 takes one baseline per role, adds a bound agent that holds the area, pins `domain_not_found` for the blind roles, keeps an admin before-and-after check. Host tests 21, 22, 23 pass on a non-superuser owner.
- Verifier: PASS, one minor finding on test 30 and one pre-existing finding on `merge_nodes`.
- builder-schema, bbae3d3: the self-type arm pins the expected settler for every role that can see the area. Learned that with the self type erased the answer degrades to the area owner, not to none.

## Close
2026-09-19: verified on branch claude/funny-tu-65d029, not pushed, not applied to any instance. Passed verification on the first attempt. Area record curated in ebcc368.
