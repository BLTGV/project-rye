# Agent-Driven Autonomy

Status: proposed design direction

## Objective

Rye should let agents consume and populate organizational knowledge with as
little recurring human coordination as the active policy safely allows.

Humans define purpose, authority, boundaries, and exception policy. Agents act
inside that envelope. New, sensitive, contradictory, or out-of-policy cases go
to review. Repeated review outcomes can propose a narrower or broader autonomy
rule, but an agent cannot activate its own authority.

The target experience is:

- simple to deploy beside an existing PostgreSQL application
- natural to use through chat, connectors, domain applications, or an admin UI
- flexible to modify through conventions, plugins, and temporal policy records
- simple to consume through SQL helpers, a secure API, MCP tools, and change
  feeds

Rye core remains SQL. The secure agent gateway and admin UI remain optional
surfaces over that database contract.

## Operating Principle

Review is a bootstrap and exception path, not a permanent tax on every agent
interpretation.

The operating rule is:

> Humans approve the autonomy policy. Agents act within it. Exceptions return
> for judgment.

This produces four autonomy modes.

| Mode | Meaning | Default handling |
|---|---|---|
| Observe | Preserve relevant source material or activity | Automatic, with provenance and retention policy |
| Direct | An authorized user explicitly requests a scoped action | Execute once; do not ask the same person to approve it again |
| Policy-driven | A familiar interpretation matches an active autonomy rule | Promote automatically and record the decision trace |
| Exception | The case is novel, sensitive, contradictory, low-confidence, or out of scope | Create a candidate, dispute, or denial record for review |

## Design Principles

1. **Authority is data.** Prompts do not grant authority. Domain, source,
   capability, speech act, classification, and effective-time policy do.
2. **Semantic interpretation remains reviewable.** An LLM-derived
   interpretation normally creates a candidate even when policy immediately
   allows promotion. The candidate preserves the reasoning and evidence path.
3. **Deterministic authoritative updates may take a shorter path.** A structured
   source covered by an active source-of-truth policy may record an assertion
   directly, but it still records the policy decision and source event.
4. **Explicit instructions are not approved twice.** The system records the
   authenticated instruction and verifies the speaker's authority before
   executing it.
5. **Exceptions teach; they do not silently expand authority.** Repeated review
   outcomes can create an autonomy-rule candidate. A trusted administrator must
   activate that rule.
6. **Decisions are temporal.** Authority, policy, classification, and source
   status are evaluated at the requested effective time.
7. **Core tables stay domain-neutral.** Domain membership and policy use
   supporting tables and assertions, not new columns on the six core tables.

## Target Interaction Path

```text
source or user request
        |
        v
observation + evidence
        |
        v
candidate or deterministic update
        |
        v
promotion policy evaluator
    |          |          |
  allow      review      deny
    |          |          |
    v          v          v
promotion   exception   audit + reason
    |        queue
    v          |
temporal       +--> repeated outcome --> autonomy-rule candidate
knowledge                                  |
                                             +--> admin activation
```

## Existing Foundations

Rye already has most of the primitives required for this direction.

| Existing primitive | Contribution |
|---|---|
| `knowledge_domains` | Names a bounded business knowledge area |
| `domain_authorities` | Records people, systems, teams, roles, and sources with claim authority |
| `domain_claim_policies` | Records claim-specific candidate and authority expectations |
| `agent_identities` and `agent_capability_grants` | Limit which verbs an external agent may attempt |
| `agent_action_log` | Audits allowed and denied external-agent actions |
| `agent_get_context_pack()` | Returns subscribed domains, authorities, policies, and open candidates |
| `agent_submit_observation()` | Preserves raw observed source material without treating it as accepted knowledge |
| `agent_create_candidate()` | Creates a scoped candidate with evidence and idempotency metadata |
| Candidate promotion helpers | Promote candidates to assertions, tasks, and edges with provenance |
| `record_assertion()` and as-of reads | Preserve current, historical, and future-effective knowledge |
| Assertion dispute helpers | Preserve contradictory claims until a reviewer resolves them |

The missing contract is a single policy decision that combines those inputs
before an accepted write.

## First-Class Domain Membership

External-agent reads and policy evaluation require a durable answer to:

> Which knowledge domains contain this node?

Candidate JSON currently carries `domain_keys`, but ordinary nodes and promoted
knowledge do not have a normalized membership contract. Add a supporting table:

```sql
CREATE TABLE rye.node_domain_memberships (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id         uuid NOT NULL REFERENCES rye.nodes(id),
    domain_id       uuid NOT NULL REFERENCES rye.knowledge_domains(id),
    scope_ref       text,
    membership_kind text NOT NULL DEFAULT 'primary',
    effective_at    timestamptz NOT NULL DEFAULT now(),
    effective_to    timestamptz,
    source_event_id uuid REFERENCES rye.events(id),
    properties      jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    CHECK (membership_kind IN ('primary', 'shared', 'derived', 'temporary')),
    CHECK (effective_to IS NULL OR effective_to > effective_at)
);
```

