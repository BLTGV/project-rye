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

## Configuration writes need an admin

Some assertion types are Rye's own configuration rather than knowledge about
the world, and Rye reads them to decide how it treats every other write. Those
types are gated by data: an `assertion_type_access` row with
`operation = 'settle'` names the roles that may make an assertion of that type
accepted. A type with no `settle` row is ungated. Two rows ship, both
`ARRAY['admin']`:

| `assertion_type` | Why |
|---|---|
| `registry_entry` | Type aliases, `self_settled_type:*`, `governed_type:*`, `DEFAULT_SCOPE`, basis priors, half lives, digest facets |
| `review_policy` | Decides whether other writes land accepted at all |

`record_assertion()` demotes rather than refuses: a non-admin's accepted write
of a gated type lands as a candidate carrying
`attrs.settle_gate = {"pending": true, ...}`, appears in `review_queue`, and an
admin accepts or rejects it there. Nothing said is lost, and no incumbent is
superseded.

Every other route to an accepted gated row raises, through one trigger on
`assertions`: a direct `INSERT`, any `UPDATE` that moves a row to `accepted`
(including `accept_assertion()` and a raw `UPDATE` by a caller who sets
`app.write_path` itself), `supersede_assertion()`, and `record_distillation()`.
`schedule_assertion_change()` and `record_scope_policy()` route through
`record_assertion()` and so demote. An agent capability grant
(`rye.authoritative.promote`) does not open the gate.

Ending an accepted configuration record changes the configuration, so the same
roles gate that too. A caller who may not settle a gated type may not change an
accepted row of it at all: not `superseded_at`, not `effective_to`, not
`status`, not `claim`, not `attrs`, by raw `UPDATE` or through any helper.
Candidates of a gated type are unaffected, and an admin keeps every lifecycle
operation. No role deletes an assertion: `assertion_delete_policy` is
`USING (false)`.

`settle_gate(assertion_type)` answers
`{assertion_type, gated, allowed_roles, current_role, may_settle}` so a client
can ask before it offers. The gate reads `app.current_role` only, and an unset
role is not an admin: a migration or script that seeds configuration must set
the role first.

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
