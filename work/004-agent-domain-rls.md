# 004 agent-domain-rls

- status: open
- opened: 2026-09-19
- areas: schema, agent-kit, admin
- contracts: contracts/sql-surface.md

## Goal
The tables that say who holds authority over an area, which agents exist,
what each agent may do, and what each agent did are protected the same way
every other Rye table is. Today any session with direct SQL, including an
agent role, can read all of them and may be able to write them. After this
item, a session sees and changes only what its role allows, and the
functions and admin screens that depend on these tables keep working.

## Finding (verified 2026-09-19, Lead)
`schema/migrations/0016_agent_domain_security.sql` enables row-level security
only on `agent_api_tokens` (line 152). Eight tables created in the same file
have no RLS enabled or forced and no policies: `knowledge_domains`,
`domain_authorities`, `channel_domain_subscriptions`, `domain_claim_policies`,
`agent_identities`, `agent_capability_grants`, `agent_action_log`,
`api_idempotency_keys`. Migrations 0017 to 0021 and `scripts/verify.sh` add
nothing for them. This contradicts the schema invariant in `docs/areas.md`
("RLS is enabled and forced on all core and supporting tables") and the
Security Model section of `AGENTS.md`. `agent_api_tokens` itself is enabled
but the Lead did not confirm it is forced.

Facts the Lead checked that shape the design:
- `ensure_knowledge_domain`, `subscribe_channel_to_domain`,
  `grant_domain_authority`, `create_agent_identity`, and
  `grant_agent_capability` (0016 lines 164 to 408) are SECURITY INVOKER and
  contain no role check. Any session can call them today. They are not
  SECURITY DEFINER, contrary to the task as handed to the Lead.
- `issue_agent_token_record`, `issue_agent_token`, `record_agent_action`,
  `authenticate_agent_token`, `revoke_agent_token`, `has_agent_capability`,
  `authorize_agent_action`, `agent_get_context_pack`,
  `agent_submit_observation`, `agent_create_candidate` are SECURITY DEFINER.
  Under FORCE, a definer function owned by a non-superuser (Supabase
  `postgres`) is still subject to policies evaluated with the caller's
  session variables.
- `rye_settlers()` (0021, work/002) is SECURITY INVOKER and reads
  `knowledge_domains`, `domain_authorities`, and `agent_identities`. It uses
  `agent_identities` to drop agents from the settler list; if a caller
  cannot see that table, that filter fails open.
- Direct table readers outside SQL functions: `scripts/rye` (around lines
  1274 to 1373) and `admin/src/server/queries.ts` (around lines 227 to 298,
  run with `app.current_role = 'admin'` through `withAdminCte`).
  `tests/conformance/20_agent_domain_security.sql` and the three
  `eval/agent_domain_replay/*/graph_load.sql` files also touch these tables.

## Acceptance criteria
- [ ] Each of the eight tables has row-level security enabled and forced, and `agent_api_tokens` is forced as well. `scripts/verify.sh` fails if any of the nine is not.
- [ ] A session with no role set reads zero rows from each of the eight tables and cannot insert, update, or delete in any of them.
- [ ] An admin session can read and write all of them.
- [ ] A non-admin, non-agent session can read what the contract says it may and nothing else, and cannot write directly.
- [ ] An agent session with direct SQL reads only what the contract says it may, cannot read another agent's capability grants or action log rows, and cannot insert, update, or delete in any of the eight tables.
- [ ] An agent or other non-admin session cannot give itself or anyone else authority, an identity, or a capability by calling `grant_domain_authority`, `create_agent_identity`, `grant_agent_capability`, `ensure_knowledge_domain`, or `subscribe_channel_to_domain`.
- [ ] `agent_get_context_pack`, `has_agent_capability`, `authorize_agent_action`, `authenticate_agent_token`, `record_agent_action`, `agent_submit_observation`, and `agent_create_candidate` return the same results as before for a valid agent, when the function owner is not a superuser.
- [ ] `rye_settlers()` returns the same answers as before for every case in its work/002 conformance test, for each role the contract lets call it, and never returns an agent identity as a settler under any role.
- [ ] The admin Worker's domain, authority, subscription, and action-log queries return the same rows as before under `app.current_role = 'admin'`.
- [ ] The `./scripts/rye` agents commands (`list`, `create`, `grant`, `issue-token`, `revoke-token`, `audit` in both output forms) work as before. Today all but `list` run with no role set and would read nothing or be refused once RLS is forced; each sets the admin role in the same statement. `tests/conformance/23_cli_agent_security.sh` passes.
- [ ] (agent-kit) `tests/conformance/22_secure_mcp_simulation.sh` and the three `eval/agent_domain_replay/*/graph_load.sql` loads, which call the write helpers with no role set today, set the admin role for their setup and pass as before. Nothing else about them changes.
- [ ] No policy reads its own table, directly or through a function, and the order in which one table's policy may read another is the one the contract states. Every rule holds with no `infinite recursion` or stack depth error for each of the four session shapes.
- [ ] Tests under `tests/security/` cover each criterion above. The full schema test command passes.

