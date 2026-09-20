# Retrieval Trace Format

The scorer reads traces, not databases. A trace is what one arm did on one
scenario: for each question, every retrieval call it made, in order, and the
answer it settled on.

This is the eval-time half of issue #21. It writes nothing to Rye and does not
depend on `log_agent_query()`, so read-only agents — which are forbidden from
logging by `rye-knowledge-reader` — can still be measured.

The step shape below is also the production one. `log_agent_query()`'s
`p_trace` argument takes a step with these field names, by
`contracts/sql-surface.md` ("Retrieval tracing") and decision `0011`, so one
reader handles a harness trace and a loop recovered from `agent_query` events
alike. Where the two differ, the contract wins and this file says so.

## Why the steps matter more than the answer

A wrong answer is the same shape whatever caused it. The step list is what
separates the causes, and each cause has a different fix:

| Observed in the trace | Bucket | Fix |
|---|---|---|
| Expected entry node never appeared in any step's results | `entry_missed` | Vocabulary visibility, reformulation prompting, or a semantic index |
| Entry found, no traversal step returned the expected edges | `path_not_found` | Depth ceiling, direction, or semantics arguments |
| Entry found, question is cross-subject, no aggregation possible | `cross_subject` | Cohort digests |
| Expected evidence was returned but the answer is wrong | `misjudged` | Agent reasoning, not retrieval |
| Nothing to find; agent answered anyway | `confabulated` | Refusal behavior |

Without the steps, all five look identical.

## Shape

```json
{
  "arm": "rye_graph",
  "scenario": "harbor_point",
  "run_id": "2026-08-17T12:00:00Z-rye-graph-01",
  "results": [
    {
      "question_id": "q-causal-01",
      "steps": [
        {
          "seq": 1,
          "tool": "find_nodes_batch",
          "intent": "locate the project named in the question",
          "args": { "p_queries": ["Pier 9 Rebuild", "Pier 9"], "p_node_types": ["project"] },
          "results": [
            {
              "query": "Pier 9 Rebuild",
              "node_id": "fa000001-0003-0001-0001-000000000001",
              "score": 0.95,
              "match_reason": "exact_label",
              "used": true
            }
          ],
          "selected": {
            "node_id": "fa000001-0003-0001-0001-000000000001",
            "from_seq": 1,
            "from_phrasing": "Pier 9 Rebuild"
          }
        },
        {
          "seq": 2,
          "tool": "find_paths",
          "intent": "walk upstream for causes",
          "args": {
            "p_from_node_id": "fa000001-0003-0001-0001-000000000001",
            "p_direction": "in",
            "p_semantics": ["causal"],
            "p_max_depth": 3
          },
          "results": [
            {
              "node_path": [
                "fa000001-0003-0001-0001-000000000001",
                "fa000001-0004-0001-0001-000000000001",
                "fa000001-0001-0001-0001-000000000006"
              ],
              "edge_path": [
                "fa000002-0002-0001-0001-000000000002",
                "fa000002-0002-0001-0001-000000000001"
              ],
              "edge_type_path": ["affects", "affects"],
              "depth": 2
            }
          ]
        }
      ],
      "answer": {
        "refused": false,
        "text": "Rebar shortage caused by Coastal Steel Supply missing two deliveries.",
        "node_ids": [
          "fa000001-0004-0001-0001-000000000001",
          "fa000001-0001-0001-0001-000000000006"
        ],
        "cited_edge_ids": [
          "fa000002-0002-0001-0001-000000000001",
          "fa000002-0002-0001-0001-000000000002"
        ],
        "cited_assertions": [
          {
            "subject_node_id": "fa000001-0004-0001-0001-000000000001",
            "assertion_type": "issue_cause",
            "assertion_key": "default"
          }
        ]
      },
      "tokens": { "in": 4100, "out": 260 },
      "latency_ms": 1830
    }
  ]
}
```

## Fields

### Trace

| Field | Required | Meaning |
|---|---|---|
| `arm` | yes | Which system produced this. Free-form; used only for grouping. |
| `scenario` | yes | Must match a directory under `scenarios/`. |
| `run_id` | no | Anything unique. Recorded in the report. |
| `results` | yes | One entry per question attempted. Questions absent from `results` are scored as unattempted, not as failures. |

### Step

