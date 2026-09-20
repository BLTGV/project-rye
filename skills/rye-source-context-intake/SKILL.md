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
7. Use a separate validated knowledge-update step to create domain nodes,
   assertion candidates, tasks, and semantic edges.

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
5. Group assertion candidates through `review_queue`. Group structural
   candidates by source container, review context, kind, status, and confidence.
6. Do not accept assertion candidates or promote structural candidates into
   tasks or edges until review chooses the candidate and target shape.
7. If the next step cannot be executed without user confirmation, create or
   return a concise confirmation packet instead of guessing.

The default post-commit order is:

1. Source inventory and confirmation worklist.
2. Assertion and structural candidate review queues.
3. Explicit assertion acceptance or structural task/edge promotion.
4. Dedupe/supersession review.
5. Optional pruning or visibility changes for stale or low-signal source items.

## Intake Consistency: Four Rules

Conversation material produces all four of the defects blind reconstruction
caught, because a message says a person left, a summary reaches past what was
said, a message backdates a handoff, and a count is quoted without its period.
The rules and their examples are in `docs/agent-ops-guide.md` under "Intake
consistency" and in `rye-agent-ops`. The reads that find breakage afterwards
are in `skills/rye-pattern-library/references/intake-consistency-checks.md`.

Every example below is executable against the fixture in
`eval/intake_consistency/` and names the role it needs.

**1. A departure closes the edges it contradicts.** When a message says someone
left, record `employment_status` with the date, then name their open `employs`
and role edges to a person. You cannot close an edge: an agent-shaped session's
`UPDATE` on `edges` reports `UPDATE 0` and changes nothing. Say so plainly —
the relationship still reads as current until someone ends it.

```sql
-- As team_member, not as an agent.
SELECT set_config('app.current_role', 'team_member', false);

UPDATE edges e
SET effective_to = d.departed_at
FROM (
    SELECT a.subject_node_id AS person_id,
           a.effective_at    AS departed_at
    FROM current_valid_assertions a
    WHERE a.assertion_type = 'employment_status'
      AND a.claim->>'status' = 'departed'
      AND a.effective_at IS NOT NULL
) d
WHERE (e.source_id = d.person_id OR e.target_id = d.person_id)
  AND e.edge_type IN ('employs', 'reports_to', 'assigned_to',
                      'member_of', 'project_member', 'affiliated_with')
  AND e.archived_at IS NULL
  AND e.effective_to IS NULL;
```

**2. A digest asserts nothing its sources establish.** Record the claims the
messages support first, then distil over those claims. A detail that lives only
in a thread does not belong in a digest claim.

```sql
-- As an agent. Both claim keys come from the two cited sources.
SELECT set_config('app.current_role', 'agent:intake-fixture', false);

SELECT record_distillation(
    p_subject_node_id := (SELECT id FROM nodes WHERE label = 'Line 3 Retool'),
    p_subject_edge_id := NULL,
    p_assertion_key := 'status',
    p_claim := '{"status":"blocked","blocked_on":"gearbox",
                 "message_count":214,"peak_hour_utc":10}'::jsonb,
    p_source_assertion_ids := ARRAY(
        SELECT a.id FROM current_valid_assertions a
        WHERE a.subject_node_id = (SELECT id FROM nodes WHERE label = 'Line 3 Retool')
          AND a.assertion_type IN ('task_status', 'message_volume')
    ),
    p_source_event_ids := '{}'::uuid[],
    p_status := 'accepted',
    p_agent := 'agent:intake-fixture',
    p_attrs := '{"source_window":{"from":"2026-09-01T00:00:00Z",
                                  "to":"2026-09-30T00:00:00Z"}}'::jsonb
);
```

**3. An effective date and an edge window tell one story.** A message dated
September about a June handoff dates the claim June and the edge June. Put the
claim on the edge (`subject_edge_id`) or name it in `attrs.edge_id`. Correcting
a date already recorded takes `supersede_assertion()`; `record_assertion()`
returns the incumbent unchanged when the claim, basis and confidence match.

