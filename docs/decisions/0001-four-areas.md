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

**`tests/` is split by the behavior each file exercises, not by the runner.**
Superseded on 2026-09-08 by the paragraph below; the original text read that
`tests/` belonged to `schema` entirely, including the tests that exercise
other areas, because `21_api_security.sh` and `22_secure_mcp_simulation.sh`
run under one runner against one disposable Postgres.

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

## Amendment, 2026-09-08 — test files follow the behavior they test

`tests/conformance/21_api_security.sh` now belongs to `admin` and
`tests/conformance/22_secure_mcp_simulation.sh` to `agent-kit`; `schema` keeps
the runner scripts (`scripts/conformance.sh`, `scripts/docker-test.sh`), the
SQL conformance and security tests, the concurrency and scenario suites, and
the two host-side tests whose subject is schema-owned code — `16_cli_smoke.sh`
and `23_cli_agent_security.sh`, both of which exercise `./scripts/rye`. The
original reasoning conflated two things: owning a test file and owning the
runner that executes it. They are separable. `docker-test.sh` names 21, 22, and
23 explicitly and still runs the whole suite from one command, so a builder
editing its own integration test changes nothing about how the suite is
invoked. The rejected alternative was leaving `tests/**` with `schema`, which
kept the runner unambiguous but meant that the strongest test of the admin API
and the strongest test of the agent kit's MCP path could only be updated by the
area that owns neither — a change to the admin API and the test proving it
still refuses cross-instance reads could never land in one diff. Also rejected:
moving the test files into `admin/` and `skills/` so ownership followed the
directory tree, which would have split the suite into three runners and given
up the single end-to-end command that decision 0001 was built around.