Membership rules:

- Assertions inherit the domains of their subject node.
- Edges are visible only when the caller can see both endpoints.
- Events inherit visibility from their participants.
- Artifacts inherit from their source and related nodes.
- Candidate creation writes membership for the candidate node.
- Promotion verifies that the target belongs to the requested domains.
- Cross-domain sharing requires an explicit `shared` membership.
- Labels, channel names, and connector metadata never create membership by
  themselves.

Backfill candidate membership from `target_payload.domain_keys`. Leave other
unclassified nodes in an admin worklist rather than inferring their domain.

## Promotion Policy Decisions

Add an append-only decision table:

```sql
CREATE TABLE rye.promotion_decisions (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    candidate_id       uuid REFERENCES rye.nodes(id),
    agent_id           uuid REFERENCES rye.agent_identities(id),
    decision           text NOT NULL,
    reason_codes       text[] NOT NULL DEFAULT '{}',
    matched_policy_ids uuid[] NOT NULL DEFAULT '{}',
    missing_conditions jsonb NOT NULL DEFAULT '[]',
    request             jsonb NOT NULL,
    policy_snapshot     jsonb NOT NULL,
    decided_at          timestamptz NOT NULL DEFAULT now(),
    effective_at        timestamptz NOT NULL DEFAULT now(),
    expires_at          timestamptz,
    CHECK (decision IN ('allow', 'review', 'deny'))
);
```

Add a stable evaluator:

```text
evaluate_candidate_promotion(
    agent_id,
    candidate_id,
    target_payload,
    at_time
) -> {
    decision,
    reason_codes,
    matched_policy_ids,
    missing_conditions,
    decision_id
}
```

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

Default outcomes:

- missing scope or ungranted domain: `deny`
- known domain with incomplete authority or evidence: `review`
- contradiction: `review` through the dispute path
- complete narrow policy match: `allow`

Policy evaluation and promotion must happen in one transaction. The promotion
event and accepted record store the decision id, policy snapshot, matched
conditions, actor, and evidence references.

Policy authoring records must themselves be temporal. Either add effective and
supersession fields to compiled policy tables or compile those tables from
temporal policy assertions. Do not overwrite policy history.

## Explicit User Authority

Add a helper that records an authenticated instruction before execution:

```text
record_agent_instruction(
    user_id,
    agent_id,
    domain_keys,
    target_ref,
    requested_action,
    requested_effective_at,
    instruction_digest,
    idempotency_key
) -> event_id
```

The instruction can satisfy the authority condition when the user has the
required domain role. The evaluator still returns `review` or `deny` when the
target is ambiguous, the user lacks authority, the action crosses scope, or the
request conflicts with active policy.

## Atomic And Idempotent Promotion

Candidate creation already supports idempotency. Promotion needs the same
protection.

```sql
CREATE TABLE rye.candidate_promotions (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    candidate_id       uuid NOT NULL REFERENCES rye.nodes(id),
    promotion_key      text NOT NULL,
    target_type        text NOT NULL,
    target_id          uuid NOT NULL,
    policy_decision_id uuid REFERENCES rye.promotion_decisions(id),
    created_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (candidate_id, promotion_key)
);
```

Promotion rules:

- accept an idempotency key at the API boundary
- lock the candidate during evaluation and promotion
- reject accidental promotion of accepted, rejected, duplicate, or superseded
  candidates
- require an explicit multi-target policy when one candidate legitimately
  produces more than one accepted result
- record candidate status, promotion target, policy decision, and promotion
  event atomically

## Administrative And Agent API Separation

Separate the current API into two data planes.

### Administrative API

- route prefix: `/api/admin/v1`
- human authentication through Cloudflare Access, OAuth, or another verified
  admin identity
- may use the Rye admin database context
- does not accept possession of a Rye agent token as administrative authority

### Agent API

- route prefix: `/api/agent/v1`
- Rye agent token required
- every route maps to a capability
- every read and write is constrained by domain membership and scope
- uses narrow SQL helpers instead of general admin queries

Until domain-safe agent reads exist, agent tokens must receive `403` from
administrative node, graph, event, dispute, dashboard, and workspace routes.

## Direct Database And CLI Access

The secure API is not the only supported agent path. Many coding agents,
database agents, and local operators will have a PostgreSQL connection and
should not need an HTTP service to use Rye.

Support three explicit access modes.

| Mode | Intended caller | Enforcement |
|---|---|---|
| Trusted SQL | Operator-controlled local agent with trusted database credentials | Session context, Rye helper conventions, and audit; the agent is inside the trusted boundary |
| Scoped DB | Agent with a restricted database credential and Rye token | Database privileges plus token-authenticated Rye functions; no direct core-table access |
| Secure API/MCP | External or untrusted runtime | Bearer token, API capability checks, domain-safe functions, and payload limits |

