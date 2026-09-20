# 008 assertion-lifecycle-gate

- status: open, integrating. Ruling received (see "Ruled by Casey"). Four verifier passes; every HIGH is closed; one MEDIUM and one LOW remain, both rulings. Not merged.
- opened: 2026-09-19
- areas: schema
- contracts: contracts/sql-surface.md
- base revision: af232e9 on agent-roles (carries work/005 and migration 0023)

## Goal
An assertion becomes accepted, and an accepted assertion ends or changes,
only through Rye's lifecycle helpers, which are where review policy and the
who-may-settle rules are applied. Today any caller who is not an admin can
go around them with plain SQL: write an accepted row directly, promote any
suggestion to accepted, or end an accepted row with nothing replacing it.
The update rules trust session settings (`app.write_path` and the per-path
row id settings) that the helpers set, and that any caller can set too.
work/005 closed this for configuration types only (registry_entry,
review_policy). This item is every other assertion type, plus erasure.

## What this does and does not protect
Rye's authorization is session variables only. A caller holding a raw
connection can also set `app.current_role = 'admin'`, and nothing in this
item changes that. This gate, like all Rye RLS, protects two things:
deployments where a trusted backend sets the session variables and callers
cannot, and well-behaved agents that state their role honestly and must not
be able to skip review by accident or by following bad instructions. It is
not a defence against a hostile caller with a raw connection. Nothing in
the contract, the migration comments, or the docs may claim more.

## Intent excerpt (BRIEF.md)
"Agents suggest; people accept. Review policy is per scope." "Acceptance
follows authority. An agent carries the authority of the person it acts for
and none of its own." "Accepted stays accepted until a settler changes it."

## Reproduced before dispatch
Lead, 2026-09-19, af232e9, fresh Docker install with crm,pm, under
`SET ROLE` to a role with rolsuper false and row_security on. Session
variables set with `set_config()`. Roles tried: `agent:t`, `viewer`,
`team_member`, and no role set at all. All four gave the same result:
- Direct `INSERT INTO assertions (... status = 'accepted' ...)` landed
  accepted.
- A candidate was promoted with a raw `UPDATE ... SET status = 'accepted'`
  after setting `app.write_path = 'accept_assertion'` and
  `app.accept_assertion_id` to the row id.
- An accepted row was ended with a raw `UPDATE ... SET superseded_at =
  now()` after setting `app.write_path = 'supersede_assertion'` and
  `app.supersede_assertion_id`. `superseded_by` stayed null: nothing
  replaced it.
- On an accepted row, with the matching path and id settings forged:
  `effective_to` was narrowed, `attrs` was rewritten through the
  `assertion_outcome` path, and `classification` was changed through the
  `assertion_classification` path (set to `public`).
Corrections to the finding as first recorded: erasure needs a second
setting, `app.supersede_assertion_id`, not only `app.write_path`; and
`assertions_immutable_guard` in 0019 does still test `status`, but its
allowance reads the same forgeable settings, so it stops nothing. A viewer
and a session with no role being able to insert assertions at all is
noted for the Architect; it may be a separate gap.
Not re-run by the Lead: the review_policy fallback. work/005's Verifier
already showed that ending a review_policy drops scope_review_policy() from
strict to open, and that 0023 now refuses it. This item must not reopen it.

