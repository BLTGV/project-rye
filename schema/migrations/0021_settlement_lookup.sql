-- Who may settle a claim: one advisory read.
--
-- Implements the "Settlement lookup" section of contracts/sql-surface.md and
-- docs/decisions/0005-who-may-settle-lookup.md. rye_settlers() answers who may
-- settle a claim and which of three steps said so: a recorded grant for that
-- kind of claim, then the relationship between speaker and subject, then the
-- owner of the area. The relationship step is selected by the claim type
-- first and the speech act second, so omitting the optional speech act
-- narrows the answer and never widens it. It is read-only and advisory. It writes nothing, refuses
-- nothing, and raises nothing for a missing answer. No new table and no new
-- core-table column: grants stay in domain_authorities, relationships stay in
-- edges, the area owner stays on knowledge_domains.
--
-- Agents are never settlers. An agent carries the authority of the person it
-- acts for and none of its own, so an agent ref is dropped before any step
-- picks a winner and counted in excluded_agents. The check fails closed on the
-- `agent:` prefix and matches identities on their stored slug, because
-- create_agent_identity() slugifies agent_key and a ref spelled `agent:my-agent`
-- would otherwise match the stored `my_agent` not at all.

SET search_path = rye, pg_catalog, public;

-- The edge lookups below ride on idx_edges_source_type and
-- idx_edges_target_type from 0001_core.sql; no new index is needed.

-- --------------------------------------------------------------------------
-- Ref resolution
-- --------------------------------------------------------------------------

-- A settler ref is a uuid, an `<external_source>:<external_id>` pair, or a
-- bare external_id. domain_authorities.authority_ref is free text by
-- convention (`person:jane-doe`, `slack:U0123`), so most refs resolve to no
-- node at all. That is not an error: the settler comes back unbound.
CREATE OR REPLACE FUNCTION rye_settler_resolve_ref(p_ref text)
RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_ref      text := nullif(trim(p_ref), '');
    v_id       uuid;
    v_source   text;
    v_external text;
BEGIN
    IF v_ref IS NULL THEN
        RETURN NULL;
    END IF;

    IF v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        SELECT n.id INTO v_id
        FROM nodes n
        WHERE n.id = v_ref::uuid
          AND n.archived_at IS NULL;
        RETURN v_id;
    END IF;

    IF position(':' IN v_ref) > 0 THEN
        v_source   := left(v_ref, position(':' IN v_ref) - 1);
        v_external := substr(v_ref, position(':' IN v_ref) + 1);

        SELECT n.id INTO v_id
        FROM nodes n
        WHERE n.archived_at IS NULL
          AND n.external_source = v_source
          AND n.external_id = v_external
        ORDER BY n.created_at, n.id
        LIMIT 1;

        IF v_id IS NOT NULL THEN
            RETURN v_id;
        END IF;
    END IF;

    SELECT n.id INTO v_id
    FROM nodes n
    WHERE n.archived_at IS NULL
      AND n.external_id = v_ref
    ORDER BY n.created_at, n.id
    LIMIT 1;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION rye_settler_resolve_ref(text) IS
    'Resolve a settler ref to a visible node id, or NULL. A uuid matches by id; an <external_source>:<external_id> pair matches both columns; anything else matches external_id alone. Used by rye_settlers(); a ref that resolves to nothing yields an unbound settler, never an error.';

