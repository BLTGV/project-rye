# Millbrook Renovations Hidden Scenario Brief

Do not provide this file to intake, SME, or graph-builder agents. It is the evaluator's top-down target for the replay.

## Business

Millbrook Home Renovations is a seven-person residential remodeling company. It has no CRM and no project management system. Leads, project work, vendor blockers, deposits, and follow-up dates are spread across Slack, email, and spreadsheets.

The owner wants Rye to become the first real CRM/PM dashboard after a human confirms imported candidates. Before confirmation, communication and spreadsheet rows are evidence only.

## Expected Business Questions

A fresh business assistant should be able to answer:

- What active opportunities exist, who owns each one, what is the value/probability, and what is the next customer action?
- Which projects or pre-project work items are blocked by customers, vendors, city review, deposits, or internal estimates?
- Which old spreadsheet rows are stale and should not confuse the current dashboard?
- Which facts are true today versus planned for future dates?
- Where did each open decision come from, and who should confirm it?
- When does Rye become the first place to check status updates?

## Expected Graph Shape

Core nodes:

- Org: Millbrook Home Renovations
- People: Dana Mills, Leo Tran, Clara Holt, Mateo Ruiz, Beth Chen, Ian Brooks
- Customers: Harper Lane household, Vale household, Olson household, Garza household
- Vendors/systems: Northstar Cabinets, City of Millbrook Permit Office, Quarry Stone Yard
- Source items: Slack #jobs export, Harper email thread, Vale ADU email thread, Olson bath email thread, Leads & Job Board spreadsheet, Deposit Tracker spreadsheet, Rye pilot note
- Pipeline: Millbrook residential opportunities
- Opportunities:
  - Harper Lane kitchen remodel
  - Vale backyard ADU feasibility
  - Olson bathroom leak repair
  - Garza deck replacement follow-up
- Projects:
  - Harper Lane kitchen pre-construction
  - Vale ADU feasibility
  - Olson bath repair
  - Garza deck nurture
- Tasks:
  - Harper cabinet allowance revision
  - Harper demolition phasing plan
  - Northstar cabinet quote confirmation
  - Vale zoning feasibility packet
  - Olson insurance-ready estimate
  - Olson July 8 crew hold
  - Garza July follow-up
- Milestones:
  - Harper signed proposal and deposit
  - Vale zoning feasibility decision
  - Olson deposit and schedule lock

Current accepted status as of 2026-06-22:

- Harper Lane kitchen remodel: proposal sent, owner Leo, contact Sarah Nguyen, value $44,800, probability 65%, next action send revised cabinet allowance by 2026-06-24.
- Vale backyard ADU feasibility: qualification, owner Dana, contact Chris Vale, value $96,000, probability 35%, next action send zoning feasibility questions to City of Millbrook by 2026-06-26.
- Olson bathroom leak repair: site survey completed, owner Mateo, contact Megan Olson, value $8,400, probability 75%, next action send insurance-ready estimate by 2026-06-23.
- Garza deck replacement follow-up: paused/nurture, owner Leo, contact Tom Garza, value $18,000, probability 20%, next action follow up on 2026-07-15.

Future knowledge:

- Harper should move to contract review on 2026-06-27 only if Sarah approves the revised cabinet allowance.
- Vale should move to proposal sent on 2026-07-05 only if zoning confirms the detached unit is feasible under 650 sqft.
- Olson should move to closed won on 2026-06-25 only if Megan approves the estimate and Beth receives a deposit.
- Garza should re-enter active qualification on 2026-07-15 only if Tom confirms August timing.
- Starting 2026-07-08, Rye should be checked first for opportunity status, next sales action, task status, and milestone status. Spreadsheets are import staging/evidence only.

Known conflicts:

- Leads & Job Board still shows Harper at $42,000 and 55%; Slack/email indicate the updated value is $44,800 and 65%.
- Leads & Job Board marks Garza as closed lost; Slack says this is wrong and should be treated as paused until July follow-up.
- Deposit Tracker has an unchecked "crew hold" flag for Olson; Slack says Mateo asked Beth to hold July 8 tentatively, not lock the schedule.

Expected pending decisions:

- Sarah approval of Harper revised cabinet allowance.
- Northstar Cabinets quote confirmation.
- City zoning answer for Vale ADU.
- Olson insurance adjuster/deposit.
- Tom Garza August timing.

