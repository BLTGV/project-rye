# 009 who-may-write

- status: open
- opened: 2026-09-20
- areas: schema
- contracts: contracts/sql-surface.md
- base revision: 642a889 on agent-roles

## Goal
A session that only reads cannot write, and nobody but a Rye admin can switch
off the review rules for an area. Today a `viewer`, and a session with no
role set at all, can insert assertions, archive an area's scope node, archive
the edge that says which scope governs a subject, and merge nodes. An agent
can delete that governing edge. Any of these turns a strict area into an open
one for helpers and raw writes alike, which undoes work/005 and work/008 from
the side. Separately, `merge_nodes()` under an agent role on a non-superuser
owner fails with a misleading "Duplicate node not found", because its row
lock is filtered by RLS before any gate opens (work/006).

## What this does and does not protect
Same boundary as work/008: session variables are the only authorization, so
this protects deployments where a trusted backend sets them and agents that
state their role honestly. Say no more than that anywhere.

## Intent excerpt (BRIEF.md)
"Agents suggest; people accept. Review policy is per scope." "An agent
carries the authority of the person it acts for and none of its own."

## Found by execution (work/008 Verifier, non-superuser role, committed)
- viewer, team_member, agent:t, and no role: direct INSERT into assertions lands.
- viewer: `UPDATE rye.nodes SET archived_at = now()` on an onboarding_scope node, 1 row; archiving a `scope_governs_subject` edge, 1 row. agent:t: DELETE of that edge, 1 row. Afterwards record_assertion() and raw inserts both land accepted in what was a strict scope.
- viewer can call merge_nodes().
- `assertion_insert_policy` gates assertion types, never roles.

## Acceptance criteria
- [ ] A `viewer` session and a session with no role set cannot insert, update, archive, or delete nodes, edges, events, event participants, assertions, assertion evidence, or artifacts, by raw SQL or through any helper. Reads are unchanged. The Architect lists every table and helper covered.
- [ ] No caller other than a Rye admin can archive, end, delete, or re-point the things that decide which review policy governs a subject: onboarding_scope nodes, `scope_governs_subject` and `scope_governs_source` edges, and any other edge or node governing_scope() reads. The Architect names the full set from governing_scope() and scope_review_policy().
- [ ] After every refused attempt, scope_review_policy() for the subject is unchanged and an agent write that was a candidate before is still a candidate.
- [ ] merge_nodes(): an agent or viewer gets a plain refusal that says who can merge, not "Duplicate node not found", on both owner types. A caller allowed to merge still can, on both owner types.
- [ ] Every existing suite, seed, replay load, scripts/rye subcommand, and the admin Worker still work. Where a test or script relied on writing with no role set, it now sets one, and the report lists each such change.
- [ ] A conformance or security test covers each case under a non-superuser role and under the non-superuser owner, fails without the new migration, and refuses to pass vacuously (superuser, row_security off, role not read back, ROW_COUNT unchecked).
- [ ] `./scripts/test-all.sh` passes.

## Constraints
- One new migration, 0026. No applied migration edited; 0022 to 0025 are applied.
- Session variables only; no current_user, session_user, pg_has_role(); every function declares search_path; no new tables unless shown necessary.
- Prefer RLS policies and the existing role tables (role_classification_access, assertion_type_access) over new mechanisms. Follow the lock-after-gate ordering recorded in docs/areas/schema.md for any FOR UPDATE.
- Trigger names on assertions: trg_assertion_settle_gate must still sort first; test 30 and test 31 pass unmodified.
- Docker: own COMPOSE_PROJECT_NAME and RYE_POSTGRES_PORT, exported before every script. No /tmp scratch. No push.

## Decided by the human
- 2026-09-20, Casey: fix the remaining items from this session and the others so the branch can be merged.

## Assumed by default
- `viewer` and an unset role are read-only. Overturn: Casey.
- Who may merge nodes: admin and team_member. Agents and viewers may not; an agent that finds a duplicate says so to its person. Overturn: Casey (work/006 queued this question for you).
- Scope and governance structure is configuration, so admin only, consistent with decision 0007. Overturn: Casey.
- team_member and agent:* keep every other write they have today. Overturn: Architect.
- Who may merge, as the Architect built it: any named role that may write; never an agent-shaped session, never viewer or unset. A `may_merge` column is the way to narrow it to admin and team_member. Overturn: Casey.
- `scope_status` becomes admin-gated, reversing a stated choice in decision 0007, because scope creation is now admin-only. Overturn: Casey.

## Verified
- filled in at close

## Reports
### Architect, 2026-09-20 (commits 7356ce2, 32504b7, 940a5a9)
Decision 0009. role_classification_access gains may_write (viewer false);
rye_role_may_write() is a conjunct on every INSERT, UPDATE, DELETE policy of
the seven core tables. Scope and governance structure admin-only.
merge_nodes() and update_node_properties() refuse before FOR UPDATE, so
"Duplicate node not found" only means absent or invisible. Migration 0026
replaces those policies and those two functions and nothing 0027 touches.
Blast radius: nine sites write with no role; conformance 01, 02, 03, 04, 05,
07, 09 and seed_quickstart.sh must set one; concurrency/01 to confirm;
nothing writes as viewer. migrate.sh runs each migration in its own session,
so 0026 sets admin itself.


## Close
status line and date
