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

For example, use `Glamies Project`, not `Glamies Slack Pilot`. Slack should be
modeled as a `source_container`, and Composio should be modeled as a
`retrieval_channel`. The intake profile can then describe how that Slack
channel contributes evidence to the Glamies project scope.

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
- `enable_plugin_for_scope(...)`
- `compile_scope_policy(...)`
- `activate_onboarding_scope(...)`
- `validate_candidate_against_scope(...)`
- `create_context_gap_candidate(...)`
- `propose_scope_revision_from_context_gap(...)`

These helpers use existing Rye tables. They create nodes, edges, assertions,
and events; they do not add new core tables.

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
