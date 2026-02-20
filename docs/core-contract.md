# Rye Core Contract (Implemented)

This implementation targets PostgreSQL 15+ and enforces the core Rye contract via schema, triggers, functions, and tests.

## Core Guarantees

- Stable core objects: `nodes`, `edges`, `events`, `event_participants`, `assertions`, `artifacts`
- Assertions are immutable in content and superseded via `supersede_assertion(...)`
- Direct `UPDATE` on `assertions` is blocked by RLS; supersession is function-mediated
- One active assertion per `(subject_ref, assertion_type, assertion_key)`
- Unknown `node_type` / `edge_type` values work without migration
- Session-context + RLS security model
- Agent-facing summary and logging functions: `agent_node_summary`, `log_agent_query`
- Agent node updates via write-path gated `update_node_properties()` (direct UPDATE blocked)

## Key Implementation Choices

- PostgreSQL 15+ only
- Direct assertion inserts are allowed (subject to RLS)
- Direct assertion updates are denied; use `supersede_assertion(...)`
- Multi-valued facts use domain keys in `assertion_key`
- Single-valued facts use `assertion_key = 'default'`
- All views use `security_invoker = true` to enforce RLS through views
- Nodes with teams must have `classification` set (enforced by trigger)
- Event creation uses pre-generated UUIDs via `record_event()`, never `INSERT ... RETURNING id`

## Release Gates

Use `./scripts/conformance.sh` as gate enforcement in CI.

Implementation note: when the test connection user is a PostgreSQL superuser, the conformance harness executes suites under a non-superuser role (`rye_conformance` by default, configurable with `RYE_TEST_ROLE`) so RLS assertions are meaningful.
