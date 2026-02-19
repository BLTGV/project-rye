# AGENTS.md

## What This Project Is

Project Rye is an open source, agent-native temporal knowledge graph data model for PostgreSQL, created by Open BLT. It is not a database, not an application, and not a framework — it is a schema (six core tables, supporting tables, views, and functions) that runs inside a standard PostgreSQL instance.

Rye provides a single queryable structure for tracking entities, relationships, activities, and evolving facts across interconnected systems. It is designed so that LLM agents can read, write, and traverse it through natural language, while remaining simple enough for developers to build on directly.

There is no runtime, no ORM, no package manager, and no build step. The deliverable is SQL.

## Quick Start for Agents

1. Set the search path: `SET search_path = rye, public, pg_catalog;`
2. Run `SELECT rye_catalog()` to see what's in the instance — node types, edge types, assertion types, tracked tables, and totals.
3. Use `link_record(schema, table, id, node_type, label, properties)` to connect existing domain table rows to the graph.
4. Use `track_table(schema, table)` to attach CDC triggers that capture changes as graph events.
5. Use `record_event(...)` for all event creation — never insert into `events` and `event_participants` separately.
6. Use `agent_node_summary(node_id, max_items)` for compact context on a specific node.

## Schema Isolation

All Rye objects live in a dedicated `rye` schema. Domain tables stay in `public` (or wherever your application puts them). Set the search path before querying:

```sql
SET search_path = rye, public, pg_catalog;
```

Or schema-qualify references: `SELECT rye.rye_catalog()`.

Every function includes `SET search_path` in its definition, so function calls work regardless of session state. See `design/model/deployment.md` for the full rationale.

## Overlay Architecture

Rye sits alongside existing tables. Domain tables are the system of record — Rye connects them without modifying them. The graph points to domain tables via `node_source_map`. Domain tables never point to the graph. Dropping the Rye schema leaves all operational systems intact.

Domain tables are encouraged. If the data has a well-defined use, keep it in a domain table and use `link_record()` to connect it to the graph.

## Project Structure

```
schema/
  migrations/
    0001_core.sql           — Core tables, indexes, RLS policies, views, triggers
    0002_functions.sql      — Core functions (supersession, merge, record_event, link_record, track_table, rye_catalog)
    0004_agent_capabilities.sql — Agent INSERT policies, record_artifact(), assertion disputes
    0005_function_fixes.sql — agent_node_summary, node_context, merge/create events, bulk link, CDC PK, link_record consistency
    0006_security_config.sql — Data-driven assertion type gating, role hierarchy, supporting table RLS
    0100_profile_crm.sql    — CRM profile (opportunities, pipelines, deal stages)
    0110_profile_pm.sql     — PM profile (tasks, projects, sprints)
scripts/
  install.sh                — Install/migrate Rye into a PostgreSQL database
  verify.sh                 — Validate required objects and policies
  conformance.sh            — Run conformance and security tests
  docker-test.sh            — Docker-based test flow
  seed_quickstart.sh        — Seed sample data
tests/
  conformance/              — Conformance test suites
  security/                 — Security and RLS tests
design/
  model/
    overview.md             — Architecture overview and design principles
    deployment.md           — Schema isolation, search_path, SECURITY DEFINER hardening
    schema.md               — Table definitions, indexes, and full DDL
    functions.md            — All functions: supersession, merge, record_event, link_record, track_table, rye_catalog
    security.md             — RLS policies, field-level redaction, classification enforcement
    integration.md          — Domain table overlay, CDC triggers, link_record, track_table
    core-contract-and-conformance.md — Normative contract, checklist, and test matrix
  layers/
    crm.md                  — CRM conventions (contacts, opportunities, pipelines)
    pm.md                   — PM conventions (tasks, projects, sprints)
  cookbooks/
    quickstart.md           — Connect your data in 5 minutes (overlay-first walkthrough)
    saas-customer-operations.md
    recruiting-pipeline.md
    product-development.md
    mineral-rights.md
skills/
  rye-installer/            — Install and migrate Rye
  rye-agent-ops/            — Safe agent read/write patterns
  rye-domain-onboarding/    — Add new domain conventions
docs/
  data-dictionary.md        — Every table, view, and function: what it does and why
  agent-ops-guide.md        — Agent operations guide
  core-contract.md          — Implementation choices
  conventions-catalog.md    — Convention reference
```

The `schema/` directory contains the executable SQL. The `design/` directory is the design reference. Skills under `skills/` provide agent-specific guidance.

## Core Data Model (Six Tables)

| Table | Layer | Purpose |
|---|---|---|
| `nodes` | Graph | Entities: people, companies, projects, tickets, parcels |
| `edges` | Graph | Directed relationships between nodes with temporal bounds |
| `events` | Event Log | Immutable record of things that happened |
| `event_participants` | Event Log | Junction linking events to involved nodes |
| `assertions` | Knowledge | Time-versioned facts that can be superseded, never mutated |
| `artifacts` | Knowledge | Extracted content and document references |

Supporting tables: `access_grants`, `field_classifications`, `node_source_map`, `node_merges`, `crm_code_counters`, `assertion_type_access`, `role_classification_access`.

Views: `current_assertions` (non-superseded only), `node_context` (full node context with edges and assertions), `active_disputes` (subjects with competing active assertions).

## Design Principles (Non-Negotiable)

