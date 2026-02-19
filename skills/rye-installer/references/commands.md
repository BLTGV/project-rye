# Rye Installer Commands

## Install

```bash
export DATABASE_URL='postgresql://user:pass@host:5432/db'
./scripts/install.sh --profiles crm,pm
```

## Verify

```bash
./scripts/verify.sh
```

`verify` checks that assertion updates are scoped to supersession context.

## Seed

```bash
./scripts/seed_quickstart.sh
```

## Conformance

```bash
./scripts/conformance.sh
```
