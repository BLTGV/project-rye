# 0011 Retrieval tracing is a step on the event

Date: 2026-09-20. Work item: `work/015-retrieval-eval-and-tracing.md`.
Contract: `contracts/sql-surface.md`, section "Retrieval tracing". Areas:
schema, agent-kit. Migration: `0034`. Conformance: `40`. Closes the production
half of issue 21.

## The gap

`log_agent_query()` (live in `0002`) writes one `agent_query` event carrying
`properties = {query, agent_id}`, the result summary, and the nodes it touched
as participants. An agent's retrieval is a loop — reformulate, narrow by type,
judge candidates — so one question produces N of those events and nothing joins
them. The final answer is the same shape whether the agent never generated a
matching phrasing, generated one the trigram threshold rejected, reached the
node and misjudged it, or the knowledge is absent. Only the grouped steps
separate those four, and they have four different fixes.

## A. Two halves, one step shape, no shared dependency

Eval-time capture (`eval/retrieval/`) and production tracing stay separate:
the harness writes nothing to the database and does not read `agent_query`
events, so a read-only agent can be scored. What they share is the **shape of a
step**, and deliberately so. `eval/retrieval/trace_format.md` already fixes it:
`seq`, `tool`, `intent`, `args`, `results`. Production tracing reuses those
names so one scorer, one mental model, and one skill paragraph cover both. A
trace assembled from `agent_query` events can be rewritten into a harness trace
by renaming nothing.

## B. The trace rides in the event's properties, under one key

No new table, as issue 21 requires, and no new event type: an `agent_query`
event is still an `agent_query` event. The convention is one reserved key:

```
properties.trace = {
  "trace_id": "<non-empty text, the caller's id for one loop>",
  "seq":      <integer >= 1, unique within the trace>,
  "tool":     "find_nodes" | "find_nodes_batch" | "find_paths" |
              "neighborhood" | "sql" | <arm-specific>,        -- optional
  "intent":   "<why this phrasing was tried>",                -- optional
  "args":     { ... as passed ... },                          -- optional
  "results":  [ {node_id, score, match_reason, used} ... ],   -- optional
  "selected": {node_id, from_seq, from_phrasing}              -- optional
}
```

`properties.query` keeps the phrasing, exactly as today, so `selected` needs to
carry only `from_seq` to name which phrasing produced the candidate that was
used; `from_phrasing` is a convenience copy for a reader that has one event and
not the loop. Everything except `trace_id` and `seq` is optional, and a caller
that knows nothing but the grouping writes those two.

`node_salience` reads `properties->>'agent_id'` and the participants only, so
it is untouched and improves as a side effect: more traced reads mean more
cooperative attention signal, which is all that view has ever had.

## C. An optional parameter, not a repurposed column

The live signature is `log_agent_query(p_agent_id text, p_query_text text,
p_result_summary text, p_nodes_referenced uuid[])`, and it builds `properties`
itself. There is no jsonb argument to hide a trace in, and encoding one in
`p_query_text` or `p_result_summary` would make the phrasing unreadable and the
trace unparseable. So `0034` gives the function a fifth parameter,
`p_trace jsonb DEFAULT NULL`, by `DROP FUNCTION` and `CREATE` — the same shape
`0018` used for `record_assertion()` and `0019` for `accept_assertion()` and
`reject_candidate()`. A four-argument overload is *not* created beside it: both
would match a four-argument call and PostgreSQL would raise `function ... is not
unique` at call time, which is a breakage rather than a compatibility measure.

Every existing call site — `skills/rye-agent-ops`, `tests/scenarios/05`,
`tests/conformance/26` — passes four arguments and is unchanged, and its event
carries no `trace` key at all. Widening a function so that every existing call
still resolves identically is not the "removing an object or narrowing a
signature" that `contracts/sql-surface.md` calls breaking; it is additive, and
it bumps nothing.

The function validates only what grouping needs: a non-null `p_trace` must be a
jsonb object with a non-empty `trace_id` and an integer `seq` of at least 1, or
it raises. A trace that cannot be grouped or ordered is worse than no trace,
because it looks like data.

## D. Reading it back: one view, ordered by `seq`

`agent_query_trace`, `WITH (security_invoker = true)`: one row per `agent_query`
event that carries a trace — `trace_id`, `seq`, `event_id`, `occurred_at`,
`agent_id`, `query`, `summary`, `tool`, `intent`, `args`, `results`, `selected`,
and `node_ids` (the participants, ordered). Order is `trace_id`, `seq`,
`occurred_at`, `event_id`. RLS applies as everywhere: an event whose
participants this caller cannot see is absent, and a short trace never means a
short loop.

## E. Issue 21's four questions

**Capture layer.** The agent layer, for both halves. `intent` is the field that
classifies a miss and it exists nowhere in the executed SQL; a statement log or
a wrapper records faithfully what ran and cannot record why it ran. The SQL
layer's advantage — that it cannot be forgotten — is worth nothing here, because
the whole surface is opt-in by construction: a read must not write. So the
caller emits its own step, for the harness as a JSON file and in production as a
`log_agent_query()` call, and `args` carries what was actually passed so the
faithful half is not lost.

**Ordering.** `trace_id` alone is not enough, and the reason is mechanical
rather than theoretical: `record_event()` defaults `p_occurred_at` to `now()`,
which is transaction start, so every call in one transaction — the normal shape
of a reformulation loop — lands on the identical timestamp. `seq` is therefore
required, not optional, and it is the first sort key. `occurred_at` and
`event_id` break ties only so the order is total.

