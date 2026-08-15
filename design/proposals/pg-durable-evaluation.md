# Optional Durable Execution with pg_durable

**Status:** Exploratory. No adoption decision has been made.

**Decision owner:** Project Rye maintainers

**Last evaluated:** 2026-07-12

## Summary

Rye may benefit from `pg_durable` as an optional execution adapter for
long-running, scheduled, and resumable SQL work. It should not become a Rye
Core dependency.

The strongest initial fit is scheduled materialized-view refresh, followed by
chunked imports, backfills, and post-capture processing. Rye's short atomic
writes should remain ordinary PostgreSQL transactions. This includes event
recording, assertion supersession, and governed process evaluation and
application.

This proposal records the potential integration and the conditions that would
need to be true before implementation. It does not add an extension, migration,
runtime, or PostgreSQL version requirement.

## Why Consider It

`pg_durable` is a PostgreSQL extension for checkpointed SQL workflows. It can
schedule work, compose sequential or parallel steps, wait for signals, and
resume after a database restart.

That execution model could fill a gap between Rye's durable state and the
operator that acts on that state. For example, Rye can mark a materialized view
dirty and expose that condition for inspection. An execution adapter could
refresh the view later, retry a failed refresh, and preserve progress across a
restart.

The same pattern could support:

- chunked `link_records_batch()` imports and backfills;
- artifact extraction or enrichment with stable deduplication keys;
- post-capture processing from a committed CDC staging record;
- retention and maintenance work;
- continuation after a human review, when a larger workflow must resume.

## Fit by Rye Capability

| Capability | Fit | Boundary |
|---|---|---|
| Scheduled read-model refresh | High | Refresh each due view as an observable, retryable unit. |
| Bulk import and backfill | High | Use stable batch keys and idempotent Rye functions. |
| Artifact processing | High | Use `content_hash` or another stable deduplication key. |
| Async CDC processing | Medium | Start only from committed staging data, not directly from each row trigger. |
| Human-review continuation | Medium | Treat the signal as a wake-up hint, then re-read and re-evaluate Rye state. |
| Governed process evaluation and application | Low | Keep evaluation and allowed application in one Rye transaction. |
| Events, assertions, and graph writes | Low | These are short atomic operations and do not need an orchestrator. |
| Agent and admin API isolation | None | Durable execution does not replace route or capability enforcement. |

## Non-Negotiable Architecture Boundaries

### Optional, Not Core

Rye Core supports PostgreSQL 15 and later. `pg_durable` currently targets
PostgreSQL 17 and 18, requires `shared_preload_libraries`, starts a background
worker, and is still in preview.

An integration must therefore be separately installed and capability-detected.
Core migrations, functions, tests, and conformance requirements must continue
to work without it.

Hosted PostgreSQL providers also control which native extensions and preload
libraries are available. The adapter must not weaken Rye's Supabase or generic
PostgreSQL compatibility.

### Rye Remains the System of Record

`pg_durable` execution state is operational state. It is not permanent Rye
provenance.

Consequential workflows must record their outcome through Rye, including:

- the workflow type and version;
- the `pg_durable` instance identifier;
- related node, event, candidate, assertion, or artifact identifiers;
- completion, cancellation, or failure state;
- a bounded retry and error summary.

Rye events and artifacts remain the audit record. This is required because
`pg_durable` applies retention to terminal workflow instances and does not
promise indefinite execution-history storage.

### Preserve Atomic Rye Operations

Durable steps must call existing Rye functions at transaction boundaries. They
must not split invariants that Rye currently enforces atomically.

In particular:

- use `record_event()` for event creation;
- use `record_artifact()` for artifact creation;
- use assertion supersession functions rather than mutating assertions;
- keep governed transition evaluation and application atomic;
- re-evaluate current policy, authority, evidence, and prior state after a
  human-review wait instead of applying a stale decision.

### Require Idempotency

Every retryable write activity needs a stable idempotency contract. Functions
that generate a new UUID or event on every call are not automatically safe to
retry.

Good initial candidates include `link_record()`, `link_records_batch()`, and
`record_artifact()` with `content_hash`. Other operations need an explicit
request key and uniqueness contract before durable execution can invoke them.

### Keep Authorization Token-Bound

