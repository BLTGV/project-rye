# Pattern: Slack Conversation Evidence

## Purpose

Preserve Slack messages and threads as replayable evidence for operational and
governance candidates without treating conversation as accepted business state.

## Source Contracts

| Slack object | Rye representation |
|---|---|
| workspace | `source_account` |
| channel | `source_container` |
| relevant message or thread | `source_item` plus an artifact or compact content reference |
| Slack API, MCP, or connector | `retrieval_channel` |
| workspace user | `source_identity` |

A Slack source identity uses a stable key such as
`slack:team:<team_id>:user:<user_id>`. A confirmed `identity_of` edge points
from that source identity to a person node. Display names are labels only and
must not drive identity resolution.

Use `source_identity_confirmation` to preserve who confirmed or rejected the
mapping, when, and from what evidence. Supersede the assertion if the mapping is
corrected.

## Message Properties

Message-level source items follow
`../schemas/slack_conversation_source_item.schema.json`.

Preserve source times separately:

- `occurred_at`: provider message time
- `edited_at`: provider edit time, when present
- `deleted_at`: provider deletion time, when present
- `retrieved_at`: when Rye observed the provider state

An extracted candidate may also have a business-effective time and date-quality
classification. Those belong to the candidate interpretation, not the source
message properties.

Prefer a thread source item when the thread is the meaningful evidence unit.
Use message-level items when a permalink, edit history, speaker, or individual
statement must be audited.

## Promotion Boundary

- A message is an observation.
- An extracted status, task, decision, procedure, or authority statement is a
  candidate.
- Channel names, membership, display names, and message text do not establish
  source context, person identity, role, or business authority.
- A procedure or authority statement can become accepted only through the same
  policy-aware promotion path as any other candidate.

Store compact source references when possible. Apply classification and
retention policy before preserving message bodies or attachments.

## Example

```json
{
  "schema_type": "rye.source_context.slack_source_item.properties.v1",
  "schema_version": 1,
  "provider": "slack",
  "team_id": "T001",
  "channel_id": "C-DEALS",
  "message_id": "1720611000.000100",
  "thread_id": null,
  "reply_to_message_id": null,
  "speaker_source_identity_ref": "slack:team:T001:user:U-SALES-1",
  "occurred_at": "2026-07-10T13:30:00Z",
  "edited_at": null,
  "deleted_at": null,
  "retrieved_at": "2026-07-10T13:30:08Z",
  "lifecycle_state": "active",
  "external_url": "https://example.slack.com/archives/C-DEALS/p1720611000000100",
  "content_hash": "sha256:example"
}
```

## Tests

- the same workspace, channel, message, and user IDs produce stable references
- occurrence, edit, deletion, retrieval, and business-effective times do not
  collapse into one timestamp
- an unconfirmed source identity cannot satisfy business authority
- an edited message creates new source evidence without duplicating an already
  idempotent candidate or decision
- missing conversation evidence remains `missing_evidence`, not proof of
  noncompliance
