# Domain Onboarding Checklist

## Design

- [ ] New node/edge/assertion/event types listed
- [ ] Required properties documented
- [ ] `assertion_key` rule per assertion type defined

## Implementation

- [ ] New profile migration file added
- [ ] Functions compile on PostgreSQL 15+
- [ ] Assertion supersession uses `supersede_assertion(...)`, not direct `UPDATE assertions`
- [ ] Materialized view indexes included when needed

## Tests

- [ ] Conformance tests for domain invariants
- [ ] Security tests for role-gated facts
- [ ] Concurrency tests if codes/sequences are added

## Release

- [ ] `./scripts/install.sh` passes
- [ ] `./scripts/conformance.sh` passes
- [ ] Docs updated in `docs/conventions-catalog.md`
