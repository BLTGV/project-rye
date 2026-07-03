# Rubric — Meridian Fence Co.

## A. Database state (graded against DB after intake)

### Must capture

- M1. An onboarding scope exists and is active, with a purpose about quote
  follow-up / stale leads — NOT named after the interview or a data source.
- M2. Dana Whitfield exists as a person, associated with Meridian Fence Co.
  as owner.
- M3. Priya exists as an identifiable person whose follow-up/quoting
  responsibility is recorded (full name if the interviewer asked for it).
- M4. All four customers exist: Hartwell HOA, Larkspur Elementary (or the
  school district), Kestrel Brewing, Redtail Ranch.
- M5. Hartwell quote recorded: ~$84,000, sent June 10 2026, with the amount
  marked uncertain/needs-verification (NOT recorded as a confident bare fact).
- M6. The July 15 2026 HOA board decision is captured as a future-dated
  fact, scheduled event, or task — something a "what's coming up" query finds.
- M7. The August 1 2026 prevailing-wage certification expiry is captured the
  same way, connected to the Larkspur/school-district opportunity.
- M8. Open task: send written quote to Kestrel Brewing (~$9k patio fence).
- M9. Open task or fact: follow up with Redtail Ranch (gate automation
  blocked on delayed part, promised this week).
- M10. Larkspur quote recorded: $22,500, sent June 20 2026.

### Should capture

- S1. Rob Casillas as the Hartwell HOA contact (treasurer).
- S2. IF crew leads surfaced in the interview, they exist as identifiable
  people. Not required otherwise — they are legitimately outside the quote
  follow-up scope and the persona does not volunteer them.
- S3. Payroll and crew scheduling recorded as out of scope.
- S4. Some review policy recorded for the scope before facts were promoted.
- S5. The interviewer asked for full names and/or contact details at least
  once (graded from transcript).

### Must NOT happen

- N1. No facts promoted to accepted knowledge before a scope + review policy
  existed.
- N2. No invented facts — nothing in the DB that has no basis in the
  interview (spot-check quote amounts, dates, names).
- N3. The Hartwell amount must not appear as a single confident value with
  the uncertainty silently dropped.
- N4. The scope must not be named "interview", "chat", or after a tool.
- N5. If the scope was revised mid-interview, ALL scope-defining records
  (scope node properties, scope_boundary assertion, expected_contexts
  policy) must agree — no record may still carry the pre-revision wording
  while another carries the new one.

## B. Blind reader questions (asked with no scenario context)

| # | Question | Expected answer |
|---|----------|-----------------|
| Q1 | What decision is expected on July 15 and what's at stake? | Hartwell HOA board votes on the ~$84k perimeter-fence quote |
| Q2 | What deadline is coming up around August 1 and why does it matter? | Prevailing-wage cert expires; without renewal Meridian can't take the Larkspur/school-district job |
| Q3 | Which customer still needs a written quote, for what work, roughly how much? | Kestrel Brewing, patio privacy fence, ~$9k |
| Q4 | Who handles quote follow-ups at Meridian Fence? | Priya Shah |
| Q5 | Which customer is waiting on a delayed part, and what was promised? | Redtail Ranch, gate automation; follow-up call this week |
| Q6 | What is the purpose of the active onboarding scope? | Quote follow-up / keeping leads from going stale |
| Q7 | How confident should we be in the Hartwell quote amount? | Uncertain — Dana said $84k or maybe $86k; Priya has the exact figure |

Grade each: PASS (correct + attributes provenance sensibly), PARTIAL
(directionally right, missing a key element), FAIL (wrong, missing, or
hallucinated).

## C. Process observations (from transcript)

- Did the intake agent establish the scope before ingesting facts?
- Did it ask for review policy in plain language?
- Did it batch questions reasonably (not 40 one-liners, not one giant dump)?
- Did it chase the "early June" vagueness to a concrete date?
- Did it handle Rye-jargon leakage (persona should have flagged any)?
