# Candidate Review Usability Flaws

Recorded 2026-06-22 after small-business CRM/PM candidate replay review.

## What is broken

- The review page reads like an admin inspection surface, not a human work queue.
- The user must select a candidate in one region, then find the action/edit surface somewhere else.
- On common viewports, the edit surface can fall below the fold, so the user does not know what action is expected.
- The page exposes raw Rye concepts such as assertion type, assertion key, subject node id, claim JSON, edge source id, and edge target id.
- Those fields are only appropriate for a Rye maintainer or heavily trained operator. A normal business reviewer should not need to understand them.
- Guided acceptors improved correctness but still live inside an admin mental model.
- CRM and PM candidates are being adjudicated as generic knowledge candidates rather than as business records: opportunities, deals, tasks, milestones, owners, due dates, blockers, and plan changes.
- The source evidence, candidate statement, editable business fields, and final decision are split across multiple vertical sections instead of one coherent review task.
- The interface does not clearly distinguish:
  - accepting a fact as current truth,
  - accepting a planned future change,
  - rejecting the candidate,
  - asking for more evidence,
  - editing the proposed business record before acceptance.
- The default generic editor encourages editing low-level storage shape instead of reviewing business meaning.

## Product Direction

Candidate adjudication should not be centered in the admin console.

The admin review page can remain as a diagnostic and recovery tool for Rye maintainers, but normal candidate confirmation should move to domain surfaces:

- CRM pipeline/deal surface for opportunities, contacts, customers, source-system cutovers, and deal-stage plans.
- PM board/timeline surface for projects, tasks, milestones, blockers, owners, and future status plans.

Those surfaces should show candidate knowledge as proposed business changes:

- "Move Northstar Cafe opportunity to Proposal Sent on July 2 after quote package release?"
- "Change task BW-TSK-9001 to Ready for Install on July 8 after supplier confirmation?"
- "Make PipelinePro authoritative for deal stage and next action on August 15?"

The reviewer should confirm, edit, reject, or request evidence from a business-language form. Rye ids, assertion keys, JSON claims, and edge details should be hidden behind an advanced/debug reveal.

## Boundary

Do not keep adding usability patches to the admin review page before building the CRM/PM operator surfaces. Any remaining admin review work should be treated as diagnostic tooling, not the primary human workflow.
