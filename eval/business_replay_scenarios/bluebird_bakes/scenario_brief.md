# Bluebird Bakes Scenario Brief

This file is the evaluator brief. Do not give it to intake or graph-builder agents.

## Business

Bluebird Bakes is a 24-person wholesale bakery in Columbus, Ohio. It sells frozen pastries and private-label baked goods to cafes, grocers, and local institutions.

## Goals

- Make retailer onboarding repeatable.
- Prevent allergen-labeling mistakes.
- Keep sales, quality, production, and fulfillment aligned during launches.
- Track future process changes without confusing them with current truth.

## People

- Elena Rossi: founder and general manager.
- Tina Alvarez: wholesale sales manager.
- Jules Kim: launch project manager.
- Marcus Reed: production lead.
- Priya Shah: quality and food safety lead.
- Caleb Moore: fulfillment coordinator.
- Dana Wu: finance and pricing.
- Omar Blake: GreenMart category buyer, customer contact.
- Sophie Grant: Lakeside Coffee operations director, customer contact.
- Mira Patel: LabelWorks packaging designer.
- Wyatt Ford: ColdLink 3PL account manager.

## Current Opportunities

- GreenMart frozen pastry pilot.
  - Owner: Tina Alvarez.
  - Primary contact: Omar Blake.
  - Current stage: proposal_sent.
  - Value: 128000.
  - Win probability: 0.70.
  - Future planned stage: contract_review on 2026-07-11 after GreenMart accepts the revised allergen language.
- Lakeside Coffee seasonal croissant program.
  - Owner: Tina Alvarez.
  - Primary contact: Sophie Grant.
  - Current stage: qualification.
  - Value: 52000.
  - Win probability: 0.35.
  - Future planned stage: proposal_sent on 2026-07-18 after Dana sends final pricing.

## Current Project Work

- GreenMart allergen label approval.
  - Project: GreenMart frozen pastry launch.
  - Owner: Priya Shah.
  - Status: in_review.
  - Due: 2026-07-09.
  - Priority: high.
  - Future planned status: approved on 2026-07-10 after Omar signs off.
- GreenMart case pack test.
  - Owner: Marcus Reed.
  - Status: in_progress.
  - Due: 2026-07-12.
  - Priority: high.
- ColdLink first shipment booking.
  - Owner: Caleb Moore.
  - Status: todo.
  - Due: 2026-07-15.
  - Priority: medium.
- GreenMart pilot ship date milestone.
  - Current status: waiting_customer.
  - Target date: 2026-07-24.
  - Future planned status: approved on 2026-07-22 if label approval and case pack test both pass.

## Process And Source-Of-Truth History

- 2026-04-09: Bluebird shipped a cafe order with an outdated almond label proof. The fix was to add explicit label approval before retailer launch.
- 2026-05-02: Retail launches must include a QA label approval task, a case pack test, and a first shipment booking task.
- 2026-06-03: CrumbCRM is current truth for sales stage and next sales action. KitchenBoard is current truth for launch tasks and milestones.
- 2026-07-20: LaunchPad becomes the official source for project task and milestone status. Before then, KitchenBoard remains current truth.
- 2026-08-05: Retailer onboarding checklist v2 becomes required for new retailer launches; existing GreenMart launch stays on the current checklist unless Elena approves conversion.

## Expected UI Outcome

The CRM/PM surface should say, in plain business language:

- Which retailer opportunity or launch task the user is looking at.
- Who owns it, who the customer contact is, current status, value/probability where known, next scheduled change, and open decisions.
- Current source rules must not be confused by LaunchPad or checklist v2 future changes.
- Candidate decisions should be business-language choices that a launch manager can confirm, not Rye vocabulary.

