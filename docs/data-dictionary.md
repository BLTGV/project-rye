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

**Ending an accepted entry is also settling it.** A caller who may not settle a gated type may not change an accepted row of it at all — not `superseded_at`, not `effective_to`, not `status`, not `claim`, not `attrs` — by raw `UPDATE` or through any helper. Leaving supersession open was an escalation, not just a loss: ending a scope's accepted `strict` `review_policy` dropped the scope to `open`, and the next ordinary write landed accepted instead of waiting for review. Candidates of a gated type stay ordinary suggestions, so outcome labels and classification propagation on them are unaffected, and an admin keeps every lifecycle operation. No role deletes an assertion of any type: `assertion_delete_policy` is `USING (false)`.

**Write convention:** A migration or script that seeds configuration must `SET app.current_role = 'admin'` first. An unset role is not an admin.

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
demotes. Nothing said is lost. One exemption, confined to a single tuple: a row
is left accepted when an already superseded, formerly accepted assertion **on
the same `subject_ref`, `assertion_type` and `assertion_key`** names it as its
replacement, so the supersede-then-insert order the helpers use does not strand
that key with no accepted value. The exemption does not carry across subjects,
so a `merge_nodes()` copy is judged by the canonical node's review policy.

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

**Why it exists:** Those three facts are written after the statement that needs
them. `supersede_assertion()` must mark the incumbent before inserting the
replacement, or the partial unique index on accepted unsuperseded rows rejects
the pair. A client may therefore see one of these refusals at `COMMIT`.

#### `assertion_settle_gate_guard()`

BEFORE INSERT OR UPDATE trigger on `assertions` (`trg_assertion_settle_gate`).
Raises when `app.current_role` is not one of the allowed roles and the write
would either make an assertion of a `settle`-gated type accepted, or change a
row of a gated type that is already accepted. Candidates are untouched, so
outcome labels and classification propagation on them still work for every
role. `DELETE` needs no branch: `assertion_delete_policy` is `USING (false)`.

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