## Constraints
- A new numbered migration. `0016` and every other applied migration are not edited. Functions that need changing are replaced from the new migration with the same signatures.
- Policies use session variables only. Never `current_user`, never `pg_has_role()`.
- Every function declares its own `SET search_path`.
- SQL and bash only.
- Must hold when the table owner is not a superuser (Supabase). A test run as a superuser proves nothing about RLS; the security tests must run as a role RLS applies to.
- Do not change the shape of any of the nine tables.
- Builders start only after the Architect has written the rules into `contracts/sql-surface.md`.
- Do not push.

## Decided by the human
- 2026-09-19, Casey: fix by a new migration that enables and forces RLS with session-variable policies; update `scripts/verify.sh`; add tests under `tests/security/`.
- 2026-09-19, Casey: the Architect states the per-table read and write rules in `contracts/sql-surface.md` before the builder starts.
- 2026-09-19, Casey: the new policies must not break `rye_settlers()` from work/002.

## Assumed by default
- Admin may read and write all eight tables. Offered by Casey as an assumption. Overturn: Architect.
- Non-agent roles may read `knowledge_domains`, `domain_authorities`, and `domain_claim_policies`. Offered by Casey. Overturn: Architect.
- Agent roles read only rows for domains they hold a grant on. Offered by Casey. Overturn: Architect. The Lead flags a conflict: `rye_settlers()` is SECURITY INVOKER, so under this rule an agent asking who may settle a claim in an area it holds no grant on gets `domain_not_found`, and an agent that cannot read `agent_identities` cannot filter agents out of the answer. The Architect resolves this.
- Writes happen only through helper functions. Offered by Casey on the premise that the helpers are SECURITY DEFINER; five are not (see Finding). Whether they become admin-gated definer functions or stay invoker and are limited by admin-only write policies is the Architect's call. Overturn: Architect.
- `agent_action_log` is append-only for everyone, admin included, matching how events are treated. Overturn: Architect.
- `api_idempotency_keys` is read and written only through definer functions and by admin. Overturn: Architect.
- How an agent session is tied to an agent identity for row filtering (for example `app.current_role = 'agent:<key>'` or `app.current_user_id`) follows whatever the existing agent policies in 0004 and 0006 use. Overturn: Architect.
- The agent-kit change is limited to setting the admin role in setup code it owns; found by the Architect, 2026-09-19. Overturn: Lead.
- ~~No admin area work is needed because the Worker runs as admin.~~ Overturned by the Lead 2026-09-19: the Verifier showed `withAdminCte()` sets the role in a CTE the planner may never run before the RLS filter, so the Worker's area and action-log queries return nothing under a non-superuser owner. The admin area is opened for that fix only. The same shape at about twenty older call sites on core tables predates this item; if the central fix does not cover them they become a separate item.

## Verified
- filled in at close

## Reports

## Close
