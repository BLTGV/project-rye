# Rye — Agent Access and Promotion

Status: proposed design direction

## Scope

This document defines two related contracts:

1. how trusted and scoped agents enter Rye
2. how an agent interpretation becomes accepted knowledge

It does not design CDC payload migration, change cursors, materialized-view
freshness, or retention. Those are separate proposals with different migration
and compatibility requirements.

Rye core remains SQL. An API, MCP server, CLI, or admin UI is a replaceable
wrapper over the database contract.

## Outcome

Rye should let agents complete routine work without requiring a human approval
for every interpretation. Humans define authority and policy. Every proposed
accepted write receives one decision:

| Decision | Meaning |
|---|---|
| `allow` | The request matches active authority and policy. Complete the write and record why. |
| `review` | The request may be valid, but policy, evidence, authority, or confidence is incomplete. Preserve a candidate for review. |
| `deny` | The agent lacks capability, domain access, or an applicable scope. Record the denial without writing accepted knowledge. |

Observation is a pipeline stage, not an autonomy mode. An authorized user's
explicit instruction is an authority input, not a separate decision type.
Policy, evidence, classification, confidence, and conflict state are other
inputs to the same `allow` / `review` / `deny` decision.

## Day-One Behavior

The default posture must be useful without silently granting autonomy.

### Fresh installs with no autonomy policies

- Trusted local SQL keeps the existing Rye helper behavior.
- A scoped agent may read only domains explicitly granted and populated for
  scoped access.
- A scoped agent with `rye.observation.create` may preserve an observation.
- A scoped agent with `rye.candidate.create` may create a candidate.
- A semantic promotion request with no matching policy returns `review`.
- No matching policy never means automatic promotion.
- Missing capability or an ungranted domain returns `deny`.
- An authorized reviewer may still promote through the explicit review path.

This makes an unconfigured local install usable while keeping scoped agent
autonomy conservative.

### Existing installations when the evaluator ships

The migration does not change the behavior of existing trusted helpers such as
`record_assertion()` or `promote_candidate_to_assertion()`.

Roll out policy enforcement in three operational steps:

1. Install domain membership, decision records, and policy-aware helpers.
2. Evaluate existing promotions in audit-only comparisons without blocking the
   trusted caller. Report what would have been allowed, reviewed, or denied.
3. Opt specific domain and claim-type pairs into policy enforcement after their
   authorities and source rules are confirmed.

The existing helpers remain trusted administrative primitives. Scoped DB,
API, MCP, and CLI agents use the policy-aware helper that evaluates and promotes
atomically.

## Core And Optional Footprints

### Rye Core

Rye Core contains the durable contract used by every access path:

- agent identities, tokens, capabilities, and audit records
- knowledge domains and authorities
- node-domain membership
- promotion policies and decision records
- candidate creation and lifecycle helpers
- policy-aware read, evaluation, and promotion functions

These supporting objects are installed with Rye Core. A single-user trusted
local installation does not have to configure domains or agent tokens until it
enables scoped access.

### Optional Agent Gateway

The Agent Gateway provides HTTP and MCP wrappers over the same Rye Core
functions. It owns no separate policy logic or durable authorization state.

## Three Access Paths

The access paths are deployment choices, not autonomy decisions.

| Path | Intended caller | Enforcement |
|---|---|---|
| Trusted SQL | Operator-controlled agent with trusted database credentials | Existing RLS, session context, lifecycle helpers, and audit; caller is inside the trust boundary |
| Scoped DB | Agent with a restricted database credential and Rye token | Database privileges prevent table bypass; token-authenticated Rye functions enforce capability, domain, and promotion policy |
| Secure API/MCP | External or untrusted runtime | Bearer token, payload limits, and the same policy-aware Rye functions used by scoped DB access |

### Trusted SQL

A trusted direct-database agent may query security-invoker views and call Rye
helpers directly. It must:

- set Rye session context in every stateless call
- use `current_valid_assertions` for current accepted knowledge
- use lifecycle helpers for assertions, events, candidates, disputes, and
  scheduling
- use an attributable actor and log agent reads
- treat raw table mutation outside the helper contract as an administrative
  action

This path is convenient, not an enforceable sandbox. An owner or administrative
database credential can bypass a CLI. Deployments must classify that agent as
trusted.

### Scoped direct database

Scoped DB access needs an enforceable database boundary. Provide a technical
transport role, for example `rye_agent_runtime`, with:

- `CONNECT` to the database
- `USAGE` on the `rye` schema
- `EXECUTE` on approved token-authenticated `agent_*` functions
- no direct table privileges on Rye core or supporting tables
- no execution rights on administrative helpers

