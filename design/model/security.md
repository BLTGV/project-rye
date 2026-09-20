# Rye — Security

## Row-Level Security, Field Redaction, and Access Control

All Rye security objects (RLS policies, `SECURITY DEFINER` functions) live in the `rye` schema. The `redact_properties()` function uses `SET search_path = rye, pg_catalog` (no `public`) to prevent search-path injection attacks against `SECURITY DEFINER` functions. See `design/model/deployment.md` for the full schema isolation rationale.

---

## 1. Authorization Model

Rye uses **session variables** as the single authorization mechanism. No mixing of session-based and database-role-based enforcement.

At the start of each transaction, the application sets:

```sql
BEGIN;

SET LOCAL "app.current_user_id" = 'user-456';
SET LOCAL "app.current_teams" = 'engineering,sales';
SET LOCAL "app.current_role" = 'team_lead';

-- ... the application's queries ...

COMMIT;
```

`SET LOCAL` scopes variables to the current transaction, which is safe for connection pooling (PgBouncer in transaction mode). It requires an open transaction: run outside one it warns and sets nothing, leaving every query unauthorized. In a session walk with no transaction, use plain `SET`; with a pooled or per-call SQL tool, use `set_config()` in the same call as the query.

All RLS policies, write checks, and field redaction reference these session variables — never `pg_has_role()` or `current_user`.

---

## 2. Row-Level Security

### 2.1 Enable RLS

```sql
ALTER TABLE nodes       ENABLE ROW LEVEL SECURITY;
ALTER TABLE edges       ENABLE ROW LEVEL SECURITY;
ALTER TABLE events      ENABLE ROW LEVEL SECURITY;
ALTER TABLE assertions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE artifacts   ENABLE ROW LEVEL SECURITY;

-- FORCE ensures RLS applies even to table owners
ALTER TABLE nodes       FORCE ROW LEVEL SECURITY;
ALTER TABLE edges       FORCE ROW LEVEL SECURITY;
ALTER TABLE events      FORCE ROW LEVEL SECURITY;
ALTER TABLE assertions  FORCE ROW LEVEL SECURITY;
ALTER TABLE artifacts   FORCE ROW LEVEL SECURITY;
```

### 2.2 Node Visibility (Anchor Policy)

Nodes are the anchor. If a user can't see a node, they can't see its edges, assertions, or event participations.

```sql
CREATE POLICY node_read_policy ON nodes
    FOR SELECT
    USING (
        -- Public or unclassified nodes are visible to everyone
        attrs->>'classification' = 'public'
        OR attrs->>'classification' IS NULL
        OR
        -- Team-gated: user's teams must overlap with node's teams
        attrs->'teams' ?| string_to_array(
            current_setting('app.current_teams', true), ','
        )
        OR
        -- Explicit grants from access_grants table
        EXISTS (
            SELECT 1 FROM access_grants ag
            WHERE ag.active = true
              AND ag.resource_type = 'node'
              AND (
                  ag.grantee = current_setting('app.current_user_id', true)
                  OR ag.grantee = current_setting('app.current_role', true)
                  OR ag.grantee = ANY(string_to_array(
                      current_setting('app.current_teams', true), ','
                  ))
              )
              AND (
                  ag.scope->>'node_id' = nodes.id::text
                  OR ag.scope->>'node_type' = nodes.node_type
                  OR ag.scope->>'classification' = nodes.attrs->>'classification'
              )
        )
    );
```

### 2.3 Cascading Visibility

Edges, assertions, and events inherit visibility from the nodes they reference.

```sql
-- Edges: must see both endpoints
CREATE POLICY edge_read_policy ON edges
    FOR SELECT
    USING (
        EXISTS (SELECT 1 FROM nodes WHERE id = edges.source_id)
        AND EXISTS (SELECT 1 FROM nodes WHERE id = edges.target_id)
    );

-- Assertions: must see the subject node
CREATE POLICY assertion_read_policy ON assertions
    FOR SELECT
    USING (
        subject_node_id IS NULL
        OR EXISTS (SELECT 1 FROM nodes WHERE id = assertions.subject_node_id)
    );

-- Event participants: must see the participating node
CREATE POLICY ep_read_policy ON event_participants
    FOR SELECT
    USING (
        EXISTS (SELECT 1 FROM nodes WHERE id = event_participants.node_id)
    );

-- Events: visible if user can see at least one participant, or if admin
CREATE POLICY event_read_policy ON events
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM event_participants ep WHERE ep.event_id = events.id
        )
        OR current_setting('app.current_role', true) = 'admin'
    );

-- Artifacts: must see the source node
CREATE POLICY artifact_read_policy ON artifacts
    FOR SELECT
    USING (
        source_node_id IS NULL
        OR EXISTS (SELECT 1 FROM nodes WHERE id = artifacts.source_node_id)
    );
```

