# Rye — Security

## Row-Level Security, Field Redaction, and Access Control

---

## 1. Authorization Model

Rye uses **session variables** as the single authorization mechanism. No mixing of session-based and database-role-based enforcement.

At the start of each transaction, the application sets:

```sql
SET LOCAL app.current_user_id = 'user-456';
SET LOCAL app.current_teams = 'engineering,sales';
SET LOCAL app.current_role = 'team_lead';
```

`SET LOCAL` scopes variables to the current transaction, which is safe for connection pooling (PgBouncer in transaction mode).

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

-- Events: visible if user can see at least one participant
CREATE POLICY event_read_policy ON events
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM event_participants ep WHERE ep.event_id = events.id
        )
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

Certain assertion types contain privileged information. Gate visibility by role using session variables:

```sql
CREATE POLICY assertion_type_read_policy ON assertions
    FOR SELECT
    USING (
        CASE assertion_type
            WHEN 'financial_terms'    THEN current_setting('app.current_role', true) IN ('deal_manager', 'finance', 'admin')
            WHEN 'negotiation_stance' THEN current_setting('app.current_role', true) IN ('deal_manager', 'admin')
            WHEN 'compensation'       THEN current_setting('app.current_role', true) IN ('hr_admin', 'admin')
            ELSE true
        END
    );
```

### 2.5 Write Policies

```sql
-- Assertion write restrictions by type
CREATE POLICY assertion_write_policy ON assertions
    FOR INSERT
    WITH CHECK (
        CASE assertion_type
            WHEN 'financial_terms' THEN current_setting('app.current_role', true) IN ('deal_manager', 'admin')
            WHEN 'compensation'    THEN current_setting('app.current_role', true) IN ('hr_admin', 'admin')
            ELSE true
        END
    );

-- Agent safety: agents can insert but not update or delete
CREATE POLICY agent_insert_only ON assertions
    FOR INSERT
    WITH CHECK (
        current_setting('app.current_role', true) NOT LIKE 'agent:%'
        OR true  -- agents CAN insert
    );

CREATE POLICY agent_no_delete ON assertions
    FOR DELETE
    USING (
        current_setting('app.current_role', true) NOT LIKE 'agent:%'
    );
```

---

## 3. Field-Level Redaction

PostgreSQL's column-level GRANT/REVOKE doesn't reach inside JSONB. Field-level security uses a redacting function.

### 3.1 Redaction Function

Strips sensitive keys from JSONB based on field classifications and the current session role.

```sql
CREATE FUNCTION redact_properties(
    p_properties jsonb,
    p_node_type text
) RETURNS jsonb AS $$
DECLARE
    v_result jsonb := p_properties;
    v_field record;
    v_user_role text := current_setting('app.current_role', true);
    v_role_hierarchy text[] := CASE v_user_role
        WHEN 'admin' THEN ARRAY['public', 'internal', 'confidential', 'restricted']
        WHEN 'deal_manager' THEN ARRAY['public', 'internal', 'confidential']
        WHEN 'team_lead' THEN ARRAY['public', 'internal', 'confidential']
        WHEN 'team_member' THEN ARRAY['public', 'internal']
        ELSE ARRAY['public']
    END;
BEGIN
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

### 3.2 Redacted View

Application queries should use this view instead of the raw `nodes` table when field-level redaction is needed:

```sql
CREATE VIEW nodes_secure AS
SELECT
    id, node_type, label, external_id, external_source,
    redact_properties(properties, node_type) AS properties,
    attrs, created_at, updated_at, archived_at
FROM nodes;
```

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
    INSERT INTO events (event_type, occurred_at, summary, properties, actor_system)
    VALUES (
        'agent_query', now(), p_result_summary,
        jsonb_build_object('query', p_query_text, 'agent_id', p_agent_id),
        'agent:' || p_agent_id
    )
    RETURNING id INTO v_event_id;

    INSERT INTO event_participants (event_id, node_id, role)
    SELECT v_event_id, unnest(p_nodes_referenced), 'queried';

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;
```
