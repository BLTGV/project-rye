# Rye Agent Domain Replay Harness

This harness tests the secure Rye intake pattern from both directions:

1. Build the expected business graph top down.
2. Construct realistic source packets that imply that graph.
3. Give only source material and Rye intake instructions to an isolated agent.
4. Give source material plus candidates to an isolated SME-review agent.
5. Load reviewed candidates into Rye through domain-scoped functions.
6. Compare isolated output against the hidden oracle.

The scenarios exercise domain authority, channel-specific and shared domains,
candidate/current/future separation, superseded process knowledge, and cross-cutting
business context.

## Scenarios

- `mineral_acquisition_firm`: acquisition pipeline, owner/account updates, title diligence, closing/funding, and a future diligence process change.
- `custom_fabrication_company`: quote pipeline, engineering review, production handoff, QA hold/release, customer commitments, and a superseded spreadsheet process.
- `service_operations_company`: support/account health, implementation milestones, billing risk, delivery process, account updates, and planned CRM/PM adoption.

## Run

```bash
node eval/agent_domain_replay/compare_replay.mjs
```

Use `--write` to refresh each scenario's `comparison_report.md`.
