# Rye — Core Contract and Conformance Kit

## Normative Contract, Implementation Checklist, and Test Matrix

---

## 1. Purpose

This document defines:

1. The **Core Contract** that should stay stable across versions.
2. A practical **implementation checklist** for shipping Rye safely.
3. A **conformance test matrix** so adopters can verify behavior in their environment.

The goal is to keep Rye opinionated and agent-friendly while remaining extensible for unknown domains.

---

## 2. Layer Model

Rye should be implemented as three layers:

1. **Stable Core (normative):** shared guarantees every adopter can rely on.
2. **Extensible Conventions (profiles):** CRM/PM/domain-specific semantics that can vary.
3. **Agent-Safe Interface:** constrained write paths, auditable operations, and consistent security semantics.

---

## 3. Core Contract (Normative)

### 3.1 Core Objects (MUST)

- `nodes`, `edges`, `events`, `event_participants`, `assertions`, `artifacts` exist.
- `current_assertions` exists and returns only non-superseded assertions.
- `assertions` support supersession (`superseded_at`, `superseded_by`) and preserve history.
- Soft-delete semantics are explicit (`archived_at`) where applicable.

### 3.2 Core Behavior (MUST)

- Assertions are append-only in content: replacement is via supersession, not in-place mutation.
- Events are immutable once written (except metadata fields if explicitly documented).
- Entity and relationship typing is convention-driven (`node_type`, `edge_type`, etc.), not hardcoded by schema branching.
- Provenance is preserved for agent and human operations (actor/session/event traceability).

### 3.3 Extensibility (MUST)

- Unknown `node_type` and `edge_type` values are supported without migrations.
- Domain table integration occurs through `node_source_map` (or equivalent mapping mechanism), not tight coupling.
- Domain profiles can add conventions without breaking core contract behavior.

### 3.4 Security Model (MUST)

- One authorization model is used consistently (session context + RLS recommended).
- Security policy behavior is deterministic and testable by role/team/user context.
- Field redaction behavior is deterministic and documented.
- Agent permissions are explicit (read-only, constrained write, privileged/admin-assist).

### 3.5 Agent Interface (SHOULD)

- Stable function surface for writes (for example: create, advance, supersede, merge flows).
- Explicit forbidden operations for agents (for example: destructive deletes, unmanaged direct updates).
- Human-approval boundaries for high-risk operations.

---

## 4. Implementation Checklist

Use this checklist before releasing a Rye version.

### 4.1 Spec and Versioning

- [ ] Core contract is versioned (for example `v1`, `v1.1`) and changelog is published.
- [ ] Every documented SQL example is syntactically valid for supported PostgreSQL versions.
- [ ] Core vs profile-specific behavior is clearly labeled.

### 4.2 Schema and Functions

- [ ] Fresh install path succeeds end-to-end.
- [ ] Upgrade path from previous version is documented and tested.
- [ ] Core functions are stable and documented with inputs, outputs, and side effects.
- [ ] Invariants are enforced by constraints/triggers/functions, not only narrative docs.

### 4.3 Security and Governance

- [ ] RLS scope is complete for all protected tables.
- [ ] Write policies align with function behavior (no accidental bypasses).
- [ ] Redacted views/functions are available for sensitive JSONB fields.
- [ ] Audit/provenance requirements are met for all write operations.

### 4.4 Agent Operations

- [ ] Agent write paths are constrained to approved functions.
- [ ] High-risk actions require explicit human approval.
- [ ] Denied operations produce clear, actionable errors.
- [ ] Agent operations are logged and attributable.

### 4.5 Performance and Operability

- [ ] Baseline indexes are in place and justified.
- [ ] Query plan and p95/p99 latency baselines exist for core queries.
- [ ] Materialized views are optional and justified by measured query pressure.
- [ ] Monitoring dashboard includes schema growth, query latency, and policy overhead.

### 4.6 Documentation and Adoption

- [ ] Conventions catalog exists (type definitions, required claim keys, semantics).
- [ ] Minimum quickstart path exists for self-hosted adopters.
- [ ] Conformance test kit is executable in CI.
- [ ] Backward compatibility and deprecation policy are documented.

---

## 5. Conformance Test Matrix

Legend:

- **P0**: required to claim "Rye Core Conformant"
- **P1**: strongly recommended for production readiness
- **P2**: optional/advanced

