# 0014 Who may reject, and edges carry their own classification

Date: 2026-09-20. Work item: `work/018-session-leftovers.md`, second migration.
Contract: `contracts/sql-surface.md`, sections "Who may reject a suggestion" and
"Edges carry their own classification". Areas: schema (admin and agent-kit
read the consequences). Migration: `0037`. Conformance: `43`. Closes issue 38
and the `reject_candidate()` finding from today's verification.

Two holes, both found by Verifiers today, both of the same kind: a rule the
product states in prose that the database does not enforce.

## Part one: rejecting is an authority, and it was ungated

`reject_candidate()` (live in `0019`, `SECURITY DEFINER`) checks a reason, a
recognised outcome, and that the target is a live candidate. It checks nothing
about the caller. Executed as `agent:intake` on a fresh install under a
non-superuser role, it closed another agent's suggestion, a `team_member`'s
suggestion, and a `registry_entry` configuration suggestion. `accept_assertion()`
next to it gates an `agent:*` caller on the review policy and on
`rye.authoritative.promote` for the governing scope; the closing half of the
same lifecycle had no gate at all.

`BRIEF.md` says agents suggest and people accept, and that an agent carries the
authority of the person it acts for and none of its own. A suggestion nobody
can accept but any agent can close is not a suggestion. The
agent-ops guide and three skills already say the rule in words — "rejecting your
own suggestion is housekeeping; rejecting someone else's is a person's call" —
so this record makes a documented convention enforceable, and changes no
documented workflow.

### The rule

| caller | may close a live candidate |
|---|---|
| `admin` | any, including a settle-gated configuration type |
| named role with `may_write` (`team_member`, `manager`, …) | any **except** a settle-gated configuration type |
| agent-shaped (`agent:<key>`) | only one **it authored** — `attrs.recorded_by` equals this session's `app.current_role` — and never a settle-gated configuration type |
| `viewer`, unset, unknown, `system:cdc` | none. Unchanged: "Who may write" already refuses them, through `trg_assertions_gate_may_write` |

**Rejecting a configuration suggestion is settling it.** The settle gate's whole
promise is that nothing said is lost: a non-admin's configuration write is
demoted to a candidate an admin decides on. If any writing role can close that
candidate, the demotion promises nothing — a caller who cannot set
configuration can still make sure nobody else's proposal reaches an admin. So
the rejection of a type carrying a `settle` row is admin-only, by the same data,
`assertion_type_access`, read through `assertion_settle_roles()`, and gated on
the stored spelling **or** the spelling `canonical_type()` resolves it to, which
is the rule `0036` established for the write side. Nothing said is still lost
under this rule either way: a rejected candidate is closed, not deleted, and it
appears in `rejected_candidates` (`0035`) with who closed it, when, and why.

**`rye_settlers()` is not consulted.** It stays advisory, and nothing in a write
path calls it. It answers from rows the caller can see, so an answer of "nobody"
is often blindness; a refusal derived from it would vary by classification and
by area membership, which is not a rule. Who may reject is a role rule and an
authorship rule, both decidable from the row and the session.

### How authorship is known

It is not on the row today. `assertions` has no author column, and
`record_assertion()` takes no actor argument and records no event; `attrs` is
whatever the caller passed. So `0037` records it, in the only place that cannot
be skipped: **a `BEFORE INSERT` trigger on `assertions`,
`assertion_authorship_stamp()`, writes `attrs.recorded_by` as the session's
`app.current_role`**, overwriting any value the caller supplied, on every
insert, from every route, helper and raw alike. It also writes
`attrs.recorded_by_label` from `app.current_user_id` for the audit trail, and
that field decides nothing — `app.current_role` is which agent a session is, and
the label is a label, exactly as "Governance tables" already says.

Three consequences, stated because a client will meet them:

- **Older rows carry no `recorded_by`, and an agent may not close them.**
  Unknown authorship is not own authorship; unknown is restrictive. A named
  writing role or an admin closes them, and an instance that wants its history
  attributable backfills nothing — `attrs` is immutable, so there is no route
  to backfill, and that is the correct answer rather than an inconvenience.
- **A caller cannot forge authorship on a row it did not write.** It can write a
  new row claiming another author — the stamp overwrites, so in fact it cannot
  even do that — and it can never change an existing row's `attrs`, which the
  row rules already make immutable except for an outcome label.
