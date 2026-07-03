# Scenario Brief: Northstar Fabrication

Northstar Fabrication is a fictional custom metal fabrication shop. It sells engineered fixtures, routes won jobs through engineering, then production, then QA.

## Expected Shape

- Domains:
  - `quote-pipeline`: quote stage, value, customer commitment, win timing.
  - `engineering-review`: design risk, drawing approval, engineering owner.
  - `production-handoff`: production start, traveler readiness, plant owner.
  - `qa-release`: QA hold/release and rework requirements.
  - `fabrication-process`: current and superseded process rules.
- Authorities:
  - Mateo Ruiz, sales director: quote stage and customer commitments.
  - Dana Fox, plant manager: production handoff and plant schedule.
  - Lin Park, QA lead: QA hold/release decisions.
  - Avery Cho, engineering lead: drawing readiness and engineering risk.
- Temporal test:
  - Superseded process: pre-June jobs used `Quotes Master.xlsx` as the handoff tracker.
  - Current process: as of 2026-06-10, won jobs need a traveler packet before production start.
