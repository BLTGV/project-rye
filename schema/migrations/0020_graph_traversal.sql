-- Graph traversal and node entry points.
--
-- Adds the agent-facing reads that were missing: find an entry node from a
-- text query, walk typed multi-hop paths, and pull a bounded neighborhood
-- subgraph with current accepted knowledge attached.
--
-- Visibility contract (design/proposals/rls-visibility-contract.md, D1):
-- every function here is SECURITY INVOKER. RLS prunes the walk to rows the
-- caller can see, and no completeness signal is emitted — a path hidden by
-- classification is indistinguishable from a path that does not exist. A
-- SECURITY DEFINER walk over arbitrary edges would be a wholesale topology
-- disclosure, so it is forbidden and conformance-tested.
--
-- These functions perform no writes. Callers who want the traversal to feed
-- node_salience call log_agent_query() themselves; auto-logging here would
-- break the read-only contract that rye-knowledge-reader depends on.

SET search_path = rye, pg_catalog, public;

-- --------------------------------------------------------------------------
-- Edge semantics
-- --------------------------------------------------------------------------
-- Registry key `edge_semantics:<edge_type>` classifies what traversing an
-- edge means. Unregistered edge types are 'associative' — the weakest reading
-- — so an unclassified vocabulary can never be mistaken for causation.
--
--   causal      one thing produced, blocked, or changed another
--   structural  composition, membership, ownership, assignment
--   associative mention, reference, topical adjacency
--   temporal    ordering without a claim of cause
--
-- This is the difference between `caused_by` and `mentioned_alongside` as a
-- filter predicate rather than a prompt instruction.

