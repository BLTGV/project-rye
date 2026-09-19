# 005 registry-write-gate

- status: open
- opened: 2026-09-19
- areas: schema, agent-kit
- contracts: contracts/sql-surface.md

## Goal
Only a Rye admin can change Rye's own configuration. Today any caller,
including an agent, can record an accepted registry entry when the area's
review policy is open, which is also the answer on a fresh install with no
policy recorded. The registry holds type aliases and the list of things a
person may settle about themselves, and since work/002 those decide who may
settle a claim. An agent that writes one alias can hand a person the
expectation their manager set on them. Found by the Verifier on work/002,
by execution. The gap predates work/002: the registry and aliases are from
migrations 0017 and 0018.

## Intent excerpt (BRIEF.md)
"An agent carries the authority of the person it acts for and none of its
own." "Accepted stays accepted until a settler changes it." And from the
authorization strategy: ordinary conversation content cannot authorize
policy changes.

## Acceptance criteria
- [ ] Under an agent role, a viewer, and a team member, an attempt to record an accepted registry entry (a type alias, a self-settled type, or any other registry key) never lands accepted, under review policy open, candidates_only, strict, and with no policy recorded at all.
- [ ] Nothing a person or agent says is lost: such an attempt lands as a suggestion a Rye admin can accept or decline, with the usual evidence, and the caller is told plainly that it is waiting for an admin. It is not an error that discards the statement.
- [ ] A Rye admin can still record and accept registry entries, and the existing seeds and onboarding flows that write registry entries still work.
- [ ] No lifecycle helper lets a non-admin turn a registry suggestion into an accepted entry: accept, supersede, schedule, and any other path that ends in an accepted registry entry.
- [ ] After a non-admin attempt, the answer to "who may settle an expectation on John" is unchanged for every role.
- [ ] The same gate covers the other configuration Rye reads to make decisions, or the item says which it covers and lists the rest: scope policies, review policy, governed types, plugin enablement. The Architect names the set.
- [ ] A conformance or security test covers each case above under a non-superuser role and refuses to pass vacuously.
- [ ] The agent-operations skill tells an agent that declaring a self type or an alias is an admin's call, and what to say to the person in plain words.

## Constraints
- Additive: a new numbered migration. Use 0023: a separate session working on work/004 has taken 0022. Applied migrations are not edited; 0021 is now merged and treated as applied.
- Authorization stays session variables only. No SECURITY DEFINER shortcut that reads or writes past RLS.
- Prefer existing mechanisms: assertion_type_access, review policy, the lifecycle helpers. No new tables unless the Architect shows none of those can express it.
- No customer names. Internals keep canonical vocabulary; person-facing lines use the glossary.

## Decided by the human
- none yet. Casey asked for GitHub issue 16 to be fixed and approved the authority model; this gap was found afterward.

## Assumed by default
- A non-admin attempt lands as a suggestion rather than being refused, so nothing said is lost. Overturn: Casey.
- "Rye admin" means app.current_role = 'admin'. An area owner who is not an admin cannot accept configuration. Overturn: Casey, since it means an area owner must ask an admin to declare a self type.
- The Architect decides how wide the gate is beyond registry entries. Overturn: Architect.
- work/004 (RLS on the governance tables, separate session) is independent and merges separately; whichever lands second reconciles migration order. Overturn: Lead.

## Verified
- filled in at close

## Reports
Paste each role's report here as it arrives.

