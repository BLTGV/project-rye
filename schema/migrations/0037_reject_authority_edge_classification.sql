-- Who may reject a suggestion, and an edge carries its own classification.
--
-- Work item: work/018-session-leftovers.md, second migration.
-- Contract:  contracts/sql-surface.md, "Who may reject a suggestion" and
--            "Edges carry their own classification".
-- Decision:  docs/decisions/0014-who-may-reject-and-edges-carry-their-own-classification.md
-- Tests:     tests/conformance/43_reject_authority_edge_classification.sql
-- Issues:    38, and the reject_candidate() finding recorded on 32.
--
-- Two holes of the same kind: a rule the product states in prose that the
-- database does not enforce.
--
-- One. Accepting a candidate is gated; closing one was not. reject_candidate()
-- (0019) checked a reason, a recognised outcome, and that the target was a live
-- candidate, and nothing at all about the caller. Executed as agent:intake on a
-- fresh install it closed another agent's suggestion, a team_member's
-- suggestion, and a registry_entry configuration suggestion. BRIEF.md says
-- agents suggest and people accept; a suggestion nobody can accept but any
-- agent can close is not a suggestion.
--
-- Two. edge_read_policy (0003) asked only whether both endpoints were visible,
-- so an edge marked {"classification":"confidential","teams":["locked"]} between
-- two public nodes was readable by a viewer and by a session with no role.
--
-- WHAT THIS PROTECTS AND WHAT IT DOES NOT, in the words the rest of the schema
-- uses. A caller holding a raw connection can set app.current_role to 'admin',
-- and nothing here changes that. What is protected is a deployment where a
-- trusted backend owns the session variables, and a well-behaved agent that
-- states its role honestly -- which is the population that produced the
-- finding. The admin API is a separate answer: its Worker sets
-- app.current_role = 'admin' for every query, so an agent rejecting through
-- POST /api/assertions/:id/reject is judged by that route's
-- rye.candidate.adjudicate capability and not by the authorship rule here.
-- Recorded in contracts/admin-api.md.

SET search_path = rye, pg_catalog, public;

-- ---------------------------------------------------------------------------
-- 1. Authorship. Rye writes it; the caller does not.
-- ---------------------------------------------------------------------------
--
-- assertions has no author column, and record_assertion() takes no actor
-- argument and records no event. attrs is whatever the caller passed. So the
-- stamp goes in the one place that cannot be skipped: a BEFORE INSERT trigger,
-- which covers every helper and the raw INSERT alike, and overwrites anything
-- the caller supplied. A caller therefore cannot claim another author, and
-- cannot change an existing row's attrs either -- 0025 makes attrs immutable
-- outside an outcome label.
--
-- attrs.recorded_by is app.current_role, which is which agent a session is.
-- attrs.recorded_by_label is app.current_user_id, which is a label and decides
-- nothing, exactly as "Governance tables" already says.
--
-- What this does NOT disturb:
--   * 0025's attrs rules. They judge UPDATEs; this is INSERT only. An outcome
--     labelling still may not drop a key, and recorded_by is now one of the
--     keys it must carry forward -- mark_assertion_outcome() writes
--     attrs || jsonb_build_object(...), which does.
--   * 0030's attrs.review_gate and 0023's attrs.settle_gate markers. The stamp
--     adds two keys and removes only its own two, so a marker a helper computed
--     before the INSERT survives.
--   * any helper's own attrs keys, for the same reason.
--   * merge_nodes()' copies. A copy is a new row, and it carries the recorded_by
--     of the session that ran the merge, not of whoever wrote the original.
--     That is the honest answer: the merging session is what put that row on the
--     canonical node, the original row is still there with its own author, and
--     the copy is not a suggestion the original author made.
--
-- Trigger order. trg_assertion_authorship_stamp sorts BEFORE
-- trg_assertion_settle_gate ('a' < 's' after the shared 'trg_assertion_'
-- prefix, in C and in en_US.UTF-8) and so before every other BEFORE ROW trigger
-- on assertions. That is safe because this trigger never raises and never reads
-- another trigger's output: it adds two keys to attrs and returns. No refusal
-- message moves, so tests/conformance/30_configuration_gate.sql still sees the
-- settle gate's message first. Sorting first is in fact the useful order: the
-- settle gate and the insert-review guard run on a row that already carries its
-- author.
--
-- A non-object attrs is left alone rather than coerced. Such a row carries no
-- readable recorded_by, which makes it unattributed, which is restrictive: no
-- agent may close it. Escaping the stamp can only cost a caller authority.
CREATE OR REPLACE FUNCTION assertion_authorship_stamp() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_attrs jsonb;
    v_label text := nullif(current_setting('app.current_user_id', true), '');
    v_role  text := nullif(current_setting('app.current_role', true), '');
