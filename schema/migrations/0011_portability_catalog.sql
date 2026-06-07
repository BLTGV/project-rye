-- Portable catalogs for agents and CLI discovery.
--
-- This migration keeps portability metadata in the existing Rye graph. Plugin
-- and skill manifests are synced into nodes/assertions by the install script.

SET search_path = rye, pg_catalog, public;

CREATE INDEX IF NOT EXISTS idx_nodes_skill_active
    ON nodes (external_source, external_id)
    WHERE node_type = 'skill' AND archived_at IS NULL;

CREATE OR REPLACE FUNCTION rye_jsonb_array_length(p_value jsonb) RETURNS int
SET search_path = rye, pg_catalog
AS $$
    SELECT CASE
        WHEN jsonb_typeof(p_value) = 'array' THEN jsonb_array_length(p_value)
        ELSE 0
    END;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION rye_plugin_catalog() RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
WITH plugin_rows AS (
    SELECT
        p.id,
        p.external_id AS plugin_id,
        p.label,
        p.properties,
        coalesce(p.properties->'manifest', '{}'::jsonb) AS manifest,
        coalesce(p.properties->'contributes', p.properties->'manifest'->'contributes', '{}'::jsonb) AS contributes,
        coalesce(p.properties->'capabilities', p.properties->'manifest'->'capabilities', '[]'::jsonb) AS capabilities
    FROM nodes p
    WHERE p.archived_at IS NULL
      AND p.node_type = 'plugin'
      AND p.external_source = 'rye_plugin'
),
normalized AS (
    SELECT
        id,
        plugin_id,
        label,
        properties,
        manifest,
        contributes,
        CASE WHEN jsonb_typeof(capabilities) = 'array' THEN capabilities ELSE '[]'::jsonb END AS capabilities
    FROM plugin_rows
)
SELECT jsonb_build_object(
    'plugins', coalesce((
        SELECT jsonb_agg(
            jsonb_build_object(
                'node_id', id,
                'plugin_id', plugin_id,
                'label', label,
                'version', coalesce(properties->>'version', manifest->>'version'),
                'description', coalesce(properties->>'description', manifest->>'description'),
                'dependencies', coalesce(manifest->'dependencies', '[]'::jsonb),
                'contributes', contributes,
                'onboarding', coalesce(properties->'onboarding', manifest->'onboarding', '{}'::jsonb),
                'validation', coalesce(properties->'validation', manifest->'validation', '{}'::jsonb),
                'admin', coalesce(properties->'admin', manifest->'admin', '{}'::jsonb),
                'capabilities', capabilities,
                'metadata_source', properties->>'metadata_source'
            )
            ORDER BY plugin_id
        )
        FROM normalized
    ), '[]'::jsonb),
    'totals', (
        SELECT jsonb_build_object(
            'plugins', count(*),
            'capabilities', coalesce(sum(rye_jsonb_array_length(capabilities)), 0),
            'node_types', coalesce(sum(rye_jsonb_array_length(contributes->'node_types')), 0),
            'edge_types', coalesce(sum(rye_jsonb_array_length(contributes->'edge_types')), 0),
            'assertion_types', coalesce(sum(rye_jsonb_array_length(contributes->'assertion_types')), 0),
            'event_types', coalesce(sum(rye_jsonb_array_length(contributes->'event_types')), 0),
            'artifact_types', coalesce(sum(rye_jsonb_array_length(contributes->'artifact_types')), 0)
        )
        FROM normalized
    )
);
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION rye_skill_catalog() RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
WITH skill_rows AS (
    SELECT
        s.id,
        s.external_id AS skill_id,
        s.label,
        s.properties,
        coalesce(s.properties->'manifest', '{}'::jsonb) AS manifest,
        coalesce(s.properties->'capabilities', s.properties->'manifest'->'capabilities', '[]'::jsonb) AS capabilities
    FROM nodes s
    WHERE s.archived_at IS NULL
      AND s.node_type = 'skill'
      AND s.external_source = 'rye_skill'
),
normalized AS (
    SELECT
        id,
        skill_id,
        label,
        properties,
        manifest,
        CASE WHEN jsonb_typeof(capabilities) = 'array' THEN capabilities ELSE '[]'::jsonb END AS capabilities
    FROM skill_rows
)
SELECT jsonb_build_object(
    'skills', coalesce((
        SELECT jsonb_agg(
            jsonb_build_object(
                'node_id', id,
                'skill_id', skill_id,
                'label', label,
                'version', coalesce(properties->>'version', manifest->>'version'),
                'description', coalesce(properties->>'description', manifest->>'description'),
                'source', coalesce(properties->'source', manifest->'source', '{}'::jsonb),
                'install', coalesce(properties->'install', manifest->'install', '{}'::jsonb),
                'requires', coalesce(properties->'requires', manifest->'requires', '{}'::jsonb),
                'capabilities', capabilities,
                'metadata_source', properties->>'metadata_source'
            )
            ORDER BY skill_id
        )
        FROM normalized
    ), '[]'::jsonb),
    'totals', (
        SELECT jsonb_build_object(
            'skills', count(*),
            'capabilities', coalesce(sum(rye_jsonb_array_length(capabilities)), 0)
        )
        FROM normalized
    )
);
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION rye_capability_catalog() RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
WITH carriers AS (
    SELECT
        n.node_type AS source_kind,
        n.external_id AS source_id,
        n.label AS source_label,
        CASE
            WHEN jsonb_typeof(coalesce(n.properties->'capabilities', n.properties->'manifest'->'capabilities')) = 'array'
                THEN coalesce(n.properties->'capabilities', n.properties->'manifest'->'capabilities')
            ELSE '[]'::jsonb
        END AS capabilities
    FROM nodes n
    WHERE n.archived_at IS NULL
      AND (
        (n.node_type = 'plugin' AND n.external_source = 'rye_plugin')
        OR (n.node_type = 'skill' AND n.external_source = 'rye_skill')
      )
),
capability_rows AS (
    SELECT
        c.source_kind,
        c.source_id,
        c.source_label,
        capability AS capability
    FROM carriers c
    CROSS JOIN LATERAL jsonb_array_elements(c.capabilities) AS capability
)
SELECT jsonb_build_object(
    'capabilities', coalesce((
        SELECT jsonb_agg(
            jsonb_build_object(
                'source_kind', source_kind,
                'source_id', source_id,
                'source_label', source_label,
                'id', capability->>'id',
                'label', capability->>'label',
                'kind', capability->>'kind',
                'description', capability->>'description',
                'read_only', coalesce((capability->>'read_only')::boolean, false),
                'requires', coalesce(capability->'requires', '{}'::jsonb),
                'entrypoints', coalesce(capability->'entrypoints', '[]'::jsonb)
            )
            ORDER BY source_kind, source_id, capability->>'id'
        )
        FROM capability_rows
    ), '[]'::jsonb),
    'totals', (
        SELECT jsonb_build_object(
            'capabilities', count(*),
            'read_only', count(*) FILTER (WHERE coalesce((capability->>'read_only')::boolean, false)),
            'write_capable', count(*) FILTER (WHERE NOT coalesce((capability->>'read_only')::boolean, false))
        )
        FROM capability_rows
    )
);
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION rye_source_inventory() RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.node_type, q.label), '[]'::jsonb)
FROM (
    SELECT
        n.id,
        n.node_type,
        n.label,
        n.external_source,
        n.external_id,
        n.properties->>'confirmation_status' AS confirmation_status,
        n.properties->>'source_account_id' AS source_account_id,
        count(e.id) FILTER (
            WHERE e.edge_type = 'contains_item'
              AND child.node_type = 'source_item'
        ) AS source_item_count,
        n.properties
    FROM nodes n
    LEFT JOIN edges e ON e.source_id = n.id AND e.archived_at IS NULL
    LEFT JOIN nodes child ON child.id = e.target_id AND child.archived_at IS NULL
    WHERE n.archived_at IS NULL
      AND n.node_type IN ('source_account', 'source_container')
    GROUP BY n.id
) q;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION rye_pending_context_confirmations() RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.node_type, q.label), '[]'::jsonb)
FROM (
    SELECT id, node_type, label, external_source, external_id, properties
    FROM nodes
    WHERE archived_at IS NULL
      AND node_type IN ('source_account', 'source_container')
      AND coalesce(
          properties->>'confirmation_status',
          properties#>>'{context_confirmation,status}',
          'needs_confirmation'
      ) = 'needs_confirmation'
) q;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION rye_agent_context(
    p_scope_id uuid DEFAULT NULL
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
WITH active_scopes AS (
    SELECT
        n.id,
        n.external_id AS scope_key,
        n.label,
        status.claim->>'status' AS status,
        purpose.claim->>'purpose' AS purpose
    FROM nodes n
    JOIN current_valid_assertions status
      ON status.subject_node_id = n.id
     AND status.assertion_type = 'scope_status'
     AND status.assertion_key = 'default'
     AND status.claim->>'status' = 'active'
    LEFT JOIN current_valid_assertions purpose
      ON purpose.subject_node_id = n.id
     AND purpose.assertion_type = 'scope_purpose'
     AND purpose.assertion_key = 'default'
    WHERE n.archived_at IS NULL
      AND n.node_type = 'onboarding_scope'
),
active_count AS (
    SELECT count(*) AS count FROM active_scopes
),
selected AS (
    SELECT
        CASE
            WHEN p_scope_id IS NOT NULL THEN p_scope_id
            WHEN (SELECT count FROM active_count) = 1 THEN (SELECT id FROM active_scopes LIMIT 1)
            ELSE NULL::uuid
        END AS scope_id,
        CASE
            WHEN p_scope_id IS NOT NULL THEN 'explicit'
            WHEN (SELECT count FROM active_count) = 0 THEN 'none'
            WHEN (SELECT count FROM active_count) = 1 THEN 'single_active'
            ELSE 'multiple_active'
        END AS mode
),
selected_scope AS (
    SELECT n.id
    FROM nodes n
    WHERE n.id = (SELECT scope_id FROM selected)
      AND n.archived_at IS NULL
      AND n.node_type = 'onboarding_scope'
)
SELECT jsonb_build_object(
    'catalog', rye_catalog(),
    'plugins', rye_plugin_catalog(),
    'skills', rye_skill_catalog(),
    'capabilities', rye_capability_catalog(),
    'source_inventory', rye_source_inventory(),
    'pending_context_confirmations', rye_pending_context_confirmations(),
    'active_scopes', coalesce((
        SELECT jsonb_agg(to_jsonb(active_scopes) ORDER BY label)
        FROM active_scopes
    ), '[]'::jsonb),
    'scope_selection', jsonb_build_object(
        'mode', (SELECT mode FROM selected),
        'selected_scope_id', (SELECT scope_id FROM selected),
        'selected_scope_found', EXISTS (SELECT 1 FROM selected_scope)
    ),
    'scope_policy', CASE
        WHEN EXISTS (SELECT 1 FROM selected_scope)
            THEN compile_scope_policy((SELECT id FROM selected_scope LIMIT 1))
        ELSE NULL
    END
);
$$ LANGUAGE sql STABLE;
