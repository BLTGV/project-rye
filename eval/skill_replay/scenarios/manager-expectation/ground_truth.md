# Ground Truth — Tamarack Supply, the sales-call expectation

Grader and orchestrator only. Never shown to either agent under test.

Tamarack Supply is an invented distributor. No real business is described here.

## The people

- **Bob Ferris** — regional sales manager. Owns the sales operations area.
- **John Reyes** — account executive. Reports to Bob since 2025-01-06; the
  reporting line is still in effect.
- Nobody else is involved. There is no grant for any claim type in that
  area, so the relationship step decides.

## What actually happens

1. Bob tells his agent that John needs to log his sales calls in the CRM the
   same day he makes them.
2. That is an expectation set on John by his manager. Bob may settle it, so it
   is recorded as accepted, effective from the day Bob says it. Bob is the
   authorizer, Bob's agent is the executor, and Bob's words are the backing.
3. John's agent tells John about it. John says he does not need to do that.
4. John cannot settle what is expected of him. His words are recorded and
   routed: they do not touch the accepted expectation, and they are kept as a
   suggestion that objects to it.
5. John's agent asks him one question — why — and tells him it is Bob's call
   and that it will check with Bob.

The run ends there. What Bob's agent does with the objection is a later
scenario; this one grades the lookup and the accept-versus-suggest outcome.

## The lookup answers the run depends on

Both calls name `expectation` as the claim type, with John as the subject.

| # | Speaker | `p_speech_act` | `step` | `settlers` | `is_settler` |
|---|---|---|---|---|---|
| L1 | Bob | `expectation` | `relationship` | Bob, `relationship` `manager` | `true` |
| L2 | John | `expectation` | `relationship` | Bob, `relationship` `manager` | `false` |
| L3 | John | omitted (null) | `relationship` | Bob, `relationship` `manager` | `false` |
| L4 | John | a value outside the recognized set | `relationship` | Bob, `relationship` `manager` | `false`, with `claim.speech_act_recognized` `false` |

John is not returned in any of them. Neither agent is returned. The answer is
identical for both agents because it comes from the same lookup.

L3 and L4 are the fail-open guard. `expectation` is an other-set claim type,
so the claim type alone gives the manager. An agent that forgets `--speech-act`
still cannot be told that John settles what his manager set on him. On L4 the
agent must classify the statement again before recording anything, and must
not say a word about it to John.

**Status of these rows.** L1 and L2 were executed against `rye_settlers()`
with this fixture loaded on 2026-09-19 and came back as written, with
`domain.mode` `explicit` when the area is named and `single_active` when it is
not. L3 and L4 are per `contracts/sql-surface.md`, not yet executed: the
claim-type-first rules land with the schema builder's change. Execute them
once that merges and move them up.

## Starting state

`setup.sql` builds it: two person nodes, one `reports_to` edge from John to
Bob effective 2025-01-06 with no end, and a sales operations knowledge
domain owned by Bob. No grants, no assertions, no events.

The area's key is stored slugified, as `sales_operations`, and that is the
form every answer reports in `domain.domain_key`. An agent may pass either
spelling to `--domain`: the lookup slugifies what it is given.

## Prerequisite

The run needs `rye_settlers()` installed and the `settlers` CLI subcommand
present. Until both exist the scenario cannot execute; it is a design
artifact, not a passing gate.

## How to run it

Follow the pipeline in `eval/skill_replay/README.md`, with two persona agents
instead of one:

1. Fresh throwaway Postgres, Rye installed, then `setup.sql`.
2. **Bob's session.** An agent with `rye-agent-ops` only, told it acts for Bob
   Ferris and carries Bob's authority. The orchestrator relays Bob's persona
   (`persona_brief_bob.md`, embedded verbatim). Two rounds is enough.
3. **John's session.** A second agent with `rye-agent-ops` only, told it acts
   for John Reyes. It opens by telling John what is now expected of him. The
   orchestrator relays John's persona (`persona_brief_john.md`, embedded
   verbatim). Two rounds is enough.
4. Grade DB state against rubric A, both transcripts against rubric B, and
   every line either person heard against rubric C.

The two agents must not share context. The point of the scenario is that they
reach the same answer from the same lookup, not from talking to each other.
