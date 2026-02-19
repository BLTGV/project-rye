-- Rye security model (session-context + RLS)

ALTER TABLE nodes               ENABLE ROW LEVEL SECURITY;
ALTER TABLE edges               ENABLE ROW LEVEL SECURITY;
ALTER TABLE events              ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_participants  ENABLE ROW LEVEL SECURITY;
ALTER TABLE assertions          ENABLE ROW LEVEL SECURITY;
ALTER TABLE artifacts           ENABLE ROW LEVEL SECURITY;

ALTER TABLE nodes               FORCE ROW LEVEL SECURITY;
ALTER TABLE edges               FORCE ROW LEVEL SECURITY;
ALTER TABLE events              FORCE ROW LEVEL SECURITY;
ALTER TABLE event_participants  FORCE ROW LEVEL SECURITY;
ALTER TABLE assertions          FORCE ROW LEVEL SECURITY;
ALTER TABLE artifacts           FORCE ROW LEVEL SECURITY;

-- Nodes
DROP POLICY IF EXISTS node_read_policy ON nodes;
CREATE POLICY node_read_policy ON nodes
    FOR SELECT
    USING (
        attrs->>'classification' = 'public'
        OR attrs->>'classification' IS NULL
        OR attrs->'teams' ?| coalesce(string_to_array(current_setting('app.current_teams', true), ','), ARRAY[]::text[])
        OR EXISTS (
            SELECT 1
            FROM access_grants ag
            WHERE ag.active = true
              AND ag.resource_type = 'node'
              AND (
                  ag.grantee = current_setting('app.current_user_id', true)
                  OR ag.grantee = current_setting('app.current_role', true)
                  OR ag.grantee = ANY(coalesce(string_to_array(current_setting('app.current_teams', true), ','), ARRAY[]::text[]))
              )
              AND (
                  ag.scope->>'node_id' = nodes.id::text
                  OR ag.scope->>'node_type' = nodes.node_type
                  OR ag.scope->>'classification' = nodes.attrs->>'classification'
              )
        )
    );

DROP POLICY IF EXISTS node_insert_policy ON nodes;
CREATE POLICY node_insert_policy ON nodes
    FOR INSERT
    WITH CHECK (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
    );

DROP POLICY IF EXISTS node_update_policy ON nodes;
CREATE POLICY node_update_policy ON nodes
    FOR UPDATE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
    )
    WITH CHECK (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
    );

DROP POLICY IF EXISTS node_delete_policy ON nodes;
CREATE POLICY node_delete_policy ON nodes
    FOR DELETE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
    );

-- Edges
DROP POLICY IF EXISTS edge_read_policy ON edges;
CREATE POLICY edge_read_policy ON edges
    FOR SELECT
    USING (
        EXISTS (SELECT 1 FROM nodes WHERE id = edges.source_id)
        AND EXISTS (SELECT 1 FROM nodes WHERE id = edges.target_id)
    );

DROP POLICY IF EXISTS edge_insert_policy ON edges;
CREATE POLICY edge_insert_policy ON edges
    FOR INSERT
    WITH CHECK (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
    );

DROP POLICY IF EXISTS edge_update_policy ON edges;
CREATE POLICY edge_update_policy ON edges
    FOR UPDATE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
    )
    WITH CHECK (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
    );

DROP POLICY IF EXISTS edge_delete_policy ON edges;
CREATE POLICY edge_delete_policy ON edges
    FOR DELETE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
    );

-- Assertions (single read policy includes subject visibility + type gating)
-- Direct assertion UPDATE is blocked; supersession path is scoped via
-- app.write_path/app.supersede_assertion_id set inside approved functions.
DROP POLICY IF EXISTS assertion_read_policy ON assertions;
CREATE POLICY assertion_read_policy ON assertions
    FOR SELECT
    USING (
        (
            subject_node_id IS NULL
            OR EXISTS (SELECT 1 FROM nodes WHERE id = assertions.subject_node_id)
        )
        AND (
            CASE assertion_type
                WHEN 'financial_terms' THEN current_setting('app.current_role', true) IN ('deal_manager', 'finance', 'admin')
                WHEN 'negotiation_stance' THEN current_setting('app.current_role', true) IN ('deal_manager', 'admin')
                WHEN 'compensation' THEN current_setting('app.current_role', true) IN ('hr_admin', 'admin')
                ELSE true
            END
        )
    );

