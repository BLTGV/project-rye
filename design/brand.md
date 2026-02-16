# Project Rye — Branding & Messaging Guide

## By Open BLT

---

## 1. Identity

### 1.1 Name

**Project Rye**

The name comes from rye bread — the foundation of any good sandwich. It's a nod to Open BLT's brand identity while standing on its own as a short, distinctive, and memorable name. Rye is sturdy, unpretentious, and holds whatever you put on it. That's exactly what this project does for your data.

As the project matures, "Project" may be dropped and it becomes simply **Rye**.

### 1.2 Relationship to Open BLT

Project Rye is an open source project by Open BLT. The brand relationship is:

- **Open BLT** is the company. It builds tools and provides services.
- **Project Rye** is the open source data model. It's the foundation that Open BLT's tools — and anyone else's — can build on.

The metaphor is deliberate and cohesive:

| Brand Element | Meaning |
|---|---|
| Open BLT | The company — open, layered, practical |
| Rye | The foundation — what everything is built on |
| Open source | Open-faced — nothing hidden |

### 1.3 Logo and Visual Direction

Suggested direction (not prescriptive):

- Clean, minimal mark. A simple grain or bread cross-section motif, or an abstract layered form suggesting strata.
- Earthy, warm tones — amber, brown, cream — consistent with the bread/grain metaphor without being literal.
- Monospace or clean sans-serif type for the wordmark. The project is technical; the typography should reflect that.
- Avoid anything that looks like a database logo or a generic tech startup mark. The whole point is that this is different.

---

## 2. Taglines

### 2.1 Primary Tagline

> **Agent-native temporal knowledge graph for PostgreSQL. Natural language in, structured knowledge out.**

This is the one-liner that goes in the GitHub repo description, the README header, and anywhere the project needs to be described in a single breath. It communicates three things: what it's built for (agents), what makes it different (temporal knowledge graph), and what it runs on (PostgreSQL).

### 2.2 Extended Tagline

> **An agent-native data model for PostgreSQL. Structured enough for machines to reason over. Flexible enough for humans to build on. Simple enough to stay that way.**

Use this in the README introduction, landing page hero section, and conference talk abstracts. It addresses three audiences in priority order:

1. **Agents** — "Structured enough for machines to reason over." The schema is designed so LLMs can read, write, and traverse it through natural language without understanding a rigid normalized schema.
2. **Developers** — "Flexible enough for humans to build on." JSONB properties, typed nodes and edges, and no upfront schema migration required for new entity or relationship types.
3. **Maintainers** — "Simple enough to stay that way." Append-only facts, minimal table count, no framework dependencies. Technical debt stays low because the model resists complexity accumulation.

### 2.3 Philosophy Tagline

> **The less you hardcode, the more you can build.**

Use this as a secondary tagline, a pull quote, or a guiding principle in documentation. It captures the core insight: rigid schemas create short-term clarity and long-term debt. Flexible schemas with good conventions create long-term optionality.

### 2.4 Functional Tagline

> **Connect your people, documents, and actions. Let agents manage the rest.**

Use this when speaking to non-technical audiences or business stakeholders who care about outcomes, not architecture.

### 2.5 Data Ownership Tagline

> **Your data. Your database. Your rules.**

Use this when the conversation is about vendor lock-in, data portability, SaaS dependency, or control. It's the sharpest version of Rye's ownership message. A longer form for landing pages or pitch decks:

> **Your knowledge graph lives in your PostgreSQL instance — not in someone else's cloud. No vendor lock-in. No API dependency. No monthly invoice for access to your own data. Fork it, host it, own it.**

### 2.6 Combined Tagline (Full Positioning)

> **An agent-native data model you actually own. Structured enough for machines to reason over. Flexible enough for humans to build on. Simple enough to stay that way. Runs in your PostgreSQL — nowhere else.**

This is the strongest version when you need to communicate everything at once: agent-native design, flexibility, simplicity, and ownership in a single breath.

---

## 3. Messaging Framework

### 3.1 Positioning Statement

Project Rye is an **open source, agent-native data model for PostgreSQL** that gives organizations full ownership and control of their knowledge graph. It provides a flexible, temporal structure for tracking entities, relationships, activities, and evolving facts across interconnected systems. It is designed to be read, written, and reasoned over by LLM agents through natural language, while remaining simple enough for developers to build on and maintain without accumulating technical debt. It runs in your PostgreSQL instance — not in a vendor's cloud — which means your data never leaves infrastructure you control.

### 3.2 Core Messages

Each core message addresses a different audience concern. Use whichever is most relevant to the context.

**For the AI/agent audience:**

