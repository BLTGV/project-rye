# Rye — Overview

## Why a Graph, and Why in PostgreSQL

---

## 1. The Core Challenge

Operational systems store data in silos. A CRM tracks contacts. A project manager tracks tasks. A support tool tracks tickets. A billing system tracks subscriptions. Each system is optimized for its own workflow, but none of them answer the question that drives decisions:

> "Given this entity, who is connected to it, what has happened, what do we currently believe about it, what has changed, and how does it relate to everything else?"

That question spans every silo. Answering it today requires a human to manually cross-reference systems, hold relationships in their head, and hope nothing was missed. When that person leaves, the institutional knowledge leaves with them.

Rye solves this by providing a single queryable structure that captures entities, their relationships, what happened, and what we believe — without replacing the systems that already work.

---

## 2. Why a Graph

The data is fundamentally a graph. Entities (people, companies, parcels, tickets, projects) connect through relationships (owns, employs, targets, assigned_to, references). Those relationships have properties — an ownership has a fractional interest, an employment has a start date. The relationships are as important as the entities.

A traditional normalized schema can model known, stable relationships. But operational domains have characteristics that make rigid schemas brittle:

- **Entity types are not fully known upfront.** Today it's customers and tickets. Tomorrow it's partners, integrations, and regulatory filings.
- **Relationship types are not fully known upfront.** "Referred by," "escalated from," "blocks," "successor to" — these emerge as the domain is explored.
- **The same real-world entity exists in multiple systems.** A person is a CRM contact, a support ticket requester, a billing account owner, and a Slack user.
- **Relationships change over time.** People change roles. Deals advance. Subscriptions churn and reactivate.
- **Later facts contradict earlier ones.** A data correction reveals that a customer's plan was miscategorized. The system must preserve both the old belief and the new one.

---

## 3. Why PostgreSQL

A dedicated graph database (Neo4j, Neptune) is a valid choice, but PostgreSQL with JSONB and lightweight graph tables offers significant advantages:

- **Single operational database.** No synchronization between a relational store and a graph store. Domain tables and the graph live in the same database, queryable in the same transaction.
- **JSONB with GIN indexes.** Flexible, schema-on-read storage with indexed access to any field. New properties require no migration.
- **Row-Level Security.** Native RLS enforces access control at the database engine level, not the application level.
- **Mature ecosystem.** Triggers, materialized views, CTEs, window functions, and the full SQL toolkit.
- **Recursive CTEs handle graph traversal** adequately for millions of edges. If traversal becomes a bottleneck, Apache AGE adds openCypher without leaving PostgreSQL.

---

## 4. Conceptual Architecture

The data model has six tables organized into three layers:

**Layer 1: The Graph (Structure)**
- `nodes` — Entities (vertices): people, companies, projects, tickets, parcels, documents
- `edges` — Directed relationships between entities with optional temporal bounds

**Layer 2: The Event Log (Activity)**
- `events` — Immutable record of things that happened: emails, calls, status changes, imports
- `event_participants` — Junction linking events to the nodes involved

**Layer 3: The Knowledge Layer (Intelligence)**
- `assertions` — Time-versioned facts that can be superseded: valuations, statuses, opinions
- `artifacts` — Extracted content, document references, structured data products

Supporting tables handle security, integration, and deduplication:
- `access_grants` — Runtime-configurable permissions
- `field_classifications` — Field-level sensitivity metadata
- `node_source_map` — Maps graph nodes to records in domain tables
- `node_merges` — Tracks entity deduplication decisions
- `crm_code_counters` — Human-readable code generation

---

## 5. Design Principles

1. **Append-only safety.** Assertions are never mutated — only superseded. Events are immutable. You can't corrupt history, only build on it.
2. **Overlay architecture.** The graph points to your domain tables. Your domain tables don't know the graph exists. Drop the graph schema and all operational systems continue.
3. **Temporal by default.** Every fact has a timestamp and provenance. You always know what you believed and when.
4. **Agent-native.** The schema is structured for LLM agents to read, write, and traverse through natural language. Agents insert facts; they never overwrite or delete.
5. **Convention over schema.** New entity types, relationship types, and properties require no migration. Write a new `node_type` value and it exists.
6. **Single auth model.** Access control uses session variables (`SET LOCAL "app.current_role" = ...`) consistently. No mixing of session-based and database-role-based enforcement.

---

## 6. Related Documents

- [Data Dictionary](/docs/reference/data-dictionary/) — Every table, view, and function: what it does and why
- [Core Contract and Conformance Kit](/docs/model/core-contract-and-conformance/) — Normative contract, implementation checklist, and test matrix
- [Schema Reference](/docs/model/schema/) — Table definitions and DDL
- [Functions Reference](/docs/model/functions/) — Utility functions and query patterns
- [Security](/docs/model/security/) — RLS policies and field-level redaction
- [Integration](/docs/model/integration/) — Domain table overlay and change tracking
- [CRM Conventions](/docs/layers/crm/) — Contact, opportunity, and pipeline conventions
- [PM Conventions](/docs/layers/pm/) — Task, project, and sprint conventions
