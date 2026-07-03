# Scenario Brief: Beacon Field Services

Beacon Field Services is a fictional service operations company that manages customer support, implementation projects, and recurring billing.

## Expected Shape

- Domains:
  - `account-health`: customer status, risk, owner updates.
  - `support-operations`: support incidents, escalation state, resolution.
  - `implementation-projects`: milestones, delivery owner, project status.
  - `billing-risk`: invoice hold, collection risk, billing authority.
  - `systems-adoption`: planned CRM/PM adoption and future process changes.
- Authorities:
  - Simone Bell, account owner: account health and customer commitment.
  - Omar Velez, delivery lead: implementation milestones and delivery status.
  - Tess Morgan, finance/admin reviewer: billing hold and invoice release.
  - Jae Lin, support lead: support incident resolution.
- Temporal test:
  - Current tracking: communication and spreadsheets are source material.
  - Future process: starting 2026-08-01, CRM stages and PM milestones must be updated in Rye dashboards, not only Slack/spreadsheets.
