# Patchwork Pantry Graph Builder Report

Run date: 2026-06-22

Target database: `rye_eval_patchwork_catering`

## Purpose

This scenario tests a business with no existing CRM or PM system. Slack, email, the Lead Tracker spreadsheet, and the Event Workboard spreadsheet are evidence sources only. After Ana Rivera and Sofia Klein confirm the inferred records, Rye becomes the CRM/PM dashboard.

## Inputs Used

- `source_material.md`
- `candidate_facts.json`
- `sme_interview_adjudication.md`
- Rye CRM/PM schema helpers

`scenario_brief.md` was not used for intake or SME adjudication.

## Load Method

The clean graph-builder agent was stopped before writing or executing SQL. The executed loader is:

- `graph_builder_load.sql`

That loader uses Rye CRM/PM helpers where available:

- `create_opportunity`
- `create_task`
- `advance_deal_stage`
- `advance_task_status`
- `schedule_deal_stage_change`
- `schedule_milestone_status_change`
- `create_knowledge_candidate`
- `set_candidate_status`
- `record_source_of_truth_policy`

Projects and milestones are direct Rye nodes because the PM profile does not yet expose `create_project` or `create_milestone` helpers.

## Dashboard Records Created

### Sales

- Atlas Labs summer offsite catering
  - Owner: Sofia Klein
  - Contact: Priya Menon
  - Stage: proposal sent
  - Value: $18,600
  - Probability: 60%
  - Next action: send revised vegetarian station pricing by June 24, 2026
  - Scheduled change: contract review on June 26, 2026 if Priya approves the updated package

- Willow Creek School gala
  - Owner: Ana Rivera
  - Contact: Miguel Arroyo
  - Stage: qualification
  - Value: $32,000
  - Probability: 45%
  - Next action: complete River Hall site walk and confirm kitchen access on June 27, 2026
  - Scheduled change: proposal sent on June 30, 2026 if headcount and kitchen access are workable

- Baxter-Diaz late-night dessert bar
  - Owner: Sofia Klein
  - Contact: Jenna Baxter
  - Stage: needs scope
  - Value: $7,800
  - Probability: 30%
  - Next action: ask whether the request is dessert only or dessert plus coffee service by June 25, 2026

### Projects

- Atlas revised vegetarian station pricing: in progress, Marco Bell, due June 24, high priority
- Send Atlas revised pricing to Priya: to do, Sofia Klein, due June 24, high priority
- Atlas rentals confirmation: blocked, Nora Voss, due June 25, high priority
- Willow Creek site walk checklist: to do, Rae Chen, due June 27, medium priority
- Willow Creek staffing estimate: waiting on site walk, Ana Rivera, medium priority
- Clarify Baxter-Diaz dessert bar scope: to do, Sofia Klein, due June 25, medium priority

### Milestones

- Willow Creek River Hall site walk: planned, target June 27, 2026
- Atlas contract signed and deposit received: waiting customer, target June 28, 2026
- Willow Creek proposal decision: pending site walk, target June 30, 2026

## Candidate Outcomes

Accepted:

- Source materials are evidence until Ana or Sofia confirms them.
- Starting July 1, Rye should be checked first for opportunity status, next sales action, task status, and milestone status.
- Atlas, Willow, and Baxter-Diaz sales records.
- Atlas rentals is blocked, not done.

Rejected:

- Old Atlas value of $17,800.
- Old Atlas probability of 55%.
- Event Workboard `Done?` as proof that rentals are complete.

Needs review:

- Priya approval of the revised Atlas package.
- Crest response after revised tent dimensions.
- River Hall kitchen access and Willow final headcount.
- Jenna Baxter dessert-only versus coffee-service answer.

## Source-Of-Truth Result

Rye is now modeled as the source of truth for confirmed dashboard records:

- sales stage
- next sales action
- project task status
- project milestone status

The source policy still preserves the review gate:

- Slack, email, Lead Tracker, and Event Workboard are evidence.
- Ana or Sofia confirmation is required before imported records become official.
- Starting July 1, new status updates should be checked in Rye first.

## Verification

The loaded database shows:

- 3 active opportunities
- 6 active project tasks
- 3 active milestones
- 2 sales stage plans
- 1 milestone status plan
- 8 source-of-truth policy assertions
- 11 knowledge candidates with accepted, rejected, and needs-review outcomes

The CRM/PM surface routes:

- `/?instance=eval-patchwork-catering&view=sales`
- `/?instance=eval-patchwork-catering&view=projects`
- `/?instance=eval-patchwork-catering&view=systems`

## Remaining Gaps

- Rye should add first-class PM helper functions for projects and milestones.
- Candidate routing should use target payload IDs directly instead of relying on statement text to determine whether a candidate belongs to Sales or Projects.
- Pending customer/vendor answers need better action labels than `Ask for proof`; for this scenario, a better label would be `Keep waiting` or `Request update`.
- The Decisions page is improved, but still has some review-system language that should be replaced before exposing it to non-technical users.
