-- Category vocabulary: what kinds of things live here, and what each means.
--
-- Implements contracts/category-vocabulary.md. A category is a node type.
-- Edge and assertion types appear only as the relationships a node type takes
-- part in. Nothing new is stored: descriptions are ordinary assertions on a
-- node that stands for the category, so a person can change what a type means
-- here and the next read shows the new words.

SET search_path = rye, pg_catalog, public;

CREATE INDEX IF NOT EXISTS idx_nodes_category_active
    ON nodes (external_source, external_id)
    WHERE node_type = 'category' AND archived_at IS NULL;

-- --------------------------------------------------------------------------
-- Read surface
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION rye_categories(
    p_scope_id uuid DEFAULT NULL
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
WITH active_scopes AS (
    SELECT n.id
    FROM nodes n
    JOIN current_valid_assertions status
      ON status.subject_node_id = n.id
     AND status.assertion_type = 'scope_status'
     AND status.assertion_key = 'default'
     AND status.claim->>'status' = 'active'
    WHERE n.archived_at IS NULL
      AND n.node_type = 'onboarding_scope'
),
active_count AS (
    SELECT count(*) AS scopes FROM active_scopes
),
-- Scope selection mirrors rye_agent_context() exactly.
selected AS (
    SELECT
        CASE
            WHEN p_scope_id IS NOT NULL THEN p_scope_id
            WHEN (SELECT scopes FROM active_count) = 1 THEN (SELECT id FROM active_scopes LIMIT 1)
            ELSE NULL::uuid
        END AS scope_id,
        CASE
            WHEN p_scope_id IS NOT NULL THEN 'explicit'
            WHEN (SELECT scopes FROM active_count) = 0 THEN 'none'
            WHEN (SELECT scopes FROM active_count) = 1 THEN 'single_active'
            ELSE 'multiple_active'
        END AS mode
),
scope_node AS (
    SELECT n.id, n.external_id AS scope_key, n.label
    FROM nodes n
    WHERE n.id = (SELECT scope_id FROM selected)
      AND n.archived_at IS NULL
      AND n.node_type = 'onboarding_scope'
),
-- An unknown or archived p_scope_id is not an error: it answers empty.
resolution AS (
    SELECT
        (SELECT id FROM scope_node) AS scope_id,
        EXISTS (SELECT 1 FROM scope_node) AS scope_found,
        (p_scope_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM scope_node)) AS unresolved
),
type_policy AS (
    SELECT a.claim->'types' AS types
    FROM current_valid_assertions a
    WHERE a.subject_node_id = (SELECT scope_id FROM resolution)
      AND a.assertion_type = 'allowed_node_types'
      AND a.assertion_key = 'default'
    ORDER BY a.asserted_at DESC, a.id
    LIMIT 1
),
allowed_types AS (
    SELECT DISTINCT t.value AS name
    FROM type_policy tp
    CROSS JOIN LATERAL jsonb_array_elements_text(
        CASE WHEN jsonb_typeof(tp.types) = 'array' THEN tp.types ELSE '[]'::jsonb END
    ) AS t(value)
    WHERE NOT (SELECT unresolved FROM resolution)
),
-- Types in use. RLS-hidden rows are simply absent, never reported.
present AS (
    SELECT n.node_type AS name, count(*)::bigint AS usage_count
    FROM nodes n
    WHERE n.archived_at IS NULL
      AND NOT (SELECT unresolved FROM resolution)
    GROUP BY n.node_type
),
-- With a scope, the plugins it enables; unscoped, every catalogued plugin.
plugins_in_play AS (
    SELECT
        p.external_id AS plugin_id,
        coalesce(
            p.properties->'contributes',
            p.properties->'manifest'->'contributes',
            '{}'::jsonb
        ) AS contributes
    FROM nodes p
    WHERE p.archived_at IS NULL
      AND p.node_type = 'plugin'
      AND p.external_source = 'rye_plugin'
      AND NOT (SELECT unresolved FROM resolution)
      AND (
          (SELECT scope_id FROM resolution) IS NULL
          OR EXISTS (
              SELECT 1
              FROM edges e
              WHERE e.edge_type = 'scope_enables_plugin'
                AND e.source_id = (SELECT scope_id FROM resolution)
                AND e.target_id = p.id
                AND e.archived_at IS NULL
          )
      )
),
declared AS (
    SELECT DISTINCT t.value AS name, pl.plugin_id
    FROM plugins_in_play pl
    CROSS JOIN LATERAL jsonb_array_elements_text(
        CASE
            WHEN jsonb_typeof(pl.contributes->'node_types') = 'array'
                THEN pl.contributes->'node_types'
            ELSE '[]'::jsonb
        END
    ) AS t(value)
),
names AS (
    SELECT name FROM present
    UNION
    SELECT name FROM declared
    UNION
    SELECT name FROM allowed_types
),
-- Properties are observed from the rows themselves; no schema registry exists.
observed AS (
    SELECT n.node_type AS name, k.key AS key, count(*)::bigint AS cnt
    FROM nodes n
    CROSS JOIN LATERAL jsonb_object_keys(
        CASE WHEN jsonb_typeof(n.properties) = 'object' THEN n.properties ELSE '{}'::jsonb END
    ) AS k(key)
    WHERE n.archived_at IS NULL
      AND NOT (SELECT unresolved FROM resolution)
    GROUP BY n.node_type, k.key
),
rel_source AS (
    SELECT
        s.node_type AS name,
        e.edge_type,
        count(*)::bigint AS cnt,
        jsonb_agg(DISTINCT t.node_type) AS other_types
    FROM edges e
    JOIN nodes s ON s.id = e.source_id AND s.archived_at IS NULL
    JOIN nodes t ON t.id = e.target_id AND t.archived_at IS NULL
    WHERE e.archived_at IS NULL
      AND NOT (SELECT unresolved FROM resolution)
    GROUP BY s.node_type, e.edge_type
),
rel_target AS (
    SELECT
        t.node_type AS name,
        e.edge_type,
        count(*)::bigint AS cnt,
        jsonb_agg(DISTINCT s.node_type) AS other_types
    FROM edges e
    JOIN nodes s ON s.id = e.source_id AND s.archived_at IS NULL
    JOIN nodes t ON t.id = e.target_id AND t.archived_at IS NULL
    WHERE e.archived_at IS NULL
      AND NOT (SELECT unresolved FROM resolution)
    GROUP BY t.node_type, e.edge_type
),
category_nodes AS (
    SELECT c.id, c.external_id AS name
    FROM nodes c
    WHERE c.archived_at IS NULL
      AND c.node_type = 'category'
      AND c.external_source = 'rye_category'
      AND c.external_id IS NOT NULL
),
-- Scope key first, then the org-wide default. current_valid_assertions only,
-- so a candidate description stays invisible until someone accepts it.
descriptions AS (
    SELECT DISTINCT ON (cn.name)
        cn.name,
        cn.id AS category_node_id,
        a.id AS assertion_id,
        a.assertion_key,
        a.asserted_at,
        a.claim->>'description' AS description
    FROM category_nodes cn
    JOIN current_valid_assertions a
      ON a.subject_node_id = cn.id
     AND a.assertion_type = 'category_description'
    WHERE a.assertion_key = 'default'
       OR a.assertion_key = (SELECT scope_id FROM resolution)::text
    ORDER BY
        cn.name,
        CASE WHEN a.assertion_key = (SELECT scope_id FROM resolution)::text THEN 0 ELSE 1 END,
        a.asserted_at DESC,
        a.id
),
category_rows AS (
    SELECT
        nm.name,
        coalesce(pr.usage_count, 0::bigint) AS usage_count,
        d.category_node_id,
        d.assertion_id,
        d.assertion_key,
        d.asserted_at,
        d.description
    FROM names nm
    LEFT JOIN present pr ON pr.name = nm.name
    LEFT JOIN descriptions d ON d.name = nm.name
),
built AS (
    SELECT
        cr.name,
        cr.usage_count,
        jsonb_build_object(
            'name', cr.name,
            'kind', 'node_type',
            'description', cr.description,
            'description_source', CASE
                WHEN cr.assertion_id IS NULL THEN NULL::jsonb
                ELSE jsonb_build_object(
                    'category_node_id', cr.category_node_id,
                    'assertion_id', cr.assertion_id,
                    'assertion_key', cr.assertion_key,
                    'asserted_at', cr.asserted_at
                )
            END,
            'properties', jsonb_build_object(
                'observed', coalesce((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'key', o.key,
                            'count', o.cnt,
                            'frequency', round(o.cnt::numeric / cr.usage_count, 3)
                        )
                        ORDER BY o.cnt DESC, o.key
                    )
                    FROM observed o
                    WHERE o.name = cr.name
                ), '[]'::jsonb),
                'required', '[]'::jsonb,
                'required_source', 'none'
            ),
            'relationships', jsonb_build_object(
                'as_source', coalesce((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'edge_type', r.edge_type,
                            'other_types', r.other_types,
                            'count', r.cnt
                        )
                        ORDER BY r.cnt DESC, r.edge_type
                    )
                    FROM rel_source r
                    WHERE r.name = cr.name
                ), '[]'::jsonb),
                'as_target', coalesce((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'edge_type', r.edge_type,
                            'other_types', r.other_types,
                            'count', r.cnt
                        )
                        ORDER BY r.cnt DESC, r.edge_type
                    )
                    FROM rel_target r
                    WHERE r.name = cr.name
                ), '[]'::jsonb)
            ),
            'enabled', CASE
                WHEN (SELECT scope_id FROM resolution) IS NULL THEN 'unscoped'
                WHEN EXISTS (SELECT 1 FROM allowed_types al WHERE al.name = cr.name) THEN 'on'
                ELSE 'off'
            END,
            'usage_count', cr.usage_count,
            'declared_by', coalesce((
                SELECT jsonb_agg(dd.plugin_id ORDER BY dd.plugin_id)
                FROM declared dd
                WHERE dd.name = cr.name
            ), '[]'::jsonb)
        ) AS category
    FROM category_rows cr
)
SELECT jsonb_build_object(
    'contract_version', 1,
    'categories', coalesce(
        (SELECT jsonb_agg(b.category ORDER BY b.usage_count DESC, b.name) FROM built b),
        '[]'::jsonb
    ),
    'category_count', (SELECT count(*) FROM built),
    'empty', (SELECT count(*) = 0 FROM built),
    'scope', jsonb_build_object(
        'requested_scope_id', p_scope_id,
        'scope_id', (SELECT scope_id FROM resolution),
        'scope_found', (SELECT scope_found FROM resolution),
        'scope_key', (SELECT scope_key FROM scope_node),
        'label', (SELECT label FROM scope_node),
        'mode', (SELECT mode FROM selected),
        'type_policy', CASE
            WHEN EXISTS (SELECT 1 FROM type_policy) THEN 'present'
            ELSE 'missing'
        END
    )
);
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION rye_categories(uuid) IS
    'Every category (node type) in the selected scope with its description in the organization''s words, observed properties, the relationships it takes part in, whether it is on or off here, its usage count, and the plugins that declare it. Contract: contracts/category-vocabulary.md (contract_version 1). Membership with a scope is types in use, types the scope''s enabled plugins declare, and names in its allowed_node_types; unscoped it is types in use plus every catalogued plugin''s. Categories that are off are listed as off, never omitted. An unknown or archived scope answers empty rather than raising. declared_by lists only the plugins in play for this answer. Reads honor RLS: hidden rows are absent from counts, not reported.';

