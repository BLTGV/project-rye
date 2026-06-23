# Rye Business Replay Evaluation Report

Date: 2026-06-22

This report documents the latest top-down / bottom-up Rye evaluation pass. The purpose was to test whether fresh agents can take realistic business source material, extract candidate business knowledge, confirm it with a simulated SME, write it into Rye, and have the CRM/PM surface show the result in plain business language.

## What Was Tested

Two separate fictional small-business scenarios were built from the top down, then replayed bottom up by clean agents.

### Scenario 1: Cedar Ridge HVAC

Cedar Ridge HVAC & Controls is an 18-person commercial HVAC contractor. The scenario tests sales follow-up, permit-sensitive delivery work, supplier dependencies, customer coordination, and future source-system transitions.

Key business questions Rye should answer:

- What sales opportunities are active today?
- Who owns each customer follow-up?
- What is the current stage, next action, value, and probability?
- Which project tasks are active, blocked, or scheduled?
- Which system should be trusted for sales and project status today?
- Which future process/system changes are scheduled but not yet current?

Important temporal behavior:

- HearthCRM is current truth for sales stages and next sales actions as of June 22, 2026.
- JobBoardPM is current truth for project task and milestone status as of June 22, 2026.
- BuildBoard becomes official for crew scheduling on July 15, 2026, but not for task or milestone status.
- PipelinePro becomes official for sales stages and next sales actions on August 1, 2026.
- Future sales and project changes must not overwrite current truth before their effective dates.

Artifacts:

- Hidden evaluator brief: `cedar_hvac/scenario_brief.md`
- Agent-visible source packet: `cedar_hvac/source_material.md`
- Official second-pass system snapshot: `cedar_hvac/official_system_snapshot.md`
- Intake output: `cedar_hvac/candidate_facts.json`
- SME review output: `cedar_hvac/sme_review.json`
- Clean SME interview output: `cedar_hvac/sme_interview_adjudication.md`
- Graph-builder report: `cedar_hvac/graph_builder_report.md`
- Iteration 2 report: `cedar_hvac/iteration_2_report.md`

### Scenario 2: Bluebird Bakes

Bluebird Bakes is a 24-person wholesale bakery. The scenario tests sales pipeline, retailer launch process, QA approval, production/fulfillment dependencies, customer approval, and future process/system changes.

Key business questions Rye should answer:

- Which retailer opportunities are active today?
- What is each opportunity's current sales status, next action, value, and probability?
- Which launch tasks must happen before first shipment?
- What quality and logistics dependencies affect the GreenMart pilot?
- Which systems are authoritative today?
- What future checklist and system changes are planned but not current?

Important temporal behavior:

- CrumbCRM is current truth for sales stage and next sales action as of June 22, 2026.
- KitchenBoard is current truth for launch task and milestone status as of June 22, 2026.
- LaunchPad becomes current truth for project task and milestone status on July 20, 2026.
- Retailer onboarding checklist v2 starts on August 5, 2026 for new retailer launches only.
- GreenMart remains on the current checklist unless Elena Rossi approves conversion.

Artifacts:

- Hidden evaluator brief: `bluebird_bakes/scenario_brief.md`
- Agent-visible source packet: `bluebird_bakes/source_material.md`
- Official second-pass system snapshot: `bluebird_bakes/official_system_snapshot.md`
- Intake output: `bluebird_bakes/candidate_facts.json`
- SME review output: `bluebird_bakes/sme_review.json`
- Clean SME interview output: `bluebird_bakes/sme_interview_adjudication.md`
- Graph-builder SQL: `bluebird_bakes/graph_builder_load.sql`
- Graph-builder report: `bluebird_bakes/graph_builder_report.md`
- Iteration 2 report: `bluebird_bakes/iteration_2_report.md`

## Agent Replay Process

The scenarios were not handed to the intake or graph-builder agents. Those agents only received source material and candidate/review files.

1. Constructed each business scenario top down.
2. Created source material that looked like normal business work: Slack-style coordination, email-style customer/vendor messages, CRM exports, PM exports, and process notes.
3. Ran fresh intake agents with no parent context to extract candidate facts.
4. Ran fresh SME/review agents to adjudicate candidate facts from only the source packet and candidates.
5. Opened clean SME-interview agents and answered their questions as the business SME.
6. Ran graph-builder agents to create Rye graph records from the source, candidates, and SME decisions.
7. Added official system snapshots for a second pass where the official CRM/PM exports resolved source-verification gaps.
8. Reviewed the live database and CRM/PM surface.
9. Improved the API and CRM/PM surface so business users see business records, not Rye scaffolding.

## What Failed In Iteration 1

The first graph-build pass stored a lot of useful knowledge, but the surface exposed several wrong things for a business user.

- Evidence-review tasks appeared on the PM board as if they were project delivery work.
- Sales and project pages leaned on Rye/internal concepts instead of business language.
- Source-of-truth policies existed in the graph, but were hard to understand from the UI.
- Current facts and future facts were both stored, but the UI did not make "true today" versus "scheduled later" clear enough.
- Some official system facts were left pending because the first source packet did not include official CRM/PM snapshots.
- The stock `opportunities_active` view did not expose next sales action, even when the graph had accepted that fact.

