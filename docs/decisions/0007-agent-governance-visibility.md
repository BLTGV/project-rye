# 0007 — The governance tables are read by role, written by admin

Date: 2026-09-19. Status: accepted. Decided by: Architect, for work item 004.

**The role list is the role list, so a session is admin, a named role, an
agent, or unknown.** Every rule in the new contract section keys off
`app.current_role`, with "named role" defined as a value that matches a
`role_classification_access.role_name` row rather than a list spelled into each
policy. That table is already the instance's role vocabulary and is already
readable by every session for `redact_properties()`, so adding a role stays an
insert rather than a migration, which is the project's convention-over-schema
rule applied to authorization. It also gives the human's acceptance criterion a
crisp meaning: a session with no role set matches nothing and reads nothing,
and so does a session that invents a role name. The rejected alternative was
`current_setting('app.current_role', true) IS NOT NULL` — anything with a role
set may read the area tables. It was declined because an unset variable and a
typo would then differ, and because the instance would have no list of who its
roles are while its policies depended on there being one.

**An agent reads the whole agent roster, and that is what keeps "agents settle
nothing" fail-closed.** `agent_identities` is readable by admin, by every named
role, and by every session whose `app.current_role` has the `agent:<key>` form,
which makes its read set a strict superset of
the read set of `knowledge_domains` and `domain_authorities`. That superset is
the whole argument: the ref half of `rye_settler_is_agent()` only ever matters
for a settler whose ref came from a governance table, and any caller that can
see such a row can also see the roster that filters it out. The rejected
alternatives were a narrow `SECURITY DEFINER` helper for the agent check and
making `rye_settlers()` itself `DEFINER`. Both were declined for the same
reason, which is the central fact of this item: under `FORCE ROW LEVEL
SECURITY` with an owner that is not a superuser, a definer function is still
subject to every policy, evaluated with the caller's session variables, so
`DEFINER` buys no visibility at all and would only have moved the failure
somewhere harder to see. Restricting agents to their own identity row was
declined too — it hides other agents from the deny-list, which is precisely the
fail-open case. The honest cost is that the roster is not secret; it holds a
key, a label, and a runtime, while the tokens and the capabilities stay
admin-only.

**Which agent you are is asked one level down, because the roster's own policy
cannot ask it.** Added 2026-09-19, after the Lead found the self-reference. The
first version of this record defined an agent session as one naming an *active*
identity, which puts a read of `agent_identities` inside `agent_identities`' own
policy. That is not implementable. Verified on PostgreSQL 16 with a
non-superuser owner and `FORCE ROW LEVEL SECURITY`: a policy that subqueries its
own table raises `infinite recursion detected in policy for relation`, and a
policy that calls a function reading its own table recurses to `stack depth
limit exceeded` — `SECURITY DEFINER` included, which is the paragraph above seen
from the other side. The session shape therefore splits. **Agent-shaped** is the
`agent:<key>` form, decided from the session variable alone, and it governs
exactly one rule: reading the roster. **Bound agent** resolves that key to an
active identity and governs everything else. The tables are ordered
`role_classification_access` → `agent_identities` → the four agent tables → the
four area tables, and a policy may read only levels strictly below its own, so
the chain area → grants → identities → roles terminates. The rejected
alternative was to keep the active-identity check on the roster and move the
resolution into a second session variable such as `app.current_agent_id`, set by
the trusted layer. It was declined because it adds another thing every caller
must set correctly for RLS to be right, and a caller that sets it wrong reads
another agent's grants, which is the one failure this item exists to prevent.
The accepted cost is that a session can call itself `agent:` anything and read
the secret-free roster. It gains nothing else — every other rule needs a real
identity row — and the criterion that a session with no role set reads zero rows
from all nine tables still holds.

**One session variable says which agent you are, and it is
`app.current_role`.** Added 2026-09-19, after the Verifier found conformance
test 26 failing. `agent_can_promote_in_scope()` resolved the acting agent from
`app.current_user_id` first, while the new grants policy binds own rows from
`app.current_role`, and test 26 sets the two to different agents — role
`agent:test`, label `governance_agent` — so the grants went invisible and the
promotion gate closed. The function is replaced from the new migration with the
same signature and resolves through `rye_current_agent_id()` only, and the test
is corrected to name one agent in both places. The rejected alternative was to
widen the binding so a session is whichever agent either variable names. It is
implementable — `agent_key = rye_slugify_key(current_setting('app.current_user_id'))`
reads no table, so the level-1 policy stays row-local and the order stays
acyclic — and it is not obviously worse in the direct-SQL threat model, where a
session can set either variable freely. It was declined because it makes one
session two agents at once and leaves which one wins depending on which function
you call, which is the bug in the first place, and because it turns a label into
a credential: `app.current_user_id` is free text that helpers copy into events,
`created_by`, and audit payloads, and a trusted layer that sets the role from a
verified token while copying a caller-supplied actor string into the label would
hand out another agent's grants. The narrowing closes a real escape hatch: the
promotion gate already fires on `app.current_role LIKE 'agent:%'` alone, so
before this a session could declare itself `agent:anything` to trip the gate and
then name a capable agent in the label to pass it. Every other function that
touches the governance tables takes the agent as an explicit argument, so the
correction is one function and one test.

**The five write helpers stay `SECURITY INVOKER` and admin-only write policies
do the enforcing.** `ensure_knowledge_domain`, `subscribe_channel_to_domain`,
`grant_domain_authority`, `create_agent_identity`, and `grant_agent_capability`
keep their bodies and their signatures; what stops a non-admin calling them is
the same policy that stops a non-admin writing the table directly. The rejected
alternative was to replace all five as `SECURITY DEFINER` with an explicit
`app.current_role = 'admin'` check in the body, which reads more helpfully
because it can raise a sentence instead of an RLS violation. It was declined
because the policies are needed anyway for the direct-SQL path, so the check in
the body would be a second copy of the same rule in a second place, free to
drift; because a definer function under FORCE is policy-checked regardless, so
the marking would suggest a bypass that does not exist; and because a definer
helper that writes on a non-admin's behalf is exactly the escalation the item
exists to close. The cost is an unfriendly refusal, so the contract states the
refusal shapes instead: insert raises `42501`, update and delete affect zero
rows and raise nothing.

**The two writes a non-admin legitimately causes use the existing named gate,
and the action log is append-only for admin too.** `record_agent_action()` and
the idempotency insert inside `agent_create_candidate()` open
`app.write_path` around their own statement, the same mechanism
`supersede_assertion` and `update_node_properties` already use, rather than a
new session variable or a new role. The log insert is admitted from any session
so that a denial is recorded even when the caller was impersonating another
agent: an audit trail that the audited action can suppress is not one. No
session updates or deletes `agent_action_log`, admin included, matching `events`
and `assertion_evidence`; an admin able to edit it could erase the record of its
own grants, and the one thing the table exists for is to be unforgeable after
the fact. `api_idempotency_keys` is treated the other way, as a cache with an
expiry that admin may delete from, and agents read their own rows there because
`agent_create_candidate()` that cannot see its own prior response quietly
creates a second candidate instead of returning the first. The rejected
alternative for both was admin-and-definer-functions-only, as the work item
assumed. It was declined because under FORCE there is no such thing as
"definer-only", so the rule has to be written as something a policy can
actually express.
