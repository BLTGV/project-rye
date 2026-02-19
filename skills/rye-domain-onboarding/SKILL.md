---
name: rye-domain-onboarding
description: Add new Rye domain conventions and profile migrations. Use when introducing new node/edge/assertion/event conventions, creating new profile-specific functions/views, and extending conformance tests without breaking Rye core guarantees.
---

# Rye Domain Onboarding

## Workflow

1. Identify existing domain tables to connect (domain tables are encouraged — keep well-defined data in domain tables, use Rye to connect them).
2. Define domain conventions:
   - `node_type` — what entities are these?
   - `edge_type` — what relationships exist between them?
   - `assertion_type` — what facts do you track about them?
   - `event_type` — what happens to them?
3. Use `link_record()` to connect existing table rows to the graph.
4. Use `track_table()` to attach CDC triggers for change tracking.
5. Define active-fact keying rules with `assertion_key`:
   - singleton facts: `default`
   - multi-valued facts: stable domain key
6. Optionally add a profile migration in `schema/migrations` using `*_profile_<name>.sql` naming for helper functions and materialized views.
7. Add tests in `tests/conformance` and `tests/security`.
8. Run `./scripts/conformance.sh` before merge.

## Guardrails

- Keep core migrations backward-safe.
- Do not mutate assertion content directly.
- Route assertion supersession through `supersede_assertion(...)`; avoid direct assertion updates.
- Enforce profile behavior through tests, not docs only.
