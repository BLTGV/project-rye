# 000 bootstrap

- status: done
- opened: 2026-09-07
- areas: all
- contracts: all

## Goal
Stand up the six-role working model on this repository and run the bootstrap
sequence from agents/README.md: Product, Architect, generate builders,
Operator.

## Acceptance criteria
- [x] docs/product.md and docs/glossary.md exist and stories have code-blind acceptance criteria
- [x] docs/architecture.md, docs/areas.md, contracts/, docs/decisions/0001 exist
- [x] scripts/gen-agents produces one builder per area for all three tools
- [x] one local command runs all tests; CI runs it on pull requests; docs/runbooks/deploy.md exists

## Constraints
- Product writes only under docs/; Architect only under docs/ and contracts/; Operator never edits product code
- .github/workflows changes cannot be pushed with local credentials

## Reports

### Product (2026-09-07)
Result: done. Changed docs/product.md (10 stories S1–S10), docs/glossary.md.
Learned: docs/onboarding.md and docs/core-model-v2.md disagree on
future-effective writes (three per-domain helpers vs one generic helper);
S9 is written against v2.

Questions for Casey, with the default assumed:
1. Does a subject belong durably to a scope, or must every write name its scope? Default: writes name the scope; durable ownership deferred.
2. Must the reviewer's queue ship as a screen, or is the CLI enough? Default: a screen is required (S4, S5 assume one).
3. Is "under an hour" measured locally only, or also against a remote database with existing data? Default: both.
4. Which plugins must exist before the first scope is useful? Default: rye-org plus rye-source-context.
5. How much of a source may be sampled before a person confirms its meaning? Default: metadata plus a small sample, 90-day window, public containers first.

### Operator (2026-09-07)
Result: done. Changed scripts/test-all.sh (orchestrates docker-test.sh plus
admin and site builds), .github/workflows/test.yml (runs it on PRs and pushes
to main), docs/runbooks/deploy.md (three deployable units, each with a
rollback line).
Tested: ./scripts/test-all.sh, full pass: SQL conformance, security,
concurrency, scenarios, and the node-dependent API/MCP/CLI security tests;
admin build; site build.
Learned: docker-test.sh test is already the full local SQL runner; this host
has docker, node 24, psql, and wrangler so the suite runs end to end; there
are no down-migrations, so schema rollback is restore-from-backup.
Questions: the workflow file cannot be pushed from this machine. Default:
Casey pushes it from an account with workflow scope.

### Architect (2026-09-07)
Result: done. Changed docs/architecture.md, docs/areas.md (four areas:
schema, agent-kit, admin, site), five contracts (sql-surface, rye-cli,
admin-api, plugin-manifest, docs-content), decisions 0001 and 0002.
Learned: admin has no npm test, build is the only gate; the agent kit's real
integration coverage lives in tests/conformance/21-23, owned by schema;
nothing validates plugin or skill manifests against their schemas, so the
plugin-manifest contract states an invariant no command enforces; the CLI's
--json is verbatim SQL output.
Questions for Casey, with the default assumed:
1. Keep agent-kit as an area despite its weak test? Default: keep; ask Operator for a manifest validator.
2. tests/** owned entirely by schema? Default: leave it; one runner, one suite.
3. Reference docs assigned to code areas? Default: as written.
4. Keep the docs-content contract? Default: keep.
5. surfaces/ folded into admin? Default: yes.

### Lead (2026-09-07)
Ran scripts/gen-agents: 9 roles, 4 builders, rendered for Claude Code,
OpenCode, and Codex. Codex TOML parses. Area records created under
docs/areas/ with empty Learned sections; the Learned lines above are filed
there.

### Review, Codex gpt-6-astra (2026-09-07)
Full text: work/000-bootstrap-review-astra.md. Verdict: keep area memory,
work items, and independent verification; cut compulsory handoffs; make
discover-classify-resolve the organizing product test; the branch
"formalizes assumptions faster than it validates them."
Adapter defects it found were confirmed and fixed the same day: builder
frontmatter failed YAML (unquoted colons), invariants were word-split by the
generator, Codex role files lacked name/description and used absolute paths.
Its design points (roles, areas, loop failure modes, first three work items)
are open for Casey's decision.

## Close
- status: done 2026-09-07. Open questions above await Casey; defaults stand until answered.

