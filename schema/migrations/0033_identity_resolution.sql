-- Advisory identity resolution and merge-chain lookup.
--
-- Work item: work/014-identity-resolution.md (supersedes pull request 20,
--            which was written as 0021 against a main that predates 0020-0030).
-- Contract:  design/proposals/rls-visibility-contract.md (D1, D4), issue 17.
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
-- identity match reports `new`, exactly as it does today, and
-- tests/security/04_identity_visibility.sql pins that so adopting D3 changes
-- the test deliberately rather than discovering it failing.
--
-- Every function here is a read: SECURITY INVOKER, STABLE or IMMUTABLE, and
-- writing nothing. That is deliberate and conformance-tested, so a viewer or
-- a session that sets no role may call them as far as RLS admits, and the
-- work/009 write gate never has to consider them.

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
'Normalizes an identity value for comparison. Unknown normalizers raise; a silent pass-through would quietly widen identity. IMMUTABLE and SECURITY INVOKER, so it may carry an expression index.';

-- --------------------------------------------------------------------------
-- Declared identity keys
-- --------------------------------------------------------------------------
-- Registry key `identity_keys:<node_type>` holds a JSON array of
--   {"property": "<properties key>", "normalize": "<normalizer>"}
-- Empty or unset means the node type has no declared identity, so only
-- external identity and fuzzy label matching apply.
--
-- registry_value() reads current_valid_assertions under the caller's own RLS,
-- so a caller who cannot see the registry entry sees no declared keys and
-- falls back to external identity and label similarity. That fails toward
-- `ambiguous` and `new`, never toward a wrong `match`.

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
'Declared identity properties for a node type, as [{"property":..,"normalize":..}]. Read under the caller''s RLS: a caller who cannot see the registry entry gets an empty list.';

-- --------------------------------------------------------------------------
-- resolve_merged_node — follow a merge chain
-- --------------------------------------------------------------------------
-- merge_nodes() has always recorded node_merges rows, and the data dictionary
-- has always promised that "old references can be traced to the surviving
-- node" — but nothing read the table, so a stale reference to a merged-away
-- id resolved to nothing. This closes that.
--
-- node_merges got forced RLS in 0029. Its read policy admits an admin, or any
-- caller that can see BOTH the duplicate and the canonical node — the same
-- anchor edges use. So this lookup works for every role that can see the
-- nodes involved, on either owner type, without being SECURITY DEFINER.
--
-- When a node in the middle of a chain is invisible to the caller, the two
-- merge rows that name it are invisible too, and the walk stops at the last
-- link the caller can see. That is decision D1 of
-- design/proposals/rls-visibility-contract.md applied here: a derived read
-- prunes silently rather than disclosing the existence of rows behind the
-- policy, and the failure is recoverable — a caller with wider access gets
-- the whole chain on a re-run, and nothing was written in the meantime. No id
-- of an invisible node is ever returned.

