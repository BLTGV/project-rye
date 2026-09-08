# agent-kit

Purpose: What an agent is given: skills as procedures, plugins as vocabulary manifests, and replay scenarios that grade whether a clean-room agent can actually do the job. Includes the MCP servers and intake scripts skills shell out to.
Paths: skills/** plugins/** eval/** docs/onboarding.md docs/agent-ops-guide.md docs/conventions-catalog.md
Test: npm --prefix skills/rye-source-context-intake run check && bash tests/conformance/22_secure_mcp_simulation.sh

## Learned
Dated entries. What a stranger would need to know and could not read from the code.
- 2026-09-07: real integration coverage lives in tests/conformance/21, 22, 23, which are owned by schema. The area's own test is a syntax check plus one MCP simulation.
- 2026-09-07: nothing validates rye-plugin.json or rye-skill.json against the schemas beside them; contracts/plugin-manifest.md states an invariant no command enforces.