### Trusted SQL mode

A trusted direct-database agent may query security-invoker views and call Rye
helpers directly. It must:

- set Rye session context in every stateless call
- use `current_valid_assertions` for current accepted knowledge
- use lifecycle helpers for assertions, events, candidates, disputes, and
  scheduling
- record agent reads and writes with an attributable actor
- treat raw table mutation outside the helper contract as an administrative
  action

This mode is convenient, not an enforceable sandbox. An agent with an owner or
administrative database credential can bypass a CLI and cannot be constrained
by prompt instructions. Deployments must classify that agent as trusted.

### Scoped DB mode

Scoped direct access needs an enforceable database boundary. Create one
technical transport role, for example `rye_agent_runtime`, with:

- `CONNECT` to the database
- `USAGE` on the `rye` schema
- `EXECUTE` only on the approved token-authenticated `agent_*` functions
- no direct `SELECT`, `INSERT`, `UPDATE`, or `DELETE` grants on Rye core or
  supporting tables
- no execution rights on administrative helpers

The transport role is not a business authorization model. Rye must not use
`current_user`, `pg_has_role()`, or database-role membership to decide domain
authority. Its purpose is only to prevent a direct-database caller from
bypassing the token-authenticated function surface. Business authorization
continues to use Rye identities, capabilities, domains, authorities, scopes,
and policy decisions.

Token-authenticated functions should not trust caller-set session variables as
proof of identity. A custom PostgreSQL setting can be set by the caller. Use one
of these patterns:

1. Authenticate the Rye agent token inside each parameterized function call.
2. Open a short-lived database-agent session through a `SECURITY DEFINER`
   function, bind it to the active backend and an unguessable nonce, and require
   that session in every subsequent helper call.

For transaction-mode poolers and CLI commands, the first pattern is simpler.
For a long-lived dedicated connection, the second can avoid repeated token
verification. Both patterns must avoid placing plaintext tokens in generated
SQL strings, logs, or error messages.

### Rye CLI

Provide a rigid CLI over the same database functions used by the API and MCP.
The CLI does not reimplement policy locally.

Suggested commands:

```text
./scripts/rye agent context --domain account-updates --json
./scripts/rye agent search --query Acme --domain account-updates --json
./scripts/rye agent summary --node <uuid> --json
./scripts/rye agent observe --input observation.json --idempotency-key <key>
./scripts/rye agent propose --input candidate.json --idempotency-key <key>
./scripts/rye agent evaluate --candidate <uuid> --json
./scripts/rye agent promote --candidate <uuid> --input target.json --idempotency-key <key>
./scripts/rye agent changes --cursor <cursor> --json
```

CLI requirements:

- use parameterized database calls rather than interpolated SQL
- accept connection and Rye token values through environment variables or
  secure input, not command-line arguments that appear in process listings
- return stable JSON envelopes and meaningful nonzero exit codes
- include policy reason codes for allow, review, and deny outcomes
- support `--dry-run` for evaluation and policy simulation
- make every write idempotent
- perform token authentication, authorization, lifecycle write, and audit in
  one database transaction where possible
- expose the same semantic operation names as the API and MCP

The API, MCP, CLI, and trusted SQL guidance all converge on the same database
helpers. A behavior change belongs in that shared SQL contract, not in four
different wrappers.

## Safe CDC

CDC currently preserves complete old and new row JSON. Add tracked-table
configuration:

```sql
CREATE TABLE rye.tracked_table_config (
    source_schema      text NOT NULL,
    source_table       text NOT NULL,
    payload_mode       text NOT NULL DEFAULT 'changed_fields',
    included_columns   text[],
    excluded_columns   text[] NOT NULL DEFAULT '{}',
    classified_columns jsonb NOT NULL DEFAULT '{}',
    max_value_bytes    integer NOT NULL DEFAULT 8192,
    retention_class    text,
    PRIMARY KEY (source_schema, source_table),
    CHECK (payload_mode IN ('keys_only', 'changed_fields', 'full_snapshot'))
);
```

Defaults:

- store changed fields instead of full rows
- exclude credentials, secrets, tokens, and large binary or text columns
- redact classified values before writing the event
- store hashes or changed markers when the value is not needed
- use a restricted artifact for a full replay snapshot only when policy requires
  it

Field redaction must apply to event and artifact payloads, not only node JSONB.

## Secure Consumption Surface

The secure MCP and agent API should expose a complete bounded workflow.

Read tools:

- `rye.search_nodes`
- `rye.get_node_summary`
- `rye.get_node_knowledge`
- `rye.get_changes`
- `rye.get_assertions_as_of`
- `rye.get_open_disputes`

