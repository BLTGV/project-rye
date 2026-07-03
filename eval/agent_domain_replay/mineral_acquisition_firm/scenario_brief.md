# Scenario Brief: Redtail Minerals

Redtail Minerals is a fictional small mineral acquisition firm. The expected graph was designed before writing the source packet.

## Expected Shape

- Domains:
  - `acquisition-pipeline`: opportunity stage, deal owner, next action, target close.
  - `account-updates`: owner, seller, account health, communication status.
  - `title-diligence`: title defects, curative owner, title clearance.
  - `closing-funding`: funding readiness, wire timing, closing checklist.
  - `deal-process`: current and future operating procedure.
- Channel subscriptions:
  - `slack:#deals-redtail`: acquisition pipeline, account updates, deal process.
  - `slack:#title-redtail`: title diligence, account updates, deal process.
  - `slack:#finance-redtail`: closing funding, acquisition pipeline, account updates.
- Authoritative sources:
  - Nora Quinn, deal lead: acquisition pipeline and account updates.
  - Eli Hart, land/title lead: title diligence.
  - Priya Shah, finance lead: closing funding.
- Temporal test:
  - Current process: title exceptions are tracked in the shared title sheet.
  - Future process: starting 2026-07-15, all new title exceptions must be logged in the Title Queue table before being discussed in Slack.