| Field | Required | Meaning |
|---|---|---|
| `trace_id` | in production | The caller's id for one loop. A file groups by containment and by `question_id`, so the harness does not need it; `log_agent_query()` **raises** without a non-empty one, because rows in `events` have nothing else to group them. Use the `question_id` when a run does both. |
| `seq` | yes | Integer, 1 or more, unique within the loop. The sort key. Ordering is never by time: `record_event()` stamps `occurred_at` with transaction start, so every step of one loop in one transaction shares a timestamp. |
| `tool` | no but wanted | `find_nodes`, `find_nodes_batch`, `find_paths`, `neighborhood`, `sql`, or an arm-specific name such as `vector_search`. |
| `intent` | no but wanted | Why this call was made. The one field a SQL-layer capture cannot produce, and the one that explains a miss. |
| `args` | no | Arguments as passed, under the parameter names the function declares — `p_queries`, `p_node_types`, `p_threshold`, `p_max_depth`, `p_semantics`, `p_direction`. `p_threshold` and `p_max_depth` are what tell you whether a miss was a tuning problem. |
| `results` | no | What came back, including the candidates the step passed over. `node_id`, `edge_path`, and `edge_type_path` are the fields the scorer reads; everything else is ignored and safe to include. |
| `selected` | no | `{node_id, from_seq, from_phrasing}` — which step's phrasing produced the candidate that was used. In production `properties.query` already holds this step's phrasing, so `from_seq` is the load-bearing part and `from_phrasing` is a convenience copy for a reader holding one event and not the loop. |

A result element carries `node_id`, `score`, `match_reason`, and `used`. `used`
false is a rejected candidate, and recording those is the point: the right node
returned at rank 3 and passed over is a prompting fix, while the right node
never returned is a threshold or vocabulary fix. **Cap them** — ten per step is
plenty. An event is immutable and there is no pruning path, so an unbounded
candidate list is a storage decision nobody asked for.

A step with an empty `results` array is meaningful — it records a reformulation
that found nothing, which is exactly what distinguishes "never tried" from
"tried and missed". Omitting `results` says the same thing to the scorer; write
the empty array, because absent and empty read differently to a person.

### Answer

| Field | Required | Meaning |
|---|---|---|
| `refused` | yes | True when the arm declined to answer. Scored against `answerable`. |
| `text` | no | Matched case-insensitively against `expected_claim_contains`. |
| `node_ids` | no | Entities the answer asserts. |
| `cited_edge_ids` | no | Edges offered as support. Checked against both `expected_edge_ids` and `forbidden_evidence`. |
| `cited_assertions` | no | `{subject_node_id, assertion_type, assertion_key}` tuples, not ids — seed assertion ids are generated at load time and must never be pinned. |

## Arms

`arm` is free-form so the scorer stays comparison-agnostic. The intended set:

- `rye_graph` — `find_nodes_batch` / `find_paths` / `neighborhood`
- `rag_baseline` — chunk-and-embed over the same source material
- `hybrid` — both

Only `rye_graph` is currently producible without external infrastructure. The
baseline arms need an embedding provider and a driver, which live outside this
repo.

## Producing a trace

Not automated here. An agent runs the scenario and emits this JSON, either by
wrapping its retrieval calls or by being asked to record them. The format is
deliberately simple enough to hand-write and to read out of psql, which is how
`traces/` was built: the args and results in every step there were recorded
against the seeded fixture, and only the answers are written by hand, so that
each failure bucket fires and the scorer's own behavior is checkable without an
LLM in the loop.

## The same step, written to the database

A session that may write can also emit each step as it goes, with the fifth
argument of `log_agent_query()`:

```sql
SELECT rye.log_agent_query(
    'harbor-analyst',
    'Pier 9 Rebuild',
    '1 candidate',
    ARRAY['fa000001-0003-0001-0001-000000000001'::uuid],
    jsonb_build_object(
        'trace_id', 'q-causal-01',
        'seq',      1,
        'tool',     'find_nodes_batch',
        'intent',   'locate the project named in the question',
        'args',     jsonb_build_object('p_queries', jsonb_build_array('Pier 9 Rebuild', 'Pier 9')),
        'results',  jsonb_build_array(jsonb_build_object(
                        'node_id', 'fa000001-0003-0001-0001-000000000001',
                        'score', 0.95, 'match_reason', 'exact_label', 'used', true)),
        'selected', jsonb_build_object(
                        'node_id', 'fa000001-0003-0001-0001-000000000001',
                        'from_seq', 1, 'from_phrasing', 'Pier 9 Rebuild')));
```

Read the loop back from `rye.agent_query_trace`, ordered by `trace_id` then
`seq`. RLS applies there as everywhere: an event is visible through its
participants, so a step logged with no node ids is readable only by an admin.
A step that found nothing is exactly that step, which is one more reason the
scorer reads files. A short trace never means a short loop.

Two things keep the halves apart, and both are deliberate. Tracing is a write,
so a `viewer`, a role-less session, and any role that may not write are refused
`42501` — the agents most worth measuring are the ones that may not log, which
is why the scorer reads files and never the database. And nothing auto-logs:
`find_nodes`, `find_nodes_batch`, `find_paths`, `neighborhood`,
`agent_node_summary()`, and `node_context` write no event. Emitting a step is
something the caller chooses to do.
