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

#### `assertions` — Temporal Knowledge

Append-only claims about nodes or edges. Candidates await review. Accepted
assertions can be superseded but their content never changes.

**Why it exists:** Knowledge changes and arrives with different certainty.
Rye preserves past beliefs, competing candidates, effective time, knowledge
time, and classification.

**Key columns:** `assertion_type`, `assertion_key`, `claim`, `status`
(`candidate` or `accepted`), `basis` (`observed`, `reported`, `inferred`,
`assumed`, or `unknown`), `classification`, `confidence` (stored prior),
`effective_at` / `effective_to`, `asserted_at`, and
`superseded_at` / `superseded_by`.

**Write convention:** Use `record_assertion()`. Direct inserts without evidence
are reserved for explicit `assumed` assertions. Use lifecycle helpers for
acceptance, rejection, supersession, and scheduling.

#### `assertion_evidence` — Assertion Provenance

Append-only evidence linking an assertion to an event or a source assertion.

**Why it exists:** Provenance can be a source event, corroborating event, or
derivation chain. A single foreign key cannot represent those cases or preserve
independent witnesses.

**Key columns:** `assertion_id`, `kind` (`source`, `corroboration`, or
`derivation`), `event_id`, `source_assertion_id`, `witness_node_id`,
`recorded_at`, and `attrs`. Derivation references an assertion; other kinds
reference an event. RLS requires visibility at both ends.

#### `artifacts` — Extracted Content

Content objects produced by or referenced from events — document extracts, parsed email content, structured data products.

**Why it exists:** Agents and processes extract structured data from unstructured sources (emails, documents, transcripts). Artifacts store those extractions with provenance back to the source event and links to related nodes.

**Key columns:** `artifact_type`, `source_event_id` (provenance), `source_node_id`, `content` (JSONB), `related_node_ids` (quick-reference array), and `attrs` (including propagated classification). Digest narratives inherit the digest assertion classification, and artifact RLS enforces it in addition to source-node visibility.

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

#### `current_valid_assertions`

Accepted, non-superseded assertions inside their effective window.

**Why it exists:** It is the sole base for operational knowledge reads.
Candidates, expired rows, and future rows are excluded consistently.

#### `current_assertions`

Compatibility alias for `current_valid_assertions`.

#### `current_assertions_weighted`

Current valid assertions with `effective_confidence`.

**Why it exists:** Confidence decay, corroboration lift, and candidate discount
are calculated at read time. Stored priors remain immutable.

#### `node_context`

Full context for a node — the node itself, its outbound and inbound edges, and its current assertions, all in one row. Uses correlated subqueries so each dimension (outbound edges, inbound edges, assertions) is aggregated independently — no Cartesian product explosion.

**Why it exists:** Agents and UIs frequently need "everything about this node" in a single query. This view pre-joins the common pattern.

#### `nodes_secure`

Nodes with field-level redaction applied via `redact_properties()`.

**Why it exists:** When exposing node data to users with limited roles, sensitive JSONB fields must be stripped. This view applies the redaction automatically based on the calling session's role.

Uses `security_invoker = true` so RLS is evaluated with the caller's permissions.

#### `review_queue`

Live candidates grouped by subject, assertion type, and assertion key.

#### `competing_candidates`

Candidate tuples with more than one live candidate.

#### `stale_digests`

Current digests whose subject has accepted knowledge newer than the digest
watermark, or whose derivation source was superseded or displaced. Includes a
nullable advisory `salience_score` for hot-first ordering.

#### `node_salience`

Per-node count, distinct-agent count, last query time, and 30-day exponentially
decayed score from `agent_query` events. Only reads routed through
`log_agent_query()` appear. Salience must not gate visibility, retention, or
deletion.

#### `type_vocabulary_report`

One row per stored node, edge, or assertion type with usage count, first/last
seen dates, and a canonical alias when configured. Historical spellings remain
unchanged.

#### `source_reliability`

Per witness, derives witnessed claims, labeled corrections and rejections,
displacements, prediction metrics, correction rate, latest outcome, and the
`low_sample` flag. Scores are never stored.

#### `calibration_report`

Per witness and probability bucket, reports resolvable prediction count, mean
Brier score, and hit rate. Unresolvable predictions are excluded.

#### `pattern_support`

Per `pattern_claim`, reports supporting derivations, contradictory derivations,
and distinct supporting subjects.

#### `open_gaps`

Current accepted `knowledge_gap` assertions whose claim is not resolved.

#### `assertion_support`

Visible evidence rows with target assertion and referenced event or source
assertion context.

All five review and knowledge-maintenance views use
`security_invoker = true`.

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

#### `rye_plugin_catalog()`

```
rye_plugin_catalog() → jsonb
```

Returns installed plugin manifests, contributions, onboarding metadata,
validation metadata, admin metadata, capabilities, and totals.

**Why it exists:** Plugins are portable metadata. Agents and CLI tools need to
discover which vocabulary and behavior are available without reading files from
the repository.

#### `rye_skill_catalog()`

```
rye_skill_catalog() → jsonb
```

