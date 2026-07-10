# Rye Conventions Catalog

## Type Conventions

Types are open conventions — write a new value and it exists, no migration required.

- **Node types** (`node_type`): `person`, `org`, `project`, `task`, `opportunity`, `pipeline`, `ticket`, `parcel`, `document`, `incident`, `release`, `component`, `product`
- **Edge types** (`edge_type`): `employs`, `assigned_to`, `project_member`, `blocks`, `depends_on`, `regarding`, `applied_to`, `targets`, `references`, `affects`, `triggered_by`, `contains`, `impacted`, `owns`, `adjacent_to`
- **Assertion types** (`assertion_type`): `project_status`, `task_status`, `deal_stage`, `health_score`, `churn_risk`, `sentiment`, `ownership`, `title_opinion`, `interview_feedback`, `candidate_stage`, `ticket_status`, `decision_status`
- **Event types** (`event_type`): `meeting`, `phone_call`, `email`, `escalation`, `incident_update`, `interview`, `agent_query`, `domain_change`, `task_created`, `status_change`, `comment`, `time_log`, `dispute_raised`, `dispute_resolved`, `opportunity_created`, `node_merge`, `node_properties_updated`

Onboarding and plugin metadata add convention-owned infrastructure types:

- **Node types:** `onboarding_scope`, `intake_profile`, `retrieval_channel`, `intake_run`, `plugin`
- **Edge types:** `scope_uses_profile`, `scope_enables_plugin`, `scope_applies_to_source`, `scope_uses_retrieval_channel`, `retrieved_via`, `observed_in_run`, `expected_by_profile`, `scope_has_context_gap`
- **Assertion types:** `scope_status`, `scope_purpose`, `scope_boundary`, `scope_owner`, `expected_contexts`, `holding_context`, `unexpected_context_policy`, `blocked_contexts`, `retention_policy`, `evidence_policy`, `review_gate`, `agent_autonomy_policy`, `accepted_knowledge_policy`, `source_of_truth_policy`, `process_constraint`, `process_metric`, `improvement_cycle`, `convention_registry`, `plugin_policy_binding`
- **Event types:** `onboarding_started`, `scope_policy_recorded`, `plugin_policy_bound`, `onboarding_completed`, `scope_revision_proposed`

Governed process and conversation-source patterns add:

- **Node types:** `source_identity`
- **Edge types:** `identity_of`, `holds_role`
- **Assertion types:** `source_identity_confirmation`, `process_definition`, `process_transition_policy`, `observed_process_transition`
- **Event types:** `source_identity_confirmed`, `process_transition_evaluated`, `process_exception_approved`, `observed_process_transition_aggregated`

Run `SELECT rye_catalog()` to see which types are in use in a given instance.

## Onboarding Scope Convention

Rye onboarding is scope-first. A Rye instance usually starts by assisting one
limited function or workflow. Store that setup as an `onboarding_scope` node,
not as an organization-wide assumption.

Name the scope after the organizational context, not the source or retrieval
channel. Use labels such as `Example Project` or `Lead Follow-Up`; avoid labels
such as `Example Slack Pilot` or `Composio Email Intake` unless Slack or
Composio is itself the process being modeled.

Use `expected_contexts` instead of hard context whitelists. Expected contexts
are known safe routing expectations for a source/profile. If source material
does not match, route it to a `holding_context` or create a `context_gap`
candidate according to `unexpected_context_policy`.

Use `blocked_contexts` and `never_infer` for hard boundaries.

The implementation reference lives in:

- `docs/onboarding.md`
- `schema/migrations/0010_onboarding_scope_plugins.sql`
- `schema/migrations/0013_onboarding_knowledge_policies.sql`

## Convention Registry Pattern

Use `convention_registry` assertions when a scope has repeated local vocabulary
that agents should reuse, but the pattern is not stable enough to become a full
plugin.

Each registered convention should include:

- `label`
- `aliases`
- `description`
- `use_when`
- `avoid_when`
- `status`: `observed`, `proposed`, `accepted`, `deprecated`, or
  `plugin_owned`
- optional `owning_plugin_id`

Use `register_scope_convention(...)` to write the assertion. Prefer this over
letting fresh agents infer semantics from existing node or edge labels alone.

## Source Of Truth Policy Pattern

Use `source_of_truth_policy` assertions to say which source is authoritative
for a specific status or fact domain.

Each policy should include:

- `status_domain`
- `authoritative_source`
- `effective_at`
- `review_gate`
- `evidence_allowed`
- `supersedes`
- `notes`

Use `record_source_of_truth_policy(...)` during onboarding when source authority
is part of the setup. Source names, connector names, folder names, channel
names, or logs are never authority by themselves.

