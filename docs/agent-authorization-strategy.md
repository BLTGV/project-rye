# Agent authorization and adoption strategy

Start with the access you already have. A trusted user working through an agent can use Rye directly in PostgreSQL. A channel bot or unattended agent should use a constrained API identity. Neither path needs a custom approval engine just to begin using Rye.

This document describes three adoption examples and a proposed extension for conditional auto-acceptance. It does not announce new runtime integrations or change the security contract.

## Current behavior versus proposed features

| Capability | Status |
|---|---|
| Direct PostgreSQL access through session context and SQL lifecycle helpers | Implemented |
| Scope review policies: `open`, `candidates_only`, `strict` | Implemented |
| Agent identities, expiring/revocable tokens, capability grants with domain and scope fields | Implemented |
| HTTP API for context, observations, candidates, and review operations | Implemented; authenticate deployments explicitly |
| Stdio MCP adapter for context reads, observations, candidate submission, review-queue reads, and audit reads | Implemented; not a complete SQL or promotion interface |
| Turnkey OpenClaw, Slack, or GitHub Actions agent integration | Not established; configure the runtime and source connections separately |
| Conditional auto-accept rules matched against verified source evidence | Proposed |
| Agent-assisted rule drafting and an authenticated rule-approval screen | Proposed |
| Enforced prohibition on approving one's own proposal | Not established; separate identities and grants are the current operational approach |

Relevant implementation files:

- `schema/migrations/0016_agent_domain_security.sql`: agent identities, grants, tokens, and authorization helpers.
- `schema/migrations/0018_knowledge_governance_salience_gardening.sql`: `scope_review_policy()`, scope resolution, and assertion write policy.
- `admin/src/server/worker.ts`: bearer authentication and route capability checks.
- `skills/rye-source-context-intake/scripts/rye_api_mcp_server.mts`: current MCP tool surface.
- `docs/agent-ops-guide.md`: assertion evidence, review, supersession, and read patterns.

These paths are repository references, not web links. Behavior here was checked against source; no live integration or database verification was performed for this document.

## What accepted knowledge means

Accepted is a lifecycle status, not a guarantee that a statement is correct. Evidence, basis, effective dates, and history remain important. Read current accepted knowledge through `current_valid_assertions`; a future-effective accepted assertion is not current yet.

For ordinary `record_assertion()` submissions requesting `p_status := 'accepted'`:

| Governing review policy | Behavior |
|---|---|
| `open` | Accepted status is permitted, subject to evidence, permissions, and other lifecycle checks. |
| `candidates_only` | Non-observed submissions become candidates; observed submissions may remain accepted. |
| `strict` | Accepted submissions become candidates. |

An explicitly requested candidate stays a candidate. Special helpers and assertion types can impose additional restrictions. Missing or unresolved scope policy currently defaults to `open`; configure and verify the intended scope rather than relying on that default.

`observed` is not a trust credential. Reading a Slack message proves that the message exists; it does not independently prove the business claim in the message. User testimony is normally `reported`; agent interpretation is normally `inferred`. Do not relabel either as observed to avoid review.

Review policy controls initial submission. Authorized lifecycle helpers can subsequently accept candidates. Existing strict policy is not proof that only a human can ever accept: capable agents may promote through applicable helper paths.

## Example 1: API-connected agents across Slack, a repository, and GitHub Actions

### Systems and runtime configuration

A small team uses Slack for launch coordination, Claude Code for implementation, and a scheduled GitHub Actions workflow for a daily planning agent. Rye runs in a shared PostgreSQL database. The Rye Admin Worker exposes its HTTP API.

