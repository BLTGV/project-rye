# Rye — Agent Access and Promotion

Status: proposed design direction

## Scope

This document defines two related contracts:

1. how trusted and scoped agents enter Rye
2. how an agent interpretation becomes accepted knowledge

It also defines how temporal authority and process knowledge constrain that
promotion decision. A conversation is evidence about operational state and
governance state; it is not accepted state by itself.

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
inputs to the same `allow` / `review` / `deny` decision. For state transitions,
the accepted state, process version, prerequisites, and authority assignments
in effect at the requested time are inputs as well.

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

## Conversation And Governance Knowledge

Conversation sources such as Slack contain evidence, not an implicit system of
record. Model a Slack workspace as a `source_account`, a channel as a
`source_container`, and a relevant message or thread as a `source_item` reached
through a `retrieval_channel`.

For each relevant message preserve:

- stable workspace, channel, message, thread, and speaker references
- source occurrence, edit, retrieval, and business-effective times separately
- compact content or artifact references subject to classification and
  retention policy
- reply context and message lifecycle state
- extracted speech act, confidence, and date quality

The agent extracts operational candidates, such as a proposed deal-stage
change, separately from governance candidates, such as a procedure, authority,
delegation, or policy change. A channel name, job title, repeated behavior, or
confident wording never establishes authority by itself.

## Authority Resolution Contract

Authority resolution follows this path:

> authenticated source identity -> person -> temporal role or team membership
> -> active domain authority -> permitted claim type and speech act

Use stable Rye node references for person, team, and role authorities. Keep
external text references for systems and sources. The implementation must
define one canonical `authority_ref` representation and reject ambiguous or
unresolved references.

Role and team membership are temporal edges. Delegation is explicit and
temporal. Resolve both at the candidate's requested effective time, not only at
ingestion time.

Do not use a generic numeric hierarchy. Distinguish responsibility through
speech acts and claim scope:

- a salesperson may report or propose a `deal_stage` transition
- a sales manager may approve or decide it
- a process owner may set or supersede the transition policy

When two actors genuinely hold equal decision authority and disagree, preserve
a dispute. Do not silently choose the actor with the higher title.

Every deployment needs a small root of trust established during onboarding:
confirmed identity mappings, process owners, and authorities permitted to set
authority or process policy. Agents may propose changes to that root but may
not activate their own authority.

## Temporal Process Contract

Keep the process convention-driven. Do not add domain-specific columns or a
deal-state table to Rye Core.

A stable `pipeline` or other process node identifies the process. Temporal
assertions describe its behavior:

- `process_definition` records states, initial state, and terminal states
- `process_transition_policy` records one transition and its requirements

Use stable assertion keys. A transition key should include the process,
normalized source state set, and target state. Supersede process assertions
when the process changes so an as-of query can reconstruct the rules that
applied to an earlier decision.

A `process_transition_policy` claim contains:

- process key, allowed source states, and target state
- roles or authorities that may propose, approve, decide, or reopen
- required evidence and prior steps
- whether an exception may be reviewed and who may approve it
- impact and reversibility metadata

For example, a salesperson may propose `proposal -> closed_lost`, while a sales
manager must decide it and provide a loss reason. Until those conditions match,
the accepted `deal_stage` does not change.

Conversation can suggest a new procedure or policy. Record it as a `procedure`
or `policy_change` candidate. Only an actor with applicable `policy_set`
authority can promote or supersede the active process definition.

## Observed And Authoritative Process

Process knowledge exists in two stances that must coexist without merging:

- **Observed** process describes how work actually flowed: which states
  occurred, which transitions happened, who initiated and who decided them.
  Source observations and events preserve the evidence. A derived observed
  assertion is descriptive knowledge and makes no claim about what is
  permitted.
- **Authoritative** process prescribes how work must flow. Only it binds the
  promotion evaluator. It is established by feeding structured sources such as
  an org chart or process document, or by activating a proposed rule, and in
  both cases only through an actor with applicable `policy_set` authority.

