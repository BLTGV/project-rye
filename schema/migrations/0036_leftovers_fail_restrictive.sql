-- Leftovers fail restrictive.
--
-- Work item: work/018-session-leftovers.md, the schema criteria.
-- Contract:  contracts/sql-surface.md, "Configuration writes need an admin"
--            (the written-name settle gate) and "An unsupported policy value
--            is strict, and cannot be recorded";
--            contracts/category-vocabulary.md, "Describing a category, twice,
--            as an agent".
-- Decision:  docs/decisions/0013-leftovers-fail-restrictive.md, A, B and E.
-- Tests:     tests/conformance/42_leftovers.sql,
--            tests/conformance/16_cli_smoke.sh (the CLI half of F).
--
-- Three things that were recorded as "known, left open" while items 001 to 011
-- closed, each made restrictive rather than fatal or silent.
--
-- A. THE SETTLE GATE JUDGES THE WRITTEN NAME AS WELL AS THE CANONICAL ONE.
-- 0028 refuses a NEW registry_entry keyed type_alias:assertion_type:<T> when T
-- has a `settle` row, so an alias out of a gated type cannot be recorded today.
-- An alias recorded BEFORE the type was gated is untouched by that rule and
-- still stands, and record_assertion() canonicalizes before it reads
-- assertion_settle_roles(), so a caller writing `review_policy` under such an
-- alias is judged on the alias target -- which has no settle row -- and the
-- gate never fires. From here a type is gated for record_assertion() when
-- EITHER spelling is gated, and the demotion's attrs.settle_gate carries
-- `gated_as` naming the spelling that gated it, so a reviewer can see why a
-- write of an apparently ungated type is waiting. settle_gate() answers by the
-- same rule and gains `gated_as` beside `gated`, null when the spelling the
-- caller passed is itself the gated one.
--
-- Everything else is left alone deliberately. assertion_settle_gate_guard()
-- keeps judging the stored spelling: it never sees the name a caller wrote, and
-- the stored spelling is the only one registry_value() and governing_scope()
-- read as configuration. supersede_assertion() takes the type from the
-- incumbent row and has no written name to judge. record_distillation() under a
-- standing pre-gate alias writes the alias target type, which Rye does not read
-- as configuration: a policy no-op, stated rather than closed.
--
-- B. AN UNSUPPORTED REVIEW POLICY VALUE IS STRICT, AND CANNOT BE RECORDED.
-- scope_review_policy() raised for any stored value outside open,
-- candidates_only, strict. Because every helper that inserts an assertion calls
-- it, one scope carrying a typo refused every write it governed. A
-- configuration mistake should make Rye careful, not make it stop. So reading
-- an unrecognised value returns `strict` and ranks 0, neither function raises
-- for any input, and writing one is refused by record_scope_policy() and by a
-- new trigger on assertions at every status for every role.
--
-- B2, ADDED AFTER EXECUTION ON MAIN (2026-09-20). The extraction reads
-- claim->>'review_policy', then claim->>'value', then a string claim. A
-- review_policy row whose claim carries NONE of those -- `{"policy":"strict"}`,
-- `{"review_policy":null}`, `null`, `{}` -- fell through the old coalesce to
-- the literal 'open' and was read as OPEN. That is the same fail-open as an
-- unsupported value and gets the same treatment: a row that EXISTS and cannot
-- be read is `strict` and ranks 0, and it cannot be recorded. The distinction
-- the contract makes is kept exactly: a scope with NO review_policy row at all
-- still reads `open` and ranks 2. Absent is not broken; present and unreadable
-- is broken. One helper, review_policy_claim_value(), now holds the extraction
-- so the four sites cannot drift apart.
--
-- WHAT AN UPGRADE DOES TO AN INSTANCE THAT ALREADY HOLDS ONE OF EITHER. Nothing
-- at install time: no data is rewritten and no migration refuses. A standing
-- pre-gate alias keeps resolving for every other purpose; from the first write
-- after this file, a non-admin naming the gated type gets a candidate carrying
-- attrs.settle_gate with gated_as set. A standing broken policy value keeps its
-- row and reads `strict` from the first call, so writes it governs land as
-- candidates in review_queue instead of being refused. The fix is an admin
-- recording a supported value with record_scope_policy(), which works even
-- under the new strict, because governing_scope() returns null for a scope
-- node's own policy assertions -- and the new trigger deliberately does not
-- refuse an UPDATE that leaves the claim alone and does not make the row
-- accepted, so the standing bad row can still be superseded, ended, or
-- rejected. A row that cannot be repaired is worse than a row that is wrong.
--
-- E. A REPEAT describe_category() WORKS FOR AN AGENT. The function upserts the
-- category node with ON CONFLICT DO UPDATE, and node_update_policy admits an
-- agent:* caller's UPDATE only with app.write_path = 'update_node_properties'.
-- So the first description by an agent succeeded and the second was refused,
-- and conformance 28 never saw it because it runs as admin. A client must never
-- set the named gate itself, so the function sets it transaction-locally around
-- its own upsert and clears it on the normal and the exception path -- the
-- mechanism record_agent_action() and agent_create_candidate() already use.
-- Nothing else about the function changes, and a viewer or an unset role is
-- still refused by the write gate one layer below.

