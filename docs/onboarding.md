# Rye Onboarding Scopes and Plugin Metadata

Rye onboarding is scope-first. A Rye instance usually starts by assisting one
limited function or workflow, then expands as the organization learns what is
useful. The durable unit for that setup is an `onboarding_scope` node.

An `onboarding_scope` records:

- what limited function Rye is helping with now
- what is explicitly out of scope
- why the scope matters
- which sources and retrieval channels are involved
- which plugins are active
- which node, edge, assertion, event, and artifact types agents may use
- when humans must review decisions
- when agents may act under a plugin policy
- what would trigger purpose or scope revision

Onboarding decisions are stored as Rye assertions and events. Later changes
supersede earlier assertions instead of overwriting them.

## SQL as the Agent Contract

Rye stores its durable behavior in PostgreSQL because the database is the
contract shared by agents, the admin UI, plugin helpers, import tools, and
human operators. Agents should treat helper functions as the write API, not as
incidental implementation details.

This matters most for assertion lifecycle behavior. `record_assertion(...)`
knows how to record current, historical, candidate, and future-effective
knowledge. `current_valid_assertions` knows what is valid now.
`assertions_as_of(...)` knows what was or will be valid at a point in time.

Agents should use those database surfaces rather than recreating lifecycle
logic in prompts, local code, or ad hoc SQL.

## Plans Versus Future Truth

Future work has two different knowledge shapes:

- A **plan** is current-visible knowledge about intended future work: target
  date, owner, status, dependencies, risks, and review gates.
- A **future-effective assertion** is accepted knowledge Rye should answer on
  or after its `effective_at` date.

For example, a project-management agent scheduling a launch milestone should
store the plan as current knowledge and the future milestone status as
future-effective knowledge. Before the cutover, current questions should still
return the current milestone status. As-of questions after the cutover should
return the scheduled future status.

Use plugin scheduling helpers where available:

- `schedule_deal_stage_change(...)`
- `schedule_task_status_change(...)`
- `schedule_milestone_status_change(...)`

These helpers write both the current-visible plan assertion and the scheduled
future assertion.

Onboarding should preserve changing business knowledge. Logs, source exports,
and connector traces are evidence. The durable setup record should say what the
organization is trying to improve, which source is authoritative for which
facts, what remains candidate-only, what evidence must be retained, and what
process constraint is being improved.

## Agent-Assisted Onboarding Modes

Agent-assisted onboarding has two supported modes. The same Rye concepts apply
in both modes, but the goal, allowed context, and success criteria differ.

### Real Onboarding

Use real onboarding when the user wants to set up Rye for an actual
organization, project, function, or workflow.

The agent should optimize for an accurate organizational store. It should:

- verify Rye is installed and plugin metadata is available
- ask the admin for the first limited workflow or organizational purpose
- create an `onboarding_scope` only after purpose, boundary, and owner are clear
- ask what source material means before connecting or classifying it
- define evidence, retention, inference, and review policies before promotion
- stop for user/admin input when organizational meaning is missing

Real onboarding succeeds when Rye contains a traceable scope and policy bundle
that reflects the organization's actual intent. Source metadata remains
provenance, not business truth, until the user/admin confirms its meaning.

### Development Evaluation

Use development evaluation when testing whether Rye skills, bootstrap paths,
CLI commands, subagents, and policy gates behave correctly during development.

The agent should optimize for behavioral evidence. It should:

- start from a clean consumer workspace
- install the Rye onboarding skill through the documented public path
- bootstrap Rye through the documented onboarding script
- inspect only installed skills, the cloned Rye repo, and the Rye datastore
- stop at each point where organization-specific context is required
- report what it installed, read, asked, inferred, refused to infer, and wrote

Development evaluation succeeds when the agent asks for missing scope context
instead of fabricating it, creates no source-derived facts before policy exists,
and produces actionable feedback about skill, bootstrap, CLI, or subagent
behavior.

In both modes, agents must not use prior demo notes, previous sessions, or
connector/source names as organizational truth unless those inputs are
explicitly supplied as fixture data or confirmed by the user/admin.

## Source Landscape Discovery

`Source Landscape Discovery` is a valid first onboarding scope when the user
wants Rye to understand what source material exists before choosing a narrower
business workflow.

This scope is metadata-first. Its purpose is to inventory source accounts,
containers, and limited source-item samples so Rye can recommend candidate
onboarding scopes for human review. It is not permission to categorize the
organization, ingest all content, or promote source-derived facts.

Use this scope to answer questions like:

- which Notion pages, databases, Slack channels, Outlook folders, or other
  containers exist
- which sources have recent activity, stale activity, or unknown activity
- which sources appear sensitive, private, legal, financial, or noisy
- which sources may deserve a later, narrower onboarding scope
- what context-confirmation questions a Rye admin should answer next

Allowed outputs:

- source inventory records
- provisional source categories such as source type, activity window,
  sensitivity, evidence value, and ingestion readiness
- candidate onboarding scopes
- source/context confirmation tasks
- retention and review-policy recommendations

Not allowed without explicit follow-up approval:

- accepted business facts
- semantic person, organization, customer, vendor, ownership, membership, or
  responsibility edges
- full-message, full-email, direct-message, private-channel, or attachment
  ingestion
- business meaning inferred only from a folder, channel, mailbox, or connector
  name

Recommended default boundaries:

- inventory public/shared source containers before private containers
- use a recent activity window, such as the last 90 days, unless the user asks
  for historical discovery
- inspect metadata before body content
- sample only enough source items to recommend candidate scopes
- route uncertain or unexpected material to context confirmation rather than
  accepting it as knowledge

## CLI-First Flow

Use the CLI to create the first scope after installation:

```bash
./scripts/rye onboard create \
  --label "Lead Follow-Up" \
  --purpose "Track follow-up for a limited lead workflow."
```