- **The review screen gets "who suggested this" for free.** `review_queue` and
  `review_queue_candidates` already project `attrs`; no view changes shape.

### The row is the gate here too

`reject_candidate()` is replaced so it refuses **before** it labels an outcome
or marks the row superseded — lock and write after the gate, as `merge_nodes()`
and `score_due_predictions()` were taught — with `42501` and one of:

```
Rejecting a suggestion recorded by "%" is a person's call; "%" may close only
its own. Record your correction as a new suggestion and say what you disagree
with.
```
```
Assertion type % is Rye configuration: only % may close a suggestion of that
type, because closing it is deciding it.
```

But the helper's refusal is not the rule, because the raw route exists:
`docs/decisions/0008-the-row-is-the-gate-for-assertion-lifecycle.md` deliberately
allows a candidate to be closed with `superseded_by` null, and any caller can
set `app.write_path` itself. So the rule is a trigger,
`assertion_rejection_authority_guard()`, `BEFORE UPDATE ... FOR EACH ROW`,
trigger `trg_assertions_reject_authority`, firing on exactly the rejection
shape — `OLD.status = 'candidate'`, `OLD.superseded_at IS NULL`,
`NEW.superseded_at IS NOT NULL`, `NEW.superseded_by IS NULL` — and applying the
table above. It is the only transition it touches: a candidate closed **with**
a replacement is a displacement, judged by the rules that already judge it, and
`reject_candidate()` is the only helper in the repo that passes
`mark_assertion_superseded(id, NULL)`.

The trigger name sorts after `trg_assertion_settle_gate` and
`trg_assertions_immutable`, so no existing refusal message moves; it sorts
before `0036`'s `trg_assertions_review_policy_value`, which judges a different
kind of row.

**What this does not defend against**, in the same words the rest of the
contract uses: a caller with a raw connection sets `app.current_role` to
`admin` and this rule does not stop it. It binds deployments where a trusted
backend owns the session variables, and well-behaved agents that state their
role honestly — which is the population that produced today's finding.

**One boundary is worth naming because it is not obvious.** The admin Worker
sets `app.current_role = 'admin'` for every query, so an agent rejecting through
`POST /api/assertions/:id/reject` is judged by the API's route table — capability
`rye.candidate.adjudicate`, checked per target — and **not** by the authorship
rule here. That is a grant a person made deliberately, which is a different and
defensible answer from an agent reaching for the SQL function directly, but a
client must not read this section as covering the API. Recorded in
`contracts/admin-api.md` as well.

## Part two: an edge carries its own classification

`edge_read_policy` (`0003`) is `EXISTS (source node) AND EXISTS (target node)`
and reads nothing of the edge. So an edge with
`attrs = {"classification":"confidential","teams":["locked"]}` between two
public nodes is readable by `viewer` and by a session with no role, and
traversal shows it because traversal is `security_invoker` and mirrors direct
readability. Issue 38, pre-existing, not introduced by `0032`.

**Enforced, not documented away.** The alternative — rule that edges classify
only through their endpoints and say so — was considered and rejected. Marking a
row is an operator asking for something; a mark that silently does nothing is
worse than no mark, and this one is already written where an operator would
write it. Documenting the hole would also leave `attrs.teams` on an edge as a
trap for the next person, and would make the edge the one row type in the schema
whose `attrs` mean less than they look.

**The rule is the node rule, unchanged.** Endpoint visibility still applies and
the edge's own attrs are ANDed with it:

```
both endpoints visible
AND (
    attrs->>'classification' IS NULL
    OR attrs->>'classification' = 'public'
    OR attrs->'teams' ?| app.current_teams
    OR an active access_grant matching this session by user, role, or team,
       scoped by edge_id, edge_type, or classification
)
```

`access_grants` has no `CHECK` on `resource_type`, so `resource_type = 'edge'`
with `scope->>'edge_id'`, `scope->>'edge_type'`, or `scope->>'classification'`
needs no constraint change — it is the node branch with the nouns changed.

**The write side matches the node rule too.** `enforce_edge_classification_with_teams()`
on `edges`, `BEFORE INSERT OR UPDATE`, trigger `trg_edges_classification_check`,
refuses a non-empty `attrs.teams` with no `attrs.classification`, exactly as
`enforce_classification_with_teams()` has refused it on `nodes` since `0001`.
Without it, the read rule's `classification IS NULL` branch makes a team-marked
edge world-readable, which is the same hole one table over.

