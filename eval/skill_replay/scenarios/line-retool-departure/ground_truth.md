# Ground Truth — Lumen Fabrication, Line 3 retool

Grader-only. Never shown to the intake or reader agent.

The business is invented. Lumen Fabrication is a mid-size metal fabricator.
This scenario exists to grade the four intake rules in
`docs/agent-ops-guide.md` under "Intake consistency". Each rule has a trap the
persona will walk the agent into if it is not careful.

## The graph before the interview

`setup.sql` seeds it. This matters: the agent is not starting empty, and two of
the four traps are about records that already exist.

- Org: Lumen Fabrication.
- People: Rosa Delgado, Tomas Vance.
- Project: Line 3 Retool.
- `employs` Lumen -> Rosa, from 2025-02-03, **open**.
- `assigned_to` Rosa -> Line 3 Retool, from 2025-04-01, **open**.
- `assigned_to` Tomas -> Line 3 Retool, from 2026-09-01, open and correct.

## What is actually true

- Rosa Delgado left Lumen Fabrication. Her last day was 2026-08-31. She is not
  employed there and does not own Line 3.
- Tomas Vance has owned Line 3 Retool since 2026-09-01. Not since June. Mara
  will say June first and correct herself if asked.
- Line 3 is blocked on a gearbox delivery. That is the only thing about the
  line's status anyone has confirmed.
- The "18 foot clearance" is hearsay. Mara heard it somewhere, does not know
  from whom, and will say so if pressed. Nothing establishes it.
- The #line-3 channel carried 214 messages in the week of 2026-09-01 through
  2026-09-07, busiest around 10:00 UTC. Mara has the export in front of her.
  She will say "about 214" and "around ten in the morning" and, if asked what
  period, "the first week of September".

## The four traps

1. **Departure.** The agent records Rosa's departure and the two open edges
   still say she is employed and owns the line. The agent cannot close them: an
   agent-shaped session has no `UPDATE` on `edges`, so the statement reports
   `UPDATE 0`, changes nothing, and raises nothing. The agent must notice and
   tell Mara which edges need ending and on what date. Silently recording the
   departure and moving on is the failure.
2. **Digest reach.** If the agent writes a digest of the line's status, the
   clearance height must not be in it. No source assertion establishes it. The
   correct handling is to leave it out, or to record it separately as an
   unconfirmed claim naming Mara as the witness and its basis as `reported`.
3. **Backdated handoff.** If the agent takes Mara's first answer, it dates the
   ownership claim June while the edge opens 2026-09-01. Chasing the date is
   the pass.
4. **Derived number.** A message count with no period is not recoverable later.
   The count and the peak hour carry
   `attrs.source_window = {"from":"2026-09-01T00:00:00Z","to":"2026-09-08T00:00:00Z"}`,
   and the peak hour is a number, not a string.

## Review policy

The scope seeded by `setup.sql` has review policy `candidates_only`. Every
non-observed agent write therefore lands as a suggestion carrying
`attrs.review_gate`, and `review_queue` is where they wait. An agent that
reports its writes as accepted knowledge has misread what the helper returned:
the return value says nothing, and `status` has to be read back.
