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

**Key columns:** `node_id`, `source_schema`, `source_table`, `source_id`, `synced_at`. Primary key: `(source_schema, source_table, source_id)` since `0031` — the key is the source row. One source row names one node; one node may hold many source rows, which is what a merge leaves behind. `idx_nsm_node` serves the reverse lookup.

Before `0031` the key was `(node_id, source_schema, source_table)`, one mapping per source table per node. `merge_nodes()` therefore could not re-point the duplicate's mapping when the canonical already mapped a row of the same table — the ordinary dedup case — and deleted it instead. The source row lost its graph identity with no error, and the next `link_record()` for it minted a fresh, empty node: the merged duplicate came back without its edges, assertions, or history. A merge now re-points every mapping and deletes none.

**Write convention:** Use `link_record()` instead of inserting directly — it creates both the node and the source map entry.

**Repair:** `rye_restore_merged_source_maps()` puts back mappings that pre-`0031` merges dropped.

#### `node_merges` — Deduplication Tracking

Records which nodes were merged into which canonical nodes, and by whom.

**Why it exists:** The same real-world entity often appears in multiple source systems with different identifiers. When duplicates are resolved (manually or by fuzzy matching), the merge history is preserved so that old references can be traced to the surviving node.

**Key columns:** `duplicate_id` (absorbed node), `canonical_id` (surviving node), `merged_by`, `confidence`.

**RLS (0029):** enabled and forced. Readable by an `admin`, or by a caller who can see both nodes — node visibility is the anchor here as it is for edges. Insertable by a role that may write this table (`rye_may_write_table()`), which is the role test `merge_nodes()` itself applies, less `system:cdc`, and it is `SECURITY INVOKER` so its insert runs as the caller. Never updated and never deleted, by anyone: it is history. `trg_node_merges_gate` repeats the rule as a trigger so it also binds a superuser owner and any `SECURITY DEFINER` helper.

#### `assertion_type_access` — Assertion Type Gating

Controls which roles can read, write, or settle specific assertion types. An assertion type with no row for an operation is unrestricted for that operation.

**Why it exists:** The original RLS policies hardcoded assertion type restrictions in CASE statements. Adding a new sensitive type required modifying SQL policies. This table makes the security model data-driven — add a row, not a migration.

**Key columns:** `assertion_type`, `operation` (`read`/`write`/`settle`), `allowed_roles` (text array). Unique on `(assertion_type, operation)`.

**Operations:**

| `operation` | Meaning | Enforced by |
|---|---|---|
| `read` | Who may see assertions of this type | `assertion_read_policy` |
| `write` | Who may insert them at all | `assertion_insert_policy` |
| `settle` | Who may make one **accepted** | `record_assertion()` demotes; `trg_assertion_settle_gate` refuses every other route |

**The `settle` operation.** Some assertion types are not knowledge about the world — they are Rye's own configuration, and Rye reads them to decide how it treats every other write. Two rows are seeded, both `ARRAY['admin']`:

- `registry_entry` — type aliases, `self_settled_type:*`, `governed_type:*`, `DEFAULT_SCOPE`, basis priors, half lives, digest facets.
- `review_policy` — decides whether other writes land accepted at all.

A non-admin's accepted write of a gated type is **demoted, not refused**, by `record_assertion()`: it lands as a candidate carrying `attrs.settle_gate = {"pending": true, "requested_status": "accepted", "allowed_roles": [...]}` and appears in `review_queue` for an admin to accept or reject, so nothing the person said is lost. Every other route to an accepted gated row raises: a direct `INSERT`, any `UPDATE` that moves a row to `accepted` (including `accept_assertion()` and a raw `UPDATE` by a caller who sets `app.write_path` itself), `supersede_assertion()`, and `record_distillation()`. An agent capability grant (`rye.authoritative.promote`) does not open the gate. Gating a further type is an `INSERT`, not a migration.

**No alias points out of a gated type.** A `registry_entry` whose `assertion_key` is `type_alias:assertion_type:<T>`, where `T` has a `settle` row, is refused for every caller at every status — candidate included, admin included (migration `0028`). `record_assertion()` canonicalizes before it inserts and the gate compares the stored spelling, so such an alias would route every later write under the gated name to a type the gate does not read. An alias *into* a gated type is unaffected: it narrows, because the write then canonicalizes to the gated spelling and is demoted like any other configuration write. The rule is data like the rest of the gate — add a `settle` row for a type and aliases out of it are refused with no further migration.

**Ending an accepted entry is also settling it.** A caller who may not settle a gated type may not change an accepted row of it at all — not `superseded_at`, not `effective_to`, not `status`, not `claim`, not `attrs` — by raw `UPDATE` or through any helper. Leaving supersession open was an escalation, not just a loss: ending a scope's accepted `strict` `review_policy` dropped the scope to `open`, and the next ordinary write landed accepted instead of waiting for review. Candidates of a gated type stay ordinary suggestions, so outcome labels and classification propagation on them are unaffected, and an admin keeps every lifecycle operation. No role deletes an assertion of any type: `assertion_delete_policy` is `USING (false)`.

**Write convention:** A migration or script that seeds configuration must `SET app.current_role = 'admin'` first. An unset role is not an admin.

#### `role_classification_access` — Role Hierarchy

Maps roles to the classification levels they can access. Used by `redact_properties()` for field-level redaction.

**Why it exists:** The original `redact_properties()` hardcoded a CASE statement mapping roles to classification arrays. Adding a new role or changing access levels required modifying the function. This table makes the role hierarchy data-driven.

**Key columns:** `role_name` (PK), `classifications` (text array of accessible levels), `may_write` (boolean, default true). Roles not in this table default to `['public']` only and may not write. One seeded row is reserved: `system:cdc`, described below.

It is also the instance's list of role names. The governance policies below read it to decide whether a session is a named role, so adding a role stays an insert rather than a migration.

#### Who may write — `may_write` and `rye_role_may_write()`

`may_write` says whether a session holding that role may write the seven core
tables. It is seeded `true` for every role except `viewer`. A new read-only role
is an `INSERT`; widening a role later is an `UPDATE`. Neither is a migration.
The table is readable by every session and writable only by an admin.

```
rye_role_may_write() → boolean
```

True when `app.current_role` is agent-shaped (`agent:<key>`), or names a
`role_classification_access` row whose `may_write` is true. False for `viewer`,
for an unknown role name, and for an unset role. `STABLE`, `SECURITY INVOKER`,
reads only `app.current_role` and `role_classification_access`, so it is safe in
a policy on any table.