Returns synced Rye skill manifests, install commands, requirements,
capabilities, and totals.

**Why it exists:** Skills describe agent-facing workflows. Syncing them into
Rye lets agents discover available guidance from the database itself.

#### `rye_capability_catalog()`

```
rye_capability_catalog() → jsonb
```

Returns capabilities contributed by plugins and skills, including kind,
read-only status, requirements, and entrypoints.

**Why it exists:** Agents need to know what they can read, write, or invoke
before acting. This function gives them a portable capability map.

#### `rye_source_inventory()`

```
rye_source_inventory() → jsonb
```

Returns source accounts and source containers with confirmation status and item
counts.

**Why it exists:** Agents should inspect source context before routing material
or promoting assertions.

#### `rye_pending_context_confirmations()`

```
rye_pending_context_confirmations() → jsonb
```

Returns source accounts and containers whose context still needs confirmation.

**Why it exists:** Unknown source context should be reviewed instead of treated
as business truth.

#### `rye_agent_context()`

```
rye_agent_context(p_scope_id uuid DEFAULT NULL) → jsonb
```

Returns the core catalog, plugin catalog, skill catalog, capability catalog,
source inventory, pending source context confirmations, active scopes, selected
scope status, and compiled scope policy when a scope is selected.

**Why it exists:** Agents need one portable orientation call. If exactly one
scope is active, Rye selects it automatically. If multiple scopes are active,
the caller should pass a scope ID.

#### `supersede_assertion()`

```
supersede_assertion(p_old_assertion_id, p_new_assertion_type, p_new_subject_node_id, p_new_subject_edge_id, p_new_claim, ...) → uuid
```

Replaces an accepted assertion with a new accepted version on exactly the same
subject, type, and key. Cross-tuple replacement raises an error.

**Why it exists:** Supersession must close the prior accepted row before
inserting its replacement. The helper controls that ordering and the narrow
immutability bypass.

#### `record_assertion()`

```
record_assertion(p_assertion_type, p_claim, p_subject_node_id,
                 p_subject_edge_id, p_assertion_key, p_effective_at,
                 p_effective_to, p_confidence, p_status, p_basis,
                 p_evidence, p_classification, p_attrs,
                 p_scope_node_id) → uuid
```

Writes an accepted or candidate assertion and its evidence atomically.
Accepted writes apply temporal replacement rules. Helper writes require
evidence unless `basis = 'assumed'`. New assertion types are normalized with
`canonical_type()`. When a governing scope exists, its review policy may force
the row to candidate status.

#### `accept_assertion()` / `reject_candidate()`

Accepts a candidate on its existing tuple or rejects it with an audit event.
Acceptance supersedes an accepted incumbent but leaves other candidates
live and labels them `displaced`. `p_supersedes_as = 'correction'` labels the
incumbent `corrected`; the default `update` is neutral. Rejection accepts an
optional outcome label. Inferred candidates cannot displace non-inferred
incumbents. Scoped restrictive policy requires a human or the
`rye.authoritative.promote` capability.

#### `schedule_assertion_change()`

Creates an accepted future-effective replacement for any assertion type and
closes the predecessor's effective window. Profile schedulers are thin wrappers.

#### `record_distillation()`

Creates an inferred `digest`, its derivation/source evidence, a validated
watermark, and a `distillation` event. It propagates maximum source
classification, rejects empty or mixed-access sources, and validates a digest
facet against `digest_facets:<node_type>` when configured.

#### `resolve_knowledge_gap()`

Supersedes a `knowledge_gap` with a resolved version on the same tuple. The
claim links the answer assertion; the answer is never used for cross-type
supersession.

#### `assertions_as_of()`

Returns accepted assertions effective at one timestamp and known at another.
Superseded rows remain answerable for periods when they were believed.

#### `registry_value()`

Resolves a registry key with scope override, plugin default, then core default
precedence.

#### `governing_scope()`

```
governing_scope(p_subject_node_id, p_subject_edge_id,
                p_assertion_type, p_witness_node_id) → uuid
```

Resolves the active scope by direct/inherited subject coverage, type coverage,
source coverage, then `DEFAULT_SCOPE`. Ambiguous type coverage raises.

#### `canonical_type()`

```
canonical_type(p_kind, p_value) → text
```

Follows `type_alias:<kind>:<deprecated_value>` registry chains. Cycles and
empty targets raise. Existing stored rows are not rewritten.

#### `record_prediction()` / `score_due_predictions()`

`record_prediction()` writes a validated inferred prediction with a witness
and provenance event. `score_due_predictions()` scores unscored predictions
past their horizon against the outcome tuple returned by `assertions_as_of()`
and records `prediction_scored` events.

#### `record_pattern()`

Creates a `pattern` node and candidate `pattern_claim` with at least three
distinct-subject derivation sources. Optional contradictory assertion IDs are
stored as derivation evidence with `attrs.contradicts = true`.

#### `effective_confidence()`

Calculates current belief from a stored confidence or basis prior, distinct
independent witnesses, optional half-life decay, live candidate discount, and
a capped non-low-sample witness prior. A direct derivation from an accepted
pattern is capped at that pattern's effective confidence for one hop.

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