```sql
-- As an agent. Replaces the misdated claim with one dated off the edge.
SELECT set_config('app.current_role', 'agent:intake-fixture', false);

SELECT supersede_assertion(
    p_old_assertion_id := a.id,
    p_new_assertion_type := a.assertion_type,
    p_new_subject_node_id := NULL,
    p_new_subject_edge_id := e.id,
    p_new_claim := a.claim,
    p_new_assertion_key := a.assertion_key,
    p_new_effective_at := e.effective_from,
    p_new_basis := a.basis,
    p_new_evidence := ARRAY[jsonb_build_object(
        'kind', 'source',
        'event_id', (SELECT id FROM events
                     WHERE summary LIKE 'Staffing channel:%' LIMIT 1)
    )]
)
FROM assertions a
JOIN edges e ON e.id = a.subject_edge_id
WHERE a.assertion_type = 'assignment_status'
  AND a.superseded_at IS NULL
  AND a.effective_at < e.effective_from;
```

**4. A derived number cites its window.** A message count, a peak hour, an
average response time: put the period in
`attrs.source_window = {"from": ..., "to": ...}` and make sure it covers the
items cited as evidence. A number whose window is the whole export while the
count was over one week is wrong in a way nobody can see later.

```sql
-- As an agent. The replacement cites the window containing its source.
SELECT set_config('app.current_role', 'agent:intake-fixture', false);

SELECT supersede_assertion(
    p_old_assertion_id := a.id,
    p_new_assertion_type := a.assertion_type,
    p_new_subject_node_id := a.subject_node_id,
    p_new_subject_edge_id := NULL,
    p_new_claim := a.claim,
    p_new_assertion_key := a.assertion_key,
    p_new_effective_at := a.effective_at,
    p_new_basis := a.basis,
    p_new_evidence := ARRAY[jsonb_build_object(
        'kind', 'derivation',
        'source_assertion_id', (SELECT s.id FROM current_valid_assertions s
                                WHERE s.assertion_type = 'task_status'
                                LIMIT 1)
    )],
    p_new_attrs := '{"source_window":{"from":"2026-09-01T00:00:00Z",
                                      "to":"2026-09-30T00:00:00Z"}}'::jsonb
)
FROM assertions a
WHERE a.assertion_type = 'throughput_estimate'
  AND a.superseded_at IS NULL;
```

Post-commit, run the four checks over what the run wrote and report each
finding in the confirmation packet.

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

A committed run prints `{"ok": true, "run_id": ..., "summary": ...,
"waiting_for_review": [...]}`. `waiting_for_review` lists everything the area's
review policy filed as a suggestion instead of an answer: the earlier claim, if
there was one, is still the current one until a person accepts the new one, and
`summary.waiting_for_review` counts them. The commit itself still succeeded.
Report those subjects in the post-commit worklist below rather than describing
them as updated. Each entry names the policy that held it —
`review_policy`, from the row's own `attrs.review_gate`, and null on a row
written before Rye recorded that marker — and `still_current_assertion_id`, the
claim that still answers, which is null when the claim is new and nothing stood
before it.

Every assertion this commit writes has basis `reported`, so under
`candidates_only` all of them wait: that policy keeps only `observed` writes
accepted. Expect a full `waiting_for_review` list there, not an exception.

Rerunning the same input is safe. Before writing, the commit looks for a
suggestion already waiting with the same claim on the same subject and key; if
one is there it writes nothing and lists it again with `filed_this_run` false.
`filed_this_run` true means this run put it there. A different claim still
files a new suggestion. So the natural next step after a waiting report — fix
something and run again — does not pile identical suggestions onto one subject.
It also does not write while one is waiting even if the policy has since been
opened: accept or decline the waiting suggestion instead.

## MCP

Use `scripts/rye_mcp_server.mts` when an LLM client needs a Rye instance interface. It exposes read tools (`rye.catalog`, `rye.search_nodes`, `rye.node_summary`, `rye.source_inventory`, `rye.pending_context_confirmations`) and source-context write tools (`rye.validate_source_context_update`, `rye.commit_source_context_update`).

For untrusted or external agent runtimes, use `scripts/rye_api_mcp_server.mts`
instead. It reads `RYE_API_URL` and `RYE_AGENT_TOKEN`, never accepts `db_url` or
Docker target inputs, and registers tools only from the token's granted
capabilities. Keep `rye_mcp_server.mts` as trusted local/dev tooling.

## References

- For record shapes and examples, read `references/source-context-contract.md`.
- For MCP vs CLI wrapping guidance, read `references/mcp-cli-interface.md`.
