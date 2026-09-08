# schema

Purpose: The rye schema and the bash that installs, verifies, and tests it. Tables, views, functions, RLS policies, migrations, the profile layers, and the ./scripts/rye CLI. This is the spine every other area is a client of.
Paths: schema/** tests/** scripts/install.sh scripts/migrate.sh scripts/verify.sh scripts/conformance.sh scripts/docker-test.sh scripts/seed_quickstart.sh scripts/sync_plugin_metadata.sh scripts/rye docker-compose.yml design/model/** design/layers/** design/cookbooks/** docs/data-dictionary.md docs/core-contract.md docs/core-model-v2.md docs/cli.md
Test: ./scripts/docker-test.sh test --reset --profiles crm,pm

## Learned
Dated entries. What a stranger would need to know and could not read from the code.
- 2026-09-07: `scripts/docker-test.sh test` is the full local SQL runner: compose up, install, conformance, security, concurrency, scenarios, node-dependent security tests, teardown.
- 2026-09-07: no down-migrations; rye_migrations tracks forward applies only. Rollback is restore-from-backup (docs/runbooks/deploy.md).
- 2026-09-07: the CLI's --json output is verbatim SQL-function output, so contracts/rye-cli.md is thin by construction.