BEGIN
    IF NEW.attrs IS NULL OR jsonb_typeof(NEW.attrs) <> 'object' THEN
        RETURN NEW;
    END IF;

    -- Removed first and unconditionally, so a caller cannot keep a value it
    -- supplied by writing it under a session that has no role.
    v_attrs := NEW.attrs - 'recorded_by' - 'recorded_by_label';

    IF v_role IS NOT NULL THEN
        v_attrs := v_attrs || jsonb_build_object('recorded_by', v_role);
    END IF;
    IF v_label IS NOT NULL THEN
        v_attrs := v_attrs || jsonb_build_object('recorded_by_label', v_label);
    END IF;

    NEW.attrs := v_attrs;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION assertion_authorship_stamp() IS
    'BEFORE INSERT on assertions: write attrs.recorded_by from app.current_role and attrs.recorded_by_label from app.current_user_id, overwriting anything the caller supplied, on every route. Never raises. A non-object attrs is left untouched and so unattributed, which is restrictive.';

DROP TRIGGER IF EXISTS trg_assertion_authorship_stamp ON assertions;
CREATE TRIGGER trg_assertion_authorship_stamp
    BEFORE INSERT ON assertions
    FOR EACH ROW
    EXECUTE FUNCTION assertion_authorship_stamp();

-- ---------------------------------------------------------------------------
-- 2. The rejection authority, as a trigger on the rejection shape.
-- ---------------------------------------------------------------------------
--
-- The helper's refusal is not the rule, because the raw route exists: 0008
-- deliberately allows a candidate to be closed with superseded_by null, and any
-- caller can set app.write_path itself. So the rule is here, on the shape:
--
--     OLD.status = 'candidate'
--     OLD.superseded_at IS NULL
--     NEW.superseded_at IS NOT NULL
--     NEW.superseded_by IS NULL
--
-- and on nothing else. A candidate closed WITH a replacement is a displacement,
-- judged by the rules that already judge it; reject_candidate() is the only
-- helper in the repository that passes mark_assertion_superseded(id, NULL).
--
-- The table:
--
--   admin                     any live candidate, configuration included
--   named role with may_write any except a settle-gated configuration type
--   agent-shaped              only one whose attrs.recorded_by is its own role,
--                             and never a settle-gated configuration type
--   viewer, unset, unknown    none. trg_assertions_gate_may_write (0026) sorts
--                             before this trigger and refuses them first; the
--                             branch here is the second line, not the first.
--
-- Closing a configuration suggestion is deciding it. The settle gate's promise
-- is that nothing said is lost: a non-admin's configuration write is demoted to
-- a candidate an admin decides on. If any writing role could close that
-- candidate, the demotion would promise nothing -- a caller who cannot set
-- configuration could still make sure nobody else's proposal reached an admin.
-- The gated set is the same data the write side reads, assertion_type_access
-- through assertion_settle_roles(), tested on the stored spelling and on the
-- spelling canonical_type() resolves it to. Nothing said is lost under this
-- rule either: a rejected candidate is closed, not deleted, and it appears in
-- rejected_candidates with who closed it, when, and why.
--
-- rye_settlers() is NOT consulted. It stays advisory and nothing in a write
-- path calls it. It answers from rows the caller can see, so an answer of
-- "nobody" is often blindness, and a refusal derived from it would vary by
-- classification and by area membership, which is not a rule.
--
-- Unknown authorship is not own authorship. A row written before this migration
-- carries no recorded_by; no agent may close it and a person must. attrs is
-- immutable, so there is no route to backfill, and that is the correct answer.
--
-- Trigger order. trg_assertions_reject_authority sorts after
-- trg_assertion_settle_gate, trg_assertions_gate_may_write and
-- trg_assertions_immutable, so no existing refusal message moves; it sorts
-- before 0036's trg_assertions_review_policy_value, which judges a different
-- kind of row.
CREATE OR REPLACE FUNCTION assertion_rejection_authority_guard() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_author text := OLD.attrs->>'recorded_by';
    v_canon  text;
    v_gated_as text;
    v_marked boolean := false;
    v_roles  text[];
    v_role   text := coalesce(nullif(current_setting('app.current_role', true), ''), '');