**Rejected candidates.** Recorded, optionally and bounded. `results` carries the
candidates the step returned with their `score` and `match_reason` and a `used`
flag, because rejection is where misjudgment is visible: a trace showing the
right node returned at rank 3 and passed over is a prompting fix, and a trace
showing it never returned is a threshold or vocabulary fix. They are optional
and a caller is expected to cap them — ten per step is plenty — because an
unbounded candidate list in an immutable event is a storage decision nobody
asked for.

**Retention.** There is none, and that is stated rather than hidden. Events are
immutable and Rye deletes none, so a trace written is a trace kept, and no
pruning path exists today; adding one is a new migration and an edit to
`contracts/sql-surface.md` first, exactly as `agent_action_log` is treated. The
lever available now is the one the convention already has: tracing is per call,
so a deployment traces the loops it will analyse — failures, a sampled
percentage, an eval week — and not every read. `docs/roadmap.md` keeps the
retention class; this item measures nothing about it and claims nothing.

## F. What the write gate means for a read-only agent

Nothing changes and that is the point. `log_agent_query()` reaches
`record_event()`, and `trg_events_gate_may_write` refuses a `viewer`, an unset
role, and any role whose `role_classification_access.may_write` is false with
`42501`, traced or not. A read-only agent therefore **cannot** trace, and
`skills/rye-knowledge-reader` continues to forbid the call outright rather than
letting an agent discover the refusal at run time. That is why the eval harness
must not depend on production tracing: the agents most worth measuring are the
ones that may not log. An agent-shaped session (`agent:<key>`) may write and may
trace.

Nothing auto-logs. `find_nodes`, `find_nodes_batch`, `find_paths`,
`neighborhood` (migration `0032`, work/013), `agent_node_summary()`, and
`node_context` write no event, and obligation 40.5 pins it.

## G. Migration 0034 is needed, and what it replaces

The convention itself is properties-only — no column, no table, no new event
type — but the function that writes those properties has to accept them, so
`0034` exists and replaces exactly two objects: `log_agent_query(text, text,
text, uuid[])` (dropped and recreated with the fifth parameter) and nothing
else, plus one new view, `agent_query_trace`. It touches no object `0031`
(`node_source_map`, `merge_nodes`, `link_record`), `0032` (`find_nodes`,
`find_nodes_batch`, `find_paths`, `neighborhood`, `edge_semantics`), `0033`
(`resolve_node_identity`), `0035`, or `0036` touches.

## Test obligations, conformance 40

Each runs under a non-superuser role (`SET ROLE`, as `conformance.sh` does) and
under `scripts/test-nonsuperuser-owner.sh`. The suite fails, not skips, without
`0034`, and fails without `0032`: obligation 40.5 has nothing to prove if the
traversal functions are absent, so it asserts `to_regprocedure` first.

1. **40.1 Four arguments still work.** The pre-existing call shape returns an
   event id, the event's `properties` carries `query` and `agent_id`, and
   `properties ? 'trace'` is false. Anti-vacuity: assert the event row exists
   and its `event_type` is `agent_query`.
2. **40.2 A trace lands whole.** A five-argument call writes
   `properties->'trace'` equal to what was passed, with `trace_id` and `seq`
   readable as text and integer.
3. **40.3 An ungroupable trace is refused.** `p_trace` without `trace_id`, with
   a blank `trace_id`, without `seq`, with `seq` of 0, and as a jsonb array each
   raise. Anti-vacuity: after each refusal, no new `agent_query` event exists.
4. **40.4 Ordering survives a timestamp tie.** Three traced calls in one
   transaction share `occurred_at`; `agent_query_trace` returns them in `seq`
   order. Anti-vacuity: assert the three `occurred_at` values are equal, or the
   test proves nothing.
5. **40.5 No read surface writes.** Count `events` before and after calling
   `find_nodes`, `find_nodes_batch`, `find_paths`, `neighborhood`,
   `agent_node_summary`, and `node_context`; the count is unchanged.
   Anti-vacuity: each call returns at least one row, so a call that found
   nothing cannot pass as a call that logged nothing.
6. **40.6 The write gate covers tracing.** Under `viewer` and under an unset
   role, a traced and an untraced `log_agent_query()` both raise `42501` and no
   event appears. Under `agent:<key>` both succeed.
7. **40.7 The view is invisible-safe.** A traced event whose only participant is
   a node the caller cannot see is absent from `agent_query_trace` for that
   caller and present for `admin`. Anti-vacuity: assert the admin row exists.
8. **40.8 Salience is undisturbed.** `node_salience` counts a traced event
   exactly as it counts an untraced one.

## Cost, and what was rejected

A traced call costs one jsonb object on an event that was already being
written. A deployment that traces everything grows `events` with no pruning
path, which is why the convention is per call and why retention is named above
rather than promised.

Rejected: a new `agent_query_steps` table (issue 21 rules it out, and the
grouping fits in the row that already exists); a trigger or wrapper that logs
inside the traversal functions (settled in issue 19 — a read must not write);
`trace_id` with no `seq` (identical timestamps inside one transaction make it
unorderable); a `SECURITY DEFINER` `log_agent_query()` so a read-only role could
trace (it would give a `viewer` a write, and on a non-superuser owner it would
not even work).
