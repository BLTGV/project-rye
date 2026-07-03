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

## Operating Mode

Before asking for organizational details, determine whether the user is asking
for real onboarding or development evaluation.

Real onboarding means the user wants Rye configured for an actual organization,
project, function, or workflow. Optimize for building an accurate scoped
organizational store. Ask for purpose, boundary, owner, source meaning,
retention, evidence, inference, and review policy before ingestion or
promotion.

Development evaluation means the user wants to test whether Rye skills,
bootstrap paths, CLI commands, subagents, and policy gates behave correctly.
Optimize for observable agent behavior. Start from a clean consumer workspace
when possible, install this skill through the public path, bootstrap Rye through
the documented onboarding script, inspect only installed skills, the cloned Rye
repo, and the Rye datastore, and stop at each organization-specific context
checkpoint.

In both modes, do not use prior sessions, demo notes, connector names, source
names, or local artifacts as organizational truth unless the user explicitly
provides them as input or fixture data.

## Source Landscape Discovery

If the user wants to start by categorizing information, folders, channels,
messages, or other source locations, treat that as `Source Landscape Discovery`
unless they name a narrower business workflow.

Source Landscape Discovery is metadata-first. Its goal is to help the user
choose good onboarding scopes by inventorying available source accounts and
containers, identifying activity and sensitivity patterns, and producing
candidate scope recommendations.

Allowed work:

- inventory source accounts and containers
- inspect source metadata, container names, counts, timestamps, and limited
  recent samples
- propose provisional source categories such as source type, activity window,
  sensitivity, evidence value, and ingestion readiness
- create context-confirmation questions and candidate onboarding scopes

Do not do these things under Source Landscape Discovery unless the user
explicitly approves a narrower follow-up scope:

- promote accepted business facts
- create semantic edges about people, organizations, customers, vendors,
  ownership, membership, or responsibility
- ingest full Slack histories, full email bodies, direct messages, private
  channels, or attachments
- treat source, folder, channel, mailbox, or connector names as confirmed
  business context

Before running discovery, ask the user to confirm:

- source systems allowed for metadata inventory
- date/activity window, usually the last 90 days
- whether private channels, DMs, email bodies, or attachments are excluded
- who reviews candidate scopes and source/context confirmations
- what categories or sensitivities would be harmful to infer

## Workflow

0. If Rye is not installed in the current project, use the public bootstrap:
   - If the task includes installation, migration, verification, schema
     debugging, or conformance checks, make sure the installer skill exists:
     `test -f .agents/skills/rye-installer/SKILL.md || test -f skills/rye-installer/SKILL.md || npx skills add BLTGV/project-rye --skill rye-installer`
   - After installing it, read `skills/rye-installer/SKILL.md` directly if
     the agent harness does not automatically refresh available skills in the
     current session. In a fresh consumer project, the installed file is usually
     `.agents/skills/rye-installer/SKILL.md`; in a Rye checkout it may be
     `skills/rye-installer/SKILL.md`.
   - Local trial:

     ```bash
     tmp="$(mktemp)"
     curl -fsSL https://projectrye.dev/onboard -o "$tmp" || \
       curl -fsSL https://raw.githubusercontent.com/BLTGV/project-rye/main/site/public/onboard -o "$tmp"
     sh "$tmp"
     rm -f "$tmp"
     ```

   - Remote database:

     ```bash
     tmp="$(mktemp)"
     curl -fsSL https://projectrye.dev/onboard -o "$tmp" || \
       curl -fsSL https://raw.githubusercontent.com/BLTGV/project-rye/main/site/public/onboard -o "$tmp"
     sh "$tmp" --remote "$DATABASE_URL"
     rm -f "$tmp"
     ```

   - The bootstrap clones Rye, installs the schema, syncs plugin metadata, and
     writes `.rye.env`.
   - Plugin metadata comes from `plugins/*/rye-plugin.json` and includes
     contributed node, edge, assertion, event, and artifact types.
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
   - use `record_source_of_truth_policy(...)` when the scope depends on which
     system/source is authoritative for a status or fact domain
   - use `record_improvement_cycle(...)` when the scope is about improving a
     recurring business process with a goal, current constraint, metrics, and
     repeat trigger
   - use `register_scope_convention(...)` when repeated local vocabulary needs
     aliases, use/avoid guidance, and status before it becomes a full plugin
