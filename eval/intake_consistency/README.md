# Intake Consistency Fixture

A fixture that breaks each of the four intake rules once, and the four reads
that find them. The rules are stated in `docs/agent-ops-guide.md` under "Intake
consistency"; the checks are documented, with what each one cannot decide, in
`skills/rye-pattern-library/references/intake-consistency-checks.md`.

The business is invented: Lumen Fabrication retools a production line, Rosa
Delgado leaves, Tomas Vance picks the line up.

## Files

- `fixture_violations.sql` — loads the graph with one violation of each rule.
- `checks.sql` — the four checks, executable. Same text as the reference file.
- `fixture_fixed.sql` — repairs all four. Its four blocks are the four examples
  in the guide's intake section.

## Running it

Against any install, as a non-superuser role with the grants
`scripts/conformance.sh` gives `rye_conformance`:

```bash
export DATABASE_URL=postgresql://...
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f eval/intake_consistency/fixture_violations.sql
psql "$DATABASE_URL" -f eval/intake_consistency/checks.sql   # four findings
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f eval/intake_consistency/fixture_fixed.sql
psql "$DATABASE_URL" -f eval/intake_consistency/checks.sql   # no rows
```

Load it into a throwaway database. It writes nodes, edges, events and
assertions that no other test expects.

Verified 2026-09-20 on a bare `postgres:15` install with profiles `crm,pm`,
under `SET ROLE rye_conformance`: four findings before, none after.

## What the fixture plants

Eight findings across five checks before repair, none after:

- rule 1: four open edges on a departed person — `employs`, `assigned_to`,
  `pipeline_member` (a plugin type, not a core one), and `owns`, which is a
  handoff rather than a close.
- rule 2: two digest claim keys no source establishes.
- rule 3: one claim dated June about an edge that opens in September.
- rule 4: a digest with no window, an inferred estimate whose window excludes
  its own source, and an `observed` message count with no window — the last of
  which an earlier basis-filtered draft of check 4a missed entirely.

It also plants one row that is **never** flagged, on purpose: a claim dated
2020 on an edge whose `effective_from` and `effective_to` are both NULL. That
is check 3's stated blind spot, and the fixture demonstrates it rather than
hiding it.

## What the fixture does not cover

The fixture's review policy is `open`, so every write lands accepted. Under
`candidates_only` or `strict` the same agent writes land as suggestions
carrying `attrs.review_gate`, and the checks do not all behave alike:

- **Check 1 goes quiet.** It reads `current_valid_assertions`, which does not
  show a pending suggestion, so the departure disappears from it while the
  edges stay open. **Check 1s** is the variant to run then: it reads live rows
  with `status IN ('accepted','candidate')` and reports which it found.
- **Checks 2, 3, 4a and 4b are unaffected.** They filter on
  `superseded_at IS NULL` and read suggestions already, so a pending suggestion
  that breaks one of those rules is reported whatever the policy is.

`eval/skill_replay/scenarios/line-retool-departure` runs the
`candidates_only` case end to end.