**What existing rows look like.** The trigger judges writes, not history, so an
edge already carrying teams and no classification stays readable to everyone
until somebody sets a classification on it — and setting one is an `UPDATE` that
the trigger then accepts. On today's tree the blast radius is nil: **no
migration, test, seed, fixture, or skill in the repository writes
`classification` or `teams` into an edge's attrs**, verified by grep, so no
existing row changes visibility and no suite loses a row. The rule starts
meaning something the first time an operator marks an edge, which is the point.

**What cascades, and what does not.** Assertions on an edge inherit it for free:
`assertion_read_policy` requires `EXISTS (SELECT 1 FROM edges WHERE id =
assertions.subject_edge_id)`, so an assertion about a hidden edge is hidden.
Traversal inherits it for free: `find_paths()` and `neighborhood()` (`0032`) are
`security_invoker` and read `edges` under the caller's policies.
`event_participants` does **not** cascade and needs nothing: it references
`node_id` only, and an edge is never an event participant.

The admin Worker is affected exactly as it already is for nodes, and this is
worth saying plainly because it surprises people: `node_read_policy` has **no
admin exemption**. An `admin` session reads a classified node only through
`app.current_teams` or an `access_grants` row, and the edge rule inherits that
property unchanged. So a marked edge disappears from `/api/nodes/:id/graph` and
from the knowledge map for a console session without the team, precisely as a
marked node already does, and the fix is the fix that already exists — set the
session's teams, or grant access. On today's tree no edge is marked, so no
screen changes.

## What `0037` replaces

| object | disposition |
|---|---|
| `reject_candidate(uuid, text, text, text)` (`0019`) | replaced, same signature, same `candidate_rejected` event with the same `properties` keys — `assertion_id`, `reason`, `outcome` — so `0035`'s `rejected_candidates` view stays correct |
| `edge_read_policy` on `edges` (`0003`) | replaced |
| `assertion_authorship_stamp()` + `trg_assertion_authorship_stamp` | new |
| `assertion_rejection_authority_guard()` + `trg_assertions_reject_authority` | new |
| `enforce_edge_classification_with_teams()` + `trg_edges_classification_check` | new |

None of these is replaced by `0031` (`node_source_map`, `merge_nodes`,
`link_record`), `0032` (`find_nodes`, `find_nodes_batch`, `find_paths`,
`neighborhood`, `edge_semantics`), `0033` (`resolve_node_identity`, triggers on
`node_merges`), `0034` (`log_agent_query`, `agent_query_trace`), `0035`
(`base_effective_confidence`, `review_queue`, `competing_candidates`,
`stale_digests`, and the new candidate and rejected views), or `0036`
(`scope_review_policy`, `scope_review_policy_rank`, `record_scope_policy`,
`record_assertion`, `settle_gate`, `describe_category`). Two adjacencies are
deliberate and must stay true:

- `0037` does **not** touch `record_assertion()`, which `0036` replaces. The
  authorship stamp is a trigger precisely so the two items never edit one
  function — and the trigger covers the raw `INSERT` route, which a change
  inside the helper never could.
- `0037` does **not** change the `candidate_rejected` event, which `0035`'s
  `rejected_candidates` joins on `properties->>'assertion_id'`. A refused
  rejection records no event, which is correct: the candidate is still waiting.

## Test obligations, conformance 43

Each runs under a non-superuser role (`SET ROLE`) and under
`scripts/test-nonsuperuser-owner.sh`, and the suite fails rather than skips
without `0037`. Refusal shape follows the standing rule: a refused `INSERT`
raises `42501`; a refused `UPDATE` raises where the owner is a superuser and
affects zero rows where the owner is bound by RLS — **assert the row, not the
error text**.

1. **43.1 An agent cannot close another agent's suggestion.** `agent:alpha`
   records a candidate; `agent:beta` calls `reject_candidate()` and is refused.
   Anti-vacuity: `agent:beta` can read the row (`SELECT` returns it) and the row
   is still live afterwards (`superseded_at IS NULL`).
2. **43.2 An agent cannot close a person's suggestion.** Same with a
   `team_member`-recorded candidate.