Rye uses session variables and token-bound functions for business
authorization. `pg_durable` executes later SQL connections as the PostgreSQL
role that submitted the workflow. It does not preserve Rye session variables
between steps.

Any adapter must therefore:

- use a dedicated login role with minimal grants;
- execute only fixed, reviewed Rye wrapper functions;
- establish required Rye context inside each activity;
- never accept caller-controlled SQL through a `SECURITY DEFINER` wrapper;
- avoid granting outbound HTTP capability to agent roles by default;
- prevent multiple Rye agents sharing one database role from gaining
  cross-agent workflow visibility.

## Candidate Pilot

The first pilot should be narrow and reversible.

### Scope

1. Install `pg_durable` only in a PostgreSQL 17 or 18 test environment.
2. Create a dedicated `rye_durable_executor` login role.
3. Grant that role only the fixed functions required by the pilot.
4. Schedule refresh of due Rye materialized views.
5. Store the workflow instance identifier with the Rye refresh record.
6. Record completion or terminal failure as a Rye event.

### Required Rye Adjustment

The read-model work proposed in PR #3 returns a structured `failed` result from
`refresh_read_model()` instead of raising the SQL error. A durable executor
would interpret that return as a completed step.

Before a pilot, add a narrow wrapper that raises when refresh status is
`failed`. This gives the executor a real failure signal without changing the
existing operator-facing function contract.

### Validation

The pilot must demonstrate:

- restart recovery without repeating a completed view refresh;
- bounded retry of a failed refresh;
- no duplicate Rye completion events;
- no raw Rye table access for the executor role;
- no cross-role workflow visibility;
- correct behavior when the submitting role is disabled;
- acceptable connection and worker overhead;
- clean Rye installation and conformance tests without `pg_durable` present.

## Alternatives

| Option | Use when |
|---|---|
| Manual operator call | Work is rare and operational simplicity matters most. |
| `pg_cron` | One scheduled SQL call is sufficient and step-level recovery is unnecessary. |
| PostgreSQL queue plus worker | The deployment already has an application worker or needs arbitrary code. |
| External orchestrator | Work spans services, SDKs, or control flow that is not naturally SQL-shaped. |
| `pg_durable` | Most work is SQL-local and needs checkpoints, waits, retries, or parallel steps. |

Supabase currently offers `pg_cron` and Postgres-native queue options. Those are
the likely hosted-Supabase paths unless `pg_durable` becomes a supported native
extension.

## Decision Gates

Move from evaluation to implementation only if all of these are true:

1. A real Rye workload needs more than a scheduled single SQL call.
2. The target deployment can run PostgreSQL 17 or 18 and preload the extension.
3. The extension's preview maturity is acceptable for that workload.
4. The workload has explicit idempotency and provenance contracts.
5. The role and connection model passes Rye security tests.
6. The adapter remains optional and does not change Rye Core's PostgreSQL 15
   baseline.
7. Operational measurements justify the added worker, schemas, connections,
   upgrade path, and monitoring surface.

## Open Questions

- Which concrete workload first exceeds what `pg_cron` can provide?
- Should workflow correlation live in event properties, a supporting table, or
  both?
- How should an adapter avoid duplicate starts after a caller transaction
  rolls back?
- What request-key contract should Rye expose for retryable event-producing
  functions?
- Is per-agent PostgreSQL role isolation practical, or should only a trusted
  service role submit workflows?
- What terminal execution history must be copied into Rye before extension
  retention removes it?
- Which managed PostgreSQL targets can support the extension without a custom
  server image?

## Current Recommendation

Do not adopt `pg_durable` yet. Keep it as an optional execution-adapter
candidate and revisit it when a measured workload needs durable multi-step SQL
execution.

If that threshold is reached, start with scheduled materialized-view refresh.
Do not begin with agent-controlled workflows or governed transition
application.

## References

- [`pg_durable` repository and current status](https://github.com/microsoft/pg_durable)
- [`pg_durable` user guide](https://github.com/microsoft/pg_durable/blob/main/USER_GUIDE.md)
- [PostgreSQL background worker documentation](https://www.postgresql.org/docs/current/bgworker.html)
- [Supabase extension catalog](https://supabase.com/docs/guides/database/extensions)
- [Rye PR #3: Complete governed agent knowledge flow](https://github.com/BLTGV/project-rye/pull/3)