**The gate is a trigger; the policy conjunct is the second line.** A policy
alone is not enough: a `SECURITY DEFINER` function owned by a superuser runs
with RLS switched off for itself, and on the default Docker install a `viewer`
still accepted a candidate through `accept_assertion()`, closed one through
`reject_candidate()`, and rewrote `attrs` through `mark_assertion_outcome()`.
So `rye_gate_may_write()` runs `BEFORE INSERT OR UPDATE OR DELETE ... FOR EACH
ROW` on each of the seven core tables and raises `42501` when
`rye_role_may_write()` is false. A trigger fires for a superuser, inside a
definer function, and on a raw write alike, and it needs no list of helpers to
keep current.

| table | trigger |
|---|---|
| `nodes` | `trg_nodes_gate_may_write` |
| `edges` | `trg_edges_gate_may_write` |
| `events` | `trg_events_gate_may_write` |
| `event_participants` | `trg_event_participants_gate_may_write` |
| `assertions` | `trg_assertions_gate_may_write` |
| `assertion_evidence` | `trg_assertion_evidence_gate_may_write` |
| `artifacts` | `trg_artifacts_gate_may_write` |
| `node_source_map` | `trg_node_source_map_gate_may_write` |

On `assertions` the name is chosen so the triggers sort
`trg_assertion_settle_gate`, `trg_assertions_gate_may_write`,
`trg_assertions_immutable`, `trg_assertions_insert_review` — the settle gate's
message still wins, and the shape guards still run after the role is settled.

`node_source_map` is in the list because a mapping decides which node a tracked
table's change events attach to. Before `0026` its insert policy was
`WITH CHECK (true)` and its update policy asked only that the node be visible,
so a `viewer` could map a source id onto a node of its choosing and have CDC
record its own text there, or re-point an operator's mapping. Only a role that
may write can now insert, update, or delete a mapping, by raw SQL or through
`link_record()`. Its delete policy still narrows further to `admin` and
`manager`, as it always did. `system:cdc` gets nothing here: it reads
`node_source_map` and never writes it.

Every `INSERT`, `UPDATE`, and `DELETE` policy on those eight tables
carries the same conjunct as the cheaper refusal where the owner is bound by
RLS. A `viewer` and a session with no role set may read everything they could
read before and may write nothing, by raw SQL or through any helper, including
a `SECURITY DEFINER` one. Nothing a `team_member` or an `agent:*` could write to
an ordinary row is taken away.

**A refusal has two shapes, by owner.** A `BEFORE ROW` trigger only sees rows
RLS admitted. Where the table owner is bound by RLS a refused `UPDATE` or
`DELETE` affects zero rows and raises nothing; where the owner is a superuser
the rows are visited and the trigger raises `42501`. An `INSERT` raises on both.
A client, and a test, asserts the row rather than one error text.

**`system:cdc`.** `capture_domain_change()` runs inside the application's own
transaction on a tracked domain table, and an application that does not know
Rye exists sets no `app.current_role`. Refusing its `record_event()` would fail
the application's own write; skipping the event would turn off the feature
`track_table()` exists for. So the CDC trigger resolves the source node under
the caller's own visibility, then sets `app.current_role` to `system:cdc`
around its `record_event()` call only and restores the caller's value on every
exit path, including the exception one. `rye_gate_may_write()` admits
`system:cdc` for `INSERT` on `events` and `event_participants` and refuses it
everywhere else, and `merge_nodes()` names it, so a caller who sets it by hand
can do strictly less than one who sets `team_member`. The event's
`actor_system` stays `system:cdc` and its `properties.session_role` carries the
caller's role, or null when none was set.

**The governance structure is admin-only.** A `nodes` row whose `node_type` is
`onboarding_scope`, and an `edges` row whose `edge_type` is
`scope_governs_subject`, `scope_governs_source`, or `scope_enables_plugin`, may
be inserted, updated, or deleted only by a caller whose `app.current_role` is
`admin`. The test is row-local, so it reads no table and cannot recurse, and
because RLS applies `USING` to the old row and `WITH CHECK` to the new one, one
rule covers archiving, ending, deleting, and re-pointing in both directions.
`scope_status` joins `registry_entry` and `review_policy` on the settle gate, so
activating a scope is an admin act too. `has_step` is deliberately not gated:
archiving one still drops a step's *inherited* scope, and a subject that must
stay governed gets its own `scope_governs_subject` edge.

`create_onboarding_scope()`, `activate_onboarding_scope()`,
`enable_plugin_for_scope()`, and `record_scope_policy()` keep their signatures
and bodies and are admin-only because the rows they write are.

**What this protects and what it does not.** Session variables are Rye's only
authorization, and every rule here reads the role in order to permit. It
protects deployments where a trusted backend sets the session variables and
agents that state their role honestly. It is not a defence against a hostile
caller with a raw connection. Recorded in
`docs/decisions/0009-who-may-write.md`; migration `0026`.

#### Governance tables — who reads, who writes

Nine tables say which areas exist, who holds authority in them, which channels
feed them, which agents exist, what each agent may do, and what each agent did:
`knowledge_domains`, `domain_authorities`, `channel_domain_subscriptions`,
`domain_claim_policies`, `agent_identities`, `agent_capability_grants`,
`agent_action_log`, `api_idempotency_keys`, `agent_api_tokens`. RLS is enabled
and forced on all nine. `app.current_role` decides, and nothing else does.

| table | admin | named role | bound agent | agent-shaped only | unknown |
|---|---|---|---|---|---|
| `knowledge_domains` | read all; insert, update, delete | read all | read areas it holds | nothing | nothing |
| `domain_authorities` | read all; insert, update, delete | read all | read rows of areas it holds | nothing | nothing |
| `channel_domain_subscriptions` | read all; insert, update, delete | read all | read rows of areas it holds | nothing | nothing |
| `domain_claim_policies` | read all; insert, update, delete | read all | read rows of areas it holds | nothing | nothing |
| `agent_identities` | read all; insert, update, delete | read all | read all | read all | nothing |
| `agent_capability_grants` | read all; insert, update, delete | nothing | read own rows | nothing | nothing |
| `agent_action_log` | read all; insert only | nothing | read own rows | nothing | nothing |
| `api_idempotency_keys` | read all; insert, delete | nothing | read own rows | nothing | nothing |
| `agent_api_tokens` | read all; insert, update, delete | nothing | nothing | nothing | nothing |

**Session shapes.** *Agent-shaped* is `app.current_role` of the form
`agent:<key>`, decided from the session variable alone. *Bound agent* is an
agent-shaped session whose key names an `active` `agent_identities` row. Two
read-only helpers are the definition: `rye_current_agent_key()` returns the key
or null, and `rye_current_agent_id()` returns the identity id or null. Own rows
everywhere means `agent_id = rye_current_agent_id()`.