The transport role is not business authorization. Rye does not use
`current_user`, `pg_has_role()`, or role membership to decide domain authority.
Its purpose is to stop a scoped direct-database caller from bypassing the
function surface.

### Secure API and MCP

External runtimes use the same agent functions through an optional gateway.
Tool registration and route access follow the authenticated agent's
capabilities. The gateway must not call broad admin queries on behalf of an
agent token.

## Relationship To The Existing Security Model

`design/model/security.md` remains the source of truth for RLS, `access_grants`,
classification, field redaction, and session context.

The distinction is caller trust:

- In trusted SQL and trusted applications, the application establishes session
  variables before RLS-protected queries. This is the existing model.
- In scoped DB access, caller-set session variables are not proof of agent
  identity because the caller can set custom PostgreSQL settings.
- The restricted transport role prevents direct table access. A
  token-authenticated Rye function establishes the agent identity, checks Rye
  policy data, performs the bounded operation, and records the action.
- Database roles never determine business authority. Domain and claim authority
  continue to come from Rye data.

This adds a transport boundary for untrusted database callers without replacing
the session-variable authorization model used by trusted callers.

For transaction-mode poolers, each scoped function call authenticates the Rye
token and performs the operation in one transaction. A later implementation may
add a short-lived backend-bound agent session for dedicated connections, but a
caller-set GUC alone is insufficient.

Tokens must be passed through parameterized calls and must not appear in
generated SQL, process arguments, audit payloads, or error messages.

## CLI Command Tree

Use one deliberate command tree:

- `rye agents ...` remains the existing administrative interface for creating
  identities, granting capabilities, issuing tokens, revoking tokens, and
  auditing agents.
- `rye agent ...` is the scoped runtime interface for one authenticated agent.
- the existing `rye context` command remains a compatibility alias for
  `rye agent context --trusted`; it is not a separate context contract. The
  alias must preserve the existing `--scope` and `--json` flags, global
  connection, schema, and quiet options, output shape, and exit behavior.

Proposed runtime commands:

```text
./scripts/rye agent context --domain account-updates --json
./scripts/rye agent search --query Acme --domain account-updates --json
./scripts/rye agent summary --node <uuid> --json
./scripts/rye agent observe --input observation.json --idempotency-key <key>
./scripts/rye agent propose --input candidate.json --idempotency-key <key>
./scripts/rye agent evaluate --candidate <uuid> --json
./scripts/rye agent promote --candidate <uuid> --input target.json --idempotency-key <key>
```

The singular/plural distinction is intentional: `agents` administers the
collection of agent identities; `agent` performs a scoped runtime operation.

CLI requirements:

- call the same SQL functions as API and MCP
- use parameterized database calls
- accept connection and token values through environment variables or secure
  input, not process arguments
- return stable JSON envelopes and meaningful nonzero exit codes
- include decision reason codes
- support dry-run evaluation
- make every write idempotent
- authenticate, authorize, write, and audit in one transaction where possible

## Node-Domain Membership Contract

Scoped reads need a durable answer to:

> Which knowledge domains contain this node at the requested time?

Add a supporting `node_domain_memberships` table. It does not add columns to a
core table.

Required fields:

- membership id
- node id and domain id
- nullable scope reference, normalized consistently for constraints
- effective start and end
- membership source event
- properties and creation time

Required invariants:

- no overlapping effective ranges for the same node, domain, and normalized
  scope
- at most one active membership for the same node, domain, and normalized scope
- end time later than start time
- membership kind, if retained, must not affect authorization unless its
  semantics are defined by policy

Required indexes:

- `(node_id, effective_at, effective_to)`
- `(domain_id, effective_at, effective_to)`
- a unique partial index for the active node/domain/normalized-scope key

PostgreSQL 15 cannot enforce temporal non-overlap for scalar keys without either
an exclusion constraint or a trigger. An exclusion constraint requires the
additional `btree_gist` extension. The implementation proposal must choose and
test one of these options before executable DDL is added. This overview does not
present incomplete migration-ready DDL.

Membership inheritance:

- assertions inherit the domains of their subject node
- edges require visibility to both endpoints
- events inherit visibility from their participants
- artifacts inherit from their source and related nodes
- candidate creation records candidate membership
- promotion verifies target membership
- cross-domain sharing requires an explicit membership
- labels, channel names, and connector metadata never create membership

Backfill candidate membership from `target_payload.domain_keys`. Put other
unclassified nodes in an admin worklist rather than inferring their domain.

## Promotion Decision Contract

Add an append-only promotion decision record containing:

