# Cedar Ridge HVAC & Controls Graph Builder Report

Run date: 2026-06-22
Target database: `rye_eval_cedar_hvac`
Operational inputs used: `source_material.md`, `candidate_facts.json`, `sme_review.json`

I did not read `scenario_brief.md` or prior conversation context.

## Load Summary

Loaded SME-reviewed Cedar Ridge HVAC & Controls operational knowledge into Rye with source provenance, accepted policies, CRM/PM business records, future plans, and open verification decisions.

Materialized views were refreshed after loading.

## Counts

Scenario nodes with `properties->>'scenario' = 'cedar_hvac'`: 105

| Node type | Count |
|---|---:|
| knowledge_candidate | 24 |
| source_item | 21 |
| person | 13 |
| task | 9 |
| org | 7 |
| source_account | 7 |
| deliverable | 6 |
| source_policy | 5 |
| future_plan | 4 |
| source_container | 3 |
| opportunity | 2 |
| milestone | 1 |
| onboarding_scope | 1 |
| pipeline | 1 |
| project | 1 |

Provenance and activity:

| Record class | Count |
|---|---:|
| source accounts | 7 |
| source containers | 3 |
| source items | 21 |
| source excerpt artifacts | 18 |
| Cedar events | 78 |
| graph edges | 170 |

Materialized profile views after refresh:

| View | Cedar rows |
|---|---:|
| `opportunities_active` | 2 |
| `task_board` | 9 |

## Promoted Items

Accepted source policies:

- JobBoardPM is the current official source for project task status and milestone status as of 2026-06-22. Slack and email are evidence only.
- HearthCRM is the current official source for deal stage and next sales action as of 2026-06-22.
- BuildBoard becomes authoritative for crew scheduling on 2026-07-15, excluding project task status and milestone status.
- PipelinePro becomes authoritative for deal stage and next sales action on 2026-08-01, replacing HearthCRM for those answers.
- Permit-sensitive clinic, brewery, and restaurant rooftop work needs an explicit permit milestone before any firm install window.

Accepted CRM records:

- Fulton Dental rooftop unit replacement opportunity, evidence stage `proposal sent`, value `$84,000`, win probability `65%`.
- Riverbend Brewery controls upgrade opportunity, evidence stage `qualification`, value `$46,500`, win probability `40%`.
- Fulton conditional stage plan: move to `contract review` on 2026-07-03 if the Dominion rebate letter arrives before then.
- Riverbend conditional stage plan: move to `site survey completed` on 2026-07-08 if the brewhouse walkthrough happens after tank cleaning.

Accepted PM/work records:

- Fulton Dental rooftop unit replacement project.
- Fulton permit resubmission task owned by Jordan Reed, with 2026-06-27 retained as the stated target date and a note that the source weekday label is wrong.
- Fulton curb adapter order task owned by Sam Brooks, with NorthAir ship confirmation expected by 2026-06-30.
- Fulton after-hours access plan task owned by Priya Nair, due 2026-07-01.
- Fulton permit release milestone targeted for 2026-07-02, with approval only if the revised permit is released.

Accepted dependencies and rationale:

- Southside dental emergency chiller loss retained as the lesson-learned rationale for the permit milestone policy.
- Fulton signed structural engineer letter depends on the final roof curb cut sheet; missing it risks a city permit hold.
- Riverbend proposal readiness is blocked by in-person controls cabinet inspection.

## Candidates Left Open

18 SME-reviewed candidates are accepted.

6 verification candidates remain `needs_review` because the official systems were not in the allowed source packet:

- Verify Fulton official stage and next sales action in HearthCRM.
- Verify Riverbend official stage and next sales action in HearthCRM.
- Verify Fulton permit resubmission status in JobBoardPM.
- Verify Fulton curb adapter order status in JobBoardPM.
- Verify Fulton after-hours access plan status in JobBoardPM.
- Verify Fulton permit release milestone status in JobBoardPM.

Each open verification candidate has a corresponding task in `task_board`.

## UI Gaps Noticed

- `opportunities_active` shows the evidence stage, value, and probability, but does not surface `official_stage_unverified` or `evidence_only`; a CRM board could make evidence look more official than it is.
- `task_board` shows the three Fulton work tasks as `needs_review`, but that is a graph review state, not official JobBoardPM status. The UI needs a clearer distinction between evidence status and official status.
- The Fulton permit release is a `milestone`, so it does not appear in `task_board`; the PM workspace needs a milestone-focused view.
- Source policies, future source cutovers, and conditional future plans are represented in the graph but do not have a dedicated plain-business workspace view.
- Candidate provenance is linked through `supported_by` edges to source items, but the CRM/PM profile views do not expose those source references inline.