### 2.4 Assertion-Type Gating

Certain assertion types contain privileged information. Access is controlled via the `assertion_type_access` table — new sensitive types can be added by inserting a row instead of modifying SQL policies.

```sql
-- The assertion_type_access table drives both read and write gating
CREATE TABLE assertion_type_access (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    assertion_type  text NOT NULL,
    operation       text NOT NULL CHECK (operation IN ('read', 'write')),
    allowed_roles   text[] NOT NULL,
    UNIQUE (assertion_type, operation)
);
```

The read policy uses a two-part check: if the assertion type has no entry in the table, it's visible to all. If it does, only listed roles can see it:

```sql
CREATE POLICY assertion_read_policy ON assertions
    FOR SELECT
    USING (
        -- Node visibility check (cascading)
        ...
        AND (
            NOT EXISTS (
                SELECT 1 FROM assertion_type_access ata
                WHERE ata.assertion_type = assertions.assertion_type
                  AND ata.operation = 'read'
            )
            OR EXISTS (
                SELECT 1 FROM assertion_type_access ata
                WHERE ata.assertion_type = assertions.assertion_type
                  AND ata.operation = 'read'
                  AND current_setting('app.current_role', true) = ANY(ata.allowed_roles)
            )
        )
    );
```

Default seed data:

| assertion_type | operation | allowed_roles |
|---|---|---|
| `financial_terms` | read | `deal_manager`, `finance`, `admin` |
| `financial_terms` | write | `deal_manager`, `admin` |
| `negotiation_stance` | read | `deal_manager`, `admin` |
| `compensation` | read | `hr_admin`, `admin` |
| `compensation` | write | `hr_admin`, `admin` |

### 2.5 Write Policies

Agent roles (`agent:*`) can INSERT nodes, edges, events, event participants, assertions, and artifacts. They cannot DELETE any of these. Direct UPDATE is blocked — agents modify data only through approved function paths that set session flags.

**Who may write at all.** Migration `0026` adds one conjunct,
`rye_role_may_write()`, to every `INSERT`, `UPDATE`, and `DELETE` policy on the
seven core tables. It is true when `app.current_role` is agent-shaped or names a
`role_classification_access` row whose `may_write` column is true, and false for
`viewer`, for an unknown role name, and for an unset role. The rule is a row in
a table that is already the instance's role list, so a new read-only role is an
`INSERT` and widening a role later is an `UPDATE`. The snippets below predate
`0026` and omit that conjunct; the installed policies carry it, and
`scripts/verify.sh` fails if any of the twenty-one does not.

**The governance structure is admin-only.** The same policies carry a row-local
test on the row's own type column: a `nodes` row whose `node_type` is
`onboarding_scope`, and an `edges` row whose `edge_type` is
`scope_governs_subject`, `scope_governs_source`, or `scope_enables_plugin`, may
be inserted, updated, or deleted only by a caller whose `app.current_role` is
`admin`. Because RLS applies `USING` to the old row and `WITH CHECK` to the new
one, one rule covers archiving, ending, deleting, and re-pointing in both
directions. `scope_status` is settle-gated to `admin` beside `registry_entry`
and `review_policy`. `has_step` is not gated, so an inherited scope can still be
dropped by archiving one; a subject that must stay governed gets its own
`scope_governs_subject` edge.

Every rule in this subsection reads the role in order to permit, which is what a
role model is. It protects deployments where a trusted backend sets the session
variables, and agents that state their role honestly. It is not a defence
against a hostile caller with a raw connection. Recorded in
`docs/decisions/0009-who-may-write.md`; contract in `contracts/sql-surface.md`,
"Who may write".

