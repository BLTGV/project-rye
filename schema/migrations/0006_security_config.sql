-- Data-driven security: assertion type gating, role hierarchy, supporting table RLS

SET search_path = rye, pg_catalog, public;

-- ============================================================================
-- 1. ASSERTION TYPE ACCESS — Data-driven type gating
-- ============================================================================
-- Replaces the hardcoded CASE statement in assertion_read_policy and
-- assertion_insert_policy. New sensitive assertion types can be added
-- by inserting a row instead of modifying SQL policies.

CREATE TABLE IF NOT EXISTS assertion_type_access (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    assertion_type  text NOT NULL,
    operation       text NOT NULL CHECK (operation IN ('read', 'write')),
    allowed_roles   text[] NOT NULL,
    UNIQUE (assertion_type, operation)
);

-- Seed with the existing hardcoded rules
INSERT INTO assertion_type_access (assertion_type, operation, allowed_roles) VALUES
    ('financial_terms',    'read',  ARRAY['deal_manager', 'finance', 'admin']),
    ('financial_terms',    'write', ARRAY['deal_manager', 'admin']),
    ('negotiation_stance', 'read',  ARRAY['deal_manager', 'admin']),
    ('compensation',       'read',  ARRAY['hr_admin', 'admin']),
    ('compensation',       'write', ARRAY['hr_admin', 'admin'])
ON CONFLICT (assertion_type, operation) DO NOTHING;

