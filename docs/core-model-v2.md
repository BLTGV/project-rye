# Rye Core Model v2 — Implementation Specification

Status: **approved for implementation** (pre-release; breaking changes to
migrations are in scope and expected). This spec supersedes the phased plan
in `docs/knowledge-lifecycle.md`, which should be deleted by the PR that
implements this document. The rationale and worked examples live in the
design artifact and the GitHub issue; this document is the contract the
implementation and conformance suites are written against.

## 1. Summary

v2 makes the knowledge lifecycle part of the assertion itself instead of
three parallel mechanisms (candidate nodes for facts, `contested:` key
disputes, half-built `attrs.record_mode`). Three changes carry everything:

1. **Lifecycle on the row**: `status` (`candidate` | `accepted`) and
   `basis` (`observed` | `reported` | `inferred` | `assumed` | `unknown`)
   become columns on `assertions`. The unique-active constraint applies to
   accepted rows only.
2. **One evidence primitive**: `assertion_evidence` replaces
   `source_event_id` and carries typed provenance rows
   (`source` | `corroboration` | `derivation`) referencing events or
   assertions, each with an optional canonical witness node.
3. **Gated transitions**: all cross-tuple lifecycle effects go through
   helpers (`accept_assertion`, `record_distillation`,
   `resolve_knowledge_gap`, `schedule_assertion_change`). Public
   supersession is same-tuple only.

Append-only, RLS, the six core tables, events, artifacts, structural
candidate nodes, onboarding scopes, and plugins are unchanged.

## 2. Schema changes

### 2.1 `assertions` — new columns

```sql
ALTER TABLE assertions
  ADD COLUMN status text NOT NULL DEFAULT 'accepted'
      CHECK (status IN ('candidate','accepted')),
  ADD COLUMN basis text NOT NULL DEFAULT 'unknown'
      CHECK (basis IN ('observed','reported','inferred','assumed','unknown')),
  ADD COLUMN classification text;
```

(Applied by rewriting the core migration in place — pre-release, no
ALTER-migration needed; shown as ALTER for clarity only.)

- `status = 'candidate'` rows are invisible to every operational read
  surface (`current_valid_assertions`, `agent_node_summary`, plugin views,
  materialized views). They are visible only to review surfaces.
- `basis` is immutable after insert (extend the immutability guard).
  `status` may transition candidate→accepted only, via `accept_assertion()`.
- `classification` participates in RLS exactly as node classification does;
  required (trigger-enforced) when the assertion's claim is derived from
  classified sources (§2.4).
- `confidence` semantics change to **stored prior** (optional). Effective
  belief is computed (§5). No schema change to the column.
- Drop `source_event_id` from `assertions`. All provenance moves to
  `assertion_evidence`. Update every helper and view that references it.

### 2.2 Unique-active index

```sql
DROP INDEX idx_assertions_active_unique;
CREATE UNIQUE INDEX idx_assertions_active_unique
    ON assertions (subject_ref, assertion_type, assertion_key)
    WHERE superseded_at IS NULL AND status = 'accepted';
```

Multiple candidates on one tuple are legal and expected — that state IS a
dispute. Preserve any existing effective-window uniqueness semantics from
migration 0014 for accepted rows.

### 2.3 `assertion_evidence`

```sql
CREATE TABLE assertion_evidence (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    assertion_id        uuid NOT NULL REFERENCES assertions(id),
    kind                text NOT NULL CHECK (kind IN ('source','corroboration','derivation')),
    event_id            uuid REFERENCES events(id),
    source_assertion_id uuid REFERENCES assertions(id),
    witness_node_id     uuid REFERENCES nodes(id),
    recorded_at         timestamptz NOT NULL DEFAULT now(),
    attrs               jsonb NOT NULL DEFAULT '{}',
    CHECK ( (kind =  'derivation') = (source_assertion_id IS NOT NULL)
        AND (kind <> 'derivation') = (event_id IS NOT NULL) )
);
CREATE INDEX ON assertion_evidence (assertion_id);
CREATE INDEX ON assertion_evidence (source_assertion_id) WHERE source_assertion_id IS NOT NULL;
CREATE INDEX ON assertion_evidence (event_id) WHERE event_id IS NOT NULL;
```

- **RLS**: ENABLE + FORCE. A row is visible only if the caller can see the
  assertion AND the referenced event/assertion. INSERT allowed per write
  policy; UPDATE and DELETE denied to all non-owner roles (append-only).
