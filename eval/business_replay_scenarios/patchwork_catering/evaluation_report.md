# Patchwork Pantry Catering Rye Evaluation

Evaluation date: June 22, 2026

## Overall Assessment

The loaded Rye dashboard is a strong match to the SME-confirmed Patchwork Pantry facts. Rye is functioning as the first CRM and project dashboard for the pilot: it holds the confirmed opportunity pipeline, sales next actions, project tasks, milestones, blockers, and source-of-truth policies that replace the spreadsheets once Ana Rivera or Sofia Klein confirms records.

The main remaining gaps are not broad factual errors. They are operating-detail and dashboard visibility gaps.

## What Matches

- Rye correctly treats Slack, email, Lead Tracker, and Event Workboard inputs as evidence until Ana or Sofia confirms them.
- Rye records the July 1 policy that Rye should be checked first for opportunity status, next sales action, task status, and milestone status.
- The CRM pipeline has the three SME-confirmed opportunities:
  - Atlas Labs summer offsite catering: Sofia-owned, proposal sent, Priya Menon as contact, $18,600 value, 60% probability, and next action to send revised vegetarian station pricing by June 24.
  - Willow Creek School gala: Ana-owned, qualification stage, Miguel Arroyo as contact, $32,000 tentative value, 45% probability, and River Hall site walk next action on June 27.
  - Baxter-Diaz late-night dessert bar: Sofia-owned, needs scope, Jenna Baxter as contact, $7,800 tentative value, 30% probability, and scope question due June 25.
- Rye rejects the stale Atlas spreadsheet values of $17,800 and 55%.
- The PM view has the right active work:
  - Marco owns Atlas vegetarian station pricing, in progress, high priority, due June 24.
  - Sofia owns the Atlas resend-pricing follow-up, due June 24.
  - Nora owns Atlas rentals confirmation, correctly blocked until Crest has revised tent dimensions and replies.
  - Rae owns the Willow site walk checklist, due June 27.
  - Ana owns the Willow staffing estimate, waiting on River Hall kitchen access and the site walk.
  - Sofia owns Baxter-Diaz scope clarification, due June 25.
- Milestones are aligned:
  - Atlas contract/deposit is waiting customer for June 28.
  - Willow River Hall site walk is planned for June 27.
  - Willow proposal decision is pending site walk and depends on workable headcount and kitchen access.

## Post-Evaluation Fix

The clean evaluator found that Theo Marsh was loaded as the finance/deposit contact, but the Atlas contract signed/deposit milestone was not assigned to him in the dashboard.

That gap is now fixed:

- `graph_builder_load.sql` assigns milestone owners.
- The PM workspace API now returns `owner_name`, `owner_id`, and `priority` for milestones.
- The Projects detail panel now shows milestone owner and priority.
- The live Patchwork PM API shows Theo Marsh as owner of `Atlas contract signed and deposit received`.

## Remaining Gaps

- Some operating details are present in the graph but not prominent enough in dashboard views: Crest/Lena vendor context, River Hall/DeShawn venue context, Ana's collaboration on the Willow checklist, and the Willow contingency of two extra runners plus a refrigerated van if there is no prep kitchen access.
- Atlas lounge furniture is separated as a rentals task, but the dashboard should make Priya's requirement explicit: lounge furniture must stay separate from food and staffing in the package.
- Baxter-Diaz rough options are correctly not ready until Jenna answers the scope question, but there is no separate blocked/future follow-up for sending rough options after scope is clarified.
- Pending customer/vendor answers now appear as decisions, but the action label `Ask for proof` is not ideal for this workflow. A better label would be `Request update` or `Keep waiting`.

## Conclusion

Yes, Rye is acting as both CRM and PM for this replay. As CRM, it owns opportunities, stages, owners, contacts, values, probabilities, next sales actions, and conditional stage plans. As PM, it owns projects, tasks, task statuses, due dates, blockers, milestone status, milestone owners, and future milestone plans.

This test is meaningfully different from the official-system snapshot tests: there is no external CRM/PM authority. The authority transition is from messy evidence plus SME confirmation into Rye-owned dashboard records.