`app.current_user_id` is a label, not a binding. It is the actor string helpers
write into events, `created_by`, and audit payloads, and no rule reads it. A
session whose label names a different agent than its role is not an error: the
label is ignored. Set `app.current_role` to the stored key of the identity whose
grants you expect.

**Holding an area.** An agent holds an area when it has an active, unexpired row
in `agent_capability_grants` whose `domain_id` is that area or null. The
capability name is not part of the rule.

**Writes go through the helpers, and the policies enforce it.**
`ensure_knowledge_domain`, `subscribe_channel_to_domain`,
`grant_domain_authority`, `create_agent_identity`, and `grant_agent_capability`
are `SECURITY INVOKER` with no role check in the body. What stops a non-admin is
the admin-only write policy on the table each one writes. Two writes are made on
behalf of a non-admin caller and use the `app.write_path` gate:
`record_agent_action()` inserting into `agent_action_log`, and
`agent_create_candidate()` inserting into `api_idempotency_keys`.

`agent_action_log` is append-only for everyone, admin included. There is no
UPDATE or DELETE policy on it.

Full rules, including the order in which one table's policy may read another,
are in `contracts/sql-surface.md` and
`docs/decisions/0007-agent-governance-visibility.md`.

#### `crm_code_counters` — Human-Readable Code Generation

Counters for generating sequential codes in the format `{PREFIX}-{YYMM}-{SEQ}`.

**Why it exists:** UUIDs are unambiguous but unfriendly. People say "OPP-2403-0042", not a UUID. This table provides concurrency-safe, human-readable codes that reset per month per prefix.

**Key columns:** `prefix`, `year_month`, `next_val`. Used by `generate_crm_code()`.

**RLS (0029):** enabled and forced. Readable by every role. Written only by a role that may write this table (`rye_may_write_table()`, which is `rye_role_may_write()` plus the rule that `system:cdc` only ever writes `events` and `event_participants`), and `trg_crm_code_counters_gate` holds the row to the shape `generate_crm_code()` writes: a new counter starts at `next_val = 2` for the current month and nowhere else, `prefix` and `year_month` never change, `next_val` may only become `next_val + 1`, and no counter is ever deleted — not by an `admin` either, because a restarted series re-issues codes that already name a node. Before this a `viewer` could rewind or delete a counter and jam every code-issuing helper. Drawing a code is therefore a write: a session with no `app.current_role` is refused, and it could not create the task or opportunity the code names anyway.

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

Lookup order: checks `node_source_map` first (canonical path), then falls back to `external_id`/`external_source` on the nodes table. `node_source_map`'s primary key is `(source_schema, source_table, source_id)`, so a source row names one node. After a merge the mapping points at the canonical node, and `link_record()` for that row returns it and creates nothing.

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

**It records under `system:cdc`.** The application's session may set no `app.current_role` at all, which is the normal overlay case, and since `0026` such a session may not write the graph. So the node lookup runs first, under the caller's own role and `app.current_teams` — node visibility is unchanged, and a mapped node the session cannot see still skips silently — and then `app.current_role` is set to `system:cdc` around the `record_event()` call only and restored on every exit path, including a re-raising exception block. A tracked table's writes never fail because of Rye's role rules, and a tracked table always produces its event. `actor_system` stays `system:cdc`; `properties.session_role` carries the caller's role before the swap, or null when none was set.

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

#### `rye_categories()`

```
rye_categories(p_scope_id uuid DEFAULT NULL) → jsonb
```

Returns every category — a node type — in the selected scope, and for each: its
name, what it means in this organization's words with the assertion that says
so, the properties observed on its rows with counts and frequencies, the
relationships it takes part in as source and as target, whether it is on or off
in the scope, its usage count, and the plugins that declare it. Categories that
are off are listed as `off`, never omitted. Top level carries `contract_version`,
`categories`, `category_count`, `empty`, and a `scope` block whose `mode`
resolves exactly as `rye_agent_context()` resolves it.

Membership with a scope is types in use, types the scope's enabled plugins
declare, and the names in its `allowed_node_types`; unscoped it is types in use
plus every catalogued plugin's. A declared type with no rows counts 0. An unknown
or archived `p_scope_id` answers empty rather than raising, as does a database
with nothing in it. Everything is computed on read, so an accepted description is
visible to the next call.

**Why it exists:** An agent that knows only the skills must be able to ask the
database what kinds of things it holds before trying to add one. Procedure lives
in git; vocabulary lives in the graph. The jsonb shape is governed by
`contracts/category-vocabulary.md`.

#### `describe_category()`

```
describe_category(p_node_type, p_description, p_scope_id DEFAULT NULL, p_actor DEFAULT NULL,
                  p_basis DEFAULT 'reported', p_evidence DEFAULT NULL, p_confidence DEFAULT 1.0) → uuid
```

Records what a node type means here. Creates the category node on first use,
records a `category_described` event, and records a `category_description`
assertion on that node keyed by the scope's uuid as text, or `default` for the
organization-wide fallback. Returns the assertion id.

**Why it exists:** A person must be able to change a category's meaning and have
the next `rye_categories()` call show the new words. Going through
`record_assertion()` means the scope's review policy applies: under a reviewing
policy the words land as a candidate and stay invisible until `accept_assertion()`
promotes them. Corrections are new assertions; nothing is updated in place.

#### Category node convention

A category is represented by a node with `node_type = 'category'`,
`external_source = 'rye_category'`, and `external_id` equal to the node type it
stands for — one node per type. `properties` carries
`{"category_kind": "node_type", "node_type": <name>}`. The node exists only to
give descriptions a subject; it is never a member of the category list it
describes except as an ordinary node type in its own right. `describe_category()`
creates it; `rye_categories()` only reads it.

#### `rye_settlers()`

```
rye_settlers(p_subject_id uuid, p_claim_type text, p_speaker_id uuid DEFAULT NULL,
             p_speaker_ref text DEFAULT NULL, p_domain_key text DEFAULT NULL,
             p_speech_act text DEFAULT NULL, p_as_of timestamptz DEFAULT now(),
             p_scope_ref text DEFAULT NULL) → jsonb
```

Who may settle this claim, and which of three steps said so. The steps run in
order and the first one to produce a settler wins:

1. **Grant.** Rows in `domain_authorities` for the resolved area that are
   `active`, in effect at `p_as_of`, and whose `claim_types` is empty or
   contains `p_claim_type`. A grant may narrow to named subjects through
   `properties.subjects` and `properties.subject_node_types`. If any grant
   matches, the relationship step does not run — that is how a grant narrows a
   default as well as adds to one.