```sql
-- Nodes, edges, artifacts: any role can INSERT (including agents)
CREATE POLICY node_insert_policy ON nodes
    FOR INSERT WITH CHECK (true);

-- Node updates: non-agents unrestricted; agents only via update_node_properties()
-- The function sets app.write_path = 'update_node_properties' before the UPDATE.
CREATE POLICY node_update_policy ON nodes
    FOR UPDATE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
        OR current_setting('app.write_path', true) = 'update_node_properties'
    )
    WITH CHECK (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
        OR current_setting('app.write_path', true) = 'update_node_properties'
    );

-- Assertion write restrictions by type (data-driven via assertion_type_access)
CREATE POLICY assertion_insert_policy ON assertions
    FOR INSERT
    WITH CHECK (
        NOT EXISTS (
            SELECT 1 FROM assertion_type_access ata
            WHERE ata.assertion_type = assertions.assertion_type
              AND ata.operation = 'write'
        )
        OR EXISTS (
            SELECT 1 FROM assertion_type_access ata
            WHERE ata.assertion_type = assertions.assertion_type
              AND ata.operation = 'write'
              AND current_setting('app.current_role', true) = ANY(ata.allowed_roles)
        )
    );

-- Function-scoped supersession updates only.
-- The supersede_assertion(...) function sets these flags before update.
CREATE POLICY assertion_update_policy ON assertions
    FOR UPDATE
    USING (
        current_setting('app.write_path', true) = 'supersede_assertion'
        AND id::text = current_setting('app.supersede_assertion_id', true)
    )
    WITH CHECK (
        current_setting('app.write_path', true) = 'supersede_assertion'
        AND id::text = current_setting('app.supersede_assertion_id', true)
    );

-- No direct assertion deletes.
CREATE POLICY assertion_no_delete ON assertions
    FOR DELETE
    USING (false);
```

### 2.6 Write-Path Gate Pattern

Several UPDATE policies use a **write-path gate**: the policy allows updates only when a session variable (`app.write_path`) is set to a specific value. The corresponding function sets this flag before performing the update and clears it immediately after.

| Gate value | Policy | Function |
|---|---|---|
| `supersede_assertion` | `assertion_update_policy` | `supersede_assertion()` |
| `update_node_properties` | `node_update_policy` | `update_node_properties()` |

This pattern lets agents (and other restricted roles) perform controlled updates through audited functions while blocking direct `UPDATE` statements. RLS still applies to the SELECT portion — agents can only update rows they can read.

> **Important:** `SELECT ... FOR UPDATE` requires both the SELECT and UPDATE policies to pass. When using a write-path gate, set the flag **before** the `FOR UPDATE` lock, not after. Otherwise the locking SELECT will fail for gated roles.

> **The write-path gate grants nothing.** Any caller can run the same
> `set_config()` the helper runs, so on `assertions` the gate is a pre-filter
> that stops a stray `UPDATE` and no more. Everything that matters is enforced
> by triggers that re-derive their answer from the row. See
> "The assertion lifecycle is enforced by the row" below.

### 2.7 The Assertion Lifecycle Is Enforced by the Row

Migration `0025` replaces `assertions_immutable_guard()` in place and adds two
triggers. Together they decide what an assertion may become, per column, from
`OLD`, `NEW`, rows that already exist, and `app.current_role`. No rule reads
`app.write_path`, because any caller can set it, and no rule permits on the
basis of a role, because any caller can claim one. There is no admin exemption.

| Trigger | Timing | What it decides |
|---|---|---|
| `trg_assertion_settle_gate` (0023) | BEFORE INSERT OR UPDATE | Configuration types need an admin. Sorts first, and `tests/conformance/30_configuration_gate.sql` depends on that. |
| `trg_assertions_insert_review` (0025) | BEFORE INSERT | A direct `INSERT` of an accepted row is demoted where `record_assertion()` demotes. |
| `trg_assertions_immutable` (0025 function, 0002 trigger) | BEFORE UPDATE | The per-column rules for `status`, `superseded_at`, `superseded_by`, `effective_to`, `attrs` and `classification`. |
| `trg_assertions_transition_complete` (0025) | AFTER INSERT OR UPDATE, deferred | The acceptance event, the replacement's type and key, and the successor of a narrowed window. Refuses at `COMMIT`. |

**What this protects and what it does not.** Rye's authorization is session
variables. A caller holding a raw connection can set `app.current_role` to
`admin`, and nothing here changes that. Two things are protected: deployments
where a trusted backend sets the session variables and callers cannot, and
well-behaved agents that state their role honestly and must not be able to skip
review by accident or by following bad instructions. It is not a defence against
a hostile caller with a raw connection.

