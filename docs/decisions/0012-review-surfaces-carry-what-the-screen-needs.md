# 0012 Review surfaces carry what the screen needs

Date: 2026-09-20. Work item: `work/016-admin-view-layer.md`.
Contracts: `contracts/sql-surface.md`, section "Review surfaces";
`contracts/admin-api.md`. Areas: schema, admin. Migrations: `0035` (core),
`0125` (crm profile). Conformance: `41`. Closes issue 12.

## The gap

Issue 12 lists five things the reviewer's screen needed and the views did not
have, each of which the admin compensated for in `admin/src/server/queries.ts`
with a correlated subquery, or could not compensate for at all. The compensation
is not the problem — duplication of Rye's own rules in a client is. A second
client would write them again, differently.

## A. A candidate has a projected effective confidence

`base_effective_confidence(a assertions)` (live in `0019`) opens with
`IF NOT EXISTS (SELECT 1 FROM current_valid_assertions c WHERE c.id = a.id)
THEN RETURN NULL`, so `effective_confidence()` is null for every candidate and
the screen falls back to a basis-prior chip. Everything after that gate — basis
prior, source reliability, independent-witness lift, half-life decay, competitor
discount, pattern cap — is computable for a candidate and is exactly what a
reviewer wants to see before accepting one.

`0035` factors rather than forks, so the arithmetic exists once:

| object | what it is |
|---|---|
| `base_effective_confidence_unchecked(a assertions)` | new. `0019`'s body with the membership gate removed and one change: the competitor count excludes the row itself (`candidate.id <> a.id`). |
| `base_effective_confidence(a assertions)` | replaced by a wrapper: the unchecked value when the row is in `current_valid_assertions`, else null. Same answers as today — a row in that view is accepted and unsuperseded, so it was never its own competitor. |
| `projected_effective_confidence(a assertions)` | new. Null unless the row is **live** (`superseded_at` is null and `status` is `candidate` or `accepted`); otherwise the unchecked value with the same `pattern_claim` cap `effective_confidence()` applies. |
| `candidate_assertions_weighted` | new view, `security_invoker`: live candidates with `projected_effective_confidence` beside them, mirroring `current_assertions_weighted`. |

Excluding the row from its own competitor discount is the one judgement here.
The projection answers "what would this carry if accepted", and at that moment
it is not a competing candidate. Without the exclusion a lone candidate projects
0.8 of what the same claim will read a second later, which would teach reviewers
to distrust the number.

`effective_confidence()` itself is **not** replaced. For a row in
`current_valid_assertions` the two functions return the same value, and
obligation 41.2 pins it.

## B. `review_queue` says who, against what, and why it is waiting

Existing columns keep their names, types, order, and meaning — including
`candidates`, whose jsonb objects are built exactly as today. `CREATE OR REPLACE
VIEW` appends columns at the end and is sufficient, with one trap: a dependent
view keeps its own expanded column list, so `competing_candidates`
(`SELECT * FROM review_queue WHERE candidate_count > 1`) does **not** inherit
the new columns and is replaced in the same migration with the same appended
order.

Appended to `review_queue`, tuple-level:

| column | meaning |
|---|---|
| `subject_label text` | `nodes.label` of `subject_node_id`, null for an edge subject. `LEFT JOIN`. |
| `subject_node_type text` | likewise. |
| `newest_candidate_at timestamptz` | `max(asserted_at)` over the live candidates. |
| `incumbent_assertion_id uuid` | the accepted, unsuperseded assertion on the same `subject_ref`, canonical `assertion_type`, and `assertion_key` — the row an acceptance would supersede. |
| `incumbent_claim jsonb`, `incumbent_basis text`, `incumbent_confidence numeric`, `incumbent_effective_confidence numeric`, `incumbent_asserted_at timestamptz`, `incumbent_attrs jsonb` | that row's content. |
| `incumbent_is_current boolean` | whether that row is also in `current_valid_assertions`. |
| `waiting_reason text` | `settle_gate`, `review_gate`, or `none`. |
| `waiting_detail jsonb` | the `attrs.settle_gate` or `attrs.review_gate` object it came from, else null. |

Two definitions are load-bearing. **The incumbent is the accepted unsuperseded
row, not the currently effective one**, because that is the row
`accept_assertion()` ends; the admin's subquery reads `current_valid_assertions`
and so shows no incumbent for a future-dated or expired accepted row that an
acceptance would nonetheless displace. `incumbent_is_current` keeps the old
distinction visible. And **`settle_gate` beats `review_gate`** when candidates
under one tuple carry different markers, because the settle gate's demotion is
the one that needs an admin; `none` is written rather than null so a client can
branch without a null test.