> Rye gives your agents a structured world to operate in. Nodes are entities. Edges are relationships. Events are activities. Assertions are facts with timestamps and provenance. An agent doesn't need to understand your domain schema — it reads and writes a universal graph. Natural language queries map directly to graph traversals. Appending new facts is safe because nothing is ever overwritten.

**For the developer audience:**

> Rye is six PostgreSQL tables, a handful of indexes, and a set of conventions. No ORM, no framework, no runtime dependency. Add a new entity type by writing a new `node_type` value. Add a new relationship type by writing a new `edge_type` value. Store domain-specific data in JSONB properties with GIN indexes. Deploy it with a SQL file and start building.

**For the architecture/CTO audience:**

> Rye is a graph overlay that sits on top of your existing systems without modifying them. It points to your domain tables — your domain tables don't point to it. Change data capture triggers feed mutations into an immutable event log. Temporal assertions give you point-in-time reconstruction and contradiction detection. Row-level security enforces access control at the database engine level. When you outgrow it, the upgrade path is partitioning and materialized views, not a rewrite.

**For the business audience:**

> Rye connects the dots between your people, documents, and actions. It tracks how things relate to each other and how those relationships change over time. When an agent or a team member asks "what do we know about this parcel?" or "who have we spoken with about this opportunity?", Rye has the answer — with full history of how that answer evolved.

**For the data ownership audience:**

> Every SaaS platform you adopt is another place your institutional knowledge lives that you don't control. When you outgrow the tool, switch vendors, or the vendor changes pricing, your data is hostage to their export capabilities and their timeline. Rye runs in your PostgreSQL instance. Your knowledge graph — every entity, relationship, fact, and event — lives in infrastructure you own. You can query it with any SQL tool. You can back it up with pg_dump. You can migrate it to any PostgreSQL-compatible host. No API keys expire. No vendor disappears. No pricing tier gates access to your own history. The data model is open source, so even the schema itself belongs to you. This is what data sovereignty looks like in practice: not a policy document, but an architecture that makes lock-in structurally impossible.

### 3.3 Differentiators

What makes Rye different from other graph databases, knowledge management systems, or CRM platforms:

| Differentiator | What it means |
|---|---|
| **You own your data** | Your knowledge graph lives in your PostgreSQL instance. Not a vendor's cloud. Not behind an API. Not subject to pricing changes, rate limits, or export restrictions. pg_dump is your exit strategy, and it works today. |
| **Agent-native** | Designed from the ground up for LLM agents to read, write, and reason over. Not retrofitted for AI — built for it. |
| **Temporal by default** | Every fact has a timestamp and can be superseded. You always know what you believed and when you started believing it. Later facts can contradict earlier ones without data loss. |
| **PostgreSQL-native** | No new infrastructure. No separate graph database. No sync pipelines. It's SQL tables with JSONB and indexes. Runs wherever Postgres runs. |
| **Append-only safety** | Agents and users add facts — they never overwrite or delete them. This is a safety property: you can't corrupt historical knowledge, only build on it. |
| **Schema-flexible** | New entity types, relationship types, and properties require no migration. Write them and they exist. GIN indexes handle queryability automatically. |
| **Overlay architecture** | The graph points to your domain tables. Your domain tables don't know the graph exists. Zero coupling, full connectivity. |
| **Open source** | No vendor lock-in. No proprietary query language. No cloud-only deployment. Fork it, extend it, own it. |
| **No dependency chain** | Rye is a SQL file. It has no runtime, no framework, no package manager, no build step. Your data model doesn't break because a dependency released a bad update. |

### 3.4 What Rye Is Not

Being clear about what the project is *not* is as important as what it is:

- **Rye is not a database.** It's a data model that runs inside PostgreSQL. It doesn't replace your database — it lives in it.
- **Rye is not a CRM, project manager, or task tracker.** It's the data layer those things can be built on. It provides the foundation, not the application.
- **Rye is not a graph database competitor.** Neo4j and Neptune are designed for massive-scale graph analytics with billions of edges. Rye is designed for operational knowledge graphs in the millions of entities where co-location with relational data, RLS, and transactional consistency matter more than raw traversal speed.
- **Rye is not an AI product.** It has no embedded model, no inference engine, no prompt library. It's a data model that agents happen to be very good at working with because of its structure and conventions.
- **Rye is not a SaaS platform.** There is no hosted version, no account to create, no subscription. It's a SQL file you run in your own database. This is by design, not a limitation. Your data stays on your infrastructure because that's the only way to truly own it.

---

## 4. Voice and Tone

### 4.1 Principles

Project Rye's voice should reflect its design philosophy:

- **Clear over clever.** Say what you mean. Avoid jargon when plain language works. If a concept needs a technical term, define it the first time.
- **Confident without arrogance.** The project makes strong architectural choices and should own them. But it should also be honest about tradeoffs and limitations.
- **Practical over theoretical.** Lead with examples, not abstractions. Show the SQL query, then explain why it works.
- **Warm, not corporate.** Open BLT has a personality. Rye should too. It's okay to be conversational in documentation, to use "you" and "we," to occasionally be funny.
- **Respectful of the reader's time.** Short sentences. Short paragraphs. Say it once, say it well, move on.

### 4.2 Words We Use

- "Simple" not "easy" (simple is a design property; easy is a subjective experience)
- "Flexible" not "powerful" (powerful is vague; flexible is specific)
- "Temporal" not "versioned" (temporal implies real-world time semantics, not just row versions)
- "Assertions" not "facts" in technical context (assertions can be wrong or superseded; facts imply certainty)
- "Overlay" not "layer" (overlay implies you can remove it; layer implies dependency)
- "Agent-native" not "AI-powered" (the data model isn't powered by AI; it's structured for AI to work with)
- "Own" and "control" not "manage" or "store" (ownership implies rights and permanence; manage implies you could lose the privilege)
- "Your database" not "the database" (reinforce that the user is in control)
- "Data sovereignty" not "data security" when discussing ownership (security is about protection; sovereignty is about who has authority)
- "Exit strategy" not "migration path" (exit implies freedom; migration implies difficulty)

### 4.3 Words We Avoid

- "Revolutionary," "game-changing," "disruptive" — let the work speak
- "Enterprise-grade" — means nothing, signals insecurity
- "Seamless" — nothing is seamless, and claiming it erodes trust
- "Best-in-class" — compared to what?
- "Leverage" as a verb — just say "use"
- "Solution" — be specific about what it is

---

## 5. README Structure

The README is the project's front door. Suggested structure:

```
# Project Rye 🌾

**Your data. Your database. Your rules.**

An agent-native data model for PostgreSQL. Structured enough for
machines to reason over. Flexible enough for humans to build on.
Simple enough to stay that way. Runs in your PostgreSQL — nowhere else.

By [Open BLT](https://openblt.com)

## What Is This?
[2-3 paragraphs: the problem, the approach, who it's for]

## Why Own Your Data Model?
[The case for data sovereignty — why a SQL file beats a SaaS dependency]

## Quick Start
[SQL file, 5 minutes to a working schema, one example insert + query]

## The Data Model
[Visual diagram, brief description of each table, link to full docs]

## For Agents
[How an LLM reads/writes the graph, example natural language → SQL mappings]

## For Developers
[How to extend, add node types, integrate with domain tables]

## Documentation
[Links to the full implementation guide, scaling guide, security guide]

## Contributing
[How to contribute, code of conduct, development setup]

## License
[License type]
```

### 5.1 First Impression Checklist

Within 30 seconds of landing on the repo, a visitor should know:

- [ ] What it is (a data model for PostgreSQL)
- [ ] Who it's for (agents and developers building operational systems)
- [ ] What makes it different (agent-native, temporal, append-only, overlay architecture)
- [ ] That they own it completely (runs in their database, open source, no vendor dependency)
- [ ] How to try it (a SQL file they can run right now)
- [ ] Who makes it (Open BLT)

---

## 6. Community Messaging

### 6.1 Launch Announcement Template

> **Introducing Project Rye** 🌾
>
> We've been building an open data model for PostgreSQL designed for LLM agents to manage. Six tables. JSONB properties. Temporal assertions that never overwrite history. A graph overlay that connects your existing systems without modifying them.
>
> We built it because our agents needed a structured world to operate in — and everything else was either too rigid (normalized schemas that break when the domain shifts), too complex (full graph databases that need their own infrastructure), or too dependent on someone else's platform (SaaS tools that hold your data hostage behind API limits and pricing tiers).
>
> Rye is the middle path: flexible enough to model any domain, structured enough for agents to reason over, simple enough that you're not fighting the data model six months from now, and entirely yours. It runs in your PostgreSQL instance. Your knowledge graph never leaves infrastructure you control. Your exit strategy is pg_dump, and it works today.
>
> It's open source. It's a SQL file. Your data. Your database. Your rules.
>
> [Link to repo]

### 6.2 Conference Talk Abstract

> **Project Rye: Building Agent-Native Data Models You Actually Own**
>
> What happens when you let LLM agents manage your operational knowledge graph? You need a data model that agents can read, write, and reason over through natural language — without rigid schemas that break when the domain shifts, without the complexity of a dedicated graph database, and without handing your institutional knowledge to a SaaS vendor.
>
> Project Rye is an open source PostgreSQL data model built for this purpose. In this talk, we'll walk through the design: a lightweight property graph with temporal assertions, append-only event logging, JSONB properties with GIN indexes, and row-level security that cascades through the graph. We'll show how agents interact with it, how it overlays existing operational databases without modifying them, why data sovereignty matters when agents are managing your knowledge, and where the performance boundaries actually are.