## Process Improvement Cycle Pattern

Use `improvement_cycle` assertions when a scope is about improving an
organizational process. The pattern follows the constraint-oriented improvement
loop:

- `goal`
- `Identify`: current constraint
- `Exploit`: how to get the most from the current constraint
- `Subordinate`: what other work must align to the constraint
- `Elevate`: when and how to add capacity or change the system
- `Repeat`: when to inspect the next constraint
- `metrics`
- `next_constraint`

Use `record_improvement_cycle(...)` to store the cycle. The helper also records
a `process_constraint` assertion for the current constraint. Logs and traces may
support the metrics, but the durable assertion is the reviewed business
knowledge about the process.

## Governed Process Transition Pattern

Use `process_definition` and `process_transition_policy` assertions when an
agent must interpret state changes against an accepted process rather than
copying every source statement into current state.

- The stable process node may be a `pipeline`, `procedure`, or another
  plugin-owned process type.
- `process_definition` uses key `default` and records the states, initial state,
  terminal states, and domain assertion type that holds accepted state.
- `process_transition_policy` uses key `transition:<transition_key>` and records
  allowed source states, target state, proposing and deciding authorities,
  prerequisites, evidence, exception handling, impact, and reversibility.
- `observed_process_transition` uses key
  `observed:<from_state>:<to_state>:<window_start>:<window_end>` and records
  evidenced occurrences in one closed window. It is descriptive and never
  binds the promotion evaluator.
- Process assertions are temporal. Supersede them when the process changes.
- Normalize observed and authoritative transitions to
  `(process_key, from_state, to_state)` for comparison. Their claim shapes,
  keys, and supersession lineages remain distinct.
- Source observations and events can accumulate before an authoritative
  process exists. A derived observed aggregate still follows candidate and
  promotion policy; descriptive claims do not receive an implicit lenient
  default.
- Record each aggregate with an
  `observed_process_transition_aggregated` source event containing complete
  evidence references (or an artifact that does). `sample_event_ids` are only
  examples. Late evidence uses `supersede_assertion()` for the same full window
  key; an authoritative process assertion never supersedes an observed one.

Use a confirmed temporal `holds_role` edge and `domain_authorities` to resolve
whether a person may propose, decide, approve an exception, or set policy. Do
not derive authority from titles or conversational behavior.

The full contract and claim schemas live in:

- `plugins/rye-org/patterns/governed-process-transition.md`
- `plugins/rye-org/schemas/process_definition_claim.schema.json`
- `plugins/rye-org/schemas/process_transition_policy_claim.schema.json`
- `plugins/rye-org/schemas/observed_process_transition_claim.schema.json`

## Slack Conversation Evidence Pattern

Slack is a source hierarchy and evidence stream:

- workspace -> `source_account`
- channel -> `source_container`
- relevant message or thread -> `source_item`
- workspace user -> `source_identity`

Use a confirmed `identity_of` edge to map a stable provider identity to a
person. Display names, channel membership, and message content are not identity
or authority.

Keep provider occurrence, edit, deletion, and retrieval times distinct. A
candidate's business-effective time and date quality are separate semantic
interpretations. Conversation may propose operational state, procedures, and
authority changes, but all use the normal candidate and promotion lifecycle.

The full contract and message schema live in:

- `plugins/rye-source-context/patterns/slack-conversation-evidence.md`
- `plugins/rye-source-context/schemas/slack_conversation_source_item.schema.json`

## Pattern Library Convention

When a domain needs repeatable modeling guidance but not a core migration, define a pattern contract before writing implementation SQL.

A pattern contract should describe:

- node, edge, assertion, event, and artifact type values
- required and optional JSONB fields
- assertion keying and supersession rules
- provenance and artifact rules
- security and classification expectations
- example writes and conformance checks

The pattern library skill provides reusable templates and schema guidance:

- `skills/rye-pattern-library/SKILL.md`

## Assertion Key Convention

Use `assertion_key` to define uniqueness scope for active facts:

- **Single-valued facts**: `assertion_key = 'default'`
  - Examples: `task_status`, `deal_stage`, `project_status`, `health_score`, `churn_risk`
  - Replace with `record_assertion(...)` for normal accepted writes
- **Multi-valued facts**: use a stable domain key
  - `ownership` keyed by `owner:<node_id>`
  - `candidate_stage` keyed by `role:<opportunity_code>`
  - `interview_feedback` keyed by `round:<round_name>`

Rye enforces active uniqueness by subject, assertion type, assertion key, and
effective window. This allows a current row and a scheduled future row for the
same key to coexist without making future knowledge current too early.