The command records default policy assertions, enables starter plugins, and
activates the scope. Then use:

```bash
./scripts/rye context --json
```

This returns `rye_agent_context()`, a portable context bundle with catalog,
plugin, skill, capability, source, scope, and policy data for agents.

## Source, Channel, and Context

Do not collapse source identity, retrieval channel, and business context.

- `source_account`, `source_container`, and `source_item` describe where the
  material originated.
- `retrieval_channel` describes how Rye retrieved or observed the material:
  Composio, a native plugin, a direct API, an export, a log replay, or a local
  file import.
- `intake_profile` describes how a source/channel should be collected,
  classified, retained, and promoted for a scope.

Slack is the canonical example. A workspace is a `source_account`, a channel is
a `source_container`, and messages or threads are `source_item` records. A Slack
channel may have one purpose, many purposes, or no reliable purpose. Therefore
the profile stores `expected_contexts`, not a hard context whitelist.

## Scope Naming

Name an onboarding scope after the organizational context Rye is helping with:
the project, function, workflow, process, or purpose. Do not name it after the
source, retrieval channel, connector, or implementation phase unless that is
the actual organizational context.

For example, use `Example Project`, not `Example Slack Pilot`. Slack should be
modeled as a `source_container`, and Composio should be modeled as a
`retrieval_channel`. The intake profile can then describe how that Slack
channel contributes evidence to the Example Project scope.

If a source name is the only available clue, keep the source unconfirmed and
route items to a holding context until a Rye admin identifies the real domain
purpose.

## Expected Contexts and Context Gaps

`expected_contexts` are known safe routing expectations for a source/profile.
They are not the only possible contexts.

When a source item does not match expected contexts, Rye should not fail or
silently discard it. It should route the item to the configured
`holding_context` or create a `context_gap` candidate according to
`unexpected_context_policy`.

Typical context-gap reasons:

- `ambiguous_between_expected_contexts`
- `unexpected_but_in_scope`
- `possible_new_context`
- `outside_current_scope`
- `insufficient_evidence`
- `noise_or_low_signal`
- `blocked_by_policy`

Repeated context gaps can create a `scope_revision_proposed` event, but they do
not automatically change the active scope policy.

## Plugin Metadata

Plugins define available vocabulary and behavior. Core Rye remains small.

Initial plugin priorities:

1. `rye-source-context`
2. `rye-evidence-anchor`
3. `rye-tabular-intake`
4. `rye-change-tracking`
5. `rye-logging`
6. `rye-org`
7. `rye-crm`
8. `rye-project-management`

`rye-org` is foundational but still non-core. It defines vocabulary for people,
systems, departments, mission, vision, goals, related organizations, policies,
and procedures. Many onboarding scopes will need this before CRM or project
management concepts make sense.

## Helper Functions

Migration `0010_onboarding_scope_plugins.sql` adds convention helpers:

- `create_onboarding_scope(...)`
- `record_scope_policy(...)`
- `record_source_of_truth_policy(...)`
- `record_improvement_cycle(...)`
- `register_scope_convention(...)`
- `enable_plugin_for_scope(...)`
- `compile_scope_policy(...)`
- `activate_onboarding_scope(...)`
- `validate_candidate_against_scope(...)`
- `create_context_gap_candidate(...)`
- `propose_scope_revision_from_context_gap(...)`

These helpers use existing Rye tables. They create nodes, edges, assertions,
and events; they do not add new core tables.

Migration `0013_onboarding_knowledge_policies.sql` adds focused policy helpers
for agent-guided setup:

- `record_source_of_truth_policy(...)` stores an authority matrix entry for a
  status or fact domain, including effective date, review gate, allowed
  evidence, and superseded source/policy.
- `record_improvement_cycle(...)` stores the reviewed process-improvement loop:
  goal, current constraint, `Identify`, `Exploit`, `Subordinate`, `Elevate`,
  `Repeat`, metrics, and next likely constraint.
- `register_scope_convention(...)` stores lightweight local vocabulary guidance
  with label, aliases, use/avoid rules, status, and optional plugin owner.

Use these helpers before broad source ingestion when the scope depends on
source authority, recurring business-process improvement, or repeated local
terms that fresh agents need to reuse.

Migration `0011_portability_catalog.sql` adds discovery helpers:

- `rye_plugin_catalog()`
- `rye_skill_catalog()`
- `rye_capability_catalog()`
- `rye_source_inventory()`
- `rye_pending_context_confirmations()`
- `rye_agent_context(scope_id)`

These helpers make installed plugins, skills, capabilities, sources, active
scopes, and selected policy bundles portable across CLI users and agents.

## Minimal Flow

```sql
SELECT create_onboarding_scope(
  p_scope_key := 'example:lead-followup',
  p_label     := 'Lead Follow-Up',
  p_purpose   := 'Track follow-up from a limited lead workflow.',
  p_boundary  := '{"in_scope": ["lead follow-up"], "out_of_scope": ["full CRM"]}',
  p_owner     := 'casey'
);

SELECT record_scope_policy(
  p_scope_id    := '<scope_uuid>',
  p_policy_type := 'expected_contexts',
  p_claim       := '{"contexts": ["lead_followup"]}'
);

SELECT record_scope_policy(
  p_scope_id    := '<scope_uuid>',
  p_policy_type := 'retention_policy',
  p_claim       := '{"default_retention_class": "review_window"}'
);

SELECT enable_plugin_for_scope(
  p_scope_id  := '<scope_uuid>',
  p_plugin_id := 'rye-source-context'
);

SELECT activate_onboarding_scope('<scope_uuid>');
```

Use `compile_scope_policy('<scope_uuid>')` to produce the active policy bundle
for collector and classifier agents.