-- --------------------------------------------------------------------------
-- The row is the gate: node_merges holds to the shape a merge leaves
-- --------------------------------------------------------------------------
-- 0029 gave node_merges RLS, but its insert rule is only rye_may_write_table:
-- any writing role could insert an arbitrary pair, with a caller-supplied
-- merged_at. That was harmless while nothing read the table. This migration is
-- the first reader, so the rule has to become one about the row —
-- docs/decisions/0008-the-row-is-the-gate-for-assertion-lifecycle.md: no
-- signal a helper produces is out of a caller's reach, so judge the row.
--
-- merge_nodes() (0026) inserts the row at a specific moment, and this guard
-- requires exactly what is true then. In its live body the order is: role
-- gates, ids differ, governance check, lock the duplicate, lock the canonical,
-- refuse an already-archived duplicate, INSERT INTO node_merges, record the
-- node_merge event, redirect edges/assertions/participants/artifacts/source
-- mappings, merge properties, and finally archive the duplicate. So at the
-- insert the duplicate is NOT yet archived and NO node_merge event exists yet.
-- Those two facts are therefore checked at COMMIT by a DEFERRABLE INITIALLY
-- DEFERRED constraint trigger, the way 0025's trg_assertions_transition_complete
-- judges a transaction's final state.
--
-- A BEFORE ROW trigger, not a policy conjunct: a policy does not run inside a
-- SECURITY DEFINER helper owned by a superuser, and a trigger fires for both
-- owner types. Named to sort after trg_node_merges_gate (0029), so that gate's
-- "who may write" message is still the one a read-only or system:cdc session
-- sees.
--
-- The gate makes every refusal merge_nodes() makes before its insert, from
-- the same facts and with the same predicates, so the two cannot drift: a
-- role that may not write (0029's gate, by rye_may_write_table()), an
-- agent-shaped role, system:cdc, equal ids, a non-admin merging a node the
-- governance structure touches, a duplicate or canonical the caller cannot
-- see, and an already-archived duplicate. What remains reachable by raw SQL
-- is exactly this: a caller that merge_nodes() would have let merge this pair
-- can write the row itself, and to survive the commit it must also archive
-- the duplicate and record the node_merge event -- which is what
-- merge_nodes() would have done for it. It cannot do more.
--
-- Consequence worth knowing: merge_nodes() inserts the row before it archives
-- the duplicate, so running it under SET CONSTRAINTS ALL IMMEDIATE fails at
-- the deferred check. Leave the constraint deferred, which is its default.

CREATE OR REPLACE FUNCTION rye_node_merge_shape_gate() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_next uuid;
    v_role text := coalesce(current_setting('app.current_role', true), '');
    v_seen uuid[] := ARRAY[]::uuid[];
    v_walk uuid;
BEGIN
    -- merge_nodes() refuses these two by name. A raw insert is the same act.
    IF rye_current_agent_key() IS NOT NULL THEN
        RAISE EXCEPTION
            'Recording a node merge is not available to an agent ("%"). Record the duplicate and ask a person; a Rye admin or a team member merges.', v_role
            USING ERRCODE = '42501';
    END IF;

    IF v_role = 'system:cdc' THEN
        RAISE EXCEPTION
            'Recording a node merge is not available to system:cdc, which only records domain changes.'
            USING ERRCODE = '42501';
    END IF;

    IF NEW.duplicate_id = NEW.canonical_id THEN
        RAISE EXCEPTION 'duplicate_id and canonical_id must be different'
            USING ERRCODE = '42501';
    END IF;

    -- A merge re-points the duplicate's edges and archives the duplicate, so
    -- a node the governance structure touches is an admin's to merge. Same
    -- predicate as merge_nodes(), on the same facts: without it a
    -- team_member refused by the helper could insert the row, record the
    -- event and archive the node by hand, and leave a live governance edge on
    -- an archived node.
    IF v_role <> 'admin' THEN
        IF EXISTS (
            SELECT 1 FROM nodes n
            WHERE n.id = NEW.duplicate_id AND n.node_type = 'onboarding_scope'
        ) OR EXISTS (
            SELECT 1 FROM edges e
            WHERE (e.source_id = NEW.duplicate_id OR e.target_id = NEW.duplicate_id)
              AND e.edge_type IN (
                  'scope_governs_subject', 'scope_governs_source', 'scope_enables_plugin'
              )
              AND e.archived_at IS NULL
              AND (e.effective_from IS NULL OR e.effective_from <= now())
              AND (e.effective_to IS NULL OR e.effective_to > now())
        ) THEN
            RAISE EXCEPTION
                'Merging a node a scope governs requires a Rye admin ("%" is not).', v_role
                USING ERRCODE = '42501';
        END IF;
    END IF;

    -- merge_nodes() locks both nodes next and reports them absent when the
    -- caller cannot see them. The foreign keys guarantee the rows exist, so
    -- here "not visible" is the only way this fires -- and it is the same
    -- answer the helper gives.
    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = NEW.duplicate_id) THEN
        RAISE EXCEPTION 'Duplicate node % not found', NEW.duplicate_id
            USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = NEW.canonical_id) THEN
        RAISE EXCEPTION 'Canonical node % not found', NEW.canonical_id
            USING ERRCODE = '42501';
    END IF;

    -- merge_nodes() refuses an already-archived duplicate before it inserts.
    IF EXISTS (
        SELECT 1 FROM nodes WHERE id = NEW.duplicate_id AND archived_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Duplicate node % is already archived', NEW.duplicate_id
            USING ERRCODE = '42501';
    END IF;

    -- ------------------------------------------------------------------
    -- Past here the checks are this migration's own: a merge record is now
    -- read, so it carries rules merge_nodes() never needed.
    -- ------------------------------------------------------------------

    -- A merge happened now. Back-dating hides one; forward-dating used to win
    -- the lookup outright.
    IF NEW.merged_at IS DISTINCT FROM now() THEN
        RAISE EXCEPTION
            'node_merges.merged_at is the moment of the merge (%), not % — a merge record is neither back-dated nor future-dated.',
            now(), NEW.merged_at
            USING ERRCODE = '42501';
    END IF;

    -- A node is merged away once.
    IF EXISTS (SELECT 1 FROM node_merges WHERE duplicate_id = NEW.duplicate_id) THEN
        RAISE EXCEPTION
            'Node % has already been merged away; a node is merged away once.', NEW.duplicate_id
            USING ERRCODE = '42501';
    END IF;

    -- The canonical node must not already resolve back to the duplicate.
    -- This is what refuses merge_nodes(B, A) after merge_nodes(A, B): the
    -- second merge aborts at its insert, and the first one stands.
    v_walk := NEW.canonical_id;
    LOOP
        SELECT m.canonical_id
        INTO v_next
        FROM node_merges m
        WHERE m.duplicate_id = v_walk
        ORDER BY m.merged_at, m.id
        LIMIT 1;

        EXIT WHEN v_next IS NULL;

        IF v_next = NEW.duplicate_id THEN
            RAISE EXCEPTION
                'Merging % into % would close a merge cycle: % already resolves to %.',
                NEW.duplicate_id, NEW.canonical_id, NEW.canonical_id, NEW.duplicate_id
                USING ERRCODE = '42501';
        END IF;

        EXIT WHEN v_next = ANY(v_seen) OR v_next = v_walk;
        v_seen := v_seen || v_walk;
        v_walk := v_next;
    END LOOP;

    -- Merging into a node that was itself merged away leaves the survivor
    -- pointing at an archived node.
    IF EXISTS (
        SELECT 1 FROM nodes WHERE id = NEW.canonical_id AND archived_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION
            'Canonical node % is archived; merge into the node it survives as.', NEW.canonical_id
            USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION rye_node_merge_shape_gate() IS
    'BEFORE ROW trigger on node_merges, sorting after rye_node_merge_gate(). Makes every refusal merge_nodes() makes before its insert, from the same facts: no agent, no system:cdc, distinct ids, the governance rule for a non-admin, both nodes visible, and an unarchived duplicate. Then its own: merged_at = now(), no earlier merge record for the duplicate, no cycle, an unarchived canonical. A caller can therefore reach by raw SQL only the merge merge_nodes() would have performed for it. SECURITY INVOKER, so the walk sees what the caller sees; resolve_merged_node() defends itself as well.';

DROP TRIGGER IF EXISTS trg_node_merges_shape ON node_merges;
CREATE TRIGGER trg_node_merges_shape
    BEFORE INSERT ON node_merges
    FOR EACH ROW EXECUTE FUNCTION rye_node_merge_shape_gate();

-- The two facts merge_nodes() has not established yet at its insert. A
-- deferred constraint trigger judges the transaction's final state, so
-- statement order inside the transaction cannot beat it.
CREATE OR REPLACE FUNCTION rye_node_merge_shape_complete() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM nodes WHERE id = NEW.duplicate_id AND archived_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION
            'A merge record for % was written but the duplicate is not archived. A merge archives the duplicate; use merge_nodes().',
            NEW.duplicate_id
            USING ERRCODE = '42501';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM events
        WHERE event_type = 'node_merge'
          AND properties->>'duplicate_id' = NEW.duplicate_id::text
          AND properties->>'canonical_id' = NEW.canonical_id::text
    ) THEN
        RAISE EXCEPTION
            'A merge record for % into % was written with no node_merge event. Use merge_nodes().',
            NEW.duplicate_id, NEW.canonical_id
            USING ERRCODE = '42501';
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION rye_node_merge_shape_complete() IS
    'Deferred constraint trigger on node_merges. At commit the duplicate is archived and a node_merge event names the pair -- the two facts merge_nodes() establishes after its insert, so they cannot be checked in the BEFORE trigger. Because merge_nodes() inserts before it archives, calling it under SET CONSTRAINTS ALL IMMEDIATE fails here; leave the constraint deferred, which is its default.';

DROP TRIGGER IF EXISTS trg_node_merges_shape_complete ON node_merges;
CREATE CONSTRAINT TRIGGER trg_node_merges_shape_complete
    AFTER INSERT ON node_merges
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION rye_node_merge_shape_complete();

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
        -- The table is read as untrusted, whatever the guard admits today:
        -- rows written before this migration were subject to no rule at all.
        -- A merge archives its duplicate, so a row whose duplicate is still
        -- live is not a merge and is not followed.
        IF NOT EXISTS (
            SELECT 1 FROM nodes n
            WHERE n.id = v_current AND n.archived_at IS NOT NULL
        ) THEN
            EXIT;
        END IF;

        -- Earliest first, id as the tie-break: the answer does not move when
        -- a later row appears, and a forged row cannot outrank the real one.
        SELECT m.canonical_id
        INTO v_next
        FROM node_merges m
        WHERE m.duplicate_id = v_current
        ORDER BY m.merged_at, m.id
        LIMIT 1;

        EXIT WHEN v_next IS NULL;

        -- A cycle terminates with an answer rather than an error: this is a
        -- read an agent calls, and raising would make one bad row break every
        -- lookup that passes through it. The answer is the last node reached
        -- before the walk would revisit one it has already seen.
        EXIT WHEN v_next = v_current OR v_next = ANY(v_seen);

        v_seen := v_seen || v_current;
        v_current := v_next;
    END LOOP;

    RETURN v_current;
END;
$$;

COMMENT ON FUNCTION resolve_merged_node(uuid) IS
'Follows node_merges transitively to the surviving node. Returns the input when it was never merged. Treats the table as untrusted: it follows a row only when that row''s duplicate is archived, takes the earliest row for a duplicate (id as tie-break), and on a cycle stops and returns the last node reached instead of raising. SECURITY INVOKER: reads under the caller''s RLS, so a chain through a node the caller cannot see stops at the last visible link.';


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
    -- A name the graph no longer carries. When a node was merged away, its
    -- label went with it: an agent searching the old name would be told
    -- `new` and would recreate the entity that was just deduplicated. So an
    -- archived, merged-away node whose label is similar surfaces its LIVE
    -- survivor as a candidate, with a reason that says the match was on a
    -- former name. Still never `match`: a label is not evidence of identity,
    -- whichever node carried it.
    --
    -- Both nodes are read under the caller's own RLS and resolve_merged_node()
    -- prunes the same way, so nothing about a node the caller cannot read
    -- reaches the answer.
    former_label_nodes AS (
        SELECT DISTINCT ON (f.id) f.id, f.reason, f.score, f.former_label
        FROM (
            SELECT live.id,
                   'former_label_similarity'::text AS reason,
                   round((similarity(dup.label, p_label))::numeric, 4) AS score,
                   dup.label AS former_label
            FROM nodes dup
            CROSS JOIN cfg
            JOIN nodes live ON live.id = resolve_merged_node(dup.id)
            WHERE nullif(btrim(coalesce(p_label, '')), '') IS NOT NULL
              AND dup.archived_at IS NOT NULL
              AND dup.node_type = p_node_type
              AND dup.label IS NOT NULL
              AND dup.label % p_label
              AND similarity(dup.label, p_label) >= cfg.threshold
              AND live.id <> dup.id
              AND live.archived_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM exact_nodes x WHERE x.id = live.id)
              AND NOT EXISTS (SELECT 1 FROM fuzzy_nodes z WHERE z.id = live.id)
        ) f
        ORDER BY f.id, f.score DESC, f.former_label
    ),
    chosen AS (
        SELECT id, reason, score, true  AS is_exact, NULL::text AS former_label FROM exact_nodes
        UNION ALL
        SELECT id, reason, score, false AS is_exact, NULL::text AS former_label FROM fuzzy_nodes
        UNION ALL
        SELECT id, reason, score, false AS is_exact, former_label FROM former_label_nodes
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
                WHEN (SELECT count(*) FROM former_label_nodes) > 0 THEN 'ambiguous'
                ELSE 'new'
            END,
        'node_type', p_node_type,
        'exact_count', (SELECT count(*) FROM exact_nodes),
        'fuzzy_count', (SELECT count(*) FROM fuzzy_nodes),
        'former_label_count', (SELECT count(*) FROM former_label_nodes),
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
                        || CASE
                               WHEN r.former_label IS NOT NULL
                               THEN jsonb_build_object('matched_former_label', r.former_label)
                               ELSE '{}'::jsonb
                           END
                    )
             FROM ranked r),
            '[]'::jsonb
        )
    );
$$;

COMMENT ON FUNCTION resolve_node_identity(text, text, jsonb, int, uuid) IS
'Advisory identity lookup. Read-only: returns a verdict and candidates, writes nothing, blocks nothing. Label matches never yield match, including a former name carried by a merged-away node, which surfaces its live survivor as an ambiguous candidate. SECURITY INVOKER, so a node hidden from the caller reports new (rls-visibility-contract D3 is not implemented).';
