-- Advisory identity resolution and merge-chain lookup.
--
-- Agents perform graph inserts; the database gates outcomes, not steps.
-- Entity resolution is a judgment call that depends on context the database
-- does not hold, so resolve_node_identity() is a READ that returns a verdict
-- and its evidence. It writes nothing, blocks nothing, and no write helper
-- calls it. An intake agent consults it, decides, and routes ambiguity to
-- create_knowledge_candidate() for review like any other uncertain claim.
--
-- A deterministic resolver in the write path would have to make the judgment
-- itself with less context than the agent has, and would stall a bulk import
-- on per-row ambiguity.
--
-- Scope note: the `restricted` verdict from design/proposals/
-- rls-visibility-contract.md D3 is NOT implemented here. That design assumed
-- a SECURITY DEFINER probe could see rows hidden from the caller. It cannot
-- be relied on: FORCE ROW LEVEL SECURITY applies to the table owner, so a
-- definer probe only bypasses RLS when its owner holds BYPASSRLS or is a
-- superuser, which varies by deployment. Until that is settled, a hidden
-- identity match reports `new`, exactly as it does today.

SET search_path = rye, pg_catalog, public;

-- --------------------------------------------------------------------------
-- Normalizers
-- --------------------------------------------------------------------------
-- Deliberately tiny and boring. Every normalizer is a permanent semantic
-- commitment: once nodes have been treated as the same on its basis, changing
-- it rewrites what "matched" meant historically. Unknown normalizers raise
-- rather than silently passing the value through, because a silent
-- pass-through would quietly widen identity.
--
-- Anything cleverer (plus-addressing, nickname tables, transliteration)
-- belongs in the intake skill, where it is visible and revisable.

CREATE OR REPLACE FUNCTION normalize_identity_value(
    p_value text,
    p_normalizer text DEFAULT 'trim'
) RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_norm text := lower(coalesce(nullif(btrim(p_normalizer), ''), 'trim'));
    v_out  text;
BEGIN
    IF p_value IS NULL THEN
        RETURN NULL;
    END IF;

    CASE v_norm
        WHEN 'trim' THEN
            v_out := btrim(p_value);
        WHEN 'lower' THEN
            v_out := lower(btrim(p_value));
        WHEN 'digits_only' THEN
            v_out := regexp_replace(p_value, '\D', '', 'g');
        WHEN 'domain' THEN
            -- strip scheme, credentials, path, port, and a leading www.
            v_out := lower(btrim(p_value));
            v_out := regexp_replace(v_out, '^[a-z][a-z0-9+.-]*://', '');
            v_out := regexp_replace(v_out, '^[^/@]*@', '');
            v_out := split_part(split_part(v_out, '/', 1), ':', 1);
            v_out := regexp_replace(v_out, '^www\.', '');
        ELSE
            RAISE EXCEPTION 'Unknown identity normalizer: % (allowed: trim, lower, digits_only, domain)', p_normalizer;
    END CASE;

    RETURN nullif(v_out, '');
END;
$$;

COMMENT ON FUNCTION normalize_identity_value(text, text) IS
'Normalizes an identity value for comparison. Unknown normalizers raise; a silent pass-through would quietly widen identity.';

-- --------------------------------------------------------------------------
-- Declared identity keys
-- --------------------------------------------------------------------------
-- Registry key `identity_keys:<node_type>` holds a JSON array of
--   {"property": "<properties key>", "normalize": "<normalizer>"}
-- Empty or unset means the node type has no declared identity, so only
-- external identity and fuzzy label matching apply.