Inside that boundary, three claims hold for any caller at all, forged role
included, because they read no role: an accepted assertion cannot be ended
without a replacement of the same type and key; a window cannot be narrowed
without a successor; and `claim`, `basis`, `confidence` and the subject cannot be
rewritten. Nothing anywhere may claim more.

The full per-column table and the four stated limits are in
`contracts/sql-surface.md`, section "The row is the gate, not the route".

---

## 3. Field-Level Redaction

PostgreSQL's column-level GRANT/REVOKE doesn't reach inside JSONB. Field-level security uses a redacting function.

### 3.1 Redaction Function

Strips sensitive keys from JSONB based on field classifications and the current session role. The role-to-classification mapping is data-driven via the `role_classification_access` table — new roles can be added by inserting a row.

```sql
CREATE TABLE role_classification_access (
    role_name        text NOT NULL,
    classifications  text[] NOT NULL,
    PRIMARY KEY (role_name)
);
```

Default seed data:

| role_name | classifications |
|---|---|
| `admin` | `public`, `internal`, `confidential`, `restricted` |
| `deal_manager` | `public`, `internal`, `confidential` |
| `team_lead` | `public`, `internal`, `confidential` |
| `hr_admin` | `public`, `internal`, `confidential` |
| `finance` | `public`, `internal`, `confidential` |
| `manager` | `public`, `internal`, `confidential` |
| `team_member` | `public`, `internal` |
| `viewer` | `public` |

The redaction function looks up accessible classifications for the current role. Unknown roles default to `public` only.

```sql
CREATE FUNCTION redact_properties(
    p_properties jsonb,
    p_node_type text
) RETURNS jsonb AS $$
DECLARE
    v_result jsonb := p_properties;
    v_field record;
    v_user_role text := current_setting('app.current_role', true);
    v_role_hierarchy text[];
BEGIN
    SELECT classifications INTO v_role_hierarchy
    FROM role_classification_access
    WHERE role_name = v_user_role;

    IF v_role_hierarchy IS NULL THEN
        v_role_hierarchy := ARRAY['public'];
    END IF;

    FOR v_field IN
        SELECT field_path, classification
        FROM field_classifications
        WHERE node_type = p_node_type
    LOOP
        IF NOT v_field.classification = ANY(v_role_hierarchy) THEN
            v_result := v_result - split_part(v_field.field_path, '.', 2);
        END IF;
    END LOOP;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;
```

### 3.2 View Security (`security_invoker`)

All views that query RLS-protected tables **MUST** use `security_invoker = true` (PostgreSQL 15+). Without this, views execute with the view owner's permissions, silently bypassing RLS when the owner is a superuser.

```sql
CREATE VIEW current_assertions
WITH (security_invoker = true) AS
SELECT * FROM assertions WHERE superseded_at IS NULL;

CREATE VIEW nodes_secure
WITH (security_invoker = true) AS
SELECT
    id, node_type, label, external_id, external_source,
    redact_properties(properties, node_type) AS properties,
    attrs, created_at, updated_at, archived_at
FROM nodes;
```

This applies to all views: `current_assertions`, `node_context`, and `nodes_secure`.

### 3.3 Classification Enforcement

Nodes with team scoping (`attrs->'teams'` is a non-empty array) **MUST** have `attrs->>'classification'` set. A trigger enforces this constraint. Nodes without teams or classification are treated as public and visible to all users.

### 3.4 Redacted View

Application queries should use `nodes_secure` instead of the raw `nodes` table when field-level redaction is needed.

### 3.3 Classification Examples

```sql
INSERT INTO field_classifications (node_type, field_path, classification, min_role) VALUES
    ('person', 'properties.ssn', 'restricted', 'admin'),
    ('person', 'properties.personal_email', 'confidential', 'deal_manager'),
    ('person', 'properties.salary', 'restricted', 'hr_admin'),
    ('person', 'properties.phone', 'internal', 'team_member');
```

---

## 4. Access Grant Examples

```sql
-- Engineering team can read/write their nodes
INSERT INTO access_grants (grantee, grant_type, resource_type, access_level, scope) VALUES
    ('engineering', 'team', 'node', 'write', '{"teams": ["engineering"]}');

-- Sales team can read all customers
INSERT INTO access_grants (grantee, grant_type, resource_type, access_level, scope) VALUES
    ('sales', 'team', 'node', 'read', '{"node_type": "customer"}');

-- Finance can see financial assertions across all entities
INSERT INTO access_grants (grantee, grant_type, resource_type, access_level, scope) VALUES
    ('finance', 'team', 'assertion', 'read', '{"assertion_type": "financial_terms"}');

-- Specific user gets access to a specific node
INSERT INTO access_grants (grantee, grant_type, resource_type, access_level, scope) VALUES
    ('user:bob', 'user', 'node', 'read', '{"node_id": "abc-123-def"}');
```