## Assertion Write Convention

- Prefer `record_assertion(...)` for accepted assertions. It handles current,
  historical, candidate, and future-effective writes consistently.
- Assertion content is immutable after insert. Only lifecycle metadata and
  effective-window narrowing may be updated by Rye helper functions.
- Use `supersede_assertion(...)` only when replacing a known assertion by id and
  you do not need future-scheduling behavior.
- Use `contest_assertion(...)` when contradictory information arrives but you're uncertain which is correct. Both claims coexist until resolved.
- Use `resolve_dispute(...)` to pick a winner among competing assertions.
- Do not run direct `UPDATE assertions` — RLS blocks it outside the supersession function context.

## Future Assertion And Planning Pattern

Use this pattern when an accepted future change should be visible for planning
but not treated as current truth.

1. Store the plan as current-visible knowledge.
   - Examples: `deal_stage_plan`, `task_status_plan`,
     `milestone_status_plan`.
   - Include owner, target/effective date, status, dependencies, risks, and
     the scheduled assertion id when available.
2. Store the future truth as a future-effective assertion.
   - Use the same `assertion_key` as the current fact it will replace.
   - Set `effective_at` to the cutover date.
   - Let `record_assertion(...)` close the current row's `effective_to`.
3. Read current truth from `current_valid_assertions`.
4. Read future or historical truth from `assertions_as_of(...)`.

Use CRM/PM helpers when available:

- `schedule_deal_stage_change(...)`
- `schedule_task_status_change(...)`
- `schedule_milestone_status_change(...)`

Do not report a plan as already true. A plan says "we intend this"; the
future-effective assertion says "Rye should answer this as true at that time."

## Assertion Dispute Convention

When new information contradicts an existing assertion but the correct answer is uncertain:

1. Call `contest_assertion(existing_id, new_claim, source, confidence, reason)`.
2. The competing assertion uses `assertion_key = 'contested:<source>'` so both coexist.
3. A `dispute_raised` event is recorded for audit.
4. Query `active_disputes` to find all unresolved conflicts.
5. Call `resolve_dispute(winning_assertion_id, reason, actor)` to resolve.
6. A `dispute_resolved` event is recorded. Losers are superseded. If the winner had a `contested:` key, it's promoted to `default`.

```sql
-- Contest an existing ownership assertion
SELECT contest_assertion(
    p_existing_assertion_id := '<assertion_uuid>',
    p_new_claim             := '{"fraction": 0.125}',
    p_source                := 'county_filing_2024_0892',
    p_confidence            := 0.7,
    p_reason                := 'County filing shows different fraction'
);

-- Find unresolved disputes
SELECT * FROM active_disputes;

-- Resolve in favor of the contested assertion
SELECT resolve_dispute(
    p_winning_assertion_id := '<contested_assertion_uuid>',
    p_reason               := 'Confirmed by title examiner',
    p_actor                := 'user:alice'
);
```

## Artifact Convention

- Use `record_artifact()` for all artifact creation.
- Pass `p_content_hash` to prevent duplicate artifacts from the same source material.
- If a matching artifact exists (same type and content hash), returns the existing ID.
- Agents can create artifacts (INSERT is allowed for all roles).

```sql
SELECT record_artifact(
    p_artifact_type   := 'document_parse',
    p_content         := '{"title": "Q4 Report", "sections": [...]}',
    p_source_event_id := '<parse_event_uuid>',
    p_source_node_id  := '<document_node_uuid>',
    p_content_hash    := 'sha256:abc123...'
);
```

## Tabular Intake Convention

When source data arrives as CSV or XLSX files instead of live domain tables:

- inspect first, then confirm mappings with the user before writing transforms
- keep extraction lossless by preserving source column names and raw row values
- use NDJSON as the interchange format between extract, map, and stage steps
- treat `tabular_commit_rye.mts` as the only database write boundary
- use `run_id` as the run identity and `run_fingerprint_sha1` as duplicate protection
- reject repeated source content by default unless the operator explicitly allows a replay

The reference implementation for this convention lives in:

- `skills/rye-tabular-intake/SKILL.md`

## Event Convention

- Use `record_event()` for all event creation. Never insert into `events` and `event_participants` separately.
- Every event should have at least one participant. Events with no participants are invisible under RLS.
- Use `p_actor` to identify who or what caused the event (e.g., `'user:alice'`, `'agent:triage-bot'`, `'system:cdc'`).
- Events are immutable — never update or delete them.

## Classification Convention

