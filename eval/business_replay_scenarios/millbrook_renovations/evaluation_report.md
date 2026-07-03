# Millbrook Renovations Evaluation Report

Date: 2026-06-22

## Purpose

This pass tested a greenfield small business with no CRM and no project management system. Millbrook Home Renovations tracks work in Slack, email, a lead/job spreadsheet, a deposit tracker, and a role roster. Rye is expected to infer candidate business knowledge, route it through SME review, and become the CRM/PM dashboard after confirmation.

## Clean-Agent Replay

1. The hidden scenario was constructed top down in `scenario_brief.md`.
2. Source material was constructed separately in `source_material.md`.
3. A fresh intake agent saw only `source_material.md` and wrote `candidate_facts.json`.
   - Output: 43 candidates.
   - Covered: source policies, people, orgs, opportunities, tasks, milestones, decisions, risks, conflicts, and future changes.
4. A separate fresh SME-review agent saw only `source_material.md` and `candidate_facts.json` and wrote `sme_interview_adjudication.md`.
   - The SME accepted current business records, rejected stale spreadsheet facts, and left customer/vendor/city answers pending.
5. The graph was loaded into local Docker Postgres database `rye_eval_millbrook_renovations` using `graph_builder_load.sql`.
6. The instance was registered as `eval-millbrook-renovations`.

## Business Knowledge Loaded

Official Sales records:

- Harper Lane kitchen remodel: Leo-owned, proposal sent, Sarah Nguyen contact, $44,800, 65%, next action is revised Northstar maple cabinet allowance by June 24.
- Vale backyard ADU feasibility: Dana-owned, qualification, Chris Vale contact, $96,000, 35%, next action is City feasibility questions by June 26.
- Olson bathroom leak repair: Mateo-owned, site survey completed, Megan Olson contact, $8,400, 75%, next action is insurance-ready estimate by June 23.
- Garza deck replacement follow-up: Leo-owned, paused/nurture, Tom Garza contact, $18,000 listed value, probability intentionally unknown, July 15 follow-up.

Official Project records:

- 9 work items covering design revisions, proposal sending, City feasibility, deposit confirmation, tentative crew hold, and customer follow-up.
- 4 milestones covering Harper contract/deposit, Vale zoning decision, Olson booking/deposit, and Olson July 8 crew window.
- Dependencies and blockers include Northstar written quote, City of Millbrook feasibility answer, and Olson approval/deposit.

Candidate outcomes:

- Accepted: 6 candidate records/policies.
- Rejected: 3 stale or misleading facts.
- Needs review: 5 open decisions for Sarah approval, Northstar quote, City feasibility, Olson approval/deposit, and Garza August timing.

Future knowledge:

- Conditional sales stage changes on June 25, June 27, July 5, and July 15.
- Conditional milestone changes on June 25, June 27, and July 5.
- Source-of-truth policy changes on July 8: Rye is checked first for opportunity status, next customer action, task status, and milestone status if the pilot works.

## UI Review

Sales:

- Shows four opportunities in plain language with owner, contact, current status, next planned change, and open-decision count.
- Detail panel now shows what to do next, at-a-glance facts, people/organizations, connected work, upcoming changes, gaps, and related decisions.
- Vale correctly shows City of Millbrook as an external approval gate.

Projects:

- Shows tasks and milestones together without requiring the user to know graph terminology.
- Blocked and dependent work is visible in the selected detail panel.
- Olson deposit selected by default shows the estimate dependency, crew-hold dependency, deposit blocker, related opportunity, owner, and open decision.

Decisions:

- Shows 5 business decisions with clear actions: ask owner to verify or mark not useful.
- No raw Rye identifiers or candidate status names are required for the reviewer to understand what is being decided.
- Source evidence now uses specific supported sources instead of generic source labels.

Upcoming:

- Separates future scheduled changes from what is true today.
- Includes conditional business changes and the July 8 Rye-first operating policy.

Systems:

- Shows current authority and future authority by business area.
- Confirms Rye is used today after SME confirmation, and that July 8 changes how new updates should be checked first.

## Verification

- `npm run typecheck` passed in `admin`.
- `node --check surfaces/crm-pm/app.js` passed.
- Database load succeeded with `ON_ERROR_STOP=1`.
- API checks passed:
  - CRM: 4 opportunities, 4 plans, 4 policies, 5 candidates.
  - PM: 9 tasks, 4 milestones, 3 plans, 4 policies, 5 candidates.
- Patchwork regression API still returns expected counts:
  - CRM: 3 opportunities, 4 candidates.
  - PM: 6 tasks, 3 milestones, 4 candidates.
- Browser checks on Sales, Projects, Decisions, Upcoming, and Systems had no console errors.

## Remaining Gaps

- The PM profile still needs first-class project and milestone creation helpers so graph builders do not create those records manually.
- Candidate inclusion is improved by target ids, but the review API should expose candidate target ids directly so the browser does less inference.
- Pending customer/vendor/city decisions should eventually have better actions than only verify/dismiss, such as `Record customer answer`, `Request vendor update`, or `Set reminder`.
- The UI now explains connected graph context, but it does not yet show the full source excerpt side-by-side with each decision.