| ID | Category | Priority | What to validate | Method | Pass Criteria | Covered By |
|---|---|---|---|---|---|---|
| SC-01 | Schema Install | P0 | Fresh schema install works | Run migrations on empty DB | All objects created without manual intervention | `docker-test.sh --reset` |
| SC-02 | Schema Reapply | P0 | Migration behavior is deterministic | Re-run migration sequence | Expected idempotent result or explicit versioned failure | `migrate.sh` (tracks applied) |
| SC-03 | Schema Upgrade | P0 | Forward upgrade works on realistic data | Apply `vN -> vN+1` on fixture DB | No data loss, invariants preserved | — |
| FN-01 | Function Contract | P0 | Core function signatures/behavior are stable | Unit tests per function | Inputs/outputs and side effects match spec | `verify.sh`, S5 (merge_nodes) |
| FN-02 | Supersession | P0 | Assertion supersession behavior | Insert + supersede sequence test | Exactly one active assertion per subject/type per flow | `02_supersession`, S7 (concurrent) |
| FN-03 | Provenance | P0 | Writes retain actor/source traceability | Integration tests | All writes produce required provenance fields | S5 (merge provenance) |
| IV-01 | Integrity | P0 | No orphan references | FK/integrity checks after test flows | No broken refs in core tables | FK constraints + S5 |
| IV-02 | History Safety | P0 | Historical assertions remain queryable | Point-in-time query tests | Prior assertions preserved and reconstructable | S5 (superseded assertions) |
| EX-01 | Type Extensibility | P0 | New `node_type`/`edge_type` works without migration | Insert/query unknown types | CRUD + traversal works for new types | `01_core_contract` |
| EX-02 | Domain Overlay | P1 | Integration with external domain tables | `node_source_map` + join tests | Stable joins and deterministic mapping behavior | — |
| EX-03 | Profile Isolation | P1 | CRM/PM profile does not break core | Enable/disable profile tests | Core behavior unchanged without profile tables/views | — |
| SE-01 | Read Security | P0 | RLS read matrix by role/team/user | Table-driven security tests | Allowed reads succeed; disallowed reads blocked | S1-S4, R1-R4 |
| SE-02 | Write Security | P0 | Authorized writes only | Role-based mutation tests | Unauthorized writes blocked consistently | S1 (agent), S3, R6, R8-R9 |
| SE-03 | Redaction | P0 | Field-level redaction behavior | Query redacted views across roles | Sensitive fields hidden per policy | S1 (nodes_secure), S4 |
| SE-04 | Policy Consistency | P1 | No policy bypasses via alternate path | Direct DML + function path tests | Equivalent enforcement across paths | `01_assertion_policies`, R8 |
| AG-01 | Agent Read Ops | P0 | Agent can fetch minimal context safely | Scenario tests with agent role | Returns scoped, redacted, relevant context | S1 (agent:crm-sync), S2 (agent:pm-bot) |
| AG-02 | Agent Write Ops | P0 | Agent can perform allowed writes only | Scenario tests via approved functions | Allowed writes succeed, forbidden writes fail | S1, S2, R6, R9 |
| AG-03 | Human Approval Gate | P1 | High-risk actions are gated | Simulated approval workflow tests | Action blocked without approval, succeeds with approval | — |
| AG-04 | Agent Auditability | P1 | Agent actions are fully auditable | Event/provenance log verification | Actor, time, and target references complete | S5 (log_agent_query) |
| QY-01 | Query Contracts | P0 | Core query outputs are deterministic | Snapshot tests for core views/functions | Stable schemas and deterministic row semantics | S1-S4 (exact counts) |
| QY-02 | Profile Queries | P1 | CRM/PM views return one-row-per-entity when promised | Fixture tests for fan-out cases | No duplicate entity rows unless documented | — |
| CC-01 | Code Generation | P0 | Human-readable codes under concurrency | Parallel insert tests | No duplicates; sequence semantics preserved | `01_code_generation.sh` |
| CC-02 | Local Sequence | P1 | Project-local sequence behavior | Parallel task create tests | No collisions; monotonic per project | — |
| OP-01 | Observability | P1 | Core metrics emitted | Smoke tests against monitoring queries | Metrics available for size/latency/errors | — |
| OP-02 | Performance Baseline | P1 | Baseline latency and explain plans | Benchmark fixture + plan checks | Meets documented baseline thresholds | — |
| OP-03 | Scale Guardrails | P2 | Degradation behavior past baseline | Stress tests | Clear breakpoints and mitigations documented | — |
| BC-01 | Backward Compatibility | P0 | Previous client workflows still function | Compatibility suite across versions | No breaking change without version bump + migration notes | — |
| BC-02 | Deprecation Policy | P1 | Deprecated features remain operable through grace period | Contract tests on deprecated paths | Behavior + warnings match policy | — |

### Coverage Legend

- **S1-S6**: Scenario tests (`tests/scenarios/01-06_*.sql`)
- **R1-R10**: Recommendation tests within `06_recommendations.sql`
- **S7**: Concurrent supersession test (`07_concurrent_supersession.sh`)
- **`01_*`, `02_*`, `03_*`**: Conformance/security/concurrency tests
- **—**: Not yet covered by automated tests

---

## 6. Release Gates

### Gate A — Core Conformant

Required: all **P0** tests pass.

### Gate B — Production Ready

Required: all **P0** and **P1** tests pass, plus operational runbook available.

### Gate C — Scale Ready

Required: P0/P1 pass and relevant **P2** scale tests completed for target workload.

---

## 7. Suggested Repo Structure for Adoption

```
/schema
  /core
  /profiles
  /migrations
/tests
  /conformance
  /security
  /concurrency
  /performance
/docs
  core-contract.md
  conventions-catalog.md
  agent-ops-guide.md
```

This separation helps teams reuse the core while customizing profiles and domain integrations safely.

