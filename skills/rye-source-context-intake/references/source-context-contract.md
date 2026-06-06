# Source Context Contract

This contract is connector-neutral. Records may come from Composio, a direct API client, an MCP connector, a custom scraper, an email parser, or a local file.

## Principles

- Source metadata is provenance, not business truth.
- New accounts and containers start as `needs_confirmation`.
- Unconfirmed sources may store items and provenance, but should not create semantic business edges by default.
- Provider collection is not the same as Rye promotion. Do not create a first-class
  `source_item` node for every provider record unless the item has evidence
  value, review value, a thread/file/link, or a specific audit/replay reason.
- Include a provider-native `external_url` whenever the connector can provide a
  durable link to the original item.
- Confirmed context changes are new assertions that supersede old assertions; do not silently rewrite history.
- Broad sources such as email should normally classify per item, thread, folder, sender pattern, or rule instead of using a global default.

## Record Kinds

### `source_account`

Represents a connected account, workspace, tenant, mailbox, API account, or source system account.

```json
{
  "kind": "source_account",
  "id": "slack:team:T0AN32YJH",
  "label": "Slack Workspace: BLTGV",
  "provider": "slack",
  "confirmation_status": "needs_confirmation",
  "metadata": {
    "team_id": "T0AN32YJH"
  },
  "evidence": [
    "Connector authentication succeeded."
  ]
}
```

### `source_container`

Represents a channel, folder, Fathom team, mailbox folder, shared drive, project space, or other provider subdivision.

```json
{
  "kind": "source_container",
  "id": "slack:team:T0AN32YJH:channel:C123",
  "label": "#general",
  "source_account_id": "slack:team:T0AN32YJH",
  "container_type": "slack_channel",
  "confirmation_status": "needs_confirmation",
  "metadata": {
    "channel_id": "C123"
  },
  "holding_context_id": "uncategorized_intake",
  "never_infer": [
    "Do not infer company membership from channel membership alone."
  ]
}
```

`holding_context_id` is allowed while unconfirmed. `default_context_ids`
requires `confirmation_status: "confirmed"`.

Under an onboarding scope, prefer `expected_contexts` policy assertions for
routing expectations. Older intake records may still use `allowed_context_ids`
as a confirmation field; treat it as a compatibility alias for expected review
contexts, not as a closed whitelist unless a separate policy makes it one.

When the provider-native container label is generic, namespace it in `label`
and preserve the native value in metadata. For example, a Fathom team whose
native label is `Uncategorized` should be displayed as
`Fathom team: Uncategorized`, with metadata such as:

```json
{
  "container_type": "fathom_team",
  "metadata": {
    "native_label": "Uncategorized",
    "provider_scope": "default_recording_team"
  }
}
```

Do not use a bare label such as `Uncategorized`, `Inbox`, or `General` when it
could be confused with another provider, another account, or a Rye review
context.

### `source_item`

Represents a message, meeting, email, file, transcript, task, row, or record.

```json
{
  "kind": "source_item",
  "id": "fathom:recording:146156285",
  "label": "Trey <> Casey <> WVMC",
  "source_container_id": "fathom:team:uncategorized",
  "item_type": "meeting_recording",
  "occurred_at": "2026-06-03T14:00:00Z",
  "external_url": "https://fathom.video/share/...",
  "source_value": "evidence",
  "visibility": "default",
  "persistence_reason": "Meeting summary contains candidate facts and tasks that need provenance.",
  "content_hash": "sha256:...",
  "metadata": {
    "provider": "fathom"
  },
  "classification": {
    "context_ids": ["legal_ediscovery"],
    "confidence": 0.84,
    "rationale": "The summary discusses discovery workflow and email import tooling.",
    "evidence": ["Email discovery tool", "PST import"]
  }
}
```

`source_value` should be one of:

| Value | Meaning |
|---|---|
| `evidence` | Direct support for a candidate fact, task, decision, obligation, or relationship. |
| `context_signal` | Useful for routing or context understanding, but not enough by itself to create accepted knowledge. |
| `low_signal` | Retained only for audit, replay, dedupe, or because it belongs to a larger thread/batch. |
| `noise` | Should not be promoted as a first-class Rye node; count or summarize it in a run artifact instead. |

`visibility` should be `default`, `collapsed`, or `hidden_by_default`. Use
`collapsed` or `hidden_by_default` for low-signal material so it does not appear
as important knowledge to a human reviewer.

For threaded providers, prefer one source item for the useful thread/batch over
separate nodes for each small message. The source item label should describe the
thread or useful content, not just the first trivial message.

