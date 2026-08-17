# Rye Conventions Catalog

## Type Conventions

Types are open conventions — write a new value and it exists, no migration required.

- **Node types** (`node_type`): `person`, `org`, `project`, `task`, `opportunity`, `pipeline`, `ticket`, `parcel`, `document`, `incident`, `release`, `component`, `product`
- **Edge types** (`edge_type`): `employs`, `assigned_to`, `project_member`, `blocks`, `depends_on`, `regarding`, `applied_to`, `targets`, `references`, `affects`, `triggered_by`, `contains`, `impacted`, `owns`, `adjacent_to`
- **Assertion types** (`assertion_type`): `project_status`, `task_status`, `deal_stage`, `health_score`, `churn_risk`, `sentiment`, `ownership`, `title_opinion`, `interview_feedback`, `candidate_stage`, `ticket_status`, `decision_status`
- **Event types** (`event_type`): `meeting`, `phone_call`, `email`,
  `escalation`, `incident_update`, `interview`, `agent_query`,
  `domain_change`, `task_created`, `status_change`, `comment`, `time_log`,
  `assertion_accepted`, `candidate_rejected`, `distillation`,
  `knowledge_gap_resolved`, `opportunity_created`, `node_merge`, and
  `node_properties_updated`

Onboarding and plugin metadata add convention-owned infrastructure types:

- **Node types:** `onboarding_scope`, `intake_profile`, `retrieval_channel`, `intake_run`, `plugin`
- **Edge types:** `scope_uses_profile`, `scope_enables_plugin`, `scope_applies_to_source`, `scope_uses_retrieval_channel`, `retrieved_via`, `observed_in_run`, `expected_by_profile`, `scope_has_context_gap`
- **Assertion types:** `scope_status`, `scope_purpose`, `scope_boundary`, `scope_owner`, `expected_contexts`, `holding_context`, `unexpected_context_policy`, `blocked_contexts`, `retention_policy`, `evidence_policy`, `review_gate`, `agent_autonomy_policy`, `accepted_knowledge_policy`, `source_of_truth_policy`, `process_constraint`, `process_metric`, `improvement_cycle`, `convention_registry`, `plugin_policy_binding`
- **Event types:** `onboarding_started`, `scope_policy_recorded`, `plugin_policy_bound`, `onboarding_completed`, `scope_revision_proposed`

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

- Use `record_assertion(...)` for accepted and candidate assertions. Pass
  `status`, `basis`, and `evidence`. Evidence is required unless the basis is
  `assumed`.
- Assertion content is immutable after insert. Only lifecycle metadata and
  effective-window narrowing may be updated by Rye helper functions.
- Use `accept_assertion(...)` and `reject_candidate(...)` for review.
- Use `supersede_assertion(...)` only for a same-subject, same-type,
  same-key replacement by id.
- Do not run direct `UPDATE assertions` — RLS blocks it outside the supersession function context.

## Future Assertion And Planning Pattern

Use this pattern when an accepted future change should be visible for planning
but not treated as current truth.

1. Store the future truth as a future-effective assertion.
   - Use the same `assertion_key` as the current fact it will replace.
   - Set `effective_at` to the cutover date.
   - Call `schedule_assertion_change(...)`; it closes the current row's
     `effective_to`.
2. Read current truth from `current_valid_assertions`.
3. Read future or historical truth from `assertions_as_of(...)`.

Do not report a plan as already true. A plan says "we intend this"; the
future-effective assertion says "Rye should answer this as true at that time."

## Candidate Review Convention

When new information contradicts an existing assertion but the correct answer is uncertain:

1. Insert the new claim with `status = 'candidate'` and the normal domain key.
2. Put every provenance link in `assertion_evidence`.
3. Query `review_queue`; use `competing_candidates` for tuples with multiple
   candidates.
4. Call `accept_assertion(...)` on the winner.
5. Call `reject_candidate(...)` on candidates ruled out.

Candidates remain invisible to operational reads throughout review.

## Evidence Convention

- `source` and `corroboration` evidence reference events.
- `derivation` evidence references source assertions.
- Set `witness_node_id` when the source has an identifiable witness.
- Repeated evidence from one witness is auditable but does not increase
  effective confidence.
- Evidence rows are append-only and inherit visibility from both ends.
- Derivations inherit the maximum source classification and reject
  mixed-access sources.

## Registry and Confidence Convention

- Store defaults as accepted `registry_entry` assertions.
- Resolve `half_life:<assertion_type>`, `basis_prior:<basis>`, and
  `digest_facets:<node_type>` with `registry_value(key, scope)`.
- Precedence is scope override, plugin default, then core default.
- Read calculated belief from `current_assertions_weighted`.
- Never overwrite stored confidence to represent decay or corroboration.

## Scope Coverage And Review Policy Convention

Active onboarding scopes declare durable coverage without adding a table:

- `scope_governs_subject`: scope → governed subject. A governed process or
  project also covers its immediate `has_step` children.
- `scope_governs_source`: scope → person, connector, or system witness.
- `governed_type:<assertion_type>`: a scope-level `registry_entry` marking an
  assertion type as governed.
- `DEFAULT_SCOPE`: a core registry value containing the fallback scope UUID.

`governing_scope()` resolves subject coverage first, then type, source, and the
default. Edge subjects check the source endpoint before the target endpoint.
Two active scopes claiming the same type are an error. An explicit helper
scope must match the resolved scope when both exist.

