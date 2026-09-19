-- Who may settle a claim: one advisory read.
--
-- Implements the "Settlement lookup" section of contracts/sql-surface.md and
-- docs/decisions/0005-who-may-settle-lookup.md. rye_settlers() answers who may
-- settle a claim and which of three steps said so: a recorded grant for that
-- kind of claim, then the relationship between speaker and subject, then the
-- owner of the area. It is read-only and advisory. It writes nothing, refuses
-- nothing, and raises nothing for a missing answer. No new table and no new
-- core-table column: grants stay in domain_authorities, relationships stay in
-- edges, the area owner stays on knowledge_domains.
--
-- Agents are never settlers. An agent carries the authority of the person it
-- acts for and none of its own, so an agent ref is dropped before any step
-- picks a winner and counted in excluded_agents.

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

-- An agent identity is never a settler. A ref is an agent when it names an
-- agent_identities row directly or as `agent:<agent_key>`, or when the node it
-- resolves to is an agent by node_type or attrs->>'actor_kind'.
CREATE OR REPLACE FUNCTION rye_settler_is_agent(p_ref text, p_node_id uuid)
RETURNS boolean
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_ref text := nullif(trim(p_ref), '');
BEGIN
    IF v_ref IS NOT NULL AND EXISTS (
        SELECT 1
        FROM agent_identities ai
        WHERE ai.agent_key = v_ref
           OR 'agent:' || ai.agent_key = v_ref
    ) THEN
        RETURN true;
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
    'True when a candidate settler is an agent identity: the ref is an agent_key or agent:<agent_key>, or the node is node_type ''agent'' or attrs->>''actor_kind'' = ''agent''. rye_settlers() drops these before choosing a step and counts them in excluded_agents.';

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
    v_as_of        timestamptz := coalesce(p_as_of, now());
    v_claim_type   text := nullif(trim(p_claim_type), '');
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

    r              record;
BEGIN
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
                  cardinality(da.claim_types) = 0
                  OR (v_claim_type IS NOT NULL AND v_claim_type = ANY (da.claim_types))
              )
              AND (
                  da.scope_ref IS NULL
                  OR p_scope_ref IS NULL
                  OR da.scope_ref = p_scope_ref
              )
            ORDER BY da.authority_kind, da.authority_ref, da.id
        LOOP
            v_matches := true;

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

            IF rye_settler_is_agent(r.authority_ref, v_node_id) THEN
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
    -- Which default applies is selected by the speech act, not by the claim
    -- type. A claim about a relationship edge type has no default and falls
    -- through: the reporting line is settled by the area, not by either end.
    -- ----------------------------------------------------------------------
    v_recognized := coalesce(v_speech_act IN (
        'self_commitment', 'self_report', 'expectation',
        'statement_about_other', 'statement_about_thing',
        'agreement', 'decision', 'outside_report', 'agent_inference'
    ), false);

    IF v_speech_act IN ('self_commitment', 'self_report') THEN
        v_want_self := true;
    ELSIF v_speech_act = 'expectation' THEN
        v_want_manager := true;
    ELSIF v_speech_act = 'statement_about_other' THEN
        v_want_self := true;
        v_want_manager := true;
    ELSIF v_speech_act = 'statement_about_thing' THEN
        v_want_owner := true;
    ELSIF v_speech_act IN ('agreement', 'decision', 'outside_report', 'agent_inference') THEN
        NULL;  -- no relationship default; fall through to the area owner
    ELSE
        -- Null or unrecognized: the union of whichever defaults apply.
        v_want_self := true;
        v_want_owner := true;
        v_want_manager := true;
    END IF;

    IF NOT v_halt
       AND v_step = 'none'
       AND v_subject_found
       AND coalesce(v_claim_type, '') NOT IN ('reports_to', 'owns') THEN

        -- Self: a person settles claims about themselves, with no setup.
        IF v_want_self AND v_subject.node_type = 'person' THEN
            IF rye_settler_is_agent(NULL::text, v_subject.id) THEN
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
                IF rye_settler_is_agent(NULL::text, r.node_id) THEN
                    v_excluded := v_excluded + 1;
                    CONTINUE;
                END IF;

                v_owners := v_owners || jsonb_build_object(
                    'kind',         rye_settler_node_kind(r.node_type),
                    'node_id',      r.node_id,
                    'ref',          CASE
                                        WHEN r.external_source IS NOT NULL AND r.external_id IS NOT NULL
                                        THEN r.external_source || ':' || r.external_id
                                    END,
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
                IF rye_settler_is_agent(NULL::text, r.node_id) THEN
                    v_excluded := v_excluded + 1;
                    CONTINUE;
                END IF;

                v_managers := v_managers || jsonb_build_object(
                    'kind',         rye_settler_node_kind(r.node_type),
                    'node_id',      r.node_id,
                    'ref',          CASE
                                        WHEN r.external_source IS NOT NULL AND r.external_id IS NOT NULL
                                        THEN r.external_source || ':' || r.external_id
                                    END,
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

            IF v_owner_node.id IS NULL THEN
                -- Archived, or hidden by RLS. Either way the caller gets the
                -- same empty answer and must read the reason.
                v_reason := 'area_owner_not_visible';
            ELSIF rye_settler_is_agent(NULL::text, v_owner_node.id) THEN
                v_excluded := v_excluded + 1;
                v_reason := 'area_owner_is_agent';
                v_setup_gap := true;
            ELSE
                v_settlers := jsonb_build_array(jsonb_build_object(
                    'kind',         rye_settler_node_kind(v_owner_node.node_type),
                    'node_id',      v_owner_node.id,
                    'ref',          CASE
                                        WHEN v_owner_node.external_source IS NOT NULL
                                         AND v_owner_node.external_id IS NOT NULL
                                        THEN v_owner_node.external_source || ':' || v_owner_node.external_id
                                    END,
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
    'Who may settle this claim, and which of three steps said so. One lookup: a recorded grant in domain_authorities for this claim type, then the relationship between speaker and subject (self, manager via reports_to, owner via owns), then knowledge_domains.owner_node_id for the area. Contract: contracts/sql-surface.md, section "Settlement lookup" (contract_version 1). SECURITY INVOKER and read-only: it writes nothing, refuses nothing, and raises nothing for a missing answer. p_claim_type is the assertion type verbatim. p_speech_act selects which relationship default applies. p_as_of filters effective windows only. An agent identity is never returned; dropped candidates are counted in excluded_agents. step ''none'' with settlers [] and a reason is an answer, not an error, and an empty list never means nobody is authorized, only nobody authorized and visible to this caller.';