| Runtime | Rye identity | Configuration | Intended access |
|---|---|---|---|
| OpenClaw on a team-managed server, private admin conversation | `policy-assistant` | Separate runtime profile and token; authenticated administrator approval outside ordinary channel messages | Read and draft policy proposals; no rule activation |
| OpenClaw handling `#website-launch` | `launch-channel-assistant` | Slack app connection, approved channel ID, Rye endpoint and separate token | Read launch context; submit observations and candidates |
| Claude Code in the website repository | `website-coding-agent` | Installed Rye skills plus a supported HTTP/MCP connection and local secret configuration | Read context; propose implementation knowledge |
| Agent runner invoked by a GitHub Actions schedule | `launch-planning-agent` | Model API credential and Rye token in Actions secrets; endpoint in workflow configuration | Read commitments; propose dependency issues |
| Human in Rye Admin | Administrator/reviewer identity | Authenticated access managed separately from bot secrets | Review knowledge; approve future policy-rule changes |

A schedule alone is not an agent. The Actions workflow must invoke a model-backed runner that reasons over Rye context and uses tools. No particular OpenClaw configuration syntax is prescribed here: confirm the installed version's HTTP or stdio MCP support. The current Rye MCP adapter expects `RYE_API_URL` and `RYE_AGENT_TOKEN`.

Keep database credentials on the server and with database administrators. Give each runtime its own token; do not share a reviewer token with a channel bot. Store credentials in runtime secret stores, never prompts, repository instructions, or committed MCP configuration.

Before exposing the API, set `RYE_API_AUTH_MODE=required`: the current default is off. API bearer authentication is not a finished human administrator login system. Provision and verify human access separately. Check endpoint-specific domain and scope enforcement before depending on isolation: declaring a scoped grant is not proof that every route passes the target's domain and scope to authorization.

### Start today without conditional rules

1. A database administrator installs Rye, creates the launch scope, and configures its review policy.
2. The administrator provisions separate agent identities and tokens with the CLI or SQL helpers. Context reading uses `rye.context.read`; proposal submission uses `rye.candidate.create`; observations use `rye.observation.create`.
3. A teammate writes in Slack: “I'll send the revised homepage copy by Friday, September 25.”
4. OpenClaw interprets the commitment, resolves the author, and submits a candidate with source-message evidence. If the year or timezone is unclear, it asks rather than guessing.
5. A reviewer accepts the candidate through the appropriate review path. Acceptance uses `rye.authoritative.promote`; rejection/adjudication uses `rye.candidate.adjudicate`. Review-queue visibility uses `rye.review.read` and does not itself grant acceptance.
6. Claude Code retrieves the accepted commitment when planning implementation. The scheduled planning agent notices dependencies and proposes follow-ups; neither silently changes the deadline.

The API candidate submission path does not become a conditional auto-accept endpoint merely because a scope is `open`. The current MCP adapter does not expose acceptance tools, even to identities with promotion grants.

### Proposed agent-assisted approval setup

You tell the policy assistant in an administrative conversation:

> In the launch channel, automatically record explicit commitments people make for themselves. Never infer deadlines or accept assignments to someone else.

The assistant drafts a rule and explains it:

> Allow the launch-channel assistant to record self-commitments in the Website Launch scope, with the original message as evidence. Owner must match source author. Ambiguous commitments remain candidates. Approve this exact rule?

You review a proposed authenticated approval screen and activate the exact revision. The assistant can draft, but cannot activate its own rule. Ordinary Slack content cannot authorize policy changes. A conversational approval alternative would need verified platform identity, an administrator mapping, and confirmation bound to the exact rule revision.

Illustrative configuration only; Rye does not currently consume this YAML:

```yaml
name: launch-self-commitments
agent: launch-channel-assistant
scope: website-launch
source_channel: C0123456789
assertion_type: task_commitment
requirements:
  owner_matches_source_author: true
  original_message_evidence: true
  explicit_commitment: true
otherwise: review
```

The runtime's source connector verifies channel and author identity. The agent judges the language. Approval delegates that narrow judgment; it does not make the judgment deterministic or error-free. A copied message or an agent-supplied source label alone is not verified evidence.

Under the proposed gate, a matching submission becomes accepted and records its evidence, acting agent, and rule revision. “Maybe someone can handle the copy next week” remains a candidate. A proposed human-only policy setting would take precedence over auto-accept rules; do not confuse that proposed precedence with today's general `strict` submission policy.

## Example 2: a single user directing Claude Code with direct PostgreSQL access

### Systems and configuration

