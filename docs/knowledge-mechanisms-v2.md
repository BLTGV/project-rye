# Rye Knowledge Mechanisms (v2 follow-on) — Implementation Specification

Status: **approved for implementation**. Implements the mechanisms deferred
by `docs/core-model-v2.md` §7: scope governance, salience, gardening,
source reputation, predictions & calibration, and induction. Everything
here builds on the merged v2 core (status/basis/evidence, gated helpers)
and changes no existing core semantics except where explicitly stated.
Design caveats raised in the independent v2 audit are incorporated and
marked (audit).

## 1. Scope governance

The largest open item from v2: with multiple active scopes, which scope's
review policy gates a write? v2 helpers accept `p_scope_node_id` and
validate only when given. This makes governance durable and deterministic.

### 1.1 Coverage relation

Scopes declare what they govern with edges (no new table):

- `scope_governs_subject` — scope → node: this scope governs knowledge
  about that subject (and, for process/project-like subjects, its
  `has_step` children).
- `scope_governs_source` — scope → source node (person, connector,
  system): this scope governs knowledge originating from that source.
  (The source/channel distinction already exists in intake conventions.)
- `scope_governs_type` — scope → registry: governed `assertion_type`
  values, stored as registry entries `governed_type:<assertion_type>`
  on the scope, since types are not nodes.

### 1.2 Resolution

```
governing_scope(p_subject_node_id uuid, p_subject_edge_id uuid,
                p_assertion_type text, p_witness_node_id uuid)
RETURNS uuid  -- scope node id or NULL
```

Deterministic precedence, first match wins:

1. Explicit subject coverage (`scope_governs_subject`, nearest: direct
   before inherited-via-`has_step`).
2. Type coverage (`governed_type:` registry entry on exactly one active
   scope; if two active scopes claim the same type, resolution RAISES —
   ambiguity is an admin error surfaced at write time, not silently
   picked).
3. Source coverage via the witness (`scope_governs_source`).
4. `DEFAULT_SCOPE` registry entry if set; else NULL (ungoverned).

Edge subjects resolve via their endpoint nodes (source endpoint first).

### 1.3 Enforcement

- `record_assertion` / `accept_assertion` / `record_distillation` call
  `governing_scope(...)` when `p_scope_node_id` is NULL. If a governing
  scope is found, its compiled policy applies; explicit `p_scope_node_id`
  must match the resolved scope when both exist (mismatch RAISES).
- Scope policy gains one field consumed here: `review_policy` with values
  `open` (accepted writes allowed), `candidates_only` (all non-`observed`
  writes forced to candidate status), `strict` (ALL writes forced to
  candidate, including observed). Stored in the existing compiled scope
  policy; default `open` preserves current behavior for all existing
  installs and tests.
- `accept_assertion` under `candidates_only`/`strict` requires a
  non-agent role (`app.current_role` NOT LIKE 'agent:%') — human
  acceptance — unless the scope grants the agent
  `rye.authoritative.promote` capability (existing capability machinery).

## 2. Salience

Attention signal from the query log that already exists.

```sql
CREATE VIEW node_salience WITH (security_invoker = true) AS
SELECT n.id AS node_id,
       count(*)                                   AS query_count,
       count(DISTINCT e.properties->>'agent_id')  AS distinct_agents,
       max(e.occurred_at)                         AS last_queried_at,
       sum(exp(-extract(epoch from (now() - e.occurred_at)) / 2592000.0))
                                                  AS salience_score  -- 30-day e-folding recency weight
FROM events e
JOIN event_participants ep ON ep.event_id = e.id
JOIN nodes n ON n.id = ep.node_id
WHERE e.event_type = 'agent_query'
GROUP BY n.id;
```

- (audit) Coverage is cooperative — only queries routed through
  `log_agent_query` count. Therefore salience is advisory: it may ORDER
  retention/distillation work, it must never GATE visibility or deletion.
  Document this in the view comment and agent-ops guide.
- `stale_digests` gains a `salience_score` column (LEFT JOIN; NULL = never
  queried) so the distiller can work hot-first.
- No new writes. No schema change.

## 3. Gardening

Keeps schema-flexibility from rotting into vocabulary chaos.

### 3.1 Vocabulary report

```sql
CREATE VIEW type_vocabulary_report WITH (security_invoker = true) AS
-- one row per (kind, type_value): kind in ('node_type','edge_type','assertion_type')
-- columns: kind, type_value, usage_count, first_seen, last_seen,
--          canonical_value (from alias registry, NULL if canonical itself)
```

Near-duplicate detection (levenshtein/similarity) stays in the gardener
skill, not SQL — no extension dependency.

### 3.2 Alias registry

Registry entries `type_alias:<kind>:<deprecated_value>` → canonical value.
Read-side translation only:

- `canonical_type(p_kind, p_value)` resolution function (registry
  precedence rules from v2 apply).
- Helpers normalize NEW writes through `canonical_type()`; existing rows
  are never rewritten (append-only; history keeps its spelling).
- Views that group by type (`type_vocabulary_report`, `review_queue`
  question-type filter) group by canonical value.

### 3.3 Gardener skill

`skills/rye-gardener/` (sibling of rye-onboarding): reads
`type_vocabulary_report`, proposes alias registry entries and
`merge_nodes()` calls as **structural candidates** for human review —
(audit) `merge_nodes` is irreversible and stays review-gated; the skill
never merges directly. Skill ships with SKILL.md + prompts only; no
runtime.

## 4. Source reputation

(audit) Ordinary supersession is NOT evidence a source was wrong — status
changing naturally supersedes its predecessor. Reputation derives only
from **labeled** outcomes:

- `accept_assertion` over a competing candidate records, on the loser(s),
  `attrs.outcome = 'displaced'` plus `displaced_by`.