1. **Append-only safety.** Assertions are never mutated — only superseded. Events are immutable. History cannot be corrupted, only built upon.
2. **Overlay architecture.** The graph points to domain tables. Domain tables never point to the graph. Dropping the graph schema leaves all operational systems intact.
3. **Temporal by default.** Every fact has a timestamp and provenance. Point-in-time reconstruction is always possible.
4. **Agent-native.** The schema is structured for LLM agents to read, write, and traverse. Agents insert facts; they never overwrite or delete.
5. **Convention over schema.** New `node_type`, `edge_type`, and property values require no migration. Write a new value and it exists.
6. **Single auth model.** Session variables (`SET LOCAL "app.current_role" = ...`) are the only authorization mechanism. No mixing with database roles.
7. **No dependency chain.** No runtime, framework, ORM, or package manager. The project is SQL files.

## Key Functions

| Function | Purpose |
|---|---|
| `rye_catalog()` | See what's in the instance — node types, edge types, assertion types, tracked tables, totals |
| `record_event(type, summary, properties, participant_ids, participant_roles, actor)` | Create an event with participants atomically. Returns event UUID. |
| `link_record(schema, table, id, node_type, label, properties)` | Connect a domain table row to the graph. Idempotent. |
| `track_table(schema, table)` | Attach CDC trigger to a domain table for automatic change tracking |
| `agent_node_summary(node_id, max_items)` | Compact context for a node (relationships, facts, activity) |
| `supersede_assertion(old_id, ...)` | Replace a single-valued assertion with a new version |
| `record_artifact(type, content, source_event_id, source_node_id, related_node_ids, location, content_hash)` | Create an artifact with optional dedup. Returns artifact UUID. |
| `contest_assertion(existing_id, new_claim, source, confidence, reason)` | Record a competing claim without superseding the original |
| `resolve_dispute(winning_assertion_id, reason, actor)` | Pick a winner and supersede all other competing assertions |
| `link_records_batch(schema, table, ids[], type, labels[], properties[])` | Bulk domain table import. Returns uuid[]. |
| `refresh_materialized_views()` | Refresh all profile matviews (CONCURRENTLY) |
| `log_agent_query(agent_id, query, summary, node_ids)` | Audit log for agent reads |
| `merge_nodes(duplicate_id, canonical_id)` | Deduplicate nodes. Records `node_merge` event. |

## Key Conventions

- **Entity types** are string values in `node_type` (e.g., `'person'`, `'org'`, `'opportunity'`, `'task'`).
- **Relationship types** are string values in `edge_type` (e.g., `'employs'`, `'assigned_to'`, `'blocks'`).
- **Domain data** goes in JSONB `properties` columns with GIN indexes.
- **System metadata** goes in JSONB `attrs` columns (classification, teams, tags).
- **Classification enforcement:** Nodes with `attrs->'teams'` (non-empty array) must have `attrs->>'classification'` set.
- **Human-readable codes** follow the format `{PREFIX}-{YYMM}-{SEQ}` (e.g., `OPP-2403-0042`, `TSK-2403-0187`).
- **Temporal edges** use `effective_from`/`effective_to` instead of deletion.
- **Soft delete** uses `archived_at` (null = active).
- **Assertion supersession** is handled by `supersede_assertion()` which sets `superseded_at`/`superseded_by` on the old assertion and inserts the new one atomically.
- **Assertion disputes:** When contradictory information arrives but you're uncertain which is correct, use `contest_assertion()` to record a competing claim without superseding the original. Use `resolve_dispute()` to pick a winner. Query `active_disputes` to find unresolved conflicts.
- **Artifact creation** uses `record_artifact()` — supports optional `content_hash` dedup to prevent re-processing the same source material.
- **Event creation** always uses `record_event()` — never insert into `events` and `event_participants` separately.

## Security Model

- RLS is enabled and forced on all core and supporting tables.
- Node visibility is the anchor — if you can't see a node, you can't see its edges, assertions, or event participations.
- Cascading visibility: edges require both endpoints visible; assertions require their subject visible.
- Assertion-type gating is data-driven via `assertion_type_access` table. Types not in the table are unrestricted.
- Field-level redaction strips sensitive JSONB keys via `redact_properties()` based on `role_classification_access` table.
- Agent permissions are explicit: agents can INSERT nodes, edges, events, assertions, and artifacts. They cannot UPDATE or DELETE.
- Supporting tables (`access_grants`, `node_source_map`, `field_classifications`, config tables) have their own RLS policies.

## What Not To Do

- Do not add columns to core tables to accommodate domain-specific needs. Use JSONB `properties` instead.
- Do not create domain-specific tables that reference core tables. Use `link_record()` and `node_source_map` for integration.
- Do not mutate assertion content. Use supersession.
- Do not delete events. They are immutable.
- Do not insert into `events` and `event_participants` separately. Use `record_event()`.
- Do not use `INSERT INTO events ... RETURNING id` — it fails under RLS. Use `record_event()`.
- Do not create nodes with `attrs->'teams'` without setting `attrs->>'classification'`. The trigger will reject it.
- Do not use `pg_has_role()` or `current_user` for authorization. Use session variables.
- Do not introduce framework dependencies, ORMs, or build steps.

## PostgreSQL Requirements

- **Version:** 15+ required (for `security_invoker` views and `gen_random_uuid()`).
- **Extensions:** `pgcrypto`, `btree_gin`, `pg_trgm`.
- **Table creation order matters** due to FK dependencies: nodes -> edges -> events -> event_participants -> assertions -> artifacts -> supporting tables -> views.

## Voice and Tone (for Documentation)

- Clear over clever. Practical over theoretical. Lead with examples.
- Use "simple" not "easy", "flexible" not "powerful", "temporal" not "versioned", "assertions" not "facts".
- Avoid: "revolutionary", "game-changing", "enterprise-grade", "seamless", "best-in-class", "leverage", "solution".
- Short sentences, short paragraphs. Respect the reader's time.