BEGIN
    -- The rejection shape, and only it.
    IF NOT (OLD.status = 'candidate'
            AND OLD.superseded_at IS NULL
            AND NEW.superseded_at IS NOT NULL
            AND NEW.superseded_by IS NULL)
    THEN
        RETURN NEW;
    END IF;

    -- Configuration first: it binds every caller, agent or person, and its
    -- message is the more specific one.
    v_roles := assertion_settle_roles(OLD.assertion_type);
    IF v_roles IS NULL THEN
        v_canon := canonical_type('assertion_type', OLD.assertion_type);
        IF v_canon IS DISTINCT FROM OLD.assertion_type THEN
            v_roles := assertion_settle_roles(v_canon);
        END IF;
    END IF;

    -- 0036 demotes a write whose WRITTEN name is gated even where the stored
    -- canonical type is not -- the pre-gate alias case -- and marks the row
    -- attrs.settle_gate with the allowed roles and the spelling that gated it.
    -- That marker is this row's gate, exactly as it is for
    -- assertion_settle_gate_guard(): a suggestion waiting for an admin must
    -- not be closable by the role the demotion excluded, or the demotion
    -- promises nothing. Read only when neither type lookup answered, so a
    -- forged marker can add refusals and never remove one, and 0025 makes it
    -- unstrippable.
    IF v_roles IS NULL
       AND jsonb_typeof(OLD.attrs->'settle_gate'->'allowed_roles') = 'array'
    THEN
        SELECT coalesce(array_agg(role.value #>> '{}'), '{}'::text[])
        INTO v_roles
        FROM jsonb_array_elements(OLD.attrs->'settle_gate'->'allowed_roles') AS role(value);
        v_marked := true;
        v_gated_as := coalesce(
            nullif(OLD.attrs->'settle_gate'->>'gated_as', ''), OLD.assertion_type
        );
    END IF;

    IF v_roles IS NOT NULL THEN
        IF v_role = ANY(v_roles) THEN
            RETURN NEW;
        END IF;

        -- Where the MARKER is the gate, an admin always qualifies, whatever
        -- the array holds. attrs is caller-supplied on a raw INSERT, so an
        -- empty allowed_roles -- or one naming roles that exclude admin --
        -- otherwise parks a suggestion nobody with the authority to clear it
        -- can accept or reject. An admin must never be locked out of the
        -- queue. This widens nothing: a gated STORED type is judged by
        -- assertion_type_access above, and an admin already settles those.
        -- 0036 applies the same rule on the acceptance half.
        IF v_marked AND v_role = 'admin' THEN
            RETURN NEW;
        END IF;

        -- One exception, and only on the marker: the author withdraws its
        -- own, whatever shape of role it is. The stored type is ungated, so
        -- the row is an ordinary suggestion that happened to be written under
        -- a gated spelling, and withdrawing your own words decides nobody
        -- else's -- the configuration is unchanged either way. The correction
        -- route the agent-ops guide and three skills document (close your own
        -- pending suggestion, file a corrected one) has to keep working, and
        -- a person who wrote one is in exactly the same position. Closing
        -- SOMEBODY ELSE'S is the harm, and it is still refused. Unknown
        -- authorship is not own authorship, as everywhere. A row whose stored
        -- type is gated has no such exception: there, closing is deciding,
        -- whoever wrote it.
        IF v_marked AND v_author IS NOT NULL AND v_author = v_role THEN
            RETURN NEW;
        END IF;

        IF v_marked THEN
            RAISE EXCEPTION
                'Assertion % is waiting on the settle gate for Rye configuration type %: only % may close a suggestion of that type, because closing it is deciding it. Its author may still withdraw it.',
                OLD.id,
                v_gated_as,
                array_to_string(v_roles, ', ')
                USING ERRCODE = 'insufficient_privilege';
        END IF;

        RAISE EXCEPTION
            'Assertion type % is Rye configuration: only % may close a suggestion of that type, because closing it is deciding it.',
            OLD.assertion_type,
            array_to_string(v_roles, ', ')
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- A session that may not write may not close. Unreachable through the
    -- may-write gate, which sorts first; kept because this trigger is the rule
    -- and must stand on its own.
    IF NOT rye_role_may_write() THEN
        RAISE EXCEPTION
            'Closing a suggestion is a decision, and "%" may not write this instance. A named writing role or an admin closes it.',
            v_role
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF v_role LIKE 'agent:%' THEN
        IF v_author IS NULL OR v_author IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION
                'Rejecting a suggestion recorded by "%" is a person''s call; "%" may close only its own. Record your correction as a new suggestion and say what you disagree with.',
                coalesce(v_author, 'nobody recorded'),
                v_role
                USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION assertion_rejection_authority_guard() IS
    'BEFORE UPDATE on assertions, firing only on the rejection shape (a live candidate ending with no replacement). An admin closes any; a named writing role closes any except a settle-gated configuration type, tested on the stored spelling, on the canonical one, and -- where both are ungated -- on attrs.settle_gate.allowed_roles, the marker 0036 writes when the written name was gated, where an admin always qualifies and the author of that row may still withdraw it; an agent-shaped session closes only a candidate whose attrs.recorded_by is its own role. Unknown authorship is not own authorship.';

DROP TRIGGER IF EXISTS trg_assertions_reject_authority ON assertions;
CREATE TRIGGER trg_assertions_reject_authority
    BEFORE UPDATE ON assertions
    FOR EACH ROW
    EXECUTE FUNCTION assertion_rejection_authority_guard();

-- ---------------------------------------------------------------------------
-- 3. reject_candidate() refuses first, with a sentence.
-- ---------------------------------------------------------------------------
--
-- Replaced from 0019 with the same signature, the same SECURITY DEFINER
-- setting, the same search_path, and the same candidate_rejected event with the
-- same properties keys -- assertion_id, reason, outcome -- so 0035's
-- rejected_candidates view stays correct. The only change is the gate, and
-- where it sits: before the outcome label and before the row is marked, as
-- merge_nodes() and score_due_predictions() were taught. A refused rejection
-- records no event, which is correct: the candidate is still waiting.
--
-- The gate duplicates the trigger's conditions rather than calling a shared
-- helper, because the two answer different questions: the trigger is the rule
-- and must bind the raw route, the helper gives a caller a sentence instead of
-- a trigger error or a silent zero rows. Keep them in step; the conformance
-- suite drives both.
CREATE OR REPLACE FUNCTION reject_candidate(
    p_assertion_id uuid,
    p_reason text,
    p_actor text DEFAULT NULL,
    p_outcome text DEFAULT NULL
) RETURNS void
SECURITY DEFINER
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_author text;
    v_canon text;
    v_candidate assertions;
    v_gated_as text;
    v_marked boolean := false;
    v_outcome text := lower(nullif(trim(coalesce(p_outcome, '')), ''));
    v_participant_ids uuid[];
    v_participant_roles text[];
    v_role text := coalesce(nullif(current_setting('app.current_role', true), ''), '');
    v_settle_roles text[];
BEGIN
    IF nullif(trim(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'Candidate rejection reason is required';
    END IF;
    IF v_outcome IS NOT NULL AND v_outcome NOT IN ('incorrect', 'unsupported', 'duplicate', 'stale') THEN
        RAISE EXCEPTION 'Unsupported candidate rejection outcome: %', p_outcome;
    END IF;

    SELECT * INTO v_candidate FROM assertions WHERE id = p_assertion_id;
    IF NOT FOUND OR v_candidate.status <> 'candidate' OR v_candidate.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION 'Assertion % is not a live candidate', p_assertion_id;
    END IF;

    -- The gate, before anything is written.
    v_settle_roles := assertion_settle_roles(v_candidate.assertion_type);
    IF v_settle_roles IS NULL THEN
        v_canon := canonical_type('assertion_type', v_candidate.assertion_type);
        IF v_canon IS DISTINCT FROM v_candidate.assertion_type THEN
            v_settle_roles := assertion_settle_roles(v_canon);
        END IF;
    END IF;

    -- 0036's marker is this row's gate where neither type lookup answered.
    -- Same rule and same exception as the trigger; see its comment.
    IF v_settle_roles IS NULL
       AND jsonb_typeof(v_candidate.attrs->'settle_gate'->'allowed_roles') = 'array'
    THEN
        SELECT coalesce(array_agg(role.value #>> '{}'), '{}'::text[])
        INTO v_settle_roles
        FROM jsonb_array_elements(v_candidate.attrs->'settle_gate'->'allowed_roles') AS role(value);
        v_marked := true;
        v_gated_as := coalesce(
            nullif(v_candidate.attrs->'settle_gate'->>'gated_as', ''),
            v_candidate.assertion_type
        );
    END IF;

    IF v_settle_roles IS NOT NULL THEN
        v_author := v_candidate.attrs->>'recorded_by';
        IF NOT (v_role = ANY(v_settle_roles))
           AND NOT (v_marked AND v_role = 'admin')
           AND NOT (v_marked AND v_author IS NOT NULL AND v_author = v_role)
        THEN
            IF v_marked THEN
                RAISE EXCEPTION
                    'Assertion % is waiting on the settle gate for Rye configuration type %: only % may close a suggestion of that type, because closing it is deciding it. Its author may still withdraw it.',
                    p_assertion_id,
                    v_gated_as,
                    array_to_string(v_settle_roles, ', ')
                    USING ERRCODE = 'insufficient_privilege';
            END IF;
            RAISE EXCEPTION
                'Assertion type % is Rye configuration: only % may close a suggestion of that type, because closing it is deciding it.',
                v_candidate.assertion_type,
                array_to_string(v_settle_roles, ', ')
                USING ERRCODE = 'insufficient_privilege';
        END IF;
    ELSIF NOT rye_role_may_write() THEN
        RAISE EXCEPTION
            'Closing a suggestion is a decision, and "%" may not write this instance. A named writing role or an admin closes it.',
            v_role
            USING ERRCODE = 'insufficient_privilege';
    ELSIF v_role LIKE 'agent:%' THEN
        v_author := v_candidate.attrs->>'recorded_by';
        IF v_author IS NULL OR v_author IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION
                'Rejecting a suggestion recorded by "%" is a person''s call; "%" may close only its own. Record your correction as a new suggestion and say what you disagree with.',
                coalesce(v_author, 'nobody recorded'),
                v_role
                USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;

    IF v_outcome IS NOT NULL THEN
        PERFORM mark_assertion_outcome(p_assertion_id, v_outcome, jsonb_build_object('outcome_reason', p_reason));
    END IF;
    PERFORM mark_assertion_superseded(p_assertion_id, NULL);

    IF v_candidate.subject_node_id IS NOT NULL THEN
        v_participant_ids := ARRAY[v_candidate.subject_node_id];
        v_participant_roles := ARRAY['subject'];
    ELSE
        SELECT ARRAY[source_id, target_id], ARRAY['edge_source', 'edge_target']
        INTO v_participant_ids, v_participant_roles
        FROM edges WHERE id = v_candidate.subject_edge_id;
    END IF;

    PERFORM record_event(
        p_event_type := 'candidate_rejected',
        p_summary := format('Rejected candidate assertion %s/%s', v_candidate.assertion_type, v_candidate.assertion_key),
        p_properties := jsonb_build_object(
            'assertion_id', p_assertion_id,
            'reason', p_reason,
            'outcome', v_outcome
        ),
        p_participant_ids := coalesce(v_participant_ids, '{}'::uuid[]),
        p_participant_roles := coalesce(v_participant_roles, '{}'::text[]),
        p_actor := p_actor
    );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION reject_candidate(uuid, text, text, text) IS
    'Close a live candidate with a reason and an optional outcome label, recording a candidate_rejected event. Refuses before it writes anything: a settle-gated configuration type -- by stored spelling, canonical spelling, or 0036''s attrs.settle_gate marker -- is closed only by its settle roles, except that on the marker an admin always qualifies and the author may withdraw its own; an agent-shaped session otherwise closes only a candidate it authored. The rule itself is trg_assertions_reject_authority, which binds the raw route too.';

-- ---------------------------------------------------------------------------
-- 4. An edge carries its own classification.
-- ---------------------------------------------------------------------------
--
-- Enforced, not documented away. The alternative -- rule that edges classify
-- only through their endpoints and say so -- was considered and rejected in the
-- decision record. Marking a row is an operator asking for something, and a
-- mark that silently does nothing is worse than no mark.
--
-- The rule is the node rule, ANDed with endpoint visibility, with the nouns
-- changed. access_grants has no CHECK on resource_type, so resource_type =
-- 'edge' with scope->>'edge_id', 'edge_type' or 'classification' needs no
-- constraint change.
--
-- There is no admin exemption, because node_read_policy has none: an admin
-- session reads a classified node only through app.current_teams or an
-- access_grants row, and the edge rule inherits that property unchanged.
--
-- Cost: a query over unmarked edges pays two boolean tests and nothing else.
-- The access_grants subquery runs only when the first three tests all fail,
-- which is the same shape node_read_policy has always had.
--
-- What cascades, and what does not. Assertions on an edge inherit it for free:
-- assertion_read_policy already requires EXISTS (SELECT 1 FROM edges WHERE id =
-- assertions.subject_edge_id). Traversal inherits it for free: find_paths() and
-- neighborhood() (0032) are security_invoker and read edges under the caller's
-- policies. event_participants does not cascade and needs nothing -- it
-- references node_id only, and an edge is never an event participant.
--
-- Blast radius on this tree: nil. No migration, test, seed, fixture, replay
-- load, admin query or skill writes classification or teams into an edge's
-- attrs, so every existing edge takes the `classification IS NULL` branch and
-- no row changes visibility.
DROP POLICY IF EXISTS edge_read_policy ON edges;
CREATE POLICY edge_read_policy ON edges
    FOR SELECT
    USING (
        EXISTS (SELECT 1 FROM nodes WHERE id = edges.source_id)
        AND EXISTS (SELECT 1 FROM nodes WHERE id = edges.target_id)
        AND (
            attrs->>'classification' IS NULL
            OR attrs->>'classification' = 'public'
            OR attrs->'teams' ?| coalesce(string_to_array(current_setting('app.current_teams', true), ','), ARRAY[]::text[])
            OR EXISTS (
                SELECT 1
                FROM access_grants ag
                WHERE ag.active = true
                  AND ag.resource_type = 'edge'
                  AND (
                      ag.grantee = current_setting('app.current_user_id', true)
                      OR ag.grantee = current_setting('app.current_role', true)
                      OR ag.grantee = ANY(coalesce(string_to_array(current_setting('app.current_teams', true), ','), ARRAY[]::text[]))
                  )
                  AND (
                      ag.scope->>'edge_id' = edges.id::text
                      OR ag.scope->>'edge_type' = edges.edge_type
                      OR ag.scope->>'classification' = edges.attrs->>'classification'
                  )
            )
        )
    );

-- The write side matches the node rule too. Without it the read rule's
-- `classification IS NULL` branch makes a team-marked edge world-readable,
-- which is the same hole one table over.
--
-- The trigger judges writes, not history: an edge already carrying teams and no
-- classification stays readable to everyone until somebody sets a
-- classification on it, and setting one is an UPDATE this trigger then accepts.
CREATE OR REPLACE FUNCTION enforce_edge_classification_with_teams() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
BEGIN
    IF NEW.attrs ? 'teams'
       AND jsonb_typeof(NEW.attrs->'teams') = 'array'
       AND jsonb_array_length(NEW.attrs->'teams') > 0
       AND (NEW.attrs->>'classification') IS NULL
    THEN
        RAISE EXCEPTION 'Edges with teams must have classification set in attrs (e.g. "internal", "confidential", "restricted")';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION enforce_edge_classification_with_teams() IS
    'BEFORE INSERT OR UPDATE on edges. Refuses a non-empty attrs.teams with no attrs.classification, exactly as enforce_classification_with_teams() has refused it on nodes since 0001, because edge_read_policy''s classification IS NULL branch would otherwise make a team-marked edge world-readable.';

DROP TRIGGER IF EXISTS trg_edges_classification_check ON edges;
CREATE TRIGGER trg_edges_classification_check
    BEFORE INSERT OR UPDATE ON edges
    FOR EACH ROW
    EXECUTE FUNCTION enforce_edge_classification_with_teams();