CREATE OR REPLACE FUNCTION identity_keys(
    p_node_type text,
    p_scope uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = rye, pg_catalog
AS $$
    SELECT CASE
        WHEN jsonb_typeof(registry_value('identity_keys:' || p_node_type, p_scope)) = 'array'
            THEN registry_value('identity_keys:' || p_node_type, p_scope)
        ELSE '[]'::jsonb
    END;
$$;

COMMENT ON FUNCTION identity_keys(text, uuid) IS
'Declared identity properties for a node type, as [{"property":..,"normalize":..}].';

-- --------------------------------------------------------------------------
-- resolve_node_identity — advisory, read-only
-- --------------------------------------------------------------------------
-- Verdicts:
--   match      exactly one node matches on external identity or a declared
--              identity key. Safe to reuse.
--   ambiguous  more than one exact match, or no exact match but a plausible
--              label match. Needs a decision.
--   new        nothing matched. Safe to create.
--
-- Fuzzy label matching NEVER produces `match`. Similar names are not
-- sufficient evidence of identity; they are grounds for review.

CREATE OR REPLACE FUNCTION resolve_node_identity(
    p_node_type text,
    p_label text DEFAULT NULL,
    p_identity jsonb DEFAULT '{}'::jsonb,
    p_limit int DEFAULT 10,
    p_scope uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql STABLE
-- public is on the path for pg_trgm's similarity()/%.
SET search_path = rye, pg_catalog, public
AS $$
    WITH cfg AS (
        SELECT
            greatest(
                coalesce((registry_value('identity_threshold:' || p_node_type, p_scope) #>> '{}')::numeric, 0.45),
                0.3
            ) AS threshold,
            greatest(coalesce(p_limit, 10), 1) AS lim,
            coalesce(p_identity, '{}'::jsonb) AS identity
    ),
    specs AS (
        SELECT s->>'property' AS prop,
               coalesce(nullif(s->>'normalize', ''), 'trim') AS norm
        FROM jsonb_array_elements(identity_keys(p_node_type, p_scope)) s
        WHERE s->>'property' IS NOT NULL
    ),
    exact_matches AS (
        SELECT n.id, 'external_id'::text AS reason, 1.00::numeric AS score
        FROM nodes n, cfg
        WHERE n.archived_at IS NULL
          AND n.node_type = p_node_type
          AND cfg.identity ? 'external_source'
          AND cfg.identity ? 'external_id'
          AND n.external_source = cfg.identity->>'external_source'
          AND n.external_id     = cfg.identity->>'external_id'

        UNION

        SELECT n.id, 'identity:' || sp.prop, 0.90::numeric
        FROM nodes n
        CROSS JOIN specs sp
        CROSS JOIN cfg
        WHERE n.archived_at IS NULL
          AND n.node_type = p_node_type
          AND normalize_identity_value(cfg.identity->>sp.prop, sp.norm) IS NOT NULL
          AND normalize_identity_value(n.properties->>sp.prop, sp.norm)
              = normalize_identity_value(cfg.identity->>sp.prop, sp.norm)
    ),
    exact_nodes AS (
        SELECT DISTINCT ON (e.id) e.id, e.reason, e.score
        FROM exact_matches e
        ORDER BY e.id, e.score DESC, e.reason
    ),
    fuzzy_nodes AS (
        SELECT n.id,
               'label_similarity'::text AS reason,
               round((similarity(n.label, p_label))::numeric, 4) AS score
        FROM nodes n, cfg
        WHERE nullif(btrim(coalesce(p_label, '')), '') IS NOT NULL
          AND n.archived_at IS NULL
          AND n.node_type = p_node_type
          AND n.label IS NOT NULL
          AND n.label % p_label
          AND similarity(n.label, p_label) >= cfg.threshold
          AND NOT EXISTS (SELECT 1 FROM exact_nodes x WHERE x.id = n.id)
    ),
    chosen AS (
        SELECT id, reason, score, true  AS is_exact FROM exact_nodes
        UNION ALL
        SELECT id, reason, score, false AS is_exact FROM fuzzy_nodes
    ),
    ranked AS (
        SELECT c.*, n.label
        FROM chosen c
        JOIN nodes n ON n.id = c.id
        ORDER BY c.is_exact DESC, c.score DESC, n.label NULLS LAST, c.id
        LIMIT (SELECT lim FROM cfg)
    )
    SELECT jsonb_build_object(
        'verdict',
            CASE
                WHEN (SELECT count(*) FROM exact_nodes) = 1 THEN 'match'
                WHEN (SELECT count(*) FROM exact_nodes) > 1 THEN 'ambiguous'
                WHEN (SELECT count(*) FROM fuzzy_nodes) > 0 THEN 'ambiguous'
                ELSE 'new'
            END,
        'node_type', p_node_type,
        'exact_count', (SELECT count(*) FROM exact_nodes),
        'fuzzy_count', (SELECT count(*) FROM fuzzy_nodes),
        'identity_keys_configured', (SELECT count(*) FROM specs),
        'threshold', (SELECT threshold FROM cfg),
        'candidates', coalesce(
            (SELECT jsonb_agg(
                        jsonb_build_object(
                            'node_id',      r.id,
                            'label',        r.label,
                            'score',        r.score,
                            'match_reason', r.reason,
                            'exact',        r.is_exact
                        )
                    )
             FROM ranked r),
            '[]'::jsonb
        )
    );
$$;

COMMENT ON FUNCTION resolve_node_identity(text, text, jsonb, int, uuid) IS
'Advisory identity lookup. Read-only: returns a verdict and candidates, writes nothing, blocks nothing. Fuzzy label matches never yield match.';

-- --------------------------------------------------------------------------
-- resolve_merged_node — follow a merge chain
-- --------------------------------------------------------------------------
-- merge_nodes() has always recorded node_merges rows, and the data dictionary
-- has always promised that "old references can be traced to the surviving
-- node" — but nothing read the table, so a stale reference to a merged-away
-- id resolved to nothing. This closes that.

CREATE OR REPLACE FUNCTION resolve_merged_node(
    p_node_id uuid
) RETURNS uuid
LANGUAGE plpgsql STABLE
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_current uuid := p_node_id;
    v_next    uuid;
    v_seen    uuid[] := ARRAY[]::uuid[];
BEGIN
    IF p_node_id IS NULL THEN
        RETURN NULL;
    END IF;

    LOOP
        SELECT m.canonical_id
        INTO v_next
        FROM node_merges m
        WHERE m.duplicate_id = v_current
        ORDER BY m.merged_at DESC
        LIMIT 1;

        EXIT WHEN v_next IS NULL;

        IF v_next = ANY(v_seen) OR v_next = v_current THEN
            RAISE EXCEPTION 'Merge chain for % contains a cycle at %', p_node_id, v_next;
        END IF;

        v_seen := v_seen || v_current;
        v_current := v_next;
    END LOOP;

    RETURN v_current;
END;
$$;

COMMENT ON FUNCTION resolve_merged_node(uuid) IS
'Follows node_merges transitively to the surviving node. Returns the input when it was never merged. Raises on a merge cycle.';