## Acceptance criteria
- [ ] Under an agent role, a viewer, a team member, and no role set, a direct INSERT of an accepted assertion of an ordinary type does not land accepted outside what record_assertion() would have allowed the same caller in the same scope. The Architect decides whether it is refused or lands as a suggestion, and says why.
- [ ] Under the same four callers, no raw UPDATE promotes a candidate, whatever session settings the caller sets first. Every helper-owned setting is tried, not only the two known ones.
- [ ] Under the same four callers, no raw UPDATE ends an accepted assertion, narrows its window, rewrites its attrs, or changes its classification, whatever settings the caller sets first.
- [ ] Every lifecycle helper still works for a caller it worked for before: record_assertion, accept_assertion, reject_candidate, supersede_assertion, schedule_assertion_change, record_distillation, resolve_knowledge_gap, mark_assertion_outcome, window narrowing inside record_assertion, classification propagation from evidence, merge_nodes, and the crm and pm profile helpers that write assertions. The Architect lists the full set from the migrations; the list above is the Lead's starting point, not the answer.
- [ ] A helper still refuses what it refused before: an agent under a strict review policy cannot accept through accept_assertion().
- [ ] work/005 is unchanged in effect: tests/conformance/30_configuration_gate.sql passes unmodified, and ending or promoting a registry_entry or review_policy as a non-admin is still refused.
- [ ] A conformance or security test covers each case above under a non-superuser role, fails on a tree without the new migration, and refuses to pass vacuously: it refuses to run as a superuser or with row_security off, it checks ROW_COUNT after every UPDATE and DELETE (RLS turns a refused write into zero rows, not an error), and it proves the session role was actually set (`SET app.current_role = ...` is a syntax error because current_role is reserved; use set_config()).
- [ ] `./scripts/docker-test.sh test --reset --profiles crm,pm` passes from an empty volume.
- [ ] The contract and the migration header state the protection boundary in the terms of "What this does and does not protect" above.

## Constraints
- Additive: one new numbered migration, 0025. 0022 is work/004 and 0024 is work/006, both in another session's worktrees and not yet on this branch; 0023 is work/005. No applied migration is edited, 0023 included.
- Authorization is session variables only. No current_user, session_user, or pg_has_role() for authorization. Every function declares its own search_path.
- Trigger order: triggers on assertions fire alphabetically by name. work/005's is trg_assertion_settle_gate. The Architect states where the new or changed trigger sorts relative to it and to the immutability guard's trigger, and why the order is safe both ways.
- `status` and `superseded_at` are in the immutability guard with an explicit allowance for the helpers, and that allowance must not be something a non-admin caller can produce with set_config().
- Helpers that are SECURITY DEFINER stay hardened as design/model/deployment.md describes. No new route that reads or writes past RLS for the caller's benefit.
- No new tables unless the Architect shows the existing mechanisms cannot express it.
- No customer names. Invented names only in tests.
- Docker: check `docker ps` first; use an unused RYE_POSTGRES_PORT and a COMPOSE_PROJECT_NAME of your own. Other sessions hold other ports; `--reset` on a shared project name would drop their volume.

## Decided by the human
- 2026-09-19, Casey: acceptance and supersession go only through the lifecycle helpers; the helper-only settings are made unforgeable by a caller or replaced by something a caller cannot set; `status` and `superseded_at` return to the immutability guard with an explicit allowance for the helpers; coordinate with work/005's trigger; tests run under a non-superuser role, fail before the change, and refuse to pass vacuously; the framing stays honest about what session-variable authorization can protect.
- 2026-09-19, Casey: do not push.

## Assumed by default
- Item number 008 and migration 0025. Opened as 007; renumbered 2026-09-20 at integration because the other session had closed work/007-ci-nonsuperuser-owner by then. Reports below that say work/007 mean this item. Overturn: Lead.
- The four other forged paths found during reproduction (window, outcome attrs, classification, and the supersede id) are in scope, since they are the same defect. Overturn: Casey.
- Admin keeps the ability it has today. Whether an admin may do by raw UPDATE what a helper does is the Architect's call. Overturn: Architect.
- Viewer and no-role callers being able to insert assertions at all is reported, and fixed here only if the Architect finds it is the same mechanism. Overturn: Architect.
- Mechanism (decision 0008): no signal a helper can produce is out of a caller's reach under session-variable authorization, so the gate reads the row, not the route. Casey asked for the settings to be "made unforgeable or replaced by something a caller cannot set"; this is the second branch. Consequence: a caller who forges the settings can still do by raw SQL what the matching helper would have let that same caller do, provided it also writes what the helper writes (the acceptance event, a real replacement). It cannot do more. Overturn: Casey.
- A merge under a strict scope now moves the copied assertions into review instead of carrying them across accepted. Visible behavior change. Overturn: Casey.
- An admin gets no raw-UPDATE exemption, because an exemption keyed on the role is forgeable by the same set_config(). An admin's raw `UPDATE assertions SET superseded_at = now()` works today and will fail; the helpers remain. Overturn: Casey.
- Three refusals arrive at COMMIT, not at the statement. Overturn: Architect.
- The raw-promotion rule must refuse whatever accept_assertion() refuses for the same caller and row. If accept_assertion() checks more than decision 0008 section C lists, the guard follows the helper. Overturn: Architect.
- No agent-kit change: the skill already tells agents to use the helpers. If the Architect changes a helper's signature or a caller-visible message, agent-kit is added. Overturn: Architect.

