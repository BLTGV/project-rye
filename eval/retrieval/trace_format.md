# Retrieval Trace Format

The scorer reads traces, not databases. A trace is what one arm did on one
scenario: for each question, every retrieval call it made, in order, and the
answer it settled on.

This is the eval-time half of issue #21. It writes nothing to Rye and does not
depend on `log_agent_query()`, so read-only agents — which are forbidden from
logging by `rye-knowledge-reader` — can still be measured.

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
          "args": { "queries": ["Pier 9 Rebuild", "Pier 9"], "p_node_types": ["project"] },
          "results": [
            {
              "query": "Pier 9 Rebuild",
              "node_id": "fa000001-0003-0001-0001-000000000001",
              "score": 0.95,
              "match_reason": "exact_label"
            }
          ]
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
              "edge_type_path": ["affects", "affects"]
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
| `seq` | yes | 1-based order. Preserves ordering when timestamps collide. |
| `tool` | yes | `find_nodes`, `find_nodes_batch`, `find_paths`, `neighborhood`, `sql`, or an arm-specific name such as `vector_search`. |
| `intent` | no but wanted | Why this call was made. The one field a SQL-layer capture cannot produce, and the one that explains a miss. |
| `args` | no | Arguments as passed. `p_threshold` and `p_max_depth` are what tell you whether a miss was a tuning problem. |
| `results` | yes | What came back. `node_id`, `edge_path`, and `edge_type_path` are the fields the scorer reads; everything else is ignored and safe to include. |

A step with an empty `results` array is meaningful — it records a reformulation
that found nothing, which is exactly what distinguishes "never tried" from
"tried and missed".

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
deliberately simple enough to hand-write, which is how
`traces/example_rye_graph.json` was built — it exercises every bucket so the
scorer's own behavior can be checked without an LLM in the loop.