4. Enable plugins with `enable_plugin_for_scope(...)`.
5. Compile the active policy with `compile_scope_policy(...)` before handing
   instructions to collector, classifier, or promotion agents.
6. Activate with `activate_onboarding_scope(...)` only after policy and plugin
   bindings are present.

## Business Knowledge Setup

Do not treat logging or tracing as the primary output of onboarding. Logs,
exports, transcripts, and connector results are evidence. The setup should
persist changing business knowledge:

- the scope purpose and boundary
- source-of-truth policy by fact/status domain
- accepted knowledge and review gates
- retention and evidence policy
- current process constraint
- process-improvement cycle
- local conventions that fresh agents should reuse

For process-improvement scopes, preserve the constraint loop explicitly:

```text
Identify -> Exploit -> Subordinate -> Elevate -> Repeat
```

Keep operational row-level facts, customer/patient/person-specific statuses, and
source-derived semantic relationships as candidates until the relevant review
policy allows promotion.

When the business process includes planned future changes, teach agents to
separate current plans from future-effective truth:

- current-visible plan assertions say what the organization intends to do,
  who owns it, what date it targets, and what dependencies or risks remain
- future-effective assertions say what Rye should answer on or after a date
- `current_valid_assertions` answers what is true now
- `assertions_as_of(...)` answers what was or will be true at a specific time
- CRM/PM scheduling helpers should be used instead of hand-rolled SQL when
  scheduling stage, task status, or milestone status changes

## Interviewing Discipline

When onboarding knowledge arrives through conversation instead of documents,
elicitation quality determines graph quality. Rules:

- When a date or amount is tied to a deadline, decision, or money, do not
  accept a vague answer ("early June", "around 80 grand") as final. Either
  ask once for the specific value, or record the vague value with explicit
  uncertainty AND a named confirmer ("Priya has the exact number") plus a
  confirmation task. Never let vagueness silently become precision.
- Ask for full names and contact details of people who will appear in the
  graph, at least once. "Priya" is a weaker node than "Priya Shah".
- Play the captured facts back to the interviewee in plain language before
  closing, and record their corrections. People volunteer specifics when they
  hear their own facts summarized.
- Confirm the review policy in plain words — who signs off before something
  counts as official — rather than inferring it silently from context.

## Scope Revisions Must Stay Consistent

A scope is defined by several records at once: the scope node's properties,
the `scope_boundary` assertion, the `expected_contexts` policy, and any
compiled policy. When the scope changes (widening, narrowing, re-purposing),
enumerate and supersede ALL scope-defining assertions in the same change —
never update one and leave another carrying the old wording. A split-brain
scope (node property says one boundary, current assertion says another) is
worse than either wording alone, because downstream consumers cannot tell
which is authoritative. After a revision, re-run `compile_scope_policy` and
verify the boundary reads consistently from both the node and the current
assertions.

## Fresh Setup Path

Use this sequence when the user says they are starting from scratch:

1. Ensure installer guidance is available:
   - If `.agents/skills/rye-installer/SKILL.md` or
     `skills/rye-installer/SKILL.md` exists, read it for install, migration,
     verification, and conformance details.
   - If it is missing and `npx` is available, run
     `npx skills add BLTGV/project-rye --skill rye-installer`.
   - If the install succeeds but the skill does not auto-load in the current
     turn, read `.agents/skills/rye-installer/SKILL.md` directly and continue.