-- An agent identity is never a settler, and this is the one place that rule
-- lives. Two rules, in this order:
--
-- 1. Fail closed on the prefix. Any ref whose first non-whitespace characters
--    are `agent` followed by a colon is an agent, whatever the case and
--    whatever whitespace sits at the front or around the colon, and whether or
--    not an agent_identities row backs it. A ref that says it is an agent
--    never settles. The alternative — treating an unmatched `agent:` ref as an
--    ordinary person — turns a typo or a deleted identity into authority.
--    Whitespace here means more than PostgreSQL's trim(), which strips plain
--    spaces only: tab, CR, LF, form feed, vertical tab, and the non-breaking
--    space U+00A0 are all stripped and all ignored around the colon.
-- 2. Match on the slug, not the spelling. create_agent_identity() stores
--    rye_slugify_key(agent_key), so `my-agent`, `My Agent`, and `my_agent`
--    are one key and a ref in any of those spellings is the same agent.
--
-- Unicode lookalike letters are out of scope. A ref whose `a` is a Cyrillic
-- а is not an agent prefix here; it slugifies to a key no identity has and
-- resolves to no node, so it comes back as an unbound settler with no node
-- behind it, which is what any other unrecognised ref does.
--
-- The prefix rule reads `agent` as a whole word before a colon, so
-- `person:my-agent` is not an agent. A person never loses authority for
-- sharing a slug with an agent: only the whole ref is slugified for rule 2,
-- and `person:my-agent` slugifies to `person_my_agent`.
--
-- A node is an agent when its node_type is 'agent' or its attrs->>'actor_kind'
-- is 'agent', whatever its ref says. An inactive agent identity is still an
-- agent: the active flag is not consulted.
CREATE OR REPLACE FUNCTION rye_settler_is_agent(p_ref text, p_node_id uuid)
RETURNS boolean
SET search_path = rye, pg_catalog
AS $$
DECLARE
    -- Everything trim() misses, spelled out: space, tab, CR, LF, form feed,
    -- vertical tab, non-breaking space.
    c_space constant text := E' \t\r\n\f\u000B\u00A0';
    v_ref text := nullif(btrim(coalesce(p_ref, ''), c_space), '');
    v_key text;
BEGIN
    IF v_ref IS NOT NULL THEN
        IF v_ref ~* E'^[[:space:]\u00A0]*agent[[:space:]\u00A0]*:' THEN
            RETURN true;
        END IF;

        v_key := rye_slugify_key(v_ref);

        IF v_key IS NOT NULL AND EXISTS (
            SELECT 1
            FROM agent_identities ai
            WHERE ai.agent_key = v_key
        ) THEN
            RETURN true;
        END IF;
    END IF;

    IF p_node_id IS NOT NULL AND EXISTS (
        SELECT 1
        FROM nodes n
        WHERE n.id = p_node_id
          AND (n.node_type = 'agent' OR n.attrs->>'actor_kind' = 'agent')
    ) THEN
        RETURN true;
    END IF;

    RETURN false;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION rye_settler_is_agent(text, uuid) IS
    'True when a candidate settler is an agent. Fails closed on the prefix: a ref whose first non-whitespace characters are ''agent'' followed by a colon is an agent whether or not an agent_identities row backs it, in any case and with any whitespace at the front or around the colon — space, tab, CR, LF, form feed, vertical tab, and the non-breaking space U+00A0, which PostgreSQL''s trim() does not strip. Otherwise the ref is matched on its slug, because create_agent_identity() stores rye_slugify_key(agent_key) — so ''my-agent'', ''My Agent'', and ''my_agent'' are one key, while ''person:my-agent'' slugifies to ''person_my_agent'' and is not an agent. An inactive agent identity is still an agent; the active flag is not consulted. A node is an agent when its node_type is ''agent'' or its attrs->>''actor_kind'' is ''agent''. Unicode lookalike letters are out of scope: such a ref matches no identity and no node and comes back unbound. rye_settlers() drops agents before choosing a step and counts them in excluded_agents.';

-- node_type to the settler `kind` vocabulary in contracts/sql-surface.md.
CREATE OR REPLACE FUNCTION rye_settler_node_kind(p_node_type text)
RETURNS text
SET search_path = rye, pg_catalog
AS $$
    SELECT CASE lower(coalesce(p_node_type, ''))
        WHEN 'person'     THEN 'person'
        WHEN 'team'       THEN 'team'
        WHEN 'department' THEN 'team'
        WHEN 'role'       THEN 'role'
        WHEN 'system'     THEN 'system'
        ELSE 'other'
    END;
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION rye_settler_node_kind(text) IS
    'Map a node_type to the settler kind vocabulary: person, team (team or department), role, system, else other.';