Per-candidate detail goes in a new view rather than inside the existing jsonb,
because the admin already unnests `candidates` and joins `assertions`, and a
column of arrays is a worse join key than a row:

**`review_queue_candidates`**, `security_invoker`, one row per live candidate:
`assertion_id`, `subject_ref`, `subject_node_id`, `subject_edge_id`,
`subject_label`, `assertion_type` (canonical), `stored_assertion_type`,
`assertion_key`, `claim`, `basis`, `confidence`, `classification`,
`projected_effective_confidence`, `basis_prior`, `asserted_at`, `effective_at`,
`effective_to`, `attrs`, `waiting_reason`, `waiting_detail`,
`incumbent_assertion_id`, `evidence_count`, `witness_count`,
`evidence_kinds text[]`, `latest_evidence_at`.

`evidence_*` is a summary, not the evidence. The screen's drawer wants event
summaries and witness labels, which is a join per row; the queue wants to know
whether a candidate is supported at all, which is four scalars. The admin keeps
its detailed evidence join for the expanded panel and drops the counting one.

## C. `stale_digests` names the culprit

Appended, with the existing booleans unchanged:
`newer_assertion_ids uuid[]`, `newer_latest_asserted_at timestamptz`,
`overturned_source_assertion_ids uuid[]`. Both arrays are non-null and empty
rather than null when the matching boolean is false, so
`newer_subject_assertion = (cardinality(newer_assertion_ids) > 0)` holds row by
row, which is obligation 41.5. A stale badge now links to the assertion that
made it stale.

## D. Rejected suggestions are a surface, and are never "waiting"

`reject_candidate()` leaves `status = 'candidate'` and sets `superseded_at`
with `superseded_by` null, and records a `candidate_rejected` event carrying
`properties = {assertion_id, reason, outcome}` with the actor in
`events.actor_system`. `review_queue` requires `superseded_at IS NULL`, so the
two sets are disjoint by construction — obligation 41.6 asserts no assertion id
appears in both.

