# Bluebird Bakes Iteration 2 Report

Target database: configured local evaluation database (`rye_eval_bluebird_bakes`)

Run date: 2026-06-22

## Evidence Used

- `source_material.md`
- `candidate_facts.json`
- `sme_review.json`
- `official_system_snapshot.md`
- Rye schema/profile docs and the live Rye database schema

`scenario_brief.md` was not used.

## What Changed

- Added official source provenance for the 2026-06-22 CrumbCRM and KitchenBoard exports:
  - `Official System Snapshot 2026-06-22 CrumbCRM Export`
  - `Official System Snapshot 2026-06-22 KitchenBoard Export`
- Attached those official source items to the previously unconfirmed candidates.
- Promoted all 9 previously `needs_review` official-system facts to accepted knowledge:
  - GreenMart stage and forecast
  - Lakeside stage and forecast
  - Lakeside next sales action
  - GreenMart allergen label task
  - GreenMart case pack task
  - GreenMart first shipment booking task
  - GreenMart pilot ship date milestone
- Updated current CRM opportunity facts from CrumbCRM:
  - GreenMart: `proposal_sent`, `$128000`, `0.70`, owner Tina Alvarez, contact Omar Blake.
  - Lakeside: `qualification`, `$52000`, `0.35`, owner Tina Alvarez, contact Sophie Grant.
- Updated current PM launch facts from KitchenBoard:
  - GreenMart allergen label approval: `in_review`, Priya Shah, due 2026-07-09, high.
  - GreenMart case pack test: `in_progress`, Marcus Reed, due 2026-07-12, high.
  - ColdLink first shipment booking: `todo`, Caleb Moore, due 2026-07-15, medium.
  - GreenMart pilot ship date: `waiting_customer`, Jules Kim, target 2026-07-24, high.
- Closed and archived 9 evidence-review tasks so they no longer appear in PM task surfaces.
- Moved non-official dependency context anchors out of `node_type='task'`, leaving the PM task board with only the 3 official KitchenBoard delivery tasks.
- Refreshed Rye materialized views.

## Source Policies

- Current sales stage and next sales action: CrumbCRM, effective 2026-06-22.
- Current launch task and milestone status: KitchenBoard, effective 2026-06-22 through 2026-07-20.
- Future project task and milestone status: LaunchPad, effective 2026-07-20.
- Checklist v2 remains future-only for new retailer launches, effective 2026-08-05; GreenMart is excluded unless Elena Rossi approves.

## Verification

- `rye.opportunities_active`: 2 rows.
- `rye.task_board`: 3 GreenMart delivery task rows, 0 evidence-review rows.
- Active Bluebird milestone nodes: 1.
- Archived Bluebird evidence-review tasks: 9.
- Previously blocked official-system candidates now accepted: 9 of 9.

## Remaining Gaps

- `next_sales_action` is accepted in graph assertions and copied to opportunity node properties, but the stock `opportunities_active` materialized view does not expose a next-action column.
- Omar approval on 2026-07-10 remains a conditional future plan, not a current KitchenBoard delivery task.