- candidate and authenticated agent
- decision: `allow`, `review`, or `deny`
- durable reason codes
- matched policy references and a policy snapshot
- missing conditions
- requested target
- decision and effective times

The evaluator considers:

- agent capability and domain grants
- candidate and target domain membership
- assertion or target type and stable key
- authority kind and authority reference
- speech act such as confirmed, approved, decided, suggested, or inferred
- source confirmation status
- evidence requirements
- confidence policy
- classification and sensitivity
- impact and reversibility
- current, planned, future, or historical meaning
- conflicting active assertions
- policy effective dates

Default results:

- missing capability or ungranted domain: `deny`
- no applicable promotion policy: `review`
- incomplete authority or evidence: `review`
- contradiction: `review` through the dispute path
- complete active policy match: `allow`

Policy records are temporal. A decision retains the policy snapshot used at the
time so later policy changes do not rewrite why the action occurred.

## Explicit User Instructions

An authenticated user instruction is one authority input to the evaluator. The
system records:

- user and agent identity
- requested operation and target
- domain and effective time
- a safe instruction digest
- idempotency key

The evaluator may return `allow` when the user has authority for the narrow
action. It returns `review` or `deny` when the target is ambiguous, the user
lacks authority, the request crosses scope, or active policy conflicts.

The same authorized user is not asked to approve the same action twice.

## Candidate And Promotion Lifecycle

An LLM-derived semantic interpretation normally creates a candidate even when
policy immediately returns `allow`. This preserves evidence and reasoning.

A deterministic structured source covered by an active source-of-truth policy
may use a shorter assertion path, but it still records the source event and
promotion decision.

Policy evaluation and promotion happen atomically. Add a durable promotion
record with a unique candidate and promotion key. The helper:

- locks the candidate
- evaluates active policy
- rejects invalid candidate statuses
- returns an existing result for a repeated idempotency key
- creates the target, status transition, event, decision reference, and audit
  record in one transaction
- requires an explicit policy when one candidate legitimately produces multiple
  accepted targets

The existing promotion helpers remain trusted primitives. Scoped callers use
the policy-aware atomic helper.

## Wrapper Contract

CLI, API, and MCP expose the same semantic operations:

- context and domain listing
- bounded node search and summary
- observation creation
- candidate creation
- candidate evaluation
- candidate status and promotion, when capability permits
- audit reads, when capability permits

Each response separates accepted knowledge, plans, pending candidates,
evidence, and history. External wrappers do not expose raw SQL.

## Out Of Scope Follow-Ups

The following findings remain important but are intentionally separate:

- **CDC data protection.** Define a versioned migration for new payload shapes,
  consumer compatibility, classification and read-time redaction of existing
  immutable events, and safe defaults for newly tracked tables.
- **Incremental consumption.** Define domain-safe event cursors, replay, and
  optional wakeup mechanisms.
- **Read-model freshness.** Define how materialized CRM and PM views report and
  refresh freshness.
- **Retention.** Define evidence and event retention without weakening the
  append-only contract.

These proposals should be reviewed independently from agent access and
promotion.

## Conformance Requirements

Add tests for:

- existing trusted helper behavior unchanged after migration
- scoped semantic promotion with no policy returning `review`
- missing capability or ungranted domain returning `deny`
- explicit active policy returning `allow`
- no cross-domain discovery through scoped search or summary
- scoped database credentials unable to read or mutate Rye tables directly
- trusted session-context RLS continuing to behave as documented
- CLI, API, and MCP returning the same decision and reason envelope
- tokens absent from SQL text, process arguments, audit payloads, and errors
- no duplicate or conflicting active domain memberships
- temporal membership overlap rejected
- atomic retry-safe promotion
- competing concurrent promotion attempts producing one result
- invalid candidate status transitions rejected
- temporal authority and future-effective policy evaluation
- explicit user instruction recorded without duplicate approval

## Delivery Sequence

1. Close broad administrative routes to agent tokens.
2. Reconcile and document trusted SQL, scoped DB, and secure API/MCP paths.
3. Add constrained node-domain membership and domain-safe reads.
4. Add append-only promotion decisions and idempotent promotion records.
5. Implement the atomic policy-aware promotion helper with audit-only migration
   support.
6. Add the `rye agent` CLI and make API/MCP call the same SQL helpers.
7. Opt confirmed domain and claim policies into enforcement incrementally.

## Non-Goals

- Agents do not activate their own authority.
- The transport database role does not become a business authorization model.
- Trusted administrative helpers are not removed.
- Local installations do not require an API gateway.
- This proposal does not change CDC payloads or materialized views.

The desired result is not maximum autonomy. It is useful autonomy with a small,
explainable decision contract and one database-enforced implementation.