2. **Relationship.** Two selectors, the claim type first and the speech act
   second, in five ordered rules. The first that applies wins:

   | # | Condition | Default |
   |---|---|---|
   | 0 | `p_claim_type` is `reports_to` or `owns` | none, fall through |
   | 1 | `p_claim_type` is other-set, or `p_speech_act` is `expectation` | manager only; self never |
   | 2 | `p_speech_act` is recognized | `self_commitment`/`self_report` → self **when the canonical type is self-set**, else none; `statement_about_other` → the subject's manager always, and the subject as well when the canonical type is self-set; `statement_about_thing` → owner; `agreement`/`decision`/`outside_report`/`agent_inference` → none |
   | 3 | the canonical claim type is self-set | self only |
   | 4 | otherwise | none, fall through |

   **The subject is returned only when the claim type is positively known to be
   one a person settles about themselves.** Membership in the self set is the
   only thing that makes the subject its own settler. No speech act does it on
   its own: `self_commitment` on a type nobody has declared self-settled
   returns nobody, not the subject. Unknown is restrictive.

   *Other-set* claim types are claims one person sets on another. The core set
   is `expectation`, literal in the function and in the contract.

   *Self-set* claim types are ones a person settles about themselves. The core
   members are `commitment`, `self_commitment`, `self_report` and need no
   configuration. Beyond them the set is data: an organization declares one
   with a registry entry keyed `self_settled_type:<canonical assertion type>`
   whose jsonb value is exactly `true`, written with `record_assertion()` on
   the core registry node and read with `registry_value()`, the same way
   `type_alias` entries are written and read:

   ```sql
   SELECT rye.record_assertion(
       'registry_entry', '{"value": true}',
       (SELECT id FROM rye.nodes
        WHERE external_source = 'rye_registry' AND external_id = 'core'),
       p_assertion_key := 'self_settled_type:preference',
       p_basis := 'assumed'
   );
   ```

   Any other value, including `false` and null, is not a member. The type in
   the key is the canonical one — an alias is registered as an alias, not as a
   second entry. `rye_settler_self_settled()` answers membership.

   **Blindness is always restrictive.** `registry_value()` and
   `canonical_type()` both read `current_valid_assertions` under the caller's
   RLS, so a caller who cannot see an alias or a `self_settled_type` entry —
   because it is classified above their role, or is still a candidate — gets
   the answer for a claim type it cannot classify, and that answer is never the
   subject. Two roles can classify the same claim type differently; the
   difference can only cost a caller settlers, never grant them. There is
   deliberately no `SECURITY DEFINER` resolver.

   Rule 1 is the point of the ordering: an expectation is set on a person by
   someone else, so the person it is set on is never its settler, whatever the
   speech act says. Rule 4 is the other point: there is no union. A null or
   unrecognized speech act selects nothing and the answer falls through, so a
   caller gets a smaller answer for saying less, never a larger one.

   Manager is the target of a `reports_to` edge from the subject; owner is the
   source of an `owns` edge to the subject; both in effect at `p_as_of`.
3. **Area owner.** `knowledge_domains.owner_node_id` for the resolved area.

`p_claim_type` is the assertion type — one vocabulary, no mapping table. It is
resolved through `canonical_type('assertion_type', ...)` before anything is
matched against it, so the organization's type aliases classify a claim the way
the rest of the schema stores it: alias `requirement` to `expectation` and
`p_claim_type := 'requirement'` takes rule 1. Grants match on the canonical
type on both sides, so a grant naming either name covers a call naming either.
The answer reports the requested type as `claim.claim_type` (with
`claim.assertion_type` beside it, unchanged) and the resolved one as
`claim.canonical_claim_type`. Matching is case-sensitive after resolution, a
null or empty claim type is not resolved at all, and an alias cycle raises
rather than falling back to the raw string. `Expectation` with no alias of its
own is a different type in neither set, so it takes the restrictive branch; the
fix is to register `type_alias:assertion_type:Expectation`.
`canonical_type()` and not `canonical_type_in_scope()`: the lookup has no
onboarding-scope argument — `p_scope_ref` matches a grant's `scope_ref` and is
not a scope node — so it resolves through the `DEFAULT_SCOPE` registry entry,
exactly as the salience views and 0019 do.

The area resolves from `p_domain_key`, or from the single active
knowledge domain when it is omitted. `p_as_of` filters effective windows only.

`speech_act_recognized` false is an instruction, not a detail: classify the
statement, pass the speech act, and look again rather than recording it as
accepted. The same applies when rule 4 sends the answer to the area owner.

