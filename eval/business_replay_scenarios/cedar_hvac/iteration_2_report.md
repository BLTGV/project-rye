# Cedar HVAC Iteration 2 Report

## Inputs Used

- `source_material.md`
- `candidate_facts.json`
- `sme_review.json`
- `official_system_snapshot.md`

No scenario brief was used.

## What Changed

Recorded `official_system_snapshot.md` as a source-of-truth confirmation source for the second intake and applied its HearthCRM and JobBoardPM exports as accepted official knowledge.

### HearthCRM Opportunity Updates

- Fulton Dental rooftop unit replacement:
  - Stage: `proposal_sent`
  - Owner: Alex Chen
  - Customer contact: Nora Ellis
  - Next action: wait for Dominion rebate letter; move to contract review if received before 2026-07-03
  - Estimated value: `84000`
  - Win probability: `0.65`

- Riverbend Brewery controls upgrade:
  - Stage: `qualification`
  - Owner: Maya Patel
  - Customer contact: Marcus Hill
  - Next action: complete brewhouse walkthrough after tank cleaning
  - Estimated value: `46500`
  - Win probability: `0.40`

### JobBoardPM Task And Milestone Updates

- Fulton permit resubmission:
  - Status: `blocked`
  - Due date: `2026-06-27`
  - Priority: `high`
  - Owner: Jordan Reed
  - Notes: waiting for signed structural letter from CityPermit Expedite

- Order Fulton curb adapter:
  - Status: `in_progress`
  - Due date: `2026-06-28`
  - Priority: `high`
  - Owner: Sam Brooks
  - Notes: NorthAir ship confirmation expected by 2026-06-30

- Create Fulton after-hours access plan:
  - Status: `todo`
  - Due date: `2026-07-01`
  - Priority: `medium`
  - Owner: Priya Nair
  - Notes: needs Nora to confirm Saturday entry and alarm instructions

- Fulton permit release milestone:
  - Status: `waiting_city`
  - Target date: `2026-07-02`
  - Priority: `high`
  - Owner: Jordan Reed
  - Approval condition: mark approved if the city releases the revised permit

### Future Plans Kept Distinct

Existing future plans remain non-current:

- Fulton contract review on 2026-07-03, conditional on the Dominion rebate letter.
- Riverbend site survey completion on 2026-07-08, conditional on the brewhouse walkthrough.
- BuildBoard crew scheduling source cutover on 2026-07-15.
- PipelinePro sales stage and next-action cutover on 2026-08-01.

New future plans added:

- Fulton curb adapter `ready_for_install` on 2026-06-30, conditional on NorthAir ship confirmation.
- Fulton permit release `approved` on 2026-07-02, conditional on city release of the revised permit.

### Verification Task Cleanup

The six source-verification tasks for facts now confirmed by the official snapshot were closed and archived from business PM surfaces. Related open-decision edges and verification candidate statuses were resolved against `official_system_snapshot.md`.

## Verification

Materialized views refreshed:

- `rye.opportunities_active`
- `rye.task_board`
- `rye.contacts_directory`

Post-refresh checks:

- CRM workspace shows 2 Cedar opportunities.
- PM task board shows 3 Cedar delivery tasks.
- PM task board shows 0 visible Cedar source-verification tasks.
- Fulton permit release has current milestone status `waiting_city`.
- Cedar graph contains 6 active future-plan records.

## Remaining Gaps

- NorthAir ship confirmation has not been recorded as received, so `ready_for_install` remains a future conditional plan.
- City release of the revised permit has not been recorded, so permit `approved` remains a future conditional plan.
- Fulton contract review and Riverbend site survey completed remain future conditional plans, not current stages.
