# Rye Core Contract (v2)

Rye targets PostgreSQL 15+. The executable contract is the migration set plus
the conformance suites.

## Core guarantees

- The six core tables remain `nodes`, `edges`, `events`,
  `event_participants`, `assertions`, and `artifacts`.
- Assertions carry lifecycle (`candidate` or `accepted`), epistemic basis,
  effective time, system time, and classification.
- Accepted knowledge is append-only. Replacement creates a new row and
  supersedes the prior row.
- Candidate rows can compete on one tuple. They never appear in operational
  reads.
- `assertion_evidence` is the only assertion provenance primitive. It is
  append-only and visible only when both the assertion and referenced evidence
  endpoint are visible.
- Accepted assertions are unique per subject, type, key, and effective window.
- `current_valid_assertions` is the base for every operational read.
- `assertions_as_of(effective, known_as_of)` supports bitemporal reconstruction.
- Unknown node, edge, event, and assertion type values require no migration.
- Session context and forced RLS are the authorization model.
- Every view uses `security_invoker = true`.
- Traversal and search read as the caller. A path or node hidden by RLS is
  pruned silently and no completeness signal is emitted, so an empty result
  means "not visible", not "not present".

## Assertion lifecycle

Use `record_assertion()` for intake. Supply evidence in the same call unless
the basis is `assumed`.

Use `accept_assertion()` to accept a candidate. It supersedes the accepted
holder of the same tuple, if one exists. An inferred candidate cannot displace
a non-inferred accepted assertion.

Use `reject_candidate()` to close a candidate with a reason. Public
`supersede_assertion()` is restricted to a replacement with the same subject,
type, and key.

Use `schedule_assertion_change()` for future-effective accepted knowledge.
Use `record_distillation()` for inferred digests and
`resolve_knowledge_gap()` for answers to accepted gaps.

## Confidence

Stored `confidence` is a prior, not the final belief score.
`effective_confidence(assertions)` combines the stored prior or basis default,
independent corroboration, half-life decay, and live competing candidates.
`current_assertions_weighted` exposes the result without mutating assertions.

Registry keys use deterministic scope, plugin, then core precedence through
`registry_value(key, scope)`. Core basis priors are:

| Basis | Prior |
|---|---:|
| `observed` | 0.95 |
| `reported` | 0.70 |
| `inferred` | 0.60 |
| `assumed` | 0.30 |
| `unknown` | 0.50 |

## Release gate

Run `./scripts/conformance.sh` and `./scripts/verify.sh`.

When the connection user is a PostgreSQL superuser, the conformance harness
runs suites under a non-superuser role (`rye_conformance` by default,
configurable with `RYE_TEST_ROLE`) so RLS checks remain meaningful.
