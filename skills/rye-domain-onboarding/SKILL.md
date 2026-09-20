---
name: rye-domain-onboarding
description: Add new Rye domain conventions and profile migrations. Use when introducing new node/edge/assertion/event conventions, creating new profile-specific functions/views, and extending conformance tests without breaking Rye core guarantees.
---

# Rye Domain Onboarding

## Workflow

1. Identify existing domain tables to connect (domain tables are encouraged — keep well-defined data in domain tables, use Rye to connect them).
2. Discover the categories already in the graph before naming a new one:
   `./scripts/rye categories --scope <uuid-or-key> --json`, or
   `rye_categories(p_scope_id)` over SQL. Read each `name`, its `description`
   in the organization's words, `properties.observed`, `relationships`, and
   `enabled` (`off` means the scope will refuse writes of that type). `empty`
   `true` means no categories yet — ask a person rather than inventing one.
   The reply's shape is `contracts/category-vocabulary.md`.
3. Define domain conventions, reusing a discovered name wherever one fits:
   - `node_type` — what entities are these?
   - `edge_type` — what relationships exist between them?
   - `assertion_type` — what facts do you track about them?
   - `event_type` — what happens to them?
4. Use `link_record()` to connect existing table rows to the graph.
5. Use `track_table()` to attach CDC triggers for change tracking.
6. Define active-fact keying rules with `assertion_key`:
   - singleton facts: `default`
   - multi-valued facts: stable domain key
7. Optionally add a profile migration in `schema/migrations` using `*_profile_<name>.sql` naming for helper functions and materialized views.
8. Add tests in `tests/conformance` and `tests/security`.
9. Run `./scripts/conformance.sh` before merge.

## Guardrails

- A new category is a person's decision. Propose it, naming the discovered
  categories that do not fit; never create one yourself. "Category" is the
  business sense — what kind of thing this is. It is not `classification`,
  which is who may see it.
- Keep core migrations backward-safe.
- Do not mutate assertion content directly.
- Route assertion supersession through `supersede_assertion(...)`; avoid direct assertion updates. Under a review policy that would demote the caller's write it files a candidate and leaves the incumbent standing, so read `status` back from the returned id instead of assuming the replacement landed.
- Set a role that may write before any write, in every session. A `viewer` and
  an unset role write nothing, and a migration or seed script that writes sets
  `app.current_role` to `admin` first.
- Scopes are a Rye admin's to create, activate, and re-point, and so are the
  `scope_governs_subject`, `scope_governs_source`, and `scope_enables_plugin`
  edges. Propose a scope; do not build one under another role.
- Enforce profile behavior through tests, not docs only.