The answer carries `contract_version`, `step` (`grant`, `relationship`,
`area_owner`, `none`), `settlers`, `settler_count`, `speaker`, `subject`,
`claim`, `domain`, `as_of`, `advisory`, `excluded_agents`, `setup_gap`, and
`reason`. `speaker.is_settler` is the field an agent acts on: true means record
the statement as accepted, false means record a suggestion and ask the settlers
listed. Each settler carries `kind`, `node_id`, `ref`, `label`, `via`,
`relationship`, `bound`, and the evidence of where it came from (`grant_id` and
the grant's windows, or `edge_id` and `edge_type`, or `domain_id`).

An agent identity is never a settler. Candidates are dropped before a step is
chosen and counted in `excluded_agents`, by two rules in this order:

1. **Fail closed on the prefix.** A ref whose first non-whitespace characters
   are `agent` followed by a colon is an agent whether or not an
   `agent_identities` row backs it. A ref that says it is an agent never
   settles, so a typo or a removed identity cannot become authority. Case does
   not matter, and neither does whitespace at the front or around the colon —
   including tab, CR, LF, form feed, vertical tab, and the non-breaking space
   U+00A0, none of which PostgreSQL's `trim()` strips. So `agent:bot`,
   `Agent : Bot`, and a tab-prefixed `agent:bot` are one rule.
2. **Match on the slug, not the spelling.** `create_agent_identity()` stores
   `rye_slugify_key(agent_key)`, so the stored key for `my-agent` is
   `my_agent`. Refs are slugified before comparison, which makes `my-agent`,
   `My Agent`, and `my_agent` one key. An inactive agent identity is still an
   agent; the `active` flag is not consulted.

A person never loses authority for sharing a slug with an agent: rule 1 reads
`agent` as a whole word before a colon and rule 2 slugifies the whole ref, so
`person:my-agent` becomes `person_my_agent` and stays a person. Unicode
lookalike letters are out of scope — a ref whose `a` is a Cyrillic а is not an
agent prefix, and like any other unrecognised ref it matches no identity and no
node and comes back as an unbound settler.

A node is an agent wherever it stands — grant holder, `reports_to` or `owns`
endpoint, or area owner — when its `node_type` is `agent` or its
`attrs->>'actor_kind'` is `agent`. A grant whose only holder is an agent is
therefore not a match and the lookup continues to the next step; an area whose
`owner_node_id` is an agent answers `step` `none` with `reason`
`area_owner_is_agent` and `setup_gap` true.

Nothing raises for a missing answer. An area with no owner returns `step` `none`,
`reason` `area_has_no_owner`, and `setup_gap` true — a setup gap, not an error.
An unknown area key returns `domain_found` false and `reason` `domain_not_found`.
Because RLS silence applies, an empty `settlers` never means nobody is
authorized; it means nobody is authorized and visible to this caller.

**What it does not answer.** It reads no assertion, so it cannot see that a
claim on this subject is already accepted and cannot tell a new statement from a
contradiction of an old one. `is_settler` true is not permission to replace an
accepted claim the caller did not check for. Objections are a later work item;
this lookup answers who may settle a claim, not who may unsettle one.

**Why it exists:** Every agent must get the same answer to "who may settle
this", from one lookup rather than from its own judgment. `SECURITY INVOKER` and
read-only: it writes nothing, not even an audit row, and it refuses nothing. The
jsonb shape is governed by the "Settlement lookup" section of
`contracts/sql-surface.md`.

#### `rye_settler_self_settled()`

```
rye_settler_self_settled(p_canonical_type text) → boolean
```

True when a canonical assertion type is one a person settles about themselves:
the core members `commitment`, `self_commitment`, `self_report`, or a type with
a `self_settled_type:<type>` registry entry whose value is `true`. Read with
`registry_value()` under the `DEFAULT_SCOPE`, so it obeys scope exactly as
`type_alias` does, and under the caller's RLS, so an entry a caller cannot see
is not a member for that caller.

**Why it exists:** it is the single gate on returning the subject as its own
settler. `SECURITY INVOKER` on purpose — a definer-rights resolver would let a
configuration row a caller cannot read widen that caller's authority answer.

#### `rye_settler_resolve_ref()` and `rye_settler_is_agent()`

```
rye_settler_resolve_ref(p_ref text) → uuid
rye_settler_is_agent(p_ref text, p_node_id uuid) → boolean
```

Helpers `rye_settlers()` uses. `rye_settler_resolve_ref()` turns a settler ref
into a visible node id or NULL: a uuid matches by id, an
`<external_source>:<external_id>` pair matches both columns, anything else
matches `external_id` alone. `domain_authorities.authority_ref` is free text, so
most refs resolve to no node; that is not an error, the settler comes back with
`bound` false. `rye_settler_is_agent()` is the single place the "agents settle
nothing" rule is implemented: it fails closed on the `agent:` prefix, ignoring
case and any whitespace at the front or around the colon, and otherwise
compares `rye_slugify_key()` of the ref against the stored `agent_key`, so no
spelling of an agent key gets past it.

#### `supersede_assertion()`

```
supersede_assertion(p_old_assertion_id, p_new_assertion_type, p_new_subject_node_id, p_new_subject_edge_id, p_new_claim, ...) → uuid
```

Replaces an accepted assertion with a new version on exactly the same subject,
type, and key. Cross-tuple replacement raises an error.

Under a scope where `record_assertion()` would demote the same caller's write —
`strict`, or `candidates_only` with a basis other than `observed` — the
replacement lands as a **candidate**, the accepted incumbent is left standing and
unsuperseded, and the new row carries
`attrs.review_gate = {"pending": true, "requested_status": "accepted",
"review_policy": ..., "scope_node_id": ..., "incumbent_assertion_id": ...}`,
the same shape as `attrs.settle_gate`. A `NOTICE` names the incumbent and the
policy. The return type does not change: the new row's id comes back either way,
so read `status` or `attrs->'review_gate'`, or find the row in `review_queue`.
Accepting the candidate with `accept_assertion()` supersedes the incumbent then.

**Why it exists:** Supersession must close the prior accepted row before
inserting its replacement. The helper controls that ordering and the narrow
immutability bypass, and it is where the review policy is applied so that a
supersession cannot land accepted where an ordinary write would not.

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

**A demoted write says so (0030).** Where the review policy demotes the write,
the candidate carries `attrs.review_gate = {"pending": true,
"requested_status": "accepted", "review_policy": ..., "scope_node_id": ...,
"incumbent_assertion_id": null}` — the shape `supersede_assertion()` writes,
with a null incumbent because this write replaces nothing — and a `NOTICE`
names the policy and the scope. The return type does not change, so read
`status` or `attrs->'review_gate'`, or find the row in `review_queue`. Where
the **settle gate** demotes the write first, the row carries `attrs.settle_gate`
alone and no `NOTICE` is raised: a configuration write is waiting for an admin,
not for a settler.

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
facet against `digest_facets:<node_type>` when configured. Where the review
policy demotes the digest to a candidate it carries the same
`attrs.review_gate` marker `record_assertion()` writes, beside its own
`watermark` and `distillation_event_id` keys, and raises the same `NOTICE`
(0030).

#### `resolve_knowledge_gap()`

Supersedes a `knowledge_gap` with a resolved version on the same tuple. The
claim links the answer assertion; the answer is never used for cross-type
supersession. It goes through `supersede_assertion()`, so under a demoting
review policy the resolution is filed as a candidate, the gap stays open and
stays in `open_gaps` until a settler accepts, and the `knowledge_gap_resolved`
event carries `pending_review` and `review_policy` in its properties. One limit:
the resolution is written with basis `inferred`, and `accept_assertion()` refuses
an inferred candidate displacing a non-inferred accepted incumbent, so a gap
recorded with another basis produces a candidate a settler cannot accept. Record
gaps with basis `inferred`, or reject the resolution and record the resolved gap
with `record_assertion()`.

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
source coverage, then `DEFAULT_SCOPE`. Ambiguous type coverage raises. When more
than one scope is a candidate inside the branch that matched — which is what a
cross-scope `merge_nodes()` leaves behind — the **most restrictive review policy
wins**, `strict` over `candidates_only` over `open`, with `scope.id` only as a
tie-break. For an edge subject the source endpoint still beats the target
endpoint before restrictiveness is consulted.

`scope_review_policy_rank(p_scope_id) → int` does the ranking: `0` strict, `1`
candidates_only, `2` everything else. Unlike `scope_review_policy()` it never
raises, so one scope carrying an unsupported stored value cannot refuse writes on
a neighbouring subject; if that scope is the one selected,
`scope_review_policy()` still raises on it.

#### `canonical_type()`

```
canonical_type(p_kind, p_value) → text
```

Follows `type_alias:<kind>:<deprecated_value>` registry chains. Cycles and
empty targets raise. Existing stored rows are not rewritten.

#### `settle_gate()`

```
settle_gate(p_assertion_type) → jsonb
```

Answers `{assertion_type, gated, allowed_roles, current_role, may_settle}` for
an assertion type. `STABLE`, `SECURITY INVOKER`, writes nothing. Call it before
offering to record configuration, so a client can tell the person what will
happen — the schema returns facts, the sentence a person hears is the client's.
Matches the stored spelling with no alias resolution, the same way
`registry_value()` and `governing_scope()` do.

`assertion_settle_roles(p_assertion_type)` returns the allowed roles or `NULL`
when the type is ungated. `may_settle_assertion_type(p_assertion_type)` is the
boolean the demotion and the trigger both use. Both read
`app.current_role` only: no `current_user`, no `pg_has_role()`. An unset role is
never allowed.

#### `record_prediction()` / `score_due_predictions()`

`record_prediction()` writes a validated inferred prediction with a witness
and provenance event. `score_due_predictions()` scores unscored predictions
past their horizon against the outcome tuple returned by `assertions_as_of()`
and records `prediction_scored` events. It returns how many it scored, and it
scores only predictions the calling session may read; it locks each one inside
the `assertion_outcome` write-path gate, so the lock is not filtered away by
`assertion_update_policy` on an install whose owner is not a superuser.

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

**Who may call it.** A merge is irreversible, it moves one subject's history onto another, and it crosses review policies, so it is for people. Four refusals, all `42501` and all raised **before the first `FOR UPDATE`**: a role `rye_role_may_write()` is false for (`merge_nodes requires a role that may write`), an agent-shaped role (`merge_nodes is not available to an agent`; record the duplicate and ask a person), `system:cdc` (`merge_nodes is not available to system:cdc, which only records domain changes`), and a non-admin merging a duplicate that is an `onboarding_scope` node or an endpoint of a live governance edge (`Merging a node a scope governs requires a Rye admin`). The ordering matters: `SELECT ... FOR UPDATE` applies the UPDATE policy as a silent filter, so a gate placed after the lock reported `Duplicate node % not found` about a node the caller could see. After `0026` that message means the node is absent or invisible and nothing else.

**Source mappings travel; none is deleted.** Since `0031` every `node_source_map` row the duplicate holds is re-pointed at the canonical node. The key is `(source_schema, source_table, source_id)`, which does not contain `node_id`, so a re-point never collides and the canonical node ends up holding one mapping per merged source row. `link_record()` for any of those rows returns the canonical node, and change capture attaches that row's later events to it.

#### `rye_restore_merged_source_maps()`

```
rye_restore_merged_source_maps() → jsonb
```

Puts back source mappings that a pre-`0031` merge deleted, reading `node_merges` and the archived duplicate's `external_id` / `external_source`. `node_merges` is treated as untrusted — its insert policy asks only that the role may write, so a row there may be forged. A row is followed only when its duplicate node is archived; where several rows name one duplicate the earliest by `merged_at` then `id` wins, so a later forged row cannot redirect a real merge; a cycle stops the walk and the duplicate is reported `unresolved`. Admin only, `SECURITY INVOKER`, re-runnable, and a no-op once every mapping is correct — which is every instance installed from `0031` onward. Migration `0031` runs it once.

Returns counts. `restored`: a mapping was put back on the merge's terminal canonical node. `already_mapped`: the source row already maps there. `occupied`: the source row maps to some other node — the resurrected duplicate the old key minted on the next lazy link, which may have accumulated its own history, so nothing is re-pointed silently; the remedy is `merge_nodes(mapped_node, canonical)`. `ambiguous`: two archived duplicates claim the same source row and were merged into different canonicals. `unresolved`: `external_source` matched no surviving `(source_schema, source_table)` pair, or matched several. The last three are left alone and reported.

#### `agent_node_summary()`

```
agent_node_summary(p_node_id, p_max_items) → jsonb
```

Returns compact context for a node: the node, relationships, active digests
first, uncovered raw assertions, and recent activity. Assertions come only from
`current_valid_assertions`, include basis labels, and share the item budget.

**Why it exists:** Agents need context but have limited context windows. Dumping a node's full history overwhelms the model. This function returns a ranked, bounded summary that fits typical agent consumption.

#### `resolve_node_identity()`

```
resolve_node_identity(p_node_type, p_label, p_identity, p_limit, p_scope) → jsonb
```

Advisory identity lookup. Returns `verdict` (`match`, `ambiguous`, or `new`)
plus the candidates and why each surfaced. Matches exact external identity and
declared identity keys from `identity_keys:<node_type>`, then falls back to
trigram label similarity.

Fuzzy label matching never produces `match` — a similar name is grounds for
review, not evidence of identity.

A **former name** is searchable. When a node was merged away its label went
with it, so an archived, merged-away node whose label is similar surfaces its
live survivor as a candidate with `match_reason` `former_label_similarity` and
the old name in `matched_former_label`, counted in `former_label_count`. It is
a label match, so it is `ambiguous`, never `match`. Without it an agent
searching an old name would be told `new` and would recreate the entity that
was just deduplicated.

**Why it exists:** Agents perform graph inserts; the database gates outcomes,
not steps. This is a read an intake agent consults before creating a node. It
writes nothing, blocks nothing, and no write helper calls it — a deterministic
resolver in the write path would make the judgment with less context than the
agent has and stall a bulk import on per-row ambiguity. Ambiguity routes to
`create_knowledge_candidate()` for review like any other uncertain claim.

**Visibility.** `SECURITY INVOKER`, so it sees exactly what the caller sees. A
node hidden by classification is not matched and the verdict is `new` — the
same answer a genuinely absent node gives. That is the split-brain risk in
`design/proposals/rls-visibility-contract.md`; its `restricted` verdict (D3)
is not implemented, because the `SECURITY DEFINER` probe it assumed does not
read past `FORCE ROW LEVEL SECURITY` on a non-superuser owner. Where it
matters, run intake under a role that sees the whole population for the node
type. `tests/security/04_identity_visibility.sql` pins the behavior.

**Scale note:** identity-key matching normalizes both sides, so it cannot use
an index out of the box. On large installs add an expression index per
declared key:

```sql
CREATE INDEX idx_org_email_identity ON rye.nodes
  (rye.normalize_identity_value(properties->>'email', 'lower'))
  WHERE node_type = 'org' AND archived_at IS NULL;
```

#### `normalize_identity_value()` / `identity_keys()`

```
normalize_identity_value(p_value, p_normalizer) → text
identity_keys(p_node_type, p_scope) → jsonb
```

Normalizers are `trim`, `lower`, `digits_only`, and `domain`. An unknown
normalizer raises — a silent pass-through would quietly widen identity.
`identity_keys()` resolves the declared keys for a node type, returning `[]`
when none are configured or when the caller cannot see the registry entry.

#### `resolve_merged_node()`

```
resolve_merged_node(p_node_id) → uuid
```

Follows `node_merges` transitively to the surviving node, returning the input
when it was never merged and raising on a merge cycle.

**Why it exists:** `merge_nodes()` has always recorded merges so old
references could be traced to the survivor, but nothing read the table — a
stale reference to a merged-away id resolved to nothing.

**Visibility.** `SECURITY INVOKER`. `node_merges` has forced RLS since `0029`
and its read policy admits an admin or a caller that can see both endpoints,
so the lookup works for every role that can see the nodes involved without any
elevated privilege. A chain through a node the caller cannot see stops at the
last visible link: no id behind the policy is ever returned, and a caller with
wider access gets the whole chain on a re-run.

**A merge record is held to the shape a merge leaves.** `node_merges` is
insert-only, and since `0033` a row is refused unless it passes every refusal
`merge_nodes()` makes before its own insert, evaluated from the same facts: a
role that may not write, an agent-shaped role, `system:cdc`, equal ids, a
non-admin merging a node the governance structure touches, a duplicate or
canonical the caller cannot see, an already-archived duplicate. Four more are
this migration's own, because the row is now read: `merged_at` must equal the
transaction's `now()`, a duplicate carries at most one merge record, the
canonical must not already resolve back to the duplicate, and the canonical
must not itself be archived. At commit the duplicate must be archived and a
`node_merge` event must name the pair.

So what a caller can reach by raw SQL is exactly what `merge_nodes()` would
have done for it: a role allowed to merge that pair may write the row itself,
and to survive the commit it must also archive the duplicate and record the
event. It cannot do more. A role the helper refuses is refused here too, by
the same sentence.

One consequence: `merge_nodes()` inserts the row *before* it archives the
duplicate, so calling it inside `SET CONSTRAINTS ALL IMMEDIATE` fails with
"the duplicate is not archived". Leave the constraint deferred — its default —
and it judges the transaction's final state as intended.

**The table is read as untrusted.** A merge archives its duplicate, so a row
whose duplicate is still live is not a merge and is not followed. Several rows
for one duplicate resolve by earliest `merged_at`, then `id`, so a later row
cannot outrank an earlier one. A cycle stops and returns the last node reached
rather than raising — this is a read an agent calls, and one bad row must not
break every lookup that passes through it.

**Rows written before `0033`** were subject to no rule beyond "a role that may
write", so an upgraded instance should be checked once. Every row a real merge
left is archived, unique per duplicate, and has a `node_merge` event; anything
else predates the guard and may be forged:

```sql
SELECT m.id, m.duplicate_id, m.canonical_id, m.merged_at, m.merged_by,
       CASE
         WHEN d.archived_at IS NULL THEN 'duplicate is not archived'
         WHEN c.archived_at IS NOT NULL THEN 'canonical is archived'
         WHEN (SELECT count(*) FROM rye.node_merges x
                WHERE x.duplicate_id = m.duplicate_id) > 1
              THEN 'more than one merge record for this duplicate'
         ELSE 'no node_merge event'
       END AS why
FROM rye.node_merges m
JOIN rye.nodes d ON d.id = m.duplicate_id
JOIN rye.nodes c ON c.id = m.canonical_id
WHERE d.archived_at IS NULL
   OR c.archived_at IS NOT NULL
   OR (SELECT count(*) FROM rye.node_merges x
        WHERE x.duplicate_id = m.duplicate_id) > 1
   OR NOT EXISTS (
        SELECT 1 FROM rye.events e
        WHERE e.event_type = 'node_merge'
          AND e.properties->>'duplicate_id' = m.duplicate_id::text
          AND e.properties->>'canonical_id' = m.canonical_id::text
   )
ORDER BY m.merged_at;
```

Run it as `admin`. Rows it returns are not followed by `resolve_merged_node()`
when the duplicate is live; for the rest, decide by hand — `node_merges` is
insert-only, so a wrong row is corrected by a real merge, not by deleting it.

#### `find_nodes()` / `find_nodes_batch()`

```
find_nodes(p_query, p_node_types, p_limit, p_threshold, p_scope)
  → (node_id, node_type, label, score, match_reason)

find_nodes_batch(p_queries[], p_node_types, p_limit_per_query, p_threshold, p_scope)
  → (query, node_id, node_type, label, score, match_reason)
```

Ranked entry-point lookup. Matches exact external identity, exact label, then
trigram similarity and literal substring containment, returning the best
reason per node. Results carry `score` and `match_reason` so the caller can
judge rather than trust an opaque rank.

The containment tier is literal, not a pattern language: `%`, `_`, and `\` in
the query match themselves (`rye_like_literal()` escapes them and the `ILIKE`
carries an explicit `ESCAPE '\'`). A one-character query is a one-character
query, not a wildcard.

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

Both are closed sets, and an unrecognized value raises `22023` naming the
accepted ones — `out`, `in`, `any` for the direction; `causal`, `structural`,
`associative`, `temporal` for the semantics. An unknown value must never widen
the answer, and a misspelled direction used to fall through to the undirected
walk. `neighborhood()` refuses the same two arguments the same way, with `any`
as its direction default.

#### `neighborhood()`

```
neighborhood(p_node_id, p_max_depth, p_edge_types, p_semantics, p_as_of,
             p_direction, p_max_nodes, p_max_assertions_per_node, p_scope) → jsonb
```

Bounded subgraph with each node's current accepted assertions attached, under
explicit node and per-node assertion budgets. Node properties are redacted per
role. Knowledge comes from `current_valid_assertions`, so a candidate never
appears — not one written as a candidate, not one a review policy demoted, and
not one `reject_candidate()` closed, which leaves `status = 'candidate'` with
`superseded_at` set. A superseded incumbent is excluded for the same reason.

`truncated` reports that the node budget was reached. It is not a visibility
signal — nodes pruned by RLS are absent and uncounted.

#### `edge_semantics()`

```
edge_semantics(p_edge_type, p_scope) → text
```

Resolves `edge_semantics:<edge_type>` to `causal`, `structural`,
`associative`, or `temporal`. Unregistered types resolve to `associative`, so
an unclassified vocabulary can never be mistaken for causation. It reads the
registry under the caller's RLS, so a registry entry a caller cannot see reads
as `associative` for that caller: blindness narrows a causal traversal, never
widens it.

**Why it exists:** `caused_by` is a claim; `mentioned_alongside` is not. This
makes the distinction a filter predicate instead of a prompt instruction.

**Read-only.** All five of these are `STABLE` and `SECURITY INVOKER`, and none
writes — no event, no salience, no audit row. A caller that wants a read to
count calls `log_agent_query()` itself. That is what lets a `viewer` and a
session that sets no role call them at all: after migration 0026 those two
sessions may not write the core tables, so a function that logged would refuse
for them.

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

Two refusals come before the gate and the lock, both `42501`, because RLS would otherwise report a visible node as missing: a role `rye_role_may_write()` is false for, and a non-admin editing an `onboarding_scope` node.

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

Generates a human-readable code like `OPP-2403-0042`. Uses `INSERT ... ON CONFLICT DO UPDATE` on `crm_code_counters` for concurrency safety. `SECURITY INVOKER`: the counter moves as the caller, so the caller must be a role that may write (0029). The sequence is zero-padded to four digits and **widens** past 9999 (`TSK-2609-10000`) rather than truncating, which used to re-issue the 1000th code of the month.

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

BEFORE UPDATE trigger on `assertions` (`trg_assertions_immutable`). Decides per
column from `OLD`, `NEW`, rows that already exist, and `app.current_role`.
`claim`, `assertion_type`, `assertion_key`, the subject columns, `asserted_at`,
`effective_at`, `basis`, `confidence` and `created_at` never change. `status`
moves `candidate` to `accepted` and never back, only on a live candidate that no
other accepted unsuperseded assertion on the same tuple already covers at
`greatest(coalesce(effective_at, now()), now())`, and an `agent:*` caller under
`candidates_only` or `strict`, or on a `pattern_claim`, additionally needs
`rye.authoritative.promote` for the governing scope. Only `agent:*` callers are
policy-gated on promotion, because that is the rule `accept_assertion()` applies.
`superseded_at` is set once
and, on a row that was accepted, only together with a `superseded_by` naming a
row of the same type and key. `effective_to` narrows only, to a future instant
inside the old window. `attrs` changes only as an outcome label: no key dropped,
no existing key's value changed outside `assertion_outcome_label_keys()`, and
the result must name an `outcome` in `assertion_outcome_values()`.
`classification` may only become `assertion_derived_classification()` for the
row's own derivation evidence.

It does not read `app.write_path`, because any caller can set it. It reads
`app.current_role` only in order to refuse, and there is no admin exemption.

**Why it exists:** Enforces the append-only contract, and the acceptance and
supersession rules with it. The session settings the helpers use are forgeable,
so the rules are about the row rather than the route.

#### `assertions_insert_review_guard()`

BEFORE INSERT trigger on `assertions` (`trg_assertions_insert_review`). A direct
`INSERT` of an `accepted` row is judged by the same review policy
`record_assertion()` applies, and lands as a `candidate` where that policy
demotes. It first refuses, at any status, a row that does not carry exactly one
subject: `assertion_has_subject` is `OR`, not `XOR`, so a row with both
`subject_node_id` and `subject_edge_id` is insertable, `governing_scope()`
cannot read it, and it would escape the review rules while still appearing as
the node's row in `current_valid_assertions`. `record_assertion()` already
refuses that shape, so nothing legitimate writes it. Nothing said is lost.

**There is no exemption.** Migration `0025` left a row accepted when an already
superseded, formerly accepted assertion on the same tuple named it as its
replacement, so that the helpers' supersede-then-insert order would not strand
the key. Migration `0027` removed it, and replaced it with the rule below: every
helper that inserts an assertion takes the stricter of its two scope
resolutions, so no helper ends an incumbent the guard is about to demote. A raw
supersede-and-replace under a demoting policy is therefore refused at commit by
`trg_assertions_transition_complete` rather than landing accepted — the
incumbent still stands after the rollback. A `merge_nodes()` copy is judged by
the canonical node's review policy, as before.

**A helper's policy is the stricter of two resolutions.** This guard resolves
the governing scope with no witness, because evidence is written after the
assertion. A witness-free resolution does not merely lose the witness scope: the
witness branch of `governing_scope()` runs *before* `DEFAULT_SCOPE`, so it falls
through to `DEFAULT_SCOPE`, which can be stricter. So
`record_assertion()`, `supersede_assertion()` and `record_distillation()` each
resolve twice — with their primary witness and with none — and apply the
stricter policy, through `effective_review_policy()`. The scope *id* they report
is still the witness-resolved one. Without this, a subject whose only coverage is
a `scope_governs_source` edge from an `open` scope, on an instance with a
`strict` `DEFAULT_SCOPE`, had the helper insert accepted and this guard demote
the same row. A raw `INSERT` is still judged by the witness-free policy alone,
which is a stated limit in the contract.

**Why it exists:** Rye cannot tell `record_assertion()`'s insert from a raw one,
so it judges the row. Refusing instead would break `merge_nodes()` and throw
away what a caller said.

#### `assertions_transition_complete()`

`AFTER INSERT OR UPDATE` constraint trigger on `assertions`
(`trg_assertions_transition_complete`), `DEFERRABLE INITIALLY DEFERRED`. At
commit: a promotion has an `assertion_accepted` event naming the row, a
`superseded_by` names a row with the same `assertion_type` and `assertion_key`,
and a narrowed `effective_to` has a successor accepted assertion starting where
the window now ends.

All three **fail closed** under the caller's RLS: a row the writer cannot read
back is refused, not waved through. Otherwise an accepted assertion could be
ended by naming a replacement classified above the writer's own read level,
which is erasure.

**Why it exists:** Those three facts are written after the statement that needs
them. `supersede_assertion()` must mark the incumbent before inserting the
replacement, or the partial unique index on accepted unsuperseded rows rejects
the pair. A client may therefore see one of these refusals at `COMMIT`. The one
legitimate call this refuses is `record_assertion()` with a `p_classification`
above the caller's own read level over an accepted incumbent.

#### `assertion_settle_gate_guard()`

BEFORE INSERT OR UPDATE trigger on `assertions` (`trg_assertion_settle_gate`).
Raises when `app.current_role` is not one of the allowed roles and the write
would either make an assertion of a `settle`-gated type accepted, or change a
row of a gated type that is already accepted. Candidates are untouched, so
outcome labels and classification propagation on them still work for every
role. `DELETE` needs no branch: `assertion_delete_policy` is `USING (false)`.
It also refuses, for every caller and at every status, a `registry_entry` whose
`assertion_key` is `type_alias:assertion_type:<gated type>` (migration `0028`),
because an alias out of a gated name would route later writes past the gate.

**Why it exists:** `record_assertion()` demotes a non-admin's configuration
write to a candidate, so every remaining route to an accepted gated row is a
route that bypasses it. The check lives in one trigger rather than in each
helper because a trigger fires inside a `SECURITY DEFINER` helper and on a raw
`INSERT` or `UPDATE` alike, and because the list of helpers grows.

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