- Every assertion insert through helpers MUST carry at least one evidence
  row in the same transaction (`source` for intake, `derivation` for
  distillation/inference). Direct inserts without evidence are allowed only
  for `basis = 'assumed'` rows.
- Corroboration independence: helpers count independent support per
  distinct `witness_node_id`, not per event. A corroboration row whose
  witness matches an existing source/corroboration witness for the same
  assertion is recorded but flagged `attrs.independent = false`.

### 2.4 Classification propagation

For any assertion inserted with `derivation` evidence:
`classification := max(classification of all source assertions)` using the
ordering defined in `field_classifications` semantics. If sources span
access populations such that no single population can see all of them
("mixed-access"), the insert is **refused** with a clear error. Same rule
applies to narrative artifacts linked from digests.

## 3. Function contract

### 3.1 New / rewritten helpers

```
record_assertion(...)      -- gains p_status, p_basis, p_evidence[]; drops p_source_event_id.
                           -- status defaults 'accepted', basis defaults per caller.
                           -- attrs.record_mode is removed everywhere.

accept_assertion(p_assertion_id, p_evidence DEFAULT NULL, p_reason DEFAULT NULL,
                 p_actor DEFAULT NULL) RETURNS uuid
  -- Candidate → accepted, atomically: supersede current accepted holder of the
  -- tuple (if any), flip status, append optional corroboration evidence,
  -- record 'assertion_accepted' event. Enforces: inferred rows may displace
  -- only inferred rows. Enforces classification propagation. SECURITY DEFINER
  -- with the same session-context checks as existing write helpers.

reject_candidate(p_assertion_id, p_reason, p_actor) RETURNS void
  -- Candidate → superseded (by nothing); records 'candidate_rejected' event.

supersede_assertion(...)   -- RESTRICTED: new row must share (subject_ref,
                           -- assertion_type, assertion_key) with the old row.
                           -- Cross-tuple supersession raises.

record_distillation(p_subject_node_id, p_subject_edge_id, p_assertion_key,
                    p_claim, p_source_assertion_ids uuid[], p_source_event_ids uuid[],
                    p_status DEFAULT 'accepted', p_agent, ...) RETURNS uuid
  -- Writes digest assertion (assertion_type 'digest', basis 'inferred'),
  -- derivation + source evidence rows, supersedes prior digest on the tuple
  -- (supersede-then-insert order inside one transaction), records
  -- 'distillation' event. Edge subjects: participants are the edge's endpoint
  -- nodes; edge id goes in event attrs. Watermark stored as validated
  -- attrs.watermark (timestamptz, computed max(asserted_at) over sources;
  -- required non-null: refuse empty source list).

resolve_knowledge_gap(p_gap_assertion_id, p_answer_assertion_id, p_actor) RETURNS void
  -- Supersedes the gap with a resolved gap version (same tuple) whose claim
  -- links the answering assertion. Never cross-type supersession.

schedule_assertion_change(p_subject..., p_assertion_type, p_assertion_key,
                          p_claim, p_effective_at, ...) RETURNS uuid
  -- Generic replacement for schedule_deal_stage_change /
  -- schedule_task_status_change / schedule_milestone_status_change.
  -- Those three become thin wrappers or are deleted with call sites updated.
```

### 3.2 Deleted

- `contest_assertion`, `resolve_dispute`, the `contested:` key namespace and
  all key-rewriting behavior. Replacement: write competing row as candidate;
  `accept_assertion` on the winner; `reject_candidate` on losers.
- `promote_candidate_to_assertion` (fact path). Structural candidate flows
  (`create_knowledge_candidate`, `promote_candidate_to_task`,
  `promote_candidate_to_edge`) remain, updated to write v2 assertions.
- `attrs.record_mode` handling in all functions and views.

### 3.3 Repaired

- `assertions_as_of(p_effective timestamptz, p_known_as_of timestamptz DEFAULT NULL)`
  — bitemporal: returns rows that were effective at `p_effective` AND known
  (asserted, not yet superseded) as of `p_known_as_of` (default: effective
  time). Superseded rows MUST remain answerable for times when they were
  believed. Only `status = 'accepted'` rows.
- `current_valid_assertions` = accepted + `superseded_at IS NULL` + inside
  effective window. This is the ONLY base for operational reads; audit every
  view/function using bare `superseded_at IS NULL` and rebase.
