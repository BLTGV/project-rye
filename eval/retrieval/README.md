# Retrieval Eval Harness

Measures whether Rye's retrieval surfaces answer real questions, and — when
they do not — **why**, in a way that names which piece of work would fix it.

This is the instrument the open decisions in issue #17 depend on. Cohort
digests and an optional semantic index are both deliberately gated on numbers
from here rather than on argument.

## Run

```bash
# Load the fixture into a Rye database (once)
psql "$DATABASE_URL" -f eval/retrieval/scenarios/harbor_point/seed.sql

# Score whatever traces are present
node eval/retrieval/score_retrieval.mjs
node eval/retrieval/score_retrieval.mjs --write          # refresh report.md
node eval/retrieval/score_retrieval.mjs --trace path.json
```

The scorer needs no database and no dependencies. Its input is a trace; the
database is only needed to produce one.

A trace is usually hand-written, so a missing field is the common mistake. The
scorer checks every field it will dereference before it starts, and says which
file and which field in one line, then exits 1. Two fixtures under
`traces/malformed/` demonstrate that; the directory is skipped by a plain run,
so they never enter a score.

```
$ node eval/retrieval/score_retrieval.mjs --trace eval/retrieval/traces/malformed/no_scenario.json
eval/retrieval/traces/malformed/no_scenario.json: scenario: required, and must name a directory under scenarios/

$ node eval/retrieval/score_retrieval.mjs --trace eval/retrieval/traces/malformed/step_without_seq.json
eval/retrieval/traces/malformed/step_without_seq.json: results[0].steps[1].seq: required: a whole number of at least 1, ordering this step within the loop
```

The seed sets `app.current_role = 'admin'` itself, because the write gate
refuses a `viewer` and a role-less session; the database role running `psql`
needs INSERT on the `rye` tables. It ends by checking its own outcome: under a
scope whose review policy is `strict`, or `candidates_only` with a basis other
than observed, `record_assertion()` files suggestions instead of current
claims, and it stops with a message naming that rather than leaving a fixture
whose direct-fact questions all score as retrieval misses.

The fixture loads into any Rye install. Producing a `rye_graph` trace against
it additionally needs the traversal surfaces — `find_nodes`,
`find_nodes_batch`, `find_paths`, `neighborhood` and the `edge_semantics`
registry, all from migration `0032`. The `causal_path` questions are
meaningless without the semantics filter: with it, the supplier-to-penalty
chain resolves in three hops; without it, the associative decoy returns a
spurious one-hop "cause".

## Why the trace, not the answer

Retrieval runs as a loop, not a call. The agent owns semantic matching — it
reformulates, narrows by type, judges candidates on `score` and
`match_reason`. Rye supplies primitives.

That makes the final answer nearly useless as a diagnostic, because a failure
looks identical whether the agent never generated a matching phrasing, the
threshold rejected a good one, it found the right node and misjudged it, or
the knowledge simply is not there. Four causes, four different fixes, one
observable outcome.

So the scorer reads the whole step list and assigns a mechanical cause:

| Bucket | What it means | What would fix it |
|---|---|---|
| `entry_missed` | The expected node never appeared in any step's results | Vocabulary visibility, reformulation prompting, or a semantic index |
| `path_not_found` | Entry found; expected evidence never returned by any call | Depth, direction, or semantics arguments |
| `cross_subject` | Answer needs aggregation across subjects | Cohort digests |
| `misjudged` | Evidence was returned and the answer is still wrong | Agent reasoning, not retrieval |
| `co_occurrence_as_causation` | An associative edge was cited as causal support | Nothing to build — the filter exists; it was not used |
| `confabulated` | Nothing to find; the agent answered anyway | Refusal behavior |
| `refused_answerable` | Everything needed was found and it still declined | Agent reasoning |

`entry_missed` deliberately outranks `refused_answerable`: an agent that
honestly declines because it never found the entity has an entry-point
problem, and calling that a refusal hides the only actionable cause.
`traces/bucket_entry_missed.json` and `traces/bucket_refused_answerable.json`
are that pair: both end in a refusal, and they land in different buckets.

One `traces/bucket_*.json` file per bucket holds a short failing trace, so the
scorer's assignment can be checked against the cause it is supposed to name.
Their steps were recorded against the seeded fixture; only the answers are
written by hand.

