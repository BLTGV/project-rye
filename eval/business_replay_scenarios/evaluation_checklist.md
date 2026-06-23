# Business Replay Evaluation Checklist

Use this checklist after each clean graph-builder run.

## Intake Integrity

- Intake agents only saw source material, not the scenario brief.
- SME agents only saw source material plus candidate facts.
- Graph-builder agents only saw source material, candidate facts, SME review, and Rye docs/schema as needed.
- Hidden scenario briefs are used only for evaluator comparison.

## Database Checks

- Source account/container/item nodes exist for Slack and email evidence.
- Knowledge candidates exist for intake findings.
- SME-confirmed or edited items were promoted.
- Needs-more-evidence items remain proposed or needs_review, not accepted as official truth.
- Current source-of-truth policies distinguish current truth from future truth.
- Future plans appear as plans or future-effective assertions without changing current status.
- CRM/PM materialized views are refreshed.

## Surface Checks

- Sales tab shows opportunities with plain customer names, owner, customer contact, current stage, value/probability where available, next planned change, and open decisions.
- Projects tab shows tasks and milestones with plain names, owners, due/target dates, current status, next planned change, and open decisions.
- Decisions tab explains what the user is deciding in business language.
- Upcoming tab separates scheduled changes from current truth.
- Systems tab explains which business system is current and which future changes are scheduled.

## Regression Checks

- A legacy evaluation instance still renders when configured.
- URL instance selection works with `?instance=eval-cedar-hvac` and `?instance=eval-bluebird-bakes`.
- Mobile shows the list before the detail pane.