### Architect, 2026-09-19
Result: done. Changed: contracts/sql-surface.md (new "Configuration writes
need an admin"), docs/decisions/0007-configuration-writes-need-an-admin.md
(with 11 test obligations). Mechanism: assertion_type_access `write` rows
refuse through the RLS INSERT policy and would discard the statement, so
the table gains a third operation value `settle` (data, admin-writable,
readable by every role so the gate is never invisible to the caller it
binds). record_assertion() demotes to candidate at the same point as the
review-policy demotion, BEFORE the block that supersedes the incumbent, or
the key would be erased. One BEFORE INSERT OR UPDATE trigger on assertions
raises on every other route, and fires inside SECURITY DEFINER helpers.
Lifecycle: demote in record_assertion() only; refuse in accept_assertion,
supersede_assertion, record_distillation, raw INSERT, raw UPDATE;
schedule_assertion_change and record_scope_policy route through
record_assertion and demote. Set covered: registry_entry, review_policy.
Deferred with reasons: scope_status (demotion fails open), plugin
enablement (an edge, not an assertion), other scope policy types,
domain_authorities. Existing flows: every registry and scope-policy write
in tests, scripts/rye, and sync_plugin_metadata.sh already runs as admin;
migrations must set the role. Caller is told through attrs.settle_gate on
the candidate, visible in review_queue, plus a read function
settle_gate(type) to ask first. Learned: a non-admin can insert an accepted
assertion directly today, and can promote ANY candidate with a raw UPDATE
after setting app.write_path and app.accept_assertion_id, because the RLS
update policy trusts those settings and the 0019 immutability guard no
longer lists status. Wider than this item; gated here only for
configuration types. Questions: the wider promotion hole as its own item
(Lead: yes, flagged separately); settle_gate() as a new read function
(Lead: accepted).

### Builder schema, 2026-09-19 (commit 9502c63, branch worktree-agent-a857af82028ec3665)
Result: done. schema/migrations/0023_configuration_settle_gate.sql: `settle`
operation on assertion_type_access (inline CHECK dropped and re-added; two
admin-only rows seeded inside a DO block that sets the admin role locally);
assertion_settle_roles(), may_settle_assertion_type(), settle_gate();
record_assertion() replaced with the demotion placed before the
review-policy demotion, so the requested status is what is gated and the
mark appears under strict and candidates_only too, and before supersession;
assertion_settle_gate_guard() with trg_assertion_settle_gate.
tests/conformance/30_configuration_gate.sql covers all 11 obligations; each
was confirmed to fail on a live install before the migration, including
the defect itself: under agent:t, rye_settlers(John, expectation,
self_commitment) flipped from Bob/manager to John/self; after the migration
it stays Bob/manager for admin, agent, and viewer. Full Docker flow passed
from an empty volume on port 54339 (another agent held the default).
Learned: see docs/areas/schema.md entries dated 2026-09-19. Questions: a
remaining path, erasure: a non-admin can UPDATE an already accepted gated
row's superseded_at with app.write_path = 'supersede_assertion', ending an
accepted alias without creating an accepted row; the trigger deliberately
lets accepted-to-accepted updates through (Lead: routed to the separate
promotion-and-erasure item; Verifier asked to reproduce it and report the
lookup's answer afterwards). Criterion 8 is agent-kit's (Lead: dispatched).

### Builder agent-kit, 2026-09-19 (commit c6dbad6, branch worktree-agent-a20ce071bc8dc1085)
Result: done, criterion 8. SKILL.md: new "Rye's own setup is an admin's
call" (the gated set, settle_gate()); "Declaring a type a person's own
call" rewritten for admin versus anyone else, one route and only once,
nothing changes while it waits; two person-facing lines; a role rule under
"What you must never do" (the agent does not set its own role to admin).
docs/agent-ops-guide.md and docs/conventions-catalog.md match (new
Configuration Write Convention; Settlement Convention corrected). Scenario
manager-expectation gains one beat and rubric lines, marked per contract,
not yet executed. rye-skill.json lists settle_gate. Tested: intake check
passes; 19 manifests validate; 22_secure_mcp_simulation.sh not run (no
database for this builder). Questions: the glossary has no plain term for
Rye's own configuration; rendered as "how Rye is set up here" (Lead: route
the suggested entry to Product at close); scripts/rye has no settle-gate
subcommand while every neighbouring lookup has a CLI form (Lead: a small
follow-up for the schema area, not blocking).

### Verifier, 2026-09-19, live Docker install on its own port, commit 9502c63: PASS on criteria 1-7; 8 pending
Criteria 1-7 verified by execution under SET ROLE to the non-superuser
conformance role. 36 record_assertion attempts (3 roles by 4 policies by 3
keys) all landed as candidates with attrs.settle_gate.pending true and
appeared in review_queue; registry_value() stayed null. accept_assertion,
a raw UPDATE with spoofed write-path settings, supersede_assertion, direct
INSERT, and record_distillation all raised insufficient_privilege;
schedule_assertion_change and record_scope_policy demoted;
rye.authoritative.promote did not open it. After 143 probe attempts
rye_settlers(John, expectation, self_commitment) was byte-identical to
baseline for admin, agent, viewer, team_member. Admin paths work; the full
suite passed including seeds and onboarding. Test 30 refuses to run as
superuser and fails on a tree without 0023, where the original defect
reproduces exactly. Role-string attacks (Admin, ADMIN, padded, agent:admin,
admin,admin, empty, unset) all failed closed. Gate rows readable by every
role; DELETE and UPDATE affected 0 rows and INSERT raised for non-admins.
record_assertion() differs from the 0018 version by exactly the demotion
block, placed before supersession. FINDING, HIGH, reproduced: a non-admin
can end an accepted gated row by spoofing app.write_path =
'supersede_assertion' (0023 lines 392-394 return NEW when OLD.status is
accepted). For registry_entry the result is restrictive. For review_policy
it is NOT: scope_review_policy() fell from strict to open and the same
ordinary agent write then landed accepted. Lead: ruled in scope, since the
goal is that only an admin changes configuration; sent to the schema
builder as fix attempt 1. Cookbook: 39 statements executed, 3 failed from
one ordering bug, 3 were silent no-ops (SET LOCAL outside a transaction);
everything else confirmed correct; sent to the cookbook author.

### Builder schema, 2026-09-19, fix attempt 1 (commit 0c6f77e)
Result: done. 0023 edited in place: assertion_settle_gate_guard() now
raises, for a gated type and a caller not in allowed_roles, both when a row
becomes accepted and when an already accepted row is changed in any way; on
UPDATE the gated spelling is taken from OLD, so an accepted configuration
row stays configuration; candidates untouched. New obligation 5b in test
30. Pre-fix reproduction under agent:t on the non-superuser role: ending an
accepted registry_entry succeeded; narrowing effective_to succeeded;
rewriting attrs through the assertion_outcome path succeeded; ending the
scope's review_policy succeeded, scope_review_policy fell strict to open,
and the next ordinary agent write landed ACCEPTED. Post-fix all are
refused, the policy stays strict, and that write lands as a candidate.
Full Docker flow passed from an empty volume. Learned:
assertion_delete_policy is USING (false), so no role deletes an assertion,
admin included, and DELETE returns 0 rows silently, so tests must check
ROW_COUNT; app.write_path = 'assertion_outcome' is the one path the 0019
immutability guard lets attrs through.

### Builder agent-kit, 2026-09-19, session context in two docs (commit 85df91b)
docs/agent-ops-guide.md "Start a session" now uses plain SET;
docs/conventions-catalog.md "Session Variable Convention" keeps SET LOCAL
and gains BEGIN and COMMIT. No SET LOCAL in any SKILL.md; the two script
hits emit BEGIN on the line before. Intake check passes. Found while
executing the small product team cookbook; rides on this branch.

## Close