## Improvements Made

### Data and Rye Graph

- Added official CRM/PM system snapshots for both scenarios.
- Promoted official-system facts after the second pass.
- Closed evidence-verification candidates that had been resolved.
- Archived source-verification tasks so they no longer appear as delivery tasks.
- Added source-of-truth policy assertions with effective dates and review gates.
- Added plugin-native future schedule assertions for task, milestone, and sales-stage changes.
- Preserved future facts separately from current facts so scheduled changes do not overwrite current truth.

### Admin API

- Filtered PM workspace tasks so evidence-review and source-verification work does not leak into the project board.
- Added CRM workspace support for accepted `next_sales_action` assertions so sales pages show the practical next follow-up.
- Added both scenario databases as selectable instances in the local admin/dev configuration.

### CRM/PM Surface

- Added instance selection by URL, so each scenario can be reviewed directly.
- Reworked Sales and Projects into a business-list plus selected-detail layout.
- Removed repeated "No open decisions" table columns when there are no decisions.
- Added plain-language detail panels for owners, customer contacts, next actions, values, probability, project context, upcoming official changes, and follow-up gaps.
- Added a Systems tab that explains where information comes from today and which systems are scheduled to take over later.
- Kept future source changes visible without letting them change current Sales or Projects truth.

## Current Verification

Databases:

- `rye_eval_cedar_hvac`
- `rye_eval_bluebird_bakes`

Local API:

- configured through the admin API environment (`RYE_ADMIN_API_PORT` or `?api=...`)

CRM/PM surface routes:

- Cedar Sales: `/?instance=eval-cedar-hvac&view=sales`
- Cedar Projects: `/?instance=eval-cedar-hvac&view=projects`
- Bluebird Sales: `/?instance=eval-bluebird-bakes&view=sales`
- Bluebird Projects: `/?instance=eval-bluebird-bakes&view=projects`
- Bluebird Systems: `/?instance=eval-bluebird-bakes&view=systems`

Checks run:

- `node --check surfaces/crm-pm/app.js`
- `npm run typecheck` in `admin`
- API workspace checks for both CRM and PM endpoints across both scenarios
- Tailnet HTTP check returned 200
- Headless screenshots captured for Cedar Sales, Cedar Projects, Bluebird Sales, Bluebird Projects, and Bluebird Systems

Current surface result:

- Cedar Sales shows two current opportunities, current status, next scheduled sales change, owner/contact, next action, value, and probability.
- Cedar Projects shows the three delivery tasks plus the permit-release milestone, with future task/milestone changes separated as upcoming official changes.
- Bluebird Sales shows GreenMart and Lakeside with current CrumbCRM facts and future stage plans.
- Bluebird Projects shows the three current KitchenBoard launch tasks and the GreenMart ship-date milestone without evidence-review tasks.
- Bluebird Systems shows KitchenBoard as current and LaunchPad as scheduled for July 20, 2026.

## Clean SME Interview Findings

The clean SME-interview agents asked business-facing questions rather than schema questions.

Cedar example:

- The agent asked whether the target should be Friday, June 26, 2026 or Saturday, June 27, 2026.
- The SME answer accepted the date June 27, 2026 and rejected the conflicting weekday text.
- This is a realistic adjudication case: keep the authoritative value, do not discard the whole fact because a source included a bad label.

Bluebird example:

- The agent asked whether current retailer launches require QA label approval, case pack test, and first shipment booking.
- The SME confirmed the process, its reason, and which systems are authoritative today versus later.
- The graph can now represent both "this is how launches work now" and "this is why the process exists."

## Remaining Gaps

These are no longer blocking the scenario demo, but they are important for Rye core.

- `opportunities_active` still does not natively expose next sales action; the API joins accepted assertions to fill the gap.
- Source-of-truth policy creation should have a first-class helper so agents do not hand-roll subtly different source-policy claims.
- Future assertions should have a consistent plugin contract: subject, planned value, effective date, condition, current/future classification, and source authority.
- CRM and PM plugins should schedule future work through those helper APIs rather than generic graph assertions.
- The CRM/PM surface should eventually include an evidence drawer so a user can see the source excerpts behind a fact without leaving the page.
- The review page still needs a deeper redesign before business users should rely on it. The current pass focused on Sales, Projects, Systems, and scenario replay.
- A repeatable test harness should automate clean-agent intake, SME question capture, graph loading, database inspection, and screenshot comparison.

## Recommendation

Rye should treat candidate knowledge as the normal intake state. Agents should infer candidate business knowledge from connected systems, then ask humans to confirm contradictions, missing context, source authority, and future-effective changes. That matches how people actually work: humans are better at correcting and contradicting a draft than constructing complete business documentation from scratch.

The core pattern should be universal:

1. Observe source-system activity.
2. Extract candidate business facts in plain language.
3. Attach evidence and source authority.
4. Ask targeted SME questions only where needed.
5. Promote accepted facts into current or future-effective assertions.
6. Show business surfaces from accepted knowledge, not raw agent notes.
7. Keep old, future, and superseded assertions available without confusing them with what is true today.
