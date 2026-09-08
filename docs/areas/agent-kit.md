# agent-kit

Purpose: What an agent is given: skills as procedures, plugins as vocabulary manifests, and replay scenarios that grade whether a clean-room agent can actually do the job. Includes the MCP servers and intake scripts skills shell out to.
Paths: skills/** plugins/** eval/** docs/onboarding.md docs/agent-ops-guide.md docs/conventions-catalog.md
Test: npm --prefix skills/rye-source-context-intake run check && bash tests/conformance/22_secure_mcp_simulation.sh

## Learned
Dated entries. What a stranger would need to know and could not read from the code.
- 2026-09-07: real integration coverage lives in tests/conformance/21, 22, 23, which are owned by schema. The area's own test is a syntax check plus one MCP simulation.
- 2026-09-07: nothing validates rye-plugin.json or rye-skill.json against the schemas beside them; contracts/plugin-manifest.md states an invariant no command enforces.
- 2026-09-08: rye-skill.json entrypoint types in use are skill_install, cli_command, db_function, bootstrap_script (cli_command, not cli).
- 2026-09-08: scripts/sync_plugin_metadata.sh copies the whole requires and capabilities blobs into a skill_capabilities assertion, so new manifest keys reach the graph with no script change. That is the joint between skill metadata and the graph.
- 2026-09-08: every rye-skill.json carries a $schema key that skills/rye-skill.schema.json forbids via additionalProperties:false. A future manifest validator must allow $schema or all ten manifests fail.
- 2026-09-08: the discover step is written into rye-agent-ops, rye-domain-onboarding, and rye-knowledge-reader SKILL.md files and docs/agent-ops-guide.md, using the field names from contracts/category-vocabulary.md.
