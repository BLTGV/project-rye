# 0007 Configuration writes need an admin

Date: 2026-09-19. Work item: `work/005-registry-write-gate.md`.
Contract: `contracts/sql-surface.md`, section "Configuration writes need an
admin". Areas: schema, agent-kit.

## The gap

Registry entries are accepted `registry_entry` assertions. Nothing checked who
wrote them. Under review policy `open`, which is also the answer on a fresh
install with no scope and no policy row, a caller under
`app.current_role = 'agent:x'`, `viewer`, or `team_member` wrote an accepted
alias and an accepted `self_settled_type` entry on the Rye Core Registry node,
and the answer to who may settle an expectation on a person changed for every
role, admin included. Ordinary conversation content must not be able to change
policy. That is what this closes.

## The gate is a row, not code

`assertion_type_access` already gates assertion types by role for `read` and
`write`, is readable by every role, and is writable only by `admin`. Neither
existing operation says what is needed. `write` refuses the insert outright,
which throws away what the person said, and the item's default is that nothing
said is lost. So the table gains a third `operation` value, `settle`, meaning
"only these roles may make this type accepted". Two rows are seeded,
`registry_entry` and `review_policy`, both `ARRAY['admin']`. Gating a further
type later is an `INSERT`.

Rejected: a new `configuration_types` table. It would carry one column of
information that an existing table already models, and the item says no new
table unless nothing existing can express it. Rejected: naming the set in SQL
inside the trigger, which makes every later addition a migration. Rejected:
reusing `write` with `ARRAY['admin']`, which refuses and discards.

## Demote on the documented path, refuse on every other

`record_assertion()` already demotes an accepted write to `candidate` when the
governing scope's review policy says so. The gate goes in the same place, a few
lines earlier than the supersession block, and for the same reason: the status
has to be settled before anything supersedes an incumbent. A non-admin's
registry write therefore becomes a candidate that an admin can accept from
`review_queue`, marked with `attrs.settle_gate`.

Every other route to an accepted row raises instead: a direct `INSERT`, any
`UPDATE` that moves the row to `accepted` (which covers `accept_assertion()`
and also covers a caller who sets `app.write_path` by hand, since the RLS
update policy trusts that variable and the immutability trigger does not guard
`status`), `supersede_assertion()`, and `record_distillation()`. Demotion would
be wrong on those last two: both mark or displace the incumbent first, so a
silent demotion would leave the key with no accepted value and let a non-admin
erase an alias by proposing one. A refusal there loses nothing, because the
same statement recorded through `record_assertion()` becomes a suggestion.

The check lives in one trigger on `assertions`, not in each helper. Rejected:
an explicit admin check inside `accept_assertion()`, `supersede_assertion()`,
`schedule_assertion_change()`, and the rest. Both `accept_assertion()` and
`reject_candidate()` are `SECURITY DEFINER`, the list of helpers grows, and a
per-helper check leaves the direct `INSERT` and the raw `UPDATE` open. A
trigger fires inside a `SECURITY DEFINER` function and on a raw write alike,
and it reads `app.current_role`, which `SECURITY DEFINER` does not change. It
is one place and cannot be bypassed.

The trigger matches the stored spelling of `assertion_type` with no alias
resolution. That is not a shortcut: `registry_value()` and `governing_scope()`
match the stored literal too, so a row written under another spelling is not
read as configuration in the first place. `record_assertion()` canonicalizes
before inserting, so an alias of a gated type is gated. Rejected: resolving the
type in the trigger, which would add a registry read to every assertion insert
and could raise on an alias cycle in an unrelated write.

## How wide the gate is

`registry_entry` and `review_policy` only. `scope_status` is deliberately left
out: demoting it leaves the scope inactive, `governing_scope()` then does not
select it, its review policy stops applying, and the result is looser than
today. Plugin enablement is left out because the thing that is read is the
`scope_enables_plugin` edge, not the `plugin_policy_binding` assertion, so an
assertion gate there would be theatre. The remaining scope policy types shape
what agents are told rather than what Rye computes, and they separately escape
the review policy because `governing_scope()` returns null for a scope node's
own policy assertions; that leak is its own item and is untouched here.
`domain_authorities` grants are table rows, not assertions, and their RLS is
`work/004`.

## What the tests must show

One suite, `tests/conformance/30_configuration_gate.sql`. `conformance.sh`
globs the directory, so no registration, and it runs the file under the
non-superuser `rye_conformance` role by `SET ROLE` when the connection is
superuser. Every case below sets `app.current_role` explicitly.

1. `record_assertion('registry_entry', ..., p_status := 'accepted')` on the core
   registry node under `agent:t`, `viewer`, `team_member`, and with the role
   unset, lands `candidate` with `attrs->'settle_gate'->>'pending'` true. Run
   the agent case under review policy `open`, `candidates_only`, `strict`, and
   with no policy recorded.
2. A direct `INSERT INTO assertions` of an accepted `registry_entry` raises,
   under the same roles.
3. `accept_assertion()` on a registry candidate raises under the same roles,
   and so does a raw `UPDATE ... SET status = 'accepted'` by a caller that sets
   `app.write_path` and `app.accept_assertion_id` itself.
4. An agent holding `rye.authoritative.promote` for the scope still cannot
   accept a registry candidate.
5. `supersede_assertion()` on an accepted registry entry under a non-admin
   raises, and afterwards the incumbent is still `accepted` with
   `superseded_at` null.
6. `schedule_assertion_change()` under a non-admin on a registry key lands
   `candidate` and never becomes effective.
7. `record_scope_policy(scope, 'review_policy', ...)` under a non-admin on a
   scope whose accepted policy is `strict` lands `candidate`, and
   `scope_review_policy(scope)` still returns `strict`.
8. Admin still works: record an accepted registry entry, and accept a
   non-admin's candidate, after which `registry_value()` returns it.
9. `registry_value('basis_prior:observed', NULL)` is `0.95`, proving the gate
   did not demote the install seeds.
10. The settlement answer is unchanged. With a subject who reports to a
    manager, read `rye_settlers(subject, 'expectation', subject, ...,
    'self_commitment')` as admin and assert it names the manager and
    `is_settler` false. Run the agent's alias and `self_settled_type` writes.
    Read again as admin, agent, and viewer and assert the same answer.
11. Anti-vacuity: then have an admin accept those same candidates and assert
    the answer does change. A suite that cannot show the change would not have
    caught the gap.

## Cost

An unset `app.current_role` is not an admin, so a future migration or script
that seeds configuration must set the role first, as `sync_plugin_metadata.sh`
already does. Every registry and scope policy write in the existing tests,
scripts, and CLI already runs as `admin`, so nothing in the repository changes
behaviour. An area owner who is not a Rye admin cannot declare a self-settled
type without asking one. That is the item's stated default and Casey can
overturn it.