## Verified
Nothing is merged. What follows was checked by execution on the builder's
branch worktree-agent-adaac359cced8c325 at 21919b9 (agent-roles ff99729
merged in), by the Verifier, third pass, on a live Docker install under SET
ROLE to a non-superuser role, with writes committed and rows re-read:
- Holds for agent:t, viewer, team_member, and no role, with every helper-owned setting forged: a direct accepted INSERT is judged by the scope's review policy exactly as record_assertion() would (accepted under open, candidate under strict and candidates_only); no raw UPDATE promotes a candidate; no raw UPDATE narrows a window without a successor, rewrites or drops attrs keys, changes classification, un-ends a row, or moves accepted back to candidate; a cross-tuple replacement, a decoy replacement, a two-subject row, and a future-effective promotion into an instant an accepted row holds are all refused.
- Every helper in decision 0008 obligation 8 still commits, asserted by effect. accept_assertion() still refuses agent:t under strict. Test 30 is byte-identical to agent-roles and passes. Test 31 fails without 0025 and refuses a superuser. `./scripts/docker-test.sh test --reset --profiles crm,pm` passes from an empty volume. Constraint audit passes: no current_user, session_user, pg_has_role, SECURITY DEFINER, or new table; all seven functions declare search_path.
- DOES NOT HOLD (open HIGH): a caller can end an accepted assertion by naming a replacement it cannot read back. Both replacement checks (0025 lines 426 and 558, `IF FOUND`) run under the caller's RLS, so a row the caller classifies above its own read level passes both. Reproduced as viewer, committed: forge the supersede settings, UPDATE the accepted row setting superseded_at and superseded_by to a new id, INSERT that id as a candidate of another type and key with classification 'restricted', COMMIT. The incumbent is ended and current_valid_assertions has 0 rows for the tuple. This is erasure, the thing this item exists to stop. It is the one fail-open decision 0008 section A chose on purpose.
- DOES NOT HOLD (LOW): 0025 line 534 says the contract discloses that fail-open; the contract's list of limits does not.

## Ruled by Casey, 2026-09-20
Take the Lead's recommendation on both remaining findings: change no code, disclose the hidden-rival overlap as a stated limit and correct the false sentence, reword the erasure claim to "replaced, or moved into review". Also: integrate the other session's verified items (work/004 with 0022, work/006 with 0024, work/007-ci) so everything merges together. Architect wording: da2f316. Their branch merged into agent-roles at 285d694.

## Open ruling, 2026-09-20 (fourth pass, builder df43fa1, Architect 002044a)
Closed and re-verified on df43fa1: the invisible-replacement erasure, in
twelve committed runs (four callers by three hidden classifications), a
replacement on an unseen node, a chain ending in an invisible row, and an
invisible successor; the incumbent survived every time on an admin
read-back. All earlier fixes hold. Full Docker flow passes. One deliberate
new refusal confirmed: record_assertion() with p_classification above the
caller's own read level, superseding a lower-classified accepted incumbent,
fails at COMMIT with the incumbent intact.
Remaining:
- MEDIUM. A caller who cannot see an accepted rival (classified above its read level) can raw-promote a visible candidate on the same tuple and leave two overlapping accepted rows. accept_assertion() by the same caller leaves one in the Docker install, because it is SECURITY DEFINER over a superuser owner and reads past RLS, which means it ends a row the caller cannot see. On Supabase the owner is not a superuser, so helper and raw path agree. The contract's sentence that the helper reads rivals "the same way" is therefore false in the reference install. The inferred-displacement search has the same root cause and is untested (fixture could not be built).
- LOW. An accepted row may be ended naming a same-tuple replacement that is a candidate, leaving no accepted value and one row in review_queue. Requiring the replacement to be accepted would break merge_nodes() under a strict scope, which is the default already taken. The contract's bold claim "never ends with nothing replacing it" reads stronger than the rule.
Lead's recommendation: change no code. Disclose the MEDIUM as a stated limit and correct the false sentence; reword the LOW's claim to "replaced, or moved into review". The alternative for the MEDIUM, a SECURITY DEFINER reader used only to refuse, would tell a caller that a hidden row exists, is a no-op on Supabase where the owner is bound by RLS, and cuts against the constraint on reading past RLS.

