# Patchwork Pantry Catering Scenario Brief

This file is the evaluator brief. Do not give it to intake or graph-builder agents.

## Business

Patchwork Pantry Catering is a 12-person catering and event services company in Asheville, North Carolina. The company handles corporate lunches, nonprofit galas, weddings, and small institutional events.

The company has no CRM and no PM tool. Work is tracked through email, Slack, a lead tracker spreadsheet, an event workboard spreadsheet, and informal owner memory. Rye is being tested as the first CRM/PM dashboard and the eventual system of record.

## Goals

- Stop losing sales follow-ups between email, Slack, and the lead tracker.
- Give the owner a single view of active opportunities and event work.
- Keep customer commitments, menu work, rentals, and staffing visible together.
- Let agents infer candidate business records from communication and spreadsheets.
- Require SME confirmation before inferred records become authoritative.
- Preserve future operating changes without confusing them with current truth.

## People

- Ana Rivera: owner and general manager.
- Sofia Klein: sales and event coordinator.
- Marco Bell: chef and menu lead.
- Nora Voss: operations and rentals coordinator.
- Eli Grant: staffing lead.
- Theo Marsh: finance and deposits.
- Rae Chen: part-time event captain.
- Priya Menon: Atlas Labs workplace experience manager, customer contact.
- Miguel Arroyo: Willow Creek School gala chair, customer contact.
- Jenna Baxter: Baxter-Diaz wedding customer contact.
- Omar Diaz: Baxter-Diaz wedding customer contact.
- Lena Park: Crest Rentals account manager.
- DeShawn Price: River Hall venue manager.

## Current Opportunities

- Atlas Labs summer offsite catering.
  - Owner: Sofia Klein.
  - Customer contact: Priya Menon.
  - Current stage after SME confirmation: proposal_sent.
  - Value: 18600.
  - Win probability: 0.60.
  - Next action: send revised vegetarian station pricing by 2026-06-24.
  - Future planned stage: contract_review on 2026-06-26 if Priya approves the revised vegetarian station pricing.

- Willow Creek School gala.
  - Owner: Ana Rivera.
  - Customer contact: Miguel Arroyo.
  - Current stage after SME confirmation: qualification.
  - Value: 32000.
  - Win probability: 0.45.
  - Next action: complete River Hall site walk and confirm kitchen access on 2026-06-27.
  - Future planned stage: proposal_sent on 2026-06-30 if headcount and kitchen access are confirmed.

- Baxter-Diaz late-night dessert bar.
  - Owner: Sofia Klein.
  - Customer contact: Jenna Baxter.
  - Current stage after SME confirmation: needs_scope.
  - Value: 7800.
  - Win probability: 0.30.
  - Next action: ask Jenna whether they want dessert only or dessert plus coffee service by 2026-06-25.

## Current Project Work

- Atlas revised vegetarian station pricing.
  - Project/opportunity: Atlas Labs summer offsite catering.
  - Owner: Marco Bell.
  - Status after SME confirmation: in_progress.
  - Due: 2026-06-24.
  - Priority: high.

- Atlas rentals confirmation.
  - Project/opportunity: Atlas Labs summer offsite catering.
  - Owner: Nora Voss.
  - Status after SME confirmation: blocked.
  - Due: 2026-06-25.
  - Priority: high.
  - Blocker: Crest Rentals still needs revised tent dimensions before confirming lounge furniture.

- Willow Creek site walk checklist.
  - Project/opportunity: Willow Creek School gala.
  - Owner: Rae Chen.
  - Status after SME confirmation: todo.
  - Due: 2026-06-27.
  - Priority: medium.

- Atlas contract signed milestone.
  - Current status after SME confirmation: waiting_customer.
  - Target date: 2026-06-28.
  - Future planned status: approved on 2026-06-28 if Priya signs the revised package and Theo receives the deposit.

## Process And Source-Of-Truth History

- 2026-04-14: A museum luncheon follow-up was missed because the owner thought the spreadsheet row had been updated and sales thought the email reply was enough.
- 2026-05-08: Patchwork started using Slack channel `#event-desk` for daily work triage.
- 2026-05-20: Lead Tracker became the shared spreadsheet for opportunity rows, but nobody trusts it as complete.
- 2026-06-03: Event Workboard became a shared spreadsheet for event tasks, but it is sometimes stale.
- 2026-06-22: Rye pilot starts. Existing spreadsheets and communications are evidence, not authoritative truth by themselves. A human SME must confirm inferred records before they become official in Rye.
- 2026-07-01: Rye becomes the primary dashboard for opportunity status, next sales action, project task status, and milestone status. Spreadsheets may still be used for estimating and imports, but not as the status source of record after accepted migration.

## Expected UI Outcome

The CRM/PM surface should say, in plain business language:

- Rye is acting as the CRM/PM dashboard for Patchwork Pantry because there is no external CRM/PM.
- Sales should show active opportunities, owners, contacts, current stage, next action, value/probability, and scheduled stage changes.
- Projects should show event work items, owners, current status, due date, blockers, and scheduled milestone/task changes.
- Systems should explain that communications/spreadsheets were source evidence and Rye becomes the accepted dashboard after SME confirmation.
- Future July 1 operating policy should not imply that old spreadsheet rows are authoritative today.