Trace shape is specified in [`trace_format.md`](trace_format.md). It is the
eval-time half of issue #21 — it writes nothing and does not depend on
`log_agent_query()`, so read-only agents can be measured. The same step shape
is what `log_agent_query()`'s `p_trace` accepts
(`contracts/sql-surface.md`, "Retrieval tracing"), so one reader handles a
harness trace and a production loop alike — but the scorer never reads the
database, because an agent that may not write cannot trace.

## Metrics and what each one decides

| Metric | Decides |
|---|---|
| `loop_recall` | Whether the entry-point problem is real at all |
| `loop_recall_within_budget` | Whether it is solved cheaply or by brute force |
| `mean_calls_to_entry` | Cost of the search loop; batching should keep this near 1 |
| `entry_found_by_difficulty` | **The semantic-index decision.** Splits misses into typo-class (fix by threshold) and abbreviation/paraphrase-class (only reformulation or embeddings reach these) |
| `failure_buckets.cross_subject` | **The cohort-digest decision** |
| `provenance_correctness` | The metric that separates Rye from a RAG baseline: every claim traceable to a real assertion or edge. Mechanically checkable here; structurally impossible for a chunk-and-embed arm |
| `correct_refusal` / `confabulation` | The other differentiator. Gaps in a graph are visible in a way gaps in a vector store are not — this is where that should show |
| `tokens_per_correct_answer` | If the graph arm wins on correctness at several times the cost, tune `neighborhood()` budgets before building anything new |

`answer_correctness` is the headline number and the least useful one: it cannot
discriminate between the follow-ups, because both would raise it.

### Proposed thresholds

Not settled. Argue with them before the harness is used to decide anything.

- Entry-point work is warranted if `loop_recall` < 0.90 **and** the misses are
  mostly abbreviation/paraphrase rather than typo-class.
- Cohort digests are warranted if `cross_subject` is ≥ 20% of failures **and**
  those questions are ones people actually ask — check that against the
  persona material in `eval/skill_replay`, not against intuition.
- A semantic index is warranted only if paraphrase misses survive after
  vocabulary visibility and reformulation prompting have been tried. It is the
  expensive fix, so it should be the last one tested.

## Scenario

`scenarios/harbor_point/` is a fictional fabrication company, built to
discriminate rather than to be representative. Every element exists to make one
measurement possible:

- near-duplicate labels (`Meridian Fence & Gate` / `Meridian Fencing Supply`)
- an abbreviation-only label (`HPF Drydock`) that no threshold reaches: the
  natural phrasing scores 0.2500 against it, under the 0.35 floor, while the
  parent company scores 0.7576 on the same query, so the miss arrives as the
  wrong company rather than as an empty result
- a paraphrase-only target ("the fence company")
- a 3-hop causal chain with a real answer
- an **associative decoy**: a `regarding` edge connecting the two ends of that
  chain directly, so an unfiltered traversal returns a spurious 1-hop "cause"
- one root cause upstream of two of three delayed projects, for the
  cross-subject question
- three questions whose answers are absent, including one where the node is
  named for a cost that is never quantified

Citing the decoy fails the question outright, even when the conclusion happens
to be true: "X caused Y because X and Y are mentioned together" does not become
right when X did cause Y, and scoring it correct would hide the failure the
fixture exists to catch.

## What is not built

Stated plainly so the harness is not mistaken for a completed comparison.

- **No RAG baseline arm.** `arm` is free-form and the scorer is comparison
  agnostic, but producing `rag_baseline` or `hybrid` needs an embedding
  provider and a driver, which live outside this repo.
- **No trace producer.** An agent runs the scenario and emits the JSON. The
  format is simple enough to hand-write and to read out of psql, which is how
  `traces/` was built.
- **No model has run against this.** Every step in `traces/` was recorded by
  hand from psql against the seeded fixture, so the ids, scores, match reasons
  and edge paths are real. The *answers* are written, chosen to make each
  bucket fire, so the scorer's own behavior is checkable without an LLM in the
  loop. The metrics in `report.md` are therefore a property of those written
  answers and say nothing about Rye. There is no token or latency data either,
  so `tokens_per_correct_answer` reports `n/a`.
- **One scenario, 16 questions.** Enough to validate the instrument, not to set
  a threshold. Roughly 40–60 across several scenarios before a 20% cutoff is
  more than noise — at 16, one question is six points.
- **Real tenant data.** The conclusions that matter need the production graphs,
  not a 15-node fixture.