Store `review_policy` on the scope with one of these values:

- `open`: preserve accepted writes.
- `candidates_only`: force non-observed writes to candidates.
- `strict`: force every write to a candidate.

Agents need `rye.authoritative.promote` to accept candidates under
`candidates_only` or `strict`. Non-agent reviewers may accept them directly.

## Type Alias Convention

Store aliases as `registry_entry` assertions with key
`type_alias:<kind>:<deprecated_value>` and the canonical string in
`claim.value`. `kind` is `node_type`, `edge_type`, or `assertion_type`.

`canonical_type()` follows alias chains and raises on cycles. New helper writes
use the canonical value. Existing rows retain their stored spelling. Read
historical vocabulary and canonical mappings from `type_vocabulary_report`.
Near-duplicate detection stays in the gardener skill; no similarity extension
is required in PostgreSQL. Alias activation and `merge_nodes()` remain
human-reviewable actions.

## Identity Key Convention

Declare what makes a node type the same entity with a `registry_entry`
assertion keyed `identity_keys:<node_type>`, whose `claim.value` is an array:

```json
[{"property": "email",   "normalize": "lower"},
 {"property": "website", "normalize": "domain"}]
```

Normalizers are `trim`, `lower`, `digits_only`, and `domain`. An unknown
normalizer raises. Keep the set boring: every normalizer is a permanent
semantic commitment, because changing it rewrites what "matched" meant for
everything already resolved on its basis.

A node matching **any** declared key is an exact candidate. Matching more than
one node is `ambiguous`, not a merge.

`identity_threshold:<node_type>` sets the trigram floor for label similarity
(default 0.45, floored at the `pg_trgm.similarity_threshold` GUC). Label
similarity only ever produces `ambiguous`.

Resolution is advisory. `resolve_node_identity()` is a read; agents decide and
route ambiguity to review. Deterministic resolution belongs only where the
process is predefined — tabular imports with a declared key, `link_record()`
mirroring of a domain table, connector syncs with stable external ids.

## Outcome Label Convention

Reputation uses explicit outcomes, not ordinary supersession:

- accepting one candidate labels other live candidates `displaced`;
- `reject_candidate(..., p_outcome => ...)` accepts `incorrect`,
  `unsupported`, `duplicate`, or `stale`;
- `accept_assertion(..., p_supersedes_as => 'correction')` labels the
  incumbent `corrected`; the default `update` is neutral.

Only `incorrect`, `unsupported`, `corrected`, and scored-incorrect predictions
reduce source reliability. `source_reliability` is derived at read time. Fewer
than five witnessed claims is a low sample, so effective confidence does not
apply a reputation discount yet. The discount can halve a prior, never zero it.

## Prediction Convention

Predictions use `assertion_type = 'prediction'`. Their claim contains
`question`, `outcome_key`, `predicted_value`, `probability`, and `horizon`.
Use `record_prediction()` so the shape, probability, inferred basis, witness,
and provenance event are validated together.

A prediction is a probabilistic statement on its own tuple. It never occupies
the tuple named by `outcome_key`. `score_due_predictions()` reads that outcome
through `assertions_as_of()` at the horizon and labels the prediction
`correct`, `incorrect`, or `unresolvable`. Unresolvable rows are excluded from
`calibration_report`.

Do not use a prediction for an accepted future-effective assertion. A
future-effective assertion says what Rye should treat as true at that time; a
prediction says how likely an outcome is and is eligible for calibration.

## Pattern Induction Convention

`record_pattern()` creates a `pattern` node and a candidate `pattern_claim`
assertion. It requires derivation evidence from at least three distinct
subjects. Evidence with `attrs.contradicts = true` is counter-evidence and is
counted separately in `pattern_support`.

Direct accepted `pattern_claim` writes are refused. A human or an agent with
`rye.authoritative.promote` must accept the candidate. Later inferences may
cite an accepted pattern as derivation evidence, but their effective confidence
is capped by the pattern's confidence for one derivation hop. Deeper chains are
not propagated.

## Artifact Convention

- Use `record_artifact()` for all artifact creation.
- Pass `p_content_hash` to prevent duplicate artifacts from the same source material.
- If a matching artifact exists (same type and content hash), returns the existing ID.
- Agents can create artifacts (INSERT is allowed for all roles).
- Digest narrative artifacts inherit and enforce the linked digest assertion's
  classification.

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
| `current_valid_assertions` | Accepted, live, effective-now assertions |
| `current_assertions_weighted` | Current assertions with effective confidence |
| `node_context` | Full node context with edges and assertions |
| `nodes_secure` | Nodes with field-level redaction applied |
| `review_queue` | Live candidates grouped by assertion tuple |
| `competing_candidates` | Tuples with more than one live candidate |
| `stale_digests` | Digests invalidated by newer knowledge or displaced sources |
| `node_salience` | Advisory query attention from logged agent reads |
| `type_vocabulary_report` | Stored type vocabulary and canonical aliases |
| `source_reliability` | Fresh witness outcomes and low-sample status |
| `calibration_report` | Scored prediction calibration by witness and bucket |
| `pattern_support` | Pattern support, contradictions, and distinct subjects |
| `open_gaps` | Accepted unresolved knowledge gaps |
| `assertion_support` | Visible evidence bundle |

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