-- --------------------------------------------------------------------------
-- Write surface
-- --------------------------------------------------------------------------

-- Say what a category means here. Creates the node that stands for the
-- category on first use, then records an ordinary assertion on it, so the
-- scope's review policy decides whether the words are visible immediately or
-- wait for a person.
CREATE OR REPLACE FUNCTION describe_category(
    p_node_type text,
    p_description text,
    p_scope_id uuid DEFAULT NULL,
    p_actor text DEFAULT NULL,
    p_basis text DEFAULT 'reported',
    p_evidence jsonb[] DEFAULT NULL,
    p_confidence numeric DEFAULT 1.0
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_actor text;
    v_assertion_id uuid;
    v_assertion_key text;
    v_category_node_id uuid;
    v_description text;
    v_evidence jsonb[];
    v_event_id uuid;
    v_node_type text;
    v_participant_ids uuid[];
    v_participant_roles text[];
BEGIN
    v_node_type := nullif(trim(p_node_type), '');
    v_description := nullif(trim(p_description), '');
    v_actor := coalesce(p_actor, current_setting('app.current_user_id', true));

    IF v_node_type IS NULL THEN
        RAISE EXCEPTION 'node_type is required';
    END IF;

    IF v_description IS NULL THEN
        RAISE EXCEPTION 'description is required';
    END IF;

    IF p_scope_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = p_scope_id
          AND node_type = 'onboarding_scope'
          AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Onboarding scope % not found', p_scope_id;
    END IF;

    -- Aliases resolve to the spelling the graph actually stores.
    v_node_type := canonical_type_in_scope('node_type', v_node_type, p_scope_id);
    v_assertion_key := coalesce(p_scope_id::text, 'default');

    INSERT INTO nodes (node_type, label, external_id, external_source, properties, attrs)
    VALUES (
        'category',
        v_node_type,
        v_node_type,
        'rye_category',
        jsonb_build_object('category_kind', 'node_type', 'node_type', v_node_type),
        jsonb_build_object('created_by', v_actor)
    )
    ON CONFLICT (external_source, external_id)
        WHERE external_id IS NOT NULL AND archived_at IS NULL
    DO UPDATE
        SET properties = nodes.properties || EXCLUDED.properties,
            updated_at = now()
    RETURNING id INTO v_category_node_id;

    v_participant_ids := ARRAY[v_category_node_id];
    v_participant_roles := ARRAY['category'];
    IF p_scope_id IS NOT NULL THEN
        v_participant_ids := v_participant_ids || p_scope_id;
        v_participant_roles := v_participant_roles || 'scope'::text;
    END IF;

    v_event_id := record_event(
        p_event_type        := 'category_described',
        p_summary           := format('Category described: %s', v_node_type),
        p_properties        := jsonb_build_object(
            'node_type', v_node_type,
            'category_node_id', v_category_node_id,
            'scope_id', p_scope_id,
            'assertion_key', v_assertion_key
        ),
        p_participant_ids   := v_participant_ids,
        p_participant_roles := v_participant_roles,
        p_actor             := v_actor
    );

    v_evidence := coalesce(
        p_evidence,
        ARRAY[jsonb_build_object('kind', 'source', 'event_id', v_event_id)]
    );

    v_assertion_id := record_assertion(
        p_assertion_type  := 'category_description',
        p_assertion_key   := v_assertion_key,
        p_subject_node_id := v_category_node_id,
        p_claim           := jsonb_build_object('description', v_description),
        p_evidence        := v_evidence,
        p_basis           := p_basis,
        p_confidence      := p_confidence,
        p_attrs           := jsonb_build_object(
            'category_event_id', v_event_id,
            'node_type', v_node_type,
            'scope_id', p_scope_id
        ),
        p_scope_node_id   := p_scope_id
    );

    RETURN v_assertion_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION describe_category(text, text, uuid, text, text, jsonb[], numeric) IS
    'Record what a node type means in this organization''s words. Creates the node that stands for the category on first use (node_type ''category'', external_source ''rye_category'', external_id the type name) and records a category_description assertion on it, keyed by the scope uuid as text or ''default'' for the org-wide fallback. Goes through record_event and record_assertion, so the scope''s review policy applies: under a reviewing policy the words land as a candidate and rye_categories() keeps showing the previous description until someone accepts. Corrections are new assertions; nothing is updated in place.';
