---
name: rye-source-context-intake
description: Register source accounts, containers, items, context profiles, and confirmation decisions in Rye without assuming external connector semantics. Use when ingesting Slack, email, Fathom, files, API records, Composio results, MCP connector output, or any other source material where an LLM must classify purpose, allowed contexts, provenance, and when semantic connections are safe to create.
---

# Rye Source Context Intake

Use this skill before turning external material into people, orgs, tasks, facts, or semantic edges.

## Core Rule

Connectors collect. Rye classifies, validates, records provenance, and stores evolving source context.

Do not infer business meaning from connector metadata alone. A Slack channel, Fathom team, folder, mailbox, workspace, or account name can be evidence, but it is not confirmed context until recorded as a confirmation decision.

Do not name onboarding scopes after the source or retrieval channel. Register
the source neutrally, then ask what organizational project, function, workflow,
or purpose the material supports.

## Workflow

1. Register source accounts and containers with neutral labels.
2. Mark new sources as `needs_confirmation`.
3. Store provider batches and raw metadata as provenance. Promote individual
   `source_item` nodes only when the item has evidence value, review value, a
   thread/file/link, or an explicit audit/replay requirement.
4. Classify each promoted item by content while source context is unconfirmed.
5. Ask for or record confirmation of source purpose, expected review contexts,
   default routing context if any, and what must never be inferred.
6. Only after confirmation should a source container supply default semantic
   context. Under onboarding scopes, prefer `expected_contexts` over hard
   context whitelists.
7. Use a separate validated knowledge-update step to create arbitrary people/org/task/fact edges.

## Post-Commit Next Steps

After committing source context records, do not stop at "data loaded." Run the
post-commit gate and report the next required human or agent action.

1. Verify counts by `node_type`, source accounts/containers still
   `needs_confirmation`, source items, artifacts, events, and candidate
   statuses.
2. Report collection scope explicitly:
   - provider/account
   - date window
   - included source types
   - excluded source types, especially direct messages, private messages, or
     low-signal records
   - raw artifact paths or durable provider links used for replay
3. Build a pending source-confirmation worklist for every source account and
   source container whose `confirmation_status` is `needs_confirmation`.
4. Do not mark a source `confirmed` unless the user or a trusted admin has
   explicitly confirmed:
   - source purpose
   - expected review contexts
   - default routing context, if any
   - facts that must never be inferred from this source
5. Group proposed knowledge candidates by source container, review context,
   candidate kind, status, and confidence. This is the candidate review queue.
6. Do not promote candidates into accepted facts, tasks, or edges until review
   chooses the candidate and target shape. Promotion belongs to the Rye
   knowledge-promotion helpers, not to source intake.
7. If the next step cannot be executed without user confirmation, create or
   return a concise confirmation packet instead of guessing.

The default post-commit order is:

1. Source inventory and confirmation worklist.
2. Candidate review queue.
3. Explicit promotion of accepted facts/tasks/edges.
4. Dedupe/supersession review.
5. Optional pruning or visibility changes for stale or low-signal source items.

## Source Item Granularity

Do not create first-class Rye nodes for every provider record by default. Broad
sources such as Slack channels, email inboxes, or shared folders can contain
low-signal chatter, duplicates, system messages, and private material that is
only useful as raw audit context.

For each candidate item, record:

- `source_value`: `evidence`, `context_signal`, `low_signal`, or `noise`.
- `persistence_reason`: why this item should exist as an individual Rye node.
- `visibility`: `default`, `collapsed`, or `hidden_by_default`.
- `external_url`: the provider-native link when the connector can provide it.

If an item is `noise`, skip the first-class node and count it in a run artifact
or report. If an item is `low_signal`, store it as an individual node only when
retention, replay, or later thread expansion requires it, and mark it
`hidden_by_default` or `collapsed`.

## Slack and Composio Intake Notes

For Slack via Composio:

- Use Slack search for broad 30-day collection or discovery of active channels.
  Use channel history for targeted expansion, thread reconstruction, or replay.
- If history calls are rate-limited, preserve partial progress and switch to
  active-channel search rather than repeatedly walking dormant channels.
- Exclude IM/DM/MPIM results unless the user explicitly authorizes direct-message
  ingestion for this run. Report the number excluded.
- Store Slack channel messages as `source_item` records only when they are
  evidence, context signals, thread/file/link references, or needed for replay.
- Treat Slack channel names as routing hints. They do not confirm source purpose
  or business relationships.
- Do not turn the channel name or Composio retrieval path into the onboarding
  scope name. The scope name should come from the project or organizational
  purpose the Slack evidence supports.
- Store provider permalinks where available.
- For threaded results, prefer one useful thread/batch source item when the
  thread is the meaningful unit. Store individual messages when the connector
  result, permalink, or evidence needs message-level traceability.

## CLI

Use the bundled script for deterministic validation and SQL generation:

```bash
node skills/rye-source-context-intake/scripts/source_context_commit_rye.mts \
  --input /tmp/source-context.ndjson \
  --emit-sql > /tmp/source-context.sql
```

Or write directly:

```bash
node skills/rye-source-context-intake/scripts/source_context_commit_rye.mts \
  --input /tmp/source-context.ndjson \
  --db-url "$DATABASE_URL"
```

Use `--validate-only` to check record shape without writing.

## MCP

Use `scripts/rye_mcp_server.mts` when an LLM client needs a Rye instance interface. It exposes read tools (`rye.catalog`, `rye.search_nodes`, `rye.node_summary`, `rye.source_inventory`, `rye.pending_context_confirmations`) and source-context write tools (`rye.validate_source_context_update`, `rye.commit_source_context_update`).

For untrusted or external agent runtimes, use `scripts/rye_api_mcp_server.mts`
instead. It reads `RYE_API_URL` and `RYE_AGENT_TOKEN`, never accepts `db_url` or
Docker target inputs, and registers tools only from the token's granted
capabilities. Keep `rye_mcp_server.mts` as trusted local/dev tooling.

## References

- For record shapes and examples, read `references/source-context-contract.md`.
- For MCP vs CLI wrapping guidance, read `references/mcp-cli-interface.md`.
