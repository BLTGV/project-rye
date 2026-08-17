# RLS Visibility Contract for Derived Reads

**Status:** Proposed. Recommendation is to adopt.

**Decision owner:** Project Rye maintainers

**Last evaluated:** 2026-08-17

**Context:** issue #17. Constrains the graph traversal and identity resolution
work. The default-safe half is implementable immediately; the two opt-in
disclosures below need a maintainer decision before they ship.

## Summary

Forced RLS means a derived read cannot distinguish *absent* from *invisible*.
Every existing Rye read surface is a projection of rows the caller can see, so
this has never mattered: an assertion you cannot see simply is not in
`current_valid_assertions`, and nothing downstream claims otherwise.

Two new derived reads break that property, because both answer questions about
what is **not** there:

- **Traversal** — "is there a path from A to B?" A path pruned by RLS returns
  the same empty result as a path that does not exist.
- **Identity resolution** — "does a node with this identity already exist?" A
  node hidden by RLS returns the same "no" as a node that was never created.

The two failure modes are not equally serious, and this proposal treats them
differently.

## Failure modes

### Traversal false negative — recoverable

An agent asks whether a supplier problem connects to a conversion drop. The
connecting node is classified above the caller's access. Traversal returns
nothing, the agent reports no connection.

This is wrong but survivable. Nothing is written, no state is corrupted, and a
caller with wider access gets the right answer on a re-run. It is the same
class of wrongness as any RLS-scoped read: you see less than the whole truth,
which is the point of RLS.

### Resolution split-brain — silent and corrupting

An intake agent resolves the identity of an organization. The existing
canonical node is classified above the caller. Resolution returns `new`, the
agent creates a second node, and both now exist.

This is materially worse:

1. No single role can see both nodes, so no one is positioned to notice.
2. Evidence, assertions, and edges accrue to both independently.
3. `record_distillation()` refuses mixed-access source sets
   (`docs/core-model-v2.md` §2.4), so a digest spanning the two can never be
   written — the split is not merely untidy, it is a permanent hole in the
   derived layer.
4. `merge_nodes()` needs a role that can see both. That role may not exist.

A write path that silently produces un-mergeable duplicates is a correctness
bug, not an access-control nicety. It deserves a different answer than
traversal gets.

## Principle

Rye's existing stance is that **gaps are visible**: `knowledge_gap`
assertions, `open_gaps`, `context_gap` candidates, and the
`node_salience` view comment all say the same thing — an honest system reports
what it does not know instead of implying completeness.

The tension is that saying "there is something here you cannot see" is itself a
disclosure. Separate two kinds:

- **Existence disclosure** — one bit, about a specific identifier the caller
  already supplied. Bounded, non-enumerable, auditable.
- **Content disclosure** — labels, types, properties, counts, or anything that
  varies over time. A count is a cardinality channel; a label is content. Never
  disclosed.

Existence disclosure against a caller-supplied exact identifier is acceptable
where it prevents corruption. Everything else is not.

## Decisions

### D1 — Traversal prunes silently (default, ships now)

`find_paths()` and `neighborhood()` run as `SECURITY INVOKER`, walk only rows
RLS admits, and emit no completeness signal. A caller cannot tell a pruned path
from an absent one.

Rationale: the failure is recoverable, and the alternative leaks graph topology
— the one thing a traversal function is uniquely able to leak in bulk.

**Traversal must never be `SECURITY DEFINER`.** A definer-side walk over
arbitrary edges is a wholesale topology disclosure, and no filtering applied
afterwards can undo it. This is a hard constraint, enforced by conformance.

### D2 — Opt-in traversal completeness flag (needs decision)

Behind a `rye.path.completeness` capability grant, traversal results gain a
single boolean `partial` for the **whole result set** — not per hop, not a
count of pruned edges. A count would let a holder measure hidden fanout;
a boolean tells them only that their answer is incomplete.

Grantees are expected to be admin-facing or audit tooling, not ordinary agents.

Not required by the initial traversal work. Recommended as a follow-up once
there is a caller that needs it.

### D3 — Identity resolution reports a restricted match (needs decision)

`resolve_node_identity()` gains a fourth verdict alongside `match`,
`ambiguous`, and `new`:

```
restricted — an existing node matches this identity, and you cannot see it.
```

The verdict carries **no node id, no label, no type, and no count.** An earlier
draft of this design returned candidate ids from the definer path; that is
unnecessary — the caller cannot act on an id it cannot read. One bit is
sufficient to prevent the duplicate, so one bit is all that is disclosed.

Agent behavior on `restricted`: do not create the node. Route to
`create_knowledge_candidate()` with reason `restricted_identity_match`, for
resolution by a role with wider visibility.

Implementation constraints, all conformance-tested:

- The probe is `SECURITY DEFINER` over **exact equality on normalized declared
  identity keys only** — tier 1 (`external_source`/`external_id`) and tier 2
  (`identity_keys:<node_type>`). Trigram and label matching never run in the
  definer path, so the probe cannot be used to enumerate or to search.
- The probe returns `boolean`. It cannot return rows.
- Every `restricted` verdict is recorded via `record_agent_action()`, so
  repeated probing is visible in the audit trail.
- Disableable per install with registry key `identity_restricted_probe`
  (default `true`). On a single-population install the probe is a no-op
  because nothing is hidden from the caller in the first place.

**Residual risk, stated plainly:** a caller who already knows an exact
normalized identifier can learn whether a node with that identifier exists.
That is a genuine oracle. It is accepted because the identifier must be known
in advance (no enumeration), the disclosure is one bit with no content, the
alternative is silent permanent graph corruption, and the probe is both
auditable and switchable off.

### D4 — Advisory, never blocking

`resolve_node_identity()` is a read. It writes nothing, and no write helper
calls it. Intake agents call it and decide; the database records the outcome
through the ordinary candidate and review path.

This follows the broader principle in issue #17 — agents perform graph inserts,
the database gates outcomes rather than steps. A deterministic resolver in the
write path would have to make the judgment call itself, with less context than
the agent has, and would block bulk intake on per-row ambiguity.

## Conformance requirements

1. No traversal function is `SECURITY DEFINER` (catalog assertion over
   `prosecdef`, not a grep).
2. Traversal as a restricted role returns no path through a node that role
   cannot see, and returns no completeness signal without the capability.
3. The identity probe returns `boolean` only; its return type is asserted in
   the catalog.
4. The probe ignores label/trigram input entirely — a caller supplying only a
   label never reaches the definer path.
5. `restricted` is returned when a hidden identity-key match exists, and `new`
   when nothing matches, for the same caller.
6. `identity_restricted_probe = false` collapses `restricted` to `new`.
7. `resolve_node_identity()` performs no writes other than the audit record,
   and no write helper references it.
8. An install that configures no identity keys and no classifications behaves
   exactly as it does today across the full existing suite.

## Rejected alternatives

| Alternative | Why rejected |
|---|---|
| Return candidate ids from the definer probe | The caller cannot read them. One bit achieves the same prevention with strictly less disclosure. |
| Return a count of hidden matches | Cardinality channel. `restricted` is `restricted` whether one node or fifty. |
| Accept the split and rely on a later gardener pass | The gardener needs a role that sees both, which may not exist; by then both nodes carry independent evidence and the digest layer has already been unable to span them. |
| Refuse the write when the caller's population is narrower than the node type's | Too blunt. Ordinary multi-team operation is exactly this case, and it would break normal intake to prevent a rare corruption. |
| Definer traversal with post-filtering | Filtering after the walk does not undo the walk; ranking, ordering, and result counts all remain functions of invisible rows. |
