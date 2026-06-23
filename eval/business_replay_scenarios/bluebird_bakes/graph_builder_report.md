# Bluebird Bakes Graph Builder Report

Load target: configured local evaluation database (`rye_eval_bluebird_bakes`)

Loaded on: 2026-06-22

## Input Files Used

- `source_material.md`
- `candidate_facts.json`
- `sme_review.json`

I did not use `scenario_brief.md`.

## Loader

- Created `graph_builder_load.sql` in this scenario directory.
- Executed the loader with merged candidate + SME review JSON supplied through psql variable `merged`.
- Refreshed materialized views with `rye.refresh_materialized_views()`.

## Counts

- Bluebird scenario nodes: 87
- Edges involving Bluebird scenario nodes: 100
- Source accounts: 2
- Source containers: 3
- Source items: 16
- Source raw artifacts: 16
- Input packet artifact: 1
- Knowledge candidates: 25
- Candidate support edges: 41
- Candidate statuses: 16 accepted, 9 needs_review
- Opportunities visible in `rye.opportunities_active`: 2
- Bluebird task rows visible in `rye.task_board`: 14
- Future-effective assertions: 6
- Events involving Bluebird nodes: 111

## Business Records Created

- Scope: Bluebird Bakes Retail Launch and Sales Intake
- Opportunities:
  - GreenMart frozen pastry pilot
  - Lakeside Coffee seasonal croissant program
- Projects:
  - GreenMart frozen pastry pilot launch
  - Bluebird Bakes evidence review
- GreenMart launch tasks / milestone:
  - GreenMart allergen label approval
  - Omar Blake signoff on GreenMart revised allergen language
  - GreenMart case pack test
  - ColdLink first shipment booking
  - Final GreenMart case pack
  - GreenMart pilot ship date
- Evidence review tasks:
  - 9 tasks for CrumbCRM/KitchenBoard/approved sales-system evidence gaps
- Source systems:
  - CrumbCRM
  - KitchenBoard
  - LaunchPad

## Promoted SME-Approved Items

- `crumbcrm-sales-truth`: accepted source policy; CrumbCRM owns current sales stages and next sales actions.
- `kitchenboard-launch-truth`: accepted source policy; KitchenBoard owns launch task and milestone status until 2026-07-20.
- `launchpad-status-future-truth`: accepted future source policy; LaunchPad owns project task and milestone status starting 2026-07-20.
- `launchpad-not-sales-source`: accepted source policy; LaunchPad does not own sales stage or next sales action.
- `checklist-v2-new-launches-only`: accepted future checklist policy starting 2026-08-05 for new launches only; GreenMart excluded unless Elena approves.
- `qa-label-before-shipment`: accepted retailer launch procedure requiring QA label approval before first shipment.
- `retail-launch-checklist-items`: accepted current checklist requirement for QA label approval, case pack test, and first shipment booking.
- `almond-label-status-risk`: accepted process risk tying the almond label incident to scattered launch status.
- `greenmart-label-omar-dependency`: accepted `blocks` edge from Omar signoff to GreenMart allergen label approval.
- `greenmart-omar-approval-plan`: scheduled future task status for Omar signoff to become approved on 2026-07-10 if wording is acceptable.
- `greenmart-contract-review-plan`: scheduled GreenMart opportunity stage change to contract review on 2026-07-11 if Omar accepts revised language.
- `greenmart-case-pack-12`: accepted case-pack decision: 12 packs per case because freezer shelf height is tight.
- `greenmart-dock-appointment-dependency`: accepted dependency from ColdLink booking to final GreenMart case pack by 2026-07-15 for the week-of-2026-07-22 dock appointment.
- `greenmart-ship-approval-plan`: scheduled GreenMart pilot ship date milestone approval for 2026-07-22 if label approval and case pack pass, using LaunchPad per SME edit.
- `greenmart-launch-risk`: accepted launch risk listing open approval and logistics dependencies.
- `lakeside-proposal-plan`: scheduled Lakeside opportunity stage change to proposal sent on 2026-07-18 if Dana sends final pricing.

## Candidates Left Open

These remain `needs_review` candidates and have evidence-review tasks:

- `greenmart-opportunity-stage`: needs CrumbCRM current stage for GreenMart frozen pastry pilot.
- `greenmart-forecast`: needs approved sales-system forecast for GreenMart.
- `greenmart-allergen-label-task`: needs KitchenBoard task record for GreenMart allergen label approval.
- `greenmart-case-pack-task`: needs KitchenBoard task record for GreenMart case pack test.
- `greenmart-first-shipment-task`: needs KitchenBoard task record for ColdLink first shipment booking.
- `greenmart-ship-milestone`: needs KitchenBoard milestone record for GreenMart pilot ship date.
- `lakeside-opportunity-stage`: needs CrumbCRM current stage for Lakeside Coffee seasonal croissant program.
- `lakeside-forecast`: needs approved sales-system forecast for Lakeside Coffee.
- `lakeside-final-pricing-task`: needs CrumbCRM next sales action or task record for Lakeside final pricing.

## UI Gaps Noticed

- `opportunities_active` shows the opportunity rows, but pipeline/stage columns stay blank when current stage is intentionally withheld pending CrumbCRM evidence. The future `deal_stage_plan` assertions exist, but the CRM view does not surface plan metadata.
- `task_board` shows review tasks and GreenMart launch task anchors, but launch task anchors have blank status when KitchenBoard evidence is missing. That is correct for evidence policy, but the UI needs a clear "status pending authoritative source" display.
- Milestones are not represented in `task_board`, so the GreenMart pilot ship date and its scheduled future approval require graph/assertion views rather than a PM board row.
- Candidate rows retain source references and SME decisions, but the profile views do not expose candidate provenance or the accepted/open split without querying candidate assertions directly.