3. **43.3 The correction route still works.** `agent:alpha` closes its own
   candidate and files a corrected one; the closed row appears in
   `rejected_candidates` with `rejected_reason`, and the new row is in
   `review_queue`. Anti-vacuity: assert `attrs->>'recorded_by' = 'agent:alpha'`
   on the closed row, so the test proves authorship matching and not a missing
   guard.
4. **43.4 A person still rejects ordinary suggestions.** `team_member` closes an
   `agent:alpha` candidate and an `admin` candidate of an ordinary type.
5. **43.5 Configuration rejection is admin-only.** A `registry_entry` candidate:
   `team_member` and `agent:alpha` are both refused, `admin` succeeds.
   Anti-vacuity: the admin rejection leaves the row closed and the two refusals
   leave it live; repeat with a type aliased into `registry_entry` to pin the
   canonical-spelling half.
6. **43.6 The raw route agrees.** With `app.write_path` and
   `app.accept_assertion_id`-style settings forged by hand, a raw
   `UPDATE assertions SET superseded_at = now()` on another author's live
   candidate, as `agent:beta`, leaves the row unchanged. Anti-vacuity: the same
   raw shape on `agent:beta`'s **own** candidate succeeds, so the test proves
   the authority guard rather than a policy that blocks every raw update.
7. **43.7 An unattributed row is closed by people only.** A candidate inserted
   with the stamp trigger disabled (as owner) carries no `recorded_by`; every
   agent-shaped caller is refused, `team_member` succeeds.
8. **43.8 Authorship cannot be chosen by the caller.** `record_assertion(...,
   p_attrs := '{"recorded_by":"agent:someone-else"}')` and a raw
   `INSERT INTO assertions` with the same attrs both land with
   `attrs->>'recorded_by'` equal to the session's `app.current_role`.
   Anti-vacuity: assert the supplied value is absent, not merely joined by the
   real one.
9. **43.9 The write gate is unchanged.** `viewer` and an unset role calling
   `reject_candidate()` are refused and the candidate is untouched.
10. **43.10 A marked edge is not readable.** An edge with
    `{"classification":"confidential","teams":["locked"]}` between two public
    nodes: invisible to `viewer`, to an unset role, and to a `team_member` whose
    `app.current_teams` is another team; visible with `app.current_teams`
    containing `locked`; visible to a session holding an active
    `access_grants` row with `resource_type = 'edge'` scoped by `edge_id`.
    Anti-vacuity: the refused sessions must see **both endpoint nodes**, or the
    test proves only that endpoints are hidden.
11. **43.11 Assertions on a hidden edge are hidden.** An assertion whose
    `subject_edge_id` is that edge returns zero rows for the refused session and
    one for the team session. Anti-vacuity: the same assertion is visible to
    `admin`.
12. **43.12 Traversal inherits.** `find_paths()` and `neighborhood()` (assert
    `to_regprocedure` first, and fail loudly if `0032` is absent) return no path
    through that edge for the refused session and do for the team session.
13. **43.13 Teams on an edge require a classification.** An `INSERT` and an
    `UPDATE` setting non-empty `attrs.teams` with no `attrs.classification` are
    refused for `admin` and for `team_member` alike; the same write with a
    classification succeeds.
14. **43.14 The historical row is disclosed, not hidden.** An edge written with
    the classification trigger disabled, carrying teams and no classification,
    is still readable by `viewer` — the stated limit — and becomes unreadable
    once an `UPDATE` sets its classification. Anti-vacuity: assert the first
    read returns the row.
15. **43.15 Nothing else moved.** `tests/conformance/30_configuration_gate.sql`
    still sees the settle gate's message first, and an ordinary unmarked edge is
    readable exactly as before to every role that could read it.

## Cost

Every assertion insert pays one `set_config`-free trigger that appends two keys
to a jsonb — measured in bytes per row, not queries. Every candidate closure
pays one role test and, for a gated type, one `assertion_settle_roles()` lookup
of a table the session already reads. `edge_read_policy` gains the node policy's
own disjunction: three cheap tests plus, only when they all fail, the same
`access_grants` subquery `node_read_policy` has always run — so a query over
unmarked edges pays two boolean tests and nothing else. The upgrade rewrites no
data and makes no existing row disappear.
