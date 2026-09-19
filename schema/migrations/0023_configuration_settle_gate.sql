-- Configuration writes need an admin.
--
-- Work item: work/005-registry-write-gate.md
-- Contract:  contracts/sql-surface.md, "Configuration writes need an admin"
-- Decision:  docs/decisions/0007-configuration-writes-need-an-admin.md
--
-- Some assertion types are not knowledge about the world. They are Rye's own
-- configuration, and Rye reads them to decide how it treats every other write.
-- `registry_entry` carries the type aliases and the self-settled type list
-- that canonical_type(), registry_value(), and rye_settlers() read.
-- `review_policy` decides whether a write lands accepted at all. Before this
-- migration nothing checked who wrote either one, so a caller under
-- app.current_role = 'agent:x', viewer, or team_member could record an
-- accepted alias and change who may settle a claim for every role, admin
-- included. Ordinary conversation content must not be able to change policy.
--
-- The gate is data, not code: assertion_type_access gains a third `operation`
-- value, `settle`. A type with no `settle` row is ungated. Gating a further
-- type later is an INSERT, not a migration.
--
-- record_assertion() demotes; every other route raises.

SET search_path = rye, pg_catalog, public;

-- --------------------------------------------------------------------------
-- 1. The gate is a row
-- --------------------------------------------------------------------------

ALTER TABLE assertion_type_access
    DROP CONSTRAINT IF EXISTS assertion_type_access_operation_check;
ALTER TABLE assertion_type_access
    ADD CONSTRAINT assertion_type_access_operation_check
    CHECK (operation IN ('read', 'write', 'settle'));

COMMENT ON TABLE assertion_type_access IS
    'Data-driven assertion type gating. operation `read` and `write` gate visibility and insertion; `settle` gates who may make an assertion of that type accepted. A type with no row for an operation is unrestricted for it. Readable by every role, writable only by admin.';

-- The seed writes configuration, so it sets the admin role first. The session
-- setting is local to this statement's transaction; a later migration or
-- script that seeds configuration must do the same.
DO $seed$
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    INSERT INTO assertion_type_access (assertion_type, operation, allowed_roles)
    VALUES
        ('registry_entry', 'settle', ARRAY['admin']),
        ('review_policy',  'settle', ARRAY['admin'])
    ON CONFLICT (assertion_type, operation) DO NOTHING;
END;
$seed$;

-- --------------------------------------------------------------------------
-- 2. Reading the gate
-- --------------------------------------------------------------------------

-- The allowed roles for a type, or NULL when the type is ungated. NULL and an
-- empty array are different answers: an empty array gates the type and allows
-- nobody.
--
-- The stored spelling is matched with no alias resolution, because every
-- reader of configuration does the same: registry_value() and
-- governing_scope() match the stored literal, so a row written under another
-- spelling is not read as configuration in the first place. record_assertion()
-- canonicalizes before it inserts, so an alias of a gated type is gated.
CREATE OR REPLACE FUNCTION assertion_settle_roles(p_assertion_type text)
RETURNS text[]
SET search_path = rye, pg_catalog
AS $$
    SELECT ata.allowed_roles
    FROM assertion_type_access ata
    WHERE ata.assertion_type = p_assertion_type
      AND ata.operation = 'settle'
    LIMIT 1;
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION assertion_settle_roles(text) IS
    'The roles allowed to make an assertion type accepted, or NULL when the type is ungated. Matches the stored spelling with no alias resolution.';

-- Whether the caller's app.current_role may make this type accepted.
-- Authorization is session variables only: no current_user, no pg_has_role().
-- An unset role is not an admin and is not allowed.
CREATE OR REPLACE FUNCTION may_settle_assertion_type(p_assertion_type text)
RETURNS boolean
SET search_path = rye, pg_catalog
AS $$
    SELECT CASE
        WHEN assertion_settle_roles(p_assertion_type) IS NULL THEN true
        ELSE coalesce(nullif(current_setting('app.current_role', true), ''), '')
             = ANY(assertion_settle_roles(p_assertion_type))
    END;
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION may_settle_assertion_type(text) IS
    'True when the caller''s app.current_role may make an assertion of this type accepted. Session variables only. An unset role is never allowed.';

