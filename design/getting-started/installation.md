# Installation

## Get Rye running on your PostgreSQL database

---

## Prerequisites

- **PostgreSQL 15+** — Rye uses features like `security_invoker` views and `pg_catalog` built-in `gen_random_uuid()`
- **`psql` CLI** — used by the install and migration scripts
- **`git`** — to clone the repository
- **`bash`** — install scripts are Bash-based

---

## Clone the Repo

```bash
git clone https://github.com/BLTGV/project-rye.git
cd project-rye
```

---

## Install Rye

### Option A: Existing Database

If you already have a PostgreSQL database running:

```bash
./scripts/install.sh --db-url postgresql://user:pass@host:5432/your_db
```

This runs all migrations and installs the `rye` schema alongside your existing tables. Nothing in your database is modified — Rye only creates objects in its own schema.

### Option B: Docker

If you want a self-contained environment:

```bash
./scripts/docker-test.sh up
```

This spins up a PostgreSQL container and installs the Rye schema automatically.

---

## Verify the Install

Connect to your database and run:

```sql
SELECT rye_catalog();
```

This returns a summary of everything in the Rye instance. On a fresh install it shows an empty catalog — that's expected.

---

## Set the Search Path

Rye objects live in the `rye` schema. To call Rye functions and query Rye tables without schema-qualifying every name, set the search path at the start of each session:

```sql
SET search_path = rye, public, pg_catalog;
```

With this in place, `SELECT rye_catalog()` works instead of `SELECT rye.rye_catalog()`. The `public` schema stays in the path so your domain tables remain accessible.

---

## Set Session Variables

Rye enforces row-level security using three session variables. Set these at the start of each connection:

```sql
SET LOCAL "app.current_user_id" = 'your-user-id';
SET LOCAL "app.current_teams" = 'team-a,team-b';
SET LOCAL "app.current_role" = 'operator';
```

| Variable | Purpose |
|----------|---------|
| `app.current_user_id` | Identifies who is making the request. Used in event attribution and RLS policies. |
| `app.current_teams` | Comma-separated team list. Controls which classified nodes and edges are visible. |
| `app.current_role` | Role name (`operator`, `agent`, `admin`, etc.). Gates access to assertion types and classification levels. |

Without these variables set, RLS policies will block most reads and writes. This is by design — Rye assumes no implicit trust.

---

## Profiles

Rye supports optional layer profiles that add domain conventions on top of the core schema:

```bash
./scripts/install.sh --db-url postgresql://... --profiles crm,pm
```

| Profile | What it adds |
|---------|-------------|
| `crm` | CRM conventions — contact, deal, and pipeline node types with standard edge patterns |
| `pm` | PM conventions — task, project, and sprint node types with status tracking |

Profiles are additive. You can install with no profiles (`--profiles ""`) and add them later by re-running the install.

---

## Next Steps

You're ready to connect your data. Head to the [Quickstart](quickstart.md) to link your first domain records, draw edges, and query across everything in under 10 minutes.