Returns compact context for a node: the node, relationships, active digests
first, uncovered raw assertions, and recent activity. Assertions come only from
`current_valid_assertions`, include basis labels, and share the item budget.

**Why it exists:** Agents need context but have limited context windows. Dumping a node's full history overwhelms the model. This function returns a ranked, bounded summary that fits typical agent consumption.

#### `find_nodes()` / `find_nodes_batch()`

```
find_nodes(p_query, p_node_types, p_limit, p_threshold, p_scope)
  → (node_id, node_type, label, score, match_reason)

find_nodes_batch(p_queries[], p_node_types, p_limit_per_query, p_threshold, p_scope)
  → (query, node_id, node_type, label, score, match_reason)
```

Ranked entry-point lookup. Matches exact external identity, exact label, then
trigram similarity and substring containment, returning the best reason per
node. Results carry `score` and `match_reason` so the caller can judge rather
than trust an opaque rank.

**Why it exists:** these are primitives for an agent's search loop, not a
search engine. The agent owns semantic matching — it knows the domain
vocabulary, and it can reformulate ("the fence company" → "Meridian Fence"),
decompose, or narrow by type. So the batch form takes many query strings in
one round trip, and `p_threshold` is a per-call argument with the registry
value as its default rather than as fixed policy.

Widening the threshold does not solve paraphrase; reformulating does. The
threshold floors at the `pg_trgm.similarity_threshold` GUC (0.3 by default),
since the `%` operator is what keeps the GIN index usable.

Property values are deliberately not searched. `field_classifications` redacts
individual property paths, so a match on a raw property would let a caller
confirm the contents of a field it cannot read.

#### `find_paths()`

```
find_paths(p_from_node_id, p_to_node_id, p_max_depth, p_edge_types,
           p_semantics, p_as_of, p_direction, p_max_paths, p_scope)
  → (node_path, edge_path, edge_type_path, depth, path_weight)
```

Bounded multi-hop traversal. Depth is capped by registry key `max_path_depth`
(core default 3) — a caller may request less, never more. Edges participate
only while live at `p_as_of`, so a past timestamp reconstructs historical
connectivity. Paths never revisit a node.

`p_direction` defaults to `out` because an edge asserts something in its
direction. Use `any` for undirected connectivity questions, never for causal
reasoning. `p_semantics` filters by `edge_semantics()`.

#### `neighborhood()`

```
neighborhood(p_node_id, p_max_depth, p_edge_types, p_semantics, p_as_of,
             p_direction, p_max_nodes, p_max_assertions_per_node, p_scope) → jsonb
```

Bounded subgraph with each node's current accepted assertions attached, under
explicit node and per-node assertion budgets. Node properties are redacted per
role. Candidates never appear.

`truncated` reports that the node budget was reached. It is not a visibility
signal — nodes pruned by RLS are absent and uncounted.

#### `edge_semantics()`

```
edge_semantics(p_edge_type, p_scope) → text
```

Resolves `edge_semantics:<edge_type>` to `causal`, `structural`,
`associative`, or `temporal`. Unregistered types resolve to `associative`, so
an unclassified vocabulary can never be mistaken for causation.

**Why it exists:** `caused_by` is a claim; `mentioned_alongside` is not. This
makes the distinction a filter predicate instead of a prompt instruction.

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

BEFORE UPDATE trigger on `assertions`. Allows only narrowly gated supersession,
candidate acceptance, and effective-window narrowing. Basis and content remain
immutable.

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

Creates an opportunity node with a generated code, links it to a pipeline,
assigns an owner, records an `opportunity_created` event, and sets the initial
`deal_stage` assertion. The initial assertion carries source evidence for the
caller event when supplied, otherwise for the creation event. Auto-sets
`classification: "internal"` when teams are provided.

#### `advance_deal_stage()`

Supersedes the `deal_stage` assertion with a new stage and records a `stage_change` event. If no prior stage exists, inserts the first one.

#### `log_crm_activity()`

Thin wrapper around `record_event()` for CRM-specific event logging.

---

## PM Profile Functions

#### `create_task()`

Creates a task node with a generated code and project sequence number, links it
to a project, assigns an owner, records a `task_created` event, and sets the
initial `task_status` assertion to `"backlog"`. The initial assertion carries
source evidence for the caller event when supplied, otherwise for the creation
event. Auto-sets `classification: "internal"` when teams are provided.

#### `advance_task_status()`

Supersedes the `task_status` assertion and records a `status_change` event. Same pattern as `advance_deal_stage()`.

#### `add_comment()`

Records a `comment` event on a task. Parses `@mention` patterns from the comment text and adds mentioned nodes as additional participants.

#### `log_time()`

Records a `time_log` event on a task with hours and description.

#### `instantiate_workflow()`

Creates a set of tasks from a workflow template node. Each template step becomes a task, with dependency edges between them. Context variables in title templates are interpolated.

**Why it exists:** Repeatable processes (onboarding, due diligence, release checklists) follow the same steps every time. This function stamps out a set of linked tasks from a template.