---

## 5. Agent Query Logging

Every agent interaction should produce an event for auditability:

```sql
CREATE FUNCTION log_agent_query(
    p_agent_id text,
    p_query_text text,
    p_result_summary text,
    p_nodes_referenced uuid[]
) RETURNS uuid AS $$
DECLARE
    v_event_id uuid;
BEGIN
    -- Pre-generate UUID instead of using RETURNING id.
    -- RETURNING triggers the event_read_policy SELECT check,
    -- which requires participants to exist — but participants
    -- are inserted after the event.
    v_event_id := gen_random_uuid();

    INSERT INTO events (id, event_type, occurred_at, summary, properties, actor_system)
    VALUES (
        v_event_id,
        'agent_query', now(), p_result_summary,
        jsonb_build_object('query', p_query_text, 'agent_id', p_agent_id),
        'agent:' || p_agent_id
    );

    INSERT INTO event_participants (event_id, node_id, role)
    SELECT v_event_id, unnest(p_nodes_referenced), 'queried';

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;
```

> **Important:** Never use `INSERT INTO events ... RETURNING id` in functions that add participants after the insert. The `event_read_policy` requires at least one participant to exist before the event is visible via SELECT, and `RETURNING` triggers that SELECT check. Always pre-generate the UUID with `gen_random_uuid()` and pass it explicitly.

---

## 6. Supporting Table RLS

RLS is enabled and forced on all supporting and configuration tables.

### `access_grants`

| Operation | Who |
|---|---|
| SELECT | `admin`, `manager`, or the grantee (user, role, or team) |
| INSERT/UPDATE | `admin`, `manager` |
| DELETE | `admin` only |

### `node_source_map`

| Operation | Who |
|---|---|
| SELECT | Anyone who can see the linked node (cascading visibility) |
| INSERT | All roles |
| UPDATE | Anyone who can see the linked node (cascading visibility) |
| DELETE | `admin`, `manager` |

### `field_classifications`

| Operation | Who |
|---|---|
| SELECT | All roles (needed by `redact_properties()` which is `SECURITY DEFINER`) |
| INSERT/UPDATE/DELETE | `admin` only |

### `assertion_type_access`

| Operation | Who |
|---|---|
| SELECT | All roles (needed by RLS policies) |
| INSERT/UPDATE/DELETE | `admin` only |

### `role_classification_access`

| Operation | Who |
|---|---|
| SELECT | All roles (needed by `redact_properties()`) |
| INSERT/UPDATE/DELETE | `admin` only |

It is also the instance's list of role names. The governance policies in section 7 read it to decide whether a session is a named role, and the core write policies in section 2.5 read its `may_write` column to decide whether a session may write at all. Only `INSERT` was policed before `0026`; that migration adds the admin-only `UPDATE` policy the "widening a role is an UPDATE" rule needs.

---

## 7. Governance Table RLS

Nine tables say which areas exist, who holds authority in them, which channels feed them, which agents exist, what each agent may do, and what each agent did. RLS is enabled and forced on all nine. `app.current_role` decides — never `current_user`, never `pg_has_role()`.

### 7.1 Session shapes

| Shape | Matched when `app.current_role` is |
|---|---|
| admin | `admin` |
| named role | any `role_classification_access.role_name` |
| agent-shaped | `agent:<key>`, whether or not an identity by that key exists |
| bound agent | `agent:<agent_key>` of an `active` `agent_identities` row |
| unknown | anything else, including unset |

Two read-only helpers are the definition. `rye_current_agent_key()` returns the part after `agent:`, or null; it reads no table, so it is safe inside `agent_identities`' own policy. `rye_current_agent_id()` resolves that key to an identity id, or null; it reads the roster, so it may be used only in policies on tables below `agent_identities`. Neither is `SECURITY DEFINER`. **Own rows** always means `agent_id = rye_current_agent_id()`.

