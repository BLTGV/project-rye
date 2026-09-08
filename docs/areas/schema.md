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
