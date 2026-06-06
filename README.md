# Project Rye Implementation Scaffold

This repo now includes an executable Rye implementation scaffold based on the design docs.

## Requirements

- PostgreSQL 15+
- Either:
  - `psql` CLI available in PATH, or
  - Docker + Docker Compose (`docker compose` or `docker-compose`)

## Install

```bash
export DATABASE_URL='postgresql://user:pass@host:5432/dbname'
./scripts/install.sh --profiles crm,pm
```

## Optional seed

```bash
./scripts/install.sh --profiles crm,pm --seed
```

## Verify

```bash
./scripts/verify.sh
```

## Design Docs

- `docs/onboarding.md` describes onboarding scopes, source/channel/context
  separation, expected contexts, context gaps, and plugin policy helpers.
- `docs/roadmap.md` records the undated improvement roadmap.
- `docs/conventions-catalog.md` lists graph conventions and type vocabulary.

## Conformance tests

```bash
./scripts/conformance.sh
```

Conformance security tests must run with RLS enforcement. If `DATABASE_URL` connects as a superuser, `conformance.sh` automatically:

- creates/uses a non-superuser test role (`rye_conformance` by default),
- grants required schema/table/sequence/function privileges,
- runs SQL suites with `SET ROLE`.

Override the role name with:

```bash
RYE_TEST_ROLE=my_test_role ./scripts/conformance.sh
```

## Docker test flow (recommended on MBP)

This path does not require host `psql`; everything runs inside Docker.

```bash
# Full reset + install + seed + conformance
./scripts/docker-test.sh test --reset --profiles crm,pm
```

Useful Docker commands:

```bash
# Start only
./scripts/docker-test.sh up

# Stop containers
./scripts/docker-test.sh down

# Stop and remove data volume
./scripts/docker-test.sh down --volumes
```

Defaults:

- Postgres image: `postgres:15` (multi-arch, works on Apple Silicon)
- Host port: `54329`
- User/password/db: `rye` / `rye` / `rye`

If you already use `54329`, set `RYE_POSTGRES_PORT` before running.

## Assertion write model

- Direct `INSERT` into `assertions` is allowed (subject to RLS).
- Direct `UPDATE` on `assertions` is blocked by policy.
- Use `supersede_assertion(...)` to change single-valued active facts.

## Profile toggles

- Core only: `./scripts/install.sh --profiles ''`
- Core + CRM: `./scripts/install.sh --profiles crm`
- Core + PM: `./scripts/install.sh --profiles pm`
- Core + CRM + PM: `./scripts/install.sh --profiles crm,pm`

## Skills

Skill folders are under `skills/`:

- `rye-installer`
- `rye-agent-ops`
- `rye-domain-onboarding`
- `rye-onboarding`
- `rye-pattern-library`
- `rye-source-context-intake`
- `rye-tabular-intake`
