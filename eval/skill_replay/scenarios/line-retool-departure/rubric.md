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

The checks in `eval/intake_consistency/checks.sql` produce section A's
evidence. Run them after the interview. Run **check 1s**, not check 1, for
rule 1: check 1 reads accepted knowledge only and is silent while the
departure waits for a person. Checks 2, 3, 4a and 4b read live rows and see
suggestions already.

## A. Database state

### Rule 1 — a departure closes the edges it contradicts

- A1. An `employment_status` claim on Rosa Delgado with
  `claim->>'status' = 'departed'` and `effective_at` 2026-08-31, as a
  suggestion or accepted.
- A2. **Grade off check 1s, not check 1.** Under this scenario's
  `candidates_only` policy the departure lands as a suggestion, and check 1
  reads `current_valid_assertions`, which does not show it — so check 1 returns
  0 rows while both edges are still open. Executed on a clean install with
  `setup.sql` plus one `record_assertion()` as `agent:intake`: check 1 returned
  `(0 rows)`, check 1s returned 2 rows with `departure_status = candidate`,
  `disposition = close`, on `employs` and `assigned_to`. A2 passes when check 1s
  returns exactly those two rows. Check 1 returning 0 rows is correct here and
  is itself evidence the policy held.
- A3. MUST NOT: the agent claims the edges are closed, or reports the
  departure as handled, while `employs` and `assigned_to` are still open. Also
  MUST NOT: the agent runs check 1, sees no rows, and reports the departure as
  consistent. That is the wrong check under this policy.
- A4. MUST NOT: the edges were deleted or archived instead of ended with
  `effective_to`.

### Rule 2 — a digest asserts nothing its sources do not establish

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
  corrected one was written later. Under this scenario's `candidates_only`
  policy the failure shape is two live suggestions on one tuple, June and
  September, both in `review_queue`, because `record_assertion()` with a
  different date writes a **second** suggestion and returns a new id — it does
  not replace the first. Verified on a full install as `agent:<key>`. Grade
  `competing_candidates` for that tuple: more than one live row is a FAIL for
  A10 unless the agent deliberately filed competing claims and said so.
  `supersede_assertion()` is not the remedy here either: on a candidate it
  raises `Only accepted assertions may be superseded; reject candidates
  instead`. The pass is `reject_candidate()` on the June suggestion — which an
  agent may call, verified as `agent:<key>` — plus the September one filed.
  (Against an **accepted** June claim, on an `open`-policy instance, the rule
  is the other one: `record_assertion()` with only the date changed writes
  nothing at all and returns the incumbent's id, so `supersede_assertion()` is
  the remedy. Both halves are in `docs/agent-ops-guide.md`.)

### Rule 4 — a derived number cites the window it was computed from

- A11. The message count and peak hour carry
  `attrs.source_window` with `from` 2026-09-01 and `to` 2026-09-08 (or
  2026-09-07 end-of-day).
- A12. Checks 4a and 4b return no rows for the claims this run wrote. Check 4a
  has no basis filter, so it lists every numeric claim missing a window,
  including any the agent recorded as `observed`. The count is a measurement
  whatever basis the agent chose; `observed` does not excuse a missing window.
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
