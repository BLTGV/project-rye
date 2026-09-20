-- Graph traversal and node entry points.
--
-- Work item: work/013-graph-traversal.md. Ports pull request 19 (branch
-- retrieval/graph-traversal, migration 0020) onto a tree that has since
-- gained migrations 0020 to 0030. The design it implements is
-- design/proposals/rls-visibility-contract.md, D1.
--
-- Adds the agent-facing reads that were missing: find an entry node from a
-- text query, walk typed multi-hop paths, and pull a bounded neighborhood
-- subgraph with current accepted knowledge attached.
--
-- Visibility contract (design/proposals/rls-visibility-contract.md, D1):
-- every function here is SECURITY INVOKER. RLS prunes the walk to rows the
-- caller can see, and no completeness signal is emitted -- a path hidden by
-- classification is indistinguishable from a path that does not exist. A
-- SECURITY DEFINER walk over arbitrary edges would be a wholesale topology
-- disclosure, so it is forbidden and conformance-tested
-- (tests/conformance/38_graph_traversal.sql,
-- tests/security/03_traversal_visibility.sql).
--
-- These functions perform no writes. Every one is declared STABLE as well as
-- SECURITY INVOKER, which is the catalog-level half of the same promise: a
-- STABLE function cannot execute a write statement. Callers who want a
-- traversal to feed node_salience call log_agent_query() themselves;
-- auto-logging here would break the read-only contract that
-- rye-knowledge-reader depends on, and after migration 0026 it would also
-- make every one of these reads refuse for a viewer and for a session that
-- sets no role, since log_agent_query() writes an event.
--
-- Relationship to the rest of the tree as of 0030:
--   * 0026 (who may write) -- nothing here writes, so viewer and role-less
--     sessions can call all of it, and see exactly what RLS admits.
--   * 0027/0030 (review policy holds on every route) -- a demoted write
--     stays `candidate`, and reject_candidate() leaves `candidate` with
--     superseded_at set. neighborhood() reads current_valid_assertions,
--     which is `status = 'accepted' AND superseded_at IS NULL` plus the
--     effective window, so candidates, demoted rows, rejected candidates and
--     superseded incumbents are all excluded by construction.
--   * 0023/0028 (configuration settle gate) -- the registry defaults seeded
--     at the bottom are `registry_entry` assertions, which only an admin may
--     make accepted, so this migration sets app.current_role itself.

SET search_path = rye, pg_catalog, public;

-- --------------------------------------------------------------------------
-- Argument handling
-- --------------------------------------------------------------------------
-- Two rules, both of them about a caller's text never meaning more than it
-- says.
--
-- rye_like_literal() turns caller text into a LIKE pattern fragment that
-- matches itself. Without it the substring tier of find_nodes_batch() is a
-- pattern language: a query of '%' or '_' matched every visible labeled node,
-- and 'Zed_Unde_' matched the label 'Zed_Under' through the underscore rather
-- than through the text. Escape the escape character first, then the two
-- wildcards, and give the LIKE an explicit ESCAPE clause so the pattern does
-- not depend on the server's default.
--
-- rye_require_path_direction() and rye_require_edge_semantics() refuse an
-- enumerated argument they do not recognize. A CASE with an ELSE branch
-- turned an unrecognized p_direction into an undirected walk, which is the
-- one reading this file tells callers never to use for causal reasoning: an
-- unknown value widened the answer. Both are plpgsql because a RAISE needs a
-- statement; both are STABLE, so the five traversal functions stay
-- non-VOLATILE and still cannot write.