**`rejected_candidates`**, new, `security_invoker`: `assertion_id`,
`subject_ref`, `subject_node_id`, `subject_edge_id`, `subject_label`,
`assertion_type` (canonical), `stored_assertion_type`, `assertion_key`, `claim`,
`basis`, `confidence`, `classification`, `attrs`, `asserted_at`,
`rejected_at` (`superseded_at`), `rejected_by` (the event's `actor_system`),
`rejected_reason`, `rejected_outcome` (`attrs->>'outcome'` where a labelling
wrote one, else the event's), `rejection_event_id`.

Membership is `status = 'candidate' AND superseded_at IS NOT NULL AND
superseded_by IS NULL` — a candidate closed by naming a replacement was
displaced, not rejected, and belongs to the supersession chain. The event is
joined on `properties->>'assertion_id'` and is a `LEFT JOIN`: a candidate closed
by a raw update has no event, and the row still appears with null `rejected_by`
and `rejected_reason` rather than vanishing. A surface that hides an unexplained
rejection is worse than one that shows it as unexplained.

## E. `opportunities_active` stamps its own snapshot

Three ways to stop a matview serving stale contact data silently, with their
costs:

1. **Refresh triggers on the source tables.** Correct to the statement, and
   unaffordable: every node, edge, and assertion write would refresh the whole
   matview, serialising writes, and on a tracked domain table it would run
   inside the application's own transaction — where `capture_domain_change()`
   is forbidden to fail or slow the application's write. Rejected on the overlay
   promise alone.
2. **A refresh-log table** written by `refresh_materialized_views()`. Cheap per
   refresh, but it is a new supporting table with its own RLS and write-gate
   rules, and it lies the moment someone runs `REFRESH MATERIALIZED VIEW`
   directly — the marker says fresh because nobody told the log.
3. **A `snapshot_at timestamptz` column on the matview**, `now()` in the view's
   own select list, so every row carries the instant the snapshot was computed,
   by whatever path refreshed it. Chosen.

The cost of (3) is stated rather than buried: `REFRESH ... CONCURRENTLY` diffs
whole rows, and since `snapshot_at` changes on every row at every refresh, the
concurrent refresh now rewrites every row instead of only changed ones.
`opportunities_active` holds open opportunities, a set bounded by a team's
pipeline rather than by instance size, so this is milliseconds and bloat the
autovacuum already handles. It also costs a `DROP` and `CREATE` of the matview
in `0125`, which rebuilds it on upgrade under an exclusive lock — the same
operation `0120` already performed.

Beside it, `opportunities_active_freshness` (view, `security_invoker`):
`snapshot_at` (the matview's `max`), `age`, `stale_after`, `stale`, `row_count`.
`stale_after` is data — `registry_value('matview_stale_after:opportunities_active')`,
defaulting to 15 minutes when unset — so an instance retunes it with an
assertion and no migration, and `stale` is `snapshot_at IS NULL OR
now() - snapshot_at > stale_after`. **It is an age marker, not change
detection.** Answering "is anything actually newer" costs a scan of nodes,
edges, and assertions on every read, and the one index that would make the node
half cheap does not exist. A false "stale" is the safe direction and the screen
says "as of 14:05" either way.

This is the whole reason the item needs a `01xx` file: `install.sh --profiles`
may omit crm entirely, and profile migrations apply after every core one, so a
core migration may not mention `opportunities_active` and a fix placed in one
would be overwritten by `0120` on a fresh install.

## F. Every new view is `security_invoker`, and silence means silence

All of `candidate_assertions_weighted`, `review_queue_candidates`,
`rejected_candidates`, `opportunities_active_freshness`, and the replaced
`review_queue`, `competing_candidates`, and `stale_digests` are
`WITH (security_invoker = true)`. None is `SECURITY DEFINER` and none reads past
RLS, so no new disclosure exists: every column is something the caller could
select from the base tables itself.

What a caller who cannot read part of a row sees:

- A candidate whose subject node is invisible is absent entirely — node
  visibility is the anchor and assertions cascade from it.
- A visible candidate whose **incumbent** is classified above the caller's read
  level shows null `incumbent_*` and `incumbent_is_current` false. That reads
  like "no incumbent" and is not, which is ordinary RLS silence, restated in
  `contracts/sql-surface.md` and in `contracts/admin-api.md`: zero rows and null
  columns never mean absence.
- `evidence_count`, `witness_count`, and `latest_evidence_at` count only
  evidence this caller can read, so two callers may see different numbers for
  one candidate. That is visibility, not disagreement, and it matches how
  `rye_settlers()` already reports `excluded_agents`.
- `opportunities_active` is a materialized view: RLS on the base tables does not
  apply to reads of it, as has always been true. Its freshness view adds no row
  that was not already readable to anyone who could select the matview.

The matview is the reason the obligations below run under both owner types
twice: on the Docker install the owner is a superuser and RLS binds nothing
inside a `SECURITY DEFINER` helper, so a view test that passes there proves
little. Under `scripts/test-nonsuperuser-owner.sh` the suite runs as
`rye_owner` with no `SET ROLE`, and the vacuity guard is `rolsuper = false AND
rolbypassrls = false`.

## G. What 0035 and 0125 replace

`0035` (core) replaces `base_effective_confidence`, `review_queue`,
`competing_candidates`, and `stale_digests`, and creates
`base_effective_confidence_unchecked`, `projected_effective_confidence`,
`candidate_assertions_weighted`, `review_queue_candidates`, and
`rejected_candidates`. It does not touch `effective_confidence`,
`current_assertions_weighted`, `open_gaps`, `node_salience`, or any function.

`0125` (crm profile) drops and recreates `opportunities_active` with
`snapshot_at` and its four indexes, and creates
`opportunities_active_freshness`.

No object here is replaced by `0031` (`node_source_map`, `merge_nodes`,
`link_record`), `0032` (the traversal functions), `0033`
(`resolve_node_identity`), `0034` (`log_agent_query`, `agent_query_trace`), or
`0036` (`scope_review_policy`, `scope_review_policy_rank`,
`record_scope_policy`, `record_assertion`, `settle_gate`, `describe_category`).

## H. What the admin removes

In `admin/src/server/queries.ts`, `fetchAssertionReviewQueue()`:

1. the `queue` CTE's `LEFT JOIN rye.nodes subject` — `subject_label` and
   `subject_node_type` come from the view;
2. the correlated `incumbent` subquery over `rye.current_valid_assertions` —
   replaced by the `incumbent_*` columns, with `incumbent_is_current` carried
   into the payload;
3. the per-candidate `newest_candidate_at` aggregate over the `candidates` jsonb;
4. the per-candidate `witness_count` subquery over `rye.assertion_evidence`;
5. the `basis_prior` chip's `registry_value('basis_prior:' || a.basis)` lookup
   and the null `effective_confidence` beside it — both become
   `projected_effective_confidence` from `review_queue_candidates`.

`ASSERTION_EVIDENCE_SQL` stays: the drawer wants event summaries and witness
labels, which the queue deliberately does not carry. Every query still goes
through `ryeQuery()`; `npm run check:db` and `check:routes` still pass.

## Test obligations, conformance 41

Each runs under a non-superuser role and under
`scripts/test-nonsuperuser-owner.sh`, and the suite fails rather than skips
without `0035`; the `0125` obligations assert `to_regclass('rye.opportunities_active')`
first and fail loudly when the crm profile is installed but the migration is not.

1. **41.1 A candidate projects a number.** A live candidate has
   `projected_effective_confidence` not null in `review_queue_candidates` and in
   `candidate_assertions_weighted`. Anti-vacuity: the same row's
   `effective_confidence(ROW(a.*))` is null, so the test proves the new function
   and not a change of fixture.
2. **41.2 The projection agrees on accepted rows.** For every row of
   `current_valid_assertions`, `projected_effective_confidence` equals
   `effective_confidence`. Anti-vacuity: assert the view returned at least three
   rows and at least one non-null value.
3. **41.3 A lone candidate is not its own competitor.** A tuple with exactly one
   live candidate projects the value it carries after acceptance, within
   rounding; a second live candidate on the same tuple lowers both projections.
4. **41.4 The queue answers without a subquery.** For a candidate written
   against an accepted incumbent: `subject_label`, `incumbent_assertion_id`,
   `incumbent_claim`, and `waiting_reason` are populated, `waiting_reason` is
   `settle_gate` for a settle-gated demotion and `review_gate` for a policy
   demotion and `none` for a plainly recorded candidate, and a tuple carrying
   both markers reads `settle_gate`. Anti-vacuity: assert the incumbent id
   equals the row `accept_assertion()` then supersedes.
5. **41.5 The culprits agree with the booleans.** In `stale_digests`, for every
   row, `newer_subject_assertion = (cardinality(newer_assertion_ids) > 0)` and
   `overturned_source = (cardinality(overturned_source_assertion_ids) > 0)`, and
   at least one row of each kind exists.
6. **41.6 Rejected is never waiting.** After `reject_candidate()`, the assertion
   appears in `rejected_candidates` with `rejected_by`, `rejected_at`, and
   `rejected_reason` populated, and in `review_queue` for no tuple. Anti-vacuity:
   assert it *was* in `review_queue` before the rejection.
7. **41.7 A candidate closed by a replacement is not a rejection.** A candidate
   with `superseded_by` set does not appear in `rejected_candidates`.
8. **41.8 Existing columns did not move.** `information_schema.columns` for
   `review_queue`, `competing_candidates`, and `stale_digests` shows the
   pre-`0035` names, types, and ordinal positions unchanged, with the new
   columns after them. This is the test that catches an accidental reorder.
9. **41.9 `competing_candidates` inherited the columns.** It exposes every
   column `review_queue` does, and only tuples with `candidate_count > 1`.
10. **41.10 The views add no visibility.** Under a role that cannot read a
    classified incumbent: the candidate row is present, `incumbent_*` is null,
    and a direct select of that incumbent from `assertions` returns zero rows for
    the same role. Under `admin` both are visible. Repeat for
    `rejected_candidates` and `review_queue_candidates`, on both owner types.
11. **41.11 The snapshot moves.** `opportunities_active.snapshot_at` is
    identical across rows, and a `refresh_materialized_views()` advances it.
    Anti-vacuity: assert the pre-refresh value is not null and strictly earlier.
12. **41.12 Freshness is data-driven.** With `matview_stale_after:opportunities_active`
    unset, `stale` is false immediately after a refresh; with the registry entry
    accepted as `'0 seconds'`, the same row reads `stale` true. Anti-vacuity:
    assert `row_count` is greater than zero, so an empty matview cannot pass.

## Cost

`review_queue` gains one `LEFT JOIN` to `nodes` and one lateral lookup of the
incumbent per tuple — work the admin was already doing per tuple, now done once
for every client. `review_queue_candidates` costs one pass over live candidates
with three evidence aggregates; it is the queue, not the graph, and the queue is
bounded by what people have not reviewed yet. The projection function is the
same arithmetic as `effective_confidence`, run on rows it used to skip. The
matview pays a full row rewrite per refresh, above.
