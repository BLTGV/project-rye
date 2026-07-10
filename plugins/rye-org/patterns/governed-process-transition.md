# Pattern: Governed Process Transition

## Purpose

Represent a stateful business process whose transitions depend on temporal
authority, evidence, and explicit policy. Use it when an agent observes state
changes in conversation or documents and no operational application owns the
workflow.

## Non-Goals

- Treating conversation as accepted state.
- Adding a domain-specific process table to Rye Core.
- Inferring authority from job titles, channel membership, frequency, or tone.
- Proving that an offline prerequisite did not happen merely because evidence
  is missing.

## Node Contracts

The stable process subject is a `pipeline`, `procedure`, or plugin-owned process
node. The item moving through it is a domain node such as an `opportunity` or
`project`.

Role nodes use `node_type = 'role'`. A confirmed temporal `holds_role` edge
connects a person to a role. Edge effective bounds determine whether the role
was active at the candidate's requested effective time.

## Assertion Contracts

| `assertion_type` | Subject | Key rule | Claim schema | Supersession |
|---|---|---|---|---|
| `process_definition` | stable process node | `default` | `../schemas/process_definition_claim.schema.json` | Supersede when states or their meaning change. |
| `process_transition_policy` | stable process node | `transition:<transition_key>` | `../schemas/process_transition_policy_claim.schema.json` | Supersede the same transition key when requirements change. |
| `observed_process_transition` | stable process node | `observed:<from_state>:<to_state>:<window_start>` | `../schemas/observed_process_transition_claim.schema.json` | Append per window; never superseded by authoritative claims. |
| domain state, such as `deal_stage` | item moving through the process | `default` | domain-owned | Change only after the transition decision allows promotion. |

Process and transition assertions use their effective windows. Evaluators must
read the versions effective at the requested business time and retain those
assertion IDs in the decision snapshot.

### Observed versus authoritative stance

`process_definition` and `process_transition_policy` are authoritative: they
bind the promotion evaluator and require `policy_set` authority to change.
`observed_process_transition` is descriptive: it records that behavior
occurred, with evidence, and never binds the evaluator. The two stances share
`process_key` and state vocabulary so divergence between them is a mechanical
comparison. Observation may accumulate before any authoritative process
exists, authoritative process may be fed before any observation exists, and
neither lineage writes to the other. Discovery tooling may draft authoritative
candidates from the observed lineage; activation still requires `policy_set`
authority.

## Authority Contract

Authority resolution is:

```text
confirmed source identity
→ person
→ active holds_role edge
→ active domain_authorities row
→ permitted claim type, scope, and speech act
```

Use responsibility-specific speech acts rather than a numeric hierarchy:

- `suggested` or `reported`: evidence only
- `proposed`: may create a candidate
- `approved` or `decided`: may satisfy transition decision authority
- `policy_set`: may supersede process policy

An actor allowed to propose but not decide produces `review`. Equal decision
authorities that conflict use the dispute path.

## Event Contracts

| `event_type` | Purpose | Participant roles | Required properties |
|---|---|---|---|
| `process_transition_evaluated` | Preserve an allow, review, or deny decision. | `subject`, `candidate`, `process` | prior state, proposed state, decision, reason codes, policy assertion IDs |
| `process_exception_approved` | Record an explicit override of a reviewable process constraint. | `subject`, `process`, `approver` | transition key, reason, missing conditions, decision reference |

Always create these with `record_event()`.

## Example

Process definition claim:

```json
{
  "schema_type": "rye.process_definition.claim.v1",
  "schema_version": 1,
  "process_key": "standard-sales",
  "state_assertion_type": "deal_stage",
  "states": ["discovery", "proposal", "negotiation", "closed_won", "closed_lost"],
  "initial_state": "discovery",
  "terminal_states": ["closed_won", "closed_lost"]
}
```

Transition policy claim:

```json
{
  "schema_type": "rye.process_transition_policy.claim.v1",
  "schema_version": 1,
  "process_key": "standard-sales",
  "transition_key": "proposal-to-closed-lost",
  "from_states": ["proposal", "negotiation"],
  "to_state": "closed_lost",
  "authority": {
    "may_propose": ["role:salesperson"],
    "may_decide": ["role:sales_manager"],
    "may_approve_exception": ["role:sales_director"],
    "may_reopen": ["role:sales_manager"]
  },
  "required_evidence": ["loss_reason"],
  "required_prior_steps": [],
  "exception_policy": "review",
  "impact": "high",
  "reversible": true
}
```

If a salesperson says a proposal is dead, preserve a `closed_lost` candidate.
Do not change the active `deal_stage` until the process and temporal authority
requirements match.

## Read And Compliance Rules

- Accepted state comes only from the current domain-state assertion.
- Candidate state remains separately visible.
- Decision compliance uses the process snapshot retained at decision time.
- Operational compliance distinguishes `missing_evidence` from
  `noncompliant`.
- Applying today's process to an old transition is a labeled retrospective
  analysis.

## Tests

- valid process and transition claims satisfy their schemas
- a missing transition key is rejected
- a proposer without decision authority returns review in the future evaluator
- policy supersession retains the prior policy reference on old decisions
- missing evidence is not classified as proven noncompliance
