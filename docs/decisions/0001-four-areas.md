# 0001 — Four areas, split by deploy unit

Date: 2026-09-07. Status: accepted. Decided by: Architect, at bootstrap.

**Four areas, not one, and not seven.** `docs/areas.md` names `schema`,
`agent-kit`, `admin`, and `site`. Each has paths nothing else claims, a test
command that already exists and passes, and an interface another area calls.
The rejected alternative was a single area covering the whole repository,
which is what "fewer is better" would suggest — but the four differ in the
only way that matters for a builder: they deploy separately and their tests
have nothing in common. `schema` is applied by `psql` against a customer's
database; `admin` and `site` are `wrangler deploy`; `agent-kit` is copied
into an agent host by `npx skills add`. A builder briefed on all four would
need a page just to say which tools it may run. The other rejected
alternative was splitting `skills/` from `plugins/`, or `admin`'s API from
its SPA — both were declined because they ship in the same unit and most
work items touch both halves.

**The CLI and the install scripts live with the schema, not on their own.**
`scripts/rye`, `scripts/install.sh`, `scripts/migrate.sh`, and
`scripts/verify.sh` are bash wrappers over SQL that this repository ships in
the same breath as the migrations, and `tests/conformance/16_cli_smoke.sh`
runs inside the same suite. Giving the CLI its own area was rejected: it has
no test command of its own and no deploy step of its own, so it would be an
area on paper only.

**`tests/` belongs to `schema` entirely, including the tests that exercise
other areas.** `21_api_security.sh` starts the admin API and
`22_secure_mcp_simulation.sh` starts an agent-kit MCP server, yet both live
in `tests/conformance/` and run under one runner against one disposable
Postgres. Splitting the suite so each area owned its own integration test was
rejected: it would give three areas the right to edit the same runner and
would break `./scripts/docker-test.sh`, which is the one command that proves
the system works end to end. The cost is that an `admin` or `agent-kit`
change whose integration test needs updating has to reach into `schema` — a
real cost, accepted because a single runnable suite is worth more.

**Reference documentation is owned by the area whose code it describes.**
`design/model/**` and `docs/data-dictionary.md` go to `schema`;
`docs/onboarding.md` and `docs/agent-ops-guide.md` go to `agent-kit`. The
rejected alternative was giving all of `docs/` to the Architect and Product
roles, which would mean a schema change and its data-dictionary entry could
never land in one diff. `docs/product.md`, `docs/glossary.md`,
`docs/architecture.md`, `docs/areas.md`, `docs/decisions/`, and `contracts/`
remain outside every area, owned by Product and the Architect.

**`surfaces/` goes to `admin`, and `scripts/gen-agents`, `agents/`, and
`work/` belong to no area.** The demonstration domain screens are the same
kind of artifact as the console and were placed with it rather than given a
fifth area for three files. The agent-workflow tooling is the Lead's and the
Operator's; no builder should regenerate its own definition.
