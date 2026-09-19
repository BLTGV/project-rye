# schema

Purpose: The rye schema and the bash that installs, verifies, and tests it. Tables, views, functions, RLS policies, migrations, the profile layers, and the ./scripts/rye CLI. This is the spine every other area is a client of.
Paths: schema/** tests/** scripts/install.sh scripts/migrate.sh scripts/verify.sh scripts/conformance.sh scripts/docker-test.sh scripts/seed_quickstart.sh scripts/sync_plugin_metadata.sh scripts/rye docker-compose.yml design/model/** design/layers/** design/cookbooks/** docs/data-dictionary.md docs/core-contract.md docs/core-model-v2.md docs/cli.md
Test: ./scripts/docker-test.sh test --reset --profiles crm,pm

## Learned
Dated entries. What a stranger would need to know and could not read from the code.
- 2026-09-07: `scripts/docker-test.sh test` is the full local SQL runner: compose up, install, conformance, security, concurrency, scenarios, node-dependent security tests, teardown.
- 2026-09-07: no down-migrations; rye_migrations tracks forward applies only. Rollback is restore-from-backup (docs/runbooks/deploy.md).
- 2026-09-07: the CLI's --json output is verbatim SQL-function output, so contracts/rye-cli.md is thin by construction.
- 2026-09-08: an isolated worktree lacks admin/ and skills/rye-source-context-intake/ node_modules, so docker-test.sh fails at tests 21 and 22 until `npm ci` runs in both. Nothing in the repo does this; run it before the area test in a fresh worktree.
- 2026-09-08: record_event p_participant_roles is text[]; appending a bare literal (`arr || 'scope'`) raises "malformed array literal". Cast the element to ::text.
- 2026-09-08: record_scope_policy()'s own assertions land accepted even under a strict review policy, because governing_scope() returns NULL for a scope node's own policy assertions. Only helpers that pass p_scope_node_id feel the policy.
- 2026-09-08: enable_plugin_for_scope stores the manifest at properties.manifest; sync_plugin_metadata.sh stores properties.contributes. Read both, as rye_plugin_catalog() does.
- 2026-09-08: category vocabulary lives in migration 0020 (rye_categories, describe_category) with conformance test 28 and a `categories` CLI subcommand; contract in contracts/category-vocabulary.md.
- 2026-09-08: `./scripts/rye --scope <unknown key>` resolves to a NULL subquery and silently falls back to automatic scope selection; only an unknown uuid reports scope_found:false. Same for `context`.
- 2026-09-08: describe_category upserts the category node with ON CONFLICT DO UPDATE; an agent role without app.write_path=update_node_properties errors on a repeat describe. Conformance test 28 runs as admin only.
- 2026-09-19: the settlement lookup lives in migration 0021 (`rye_settlers()` plus `rye_settler_resolve_ref`, `rye_settler_is_agent`, `rye_settler_node_kind`) with conformance test 29 and a `settlers` CLI subcommand. It is read-only, STABLE, SECURITY INVOKER, and advisory: nothing in an acceptance path calls it yet.
- 2026-09-19: `rye_slugify_key()` maps every run of characters outside a-z0-9 to `_`. Both `ensure_knowledge_domain()` and `rye_settlers()` slugify the area key, and `create_agent_identity()` slugifies `agent_key`. A row written directly with a hyphenated key is invisible to the lookup, and a grant `authority_ref` of `agent:my-agent` never matches agent key `my_agent`. Use the helpers.
- 2026-09-19: `rye_settlers()` returns six `reason` values: `domain_not_found`, `domain_not_resolved`, `area_has_no_owner`, `area_owner_not_visible`, `area_owner_is_agent`, `no_settler_found`. `setup_gap` is true only for `area_has_no_owner` and `area_owner_is_agent`. An unknown explicit area key short-circuits to step `none` before the relationship step, so even the self default is suppressed. That fails closed.
- 2026-09-19: of the tables migration 0016 creates, only `agent_api_tokens` has RLS. `knowledge_domains`, `domain_authorities`, `channel_domain_subscriptions`, `domain_claim_policies`, `agent_identities`, `agent_capability_grants`, `agent_action_log`, and `api_idempotency_keys` have none, contrary to this area's invariant. `rye_settlers()` therefore sees every grant regardless of role, while node-derived settlers are RLS-filtered. Open as its own item.
- 2026-09-19: `conformance.sh` globs `tests/conformance/*.sql` and `migrate.sh` globs `schema/migrations/*.sql`; a new file needs no registration.
- 2026-09-19: when Docker is unavailable, the `pgserver` PyPI wheel (PostgreSQL 16.2) in a venv can execute a single migration and test against a prelude extracted from 0001, 0013, and 0016. It ships no `pgcrypto`, `btree_gin`, or `pg_trgm`, so `install.sh` cannot run on it and RLS interaction, migration ordering, and every other suite stay unverified. It is a stopgap, not the area test.