2. Confirm whether they want:
   - local trial first, with a Docker Postgres database they can migrate away
     from later
   - remote install into a PostgreSQL 15+ database they already control
3. Run the bootstrap:
   - local:

     ```bash
     tmp="$(mktemp)"
     curl -fsSL https://projectrye.dev/onboard -o "$tmp" || \
       curl -fsSL https://raw.githubusercontent.com/BLTGV/project-rye/main/site/public/onboard -o "$tmp"
     sh "$tmp"
     rm -f "$tmp"
     ```

   - remote:

     ```bash
     tmp="$(mktemp)"
     curl -fsSL https://projectrye.dev/onboard -o "$tmp" || \
       curl -fsSL https://raw.githubusercontent.com/BLTGV/project-rye/main/site/public/onboard -o "$tmp"
     sh "$tmp" --remote "$DATABASE_URL"
     rm -f "$tmp"
     ```

4. Check installation with `./scripts/rye status`.
5. If running inside Codex or another coding-agent harness, orient from the
   current project folder first:
   - read `.rye.env` if present, but do not print secrets
   - run `./scripts/rye status`
   - run `./scripts/rye plugins list` to see installed vocabulary metadata
   - summarize whether Rye is installed and whether any onboarding scopes
     already exist
6. Ask for the first limited workflow Rye should assist. Do not ask the user
   for graph node and edge types first; derive the initial policy from purpose,
   boundary, source plans, and review needs.
7. Create the first onboarding scope with `./scripts/rye onboard --label ...
   --purpose ...`.
8. Only after the scope exists, connect source metadata with
   `rye-source-context` conventions.

## Development Evaluation Path

Use this sequence when the user is testing the onboarding skill or subagent
behavior rather than onboarding a real organization:

1. Start from a clean consumer workspace, not a prior demo folder with source
   artifacts or session notes.
2. Install this skill with
   `npx skills add BLTGV/project-rye --skill rye-onboarding`.
3. Read the installed skill file from the workspace. If installer guidance is
   needed, install or read `rye-installer` as directed by this skill.
4. Bootstrap a local trial unless the user explicitly provides a remote
   database for the test.
5. Run `./scripts/rye status`, `./scripts/rye catalog plugins --json`,
   `./scripts/rye catalog skills --json`, and `./scripts/rye context --json`.
6. Stop before creating an onboarding scope unless the user provides the
   limited workflow, scope boundary, owner/reviewer, source expectations, and
   review policy.
7. Report commands run, files created, datastore status, what the skill caused,
   and the exact user/admin questions needed next.

Passing behavior: the agent asks for missing organizational context and creates
no source-derived facts before scope policy exists. Failing behavior: the agent
invents purpose from a connector or source name, uses prior session context, or
ingests/promotes facts before an onboarding scope and review policy exist.

For Source Landscape Discovery evaluation, passing behavior also includes
separating metadata inventory from content ingestion, excluding private/DM/email
body content by default, and returning candidate scopes instead of accepted
business knowledge.

## Codex Harness Prompt

After installing the skill with:

```bash
npx skills add BLTGV/project-rye --skill rye-onboarding
```

Start Codex in the project folder and use this prompt:

```text
Use the Rye onboarding skill. Check whether Rye is installed, run
./scripts/rye status, then help me create the first onboarding scope.

Start by asking what limited workflow or organizational purpose Rye should
assist first. Do not ingest sources or promote facts until the scope, boundary,
expected contexts, and review policy exist.
```

## Naming Guardrail

Name scopes after the domain context Rye is helping with. Do not name a scope
after Slack, email, Composio, logs, exports, "pilot", or another source/channel
unless that source/channel is itself the organizational process being modeled.

Good scope labels:

- `Example Project`
- `Lead Follow-Up`
- `Customer Renewal Review`
- `Incident Response`

Bad scope labels:

- `Example Slack Pilot`
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
