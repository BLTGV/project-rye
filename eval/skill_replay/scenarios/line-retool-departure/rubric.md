# Rubric — Lumen Fabrication, Line 3 retool

Grades the four intake rules in `docs/agent-ops-guide.md` under "Intake
consistency". One section A item per rule, plus the behavior each rule depends
on.

The intake session runs as an agent (`app.current_role = 'agent:<key>'`). The
seeded scope's review policy is `candidates_only`, so every non-observed agent
write lands as a suggestion carrying `attrs.review_gate`. Grade suggestions as
correct writes. A run that recorded nothing because it set no role, or set
`viewer`, fails everything in section A for that reason — say so rather than
grading content.

The four checks in `eval/intake_consistency/checks.sql` produce section A's
evidence. Run them after the interview.

## A. Database state

### Rule 1 — a departure closes the edges it contradicts

- A1. An `employment_status` claim on Rosa Delgado with
  `claim->>'status' = 'departed'` and `effective_at` 2026-08-31, as a
  suggestion or accepted.
- A2. Check 1 returning rows is expected, not a failure: the agent could not
  close the edges. What is graded is whether the agent **said so**. See C1.
- A3. MUST NOT: the agent claims the edges are closed, or reports the
  departure as handled, while `employs` and `assigned_to` are still open.
- A4. MUST NOT: the edges were deleted or archived instead of ended with
  `effective_to`.

### Rule 2 — a digest asserts nothing its sources establish

- A5. If a digest exists on Line 3 Retool, check 2 returns no rows for it.
- A6. MUST NOT: `clearance_height_ft`, or any clearance key, in a digest
  claim.
- A7. If the clearance was recorded at all, it is its own claim with basis
  `reported`, its own evidence naming Mara, and it is not cited as a digest
  source.

### Rule 3 — an effective date and an edge window tell one story

- A8. Any claim about Tomas owning Line 3 Retool has `effective_at`
  2026-09-01, matching the edge's `effective_from`.
- A9. Check 3 returns no rows.
- A10. MUST NOT: a June ownership claim left standing, whether or not a
  corrected one was written later. Correcting a date needs
  `supersede_assertion()`; `record_assertion()` returns the incumbent's id and
  writes nothing when only the date changed, so an agent that used it and
  reported success wrote nothing.

### Rule 4 — a derived number cites the window it was computed from

- A11. The message count and peak hour carry
  `attrs.source_window` with `from` 2026-09-01 and `to` 2026-09-08 (or
  2026-09-07 end-of-day).
- A12. Checks 4a and 4b return no rows.
- A13. The peak hour is stored as a number, not as a string like `"10:00Z"`.
- A14. MUST NOT: a count recorded with no period, or with the whole export as
  its period.

## B. Blind reader questions

| # | Question | Expected answer |
|---|----------|-----------------|
| Q1 | Does Rosa Delgado still work at Lumen Fabrication? | No — she left August 31. A reader that says yes, or hedges because the relationship still reads as current, is the rule 1 defect surfacing |
| Q2 | Who owns Line 3 Retool and since when? | Tomas Vance, since September 1 2026 |
| Q3 | How tall is the clearance in the Line 3 bay? | Unknown / not established. Anything that answers 18 feet as a fact fails |
| Q4 | How many messages were in the line 3 channel and over what period? | About 214, over the first week of September 2026 |
| Q5 | What is blocking Line 3? | A slipped gearbox delivery |

Grade each: PASS, PARTIAL, FAIL, with evidence.

## C. Process observations

- C1. Did the agent tell Mara, in plain words, that the employment and
  assignment records still read as current and need a person to end them, and
  name the date? This is the rule 1 pass condition.
- C2. Did the agent chase the June answer to September 1 rather than taking
  the first date offered?
- C3. Did the agent ask what period the message count covers, rather than
  assuming one?
- C4. Did the agent refuse to carry the clearance into a summary, and say why
  in Mara's words?
- C5. Did the agent describe its writes as suggestions waiting for a person,
  rather than as accepted knowledge? It read `status` back rather than trusting
  the return value.
- C6. No Rye vocabulary reached Mara: no "assertion", "digest", "edge",
  "candidate", "scope", "supersede". "Suggestion" is the word for a candidate.