-- --------------------------------------------------------------------------
-- The lookup
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION rye_settlers(
    p_subject_id  uuid,
    p_claim_type  text,
    p_speaker_id  uuid        DEFAULT NULL,
    p_speaker_ref text        DEFAULT NULL,
    p_domain_key  text        DEFAULT NULL,
    p_speech_act  text        DEFAULT NULL,
    p_as_of       timestamptz DEFAULT now(),
    p_scope_ref   text        DEFAULT NULL
) RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    -- Which claim types are claims one person sets on another, and which are
    -- a person's own commitment or report about themselves. Literal, exact
    -- string match, additive. Stated in contracts/sql-surface.md and here and
    -- nowhere else: there is no table to configure and no migration to run.
    c_other_set constant text[] := ARRAY['expectation'];
    c_self_set  constant text[] := ARRAY['commitment', 'self_commitment', 'self_report'];

    v_as_of        timestamptz := coalesce(p_as_of, now());
    v_claim_type   text := nullif(trim(p_claim_type), '');
    v_canonical    text;
    v_speech_act   text := nullif(trim(p_speech_act), '');
    v_speaker_ref  text := nullif(trim(p_speaker_ref), '');
    v_domain_key_in text := nullif(trim(p_domain_key), '');

    v_recognized   boolean := false;
    v_want_self    boolean := false;
    v_want_manager boolean := false;
    v_want_owner   boolean := false;

    v_domain_id    uuid;
    v_domain_key   text;
    v_domain_found boolean := false;
    v_domain_mode  text;
    v_owner_id     uuid;
    v_active_count integer := 0;

    v_subject      nodes%ROWTYPE;
    v_subject_ref  text;
    v_subject_found boolean := false;
    v_speaker_found boolean := false;

    v_owner_node   nodes%ROWTYPE;

    v_grants       jsonb := '[]'::jsonb;
    v_self         jsonb := '[]'::jsonb;
    v_owners       jsonb := '[]'::jsonb;
    v_managers     jsonb := '[]'::jsonb;
    v_settlers     jsonb := '[]'::jsonb;

    v_excluded     integer := 0;
    v_step         text := 'none';
    v_reason       text;
    v_setup_gap    boolean := false;
    v_is_settler   boolean := false;
    v_halt         boolean := false;
    v_matches      boolean;
    v_node_id      uuid;
    v_ref          text;

    r              record;
