# 007 assertion-lifecycle-gate

- status: open
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
- Item number 007 and migration 0025, because another session holds work/004 with 0022 and work/006 with 0024. Overturn: Lead.
- The four other forged paths found during reproduction (window, outcome attrs, classification, and the supersede id) are in scope, since they are the same defect. Overturn: Casey.
- Admin keeps the ability it has today. Whether an admin may do by raw UPDATE what a helper does is the Architect's call. Overturn: Architect.
- Viewer and no-role callers being able to insert assertions at all is reported, and fixed here only if the Architect finds it is the same mechanism. Overturn: Architect.
- No agent-kit change: the skill already tells agents to use the helpers. If the Architect changes a helper's signature or a caller-visible message, agent-kit is added. Overturn: Architect.

## Verified
- filled in at close

## Reports
Paste each role's report here as it arrives.

## Close
status line and date