You maintain a repository with Claude Code or another coding agent that can execute `psql`. Rye is installed in your existing PostgreSQL 15+ database, or in a dedicated local Docker database. No Worker, HTTP API, channel connector, or rule engine is required.

- Install the Rye onboarding and agent-operations skills in the consumer workspace.
- Give the agent a connection through local environment/credential configuration, not a committed file. If using the Rye checkout's CLI, identify its path; installing a skill does not install `./scripts/rye` in your project.
- Create a project scope and explicitly choose `open` for user-directed accepted writes, or a stricter policy if you want a review step.
- Tell the agent which statements you authorize it to record and which changes require another question. This is operating guidance for a trusted assistant, not a database-enforced conditional rule.

### Your setup conversation

> Use Rye for this repository's architectural decisions. You may record decisions I explicitly confirm as accepted, with my instruction as evidence. Your suggestions stay candidates. Do not change the scope policy without asking me.

The agent summarizes that working agreement. You confirm it. Acting through your trusted database session, it configures the existing scope policy using `record_scope_policy()` and verifies it with `scope_review_policy()` or `compile_scope_policy()`. There is no separate rule-approval UI to visit.

For an existing scope, this is the current SQL configuration shape. Replace the scope placeholder before running:

```sql
BEGIN;
SET LOCAL search_path = rye, public, pg_catalog;
SET LOCAL "app.current_role" = 'admin';
SET LOCAL "app.current_user_id" = 'user:owner';
SELECT record_scope_policy(
    '<scope_uuid>'::uuid,
    'review_policy',
    '{"review_policy":"open"}'::jsonb,
    'default',
    'user:owner'
);
SELECT scope_review_policy('<scope_uuid>'::uuid);
COMMIT;
```

This grants no new database authority. It assumes you already have legitimate administrative access. `admin` represents this example's fully authorized owner, not a recommended default for unattended agents. The snippet configures broad initial-write policy, not the proposed per-source rule.

### Everyday use

You say:

> We decided billing webhooks activate subscriptions. Frontend callbacks must not do it. Record that as our decision.

The agent:

1. Finds the existing project and relevant vocabulary rather than inventing duplicate entities.
2. Records your confirmation through `record_event()`, keeping only necessary instruction content and a durable source reference when available.
3. Uses `record_assertion()` with `basis = 'reported'`, evidence referencing that event, the intended scope, and accepted status under `open`.
4. Checks the stored result and reads it back to you. Your instruction is the authority; the agent is executing it, not independently approving its own idea.

Next session, another agent retrieves the decision before editing checkout. If it suggests a different approach, that suggestion is a candidate. If you later approve a replacement, it uses the appropriate supersession helper, preserving the original decision and evidence.

No custom policy engine is needed for this trusted, user-directed workflow. The limitation is explicit: an agent holding your full database authority can exceed the working agreement. A skill instruction is not a sandbox.

## Example 3: a small team using direct database access

### Systems and configuration

Three fully authorized team members use Claude Code, Codex, or another SQL-capable assistant against one shared Rye database on PostgreSQL or Supabase. Their local agents have skills and a direct SQL tool or database MCP connection; there is no Rye API deployment.

Each person uses separately provisioned database connection credentials where practical, supplied through a password manager or local secret store. Database authentication controls connection access; Rye authorization remains based on session variables. Set a distinct `app.current_user_id` for attribution and the appropriate Rye role and team context in every transaction.

Session values are trusted caller context, not authenticated proof of the human identity. Separate connections improve operational accountability but do not make self-set Rye session values tamper-proof. This setup assumes collaborators and their assistants are trusted with the access they hold.

### The team approves its working arrangement

The team lead asks their assistant:

> Set up Launch Coordination. Each of us may record our own confirmed commitments immediately. Agent guesses and assignments to other people must stay candidates. Record this agreement and show us the policy before applying it.

The assistant explains the current implementation limit:

> I can use an open scope and follow that agreement when writing. Rye cannot currently enforce “only your own commitments” as a conditional rule for fully authorized direct SQL clients. If you need that enforced independently, use constrained access and a policy gate.

