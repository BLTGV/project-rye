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

## What the fixture does not cover

The fixture's review policy is `open`, so every write lands accepted and the
checks have accepted rows to find. Under `candidates_only` or `strict` the same
agent writes land as suggestions carrying `attrs.review_gate`, and the checks
would find nothing until a person accepts them. That is the correct behavior
and a different scenario.