BEGIN
    -- ----------------------------------------------------------------------
    -- Resolve the claim type through the organization's type aliases, so this
    -- lookup classifies a claim the same way the rest of the schema stores it.
    -- An organization that aliases `requirement` to `expectation` has
    -- record_assertion() writing `expectation`, governing_scope() and the
    -- salience views reading `expectation`, and now this lookup applying the
    -- rules for `expectation` too. Without it, asking about `requirement`
    -- skipped rule 1 and the person an expectation was set on came back as its
    -- settler.
    --
    -- canonical_type() and not canonical_type_in_scope(): rye_settlers() has no
    -- onboarding-scope argument. p_scope_ref is free text for matching a
    -- grant's scope_ref and is not a scope node. canonical_type() resolves the
    -- scope from the DEFAULT_SCOPE registry entry, which is what the salience
    -- views and 0019 do, so the same alias resolves the same way here as there.
    -- Adding a scope argument would change the contracted signature.
    --
    -- Matching stays case-sensitive afterwards. `Expectation` with no alias is
    -- a different claim type, unclassified, and falls through like any other.
    -- Alias resolution reads current_valid_assertions, so an alias hidden from
    -- this caller by RLS does not apply, as everywhere else.
    -- canonical_type() raises on a null value and on an alias cycle: a null or
    -- empty claim type is not resolved at all and behaves as it always did, and
    -- a cycle is a misconfiguration that raises rather than answering wrongly.
    -- ----------------------------------------------------------------------
    IF v_claim_type IS NOT NULL THEN
        v_canonical := canonical_type('assertion_type', v_claim_type);
    END IF;

    -- ----------------------------------------------------------------------
    -- Resolve the area. Step 1 needs it to find grants and step 3 is the
    -- owner of it, so it resolves before anything else runs.
    -- ----------------------------------------------------------------------
    IF v_domain_key_in IS NOT NULL THEN
        v_domain_mode := 'explicit';

        SELECT d.id, d.domain_key, d.owner_node_id
          INTO v_domain_id, v_domain_key, v_owner_id
        FROM knowledge_domains d
        WHERE d.domain_key = rye_slugify_key(v_domain_key_in)
          AND d.archived_at IS NULL;

        v_domain_found := v_domain_id IS NOT NULL;

        -- An unknown key is an answer, not an exception: nothing is looked up
        -- against an area that does not exist.
        IF NOT v_domain_found THEN
            v_reason := 'domain_not_found';
            v_halt := true;
        END IF;
    ELSE
        SELECT count(*) INTO v_active_count
        FROM knowledge_domains d
        WHERE d.archived_at IS NULL;

        IF v_active_count = 1 THEN
            SELECT d.id, d.domain_key, d.owner_node_id
              INTO v_domain_id, v_domain_key, v_owner_id
            FROM knowledge_domains d
            WHERE d.archived_at IS NULL;

            v_domain_mode  := 'single_active';
            v_domain_found := true;
        ELSIF v_active_count = 0 THEN
            v_domain_mode := 'none';
        ELSE
            v_domain_mode := 'ambiguous';
        END IF;
    END IF;

    -- ----------------------------------------------------------------------
    -- Subject and speaker. RLS silence is indistinguishable from absence on
    -- purpose: an invisible subject reads as not found.
    -- ----------------------------------------------------------------------
    IF p_subject_id IS NOT NULL THEN
        SELECT * INTO v_subject
        FROM nodes n
        WHERE n.id = p_subject_id
          AND n.archived_at IS NULL;

        v_subject_found := v_subject.id IS NOT NULL;

        IF v_subject.external_source IS NOT NULL AND v_subject.external_id IS NOT NULL THEN
            v_subject_ref := v_subject.external_source || ':' || v_subject.external_id;
        END IF;
    END IF;

    IF p_speaker_id IS NOT NULL THEN
        SELECT EXISTS (
            SELECT 1 FROM nodes n
            WHERE n.id = p_speaker_id AND n.archived_at IS NULL
        ) INTO v_speaker_found;
    ELSIF v_speaker_ref IS NOT NULL THEN
        v_speaker_found := rye_settler_resolve_ref(v_speaker_ref) IS NOT NULL;
    END IF;

    -- ----------------------------------------------------------------------
    -- Step 1: a recorded grant for this kind of claim.
    --
    -- A grant that matches displaces the relationship defaults entirely; that
    -- is how a grant narrows as well as adds. A grant that should not displace
    -- them names its subjects in properties.
    -- ----------------------------------------------------------------------
    IF NOT v_halt AND v_domain_id IS NOT NULL THEN
        FOR r IN
            SELECT da.*
            FROM domain_authorities da
            WHERE da.domain_id = v_domain_id
              AND da.active
              AND da.effective_at <= v_as_of
              AND (da.effective_to IS NULL OR da.effective_to > v_as_of)
              AND (
                  da.scope_ref IS NULL
                  OR p_scope_ref IS NULL
                  OR da.scope_ref = p_scope_ref
              )
            ORDER BY da.authority_kind, da.authority_ref, da.id
        LOOP
            -- Claim type, both sides canonicalized. A grant that names the
            -- alias covers a call that names the canonical type and the other
            -- way round; an empty claim_types still means every claim type.
            IF cardinality(r.claim_types) = 0 THEN
                v_matches := true;
            ELSIF v_canonical IS NULL THEN
                v_matches := false;
            ELSE
                SELECT EXISTS (
                    SELECT 1
                    FROM unnest(r.claim_types) AS ct(value)
                    WHERE CASE
                              WHEN nullif(trim(ct.value), '') IS NULL THEN NULL
                              ELSE canonical_type('assertion_type', ct.value)
                          END = v_canonical
                ) INTO v_matches;
            END IF;

            CONTINUE WHEN NOT v_matches;

            -- Subject narrowing lives in properties, never in a new column.
            -- An absent key means the grant covers every subject in the area.
            IF jsonb_typeof(r.properties->'subjects') = 'array'
               AND jsonb_array_length(r.properties->'subjects') > 0 THEN
                v_matches := p_subject_id IS NOT NULL AND (
                    r.properties->'subjects' ? p_subject_id::text
                    OR (v_subject_ref IS NOT NULL AND r.properties->'subjects' ? v_subject_ref)
                    OR (v_subject.external_id IS NOT NULL
                        AND r.properties->'subjects' ? v_subject.external_id)
                );
            END IF;

            IF v_matches
               AND jsonb_typeof(r.properties->'subject_node_types') = 'array'
               AND jsonb_array_length(r.properties->'subject_node_types') > 0 THEN
                v_matches := v_subject.node_type IS NOT NULL
                    AND (r.properties->'subject_node_types' ? v_subject.node_type);
            END IF;

            CONTINUE WHEN NOT v_matches;

            v_node_id := rye_settler_resolve_ref(r.authority_ref);

            IF lower(coalesce(r.authority_kind, '')) = 'agent'
               OR rye_settler_is_agent(r.authority_ref, v_node_id) THEN
                v_excluded := v_excluded + 1;
                CONTINUE;
            END IF;

            v_grants := v_grants || jsonb_build_object(
                'kind',         r.authority_kind,
                'node_id',      v_node_id,
                'ref',          r.authority_ref,
                'label',        (SELECT n.label FROM nodes n WHERE n.id = v_node_id),
                'via',          'grant',
                'relationship', NULL::text,
                'bound',        (v_node_id IS NOT NULL AND r.authority_kind <> 'source'),
                'grant_id',     r.id,
                'claim_types',  to_jsonb(r.claim_types),
                'settles_acts', to_jsonb(r.speech_acts),
                'scope_ref',    r.scope_ref,
                'effective_at', r.effective_at,
                'effective_to', r.effective_to
            );
        END LOOP;

        IF jsonb_array_length(v_grants) > 0 THEN
            v_settlers := v_grants;
            v_step := 'grant';
        END IF;
    END IF;

    -- ----------------------------------------------------------------------
    -- Step 2: the relationship between the speaker and the subject.
    --
    -- Two selectors, the claim type first and the speech act second. Five
    -- ordered rules, first match wins. The claim type carries the safety on
    -- its own, so omitting the optional speech act and mistyping it both land
    -- in the same place as classifying it correctly would.
    --
    -- The claim type read here is the canonical one, so an alias classifies
    -- exactly as the type it resolves to.
    --
    --   0. relationship edge type        -> fall through
    --   1. other-set, or act expectation -> manager only, never self
    --   2. recognized speech act         -> its documented default
    --   3. self-set claim type           -> self only
    --   4. anything else                 -> fall through to the area owner
    --
    -- There is no union. A null or unrecognized speech act never widens who
    -- may settle: saying less buys a smaller answer, never a larger one.
    -- ----------------------------------------------------------------------
    v_recognized := coalesce(v_speech_act IN (
        'self_commitment', 'self_report', 'expectation',
        'statement_about_other', 'statement_about_thing',
        'agreement', 'decision', 'outside_report', 'agent_inference'
    ), false);

    IF coalesce(v_canonical, '') IN ('reports_to', 'owns') THEN
        -- Rule 0. Neither end of a relationship settles that it exists.
        NULL;

    ELSIF v_canonical = ANY (c_other_set)
       OR v_speech_act = 'expectation' THEN
        -- Rule 1, and the point of the ordering. An expectation is set on a
        -- person by someone else, so the person it is set on is never its
        -- settler, whatever the speech act says.
        v_want_manager := true;

    ELSIF v_recognized THEN
        -- Rule 2.
        IF v_speech_act IN ('self_commitment', 'self_report') THEN
            v_want_self := true;
        ELSIF v_speech_act = 'statement_about_other' THEN
            v_want_self := true;
            v_want_manager := true;
        ELSIF v_speech_act = 'statement_about_thing' THEN
            v_want_owner := true;
        ELSE
            -- agreement, decision, outside_report, agent_inference.
            NULL;
        END IF;

    ELSIF v_canonical = ANY (c_self_set) THEN
        -- Rule 3. A person's own commitment or report about themselves still
        -- settles with no setup and no speech act.
        v_want_self := true;

    ELSE
        -- Rule 4. No claim type class, and the speech act is null or
        -- unrecognized. Nothing local is selected; the area owner answers.
        NULL;
    END IF;

    IF NOT v_halt
       AND v_step = 'none'
       AND v_subject_found THEN

        -- Self: a person settles claims about themselves, with no setup.
        IF v_want_self AND v_subject.node_type = 'person' THEN
            IF rye_settler_is_agent(v_subject_ref, v_subject.id) THEN
                v_excluded := v_excluded + 1;
            ELSE
                v_self := v_self || jsonb_build_object(
                    'kind',         rye_settler_node_kind(v_subject.node_type),
                    'node_id',      v_subject.id,
                    'ref',          v_subject_ref,
                    'label',        v_subject.label,
                    'via',          'relationship',
                    'relationship', 'self',
                    'bound',        true,
                    'edge_id',      NULL::uuid,
                    'edge_type',    NULL::text
                );
            END IF;
        END IF;

        -- Owner: source of an `owns` edge whose target is the subject.
        IF v_want_owner THEN
            FOR r IN
                SELECT e.id AS edge_id, e.edge_type, n.id AS node_id,
                       n.node_type, n.label, n.external_source, n.external_id
                FROM edges e
                JOIN nodes n ON n.id = e.source_id AND n.archived_at IS NULL
                WHERE e.edge_type = 'owns'
                  AND e.target_id = v_subject.id
                  AND e.archived_at IS NULL
                  AND (e.effective_from IS NULL OR e.effective_from <= v_as_of)
                  AND (e.effective_to IS NULL OR e.effective_to > v_as_of)
                ORDER BY n.label NULLS LAST, n.id
            LOOP
                v_ref := CASE
                             WHEN r.external_source IS NOT NULL AND r.external_id IS NOT NULL
                             THEN r.external_source || ':' || r.external_id
                         END;

                IF rye_settler_is_agent(v_ref, r.node_id) THEN
                    v_excluded := v_excluded + 1;
                    CONTINUE;
                END IF;

                v_owners := v_owners || jsonb_build_object(
                    'kind',         rye_settler_node_kind(r.node_type),
                    'node_id',      r.node_id,
                    'ref',          v_ref,
                    'label',        r.label,
                    'via',          'relationship',
                    'relationship', 'owner',
                    'bound',        true,
                    'edge_id',      r.edge_id,
                    'edge_type',    r.edge_type
                );
            END LOOP;
        END IF;

        -- Manager: target of a `reports_to` edge whose source is the subject.
        IF v_want_manager THEN
            FOR r IN
                SELECT e.id AS edge_id, e.edge_type, n.id AS node_id,
                       n.node_type, n.label, n.external_source, n.external_id
                FROM edges e
                JOIN nodes n ON n.id = e.target_id AND n.archived_at IS NULL
                WHERE e.edge_type = 'reports_to'
                  AND e.source_id = v_subject.id
                  AND e.archived_at IS NULL
                  AND (e.effective_from IS NULL OR e.effective_from <= v_as_of)
                  AND (e.effective_to IS NULL OR e.effective_to > v_as_of)
                ORDER BY n.label NULLS LAST, n.id
            LOOP
                v_ref := CASE
                             WHEN r.external_source IS NOT NULL AND r.external_id IS NOT NULL
                             THEN r.external_source || ':' || r.external_id
                         END;

                IF rye_settler_is_agent(v_ref, r.node_id) THEN
                    v_excluded := v_excluded + 1;
                    CONTINUE;
                END IF;

                v_managers := v_managers || jsonb_build_object(
                    'kind',         rye_settler_node_kind(r.node_type),
                    'node_id',      r.node_id,
                    'ref',          v_ref,
                    'label',        r.label,
                    'via',          'relationship',
                    'relationship', 'manager',
                    'bound',        true,
                    'edge_id',      r.edge_id,
                    'edge_type',    r.edge_type
                );
            END LOOP;
        END IF;

        -- Order within the step: self, owner, manager.
        v_settlers := v_self || v_owners || v_managers;

        IF jsonb_array_length(v_settlers) > 0 THEN
            v_step := 'relationship';
        END IF;
    END IF;

    -- ----------------------------------------------------------------------
    -- Step 3: the owner of the area. No owner is a setup gap, not an error.
    -- ----------------------------------------------------------------------
    IF NOT v_halt AND v_step = 'none' THEN
        IF v_domain_id IS NULL THEN
            v_reason := 'domain_not_resolved';
        ELSIF v_owner_id IS NULL THEN
            v_reason := 'area_has_no_owner';
            v_setup_gap := true;
        ELSE
            SELECT * INTO v_owner_node
            FROM nodes n
            WHERE n.id = v_owner_id
              AND n.archived_at IS NULL;

            v_ref := CASE
                         WHEN v_owner_node.external_source IS NOT NULL
                          AND v_owner_node.external_id IS NOT NULL
                         THEN v_owner_node.external_source || ':' || v_owner_node.external_id
                     END;

            IF v_owner_node.id IS NULL THEN
                -- Archived, or hidden by RLS. Either way the caller gets the
                -- same empty answer and must read the reason.
                v_reason := 'area_owner_not_visible';
            ELSIF rye_settler_is_agent(v_ref, v_owner_node.id) THEN
                v_excluded := v_excluded + 1;
                v_reason := 'area_owner_is_agent';
                v_setup_gap := true;
            ELSE
                v_settlers := jsonb_build_array(jsonb_build_object(
                    'kind',         rye_settler_node_kind(v_owner_node.node_type),
                    'node_id',      v_owner_node.id,
                    'ref',          v_ref,
                    'label',        v_owner_node.label,
                    'via',          'area_owner',
                    'relationship', NULL::text,
                    'bound',        true,
                    'domain_id',    v_domain_id
                ));
                v_step := 'area_owner';
            END IF;
        END IF;
    END IF;

    IF v_step = 'none' THEN
        v_settlers := '[]'::jsonb;
        IF v_reason IS NULL THEN
            v_reason := 'no_settler_found';
        END IF;
    END IF;

    -- The one field the agent acts on: true means record it as accepted,
    -- false means record a suggestion and ask the settlers listed.
    SELECT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_settlers) AS s(value)
        WHERE (p_speaker_id IS NOT NULL AND s.value->>'node_id' = p_speaker_id::text)
           OR (v_speaker_ref IS NOT NULL AND s.value->>'ref' = v_speaker_ref)
    ) INTO v_is_settler;

    RETURN jsonb_build_object(
        'contract_version', 1,
        'step',             v_step,
        'settlers',         v_settlers,
        'settler_count',    jsonb_array_length(v_settlers),
        'speaker', jsonb_build_object(
            'speaker_id',    p_speaker_id,
            'speaker_ref',   v_speaker_ref,
            'speaker_found', v_speaker_found,
            'is_settler',    v_is_settler
        ),
        'subject', jsonb_build_object(
            'subject_id',    p_subject_id,
            'subject_found', v_subject_found,
            'node_type',     v_subject.node_type,
            'label',         v_subject.label
        ),
        'claim', jsonb_build_object(
            'claim_type',             v_claim_type,
            'assertion_type',         v_claim_type,
            'canonical_claim_type',   v_canonical,
            'speech_act',             v_speech_act,
            'speech_act_recognized',  v_recognized
        ),
        'domain', jsonb_build_object(
            'requested_domain_key', v_domain_key_in,
            'domain_id',            v_domain_id,
            'domain_key',           v_domain_key,
            'domain_found',         v_domain_found,
            'mode',                 v_domain_mode,
            'has_owner',            v_owner_id IS NOT NULL
        ),
        'as_of',           v_as_of,
        'advisory',        true,
        'excluded_agents', v_excluded,
        'setup_gap',       v_setup_gap,
        'reason',          v_reason
    );
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION rye_settlers(uuid, text, uuid, text, text, text, timestamptz, text) IS
    'Who may settle this claim, and which of three steps said so. One lookup: a recorded grant in domain_authorities for this claim type, then the relationship between speaker and subject (self, manager via reports_to, owner via owns), then knowledge_domains.owner_node_id for the area. Contract: contracts/sql-surface.md, section "Settlement lookup" (contract_version 1). SECURITY INVOKER and read-only: it writes nothing, refuses nothing, and raises nothing for a missing answer. p_claim_type is the assertion type, resolved through canonical_type(''assertion_type'', ...) first so the organization''s type aliases classify a claim the same way the rest of the schema stores it; claim.claim_type echoes what was asked and claim.canonical_claim_type reports what it resolved to. Grants match on the canonical type on both sides, so a grant naming an alias covers a call naming the canonical type and the other way round. Matching is case-sensitive after resolution, and a null or empty claim type is not resolved at all. The canonical claim type is the first selector: the relationship step tries five ordered rules and the first that applies wins. 0, a relationship edge type (reports_to, owns) falls through. 1, an other-set claim type (expectation) or a speech act of ''expectation'' gives the manager only and never self, so a missing or wrong speech act cannot make a person the settler of an expectation set on them. 2, a recognized p_speech_act gives its documented default. 3, a self-set claim type (commitment, self_commitment, self_report) gives self only. 4, anything else falls through to the area owner. There is no union: a null or unrecognized speech act never widens who may settle. Both claim-type sets are literal strings here and in the contract, matched exactly and growing additively; no table configures them. The lookup reads no assertion, so is_settler true is not permission to replace an accepted claim the caller did not check for. p_as_of filters effective windows only. An agent identity is never returned: any ref beginning with ''agent:'' is excluded whether or not an identity backs it, other refs are matched on the slug create_agent_identity() stores, an inactive identity is still an agent, and a node that is an agent by node_type or attrs->>''actor_kind'' is excluded wherever it stands. Dropped candidates are counted in excluded_agents. step ''none'' with settlers [] and a reason is an answer, not an error, and an empty list never means nobody is authorized, only nobody authorized and visible to this caller.';
