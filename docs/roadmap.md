# Rye Roadmap

This roadmap is intentionally undated. Rye should advance by capability
maturity and real adoption pressure, not fixed calendar promises.

## Onboarding and Purpose

- Build an agent-driven onboarding flow around `onboarding_scope` that asks in
  human terms what function Rye is assisting, why it matters, what is out of
  scope, and what would signal that purpose has changed.
- Support piecemeal adoption by allowing multiple active scopes in one
  organization, each with distinct sources, plugins, policies, and autonomy
  gates.
- Add scope revision workflows for repeated `context_gap` candidates, source
  drift, new organizational goals, and policy changes.

## Plugin System

- Move non-core vocabulary and behavior into loadable plugins with manifests,
  dependencies, supersession metadata, validators, admin contributions, and
  onboarding questions.
- Keep core Rye focused on graph primitives, assertions, events, provenance,
  artifacts, security, and convention helpers.
- Mature `rye-org` as a foundational plugin for people, systems, departments,
  mission, vision, goals, related organizations, policies, and procedures.
- Add plugin validation that compares manifests against active scope policies
  before agents insert or promote graph changes.

## Source Intake and Evidence

- Make source, retrieval channel, and context first-class distinctions across
  all intake paths, including Composio, native connectors, direct APIs, exports,
  logs, and files.
- Preserve enough source evidence for replay, audit, and confidence without
  forcing every provider record to become a first-class graph node.
- Add source-specific intake profiles for Slack, email, meetings, files,
  tabular imports, logs, and application events.
- Expand post-intake review packets that show source inventory, pending
  confirmations, context gaps, candidate queues, retention exposure, and blocked
  promotions.

## Storage and Retention

- Treat storage growth as a cross-cutting design constraint in every connector,
  plugin, and admin view.
- Add retention classes for evidence, context signals, low-signal material,
  raw replay artifacts, and noise summaries.
- Later, add pruning or garbage-collection jobs that preserve accepted evidence
  anchors while collapsing stale or low-value source material.

## Admin Observability

- Focus the admin interface on Rye structure: graph exploration, source
  provenance, context gaps, candidate review, plugin policy, assertion history,
  disputes, and scope health.
- Keep domain record management in domain applications that understand Rye
  metadata, rather than making Rye admin the operational UI for every app.
- Allow plugins to contribute admin tabs, dashboard cards, policy views,
  candidate groupings, and validation explanations.

## Agent Operation

- Provide agents with compiled scope policy bundles before collection,
  classification, evidence extraction, or promotion.
- Separate collector, classifier, evidence-extractor, promotion, dispute, and
  cleanup responsibilities.
- Add audit trails for why an agent considered evidence relevant, why it chose a
  node/edge/assertion type, and which policy allowed or blocked the action.
- Support agent-only handling only after a scope policy and repeated review
  outcomes make the action safe enough.

## Graph Quality

- Strengthen candidate review, dispute handling, supersession, and confidence
  modeling for subjective knowledge extraction.
- Add quality reports for orphan nodes, unsupported edges, stale assertions,
  duplicate entities, repeated context gaps, and plugin-policy violations.
- Add migration paths for plugin supersession when a better plugin replaces an
  earlier good-enough convention.
- Give agents multi-hop traversal, a supported entry point into the graph, and
  advisory identity resolution, so intake judgment stays with the agent while
  the database keeps gating outcomes. Derived reads that answer questions about
  absence need the disclosure rules in
  [`design/proposals/rls-visibility-contract.md`](../design/proposals/rls-visibility-contract.md).

## Integration Surface

- Build repeatable Composio intake recipes that land source accounts,
  containers, source items, artifacts, context gaps, and pending confirmations
  without over-promoting business facts.
- Add native connector/plugin paths where direct integration provides better
  evidence, provenance, or control than a generic channel.
- Support indirect sources such as logs and audit trails as evidence sources
  with their own retention and confidence policies.
- Evaluate optional durable execution adapters for scheduled refreshes,
  backfills, and post-capture processing without adding a Rye Core runtime or
  dependency. The current `pg_durable` assessment is documented in
  [`design/proposals/pg-durable-evaluation.md`](../design/proposals/pg-durable-evaluation.md).

## Security and Compliance

- Expand policy gates for sensitive sources, direct messages, private files,
  regulated data, and restricted teams.
- Add process-audit views that show who or what made each onboarding,
  classification, promotion, and scope-revision decision.
- Keep human-readable policy records so technical Rye admins can communicate
  behavior to organizational leaders and compliance reviewers.