**`app.current_user_id` is a label, not a binding.** It is the actor string helpers write into events, `created_by`, and audit payloads. It is free text, it is frequently a human or a test marker, and no rule here reads it. A session whose label names a different agent than its role is not an error: the label is ignored, and the session is the agent its role names, or no agent at all. `agent_can_promote_in_scope()` resolved the acting agent from the label before this and now resolves through `rye_current_agent_id()` only. A test or client that sets `app.current_role` to `agent:<key>` must use the stored key of the identity whose grants it expects.

### 7.2 Who reads, who writes

| Table | admin | named role | bound agent | agent-shaped only | unknown |
|---|---|---|---|---|---|
| `knowledge_domains` | read all; insert, update, delete | read all | read areas it holds | nothing | nothing |
| `domain_authorities` | read all; insert, update, delete | read all | read rows of areas it holds | nothing | nothing |
| `channel_domain_subscriptions` | read all; insert, update, delete | read all | read rows of areas it holds | nothing | nothing |
| `domain_claim_policies` | read all; insert, update, delete | read all | read rows of areas it holds | nothing | nothing |
| `agent_identities` | read all; insert, update, delete | read all | read all | read all | nothing |
| `agent_capability_grants` | read all; insert, update, delete | nothing | read own rows | nothing | nothing |
| `agent_action_log` | read all; insert only | nothing | read own rows | nothing | nothing |
| `api_idempotency_keys` | read all; insert, delete | nothing | read own rows | nothing | nothing |
| `agent_api_tokens` | read all; insert, update, delete | nothing | nothing | nothing | nothing |

An agent **holds** an area when it has an active, unexpired `agent_capability_grants` row whose `domain_id` is that area or null. The capability name is not part of the rule.

The whole roster is readable by every session that can see anything else. `agent_identities` carries no secret, and it is the deny-list for "an agent is never a settler". A deny-list some callers cannot read is a deny-list that fails open.

`agent_action_log` is append-only for everyone, admin included, exactly as `events` and `assertion_evidence` are. There is no UPDATE or DELETE policy on it.

### 7.3 No policy reads its own table

A policy whose expression subqueries its own table raises `infinite recursion detected in policy for relation`. One that calls a function reading its own table recurses to `stack depth limit exceeded` — `SECURITY DEFINER` included. So the tables are ordered, and a policy reads only levels strictly below its own:

| Level | Tables |
|---|---|
| 0 | `role_classification_access`, `assertion_type_access`, `field_classifications` |
| 1 | `agent_identities` |
| 2 | `agent_capability_grants`, `agent_action_log`, `api_idempotency_keys`, `agent_api_tokens` |
| 3 | `knowledge_domains`, `domain_authorities`, `channel_domain_subscriptions`, `domain_claim_policies` |

The chain area → grants → identities → roles terminates. That is why the roster's read rule is key-only rather than "names an active identity": at level 1 there is nothing left to ask.

### 7.4 Writes go through the helpers, and the policies enforce it

`ensure_knowledge_domain`, `subscribe_channel_to_domain`, `grant_domain_authority`, `create_agent_identity`, and `grant_agent_capability` stay `SECURITY INVOKER` with no role check in the body. What refuses a non-admin is the admin-only write policy on the table each one writes — the same rule that governs a direct `INSERT`, so there is one rule in one place.

Two writes are made on behalf of a caller who is not an admin, and both use the write-path gate of section 2.6:

| Gate value | Policy | Function |
|---|---|---|
| `record_agent_action` | `agent_action_log_insert_policy` | `record_agent_action()` |
| `agent_create_candidate` | `api_idempotency_keys_insert_policy` | `agent_create_candidate()` |

The log insert is admitted from any session so that a denial is recorded even when the caller was impersonating another agent. `record_agent_action()` therefore generates the row id itself rather than using `INSERT ... RETURNING`: `RETURNING` reads the new row back, which puts it through a SELECT policy that admits only the caller's own rows, and a log write that has to be readable by its writer is not an audit trail.

### 7.5 `SECURITY DEFINER` does not bypass these policies

Under `FORCE ROW LEVEL SECURITY` with an owner that is not a superuser — the Supabase case — a `SECURITY DEFINER` function is still subject to every policy, evaluated with the caller's session variables, because `app.current_role` is session state and the function does not change it. Marking a function `DEFINER` buys no visibility here. The agent functions keep working because the rows they read are readable to the session that calls them and the rows they write are admitted by a named gate.

Refusals are not uniform. A refused `INSERT` raises `42501`. A refused `UPDATE` or `DELETE` raises nothing and affects zero rows. A refused `SELECT` returns zero rows.
