# Cedar Ridge HVAC Scenario Brief

This file is the evaluator brief. Do not give it to intake or graph-builder agents.

## Business

Cedar Ridge HVAC & Controls is an 18-person commercial HVAC contractor in Richmond, Virginia. The company sells and delivers small commercial retrofit projects for clinics, restaurants, and light industrial customers.

## Goals

- Increase proposal-to-install reliability before the summer rush.
- Reduce permit-driven schedule slips.
- Keep sales follow-up and project delivery in sync without asking humans to reconstruct status from memory.
- Preserve future process changes without treating them as current truth.

## People

- Maya Patel: owner and general manager.
- Alex Chen: sales lead.
- Lena Morales: operations manager.
- Jordan Reed: project manager.
- Priya Nair: service coordinator.
- Ben Ortiz: finance lead.
- Sam Brooks: warehouse lead.
- Nora Ellis: Fulton Family Dental office manager, customer contact.
- Dr. Valerie Quinn: Fulton Family Dental owner.
- Marcus Hill: Riverbend Brewery CFO, customer contact.
- Kara Moss: CityPermit Expedite permit runner.
- Ari Levin: NorthAir Supply account manager.
- Miguel Santos: VoltPro Electrical subcontractor.

## Current Opportunities

- Fulton Family Dental rooftop unit replacement.
  - Owner: Alex Chen.
  - Primary contact: Nora Ellis.
  - Current stage: proposal_sent.
  - Value: 84000.
  - Win probability: 0.65.
  - Future planned stage: contract_review on 2026-07-03 if the utility rebate letter is received.
- Riverbend Brewery controls upgrade.
  - Owner: Maya Patel.
  - Primary contact: Marcus Hill.
  - Current stage: qualification.
  - Value: 46500.
  - Win probability: 0.40.
  - Future planned stage: site_survey_completed on 2026-07-08 after the brewhouse walkthrough.

## Current Project Work

- Fulton Dental permit resubmission.
  - Project: Fulton Dental rooftop replacement.
  - Owner: Jordan Reed.
  - Status: blocked.
  - Due: 2026-06-27.
  - Priority: high.
  - Blocker: waiting for signed structural letter from CityPermit Expedite.
- Order Fulton rooftop curb adapter.
  - Owner: Sam Brooks.
  - Status: in_progress.
  - Due: 2026-06-28.
  - Priority: high.
  - Future planned status: ready_for_install on 2026-06-30 after NorthAir confirms ship date.
- Fulton after-hours access plan.
  - Owner: Priya Nair.
  - Status: todo.
  - Due: 2026-07-01.
  - Priority: medium.
- Fulton permit released milestone.
  - Current status: waiting_city.
  - Target date: 2026-07-02.
  - Future planned status: approved on 2026-07-02 if city releases the revised permit.

## Process And Source-Of-Truth History

- 2026-03-18: A dental clinic emergency chiller quote was lost after permit risk was discovered too late.
- 2026-04-22: Cedar Ridge decided every permit-sensitive job needs an explicit permit milestone.
- 2026-05-10: The team started using Slack channel `#install-coordination` for daily coordination.
- 2026-06-01: HearthCRM is current truth for sales stages and next sales actions. JobBoardPM is current truth for project task and milestone status.
- 2026-07-15: BuildBoard will become the official source for crew scheduling only. Slack remains informal coordination and should not answer official status questions.
- 2026-08-01: PipelinePro will become the official source for sales stages and next sales actions. Before 2026-08-01, HearthCRM remains current truth.

## Expected UI Outcome

The CRM/PM surface should say, in plain business language:

- What each opportunity or task is about, who owns it, who the customer contact is, current status, value/probability where known, next scheduled change, and open decisions.
- Open candidate decisions should read like business choices, not Rye schema details.
- Future source changes should appear in Upcoming/Systems without changing what Sales and Projects say is true today.