## Hand-off to Casey (after the third pass; superseded by "Open ruling" above)
Verification failed three times. Each failure was a different problem and each earlier one was fixed and re-verified, so no single problem survived two attempts; but three passes each finding a new HIGH is the signal the two-strike rule exists for, so the Lead stopped rather than run a third fix.
- Recommended next step, small: fail closed. In both replacement checks, raise when the named row is not visible (`IF NOT FOUND THEN RAISE`) in place of passing. The Verifier checked the cost: supersede_assertion() copies the incumbent's classification, so a helper's replacement is always as readable as the row it replaces. Architect amends decision 0008 section A and the contract's limits; builder edits 0025 in place (it is applied nowhere) and adds the attack to test 31; Verifier runs a fourth pass.
- The question worth a person's judgment: whether "the row is the gate" is converging. Found so far by attack, not by the design: a cross-tuple exemption, a null-collapsing comparison, a skipped rival test, NEW.subject_ref being null in BEFORE triggers, two-subject rows, and RLS-invisible replacements. The alternative the Architect rejected (REVOKE UPDATE plus SECURITY DEFINER helpers) is a no-op on Supabase and the Docker login, where the connection is the table owner.
- Branch to review: worktree-agent-adaac359cced8c325 (64e9e14, 6115bca, 19f4b2d, 21919b9). Contract and decision are on agent-roles (f3808d8, ff99729). Nothing pushed.
- Follow-up items the Lead will open once this is settled, none fixed here: what viewer and an unset role may write at all (they can insert assertions, archive a scope node, and archive or delete a scope_governs_subject edge, which turns strict into open for helpers and raw writes alike); supersede_assertion() never consults the review policy; merge_nodes() plus governing_scope() choose the governing scope by lowest uuid after a cross-scope merge, so obligation 11 holds only when id order cooperates.

## Reports
Paste each role's report here as it arrives.

