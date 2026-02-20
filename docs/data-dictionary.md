# Rye Data Dictionary

Every table, view, and function in the Rye schema — what it does and why it exists. All objects live in the `rye` schema (except `rye_migrations` which stays in `public`). Set `search_path = rye, public, pg_catalog` before querying.

---

## Tables

### Core Tables

#### `nodes` — Entities

Every trackable entity is a node. People, companies, projects, tickets, parcels, documents — all differentiated by `node_type`. This is the central vertex table of the graph.

**Why it exists:** Operational systems store entities in separate tables that don't know about each other. Nodes give every entity a single identity that relationships, events, and facts can reference across systems. The `external_id` / `external_source` columns allow the same node to be traced back to its origin system without modifying that system.

**Key columns:** `node_type` (open convention — no migration needed for new types), `properties` (domain data as JSONB), `attrs` (system metadata: classification, teams), `archived_at` (soft delete).

#### `edges` — Relationships

Directed relationships between nodes with optional temporal bounds and weights.

**Why it exists:** The relationships between entities (who works where, which ticket is about which customer, which task blocks which task) are often more valuable than the entities themselves. These relationships live in different systems and are invisible to each other. Edges make them explicit and queryable.

**Key columns:** `edge_type` (open convention), `source_id` / `target_id` (directionality), `effective_from` / `effective_to` (temporal bounds), `weight` (relevance ranking), `archived_at` (soft delete — use instead of deletion).

#### `events` — Activity Log

Immutable record of things that happened. Never modified or deleted.

**Why it exists:** Knowing what happened and when is essential for context reconstruction, audit trails, and agent reasoning. An event captures a phone call, a status change, a data import, an agent query — anything that occurred at a point in time. Events are append-only because history should not change.

**Key columns:** `event_type` (open convention), `occurred_at` (when it actually happened), `recorded_at` (when we logged it — these differ for imported data), `summary` (human-readable), `actor_system` (who or what caused it, e.g., `'user:alice'`, `'agent:triage-bot'`, `'system:cdc'`).

