---
name: rye-onboarding
description: Create or revise Rye onboarding scopes, source context policies, plugin bindings, and context-gap review packets before agents promote source evidence into graph knowledge.
---

# Rye Onboarding

Use this skill when setting up Rye for a limited organizational function,
expanding Rye into a new function, or revising purpose/context policies after
source intake produces repeated context gaps.

## Core Rule

Rye starts piecemeal. Treat the onboarding scope as the active adoption unit:
what function Rye is assisting now, why it matters, what is out of scope, which
sources and channels are involved, which plugins are enabled, and what agents
may do without human review.

## Workflow

0. If Rye is not installed in the current project, use the public bootstrap:
   - Local trial: `curl -fsSL https://projectrye.dev/onboard | sh`
   - Remote database:
     `curl -fsSL https://projectrye.dev/onboard | sh -s -- --remote "$DATABASE_URL"`
   - The bootstrap clones Rye, installs the schema, and writes `.rye.env`.
   - This skill can be installed with:
     `npx skills add BLTGV/project-rye --skill rye-onboarding`
1. Define the `onboarding_scope` in human terms:
   - label and key based on the organizational purpose, project, function, or
     workflow, not the source or retrieval channel
   - purpose and expected organizational value
   - in-scope function or workflow
   - explicit out-of-scope boundaries
   - owner or accountable reviewer
   - what would signal that purpose or scope has changed
2. Separate source, retrieval channel, and context:
   - source account/container/item: where the material originated
   - retrieval channel: Composio, native plugin, direct API, export, log, or file
   - expected contexts: where the material is likely useful
3. Record policies with `record_scope_policy(...)`:
   - `expected_contexts`
   - `holding_context`
   - `unexpected_context_policy`
   - `blocked_contexts`
   - `retention_policy` or `evidence_policy`
   - allowed node, edge, assertion, event, and artifact types
   - human review and agent autonomy gates
4. Enable plugins with `enable_plugin_for_scope(...)`.
5. Compile the active policy with `compile_scope_policy(...)` before handing
   instructions to collector, classifier, or promotion agents.
6. Activate with `activate_onboarding_scope(...)` only after policy and plugin
   bindings are present.

## Fresh Setup Path

Use this sequence when the user says they are starting from scratch:

1. Confirm whether they want:
   - local trial first, with a Docker Postgres database they can migrate away
     from later
   - remote install into a PostgreSQL 15+ database they already control
2. Run the bootstrap:
   - local: `curl -fsSL https://projectrye.dev/onboard | sh`
   - remote:
     `curl -fsSL https://projectrye.dev/onboard | sh -s -- --remote "$DATABASE_URL"`
3. Check installation with `./scripts/rye status`.
4. Ask for the first limited workflow Rye should assist. Do not ask the user
   for graph node and edge types first; derive the initial policy from purpose,
   boundary, source plans, and review needs.
5. Create the first onboarding scope with `./scripts/rye onboard --label ...
   --purpose ...`.
6. Only after the scope exists, connect source metadata with
   `rye-source-context` conventions.

## Naming Guardrail

Name scopes after the domain context Rye is helping with. Do not name a scope
after Slack, email, Composio, logs, exports, "pilot", or another source/channel
unless that source/channel is itself the organizational process being modeled.

Good scope labels:

- `Glamies Project`
- `Lead Follow-Up`
- `Customer Renewal Review`
- `Incident Response`

Bad scope labels:

- `Glamies Slack Pilot`
- `Slack Lead Follow-Up`
- `Composio Email Intake`
- `Logs Project`

Record sources and retrieval channels separately with `source_account`,
`source_container`, `source_item`, `retrieval_channel`, and `intake_profile`.
If only source metadata is known, create a conservative review context such as
`Needs Context` and ask for the domain purpose instead of inventing one from
the source name.

## Expected Contexts

Use `expected_contexts` as routing expectations, not a closed whitelist. If a
source item cannot be matched, route it to the configured `holding_context` or
create a `context_gap` candidate. Do not discard it only because it is
unexpected unless a hard `blocked_contexts` or retention policy requires that.

Repeated context gaps should trigger a scope revision conversation, not an
automatic expansion of scope.

## Plugin Baseline

Keep Rye core small. Prefer enabling plugins for non-core vocabulary and
behavior.

- `rye-source-context`: accounts, containers, items, retrieval channels, intake
  profiles, expected contexts, and context gaps
- `rye-evidence-anchor`: source-backed evidence and provenance behavior
- `rye-org`: people, systems, departments, mission, vision, goals, related
  organizations, policies, and procedures
- `rye-tabular-intake`: CSV/XLSX/file intake
- `rye-change-tracking`: change tracking and audit conventions
- `rye-logging`: logs as source material and operational events
- `rye-crm`: CRM-specific vocabulary
- `rye-project-management`: project/task/workstream vocabulary

## Admin Interface Intent

Use admin surfaces for observing Rye structure, policy, candidates, context
gaps, plugin bindings, and graph quality. Do not turn the Rye admin into the
application UI for domain data. Domain applications can manage their own users,
records, and workflows while Rye tracks evidence, actions, and graph state.

## References

- `docs/onboarding.md`
- `docs/conventions-catalog.md`
- `plugins/rye-plugin.schema.json`
- `schema/migrations/0010_onboarding_scope_plugins.sql`