### `context_profile`

Represents why a set of information is being reviewed and what connections are appropriate.

```json
{
  "kind": "context_profile",
  "id": "legal_ediscovery",
  "label": "Legal E-Discovery",
  "purpose": "Track litigation-support work, discovery obligations, tooling decisions, risks, and responsible parties.",
  "relevance_rules": [
    "Store facts involving discovery scope, custodians, deduplication, privilege, production, or legal risk."
  ],
  "edge_policies": [
    "Connect vendors and counterparties only when directly involved in discovery work."
  ],
  "task_policy": "Create tasks for import, deduplication, validation, evidence handling, and legal follow-up."
}
```

### `context_confirmation`

Represents a user or trusted admin decision that changes how a source should be interpreted.

```json
{
  "kind": "context_confirmation",
  "subject_id": "slack:team:T0AN32YJH:channel:C123",
  "status": "confirmed",
  "confirmed_by": "casey",
  "confirmed_at": "2026-06-03T18:30:00Z",
  "purpose": "Track general operational coordination for BLT.",
  "allowed_context_ids": ["recon_ops", "ai_tooling"],
  "default_context_ids": ["recon_ops"],
  "never_infer": [
    "Do not infer employment or ownership from channel participation."
  ]
}
```

In new onboarding-scope policy, store this as `expected_contexts` on the scope
or intake profile. Keep `allowed_context_ids` only for compatibility with older
source-confirmation records.

## Validation Rules

- `id` must be stable across runs.
- `source_container.source_account_id` must refer to a source account in the same input or an existing Rye node.
- `source_item.source_container_id` should refer to a container unless the connector exposes only account-level items.
- `default_context_ids` is valid only for confirmed containers or confirmation records with `status: "confirmed"`.
- `allowed_context_ids`, when present in source-confirmation records, means expected review contexts unless a scope policy explicitly defines it as a hard allowlist.
- `classification.context_ids` on source items is a proposal, not confirmation of source default context.
- `external_url`, when present, must be an `http` or `https` URL for the original provider item.
- `source_item` records with `source_value: "noise"` should fail human review and should normally be skipped before commit.
- `low_signal` source items require a `persistence_reason` and should use `visibility: "collapsed"` or `visibility: "hidden_by_default"`.
- Never create `member_of`, `vendor_of`, `counterparty_of`, `owns_workstream`, or similar semantic edges from account/container metadata alone.

## Post-Commit Review State

A successful source-context commit is not the end of the Rye workflow. It should
leave a reviewable state with clear next actions.

Expected state after source intake:

- Source accounts and containers are present and usually still
  `needs_confirmation`.
- Source items and artifacts preserve evidence and replay context.
- Classification assertions and `reviewed_under` edges are proposals.
- Knowledge candidates, if created by a parser or agent, are `proposed`.
- Accepted facts/tasks/edges remain unchanged unless a separate promotion step
  was explicitly executed.

Required next-step report:

```json
{
  "source_inventory": {
    "source_accounts": 1,
    "source_containers": 8,
    "source_items": 153,
    "artifacts": 153
  },
  "pending_confirmations": [
    {
      "subject_id": "slack:team:T0AN32YJH:channel:C123",
      "label": "Slack channel: #example",
      "candidate_purpose": "What the source appears to contain, if known",
      "candidate_allowed_context_ids": ["slack_recent_intake"],
      "must_confirm": [
        "source purpose",
        "allowed review contexts",
        "default review context",
        "never-infer rules"
      ]
    }
  ],
  "candidate_review_queue": {
    "proposed": 84,
    "by_kind": { "fact": 58, "task": 26 },
    "by_source_container": []
  },
  "blocked_until_user_confirms": [
    "Do not apply default source context",
    "Do not promote candidate facts/tasks/edges"
  ]
}
```

Use `context_confirmation` records only after the confirmation decision is known.
Until then, create a worklist or proposed task; do not synthesize confirmation
records from connector metadata.

## Rye Mapping

| Contract record | Rye node type | Important writes |
|---|---|---|
| `source_account` | `source_account` | node properties, `source_purpose` assertion if provided |
| `source_container` | `source_container` | provenance edge from account, confirmation properties, optional purpose assertion |
| `source_item` | `source_item` | provenance edge from container/account, artifact with raw content/metadata, external URL, source value/visibility, classification assertions |
| `context_profile` | `review_context` | purpose, relevance rules, edge policies, task policy assertions |
| `context_confirmation` | existing source node | superseded confirmation/purpose/default-context assertions |