Write tools:

- `rye.submit_observation`
- `rye.propose_candidate`

Policy and review tools, registered only with the matching capability:

- `rye.evaluate_candidate`
- `rye.set_candidate_status`
- `rye.promote_candidate`
- `rye.accept_source_policy`
- `rye.accept_scheduled_change`

Every response separates:

- accepted current knowledge
- current plans
- pending candidates
- evidence and provenance
- historical or future-effective knowledge
- freshness metadata

External runtimes never receive raw SQL access through this surface.

## Incremental Consumption

Add a cursor-based helper over immutable events:

```text
agent_changes_since(
    agent_id,
    cursor,
    domain_keys,
    event_types,
    limit
) -> { changes, next_cursor }
```

Use stable `(recorded_at, id)` ordering. Enforce domain visibility, return
affected node ids and compact summaries, and support replay after a consumer
disconnects. Optional notifications, queues, or webhooks can wake consumers,
but the event cursor remains the durable contract.

## Simple Deployment And Operation

Offer two explicit footprints.

1. **Rye Core**
   - PostgreSQL schema, migrations, verification, and conformance
   - trusted local SQL helpers
   - no required runtime, ORM, or framework
2. **Rye Agent Gateway**
   - optional secure API and MCP deployment
   - agent identity, capability, domain, and promotion-policy enforcement
   - deployable and replaceable independently of Rye Core

Extend `scripts/rye doctor` to report:

- PostgreSQL and extension compatibility
- migration and profile status
- RLS configuration
- unsafe agent-accessible administrative routes
- nodes without domain membership
- source confirmations and candidate backlog
- policy compilation failures
- CDC tables using unsafe payload modes
- active disputes
- materialized-view freshness

## Simple Modification

Most changes should use existing extension points:

- open node, edge, assertion, event, and artifact type conventions
- JSONB properties for domain data
- scope conventions for local vocabulary
- temporal authority and autonomy policy
- plugins for reusable domain behavior
- profiles for optional read models and helpers

Add a policy simulator that evaluates a proposed autonomy rule against prior
reviewed candidates without activating the rule. Report how many prior cases
would have been allowed, reviewed, or denied, including historical reviewer
disagreements and classifications affected.

The exception UI should offer two distinct actions:

- approve this case
- propose a rule for similar cases

The second action creates a policy candidate. It does not immediately expand
agent authority.

## Freshness

Profile materialized views need explicit freshness state:

```text
profile_read_model_state(
    profile_key,
    last_refreshed_at,
    latest_source_change_at,
    stale,
    acceptable_staleness
)
```

API and agent responses that use a materialized read model include this
metadata. Small installations may prefer security-invoker views. Larger
installations can use an optional refresher driven by the event feed.

## Conformance Requirements

Add tests for:

- no cross-domain discovery through search, graph, events, totals, errors, or
  timing-visible response differences
- agent tokens rejected from administrative routes
- scoped database credentials unable to read or mutate Rye tables directly
- trusted SQL and scoped DB modes documented and distinguishable in diagnostics
- CLI commands producing the same allow, review, deny, and result envelopes as
  the API and MCP
- tokens absent from SQL logs, process listings, audit request payloads, and
  errors
- policy decisions for allow, review, and deny
- temporal authority and policy evaluation
- explicit user instruction without duplicate approval
- atomic retry-safe promotion
- competing concurrent promotion attempts
- candidate status transition restrictions
- sensitive CDC fields absent from lower-privilege event and artifact reads
- secure MCP tool registration by capability
- context and knowledge reads bounded by domain and scope
- cursor replay without missed or duplicate events
- materialized-view freshness surfaced to consumers

## Delivery Sequence

1. Close administrative routes to agent tokens.
2. Define trusted SQL, scoped DB, and secure API/MCP access modes.
3. Add the restricted direct-database transport role and token-authenticated
   agent function surface.
4. Add domain membership and domain-safe read helpers.
5. Make CDC redaction safe by default.
6. Add promotion decision and promotion idempotency records.
7. Implement atomic policy evaluation and promotion.
8. Add explicit-user-authority handling.
9. Add the rigid Rye agent CLI over the shared SQL helpers.
10. Complete secure MCP reads and review tools.
11. Add cursor-based change consumption.
12. Add policy simulation and exception grouping.
13. Add freshness, health reporting, and updated documentation.

## Success Measures

Measure:

- the share of routine work completed automatically
- the reason every automatic action was allowed
- automatic decisions later reversed
- exceptions converted into reviewed policy proposals
- accepted assertions with complete evidence, authority, and policy provenance
- attempts to access or modify knowledge outside an agent's domain
- time from installation to the first useful agent workflow

The desired result is not maximum autonomy. It is the highest useful autonomy
that remains bounded, inspectable, temporal, and simple to change.
