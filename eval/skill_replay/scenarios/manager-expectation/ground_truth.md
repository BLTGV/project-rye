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

| # | Speaker | `p_speech_act` | `step` | `settlers` | `is_settler` | `speech_act_recognized` |
|---|---|---|---|---|---|---|
| L1 | Bob | `expectation` | `relationship` | Bob, `relationship` `manager` | `true` | `true` |
| L2 | John | `expectation` | `relationship` | Bob, `relationship` `manager` | `false` | `true` |
| L3 | John | omitted (null) | `relationship` | Bob, `relationship` `manager` | `false` | `false` |
| L4 | John | `banana`, outside the recognized set | `relationship` | Bob, `relationship` `manager` | `false` | `false` |
| L5 | John, claim type mislabelled `requirement` with no alias registered | `self_commitment` | `area_owner` | Bob, `via` `area_owner`, `relationship` null | `false` | `true` |

John is not returned in any of them. Neither agent is returned. The answer is
identical for both agents because it comes from the same lookup.

L3 and L4 are the guard against failing open. `expectation` is an other-set
claim type, so the claim type alone gives the manager. An agent that forgets
`--speech-act` still cannot be told that John settles what his manager set on
him. On both rows `speech_act_recognized` comes back `false`, so the agent
must classify the statement again before recording anything, and must not say
a word about it to John.

L5 is the third variant. John's agent mislabels the claim as `requirement`, a
type nobody has declared self-settled and for which no alias is registered,
and pairs it with `self_commitment`. A speech act never makes a person their
own settler on its own: the claim type has to be positively in the self set,
and `requirement` is not. So the lookup skips the relationship step entirely
and answers with the owner of the area. John is still not a settler, and his
agent still records a suggestion and says it will check.

**Bob is the area owner in this fixture, so L5 returns the same person as L1
to L4.** The settler's name does not distinguish them. Two fields do: on L5
`step` is `area_owner` and the settler's `via` is `area_owner` with
`relationship` null; on L1 to L4 `step` is `relationship` and `via` is
`relationship` with `relationship` `manager`. A grader reading only the name
cannot tell the two paths apart. Read `step` and `via`.

**Status of these rows.** L1 to L4 executed 2026-09-19 on a full install at
716692f, with this fixture loaded, through
`./scripts/rye --json settlers --claim expectation --subject <John> --domain
sales-operations`. Every value came back as written. `domain.mode` is
`explicit` when the area is named and `single_active` when it is not. L5 is
per `contracts/sql-surface.md`, not yet executed; the self-set rule lands with
the schema builder's change.

## Starting state

`setup.sql` builds it: two person nodes, one `reports_to` edge from John to
Bob effective 2025-01-06 with no end, and a sales operations knowledge
domain owned by Bob. No grants, no assertions, no events.

The area's key is stored slugified, as `sales_operations`, and that is the
form every answer reports in `domain.domain_key`. An agent may pass either
spelling to `--domain`: the lookup slugifies what it is given.

## Prerequisite

`rye_settlers()` and the `settlers` CLI subcommand both exist, and the lookup
answers above are executed fact. What is still missing is a runner for
`eval/skill_replay`: nothing drives the two agent sessions and grades the
transcripts. Until that exists the end-to-end scenario is a design artifact,
not a passing gate.

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