CREATE OR REPLACE FUNCTION edge_semantics(
    p_edge_type text,
    p_scope uuid DEFAULT NULL
) RETURNS text
LANGUAGE sql STABLE
SET search_path = rye, pg_catalog
AS $$
    SELECT coalesce(
        nullif(registry_value('edge_semantics:' || p_edge_type, p_scope) #>> '{}', ''),
        'associative'
    );
$$;

COMMENT ON FUNCTION edge_semantics(text, uuid) IS
'Resolves the semantic class of an edge type from registry key edge_semantics:<edge_type>. Unregistered types are associative.';

-- --------------------------------------------------------------------------
-- find_nodes — text entry point
-- --------------------------------------------------------------------------
-- Deliberately searches label and external identity only. `properties` is
-- excluded because field_classifications redacts individual property paths
-- (redact_properties / nodes_secure); matching on a raw property value would
-- let a caller confirm the contents of a field it is not allowed to read.
--
-- Fuzzy matching is trigram-only. It catches spacing and spelling drift
-- ("Acme Corp" / "Acme Corporation") but not synonyms or paraphrase; that is
-- what an optional semantic index would add later.

CREATE OR REPLACE FUNCTION find_nodes(
    p_query text,
    p_node_types text[] DEFAULT NULL,
    p_limit int DEFAULT 20,
    p_scope uuid DEFAULT NULL
) RETURNS TABLE (
    node_id uuid,
    node_type text,
    label text,
    score numeric,
    match_reason text
)
LANGUAGE sql STABLE
-- public is on the path because pg_trgm's similarity()/% live in the
-- extension schema, as they do for capture_domain_change().
SET search_path = rye, pg_catalog, public
AS $$
    WITH q AS (
        SELECT
            nullif(btrim(p_query), '') AS text,
            -- Floors at the pg_trgm.similarity_threshold GUC (0.3 by default):
            -- the `%` operator is what makes the GIN index usable, so a lower
            -- registry value cannot widen recall below it.
            greatest(
                coalesce((registry_value('node_search_threshold', p_scope) #>> '{}')::numeric, 0.35),
                0.3
            ) AS threshold,
            greatest(coalesce(p_limit, 20), 1) AS lim
    ),
    matches AS (
        SELECT n.id, n.node_type, n.label, 1.00::numeric AS score, 'external_id' AS reason
        FROM nodes n, q
        WHERE q.text IS NOT NULL
          AND n.archived_at IS NULL
          AND (p_node_types IS NULL OR n.node_type = ANY(p_node_types))
          AND n.external_id = q.text

        UNION ALL

        SELECT n.id, n.node_type, n.label, 0.95::numeric, 'exact_label'
        FROM nodes n, q
        WHERE q.text IS NOT NULL
          AND n.archived_at IS NULL
          AND (p_node_types IS NULL OR n.node_type = ANY(p_node_types))
          AND lower(n.label) = lower(q.text)

        UNION ALL

        SELECT n.id, n.node_type, n.label,
               round((similarity(n.label, q.text) * 0.9)::numeric, 4), 'label_similarity'
        FROM nodes n, q
        WHERE q.text IS NOT NULL
          AND n.archived_at IS NULL
          AND (p_node_types IS NULL OR n.node_type = ANY(p_node_types))
          AND n.label IS NOT NULL
          AND n.label % q.text
          AND similarity(n.label, q.text) >= q.threshold

        UNION ALL

        SELECT n.id, n.node_type, n.label, 0.40::numeric, 'label_contains'
        FROM nodes n, q
        WHERE q.text IS NOT NULL
          AND n.archived_at IS NULL
          AND (p_node_types IS NULL OR n.node_type = ANY(p_node_types))
          AND n.label ILIKE '%' || q.text || '%'
    ),
    best AS (
        SELECT DISTINCT ON (m.id)
               m.id, m.node_type, m.label, m.score, m.reason
        FROM matches m
        ORDER BY m.id, m.score DESC, m.reason
    )
    SELECT b.id, b.node_type, b.label, b.score, b.reason
    FROM best b, q
    ORDER BY b.score DESC, b.label NULLS LAST, b.id
    LIMIT (SELECT lim FROM q);
$$;

COMMENT ON FUNCTION find_nodes(text, text[], int, uuid) IS
'Ranked node lookup by label and external identity. Searches no property values because field-level redaction applies to them.';

-- --------------------------------------------------------------------------
-- find_paths — bounded multi-hop traversal
-- --------------------------------------------------------------------------
-- Depth is capped by registry key `max_path_depth` (core default 3). A caller
-- may ask for less; it cannot ask for more. Most connection questions resolve
-- in two or three hops, and greedy traversal is the cost failure mode.
--
-- Edges are temporal: an edge participates only if it is live at p_as_of,
-- so a past as_of reconstructs historical connectivity the same way
-- assertions_as_of reconstructs historical belief.
--
-- p_direction defaults to 'out' because an edge asserts something in its
-- direction; 'any' is available for undirected connectivity questions but
-- must not be used for causal reasoning.

CREATE OR REPLACE FUNCTION find_paths(
    p_from_node_id uuid,
    p_to_node_id uuid DEFAULT NULL,
    p_max_depth int DEFAULT NULL,
    p_edge_types text[] DEFAULT NULL,
    p_semantics text[] DEFAULT NULL,
    p_as_of timestamptz DEFAULT NULL,
    p_direction text DEFAULT 'out',
    p_max_paths int DEFAULT 50,
    p_scope uuid DEFAULT NULL
) RETURNS TABLE (
    node_path uuid[],
    edge_path uuid[],
    edge_type_path text[],
    depth int,
    path_weight numeric
)
LANGUAGE sql STABLE
SET search_path = rye, pg_catalog
AS $$
    WITH RECURSIVE params AS (
        SELECT
            least(
                coalesce(p_max_depth, coalesce((registry_value('max_path_depth', p_scope) #>> '{}')::int, 3)),
                coalesce((registry_value('max_path_depth', p_scope) #>> '{}')::int, 3)
            ) AS max_depth,
            coalesce(p_as_of, now()) AS as_of,
            greatest(coalesce(p_max_paths, 50), 1) AS max_paths,
            lower(coalesce(nullif(btrim(p_direction), ''), 'out')) AS direction
    ),
    sem AS (
        -- Only evaluated when semantic filtering is requested.
        SELECT DISTINCT e.edge_type
        FROM edges e
        WHERE p_semantics IS NOT NULL
          AND e.archived_at IS NULL
          AND edge_semantics(e.edge_type, p_scope) = ANY(p_semantics)
    ),
    walk AS (
        SELECT
            ARRAY[n.id]::uuid[]  AS node_path,
            ARRAY[]::uuid[]      AS edge_path,
            ARRAY[]::text[]      AS edge_type_path,
            0                    AS depth,
            1.0::numeric         AS path_weight,
            n.id                 AS node_id
        FROM nodes n
        WHERE n.id = p_from_node_id
          AND n.archived_at IS NULL

        UNION ALL

        SELECT
            w.node_path      || tgt.id,
            w.edge_path      || e.id,
            w.edge_type_path || e.edge_type,
            w.depth + 1,
            w.path_weight * coalesce(e.weight, 1.0),
            tgt.id
        FROM walk w
        CROSS JOIN params p
        JOIN edges e
          ON CASE p.direction
                 WHEN 'out' THEN e.source_id = w.node_id
                 WHEN 'in'  THEN e.target_id = w.node_id
                 ELSE (e.source_id = w.node_id OR e.target_id = w.node_id)
             END
        JOIN nodes tgt
          ON tgt.id = CASE WHEN e.source_id = w.node_id THEN e.target_id ELSE e.source_id END
        WHERE w.depth < p.max_depth
          AND e.archived_at IS NULL
          AND tgt.archived_at IS NULL
          AND (e.effective_from IS NULL OR e.effective_from <= p.as_of)
          AND (e.effective_to   IS NULL OR e.effective_to   >  p.as_of)
          AND (p_edge_types IS NULL OR e.edge_type = ANY(p_edge_types))
          AND (p_semantics  IS NULL OR e.edge_type IN (SELECT s.edge_type FROM sem s))
          AND NOT tgt.id = ANY(w.node_path)
    )
    SELECT w.node_path, w.edge_path, w.edge_type_path, w.depth, w.path_weight
    FROM walk w
    WHERE w.depth > 0
      AND (p_to_node_id IS NULL OR w.node_id = p_to_node_id)
    ORDER BY w.depth, w.path_weight DESC, w.node_path
    LIMIT (SELECT max_paths FROM params);
$$;

COMMENT ON FUNCTION find_paths(uuid, uuid, int, text[], text[], timestamptz, text, int, uuid) IS
'Bounded typed multi-hop traversal. SECURITY INVOKER: RLS prunes the walk and no completeness signal is emitted. Depth capped by registry max_path_depth.';

-- --------------------------------------------------------------------------
-- neighborhood — bounded subgraph with current knowledge
-- --------------------------------------------------------------------------
-- What an agent actually needs to answer a "why" question: the nodes within
-- N hops, the edges among them, and each node's current accepted assertions,
-- all under an explicit budget.
--
-- The `truncated` flag reports that the p_max_nodes budget was hit. It is NOT
-- an RLS completeness signal — invisible nodes are pruned silently and are
-- never counted (rls-visibility-contract.md D1).

CREATE OR REPLACE FUNCTION neighborhood(
    p_node_id uuid,
    p_max_depth int DEFAULT 2,
    p_edge_types text[] DEFAULT NULL,
    p_semantics text[] DEFAULT NULL,
    p_as_of timestamptz DEFAULT NULL,
    p_direction text DEFAULT 'any',
    p_max_nodes int DEFAULT 100,
    p_max_assertions_per_node int DEFAULT 10,
    p_scope uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = rye, pg_catalog
AS $$
    WITH RECURSIVE params AS (
        SELECT
            least(
                coalesce(p_max_depth, 2),
                coalesce((registry_value('max_path_depth', p_scope) #>> '{}')::int, 3)
            ) AS max_depth,
            coalesce(p_as_of, now()) AS as_of,
            greatest(coalesce(p_max_nodes, 100), 1) AS max_nodes,
            greatest(coalesce(p_max_assertions_per_node, 10), 1) AS max_assertions,
            lower(coalesce(nullif(btrim(p_direction), ''), 'any')) AS direction
    ),
    sem AS (
        SELECT DISTINCT e.edge_type
        FROM edges e
        WHERE p_semantics IS NOT NULL
          AND e.archived_at IS NULL
          AND edge_semantics(e.edge_type, p_scope) = ANY(p_semantics)
    ),
    walk AS (
        SELECT n.id AS node_id, 0 AS depth, ARRAY[n.id]::uuid[] AS seen
        FROM nodes n
        WHERE n.id = p_node_id
          AND n.archived_at IS NULL

        UNION ALL

        SELECT tgt.id, w.depth + 1, w.seen || tgt.id
        FROM walk w
        CROSS JOIN params p
        JOIN edges e
          ON CASE p.direction
                 WHEN 'out' THEN e.source_id = w.node_id
                 WHEN 'in'  THEN e.target_id = w.node_id
                 ELSE (e.source_id = w.node_id OR e.target_id = w.node_id)
             END
        JOIN nodes tgt
          ON tgt.id = CASE WHEN e.source_id = w.node_id THEN e.target_id ELSE e.source_id END
        WHERE w.depth < p.max_depth
          AND e.archived_at IS NULL
          AND tgt.archived_at IS NULL
          AND (e.effective_from IS NULL OR e.effective_from <= p.as_of)
          AND (e.effective_to   IS NULL OR e.effective_to   >  p.as_of)
          AND (p_edge_types IS NULL OR e.edge_type = ANY(p_edge_types))
          AND (p_semantics  IS NULL OR e.edge_type IN (SELECT s.edge_type FROM sem s))
          AND NOT tgt.id = ANY(w.seen)
    ),
    ranked AS (
        SELECT w.node_id, min(w.depth) AS depth
        FROM walk w
        GROUP BY w.node_id
    ),
    kept AS (
        SELECT r.node_id, r.depth
        FROM ranked r
        ORDER BY r.depth, r.node_id
        LIMIT (SELECT max_nodes FROM params)
    ),
    node_json AS (
        SELECT jsonb_agg(
                   jsonb_build_object(
                       'node_id',    n.id,
                       'node_type',  n.node_type,
                       'label',      n.label,
                       'depth',      k.depth,
                       'properties', redact_properties(n.properties, n.node_type),
                       'assertions', coalesce(a.items, '[]'::jsonb)
                   )
                   ORDER BY k.depth, n.label NULLS LAST, n.id
               ) AS items
        FROM kept k
        JOIN nodes n ON n.id = k.node_id
        LEFT JOIN LATERAL (
            SELECT jsonb_agg(
                       jsonb_build_object(
                           'assertion_id',   c.id,
                           'assertion_type', c.assertion_type,
                           'assertion_key',  c.assertion_key,
                           'basis',          c.basis,
                           'claim',          c.claim,
                           'asserted_at',    c.asserted_at
                       )
                       ORDER BY c.asserted_at DESC
                   ) AS items
            FROM (
                SELECT cva.*
                FROM current_valid_assertions cva
                WHERE cva.subject_node_id = n.id
                ORDER BY cva.asserted_at DESC
                LIMIT (SELECT max_assertions FROM params)
            ) c
        ) a ON true
    ),
    edge_json AS (
        SELECT jsonb_agg(
                   jsonb_build_object(
                       'edge_id',   e.id,
                       'edge_type', e.edge_type,
                       'semantics', edge_semantics(e.edge_type, p_scope),
                       'source_id', e.source_id,
                       'target_id', e.target_id,
                       'weight',    e.weight
                   )
                   ORDER BY e.edge_type, e.id
               ) AS items
        FROM edges e, params p
        WHERE e.archived_at IS NULL
          AND e.source_id IN (SELECT node_id FROM kept)
          AND e.target_id IN (SELECT node_id FROM kept)
          AND (e.effective_from IS NULL OR e.effective_from <= p.as_of)
          AND (e.effective_to   IS NULL OR e.effective_to   >  p.as_of)
          AND (p_edge_types IS NULL OR e.edge_type = ANY(p_edge_types))
          AND (p_semantics  IS NULL OR e.edge_type IN (SELECT s.edge_type FROM sem s))
    )
    SELECT jsonb_build_object(
        'root',      p_node_id,
        'as_of',     (SELECT as_of FROM params),
        'max_depth', (SELECT max_depth FROM params),
        'truncated', (SELECT count(*) FROM ranked) > (SELECT max_nodes FROM params),
        'node_count', (SELECT count(*) FROM kept),
        'nodes',     coalesce((SELECT items FROM node_json), '[]'::jsonb),
        'edges',     coalesce((SELECT items FROM edge_json), '[]'::jsonb)
    );
$$;

COMMENT ON FUNCTION neighborhood(uuid, int, text[], text[], timestamptz, text, int, int, uuid) IS
'Bounded subgraph around a node with current accepted assertions attached. truncated reports the node budget only, never RLS pruning.';

-- --------------------------------------------------------------------------
-- Core registry defaults
-- --------------------------------------------------------------------------

DO $$
DECLARE
    v_core_id uuid;
    v_entry record;
BEGIN
    SELECT id INTO v_core_id
    FROM nodes
    WHERE external_source = 'rye_registry'
      AND external_id = 'core'
      AND archived_at IS NULL;

    IF v_core_id IS NULL THEN
        RAISE EXCEPTION 'Core registry node is missing; migration 0017 must run first';
    END IF;

    FOR v_entry IN
        SELECT * FROM (VALUES
            ('max_path_depth',        '3'::jsonb),
            ('node_search_threshold', '0.35'::jsonb),

            -- Core edge vocabulary. Unlisted types resolve to 'associative'.
            ('edge_semantics:blocks',          '"causal"'::jsonb),
            ('edge_semantics:triggered_by',    '"causal"'::jsonb),
            ('edge_semantics:affects',         '"causal"'::jsonb),
            ('edge_semantics:impacted',        '"causal"'::jsonb),

            ('edge_semantics:employs',         '"structural"'::jsonb),
            ('edge_semantics:assigned_to',     '"structural"'::jsonb),
            ('edge_semantics:project_member',  '"structural"'::jsonb),
            ('edge_semantics:depends_on',      '"structural"'::jsonb),
            ('edge_semantics:contains',        '"structural"'::jsonb),
            ('edge_semantics:owns',            '"structural"'::jsonb),

            ('edge_semantics:regarding',       '"associative"'::jsonb),
            ('edge_semantics:references',      '"associative"'::jsonb),
            ('edge_semantics:applied_to',      '"associative"'::jsonb),
            ('edge_semantics:targets',         '"associative"'::jsonb),
            ('edge_semantics:adjacent_to',     '"associative"'::jsonb)
        ) AS defaults(key, value)
    LOOP
        PERFORM record_assertion(
            p_assertion_type := 'registry_entry',
            p_assertion_key := v_entry.key,
            p_subject_node_id := v_core_id,
            p_claim := jsonb_build_object('value', v_entry.value, 'layer', 'core'),
            p_basis := 'assumed',
            p_status := 'accepted',
            p_attrs := jsonb_build_object('registry_layer', 'core')
        );
    END LOOP;
END;
$$;