Both stances share a comparison vocabulary normalized to
`(process_key, from_state, to_state)`. They use stance-specific claim shapes,
assertion keys, and assertion types. Authoritative
`process_transition_policy` records transition requirements;
`observed_process_transition` records evidenced occurrences within a closed
window. The evaluator cannot bind to the observed lineage by construction.

Required properties:

1. **Order independence.** Observation may begin before any authoritative
   process exists, authoritative knowledge may be fed before any observation
   exists, and either may arrive later. Neither writes to the other's lineage.
2. **Observed knowledge accumulates under an unknown process.** Mined
   source observations and immutable events can accumulate before a process is
   known. A derived observed-process assertion follows the normal candidate and
   promotion contract: no matching policy returns `review`. A deterministic
   evidence projection may promote automatically only under an explicit active
   source or evidence policy. There is no second lenient default.
3. **Observed never becomes authoritative automatically.** Discovery emits
   authoritative-process candidates from the observed lineage. Activation
   requires `policy_set` authority. Drafts are presented as observed practice,
   not recommended governance.
4. **Fed knowledge is verifiable, not privileged.** An org chart or process
   document enters through the deterministic source-of-truth path with source
   provenance. Once active it is subject to the same divergence reporting as
   any other authoritative claim, so a stale org chart is detectable rather
   than silently trusted.
5. **Both lineages are temporal.** An as-of query reconstructs what behavior
   was believed and what the rules were at any past time, independently.

### Divergence

Divergence between the lineages is a derived read model, not an error state.
For a window and process, classify:

- observed transitions covered by active policy: routine
- observed transitions absent from active policy: unmodeled transitions —
  candidate noncompliance or evidence that the documented process is wrong
- policy transitions not observed during a window with known opportunities:
  unobserved policy transitions — possible process debt or training gaps
- observed deciders absent from active authority: authority divergence —
  candidate noncompliance or a stale org chart

A persistent divergence with acceptable outcomes is input for a
`policy_change` candidate. A divergence report never mutates either lineage
and never blocks operational writes by itself.

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
- confirmed source identity plus temporal role, team, and delegation resolution
- speech act such as confirmed, approved, decided, suggested, or inferred
- accepted subject state at the requested effective time
- active process definition and transition policy at that time
- transition prerequisites, required evidence, and exception policy
- source confirmation status
- evidence requirements
- business date quality and source occurrence versus retrieval time
- confidence policy
- classification and sensitivity
- impact and reversibility
- current, planned, future, or historical meaning
- conflicting active assertions
- policy effective dates

Default results:

- missing capability or ungranted domain: `deny`
- no applicable promotion policy: `review`
- unresolved identity or authority: `review`
- an actor permitted to propose but not decide: `review`
- missing process definition, transition rule, prerequisite, or evidence:
  `review`
- a transition explicitly marked non-overridable: `deny`
- incomplete authority or evidence: `review`
- contradiction: `review` through the dispute path
- complete active policy match: `allow`

Policy records are temporal. A decision retains the policy snapshot used at the
time so later policy changes do not rewrite why the action occurred.

For a state transition, the snapshot includes the accepted prior state,
process definition, transition policy, resolved authority path, prerequisite
results, evidence references, and date-quality basis.

## Compliance Contract

Keep decision compliance separate from operational compliance:

- **Decision compliance** asks whether Rye was permitted to accept the change.
- **Operational compliance** asks whether available evidence shows that the
  business completed the required steps.

Provide a derived view or function over promotion decisions with these results:

- `compliant`
- `approved_exception`
- `missing_evidence`
- `noncompliant`
- `not_evaluable`

Missing evidence is not proof of noncompliance. If Slack contains no legal
approval, Rye reports the missing support; it does not assert that legal review
never happened.

Compliance uses the policy snapshot effective when the decision occurred.
Applying today's process to an earlier decision is a separate retrospective
analysis and must be labeled as such. When authoritative process is fed after
observation has accumulated, the resulting backward-looking divergence report
is exactly this labeled retrospective analysis, not a compliance verdict.