- `reject_candidate` already records a reason; it gains an optional
  `p_outcome` label: `incorrect` | `unsupported` | `duplicate` | `stale`.
  Only `incorrect` and `unsupported` count against a witness.
- Explicit corrections: when an acceptance reason marks the incumbent
  wrong (new helper arg `p_supersedes_as := 'correction' | 'update'`,
  default `'update'`), the superseded row gets
  `attrs.outcome = 'corrected'`. Updates are neutral; corrections count.

```sql
CREATE VIEW source_reliability WITH (security_invoker = true) AS
-- per witness_node_id over assertion_evidence kind IN ('source','corroboration'):
--   claims_witnessed, corrections, rejected_incorrect, displaced,
--   correction_rate = (corrections + rejected_incorrect) / NULLIF(claims_witnessed,0),
--   last_outcome_at
-- Rows with claims_witnessed < 5 are marked low_sample = true.
```

- Always derived fresh — no stored scores (explainability requirement).
- `effective_confidence()` v2 formula gains an optional witness prior:
  `prior := basis_prior * (1 - least(correction_rate, 0.5))` for the
  primary source witness, applied only when `low_sample = false`. Capped
  discount; reputation can halve a prior, never zero it.

## 5. Predictions and calibration

(audit) Future-effective assertions are accepted future truth, NOT
forecasts — scoring them would punish changed plans. Predictions get
their own convention:

- `assertion_type = 'prediction'`, key = free-form outcome label.
  Claim shape (validated by `record_prediction()` helper):

```json
{"question": "pilot converts to annual contract",
 "outcome_key": "deal_stage:default",           -- tuple whose future value settles it
 "predicted_value": {"stage": "closed_won"},
 "probability": 0.7,
 "horizon": "2026-11-15T00:00:00Z"}
```

- `record_prediction(...)` writes it `basis = 'inferred'`,
  `status = 'accepted'` (a prediction being on record is not a fact claim
  about the world — the claim is explicitly probabilistic), witness = the
  predicting agent/person. Predictions never hold the slot of the tuple
  they predict (different assertion_type by construction).
- `score_due_predictions()` (callable helper; no scheduler dependency):
  for each unscored prediction past its horizon, read the outcome tuple's
  value effective at the horizon via `assertions_as_of`, compare to
  `predicted_value` (containment match), record a `prediction_scored`
  event and `attrs.outcome = 'correct' | 'incorrect' | 'unresolvable'`
  (outcome tuple missing → unresolvable, excluded from calibration).
- `calibration_report` view: per witness, count, brier_score
  (mean (probability − outcome)²), hit_rate, by probability bucket.
- Calibration feeds `source_reliability` witness stats (predictions are
  claims; scored-incorrect counts like `rejected_incorrect` but tracked
  separately: `predictions_scored`, `prediction_brier`).

## 6. Induction

Strictest gates — compresses instances into proposed patterns.

- `node_type = 'pattern'` for the pattern subject; the pattern STATEMENT
  is an assertion on it: `assertion_type = 'pattern_claim'`,
  `basis = 'inferred'`, `status = 'candidate'` — **helpers refuse to
  write `pattern_claim` as accepted directly**; only `accept_assertion`
  (human or capability-granted) can promote it.
- (audit) Evidence via the derivation model, NOT graph edges: supporting
  instances are `assertion_evidence` rows (`kind = 'derivation'` to the
  instance assertions; `kind = 'source'` to instance events). Minimum 3
  distinct-subject derivation rows enforced by `record_pattern()` helper.
- Counter-evidence: `contradicts = true` flag in evidence `attrs`;
  `pattern_support` view shows support/contradiction counts per pattern.
- Accepted patterns may be cited as derivation evidence by later
  inferences, but `effective_confidence` of anything deriving from a
  pattern is capped by the pattern's own effective confidence
  (implemented in the weighted view for one derivation hop; deeper
  chains are future work, documented).

## 7. Conformance requirements (merge gate)

1. `governing_scope()` precedence order incl. RAISE on ambiguous type
   claims; explicit-vs-resolved mismatch RAISES.
2. `candidates_only` policy forces non-observed writes to candidate;
   `strict` forces all; `open` (and absent policy) changes nothing —
   regression-guard the entire existing suite under absent policy.
3. Agent `accept_assertion` under `candidates_only` requires capability;
   human role succeeds.
4. `node_salience` counts only `agent_query` events; salience never
   appears in any WHERE clause of operational views (grep-style test on
   view definitions).
5. `canonical_type()` normalizes new writes; existing rows untouched;
   alias chains (a→b→b2) resolve fully or RAISE on cycles.
6. Reputation: plain supersession does NOT move `correction_rate`;
   labeled correction/rejection does; low_sample gate at n<5; confidence
   discount capped at 0.5 and skipped when low_sample.
7. Predictions: never occupy the predicted tuple; scoring reads the
   outcome as-of horizon (works with backdated corrections);
   unresolvable excluded; brier math checked against a hand-computed
   fixture.
8. Induction: direct accepted `pattern_claim` write refused; <3 distinct
   subjects refused; contradiction rows counted; derivation-hop
   confidence cap applied.
9. All new views `security_invoker = true`; no new table lacks RLS
   (only new relation surface is views + registry entries; if any table
   is added, both-ends RLS like `assertion_evidence`).
10. Zero behavior change for a database that configures none of this:
    full pre-existing conformance + scenario suites pass untouched.

## 8. Out of scope

- Multi-hop confidence propagation through pattern chains.
- Automated gardener/distiller scheduling (helpers are callable; cron is
  operator choice).
- Admin UI for calibration/reputation/salience (follow-up; JSON views are
  API-ready).
- Any change to production instances.
