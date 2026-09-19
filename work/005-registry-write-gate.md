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

## Close