- Nodes with `attrs->'teams'` (non-empty array) **must** have `attrs->>'classification'` set.
- The classification enforcement trigger rejects nodes with teams but no classification.
- Valid classification values: `internal`, `confidential`, `restricted` (or other domain-appropriate values).
- Nodes without teams or classification are public — visible to all users.

```sql
-- Team-scoped node (classification required)
INSERT INTO nodes (node_type, label, attrs)
VALUES ('task', 'Build feature X',
    '{"classification": "internal", "teams": ["engineering"]}');

-- Public node (no classification needed)
INSERT INTO nodes (node_type, label, properties)
VALUES ('pipeline', 'Sales Pipeline', '{"code": "PL-SALES"}');
```

## Node Property Update Convention

When the graph node IS the system of record (no backing domain table), use `update_node_properties()` to update its properties. This is the only way agents can modify nodes — direct `UPDATE nodes` is blocked by RLS.

- Properties are merged via `||` (new keys overlay old, existing keys preserved).
- Optionally updates `label` if provided.
- Returns the UUID of a `node_properties_updated` audit event with `changed_fields` containing `properties_before`, `properties_after`, `properties_added`, and optionally `label_before`/`label_after`.
- Archived nodes raise an exception.

```sql
SELECT update_node_properties(
    p_node_id    := '<node_uuid>',
    p_properties := '{"email": "jane@new.com", "title": "VP Engineering"}',
    p_summary    := 'Updated contact info from sales call'
);
```

For nodes backed by a domain table, update the domain table instead — CDC will propagate the change via `domain_change` events.

## Domain Integration Convention

Domain tables are the system of record. Rye connects them without modifying them.

- Use `link_record(schema, table, id, node_type, label, properties)` to connect domain table rows to the graph. Each distinct `source_id` creates a new node; same `(schema, table, source_id)` updates the existing one. Looks up `node_source_map` first, then `external_id`/`external_source`.
- Use `link_records_batch(schema, table, ids[], type, labels[], properties[])` for bulk imports — processes multiple records in a single call.
- Use `track_table(schema, table)` to attach CDC triggers for automatic change tracking. Supports tables with any PK column name.
- CDC events have type `domain_change` and include `changed_fields` with before/after diffs.
- Only rows with a linked node (in `node_source_map`) produce CDC events. Unlinked rows are silently skipped.

## Human-Readable Code Convention

Codes follow the format `{PREFIX}-{YYMM}-{SEQ}` (e.g., `OPP-2403-0042`, `TSK-2403-0187`).

- Generated by `generate_crm_code(prefix)`.
- Counters reset per prefix per month.
- Concurrency-safe via `INSERT ... ON CONFLICT DO UPDATE`.

## Edge Temporal Convention

- Active edges: `archived_at IS NULL`.
- Temporal bounds: `effective_from` / `effective_to`.
- To end a relationship, set `archived_at` or `effective_to`. Do not delete edges.

## Soft Delete Convention

- All core tables use `archived_at` for soft deletion.
- `archived_at IS NULL` = active.
- Views and queries filter on `archived_at IS NULL` by default.

## Session Variable Convention

Authorization uses session variables, not database roles:

```sql
SET LOCAL "app.current_user_id" = 'user:alice';
SET LOCAL "app.current_teams"   = 'engineering,sales';
SET LOCAL "app.current_role"    = 'team_member';
```

Role hierarchy: `admin > manager > team_member > viewer > agent`.

## View Convention

All views must use `security_invoker = true` (PostgreSQL 15+) so that RLS policies are evaluated using the calling session's permissions.

| View | Purpose |
|---|---|
| `current_assertions` | Non-superseded assertions only |
| `node_context` | Full node context with edges and assertions |
| `nodes_secure` | Nodes with field-level redaction applied |
| `active_disputes` | Subjects with competing active assertions |

## Materialized View Convention

Profile materialized views (`opportunities_active`, `contacts_directory`, `task_board`) need periodic refreshing.

- Use `refresh_materialized_views()` to refresh all installed profile views.
- Uses `CONCURRENTLY` — reads continue during refresh.
- Safe to call regardless of which profiles are installed.

## Security Configuration Convention

Security gating is data-driven. To add a new sensitive assertion type or role:

- Insert into `assertion_type_access` to gate read/write on specific assertion types.
- Insert into `role_classification_access` to define which classification levels a role can access.
- No SQL policy changes or migrations needed for new types or roles.

## Profiles

- CRM profile: `schema/migrations/0100_profile_crm.sql`
- PM profile: `schema/migrations/0110_profile_pm.sql`
- Profile migrations use `*_profile_<name>.sql` naming.
- Enable during install with `--profiles crm,pm`.
