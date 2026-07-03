# MCP And CLI Interface

Rye should expose the same connector-neutral intake contract through both CLI and MCP.

## CLI Role

The CLI is the reference implementation for deterministic work:

- local fresh installs
- batch imports
- CI/conformance tests
- validation before writes
- `--emit-sql` for SQL-only environments
- reproducible examples and fixtures

The CLI should never know whether data came from Composio, Slack API, Fathom API, IMAP, an MCP connector, or a local script.

## MCP Role

The MCP server should be the LLM-facing runtime wrapper over the same contract. It should expose narrow tools that constrain the model and hide raw SQL:

- `rye.catalog`
- `rye.search_nodes`
- `rye.node_summary`
- `rye.source_inventory`
- `rye.pending_context_confirmations`
- `rye.register_source_account`
- `rye.register_source_container`
- `rye.record_source_item`
- `rye.validate_source_context_update`
- `rye.commit_source_context_update`
- `rye.propose_knowledge_update`
- `rye.validate_knowledge_update`
- `rye.commit_knowledge_update`

The MCP server should call the same validator/SQL builder used by the CLI. It should set Rye session context on every database call, because many MCP or pooled SQL surfaces are stateless.

The trusted local/dev stdio implementation lives at `scripts/rye_mcp_server.mts`. It can accept a database target because it is meant for local operators and test harnesses. Run it with:

```bash
cd skills/rye-source-context-intake
npm install
RYE_DATABASE_URL="postgresql://..." npm run mcp
```

External agent runtimes should use the secure API-backed MCP server instead:

```bash
cd skills/rye-source-context-intake
RYE_API_URL="https://rye-admin.example.com" \
RYE_AGENT_TOKEN="rye_..." \
npm run mcp:api
```

The secure server does not expose DB/Docker target fields and does not register
promotion tools. Tool visibility comes from Rye API token capabilities, so a
read-only token sees only read tools and a candidate token can submit
observations/candidates without promotion rights.

## Recommended Order

1. Maintain the contract and CLI first.
2. Add test fixtures for Slack, Fathom, email, and files.
3. Wrap the same library in MCP tools.
4. Add a separate `knowledge_update` contract for semantic people/org/task/fact edges.

## Boundary

The MCP server is not an external-source connector. It is a Rye instance interface. External connectors produce source-context records; Rye MCP validates and stores them.
