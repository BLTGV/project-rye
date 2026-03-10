# Testing Fixtures

This skill includes a fixture pack for three mapping shapes:

- `contacts-basic`
  - one row becomes one destination record
- `org-profiles-one-to-many`
  - one row becomes one org plus one or two location records
- `invoice-lines-many-to-one`
  - many child rows collapse into one parent invoice plus many invoice lines

## Files

- source fixtures live under `assets/fixtures/*/source/`
- mapping configs and modules live under `assets/fixtures/*/mappings/`
- PostgreSQL demo tables and materialization SQL live under `assets/postgres/`

## Docker Postgres Flow

1. Start the Docker database:

```bash
./scripts/docker-test.sh up --reset
```

2. Install Rye into it:

```bash
export DATABASE_URL='postgresql://rye:rye@127.0.0.1:54329/rye'
./scripts/install.sh --profiles ''
```

3. Run the fixture smoke flow:

```bash
node skills/rye-tabular-intake/scripts/tabular_fixture_smoke.mts --db-url "$DATABASE_URL"
```

If your environment can run Docker containers but cannot publish host ports cleanly, use a container-only path:

```bash
docker run -d --name rye-fixture-db \
  -e POSTGRES_USER=rye \
  -e POSTGRES_PASSWORD=rye \
  -e POSTGRES_DB=rye \
  -v "$PWD":/workspace:ro \
  -w /workspace \
  postgres:15

docker exec rye-fixture-db pg_isready -U rye -d rye
docker exec rye-fixture-db bash -lc "cd /workspace && DATABASE_URL='postgresql://rye:rye@127.0.0.1:5432/rye' ./scripts/install.sh --profiles ''"
node skills/rye-tabular-intake/scripts/tabular_fixture_smoke.mts --docker-container rye-fixture-db
```

4. Inspect the demo tables:

```bash
psql "$DATABASE_URL" -c "TABLE public.demo_contacts"
psql "$DATABASE_URL" -c "TABLE public.demo_orgs"
psql "$DATABASE_URL" -c "TABLE public.demo_locations"
psql "$DATABASE_URL" -c "TABLE public.demo_invoices"
psql "$DATABASE_URL" -c "TABLE public.demo_invoice_lines"
```

5. Inspect the Rye-linked staging rows:

```bash
psql "$DATABASE_URL" -c "SELECT source_table, count(*) FROM rye.node_source_map WHERE source_table = 'demo_intake_stage' GROUP BY 1"
```

## Smoke Script Behavior

`tabular_fixture_smoke.mts` does the following:

1. creates demo tables if they do not exist
2. clears prior fixture data
3. extracts source rows into NDJSON
4. maps rows into destination-shaped records
5. stages extracted rows as Rye-friendly envelopes
6. commits extracted, mapped, and staged records into Rye via `tabular_commit_rye.mts`
7. loads fixture JSON into demo PostgreSQL tables used for destination-table verification
8. materializes destination tables
9. links fixture stage rows into Rye via `link_record()` for backward-compatible demo coverage

The Rye-side smoke data uses distinct, namespaced types:

- node types such as `rye_tabular_intake_run`, `rye_tabular_intake_row`, and `rye_tabular_intake_stage_row`
- event types prefixed with `rye_tabular_intake_`
- assertion types prefixed with `rye_tabular_intake_`
- artifact type `rye_tabular_intake_source_file`
- JSONB payloads tagged with `schema_type` and `schema_version`

The commit step also fingerprints each original source file with SHA1 and stores that in the Rye run metadata and source-file artifacts. Duplicate runs for the same source content and run kind are rejected unless `--allow-duplicate-source` is used.

The default output directory is `tmp/rye-tabular-intake-smoke`.

## XLSX Coverage

The org fixture is kept as JSON plus CSV in the repo and converted into XLSX during the smoke run. That avoids committing opaque binaries while still exercising the XLSX path end to end.