DROP POLICY IF EXISTS assertion_insert_policy ON assertions;
CREATE POLICY assertion_insert_policy ON assertions
    FOR INSERT
    WITH CHECK (
        CASE assertion_type
            WHEN 'financial_terms' THEN current_setting('app.current_role', true) IN ('deal_manager', 'admin')
            WHEN 'compensation' THEN current_setting('app.current_role', true) IN ('hr_admin', 'admin')
            ELSE true
        END
    );

DROP POLICY IF EXISTS assertion_update_policy ON assertions;
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

DROP POLICY IF EXISTS assertion_delete_policy ON assertions;
CREATE POLICY assertion_delete_policy ON assertions
    FOR DELETE
    USING (false);

-- Event participants
DROP POLICY IF EXISTS ep_read_policy ON event_participants;
CREATE POLICY ep_read_policy ON event_participants
    FOR SELECT
    USING (
        EXISTS (SELECT 1 FROM nodes WHERE id = event_participants.node_id)
    );

DROP POLICY IF EXISTS ep_insert_policy ON event_participants;
CREATE POLICY ep_insert_policy ON event_participants
    FOR INSERT
    WITH CHECK (true);

DROP POLICY IF EXISTS ep_update_policy ON event_participants;
CREATE POLICY ep_update_policy ON event_participants
    FOR UPDATE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
    )
    WITH CHECK (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
    );

DROP POLICY IF EXISTS ep_delete_policy ON event_participants;
CREATE POLICY ep_delete_policy ON event_participants
    FOR DELETE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
    );

-- Events
DROP POLICY IF EXISTS event_read_policy ON events;
CREATE POLICY event_read_policy ON events
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM event_participants ep
            WHERE ep.event_id = events.id
        )
    );

DROP POLICY IF EXISTS event_insert_policy ON events;
CREATE POLICY event_insert_policy ON events
    FOR INSERT
    WITH CHECK (true);

DROP POLICY IF EXISTS event_update_policy ON events;
CREATE POLICY event_update_policy ON events
    FOR UPDATE
    USING (false)
    WITH CHECK (false);

DROP POLICY IF EXISTS event_delete_policy ON events;
CREATE POLICY event_delete_policy ON events
    FOR DELETE
    USING (false);

-- Artifacts
DROP POLICY IF EXISTS artifact_read_policy ON artifacts;
CREATE POLICY artifact_read_policy ON artifacts
    FOR SELECT
    USING (
        source_node_id IS NULL
        OR EXISTS (SELECT 1 FROM nodes WHERE id = artifacts.source_node_id)
    );

DROP POLICY IF EXISTS artifact_insert_policy ON artifacts;
CREATE POLICY artifact_insert_policy ON artifacts
    FOR INSERT
    WITH CHECK (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
    );

DROP POLICY IF EXISTS artifact_update_policy ON artifacts;
CREATE POLICY artifact_update_policy ON artifacts
    FOR UPDATE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
    )
    WITH CHECK (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
    );

DROP POLICY IF EXISTS artifact_delete_policy ON artifacts;
CREATE POLICY artifact_delete_policy ON artifacts
    FOR DELETE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
    );

CREATE OR REPLACE FUNCTION redact_properties(
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

CREATE OR REPLACE VIEW nodes_secure
WITH (security_invoker = true) AS
SELECT
    id,
    node_type,
    label,
    external_id,
    external_source,
    redact_properties(properties, node_type) AS properties,
    attrs,
    created_at,
    updated_at,
    archived_at
FROM nodes;
