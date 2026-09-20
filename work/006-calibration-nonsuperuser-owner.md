# 006 calibration-nonsuperuser-owner

- status: open
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
- [ ] The cause is stated in one paragraph a stranger can check: which object returns what, under which session, and why a superuser owner hides it.
- [ ] On an install owned by a NOSUPERUSER NOBYPASSRLS role, `./scripts/conformance.sh` run as that role passes with every test file present, including 27. No test is held aside.
- [ ] `./scripts/docker-test.sh test --reset --profiles crm,pm` gives the same result it gives on the base revision apart from this fix: the conformance suite passes. (The host test `21_api_security.sh` fails at "reviewer sees its own area's candidate" on the base revision; that is work/003's and is not counted here.)
- [ ] A test exists that fails on a non-superuser owner before the fix and passes after it. The builder shows both runs.
- [ ] The calibration figures a session sees are computed only from predictions and outcomes that session may see. The fix does not make any row visible to a session that could not see it before, unless the Architect has written that rule into the contract first.
- [ ] If the same cause affects other objects from 0017 to 0021 (salience, source reliability, pattern support, review queue, stale digests, weighted assertions), each is listed with its disposition: fixed here, not affected and why, or left open.
- [ ] Migrations 0022 and 0023, which met for the first time on the base revision, install together and the suite passes with both.

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

## Verified
- filled in at close

## Reports

## Close
