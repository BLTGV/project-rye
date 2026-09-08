# Contract: Rye CLI

Published by **schema** (`scripts/rye`). Consumed by **agent-kit** — the
installer, onboarding, and agent-ops skills instruct an agent to shell out to
it, and `tests/conformance/16_cli_smoke.sh` holds it to this contract.

## Shape

One executable, `./scripts/rye`, with verb-first subcommands:

- `init local|remote` — install or migrate. `--fresh`, `--seed`, `--profiles`.
- `status`, `doctor` — is Rye installed, at what version, with what enabled.
- `onboard create` — create a scope. Refuses without purpose, boundary, and
  owner.
- `catalog plugins|skills|capabilities` — what vocabulary exists.
- `context [--scope]` — the agent's briefing for a scope.
- `sources inventory|pending-context` — what has been seen, what awaits a
  person.
- `agents create|grant|issue-token|revoke-token|list|audit` — agent identity
  and capability grants.

Global options: `--db-url`, `--schema`, `--env-file`, `--json`, `--quiet`.
Connection settings default from `.rye.env`, which `init` writes; a caller
never has to author it. Human output goes to stdout, diagnostics to stderr.

`--json` emits exactly the JSON the corresponding SQL function returns
(`rye_agent_context()`, `rye_plugin_catalog()`, `rye_skill_catalog()`,
`rye_capability_catalog()`, `rye_source_inventory()`,
`rye_pending_context_confirmations()`). The CLI adds no fields of its own, so
the shape of `--json` output is governed by `contracts/sql-surface.md`.

## Versioning

Subcommands, flags, and the documented aliases are additive. A new
subcommand or an optional flag is not a breaking change. Renaming a
subcommand, removing a flag, or changing what `--json` returns for an
existing command requires a decision record and an edit here first. Callers
must parse `--json`, never the human-readable tables.

## Freshness

Every invocation opens a fresh `psql` connection and reads current state.
Nothing is cached between invocations except the connection settings in
`.rye.env`. `status` and `doctor` reflect the database at the moment they
run, not the last install.

## Failure behavior

Non-zero exit on any failure, with the reason on stderr. `--json` failures
still exit non-zero; callers check the exit code first and parse second. A
missing or unreachable database exits non-zero rather than prompting. The CLI
is safe to re-run: `init` migrates forward, `onboard create` refuses a
duplicate rather than overwriting. Nothing in the CLI deletes data, and
`--fresh` is the one destructive flag — it is never implied.
