# Rye Conventions Catalog

## Type Conventions

Types are open conventions — write a new value and it exists, no migration required.

- **Node types** (`node_type`): `person`, `org`, `project`, `task`, `opportunity`, `pipeline`, `ticket`, `parcel`, `document`, `incident`, `release`, `component`, `product`
- **Edge types** (`edge_type`): `employs`, `assigned_to`, `project_member`, `blocks`, `depends_on`, `regarding`, `applied_to`, `targets`, `references`, `affects`, `triggered_by`, `contains`, `impacted`, `owns`, `adjacent_to`
- **Assertion types** (`assertion_type`): `project_status`, `task_status`, `deal_stage`, `health_score`, `churn_risk`, `sentiment`, `ownership`, `title_opinion`, `interview_feedback`, `candidate_stage`, `ticket_status`, `decision_status`
- **Event types** (`event_type`): `meeting`, `phone_call`, `email`, `escalation`, `incident_update`, `interview`, `agent_query`, `domain_change`, `task_created`, `status_change`, `comment`, `time_log`, `dispute_raised`, `dispute_resolved`, `opportunity_created`, `node_merge`

Run `SELECT rye_catalog()` to see which types are in use in a given instance.

## Assertion Key Convention

Use `assertion_key` to define uniqueness scope for active facts:

- **Single-valued facts**: `assertion_key = 'default'`
  - Examples: `task_status`, `deal_stage`, `project_status`, `health_score`, `churn_risk`
  - Supersede with `supersede_assertion(...)`
- **Multi-valued facts**: use a stable domain key
  - `ownership` keyed by `owner:<node_id>`
  - `candidate_stage` keyed by `role:<opportunity_code>`
  - `interview_feedback` keyed by `round:<round_name>`

The unique index on `(assertion_type, assertion_key, subject_node_id) WHERE superseded_at IS NULL` prevents duplicate active facts for the same key.

## Assertion Write Convention

- INSERT assertions directly (subject to RLS and assertion-type gating).
- Assertion content is immutable after insert. Only `superseded_at` and `superseded_by` may be updated.
- Use `supersede_assertion(...)` to replace single-valued facts when you're certain the new value is correct.
- Use `contest_assertion(...)` when contradictory information arrives but you're uncertain which is correct. Both claims coexist until resolved.
- Use `resolve_dispute(...)` to pick a winner among competing assertions.
- Do not run direct `UPDATE assertions` — RLS blocks it outside the supersession function context.

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
