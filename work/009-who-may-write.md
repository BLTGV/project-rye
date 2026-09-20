# 009 who-may-write

- status: done
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
- [x] A `viewer` session and a session with no role set cannot insert, update, archive, or delete nodes, edges, events, event participants, assertions, assertion evidence, or artifacts, by raw SQL or through any helper. Reads are unchanged. The Architect lists every table and helper covered.
- [x] No caller other than a Rye admin can archive, end, delete, or re-point the things that decide which review policy governs a subject: onboarding_scope nodes, `scope_governs_subject` and `scope_governs_source` edges, and any other edge or node governing_scope() reads. The Architect names the full set from governing_scope() and scope_review_policy().
- [x] After every refused attempt, scope_review_policy() for the subject is unchanged and an agent write that was a candidate before is still a candidate.
- [x] merge_nodes(): an agent or viewer gets a plain refusal that says who can merge, not "Duplicate node not found", on both owner types. A caller allowed to merge still can, on both owner types.
- [x] Every existing suite, seed, replay load, scripts/rye subcommand, and the admin Worker still work. Where a test or script relied on writing with no role set, it now sets one, and the report lists each such change.
- [x] A conformance or security test covers each case under a non-superuser role and under the non-superuser owner, fails without the new migration, and refuses to pass vacuously (superuser, row_security off, role not read back, ROW_COUNT unchecked).
- [x] `./scripts/test-all.sh` passes.

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
- Change capture keeps recording when the application's session has no Rye role, under a reserved `system:cdc` role that may only insert events and participants; the event records the original session role. The Architect first ruled that such writes record nothing; the Lead overturned that because a role-less application session is the normal overlay deployment. Overturn: Casey.
- Tests 30 and 31 had to change: they attacked as viewer and unset, which can no longer write. Their write loops now use agent:t and team_member, and the viewer and unset cases move to test 32 as refusals. Overturn: Lead.

## Verified
- Verifier, three passes by execution under both database owner types, committed, read back as admin. Third pass PASS on a tree carrying 0026 and 0027 together: viewer and unset sessions write nothing to the seven core tables or node_source_map, by raw SQL or through any helper, including all eight SECURITY DEFINER writers (list derived from pg_proc; the same calls succeed as admin in the same run); role-string spellings fail closed; scope and governance structure is admin-only for every verb and scope_review_policy() stayed strict after every attempt; merge_nodes() refuses agents, viewer, unset, and system:cdc with a plain 42501 before the lock, including for an absent id, and refuses a non-admin on a governed node; system:cdc can only insert events and participants; CDC records role-less, viewer, and agent:t domain writes with session_role, and the caller's role is restored after savepoints, multi-row statements, and a forced CDC failure; all write policies keep every prior conjunct; trigger order on assertions is settle gate, gate_may_write, immutable, insert_review under C and en_US; bulk cost 1.18x on a 5,000-row insert. Suite 32 fails without 0026 under both owners and refuses a superuser.
- Refusal shape differs: a refused INSERT raises 42501; a refused UPDATE or DELETE by an ordinary session is zero rows on every owner type; only a session that IS a superuser owner sees the trigger raise. Tests assert the row.
- Lead, integration, 2026-09-20: merged at 07022ba; final combined run on b7da6fd, `./scripts/test-all.sh` exit 0, both owner types.
- Not verified: any deployed instance.


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


### Builder schema, 2026-09-20 (branch worktree-agent-a4ce0a332077aac6e, commits 873c640, 2c9a781)
0026: may_write, rye_role_may_write(), the conjunct on 21 policies,
governance rule, merge_nodes and update_node_properties gated before the
lock, scope_status settle row. Eight blast-radius sites set admin. Tests 30
and 31 narrowed (missed by the decision). test-all.sh green, both owners.
Found: role_classification_access had no UPDATE policy.

### Verifier, 2026-09-20, first pass: FAIL
HIGH: viewer writes through accept_assertion, reject_candidate,
mark_assertion_outcome under a superuser owner, because a definer function
owned by a superuser skips RLS and so the policy conjunct. MEDIUM: coverage
dropped where tests 30 and 31 were narrowed. All else passed.

### Architect, 2026-09-20 (da415de, 7acf534)
The gate is a BEFORE ROW trigger on the seven core tables, the conjunct the
second line; names in the contract. CDC records under system:cdc (Lead's
overturn), insert on events and participants only, session_role recorded.
Fix attempt 1 sent to the builder.

### Builder schema, 2026-09-20, fix attempt 1 (commit ccabd0f)
rye_gate_may_write() BEFORE ROW trigger on the seven core tables, names per
the contract; system:cdc row and capture_domain_change() role swap around
record_event() only, session_role recorded; merge_nodes() refuses
system:cdc. Test 32 derives the prosecdef writers from pg_proc (eight) and
raises if one is uncovered. Negative controls reproduce the hole on 2c9a781.

### Verifier, 2026-09-20, second pass: FAIL
All eight definer writers refused for viewer and unset on both owners;
system:cdc contained; role restored after savepoints, multi-row statements,
and a forced CDC failure; bulk cost 1.18x on 5,000 rows. MEDIUM, new:
node_source_map's insert policy was WITH CHECK (true), so a viewer could map
any visible node into a tracked table, or re-point a mapping, and have CDC
write events against it.

### Builder schema, 2026-09-20, fix attempt 2 (commit bee3a52)
node_source_map gated by the same conjunct and trigger. Sweep of supporting
tables: all others already refused, except node_merges and
crm_code_counters, which had no RLS. Lead first listed those as bookkeeping.

### Verifier, 2026-09-20, third pass: PASS
On a tree carrying 0026 and 0027 together, both owners. Found that
crm_code_counters was not bookkeeping (a viewer could rewind a counter and
the next create_task() collided); moved to work/011, migration 0029.

## Close
done 2026-09-20. Merged to agent-roles at 07022ba; combined suite passed on b7da6fd. Two verifier failures, each a different hole (definer helpers under a superuser owner; node_source_map as a CDC write primitive), both closed. The Lead overturned one Architect ruling (CDC must keep recording).