Operational compliance additionally reports the divergence classes from
Observed And Authoritative Process: unmodeled transitions, unobserved policy
transitions, and authority divergence.

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

## Vocabulary Contract

Machine identifiers are canonical. Plain language is a presentation register
at the human boundary, not an alternate authorization or storage contract.

- Schema names, function names, API fields, categorical values, and reason
  codes use canonical internal identifiers.
- Durable records may contain human labels, statements, summaries, and reasons.
  That text is explanatory and never substitutes for the canonical code or
  structured value used to make a decision.
- When an agent addresses a non-technical person — chat, review requests,
  reports, or exception explanations — it renders internal concepts through
  one versioned lexicon and maps plain-language instructions back to canonical
  operations before calling CLI, API, MCP, or SQL helpers.
- A decision shown as "needs a decision: only a sales manager can decide this"
  retains its reason codes and policy snapshot. Where replay of the exact
  rendering matters, record the lexicon version alongside the rendered text.
- The repository owns the default lexicon. Agent-facing adapters use the same
  version; the database does not require every human sentence to come from it.
- Scopes may localize display terms through the existing convention registry.
  Internal identifiers and reason codes never localize.

Starter lexicon:

| Internal | Plain register |
|---|---|
| observation | something Rye noticed |
| source item | a record from a connected source |
| candidate | suggestion |
| promotion | acceptance |
| assertion | recorded claim; accepted knowledge when current and authoritative |
| promotion policy, autonomy rule | rule; the rulebook |
| decision `allow` | act on it |
| decision `review` | needs more information or a decision |
| decision `deny` | cannot act |
| dispute | open disagreement |
| supersession | replaced by a newer fact |
| effective time | when it is true |
| knowledge domain | area of the business |
| capability | permission |
| speech act | how it was said (reported, proposed, decided) |
| promotion evaluator | the checkpoint |
| observed process | how work actually flows |
| authoritative process | the official process |
| divergence | difference between practice and policy |
| source identity | an account or identity observed in a source; confirmation is separate |

Conformance for this contract:

- every reason code shown on a human surface has a versioned plain rendering
- agent-facing adapters map equivalent plain-language instructions to the same
  canonical operation and payload
- wrapper responses and audit records retain canonical codes even when they
  also contain human summaries
- rendered decision snapshots identify the lexicon version when exact replay is
  required

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
- source identity resolving through temporal role and team membership
- an authorized proposer who lacks decision authority returning `review`
- a manager decision matching the active transition policy returning `allow`
- missing process definition, prerequisite, and evidence returning distinct
  reason codes
- process supersession preserving the policy used by an earlier decision
- equal-authority contradictions entering the dispute path
- Slack occurrence, edit, retrieval, and business-effective times remaining
  distinct
- compliance distinguishing missing evidence from proven noncompliance
- observed and authoritative process lineages accepted in either order without
  cross-writes
- the evaluator unable to bind an observed-process assertion as policy
- divergence reporting unmodeled transitions, unobserved policy transitions,
  and authority divergence without mutating either lineage

## Delivery Sequence

1. Close broad administrative routes to agent tokens.
2. Reconcile and document trusted SQL, scoped DB, and secure API/MCP paths.
3. Add constrained node-domain membership and domain-safe reads.
4. Define the authority-resolution and temporal process pattern contracts.
5. Add append-only promotion decisions and idempotent promotion records.
6. Implement the atomic process-aware promotion helper with audit-only migration
   support.
7. Add the compliance read model.
8. Add the `rye agent` CLI and make API/MCP call the same SQL helpers.
9. Opt confirmed domain, claim, and transition policies into enforcement
   incrementally.

## Non-Goals

- Agents do not activate their own authority.
- Conversation frequency, channel names, and job titles do not establish
  authority or process policy.
- The transport database role does not become a business authorization model.
- Trusted administrative helpers are not removed.
- Local installations do not require an API gateway.
- This proposal does not change CDC payloads or materialized views.

The desired result is not maximum autonomy. It is useful autonomy with a small,
explainable decision contract and one database-enforced implementation.