-- Rewrite assertion read policy to use the table
DROP POLICY IF EXISTS assertion_read_policy ON assertions;
CREATE POLICY assertion_read_policy ON assertions
    FOR SELECT
    USING (
        (
            subject_node_id IS NULL
            OR EXISTS (SELECT 1 FROM nodes WHERE id = assertions.subject_node_id)
        )
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

-- Rewrite assertion insert policy to use the table
DROP POLICY IF EXISTS assertion_insert_policy ON assertions;
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


-- ============================================================================
-- 2. ROLE CLASSIFICATION ACCESS — Data-driven role hierarchy
-- ============================================================================
-- Replaces the hardcoded CASE in redact_properties(). New roles can be
-- added by inserting a row.

CREATE TABLE IF NOT EXISTS role_classification_access (
    role_name        text NOT NULL,
    classifications  text[] NOT NULL,
    PRIMARY KEY (role_name)
);

-- Seed with the existing hardcoded hierarchy
INSERT INTO role_classification_access (role_name, classifications) VALUES
    ('admin',        ARRAY['public', 'internal', 'confidential', 'restricted']),
    ('deal_manager', ARRAY['public', 'internal', 'confidential']),
    ('team_lead',    ARRAY['public', 'internal', 'confidential']),
    ('hr_admin',     ARRAY['public', 'internal', 'confidential']),
    ('finance',      ARRAY['public', 'internal', 'confidential']),
    ('manager',      ARRAY['public', 'internal', 'confidential']),
    ('team_member',  ARRAY['public', 'internal']),
    ('viewer',       ARRAY['public'])
ON CONFLICT (role_name) DO NOTHING;

-- Rewrite redact_properties to use the table
CREATE OR REPLACE FUNCTION redact_properties(
    p_properties jsonb,
    p_node_type text
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_result jsonb := p_properties;
    v_field record;
    v_user_role text := current_setting('app.current_role', true);
    v_role_hierarchy text[];
BEGIN
    -- Look up accessible classifications for the current role
    SELECT classifications INTO v_role_hierarchy
    FROM role_classification_access
    WHERE role_name = v_user_role;

    -- Unknown role defaults to public only
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


-- ============================================================================
-- 3. RLS ON SUPPORTING TABLES
-- ============================================================================
-- access_grants, node_source_map, and field_classifications had no RLS.
-- Add policies: admin/manager can read all; agents and viewers are restricted.

-- access_grants: only admin and the grantee can see grants
ALTER TABLE access_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE access_grants FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ag_read_policy ON access_grants;
CREATE POLICY ag_read_policy ON access_grants
    FOR SELECT
    USING (
        current_setting('app.current_role', true) IN ('admin', 'manager')
        OR grantee = current_setting('app.current_user_id', true)
        OR grantee = current_setting('app.current_role', true)
        OR grantee = ANY(coalesce(
            string_to_array(current_setting('app.current_teams', true), ','),
            ARRAY[]::text[]
        ))
    );

DROP POLICY IF EXISTS ag_insert_policy ON access_grants;
CREATE POLICY ag_insert_policy ON access_grants
    FOR INSERT
    WITH CHECK (
        current_setting('app.current_role', true) IN ('admin', 'manager')
    );

DROP POLICY IF EXISTS ag_update_policy ON access_grants;
CREATE POLICY ag_update_policy ON access_grants
    FOR UPDATE
    USING (
        current_setting('app.current_role', true) IN ('admin', 'manager')
    );

DROP POLICY IF EXISTS ag_delete_policy ON access_grants;
CREATE POLICY ag_delete_policy ON access_grants
    FOR DELETE
    USING (
        current_setting('app.current_role', true) = 'admin'
    );

-- node_source_map: visible if the linked node is visible
ALTER TABLE node_source_map ENABLE ROW LEVEL SECURITY;
ALTER TABLE node_source_map FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS nsm_read_policy ON node_source_map;
CREATE POLICY nsm_read_policy ON node_source_map
    FOR SELECT
    USING (
        EXISTS (SELECT 1 FROM nodes WHERE id = node_source_map.node_id)
    );

DROP POLICY IF EXISTS nsm_insert_policy ON node_source_map;
CREATE POLICY nsm_insert_policy ON node_source_map
    FOR INSERT
    WITH CHECK (true);

DROP POLICY IF EXISTS nsm_update_policy ON node_source_map;
CREATE POLICY nsm_update_policy ON node_source_map
    FOR UPDATE
    USING (
        EXISTS (SELECT 1 FROM nodes WHERE id = node_source_map.node_id)
    );

DROP POLICY IF EXISTS nsm_delete_policy ON node_source_map;
CREATE POLICY nsm_delete_policy ON node_source_map
    FOR DELETE
    USING (
        current_setting('app.current_role', true) IN ('admin', 'manager')
    );

-- field_classifications: admin/manager only for writes; all roles can read
-- (needed by redact_properties which is SECURITY DEFINER)
ALTER TABLE field_classifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE field_classifications FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fc_read_policy ON field_classifications;
CREATE POLICY fc_read_policy ON field_classifications
    FOR SELECT
    USING (true);

DROP POLICY IF EXISTS fc_insert_policy ON field_classifications;
CREATE POLICY fc_insert_policy ON field_classifications
    FOR INSERT
    WITH CHECK (
        current_setting('app.current_role', true) IN ('admin')
    );

DROP POLICY IF EXISTS fc_update_policy ON field_classifications;
CREATE POLICY fc_update_policy ON field_classifications
    FOR UPDATE
    USING (
        current_setting('app.current_role', true) IN ('admin')
    );

DROP POLICY IF EXISTS fc_delete_policy ON field_classifications;
CREATE POLICY fc_delete_policy ON field_classifications
    FOR DELETE
    USING (
        current_setting('app.current_role', true) IN ('admin')
    );

-- assertion_type_access: admin only for writes; all roles can read
-- (needed by RLS policies themselves)
ALTER TABLE assertion_type_access ENABLE ROW LEVEL SECURITY;
ALTER TABLE assertion_type_access FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ata_read_policy ON assertion_type_access;
CREATE POLICY ata_read_policy ON assertion_type_access
    FOR SELECT
    USING (true);

DROP POLICY IF EXISTS ata_write_policy ON assertion_type_access;
CREATE POLICY ata_write_policy ON assertion_type_access
    FOR INSERT
    WITH CHECK (
        current_setting('app.current_role', true) = 'admin'
    );

DROP POLICY IF EXISTS ata_update_policy ON assertion_type_access;
CREATE POLICY ata_update_policy ON assertion_type_access
    FOR UPDATE
    USING (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS ata_delete_policy ON assertion_type_access;
CREATE POLICY ata_delete_policy ON assertion_type_access
    FOR DELETE
    USING (current_setting('app.current_role', true) = 'admin');

-- role_classification_access: admin only for writes; all roles can read
ALTER TABLE role_classification_access ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_classification_access FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rca_read_policy ON role_classification_access;
CREATE POLICY rca_read_policy ON role_classification_access
    FOR SELECT
    USING (true);

DROP POLICY IF EXISTS rca_write_policy ON role_classification_access;
CREATE POLICY rca_write_policy ON role_classification_access
    FOR INSERT
    WITH CHECK (
        current_setting('app.current_role', true) = 'admin'
    );

DROP POLICY IF EXISTS rca_update_policy ON role_classification_access;
CREATE POLICY rca_update_policy ON role_classification_access
    FOR UPDATE
    USING (current_setting('app.current_role', true) = 'admin');

DROP POLICY IF EXISTS rca_delete_policy ON role_classification_access;
CREATE POLICY rca_delete_policy ON role_classification_access
    FOR DELETE
    USING (current_setting('app.current_role', true) = 'admin');