- `agent_node_summary()` — reads `current_valid_assertions` only; presents
  active digests first (labelled derived with `as_of`), then uncovered raw
  items, each labelled with basis; excludes candidates; respects
  `p_max_items` budget.

### 3.4 New views

```
review_queue          -- all candidates, grouped by tuple; competing groups together.
                      -- Replaces active_disputes (delete it) and candidate lists.
stale_digests         -- security_invoker; digest is stale when (a) newer accepted
                      -- assertion on subject since watermark, OR (b) any derivation
                      -- source superseded or displaced. Partial index to support:
                      -- (subject_ref, asserted_at) WHERE superseded_at IS NULL AND status='accepted'.
open_gaps             -- accepted knowledge_gap assertions, unresolved.
assertion_support     -- evidence rows joined both directions (per-assertion evidence bundle).
competing_candidates  -- tuples with >1 live candidate (the dispute surface).
```

All views `WITH (security_invoker = true)`.

## 4. Registry entries (conventions)

- `half_life:<assertion_type>` — interval, NULL = no decay. Precedence:
  scope override → plugin default → core default. Resolution helper
  `registry_value(p_key, p_scope)` implements precedence deterministically.
- `basis_prior:<basis>` — numeric prior per basis
  (defaults: observed .95, reported .70, inferred .60, assumed .30,
  unknown .50).
- Digest facet catalog per node type — plugin-contributable
  (`digest_facets:<node_type>`); `record_distillation` refuses keys outside
  the catalog when a catalog exists for the subject's type.

## 5. `effective_confidence()`

```
effective_confidence(a) =
  clamp01(
    coalesce(a.confidence, basis_prior(a.basis))
    * corroboration_lift(n_independent_witnesses)   -- 1 + 0.1·min(n,3), capped 1.3
    * CASE WHEN half_life IS NULL THEN 1
           ELSE 2 ^ (- greatest(age,0) / half_life) END
    * dispute_discount(n_live_competing_candidates) -- 0.8 ^ n, floor 0.5
  )
-- age runs from max(asserted_at, newest independent corroboration recorded_at).
-- Defined only over rows visible in current_valid_assertions.
```

Exposed via `current_assertions_weighted` view. No stored value mutates.

## 6. Conformance requirements (gate for merge)

Every item below gets a conformance test; run under the non-superuser role
per existing harness policy.

1. Candidate rows never appear in `current_valid_assertions`,
   `agent_node_summary`, plugin views, or materialized views.
2. Two candidates on one tuple insert cleanly; `accept_assertion` on one
   supersedes the accepted incumbent and leaves the other candidate intact;
   the loser can be rejected with reason.
3. `accept_assertion` refuses to let an `inferred` row displace a
   non-inferred accepted row.
4. Public `supersede_assertion` refuses cross-tuple supersession.
5. `record_distillation`: supersede-then-insert order (no unique-index
   collision under concurrency — test with two concurrent calls);
   refuses empty sources; refuses mixed-access sources; propagates max
   classification; writes derivation evidence; records event.
6. `stale_digests` flags on newer subject facts AND on overturned sources.
7. `assertions_as_of` returns superseded history for past times (regression
   test on the v1 bug), excludes candidates, handles knowledge-time.
8. `assertion_evidence`: RLS both ends; UPDATE/DELETE denied; CHECK
   constraint enforces exactly-one-reference shape.
9. `resolve_knowledge_gap` closes the gap on its own tuple, links the
   answer, never cross-type supersedes.
10. Basis immutable; status transitions only candidate→accepted via helper.
11. `effective_confidence` per §5 including null-confidence, no-half-life,
    negative-age clamp, independence flagging.
12. Legacy compatibility intentionally broken items are enumerated in the PR
    description (deleted functions, removed column) with grep-verified zero
    remaining call sites in schema/, scripts/, admin/, eval/.

## 7. Out of scope for PR1

- Admin UI rework (separate PR: review_queue surface replacing
  CandidateReviewPage + DisputesPage; evidence/basis display).
- Salience (`node_salience`), gardening, source reputation, calibration,
  induction — deferred (issue tracks).
- Prediction convention (separate from future-effective truth).
- Durable subject→scope governance relation (open design; helpers accept
  explicit `p_scope_node_id` and validate against it when provided).