### Architect, 2026-09-19 (commit f3808d8)
Result: done. Changed: contracts/sql-surface.md (new "The row is the gate,
not the route"; one bullet under Failure behavior),
docs/decisions/0008-the-row-is-the-gate-for-assertion-lifecycle.md (A to I,
14 test obligations), docs/areas/schema.md (one entry corrected, five
added). Tested: none, docs only; derived by grep. Mechanism: there is no
unforgeable helper signal here. Session variables forge; table privileges
do not bind the owner (Supabase `postgres`, Docker `rye`); PG_CONTEXT can be
matched from a pg_temp function; current_query() is text. So
assertions_immutable_guard() is replaced in place with per-column rules
read from OLD, NEW, existing rows, and app.current_role; a BEFORE INSERT
trigger trg_assertions_insert_review demotes where record_assertion()
demotes; a deferred constraint trigger trg_assertions_transition_complete
checks the acceptance event, the replacement's type and key, and the
narrowed window's successor. app.write_path stays as a pre-filter and
grants nothing. No helper changes. trg_assertion_settle_gate sorts first in
both C and en_US collations, and test 30 depends on it. Exactly five
functions UPDATE assertions. Questions: commit-time refusals (Lead:
accepted, listed as a default); merge under strict routes to review (Lead:
accepted as a default Casey can overturn); viewer and no-role callers
inserting assertions at all is a role-model gap, not forgery (Lead: separate
item); supersede_assertion() never consults the review policy, so any caller
writes an accepted row under strict by superseding (Lead: separate item;
0025 must not half-close it).

### Builder schema, 2026-09-19 (branch worktree-agent-adaac359cced8c325, commits 64e9e14, 6115bca)
Result: done. schema/migrations/0025_assertion_lifecycle_gate.sql,
tests/conformance/31_assertion_lifecycle_gate.sql, scripts/verify.sh,
docs/data-dictionary.md, design/model/security.md. Negative control: test 31
fails without 0025 at obligation 2. Full Docker flow passed from an empty
volume on port 54351. Followed the helper where it checks more than
decision C: an inferred candidate may not displace a non-inferred
incumbent. Two deviations reported: classification may change only on a row
that has derivation evidence; the rival test covered "now" only.

### Verifier, 2026-09-19, first pass on 6115bca: FAIL
HIGH: the insert-time exemption checked neither subject, type, nor key, so
an accepted row landed under a strict scope. MEDIUM: a null-collapsing
comparison let attrs be rewritten with no outcome. MEDIUM: the rival test
was skipped for future-effective rows, leaving two overlapping accepted
rows. LOW: the classification deviation is safe but undocumented. Criteria
2, 4 to 8, and 10 passed.

### Architect, 2026-09-19, rulings (commit ff99729)
Exemption requires the same subject_ref, type, and key, with no pre-dates
test. Rival test never skipped: refuse when an accepted unsuperseded row on
the tuple covers greatest(coalesce(effective_at, now()), now()).
Classification deviation adopted. Contract now says only agent:* callers
are policy-gated on promotion. Obligations 15 and 16 added, 11 rewritten.

### Builder schema, 2026-09-19, fix attempt 1 (commit 19f4b2d)
All three reproduced on 6115bca first, then fixed. Found on the way:
NEW.subject_ref is null in BEFORE triggers (stored generated column), so
both guards had silently matched nothing. Full flow passed.

### Verifier, 2026-09-19, second pass on 19f4b2d: FAIL
First-pass findings all fixed. New HIGH: a row with both subject columns
set skipped the demotion and the agent promotion gate. Pre-existing, out
of scope: after a cross-scope merge governing_scope() picks the lowest
scope uuid. Lead ruled from existing behavior (record_assertion() refuses
the shape): both guards refuse a two-subject row.

### Builder schema, 2026-09-19, fix attempt 2 (commit 21919b9)
Two-subject row refused first in both guards; both attacks reproduced on
19f4b2d first. Early-exit audit of 0025 listed with a reason each. Full
flow passed on port 54357.

### Verifier, 2026-09-19, third pass on 21919b9: FAIL
Two-subject fix holds, including on rows planted as owner. Early-exit list
complete. New HIGH: RLS-invisible replacement erases an accepted row (see
Verified). LOW: a comment cites a contract disclosure that does not exist.
Scope neutralisation by viewer fools record_assertion() equally, so not a
finding against 0025. Lead: stopped; see Hand-off.

### Architect, 2026-09-20 (commit 002044a)
Fail closed: at commit, a formerly accepted row's superseded_by must name a
replacement the caller can read with the same type and key; same for a
narrowed window's successor. The BEFORE decoy check still passes on an
absent row. No helper exception. One deliberate new refusal
(record_assertion classifying its replacement above the caller's level).

### Builder schema, 2026-09-20, fix attempt 3 (commit df43fa1)
Invisible-replacement attack committed on 21919b9 for all four callers, now
refused. RETURN NULL in the constraint trigger's first branch had skipped
later checks. Every SELECT in the triggers listed with which way blindness
cuts. Full flow passed on port 54359.

### Verifier, 2026-09-20, fourth pass on df43fa1: FAIL (MEDIUM, LOW)
See "Open ruling". SELECT inventory complete at eleven. Criteria 1, 3 to 8,
and 10 pass; 2 and 9 turn on the ruling.

## Close
status line and date