**Write convention:** Always use `record_event()` — never insert into `events` and `event_participants` separately. See [Functions](#record_event).

#### `event_participants` — Event-to-Node Links

Junction table linking events to the nodes involved, with a role for each.

**Why it exists:** Events involve multiple entities in different roles (an interview has a candidate, an interviewer, and a role it's regarding). This table captures those relationships and also drives RLS visibility — an event is visible only if you can see at least one of its participants.

**Key columns:** `event_id`, `node_id`, `role` (how the node participated). Unique on `(event_id, node_id, role)` — a node can participate in the same event in multiple roles.

#### `assertions` — Time-Versioned Facts

Append-only claims about nodes or edges. When a newer fact contradicts an older one, the old assertion is superseded — never mutated.

**Why it exists:** Facts change. A customer's health score shifts, a deal advances to a new stage, a title opinion is revised. Traditional systems overwrite the old value. Rye preserves both the old belief and the new one, with timestamps and provenance. This enables point-in-time reconstruction, contradiction detection, and audit trails.

**Key columns:** `assertion_type` (fact category), `assertion_key` (`'default'` for singleton facts, domain-specific key for multi-valued facts), `claim` (the fact content as JSONB), `confidence` (0-1), `superseded_at` / `superseded_by` (null = current), `source_event_id` (provenance).

**Write convention:** INSERT directly for new facts. Use `supersede_assertion()` to replace existing single-valued facts. Direct UPDATE is blocked by trigger.

#### `artifacts` — Extracted Content

Content objects produced by or referenced from events — document extracts, parsed email content, structured data products.

**Why it exists:** Agents and processes extract structured data from unstructured sources (emails, documents, transcripts). Artifacts store those extractions with provenance back to the source event and links to related nodes.

**Key columns:** `artifact_type`, `source_event_id` (provenance), `source_node_id`, `content` (JSONB), `related_node_ids` (quick-reference array).

### Supporting Tables

#### `access_grants` — Permissions

Runtime-configurable permissions that RLS policies reference.

**Why it exists:** Access control needs change without code deploys. A manager gets access to a deal, a team gains visibility into a project. Grants are data, not schema, so they can be modified by the application.

**Key columns:** `grantee` (user/role/team), `grant_type`, `resource_type`, `access_level` (`read`/`write`/`admin`), `scope` (JSONB filter), `active`.

#### `field_classifications` — Field-Level Sensitivity

Metadata defining which JSONB fields require which role level to see.

**Why it exists:** A node's `properties` may contain fields with different sensitivity levels — salary, SSN, financial terms. Rather than splitting data across tables, field-level redaction strips sensitive keys based on the calling user's role.

**Key columns:** `node_type`, `field_path` (e.g., `'properties.ssn'`), `classification`, `min_role`. Used by `redact_properties()`.

#### `node_source_map` — Domain Table Integration

Maps graph nodes to records in domain tables.

**Why it exists:** Rye is an overlay. When a graph node represents a row in an existing table (a customer, a product, a ticket), this table records the mapping. This enables joins back to the source table and drives CDC — only rows with a mapping produce change events.

**Key columns:** `node_id`, `source_schema`, `source_table`, `source_id`, `synced_at`. Primary key: `(node_id, source_schema, source_table)`.

**Write convention:** Use `link_record()` instead of inserting directly — it creates both the node and the source map entry.

#### `node_merges` — Deduplication Tracking

Records which nodes were merged into which canonical nodes, and by whom.

**Why it exists:** The same real-world entity often appears in multiple source systems with different identifiers. When duplicates are resolved (manually or by fuzzy matching), the merge history is preserved so that old references can be traced to the surviving node.

**Key columns:** `duplicate_id` (absorbed node), `canonical_id` (surviving node), `merged_by`, `confidence`.

#### `assertion_type_access` — Assertion Type Gating

Controls which roles can read or write specific assertion types. Assertion types not in this table are unrestricted.

**Why it exists:** The original RLS policies hardcoded assertion type restrictions in CASE statements. Adding a new sensitive type required modifying SQL policies. This table makes the security model data-driven — add a row, not a migration.

**Key columns:** `assertion_type`, `operation` (`read`/`write`), `allowed_roles` (text array). Unique on `(assertion_type, operation)`.

#### `role_classification_access` — Role Hierarchy

Maps roles to the classification levels they can access. Used by `redact_properties()` for field-level redaction.

**Why it exists:** The original `redact_properties()` hardcoded a CASE statement mapping roles to classification arrays. Adding a new role or changing access levels required modifying the function. This table makes the role hierarchy data-driven.

**Key columns:** `role_name` (PK), `classifications` (text array of accessible levels). Roles not in this table default to `['public']` only.

#### `crm_code_counters` — Human-Readable Code Generation

Counters for generating sequential codes in the format `{PREFIX}-{YYMM}-{SEQ}`.

**Why it exists:** UUIDs are unambiguous but unfriendly. People say "OPP-2403-0042", not a UUID. This table provides concurrency-safe, human-readable codes that reset per month per prefix.

**Key columns:** `prefix`, `year_month`, `next_val`. Used by `generate_crm_code()`.

---

## Views

#### `current_assertions`

Non-superseded assertions only (`WHERE superseded_at IS NULL`).

**Why it exists:** Most queries want current beliefs, not historical ones. This view filters out superseded rows so callers don't need to remember the filter.

#### `node_context`

Full context for a node — the node itself, its outbound and inbound edges, and its current assertions, all in one row. Uses correlated subqueries so each dimension (outbound edges, inbound edges, assertions) is aggregated independently — no Cartesian product explosion.

**Why it exists:** Agents and UIs frequently need "everything about this node" in a single query. This view pre-joins the common pattern.

#### `nodes_secure`

Nodes with field-level redaction applied via `redact_properties()`.

**Why it exists:** When exposing node data to users with limited roles, sensitive JSONB fields must be stripped. This view applies the redaction automatically based on the calling session's role.

Uses `security_invoker = true` so RLS is evaluated with the caller's permissions.

#### `active_disputes`

Nodes or edges with multiple active assertions of the same type — competing claims that haven't been resolved.

**Why it exists:** After `contest_assertion()` creates competing claims, someone needs to find and resolve them. This view surfaces all unresolved disputes with the competing assertions aggregated into a single row per (subject, type).

Uses `security_invoker = true` so RLS is evaluated with the caller's permissions.

---

## Profile Views

#### `opportunities_active` (CRM, materialized)

Active opportunities with their current stage, value, win probability, primary contact, and assigned owner pre-joined.

**Why it exists:** Opportunity boards and pipeline reports always need the same joins. Materializing this avoids repeated work and enables indexed lookups on `code`, `stage`, and `assigned_to_id`.

#### `contacts_directory` (CRM, materialized)

Contact records with their organization, current contact info, and sentiment pre-joined.

**Why it exists:** Contact search and display always need the org relationship and current assertions. Materializing enables fast, indexed directory lookups.

#### `task_board` (PM, materialized)

Tasks with their current status, estimation, progress, owner, reviewer, and project pre-joined.

**Why it exists:** Task boards and sprint views always need the same set of joins. Materializing enables indexed filtering on `status`, `owner`, and `project`.

---

## Core Functions

#### `record_event()`

```
record_event(p_event_type, p_summary, p_properties, p_participant_ids, p_participant_roles, p_actor, p_occurred_at) → uuid
```

Creates an event and its participants atomically. Pre-generates the event UUID so the INSERT into `events` uses a known ID, then inserts participants in a loop. Returns the event UUID.

**Why it exists:** Under RLS, `INSERT INTO events ... RETURNING id` fails because the `event_read_policy` requires participants to exist before the event is visible — a chicken-and-egg problem. This function breaks the cycle by pre-generating the UUID.

#### `link_record()`

```
link_record(p_source_schema, p_source_table, p_source_id, p_node_type, p_label, p_properties, p_source_id_type) → uuid
```

Connects a domain table row to the graph. Creates a node (with `external_id` / `external_source`) and a `node_source_map` entry. Each distinct `source_id` creates a new node. Calling again with the same `(schema, table, source_id)` updates the existing node's properties.

Lookup order: checks `node_source_map` first (canonical path), then falls back to `external_id`/`external_source` on the nodes table. A unique index on `node_source_map(source_schema, source_table, source_id)` prevents duplicate mappings.

**Why it exists:** The two-step pattern of `INSERT INTO nodes` + `INSERT INTO node_source_map` is error-prone and repetitive. This function makes domain integration a single idempotent call.

#### `track_table()`

```
track_table(p_schema, p_table, p_trigger_name) → void
```

Attaches a CDC trigger (`capture_domain_change`) to a domain table. After this, any INSERT/UPDATE/DELETE on linked rows automatically produces a `domain_change` event.

**Why it exists:** Manual event logging for domain table changes doesn't scale. This function automates change tracking so that graph consumers see updates without the source application needing to know about Rye.

#### `capture_domain_change()`

Trigger function called by `track_table()`. Not called directly. Fires on INSERT/UPDATE/DELETE, checks if the affected row has a linked node in `node_source_map`, and if so, calls `record_event()` with the full before/after diff. Unlinked rows are silently skipped.

Supports tables with any primary key column — tries `id` first, then falls back to the table's actual PK column via `pg_index` catalog lookup.

**Why it exists:** The CDC trigger needs to be generic — it works on any table without knowing its schema. It also needs to be selective — only rows that have been explicitly linked to the graph should produce events.

#### `rye_catalog()`

```
rye_catalog() → jsonb
```

Returns a summary of everything in the Rye instance: node types and counts, edge types and counts, assertion types and counts, event types and counts, tracked tables with linked node counts, and totals.

**Why it exists:** An agent's first call when entering a new instance. Instead of running multiple `SELECT DISTINCT` queries, this function returns the full picture in one call.

#### `supersede_assertion()`

```
supersede_assertion(p_old_assertion_id, p_new_assertion_type, p_new_subject_node_id, p_new_subject_edge_id, p_new_claim, ...) → uuid
```

Replaces an existing assertion with a new version. Sets `superseded_at` / `superseded_by` on the old row and inserts the new one. Supersedes the old assertion first to avoid unique-key conflicts.

**Why it exists:** The immutability trigger blocks direct updates to assertion content. Supersession is the only way to change a fact, and it must happen atomically — the old assertion must be marked superseded before the new one is inserted (because of the active uniqueness index on `(subject_ref, assertion_type, assertion_key)`). This function manages the ordering and session flags.

#### `merge_nodes()`

```
merge_nodes(p_duplicate_id, p_canonical_id, p_merged_by) → void
```

Merges a duplicate node into a canonical node. Records a `node_merge` event (before redirecting participations so both nodes are valid participants), then redirects all edges, assertions (with conflict resolution for matching type/key), event participations, artifacts, and source mappings. Archives the duplicate.

**Why it exists:** Cross-source deduplication is a common operational problem. When two nodes represent the same real-world entity, all their graph relationships need to follow the merge. This function handles the full redirect atomically.

#### `agent_node_summary()`

```
agent_node_summary(p_node_id, p_max_items) → jsonb
```

Returns compact context for a node: the node itself, top relationships (both outbound and inbound, ranked by weight, each with a `direction` field), current facts, and recent activity. Each section is limited to `p_max_items`.

**Why it exists:** Agents need context but have limited context windows. Dumping a node's full history overwhelms the model. This function returns a ranked, bounded summary that fits typical agent consumption.

#### `log_agent_query()`

```
log_agent_query(p_agent_id, p_query_text, p_result_summary, p_nodes_referenced) → uuid
```

Creates an `agent_query` event logging what the agent asked, what it got back, and which nodes were touched. Delegates to `record_event()` internally.

**Why it exists:** Agent interactions must be auditable. When an agent reads data, the query and its scope are recorded so that access patterns can be reviewed.

#### `record_artifact()`

```
record_artifact(p_artifact_type, p_content, p_source_event_id, p_source_node_id, p_related_node_ids, p_location, p_content_hash) → uuid
```

Creates an artifact with optional content-hash deduplication. If `p_content_hash` is provided and a matching artifact of the same type already exists, returns the existing ID without inserting. The hash is stored in `attrs->>'content_hash'`.

**Why it exists:** The artifacts table had no helper function, leaving agents and applications to do raw INSERTs with no dedup protection. This function makes artifact creation a single idempotent call with built-in duplicate detection for document processing pipelines.

#### `contest_assertion()`

```
contest_assertion(p_existing_assertion_id, p_new_claim, p_source, p_confidence, p_reason, p_source_event_id, p_actor) → uuid
```

Creates a competing assertion alongside an existing one without superseding it. Both remain active with different `assertion_key` values (`default` vs `contested:<source>`). Records a `dispute_raised` event.

**Why it exists:** The original assertion model was binary — active or superseded. When contradictory information arrives but the correct answer is uncertain, this function lets both claims coexist until a human or process resolves the dispute.

#### `resolve_dispute()`

```
resolve_dispute(p_winning_assertion_id, p_reason, p_actor) → uuid
```

Picks a winning assertion and supersedes all other active assertions for the same (subject, type). If the winner has a `contested:` key, promotes it to a clean `default` assertion. Records a `dispute_resolved` event.

**Why it exists:** Completes the dispute lifecycle. After `contest_assertion()` creates competing claims, someone must eventually resolve them. This function handles the resolution atomically, including key promotion and audit trail.

#### `update_node_properties()`

```
update_node_properties(p_node_id, p_properties, p_label, p_summary) → uuid
```

Merges new properties into an existing node, optionally updates the label, and records a `node_properties_updated` audit event with before/after diff. Returns the event UUID.

Uses a write-path gate (`app.write_path = 'update_node_properties'`) to temporarily open the `node_update_policy` for agent roles. The gate is set before the `FOR UPDATE` lock (required because `SELECT ... FOR UPDATE` checks both SELECT and UPDATE policies) and cleared immediately after the update.

**Why it exists:** Agents can INSERT nodes but the `node_update_policy` blocks direct UPDATE. When a node IS the system of record (no backing domain table), agents need a controlled, audited way to update properties — e.g., recording a new email discovered during conversation. This function provides that path while keeping direct `UPDATE nodes` blocked.

#### `link_records_batch()`

```
link_records_batch(p_source_schema, p_source_table, p_source_ids, p_node_type, p_labels, p_properties, p_source_id_type) → uuid[]
```

Processes multiple `link_record()` calls in a single function call. Accepts parallel arrays for source IDs, labels, and optionally properties. Returns an array of node UUIDs.

**Why it exists:** Importing many domain records one at a time (e.g., in a migration script) requires many round trips. This function batches them into a single call while reusing `link_record()`'s idempotent logic.

#### `refresh_materialized_views()`

```
refresh_materialized_views() → void
```

Refreshes all profile materialized views (`opportunities_active`, `contacts_directory`, `task_board`) that exist in the database. Uses `CONCURRENTLY` to allow reads during refresh. Safe to call regardless of which profiles are installed.

**Why it exists:** Profile materialized views need periodic refreshing to reflect current data. This function handles the check-and-refresh pattern so callers don't need to know which profiles are active.

#### `generate_crm_code()`

```
generate_crm_code(p_prefix) → text
```

Generates a human-readable code like `OPP-2403-0042`. Uses `INSERT ... ON CONFLICT DO UPDATE` on `crm_code_counters` for concurrency safety.

**Why it exists:** UUIDs are identifiers for machines. Codes like `TSK-2403-0187` are identifiers for humans. This function provides sequential, collision-free codes without a global sequence lock.

#### `normalize_tmp()`

```
normalize_tmp(raw) → text
```

Normalizes tax map parcel identifiers: `"045-0002-0031"`, `"45/2/31"`, `"45-2-31"` all become `"45-2-31"`. Strips leading zeros, normalizes delimiters.

**Why it exists:** Domain-specific normalizer for land/mineral-rights use cases. Parcels arrive from different county GIS systems with inconsistent formatting.

#### `redact_properties()`

```
redact_properties(p_properties, p_node_type) → jsonb
```

Strips sensitive JSONB keys from a node's properties based on the calling session's role, the `field_classifications` table, and the `role_classification_access` table. Used by the `nodes_secure` view. Unknown roles default to `public` only.

**Why it exists:** Field-level security within JSONB. A `person` node might have `ssn` or `salary` fields that only certain roles should see. Rather than splitting into separate tables, redaction removes the keys at query time.

---

## Trigger Functions

#### `touch_updated_at()`

BEFORE UPDATE trigger on `nodes`. Sets `updated_at = now()`.

**Why it exists:** Ensures `updated_at` is always accurate without requiring callers to set it.

#### `assertions_immutable_guard()`

BEFORE UPDATE trigger on `assertions`. Blocks changes to any column except `superseded_at` and `superseded_by`.

**Why it exists:** Enforces the append-only contract. Without this, application code could accidentally overwrite assertion content, destroying history.

#### `enforce_classification_with_teams()`

BEFORE INSERT/UPDATE trigger on `nodes`. Rejects nodes that have `attrs->'teams'` (non-empty array) but no `attrs->>'classification'`.

**Why it exists:** Team-scoped nodes without a classification would be visible to all users by default, creating a security hole. This trigger catches the mistake at write time.

#### `mark_assertion_superseded()`

Helper function used internally by `supersede_assertion()` and `merge_nodes()`. Sets `superseded_at` and `superseded_by` on an assertion while managing the session flags that bypass the immutability guard.

**Why it exists:** The immutability guard blocks all updates except through the supersession path. This function sets the session flags (`app.write_path`, `app.supersede_assertion_id`) that the RLS policy checks to allow the update.

---

## CRM Profile Functions

#### `create_opportunity()`

Creates an opportunity node with a generated code, links it to a pipeline, assigns an owner, sets the initial `deal_stage` assertion, and records an `opportunity_created` event. Auto-sets `classification: "internal"` when teams are provided.

#### `advance_deal_stage()`

Supersedes the `deal_stage` assertion with a new stage and records a `stage_change` event. If no prior stage exists, inserts the first one.

#### `log_crm_activity()`

Thin wrapper around `record_event()` for CRM-specific event logging.

---

## PM Profile Functions

#### `create_task()`

Creates a task node with a generated code and project sequence number, links it to a project, assigns an owner, sets the initial `task_status` assertion to `"backlog"`, and records a `task_created` event. Auto-sets `classification: "internal"` when teams are provided.

#### `advance_task_status()`

Supersedes the `task_status` assertion and records a `status_change` event. Same pattern as `advance_deal_stage()`.

#### `add_comment()`

Records a `comment` event on a task. Parses `@mention` patterns from the comment text and adds mentioned nodes as additional participants.

#### `log_time()`

Records a `time_log` event on a task with hours and description.

#### `instantiate_workflow()`

Creates a set of tasks from a workflow template node. Each template step becomes a task, with dependency edges between them. Context variables in title templates are interpolated.

**Why it exists:** Repeatable processes (onboarding, due diligence, release checklists) follow the same steps every time. This function stamps out a set of linked tasks from a template.