---

## 7. Naming Conventions for Future Projects

If Open BLT releases additional open source projects, the bread/grain naming convention provides a natural family:

- **Rye** — the data model (foundation)
- Future projects could follow: **Pumpernickel**, **Sourdough**, **Wheat**, **Marble**, etc.
- Or shift to sandwich components: **Pickle** (a sharp utility tool), **Mustard** (a spicy add-on), etc.

This is entirely optional and should only be pursued if it feels natural. Forced theme naming is worse than no theme.

---

## 8. Design Tokens (v1)

These tokens define Rye's baseline visual system for web properties: warm, grounded, and technical.

```css
/* Rye Design Tokens v1 */
:root {
    /* Typography */
    --font-display: "Space Grotesk", "Segoe UI", sans-serif;
    --font-body: "Source Sans 3", "Segoe UI", sans-serif;
    --font-mono: "IBM Plex Mono", "SFMono-Regular", monospace;

    --text-xs: 0.75rem;   /* 12 */
    --text-sm: 0.875rem;  /* 14 */
    --text-md: 1rem;      /* 16 */
    --text-lg: 1.125rem;  /* 18 */
    --text-xl: 1.375rem;  /* 22 */
    --text-2xl: clamp(1.75rem, 3vw, 2.5rem);
    --text-3xl: clamp(2.25rem, 4.5vw, 3.75rem);

    --lh-tight: 1.15;
    --lh-copy: 1.6;

    /* Spacing (4px base) */
    --space-1: 0.25rem;
    --space-2: 0.5rem;
    --space-3: 0.75rem;
    --space-4: 1rem;
    --space-5: 1.5rem;
    --space-6: 2rem;
    --space-7: 3rem;
    --space-8: 4rem;

    /* Radius */
    --radius-sm: 0.5rem;
    --radius-md: 0.875rem;
    --radius-lg: 1.25rem;
    --radius-pill: 999px;

    /* Brand Palette */
    --rye-cream: #f5efe3;
    --rye-sand: #e8dbc3;
    --rye-amber: #b7792b;
    --rye-rust: #8d4f1d;
    --rye-char: #1f1b16;
    --rye-slate: #4d463b;
    --rye-moss: #4f6451;

    /* Semantic Colors */
    --color-bg: var(--rye-cream);
    --color-surface: #fffaf1;
    --color-surface-2: #f2e6d2;
    --color-text: var(--rye-char);
    --color-text-muted: #6b6255;
    --color-border: #d8c8af;

    --color-brand: var(--rye-amber);
    --color-brand-strong: var(--rye-rust);
    --color-brand-soft: #edd6b6;
    --color-accent: var(--rye-moss);

    --color-success: #2f7a48;
    --color-warning: #a26316;
    --color-danger: #b23a2f;

    /* Elevation */
    --shadow-sm: 0 1px 2px rgba(31, 27, 22, 0.08);
    --shadow-md: 0 8px 24px rgba(31, 27, 22, 0.12);
    --shadow-lg: 0 18px 50px rgba(31, 27, 22, 0.16);

    /* Motion */
    --ease-standard: cubic-bezier(0.2, 0.8, 0.2, 1);
    --dur-fast: 140ms;
    --dur-med: 260ms;
    --dur-slow: 420ms;

    /* Layout */
    --container-max: 72rem; /* 1152px */
}

[data-theme="dark"] {
    --color-bg: #16130f;
    --color-surface: #1e1a15;
    --color-surface-2: #262017;
    --color-text: #f3eadb;
    --color-text-muted: #c7b89f;
    --color-border: #3a3125;

    --color-brand: #d2954c;
    --color-brand-strong: #e1ad6d;
    --color-brand-soft: #3a2b17;
    --color-accent: #7ea082;

    --shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.35);
    --shadow-md: 0 10px 28px rgba(0, 0, 0, 0.45);
    --shadow-lg: 0 20px 56px rgba(0, 0, 0, 0.55);
}

@media (prefers-reduced-motion: reduce) {
    :root {
        --dur-fast: 1ms;
        --dur-med: 1ms;
        --dur-slow: 1ms;
    }
}
```

### 8.1 Usage Rules

1. Use `--color-brand` only for primary CTAs and active states.
2. Use `--font-mono` for code, schema excerpts, and database-focused surfaces.
3. Keep body copy on `--text-md` with `--lh-copy` for readability.
4. Use only opacity/transform animations with motion duration tokens.
5. Respect `prefers-reduced-motion` for all interactive effects.