CREATE OR REPLACE FUNCTION rye_like_literal(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE SECURITY INVOKER
SET search_path = rye, pg_catalog
AS $$
    SELECT replace(replace(replace(p_text, '\', '\\'), '%', '\%'), '_', '\_');
$$;

COMMENT ON FUNCTION rye_like_literal(text) IS
'Escapes backslash, percent, and underscore so caller text used in a LIKE or ILIKE pattern matches itself. Use with an explicit ESCAPE ''\''. IMMUTABLE, SECURITY INVOKER.';

CREATE OR REPLACE FUNCTION rye_require_path_direction(p_direction text)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_direction text := lower(coalesce(nullif(btrim(p_direction), ''), 'out'));
BEGIN
    IF v_direction NOT IN ('out', 'in', 'any') THEN
        RAISE EXCEPTION
            'Unknown traversal direction %. Use out (follow the edge), in (reverse it), or any (undirected; never for causal reasoning).',
            quote_literal(p_direction)
            USING ERRCODE = '22023';
    END IF;
    RETURN v_direction;
END;
$$;

COMMENT ON FUNCTION rye_require_path_direction(text) IS
'Normalizes a traversal direction to out, in, or any, and raises 22023 on anything else. Null and blank take the out default. An unrecognized value must never fall through to the undirected walk.';

CREATE OR REPLACE FUNCTION rye_require_edge_semantics(p_semantics text[])
RETURNS text[]
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_unknown text;
BEGIN
    IF p_semantics IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT string_agg(quote_literal(s), ', ' ORDER BY s)
    INTO v_unknown
    FROM (SELECT DISTINCT unnest(p_semantics) AS s) u
    WHERE u.s IS NULL
       OR u.s NOT IN ('causal', 'structural', 'associative', 'temporal');

    IF v_unknown IS NOT NULL THEN
        RAISE EXCEPTION
            'Unknown edge semantics %. Use causal, structural, associative, or temporal.',
            v_unknown
            USING ERRCODE = '22023';
    END IF;

    RETURN p_semantics;
END;
$$;

COMMENT ON FUNCTION rye_require_edge_semantics(text[]) IS
'Returns the semantics filter unchanged, or raises 22023 naming every value that is not causal, structural, associative, or temporal. Null means no filter. A misspelled class must be a refusal, never a silently different answer.';

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
--
-- registry_value() reads current_valid_assertions under the caller's RLS, so
-- a caller who cannot see a registry entry reads 'associative' for that type.
-- Blindness is restrictive here, never permissive: an unreadable registry
-- makes causal traversal return less, never more.

CREATE OR REPLACE FUNCTION edge_semantics(
    p_edge_type text,
    p_scope uuid DEFAULT NULL
) RETURNS text
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = rye, pg_catalog
AS $$
    SELECT coalesce(
        nullif(registry_value('edge_semantics:' || p_edge_type, p_scope) #>> '{}', ''),
        'associative'
    );
$$;

COMMENT ON FUNCTION edge_semantics(text, uuid) IS
'Resolves the semantic class of an edge type from registry key edge_semantics:<edge_type>. Unregistered types are associative. STABLE, SECURITY INVOKER, writes nothing.';

-- --------------------------------------------------------------------------
-- find_nodes / find_nodes_batch — text entry points
-- --------------------------------------------------------------------------
-- These are primitives for an agent's search loop, not a search engine. The
-- agent owns semantic matching: it knows the domain vocabulary, it can
-- reformulate ("the fence company" -> "Meridian Fence"), decompose, try a
-- type filter, and judge which candidate is right. The database's job is to
-- make that loop cheap and honest, not to guess.
--
-- Three consequences for this API:
--
--   1. find_nodes_batch takes many query strings in one round trip, so N
--      reformulations cost one call rather than N.
--   2. match_reason and score are returned so the agent can judge rather than
--      trusting a rank it cannot see into.
--   3. The similarity threshold is a per-call argument, not a fixed policy.
--      The registry value is only the default.
--
-- Deliberately searches label and external identity only. `properties` is
-- excluded because field_classifications redacts individual property paths
-- (redact_properties / nodes_secure); matching on a raw property value would
-- let a caller confirm the contents of a field it is not allowed to read.
--
-- Fuzzy matching is trigram-only: it catches spacing and spelling drift, not
-- synonyms or paraphrase. Widening the threshold does not fix paraphrase —
-- reformulating the query does. That is the agent's job, which is why the
-- threshold floors rather than opening all the way down.

CREATE OR REPLACE FUNCTION find_nodes_batch(
    p_queries text[],
    p_node_types text[] DEFAULT NULL,
    p_limit_per_query int DEFAULT 20,
    p_threshold numeric DEFAULT NULL,
    p_scope uuid DEFAULT NULL
) RETURNS TABLE (
    query text,
    node_id uuid,
    node_type text,
    label text,
    score numeric,
    match_reason text
)
LANGUAGE sql STABLE SECURITY INVOKER
-- public is on the path because pg_trgm's similarity()/% live in the
-- extension schema, as they do for capture_domain_change().
SET search_path = rye, pg_catalog, public
AS $$
    WITH cfg AS (
        SELECT
            -- Per-call threshold wins; the registry value is the default.
            -- Both floor at the pg_trgm.similarity_threshold GUC (0.3 by
            -- default): the `%` operator is what keeps the GIN index usable,
            -- so a lower number cannot widen recall below it.
            greatest(
                coalesce(
                    p_threshold,
                    (registry_value('node_search_threshold', p_scope) #>> '{}')::numeric,
                    0.35
                ),
                0.3
            ) AS threshold,
            greatest(coalesce(p_limit_per_query, 20), 1) AS lim
    ),
    q AS (
        SELECT DISTINCT nullif(btrim(t), '') AS text
        FROM unnest(coalesce(p_queries, '{}'::text[])) AS t
        WHERE nullif(btrim(t), '') IS NOT NULL
    ),
    matches AS (
        SELECT q.text AS query, n.id, n.node_type, n.label,
               1.00::numeric AS score, 'external_id' AS reason
        FROM nodes n, q
        WHERE n.archived_at IS NULL
          AND (p_node_types IS NULL OR n.node_type = ANY(p_node_types))
          AND n.external_id = q.text

        UNION ALL

        SELECT q.text, n.id, n.node_type, n.label, 0.95::numeric, 'exact_label'
        FROM nodes n, q
        WHERE n.archived_at IS NULL
          AND (p_node_types IS NULL OR n.node_type = ANY(p_node_types))
          AND lower(n.label) = lower(q.text)

        UNION ALL

        SELECT q.text, n.id, n.node_type, n.label,
               round((similarity(n.label, q.text) * 0.9)::numeric, 4), 'label_similarity'
        FROM nodes n, q, cfg
        WHERE n.archived_at IS NULL
          AND (p_node_types IS NULL OR n.node_type = ANY(p_node_types))
          AND n.label IS NOT NULL
          AND n.label % q.text
          AND similarity(n.label, q.text) >= cfg.threshold

        UNION ALL

        SELECT q.text, n.id, n.node_type, n.label, 0.40::numeric, 'label_contains'
        FROM nodes n, q
        WHERE n.archived_at IS NULL
          AND (p_node_types IS NULL OR n.node_type = ANY(p_node_types))
          -- Literal containment. The query is escaped so '%' and '_' mean
          -- themselves; without this the tier is a pattern language and a
          -- one-character query returns every visible labeled node.
          AND n.label ILIKE '%' || rye_like_literal(q.text) || '%' ESCAPE '\'
    ),
    best AS (
        SELECT DISTINCT ON (m.query, m.id)
               m.query, m.id, m.node_type, m.label, m.score, m.reason
        FROM matches m
        ORDER BY m.query, m.id, m.score DESC, m.reason
    ),
    ranked AS (
        SELECT b.*,
               row_number() OVER (
                   PARTITION BY b.query
                   ORDER BY b.score DESC, b.label NULLS LAST, b.id
               ) AS rn
        FROM best b
    )
    SELECT r.query, r.id, r.node_type, r.label, r.score, r.reason
    FROM ranked r, cfg
    WHERE r.rn <= cfg.lim
    ORDER BY r.query, r.score DESC, r.label NULLS LAST, r.id;
$$;

COMMENT ON FUNCTION find_nodes_batch(text[], text[], int, numeric, uuid) IS
'Ranked node lookup for many query strings in one round trip, so an agent can try several reformulations at once. Searches no property values because field-level redaction applies to them. STABLE, SECURITY INVOKER, writes nothing.';

CREATE OR REPLACE FUNCTION find_nodes(
    p_query text,
    p_node_types text[] DEFAULT NULL,
    p_limit int DEFAULT 20,
    p_threshold numeric DEFAULT NULL,
    p_scope uuid DEFAULT NULL
) RETURNS TABLE (
    node_id uuid,
    node_type text,
    label text,
    score numeric,
    match_reason text
)
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = rye, pg_catalog
AS $$
    SELECT b.node_id, b.node_type, b.label, b.score, b.match_reason
    FROM find_nodes_batch(ARRAY[p_query], p_node_types, p_limit, p_threshold, p_scope) b
    ORDER BY b.score DESC, b.label NULLS LAST, b.node_id;
$$;

COMMENT ON FUNCTION find_nodes(text, text[], int, numeric, uuid) IS
'Single-query form of find_nodes_batch. Use the batch form when trying several reformulations. STABLE, SECURITY INVOKER, writes nothing.';

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
-- must not be used for causal reasoning. Anything else is refused: an
-- unrecognized direction used to fall through to the undirected walk, which
-- is the one reading a caller is told never to take by accident.

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
LANGUAGE sql STABLE SECURITY INVOKER
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
            -- Both enumerated arguments are validated here, and `params` is
            -- read by the LIMIT below, so an unrecognized value raises even
            -- when the walk itself matches nothing.
            rye_require_path_direction(p_direction) AS direction,
            rye_require_edge_semantics(p_semantics) AS semantics
    ),
    sem AS (
        -- Only evaluated when semantic filtering is requested.
        SELECT DISTINCT e.edge_type
        FROM edges e, params p
        WHERE p.semantics IS NOT NULL
          AND e.archived_at IS NULL
          AND edge_semantics(e.edge_type, p_scope) = ANY(p.semantics)
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
          AND (p.semantics  IS NULL OR e.edge_type IN (SELECT s.edge_type FROM sem s))
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
'Bounded typed multi-hop traversal. STABLE, SECURITY INVOKER, writes nothing: RLS prunes the walk and no completeness signal is emitted. Depth capped by registry max_path_depth.';

-- --------------------------------------------------------------------------
-- neighborhood — bounded subgraph with current knowledge
-- --------------------------------------------------------------------------
-- What an agent actually needs to answer a "why" question: the nodes within
-- N hops, the edges among them, and each node's current accepted assertions,
-- all under an explicit budget.
--
-- Knowledge comes from current_valid_assertions, so a candidate never
-- appears: not one written as a candidate, not one a review policy demoted
-- (0027/0030), and not one reject_candidate() closed, which leaves status
-- 'candidate' with superseded_at set. A superseded accepted row is excluded
-- for the same reason. What an agent reads here is what the instance
-- currently believes.
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
LANGUAGE sql STABLE SECURITY INVOKER
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
            -- `params` is read by the result object, so both validations run
            -- whatever the walk finds. The default here is 'any', not 'out'.
            rye_require_path_direction(
                coalesce(nullif(btrim(p_direction), ''), 'any')) AS direction,
            rye_require_edge_semantics(p_semantics) AS semantics
    ),
    sem AS (
        SELECT DISTINCT e.edge_type
        FROM edges e, params p
        WHERE p.semantics IS NOT NULL
          AND e.archived_at IS NULL
          AND edge_semantics(e.edge_type, p_scope) = ANY(p.semantics)
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
          AND (p.semantics  IS NULL OR e.edge_type IN (SELECT s.edge_type FROM sem s))
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
          AND (p.semantics  IS NULL OR e.edge_type IN (SELECT s.edge_type FROM sem s))
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
'Bounded subgraph around a node with current accepted assertions attached. truncated reports the node budget only, never RLS pruning. STABLE, SECURITY INVOKER, writes nothing.';

-- --------------------------------------------------------------------------
-- Core registry defaults
-- --------------------------------------------------------------------------
-- migrate.sh runs each migration file in its own psql session, so this block
-- sets app.current_role itself. `registry_entry` is settle-gated
-- configuration (0023): only an admin may make one accepted, and after 0026
-- only a writing role may write at all.

DO $$
DECLARE
    v_core_id uuid;
    v_entry record;
    v_missing text;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'migration:0032_graph_traversal', true);
    PERFORM set_config('app.current_teams', '', true);

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

    -- An instance whose DEFAULT_SCOPE review policy is strict demotes these
    -- to candidates (0027). That is not a failure -- every function here
    -- falls back to its built-in default and to 'associative' -- but an
    -- operator should know the defaults are waiting in review_queue rather
    -- than in force.
    SELECT string_agg(missing.key, ', ' ORDER BY missing.key)
    INTO v_missing
    FROM (VALUES
        ('max_path_depth'), ('node_search_threshold'),
        ('edge_semantics:blocks'), ('edge_semantics:triggered_by'),
        ('edge_semantics:affects'), ('edge_semantics:impacted'),
        ('edge_semantics:employs'), ('edge_semantics:assigned_to'),
        ('edge_semantics:project_member'), ('edge_semantics:depends_on'),
        ('edge_semantics:contains'), ('edge_semantics:owns'),
        ('edge_semantics:regarding'), ('edge_semantics:references'),
        ('edge_semantics:applied_to'), ('edge_semantics:targets'),
        ('edge_semantics:adjacent_to')
    ) AS missing(key)
    WHERE registry_value(missing.key, NULL) IS NULL;

    IF v_missing IS NOT NULL THEN
        RAISE NOTICE
            'Traversal registry defaults did not land accepted (review policy demotion): %. They are candidates in review_queue; the functions use their built-in defaults until an admin accepts them.',
            v_missing;
    END IF;
END;
$$;