SET search_path = rye, pg_catalog, public;

-- --------------------------------------------------------------------------
-- 0. One place the review policy value is read from
-- --------------------------------------------------------------------------
--
-- Three shapes are accepted, in this order, and they are the three
-- scope_review_policy() has always accepted: {"review_policy": "..."},
-- {"value": "..."}, and a bare JSON string. NULL means the claim carries no
-- readable value at all, which is a broken row, not an absent one.
CREATE OR REPLACE FUNCTION review_policy_claim_value(p_claim jsonb)
RETURNS text
SET search_path = rye, pg_catalog
AS $$
    SELECT lower(coalesce(
        nullif(p_claim->>'review_policy', ''),
        nullif(p_claim->>'value', ''),
        CASE WHEN jsonb_typeof(p_claim) = 'string'
             THEN nullif(p_claim #>> '{}', '') END
    ));
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION review_policy_claim_value(jsonb) IS
    'The review policy value a review_policy claim carries, lowercased: claim->>''review_policy'', then claim->>''value'', then a bare string claim. NULL when the claim carries none of those, which is a row that exists and cannot be read. The single extraction every review-policy site uses.';

CREATE OR REPLACE FUNCTION review_policy_value_supported(p_claim jsonb)
RETURNS boolean
SET search_path = rye, pg_catalog
AS $$
    SELECT coalesce(
        review_policy_claim_value(p_claim) IN ('open', 'candidates_only', 'strict'),
        false
    );
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION review_policy_value_supported(jsonb) IS
    'True when a review_policy claim reads as one of open, candidates_only, strict. False for an unsupported value AND for a claim with no readable value, because both fail the same way.';

-- --------------------------------------------------------------------------
-- 1. Reading a review policy never raises
-- --------------------------------------------------------------------------
--
-- Replaces the 0018 body. Same row, same order, same absent-is-open answer.
-- What changes: a row that exists and reads as something Rye does not support,
-- or reads as nothing at all, returns `strict` instead of raising.
CREATE OR REPLACE FUNCTION scope_review_policy(p_scope_id uuid)
RETURNS text
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_claim  jsonb;
    v_policy text;
BEGIN
    IF p_scope_id IS NULL THEN
        RETURN 'open';
    END IF;

    SELECT a.claim
    INTO v_claim
    FROM current_valid_assertions a
    WHERE a.subject_node_id = p_scope_id
      AND a.assertion_type = 'review_policy'
      AND a.assertion_key = 'default'
    ORDER BY a.asserted_at DESC, a.id
    LIMIT 1;

    -- Absent is not broken. A scope that has never been given a policy is open,
    -- which is what it was before this file and what the contract promises.
    IF NOT FOUND THEN
        RETURN 'open';
    END IF;

    v_policy := review_policy_claim_value(v_claim);
    IF v_policy IS NULL OR v_policy NOT IN ('open', 'candidates_only', 'strict') THEN
        RETURN 'strict';
    END IF;
    RETURN v_policy;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION scope_review_policy(uuid) IS
    'The review policy governing a scope: open, candidates_only, or strict. A scope with no review_policy assertion, and a null scope, read open. A row that exists but carries a value Rye does not support, or no readable value at all, reads strict. Never raises, for any input.';

-- Replaces the 0027 body. Ordering and selection must agree, or governing_scope()
-- would rank a broken scope as the loosest and then read it as the strictest.
-- 0 strict, 1 candidates_only, 2 open, 0 for anything else INCLUDING a claim
-- with no readable value. No row at all still ranks 2.
CREATE OR REPLACE FUNCTION scope_review_policy_rank(p_scope_id uuid)
RETURNS int
SET search_path = rye, pg_catalog
AS $$
    SELECT coalesce(
        (
            SELECT CASE review_policy_claim_value(a.claim)
                    WHEN 'strict' THEN 0
                    WHEN 'candidates_only' THEN 1
                    WHEN 'open' THEN 2
                    ELSE 0
                   END
            FROM current_valid_assertions a
            WHERE p_scope_id IS NOT NULL
              AND a.subject_node_id = p_scope_id
              AND a.assertion_type = 'review_policy'
              AND a.assertion_key = 'default'
            ORDER BY a.asserted_at DESC, a.id
            LIMIT 1
        ),
        2
    );
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION scope_review_policy_rank(uuid) IS
    'How restrictive a scope''s review policy is: 0 strict, 1 candidates_only, 2 open. A stored value Rye does not support, and a claim with no readable value, rank 0, because scope_review_policy() reads both as strict and ordering must agree with selection. A null scope and a scope with no review_policy assertion rank 2. Never raises.';

-- effective_review_policy() (0027) is deliberately unchanged. It composes
-- scope_review_policy() and scope_review_policy_rank() and inherits both
-- answers, so a broken scope is strict there too without a line of its own.

-- --------------------------------------------------------------------------
-- 2. An unsupported review policy value cannot be recorded
-- --------------------------------------------------------------------------
--
-- The helper refuses plainly, because a row nobody can read back is worse than
-- an error at the write. Carried forward from 0015 with one block added.
CREATE OR REPLACE FUNCTION record_scope_policy(
    p_scope_id uuid,
    p_policy_type text,
    p_claim jsonb,
    p_assertion_key text DEFAULT 'default',
    p_actor text DEFAULT NULL,
    p_effective_at timestamptz DEFAULT NULL,
    p_effective_to timestamptz DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_id uuid;
    v_event_id uuid;
    v_policy_type text;
BEGIN
    v_policy_type := nullif(trim(p_policy_type), '');

    IF v_policy_type IS NULL THEN
        RAISE EXCEPTION 'policy_type is required';
    END IF;

    IF p_claim IS NULL THEN
        RAISE EXCEPTION 'claim is required';
    END IF;

    -- 0036: a review policy carries one of three values and nothing else. This
    -- refuses before the event is recorded, so a refused policy leaves no trace
    -- of an act that did not happen.
    IF v_policy_type = 'review_policy'
       AND NOT review_policy_value_supported(p_claim)
    THEN
        RAISE EXCEPTION
            'Unsupported review_policy "%": use open, candidates_only, or strict',
            coalesce(review_policy_claim_value(p_claim), '');
    END IF;

    IF p_effective_at IS NOT NULL
       AND p_effective_to IS NOT NULL
       AND p_effective_to <= p_effective_at
    THEN
        RAISE EXCEPTION 'effective_to must be after effective_at';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE id = p_scope_id
          AND node_type = 'onboarding_scope'
          AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Onboarding scope % not found', p_scope_id;
    END IF;

    v_event_id := record_event(
        p_event_type        := 'scope_policy_recorded',
        p_summary           := format('Scope policy recorded: %s', v_policy_type),
        p_properties        := jsonb_build_object(
            'scope_id', p_scope_id,
            'policy_type', v_policy_type,
            'assertion_key', coalesce(nullif(trim(p_assertion_key), ''), 'default'),
            'effective_at', p_effective_at,
            'effective_to', p_effective_to
        ),
        p_participant_ids   := ARRAY[p_scope_id],
        p_participant_roles := ARRAY['scope'],
        p_actor             := p_actor
    );

    v_assertion_id := record_assertion(
        p_assertion_type  := v_policy_type,
        p_assertion_key   := p_assertion_key,
        p_subject_node_id := p_scope_id,
        p_claim           := p_claim,
        p_effective_at    := p_effective_at,
        p_effective_to    := p_effective_to,
        p_evidence         := ARRAY[jsonb_build_object('kind', 'source', 'event_id', v_event_id)],
        p_basis            := 'reported',
        p_confidence      := 1.0,
        p_attrs           := jsonb_build_object('policy_event_id', v_event_id)
    );

    RETURN v_assertion_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION record_scope_policy(uuid,text,jsonb,text,text,timestamptz,timestamptz) IS
    'Record a scope policy assertion with its own event. A review_policy claim whose value is outside open, candidates_only, strict -- or which carries no readable value at all -- is refused before anything is written.';

-- The helper's refusal is not the rule, because Rye's rule is that the row is
-- the gate. This trigger refuses the same claim on every route: a raw INSERT,
-- a SECURITY DEFINER helper, a superuser owner. It reads no role, so it refuses
-- for every role including admin, and it fires at every status, so an
-- unsupported value cannot be parked as a candidate and accepted later.
--
-- WHAT IT DOES NOT REFUSE, and why. An UPDATE that leaves the claim alone and
-- does not make the row accepted passes: superseding, ending, and rejecting a
-- standing bad row is how an instance that already holds one repairs itself,
-- and mark_assertion_superseded() reaches the incumbent through exactly that
-- shape. claim is immutable under trg_assertions_immutable anyway, so the
-- changed-claim branch is belt and braces.
--
-- THE STORED SPELLING is what it judges, like assertion_settle_gate_guard() and
-- for the same reason: scope_review_policy() matches the literal
-- `review_policy`, so a row stored under any other spelling is not read as a
-- review policy at all. record_assertion() canonicalizes before it inserts, so
-- an alias INTO review_policy is stored as review_policy and is judged here.
CREATE OR REPLACE FUNCTION assertion_review_policy_value_guard() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_becomes_accepted boolean;
BEGIN
    IF NEW.assertion_type <> 'review_policy' THEN
        RETURN NEW;
    END IF;

    v_becomes_accepted := NEW.status = 'accepted'
        AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'accepted');

    IF TG_OP = 'UPDATE'
       AND NEW.claim IS NOT DISTINCT FROM OLD.claim
       AND NOT v_becomes_accepted
    THEN
        RETURN NEW;
    END IF;

    IF review_policy_value_supported(NEW.claim) THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION
        'Unsupported review_policy "%": use open, candidates_only, or strict',
        coalesce(review_policy_claim_value(NEW.claim), '')
        USING ERRCODE = 'check_violation';
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION assertion_review_policy_value_guard() IS
    'Refuse any review_policy assertion whose claim does not read as open, candidates_only, or strict -- at every status, for every role, on every route. Reads no role. An UPDATE that leaves the claim alone and does not make the row accepted is allowed, so a standing bad row can still be superseded, ended, or rejected.';

DROP TRIGGER IF EXISTS trg_assertions_review_policy_value ON assertions;
CREATE TRIGGER trg_assertions_review_policy_value
    BEFORE INSERT OR UPDATE ON assertions
    FOR EACH ROW
    EXECUTE FUNCTION assertion_review_policy_value_guard();

-- --------------------------------------------------------------------------
-- 3. settle_gate() judges the written name as well as the canonical one
-- --------------------------------------------------------------------------
--
-- Replaces the 0023 body. `gated` is true when the spelling the caller passed
-- has a settle row OR its canonical spelling does; `allowed_roles` and
-- `may_settle` follow whichever gated it, so a client that asks before it
-- writes gets the answer record_assertion() will act on. `gated_as` names the
-- other spelling, and is null when the spelling passed in is itself the gated
-- one -- which is the ordinary case and says "nothing surprising here".
--
-- IT NORMALISES ITS ARGUMENT EXACTLY AS record_assertion() DOES, with the same
-- expression: nullif(trim(...), ''). Verification found that it did not, so
-- settle_gate(' review_policy ') answered gated false / may_settle true and
-- then record_assertion(' review_policy ', ...) demoted the write. Asking
-- first has to be truthful or a client cannot use it. The answer echoes the
-- normalised spelling, for the same reason.
--
-- A CASE VARIANT IS STILL A DIFFERENT TYPE. 'REVIEW_POLICY' is not trimmed to
-- 'review_policy' by either function, because neither lowercases: it is an
-- assertion type of its own, it is not gated, and a write under it lands
-- accepted as 'REVIEW_POLICY'. That is a policy no-op, not a hole -- nothing
-- reads that spelling as configuration, because registry_value() and
-- governing_scope() match the literal. It predates this file and is pinned in
-- tests/conformance/42_leftovers.sql so nobody reads it as a regression.
CREATE OR REPLACE FUNCTION settle_gate(p_assertion_type text)
RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_canonical text;
    v_gated_as  text;
    v_role      text := nullif(current_setting('app.current_role', true), '');
    v_roles     text[];
    v_type      text := nullif(trim(p_assertion_type), '');
BEGIN
    IF v_type IS NOT NULL THEN
        v_roles := assertion_settle_roles(v_type);

        IF v_roles IS NULL THEN
            v_canonical := canonical_type('assertion_type', v_type);
            IF v_canonical IS DISTINCT FROM v_type THEN
                v_roles := assertion_settle_roles(v_canonical);
                IF v_roles IS NOT NULL THEN
                    v_gated_as := v_canonical;
                END IF;
            END IF;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'assertion_type', v_type,
        'gated', v_roles IS NOT NULL,
        'gated_as', v_gated_as,
        'allowed_roles', CASE WHEN v_roles IS NULL THEN NULL::jsonb ELSE to_jsonb(v_roles) END,
        'current_role', v_role,
        'may_settle', v_roles IS NULL OR coalesce(v_role, '') = ANY(v_roles)
    );
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION settle_gate(text) IS
    'Answer {assertion_type, gated, gated_as, allowed_roles, current_role, may_settle} for an assertion type. The argument is normalised with nullif(trim(...), ''''), the same expression record_assertion() uses, and the answer echoes the normalised spelling. Gated when that spelling has a settle row or its canonical spelling does, which is the rule record_assertion() applies; gated_as names the other spelling and is null when the spelling given is itself the gated one. STABLE, SECURITY INVOKER, writes nothing. Call it before offering to record configuration.';

-- --------------------------------------------------------------------------
-- 3b. The demotion marker is itself a gate
-- --------------------------------------------------------------------------
--
-- Found by verification of the first cut of this file. Under a standing
-- pre-gate alias, record_assertion() demotes correctly -- the row lands
-- `candidate`, carries attrs.settle_gate {allowed_roles: ["admin"],
-- gated_as: "review_policy"}, and waits in review_queue -- but its STORED type
-- is the alias target, which is ungated, so assertion_settle_gate_guard() saw
-- an ordinary candidate and accept_assertion() promoted it FOR THE VERY ROLE
-- THE GATE HAD JUST EXCLUDED. The demotion was theatre: the caller was told to
-- wait and could then settle its own write. The contract says every route to an
-- accepted gated row raises, and review_queue tells the reviewer an admin is
-- required, so this is the gate failing, not the marker.
--
-- THE ROW IS THE GATE. The guard now reads the marker on the row when the
-- stored type is ungated, and refuses a promotion to accepted, and any change
-- to an already-accepted row, unless app.current_role is in
-- attrs.settle_gate.allowed_roles -- exactly the two refusals it already makes
-- for a gated stored type, with exactly the same shape.
--
-- WHY A FORGED MARKER GAINS NOTHING. The marker is consulted ONLY when
-- assertion_settle_roles(stored type) is NULL, so it can never override the
-- type gate and never widen anything: for an ungated type an accepted row was
-- always allowed, so a marker naming your own role leaves you exactly where you
-- were, and a marker naming another role only refuses you. It adds refusals and
-- removes none. It also cannot be washed off an existing row:
-- assertions_immutable_guard() (0025) refuses an UPDATE that drops an attrs key
-- or changes an existing key's value except as a real outcome labelling, which
-- must leave every pre-existing key untouched -- so the forged
-- `app.write_path = 'assertion_outcome'` route cannot strip settle_gate either.
-- Confirmed by execution, both owner types; the cases are in conformance 42.
--
-- An empty allowed_roles array gates and allows nobody, the same reading
-- assertion_type_access has, so it is not coalesced away into "ungated".
--
-- The whole 0028 body is carried forward below unchanged. The only new code is
-- the block marked 0036. The trigger, its name, and its order are untouched:
-- trg_assertion_settle_gate still sorts first on assertions, so the messages
-- tests/conformance/30_configuration_gate.sql pins still win.
CREATE OR REPLACE FUNCTION assertion_settle_gate_guard() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_alias_from       text;
    v_attrs            jsonb;
    v_becomes_accepted boolean;
    v_changes_accepted boolean;
    v_gated_as         text;
    v_marked           boolean := false;
    v_roles text[];
    v_type  text;
BEGIN
    v_becomes_accepted := NEW.status = 'accepted'
        AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'accepted');
    v_changes_accepted := TG_OP = 'UPDATE' AND OLD.status = 'accepted';

    -- No alias may point FROM a gated configuration type. The key carries the
    -- aliased name; the claim carries what it would resolve to, and is not
    -- read here, because what matters is which name stops reaching the gate.
    -- The type is the stored spelling `registry_entry`, because that is the
    -- only spelling registry_value() reads an alias from.
    IF NEW.assertion_type = 'registry_entry'
       AND (TG_OP = 'INSERT' OR v_becomes_accepted)
    THEN
        v_alias_from := nullif(
            substring(NEW.assertion_key from '^type_alias:assertion_type:(.+)$'), ''
        );
        IF v_alias_from IS NOT NULL
           AND assertion_settle_roles(v_alias_from) IS NOT NULL
        THEN
            RAISE EXCEPTION
                'Cannot record a type alias from "%": it is Rye configuration, and an alias would route a write under that name past the settle gate',
                v_alias_from
                USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;

    IF NOT v_becomes_accepted AND NOT v_changes_accepted THEN
        RETURN NEW;
    END IF;

    -- On an UPDATE the stored spelling is OLD's: an accepted configuration row
    -- stays configuration even if the update tried to retype it, and the
    -- immutability guard refuses retyping anyway.
    v_type := CASE WHEN TG_OP = 'UPDATE' THEN OLD.assertion_type ELSE NEW.assertion_type END;

    v_roles := assertion_settle_roles(v_type);

    -- 0036: when the stored type is ungated, the row may still carry the
    -- marker record_assertion() wrote when it demoted the write under the name
    -- the caller actually used. That marker is the gate for this row. Read
    -- OLD's on an UPDATE, for the same reason the type is OLD's.
    IF v_roles IS NULL THEN
        v_attrs := CASE WHEN TG_OP = 'UPDATE' THEN OLD.attrs ELSE NEW.attrs END;
        IF jsonb_typeof(v_attrs->'settle_gate'->'allowed_roles') = 'array' THEN
            SELECT coalesce(array_agg(role.value #>> '{}'), '{}'::text[])
            INTO v_roles
            FROM jsonb_array_elements(v_attrs->'settle_gate'->'allowed_roles') AS role(value);
            v_marked := true;
            v_gated_as := coalesce(
                nullif(v_attrs->'settle_gate'->>'gated_as', ''), v_type
            );
        END IF;
    END IF;

    IF v_roles IS NULL THEN
        RETURN NEW;
    END IF;
    IF coalesce(nullif(current_setting('app.current_role', true), ''), '')
       = ANY(v_roles)
    THEN
        RETURN NEW;
    END IF;

    -- Where the MARKER is the gate, an admin always qualifies, whatever the
    -- array holds. attrs is caller-supplied on a raw INSERT, so an empty
    -- allowed_roles -- or one naming roles that exclude admin -- otherwise
    -- parks a suggestion in review_queue that nobody with the authority to
    -- clear it can accept or reject. An admin must never be locked out of the
    -- queue. This widens nothing: a gated STORED type is judged by
    -- assertion_type_access above and never reaches here, and an admin already
    -- settles those. Every other role still has to be named.
    IF v_marked
       AND coalesce(nullif(current_setting('app.current_role', true), ''), '') = 'admin'
    THEN
        RETURN NEW;
    END IF;

    IF v_marked THEN
        RAISE EXCEPTION
            'Assertion % is waiting on the settle gate for Rye configuration type %: only % may make it accepted. It is in review_queue for one of those roles.',
            coalesce(NEW.id, OLD.id),
            v_gated_as,
            array_to_string(v_roles, ', ')
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF v_changes_accepted THEN
        RAISE EXCEPTION
            'Assertion type % is Rye configuration: only % may change an accepted entry, including ending one. Record the replacement with record_assertion() and it becomes a candidate waiting for one of those roles.',
            v_type,
            array_to_string(v_roles, ', ')
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    RAISE EXCEPTION
        'Assertion type % is Rye configuration: only % may make it accepted. Record it with record_assertion() and it becomes a candidate waiting for one of those roles.',
        v_type,
        array_to_string(v_roles, ', ')
        USING ERRCODE = 'insufficient_privilege';
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION assertion_settle_gate_guard() IS
    'Refuse any write that makes an assertion of a settle-gated type accepted, any change to a row of a gated type that is already accepted, any registry_entry that aliases a settle-gated type away (assertion_key type_alias:assertion_type:<gated type>, at every status, for every caller), and -- where the stored type is ungated -- the same two refusals driven by attrs.settle_gate.allowed_roles on the row itself, so a demotion under a pre-gate alias cannot be settled by the role it excluded. Unless app.current_role is one of the allowed roles, or is admin where the marker is the gate -- a caller-supplied empty or admin-less array must not lock an admin out of the review queue. The marker is consulted only when the stored type is ungated, so a forged one can only add refusals; 0025 makes it unstrippable. Fires inside SECURITY DEFINER helpers and on raw writes alike. DELETE needs no branch: assertion_delete_policy refuses every delete.';

-- --------------------------------------------------------------------------
-- 4. record_assertion() judges the written name as well as the canonical one
-- --------------------------------------------------------------------------
--
-- Carried forward from 0030 verbatim. One declaration and one block change:
-- the settle roles are now looked up under the canonical spelling and, if that
-- is ungated and differs from what the caller wrote, under the written one;
-- the demotion's attrs.settle_gate gains gated_as. Where the two spellings are
-- the same -- every call that is not going through a standing pre-gate alias --
-- there is no extra lookup at all.
CREATE OR REPLACE FUNCTION record_assertion(
    p_assertion_type text,
    p_claim jsonb,
    p_subject_node_id uuid DEFAULT NULL,
    p_subject_edge_id uuid DEFAULT NULL,
    p_assertion_key text DEFAULT 'default',
    p_effective_at timestamptz DEFAULT NULL,
    p_effective_to timestamptz DEFAULT NULL,
    p_confidence numeric DEFAULT NULL,
    p_status text DEFAULT 'accepted',
    p_basis text DEFAULT 'unknown',
    p_evidence jsonb[] DEFAULT NULL,
    p_classification text DEFAULT NULL,
    p_attrs jsonb DEFAULT '{}'::jsonb,
    p_scope_node_id uuid DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_type text;
    v_attrs jsonb := coalesce(p_attrs, '{}'::jsonb);
    v_existing assertions;
    v_gated_as text;
    v_governing_scope uuid;
    v_settle_roles text[];
    v_key text := coalesce(nullif(trim(p_assertion_key), ''), 'default');
    v_new_effective_to timestamptz := p_effective_to;
    v_new_id uuid := gen_random_uuid();
    v_next_future_at timestamptz;
    v_policy text;
    v_resolved_scope uuid;
    v_status text := lower(coalesce(nullif(trim(p_status), ''), 'accepted'));
    v_basis text := lower(coalesce(nullif(trim(p_basis), ''), 'unknown'));
    v_subject_ref text;
    v_witness uuid;
    v_written_type text := nullif(trim(p_assertion_type), '');
BEGIN
    IF (p_subject_node_id IS NULL) = (p_subject_edge_id IS NULL) THEN
        RAISE EXCEPTION 'Exactly one of subject_node_id or subject_edge_id is required';
    END IF;
    IF nullif(trim(p_assertion_type), '') IS NULL THEN
        RAISE EXCEPTION 'assertion_type is required';
    END IF;
    v_assertion_type := canonical_type_in_scope('assertion_type', p_assertion_type, p_scope_node_id);
    IF p_claim IS NULL THEN
        RAISE EXCEPTION 'claim is required';
    END IF;
    IF v_status NOT IN ('candidate', 'accepted') THEN
        RAISE EXCEPTION 'Unsupported assertion status: %', p_status;
    END IF;
    IF v_basis NOT IN ('observed', 'reported', 'inferred', 'assumed', 'unknown') THEN
        RAISE EXCEPTION 'Unsupported assertion basis: %', p_basis;
    END IF;
    IF v_assertion_type = 'pattern_claim' AND v_status = 'accepted' THEN
        RAISE EXCEPTION 'pattern_claim assertions must be recorded as candidates and promoted with accept_assertion()';
    END IF;
    IF v_basis <> 'assumed'
       AND cardinality(coalesce(p_evidence, '{}'::jsonb[])) = 0
    THEN
        RAISE EXCEPTION 'Non-assumed assertions require evidence';
    END IF;
    IF p_effective_at IS NOT NULL
       AND p_effective_to IS NOT NULL
       AND p_effective_to <= p_effective_at
    THEN
        RAISE EXCEPTION 'effective_to must be after effective_at';
    END IF;

    SELECT nullif(evidence->>'witness_node_id', '')::uuid
    INTO v_witness
    FROM unnest(coalesce(p_evidence, '{}'::jsonb[])) WITH ORDINALITY item(evidence, ordinality)
    WHERE evidence->>'kind' IN ('source', 'corroboration')
      AND nullif(evidence->>'witness_node_id', '') IS NOT NULL
    ORDER BY ordinality
    LIMIT 1;

    v_governing_scope := governing_scope(
        p_subject_node_id,
        p_subject_edge_id,
        v_assertion_type,
        v_witness
    );
    v_resolved_scope := v_governing_scope;
    IF p_scope_node_id IS NOT NULL
       AND v_resolved_scope IS NOT NULL
       AND p_scope_node_id <> v_resolved_scope
    THEN
        RAISE EXCEPTION 'Explicit scope % does not match governing scope %', p_scope_node_id, v_resolved_scope;
    END IF;
    v_resolved_scope := coalesce(v_resolved_scope, p_scope_node_id);
    v_assertion_type := canonical_type_in_scope(
        'assertion_type', v_assertion_type, v_resolved_scope
    );
    IF v_assertion_type = 'pattern_claim' AND v_status = 'accepted' THEN
        RAISE EXCEPTION 'pattern_claim assertions must be recorded as candidates and promoted with accept_assertion()';
    END IF;
    -- 0027: the policy is the stricter of the two resolutions, because the
    -- insert guard resolves without a witness and its answer can fall through
    -- to a stricter DEFAULT_SCOPE. The scope id above is unchanged. When
    -- nothing governs the subject, an explicit p_scope_node_id still supplies
    -- the policy exactly as before.
    IF v_governing_scope IS NULL THEN
        v_policy := scope_review_policy(v_resolved_scope);
    ELSE
        v_policy := effective_review_policy(
            p_subject_node_id, p_subject_edge_id, v_assertion_type, v_witness
        );
    END IF;

    -- Configuration writes need an admin. A gated type is Rye's own
    -- configuration, and only the roles named in the assertion_type_access
    -- `settle` row may make it accepted. Demote rather than refuse, so
    -- nothing the person said is lost: the write lands as a candidate an
    -- admin can accept from review_queue, marked so the caller can see why.
    --
    -- This runs before the review policy demotion and before the block that
    -- supersedes the incumbent. Demoting after supersession would leave the
    -- key with no accepted value at all, which is how a non-admin would erase
    -- an alias by proposing one. It is independent of the review policy: it
    -- applies under open, candidates_only, strict, and with no policy at all,
    -- so the requested status, not the post-policy status, is what is tested.
    --
    -- 0036: the gate judges the written name as well as the canonical one. An
    -- alias recorded before its type was gated cannot route a write past it.
    v_settle_roles := assertion_settle_roles(v_assertion_type);
    v_gated_as := v_assertion_type;
    IF v_settle_roles IS NULL AND v_written_type IS DISTINCT FROM v_assertion_type THEN
        v_settle_roles := assertion_settle_roles(v_written_type);
        v_gated_as := v_written_type;
    END IF;
    IF v_status = 'accepted'
       AND v_settle_roles IS NOT NULL
       AND NOT (
           coalesce(nullif(current_setting('app.current_role', true), ''), '')
           = ANY(v_settle_roles)
       )
    THEN
        v_status := 'candidate';
        v_attrs := v_attrs || jsonb_build_object(
            'settle_gate', jsonb_build_object(
                'pending', true,
                'requested_status', 'accepted',
                'assertion_type', v_assertion_type,
                'gated_as', v_gated_as,
                'allowed_roles', to_jsonb(v_settle_roles)
            )
        );
    END IF;

    -- 0030: the review-policy demotion says so, in supersede_assertion()'s
    -- shape. It runs after the settle-gate demotion and tests the status that
    -- demotion left, so a configuration write that both would demote keeps
    -- attrs.settle_gate alone.
    IF v_status = 'accepted'
       AND (v_policy = 'strict' OR (v_policy = 'candidates_only' AND v_basis <> 'observed'))
    THEN
        v_status := 'candidate';
        v_attrs := v_attrs || jsonb_build_object(
            'review_gate', jsonb_build_object(
                'pending', true,
                'requested_status', 'accepted',
                'review_policy', v_policy,
                'scope_node_id', v_resolved_scope,
                'incumbent_assertion_id', NULL
            )
        );
        RAISE NOTICE
            'Review policy % on scope %: assertion % is waiting in review_queue. It was recorded as a candidate and is not the current value. A settler accepts it with accept_assertion().',
            v_policy, coalesce(v_resolved_scope::text, 'none'), v_new_id;
    END IF;

    v_subject_ref := coalesce('n:' || p_subject_node_id::text, 'e:' || p_subject_edge_id::text);

    IF v_status = 'accepted' THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(
            v_subject_ref || ':' || v_assertion_type || ':' || v_key, 0
        ));

        IF p_effective_at IS NOT NULL AND p_effective_at > now() THEN
            SELECT * INTO v_existing
            FROM assertions
            WHERE subject_ref = v_subject_ref
              AND assertion_type = v_assertion_type
              AND assertion_key = v_key
              AND status = 'accepted'
              AND superseded_at IS NULL
              AND effective_at IS NOT DISTINCT FROM p_effective_at
            LIMIT 1;

            IF FOUND
               AND v_existing.claim = p_claim
               AND v_existing.basis = v_basis
               AND v_existing.confidence IS NOT DISTINCT FROM p_confidence
            THEN
                PERFORM append_assertion_evidence(v_existing.id, p_evidence);
                RETURN v_existing.id;
            ELSIF FOUND THEN
                PERFORM mark_assertion_superseded(v_existing.id, v_new_id);
            END IF;

            SELECT min(effective_at) INTO v_next_future_at
            FROM assertions
            WHERE subject_ref = v_subject_ref
              AND assertion_type = v_assertion_type
              AND assertion_key = v_key
              AND status = 'accepted'
              AND superseded_at IS NULL
              AND effective_at > p_effective_at;

            IF v_next_future_at IS NOT NULL
               AND (v_new_effective_to IS NULL OR v_new_effective_to > v_next_future_at)
            THEN
                v_new_effective_to := v_next_future_at;
            END IF;

            SELECT * INTO v_existing
            FROM assertions
            WHERE subject_ref = v_subject_ref
              AND assertion_type = v_assertion_type
              AND assertion_key = v_key
              AND status = 'accepted'
              AND superseded_at IS NULL
              AND (effective_at IS NULL OR effective_at < p_effective_at)
              AND (effective_to IS NULL OR effective_to > p_effective_at)
            ORDER BY effective_at DESC NULLS LAST, asserted_at DESC
            LIMIT 1;

            IF FOUND AND (v_existing.effective_to IS NULL OR v_existing.effective_to > p_effective_at) THEN
                PERFORM set_config('app.write_path', 'assertion_effective_window', true);
                PERFORM set_config('app.effective_window_assertion_id', v_existing.id::text, true);
                UPDATE assertions SET effective_to = p_effective_at WHERE id = v_existing.id;
                PERFORM set_config('app.write_path', '', true);
                PERFORM set_config('app.effective_window_assertion_id', '', true);
            END IF;
        ELSIF p_effective_to IS NULL OR p_effective_to > now() THEN
            SELECT * INTO v_existing
            FROM assertions
            WHERE subject_ref = v_subject_ref
              AND assertion_type = v_assertion_type
              AND assertion_key = v_key
              AND status = 'accepted'
              AND superseded_at IS NULL
              AND (effective_at IS NULL OR effective_at <= now())
              AND (effective_to IS NULL OR effective_to > now())
            ORDER BY effective_at DESC NULLS LAST, asserted_at DESC
            LIMIT 1;

            IF FOUND
               AND v_existing.claim = p_claim
               AND v_existing.basis = v_basis
               AND v_existing.confidence IS NOT DISTINCT FROM p_confidence
            THEN
                PERFORM append_assertion_evidence(v_existing.id, p_evidence);
                RETURN v_existing.id;
            END IF;
            IF FOUND THEN
                PERFORM mark_assertion_superseded(v_existing.id, v_new_id);
            END IF;
        END IF;
    END IF;

    INSERT INTO assertions (
        id, assertion_type, assertion_key, status, basis, classification,
        subject_node_id, subject_edge_id, claim, effective_at, effective_to,
        confidence, attrs
    ) VALUES (
        v_new_id, v_assertion_type, v_key, v_status, v_basis, p_classification,
        p_subject_node_id, p_subject_edge_id, p_claim, p_effective_at,
        v_new_effective_to, p_confidence, v_attrs
    );

    PERFORM append_assertion_evidence(v_new_id, p_evidence);
    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION record_assertion(text,jsonb,uuid,uuid,text,timestamptz,timestamptz,numeric,text,text,jsonb[],text,jsonb,uuid) IS
    'Record an assertion. The settle gate judges the canonical spelling and the spelling the caller wrote, so an alias recorded before its type was gated cannot route a write past it; a demotion carries attrs.settle_gate {pending, requested_status, assertion_type, gated_as, allowed_roles}, where gated_as names the spelling that gated it. Where the review policy demotes the write instead, the row carries attrs.review_gate {pending, requested_status, review_policy, scope_node_id, incumbent_assertion_id} and a NOTICE names the policy and the scope. Where the settle gate demotes it first, the row carries attrs.settle_gate alone, as it always did.';

-- --------------------------------------------------------------------------
-- 5. A repeat describe_category() works for an agent
-- --------------------------------------------------------------------------
--
-- Carried forward from 0020. The upsert is wrapped in a block that opens the
-- named update_node_properties gate transaction-locally and clears it on the
-- normal and the exception path. A plpgsql EXCEPTION block opens a
-- subtransaction, so a rollback restores the setting by itself; the explicit
-- clear is belt and braces, and the one on the normal path is the one that
-- matters -- the gate must be shut again before record_event() and
-- record_assertion() run.
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

    -- 0036: the second description of a type is an UPDATE of the category node,
    -- and node_update_policy admits an agent:* caller's UPDATE only through the
    -- named gate. A client never sets app.write_path itself, so the function
    -- does it, around this statement and nothing else.
    BEGIN
        PERFORM set_config('app.write_path', 'update_node_properties', true);

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

        PERFORM set_config('app.write_path', '', true);
    EXCEPTION WHEN OTHERS THEN
        PERFORM set_config('app.write_path', '', true);
        RAISE;
    END;

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
    'Record what a node type means in this organization''s words. Creates the node that stands for the category on first use (node_type ''category'', external_source ''rye_category'', external_id the type name) and records a category_description assertion on it, keyed by the scope uuid as text or ''default'' for the org-wide fallback. The upsert runs behind the named update_node_properties write path, opened transaction-locally around that one statement and cleared on the normal and the exception path, so a repeat description works for an agent role; a client never sets the gate itself, and a viewer or an unset role is still refused. Goes through record_event and record_assertion, so the scope''s review policy applies: under a reviewing policy the words land as a candidate and rye_categories() keeps showing the previous description until someone accepts. Corrections are new assertions; nothing is updated in place.';
