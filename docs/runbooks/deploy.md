# Deploy runbook

Three deployable units. Each has one documented deploy path and one rollback
line. No secrets appear here — see each tool's own secret store.

## 1. SQL schema (Postgres)

**What it is:** `schema/core`, `schema/profiles`, `schema/security` applied
to a Postgres 15+ database via `scripts/migrate.sh`, tracked in the
`public.rye_migrations` table (one row per applied migration file, never
rolled back automatically).

**Deploy:**

```bash
# Against a fresh or existing target database:
./scripts/install.sh --db-url "$DATABASE_URL" --profiles crm,pm
# or, for a brand-new remote target with the CLI wrapper:
./scripts/rye init remote --db-url "$DATABASE_URL" --profiles crm,pm
```

`install.sh` runs, in order: `migrate.sh` (applies pending files from
`schema/migrations`, skipping ones already recorded), `sync_plugin_metadata.sh`,
optionally `seed_quickstart.sh` (`--seed`), then `verify.sh` (schema
conformance check). It is safe to re-run: migrations already recorded in
`rye_migrations` are skipped.

**Rollback:** there are no down-migrations. Roll back by restoring the
target database from its last snapshot/point-in-time-recovery backup taken
before the deploy. If the failure is caught before other writes land,
restoring is usually unnecessary — file a decision record and hand-write a
corrective migration instead of reverting forward.

## 2. Admin app (Cloudflare Worker, `admin/`)

**What it is:** a Hono API + Vite/React SPA served from one Worker
(`admin/src/server/worker.ts`, static assets in `dist/client`). Per-tenant
database connections are supplied at runtime via the `RYE_INSTANCES` secret
(JSON list of `{id, label, databaseUrl}`), not committed anywhere.

**Deploy:**

```bash
cd admin
npm run deploy   # = npm run build (tsc -b && vite build) && wrangler deploy
```

Requires `wrangler` to already be authenticated (`wrangler login`) and the
`RYE_INSTANCES` secret to already be set (`wrangler secret put RYE_INSTANCES`);
this command does not set secrets.

**Rollback:**

```bash
cd admin
npx wrangler deployments list      # find the previous good deployment id
npx wrangler rollback <deployment-id>
```

## 3. Marketing/docs site (Cloudflare Worker, `site/`)

**What it is:** an Astro site built to a Worker bundle
(`dist/_worker.js/index.js`) with static assets in `dist/`. Content sync
(`npm run sync:docs`) pulls docs into the site build; no external secrets
required at deploy time.

**Deploy:**

```bash
cd site
npm run deploy   # = npm run build (clean + sync:docs + astro build) && wrangler deploy
```

**Rollback:**

```bash
cd site
npx wrangler deployments list
npx wrangler rollback <deployment-id>
```

## Non-superuser owner check

There is no hosted CI. `./scripts/test-all.sh`, run locally before a merge, is
the gate, and this check is one of its steps.

**What it is:** `scripts/test-nonsuperuser-owner.sh`, run as a named step
("sql (nonsuperuser owner)") inside `scripts/test-all.sh`, alongside the
existing superuser-owner step. It brings up its own disposable postgres
(`scripts/docker-test.sh`, own port) and creates a database owned by an
ordinary `NOSUPERUSER NOBYPASSRLS` role (extensions installed
by the superuser first, then handed to the owner — mirrors Supabase), and
runs `install.sh` + `conformance.sh` as that role from the host. It exists
because a superuser database owner bypasses row-level security for itself
and every `SECURITY DEFINER` function it owns; Supabase's owner is not a
superuser, and five bugs on 2026-09-19 were invisible to the suite without this.

`docker-compose.yml` sets no project name, and both this step and the
existing superuser-owner step run `docker-test.sh` from the same
directory, so they share one compose project and differ only by port.
`test-all.sh` runs them in sequence — the first step tears its container
down before the second resets it — which is what makes that safe. Do not
run the two steps at the same time from one checkout.

**Run it alone:**

```bash
RYE_POSTGRES_PORT=54351 ./scripts/test-nonsuperuser-owner.sh
```

It refuses before running any test if the role it is about to test as
turns out to be a superuser or may bypass RLS.

**Reproduce a failure by hand:** connect with `psql` as the owner role
printed in the script's output (`rye_owner` by default) against the
database it created (`rye_nonsuperuser` by default) on
`127.0.0.1:${RYE_POSTGRES_PORT}`, and re-run the specific `tests/conformance`
or `tests/security` file that failed with `SET search_path` set first, the
same way `scripts/conformance.sh` does it.

## Preparing a fresh worktree for `./scripts/test-all.sh`

**What it is:** `scripts/bootstrap-worktree.sh`. A fresh git worktree has no
`node_modules` in `admin/`, `site/`, or `skills/rye-source-context-intake/`.
Without them, `test-all.sh` dies partway through (`tsx: command not found`
at conformance test 21, then `astro: command not found` in the site build),
and a plain `npm ci` in `admin/` tries to build `sharp` from source, which is
slow and can fail outright.

**Run it in worktrees only** (`git worktree add`, e.g. `.claude/worktrees/...`
or `.codex/worktrees/...`) — never in the main checkout. Run it once per
fresh worktree, before `test-all.sh`:

```bash
./scripts/bootstrap-worktree.sh
```

For each of the three directories it copies `node_modules` from the main
checkout (found via `git rev-parse --git-common-dir`) when that checkout has
one whose `package-lock.json` hashes the same — hard-linked (`cp -al`) when
the worktree shares a filesystem with the main checkout, otherwise a full
copy (`cp -a`; never a symlink, since sharp/astro/tsx resolve real paths). It
only falls back to `npm ci` when no usable copy exists, and even then it
first moves any existing `node_modules` aside to a `.bak` sibling and
restores it if `npm ci` fails, so a failed install never leaves the
directory empty. It never writes into the main checkout, and it stamps each
`node_modules` it prepares so a second run is a no-op. `--dry-run` prints
the plan per directory without changing anything.

**Detect the main checkout, always — never run `npm ci` there.** Run
directly in the main checkout, the script prints that there is nothing to
bootstrap from and exits 0 untouched; dependencies there are installed by
hand (`npm ci` in each of the three directories directly). This matters
because `npm ci` deletes `node_modules` before installing: run against the
main checkout by mistake with a broken install, it can leave the one copy
every worktree links from empty.

**Hard links share inodes with the main checkout.** A hard-linked copy is
safe against deletion or replacement (a normal `npm install`/`npm ci` just
drops the link), but a tool that rewrites a file's contents in place —
`npm rebuild`, `patch-package`, hand-editing a file under `node_modules` —
changes the main checkout's copy too, and every other worktree linked from
it. Use `./scripts/bootstrap-worktree.sh --copy` first (forces a real `cp -a`
instead of a hard link) in any worktree where you need to run something
like that.

**Rollback:** nothing to roll back — it only ever adds `node_modules`
directories inside the worktree (or a `.bak` sibling during an `npm ci`
fallback, which it cleans up or restores itself). Delete `node_modules` in
the affected directory and re-run to force a fresh copy or `npm ci`.

## Notes

- All three units are independent: a failed admin deploy does not affect the
  site or the schema, and vice versa. Deploy them separately, in any order.
- `scripts/test-all.sh` should pass locally before any of the above; it does
  not deploy anything by itself.
- Wrangler deploy history (`wrangler deployments list`) is the source of
  truth for "what is live now" for the two Worker units; the SQL schema's
  source of truth is the `public.rye_migrations` table on the target
  database itself.
