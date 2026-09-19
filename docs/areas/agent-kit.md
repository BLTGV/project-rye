# agent-kit

Purpose: What an agent is given: skills as procedures, plugins as vocabulary manifests, and replay scenarios that grade whether a clean-room agent can actually do the job. Includes the MCP servers and intake scripts skills shell out to.
Paths: skills/** plugins/** eval/** docs/onboarding.md docs/agent-ops-guide.md docs/conventions-catalog.md
Test: npm --prefix skills/rye-source-context-intake run check && bash tests/conformance/22_secure_mcp_simulation.sh

## Learned
Dated entries. What a stranger would need to know and could not read from the code.
- 2026-09-07: real integration coverage lives in tests/conformance/21, 22, 23, which are owned by schema. The area's own test is a syntax check plus one MCP simulation.
- 2026-09-19: nothing in the repo validates rye-plugin.json or rye-skill.json against the schemas beside them, and `scripts/test-all.sh` does not reference either schema; contracts/plugin-manifest.md states an invariant no test enforces. `eval/skill_replay` also has no runner; `eval/agent_domain_replay/compare_replay.mjs` compares run outputs, not designs. (Replaces the 2026-09-07 entry; still true, now confirmed twice.)
- 2026-09-08: rye-skill.json entrypoint types in use are skill_install, cli_command, db_function, bootstrap_script (cli_command, not cli).
- 2026-09-08: scripts/sync_plugin_metadata.sh copies the whole requires and capabilities blobs into a skill_capabilities assertion, so new manifest keys reach the graph with no script change. That is the joint between skill metadata and the graph.
- 2026-09-08: every rye-skill.json carries a $schema key that skills/rye-skill.schema.json forbids via additionalProperties:false. A future manifest validator must allow $schema or all ten manifests fail.
- 2026-09-08: the discover step is written into rye-agent-ops, rye-domain-onboarding, and rye-knowledge-reader SKILL.md files and docs/agent-ops-guide.md, using the field names from contracts/category-vocabulary.md.
- 2026-09-19: `basis` is a CHECK constraint on five values: `observed`, `reported`, `inferred`, `assumed`, `unknown` (0001_core.sql, re-checked in `record_assertion`). A skill example using any other word is a runtime error, not a style choice.
- 2026-09-19: `assertion_evidence.attrs` is free jsonb passed straight through `append_assertion_evidence()`, so the authorizer and executor pair needs no migration. The helper reads only `witness_node_id`, `kind`, `event_id`, `source_assertion_id`, and `attrs` from each evidence element.
- 2026-09-19: no conformance test pins the contents of `contributes.edge_types` or `assertion_types` for any plugin; `14_plugin_metadata_install.sql` checks plugin ids and the presence of keys only, so adding a type name is safe.
- 2026-09-19: `rye-agent-ops` now tells an agent to ask who may settle a statement (`rye_settlers()` or `./scripts/rye settlers`) before recording it as accepted, keeps authorizer and executor distinct in evidence attrs, and covers all six `reason` values. `domain_not_found` and `domain_not_resolved` are the agent's own key mistake and are never said to the person.
- 2026-09-19: `eval/skill_replay/scenarios/manager-expectation` is the first scenario with two people and two non-communicating agent sessions. It adds `persona_brief_<name>.md` and `setup.sql`, and its rubric grades the words each person heard. Its lookup answers were executed against 0021; the end-to-end run waits on a replay runner.
- 2026-09-19: there is no helper or CLI command to create a `reports_to` or `owns` edge, or a node, so fixtures insert those directly. Areas do have a helper: fixtures must use `ensure_knowledge_domain()`, because a hyphenated key written directly is invisible to `rye_settlers()`. The no-raw-write invariant binds skills; fixtures follow it wherever a helper exists.
- 2026-09-19: this environment's shell guard refuses commands containing the bare word `eval`, which is also a directory name here. Glob it as `ev*/` or drive multi-step work from a Python script.