-- Ask before writing. A client calls this so it can tell the person what will
-- happen: the schema returns facts, the sentence a person hears is the
-- client's. Writes nothing.
CREATE OR REPLACE FUNCTION settle_gate(p_assertion_type text)
RETURNS jsonb
SET search_path = rye, pg_catalog
AS $$
    SELECT jsonb_build_object(
        'assertion_type', p_assertion_type,
        'gated', assertion_settle_roles(p_assertion_type) IS NOT NULL,
        'allowed_roles', CASE
            WHEN assertion_settle_roles(p_assertion_type) IS NULL THEN NULL::jsonb
            ELSE to_jsonb(assertion_settle_roles(p_assertion_type))
        END,
        'current_role', nullif(current_setting('app.current_role', true), ''),
        'may_settle', may_settle_assertion_type(p_assertion_type)
    );
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION settle_gate(text) IS
    'Answer {assertion_type, gated, allowed_roles, current_role, may_settle} for an assertion type. STABLE, SECURITY INVOKER, writes nothing. Call it before offering to record configuration. Matches the stored spelling with no alias resolution.';

-- --------------------------------------------------------------------------
-- 3. record_assertion() demotes
-- --------------------------------------------------------------------------

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

    v_resolved_scope := governing_scope(
        p_subject_node_id,
        p_subject_edge_id,
        v_assertion_type,
        v_witness
    );
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
    v_policy := scope_review_policy(v_resolved_scope);

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
    v_settle_roles := assertion_settle_roles(v_assertion_type);
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
                'allowed_roles', to_jsonb(v_settle_roles)
            )
        );
    END IF;

    IF v_status = 'accepted'
       AND (v_policy = 'strict' OR (v_policy = 'candidates_only' AND v_basis <> 'observed'))
    THEN
        v_status := 'candidate';
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

-- --------------------------------------------------------------------------
-- 4. Every other path refuses
-- --------------------------------------------------------------------------
--
-- Because record_assertion() has already demoted, an accepted row of a gated
-- type can only reach the table by some other route, and every other route
-- raises: a direct INSERT, any UPDATE that moves a row to accepted (which
-- covers accept_assertion() and a caller who sets app.write_path and
-- app.accept_assertion_id by hand, since the update policy trusts those
-- settings), supersede_assertion(), and record_distillation().
--
-- Refusing rather than demoting on those last two is deliberate: both mark or
-- displace the incumbent first, so a silent demotion would leave the key with
-- no accepted value. A refusal loses nothing, because the same statement
-- recorded through record_assertion() becomes a suggestion.
--
-- The check lives in one trigger rather than in each helper. A trigger fires
-- inside a SECURITY DEFINER helper and on a raw write alike, and it reads
-- app.current_role, which SECURITY DEFINER does not change. An agent
-- capability grant (rye.authoritative.promote) does not open it.
--
-- An UPDATE of a row that is already accepted is left alone: supersession,
-- effective-window narrowing, outcome labels, and classification propagation
-- all update accepted rows and none of them makes a new row accepted.
CREATE OR REPLACE FUNCTION assertion_settle_gate_guard() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_roles text[];
BEGIN
    IF NEW.status IS DISTINCT FROM 'accepted' THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.status = 'accepted' THEN
        RETURN NEW;
    END IF;

    v_roles := assertion_settle_roles(NEW.assertion_type);
    IF v_roles IS NULL THEN
        RETURN NEW;
    END IF;
    IF coalesce(nullif(current_setting('app.current_role', true), ''), '')
       = ANY(v_roles)
    THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION
        'Assertion type % is Rye configuration: only % may make it accepted. Record it with record_assertion() and it becomes a candidate waiting for one of those roles.',
        NEW.assertion_type,
        array_to_string(v_roles, ', ')
        USING ERRCODE = 'insufficient_privilege';
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION assertion_settle_gate_guard() IS
    'Refuse any write that makes an assertion of a settle-gated type accepted, unless app.current_role is one of the allowed roles. Fires inside SECURITY DEFINER helpers and on raw writes alike.';

DROP TRIGGER IF EXISTS trg_assertion_settle_gate ON assertions;
CREATE TRIGGER trg_assertion_settle_gate
    BEFORE INSERT OR UPDATE ON assertions
    FOR EACH ROW
    EXECUTE FUNCTION assertion_settle_gate_guard();