The team approves the trusted arrangement. Its agreement is retained as evidence and guidance; it must not be presented as an executable authorization rule. The administrator sets and verifies `open` using existing helpers.

### Daily work with agents

- A designer tells their assistant: “I commit to delivering the approved assets on September 25.” The assistant records a reported, accepted commitment with the designer's instruction as evidence.
- A developer asks their assistant: “What blocks implementation?” It reads accepted commitments and proposes an inferred dependency. That inference stays a candidate unless an authorized person approves it.
- The lead reviews the candidate through a SQL-capable assistant: “Accept that dependency; I confirmed it with both owners.” The assistant uses the lifecycle helper with the lead's reason and evidence, rather than editing assertion status directly.
- Another teammate later corrects a date. Their assistant shows the current commitment and seeks the appropriate confirmation under the team's agreement, then uses supersession. Concurrent or conflicting claims are retained for review rather than silently overwritten.

For higher-review scopes, use `strict` and have authorized users direct explicit acceptance through the lifecycle helpers. `candidates_only` is an intermediate option when genuinely observed writes may be accepted, but reported commitments still become candidates. Do not mark testimony observed simply to make it pass.

### Session and connection discipline

Use a transaction so context and operations share a connection, with `SET LOCAL` or transaction-local `set_config()`. With per-call SQL tools such as Supabase MCP, establish context and execute the operation in the same call; do not assume context survives the next call. Avoid pooled-session state leaking between people.

Preserve the human authorizer separately from the agent executor in evidence/event metadata. A caller-supplied `actor` label alone is not trustworthy identity proof. Use lifecycle helpers even when fully authorized: authority to act does not justify destroying history.

## Proposed built-in rule feature

Keep the first version small. The following is a design proposal, not an available API or migration:

1. Store revisioned rules using a suitable supporting structure, without adding domain-specific fields to core tables. Rules identify the acting agent, scope, target/type, approved source, expiry, and approving authority.
2. Separate permission to draft a rule from permission to activate or revoke it. A policy assistant can draft; an authenticated administrator activates the exact revision. These are proposed permissions, not current capability names.
3. Keep authorization checks read-only. Add a dedicated atomic submission helper that checks ordinary write permission, applicable review policy, and an active rule against verified evidence before writing.
4. Reject unauthorized submissions. Keep authorized but unmatched submissions as candidates. Make precedence and conflicts explicit; never silently fall back to permissive acceptance when a required rule is absent.
5. Record the rule revision, evidence, agent, authorizer, and result. Deduplicate source events and retries; revocation stops future matching but does not silently erase accepted history.
6. Expose one normal submission tool and a clear result: accepted, pending review, or denied. Add rule drafting and human activation surfaces separately. Do not give the general agent a broad promotion token to simulate conditional authority.

Start with exact identity, scope, type, subject, and verified-source checks rather than arbitrary expressions. Semantic conditions such as “explicit commitment” remain delegated agent judgments. Each source integration needs a trusted verification path; configuration alone cannot establish authenticity.

The SQL helper should be the shared implementation for direct SQL and HTTP callers where conditional enforcement is required. However, it cannot constrain fully authorized clients that can choose other write paths or change policy themselves. Enforced isolation requires a restricted execution boundary, not just another helper.

## Adoption order

1. For one user or a mutually trusted small team, use direct SQL, skills, an explicit scope policy, and human-directed lifecycle helpers. Prove one useful write/read loop before adding infrastructure.
2. For channel bots and unattended agents, use separate API identities with narrow permissions and review candidates initially. Verify missing-token, denied-action, revoked-token, and cross-scope behavior for the actual routes used.
3. Add conditional rules only when repeated review has a clear, narrow pattern worth delegating. Ship rule configuration, identity verification, evidence checks, and acceptance tests together; do not describe a prompt-only promise as enforcement.

Successful adoption means a fresh agent can retrieve a prior accepted decision, explain its source, propose a change, and preserve history when the authorized user approves it. The simplest deployment is the one that achieves that loop with the access and trust model the team already has.
