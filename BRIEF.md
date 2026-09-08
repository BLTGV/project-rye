# Brief

Draft written from README.md and docs/roadmap.md. Casey: edit freely; this
is the one document Product reads as your intent.

## What this is
Project Rye is an open source, agent-native temporal knowledge graph that
runs as a schema inside PostgreSQL. It gives an organization one queryable
structure for entities, relationships, events, and time-versioned facts,
designed so that LLM agents can read and write it safely while people keep
authority over what counts as accepted knowledge.

## Who it is for
- Small organizations and teams that want their agents to work from shared,
  reviewable knowledge instead of scattered chat and documents.
- Developers who install Rye alongside an existing database and connect
  domain tables to it without changing them.
- The agents themselves, which need compact context, safe write paths, and
  clear review policies.

## What must be true
- The deliverable is SQL plus skills and plugins. No runtime, framework,
  ORM, or build step for the core.
- Append-only: assertions are superseded, never mutated; events are
  immutable.
- Overlay: domain tables never point at the graph. Dropping the schema
  leaves operational systems intact.
- People accept knowledge; agents suggest. Review policy is per scope.
- Works on plain PostgreSQL 15+ and on Supabase.

## What done for the next stage looks like
- A new organization can install Rye, create a first onboarding scope, feed
  one source, and review candidates through the admin surface, guided by an
  agent, in under an hour.
- The v2 core model (assertion lifecycle, evidence, gaps, digests) is
  implemented, conformance-tested, and documented in one vocabulary.
- Plugins carry all non-core vocabulary and can be validated against scope
  policy before agents write.

## Out of scope for now
- Being the operational UI for domain applications.
- Storage pruning and garbage collection (design constraint now, jobs later).
- Any dependency on a specific connector vendor.

## Constraints
- No customer names in committed examples or fixtures.
- Internals keep canonical vocabulary; only human-facing surfaces use the
  plain-language lexicon.
- CI workflow files under .github/workflows cannot be pushed with the local
  credentials currently available; changes there need the repo owner.
