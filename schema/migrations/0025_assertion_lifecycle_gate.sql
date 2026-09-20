-- The row is the gate, not the route.
--
-- Work item: work/008-assertion-lifecycle-gate.md
-- Contract:  contracts/sql-surface.md, "The row is the gate, not the route"
-- Decision:  docs/decisions/0008-the-row-is-the-gate-for-assertion-lifecycle.md
--
-- Before this migration, assertion_update_policy and the 0019 immutability
-- guard decided what an UPDATE could do by reading app.write_path and a
-- per-path row id setting. The lifecycle helpers set those. So can any caller,
-- with set_config(). A candidate could be promoted, an accepted row ended with
-- superseded_by still null, a window narrowed, attrs rewritten, and
-- classification changed, all by raw SQL under any role.
--
-- There is no unforgeable "a helper did this" signal available here. Session
-- variables forge. Table privileges do not bind the owner, which is how Rye
-- connects on Supabase and in the Docker test database. PG_CONTEXT is
-- undocumented text a caller-created function can imitate. current_query() is
-- text. So the rules below stop asking who wrote the row and ask whether the
-- row is one Rye's rules allow. app.write_path stays exactly where it is, as a
-- cheap pre-filter in assertion_update_policy that stops a stray UPDATE. It
-- grants nothing.
--
-- WHAT THIS PROTECTS AND WHAT IT DOES NOT.
-- Rye's authorization is session variables. A caller holding a raw connection
-- can set app.current_role to 'admin', and nothing here changes that. Two
-- things are protected: deployments where a trusted backend sets the session
-- variables and callers cannot, and well-behaved agents that state their role
-- honestly and must not be able to skip review by accident or by following bad
-- instructions. This is NOT a defence against a hostile caller with a raw
-- connection. Nothing in this file claims more.
--
-- Inside that boundary, three claims hold for any caller at all, forged role
-- included, because they read no role: an accepted assertion cannot be ended
-- without a replacement of the same type and key; a window cannot be narrowed
-- without a successor; and claim, basis, confidence and the subject of an
-- assertion cannot be rewritten.
--
-- There is no admin exemption. An exemption keyed on app.current_role = 'admin'
-- is produced by the same set_config() this migration exists to close. An
-- admin's raw `UPDATE assertions SET superseded_at = now()` succeeded before
-- and fails now; supersede_assertion() and reject_candidate() remain.

SET search_path = rye, pg_catalog, public;

-- --------------------------------------------------------------------------
-- 1. The vocabularies the rules read
-- --------------------------------------------------------------------------

-- The outcome values mark_assertion_outcome() accepts. Kept as a function so
-- the guard and the helper cannot drift apart silently.
CREATE OR REPLACE FUNCTION assertion_outcome_values()
RETURNS text[]
SET search_path = rye, pg_catalog
AS $$
    SELECT ARRAY[
        'correct', 'incorrect', 'unsupported', 'duplicate', 'stale',
        'displaced', 'corrected', 'unresolvable'
    ];
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION assertion_outcome_values() IS
    'The outcome labels mark_assertion_outcome() accepts. Read by assertions_immutable_guard() so a raw attrs write must still be a real outcome labelling.';

-- The attrs keys an outcome labelling writes. Every p_details key any in-repo
-- caller of mark_assertion_outcome() passes is here: reject_candidate writes
-- outcome_reason, accept_assertion writes corrected_by and displaced_by, and
-- score_due_predictions writes the three prediction keys. A key outside this
-- set may be added by a labelling but its value may never be rewritten.
CREATE OR REPLACE FUNCTION assertion_outcome_label_keys()
RETURNS text[]
SET search_path = rye, pg_catalog
AS $$
    SELECT ARRAY[
        'outcome', 'outcome_at', 'outcome_reason',
        'corrected_by', 'displaced_by',
        'prediction_scored_event_id', 'outcome_assertion_id', 'brier_score'
    ];
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION assertion_outcome_label_keys() IS
    'The attrs keys an outcome labelling may rewrite. Any other pre-existing key must keep its value, and no key may be dropped.';

-- The classification a row is allowed to carry: the value derived from its own
-- derivation evidence, which is what propagate_assertion_classification_from_evidence()
-- computes. A row with no derivation evidence has no derived classification and
-- so may not have its classification changed at all.
CREATE OR REPLACE FUNCTION assertion_derived_classification(p_assertion_id uuid)
RETURNS text
SET search_path = rye, pg_catalog
AS $$
    SELECT derived_assertion_classification(
        (SELECT array_agg(DISTINCT ae.source_assertion_id ORDER BY ae.source_assertion_id)
         FROM assertion_evidence ae
         WHERE ae.assertion_id = p_assertion_id
           AND ae.kind = 'derivation')
    );
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION assertion_derived_classification(uuid) IS
    'The classification derived from an assertion''s own derivation evidence, computed exactly as propagate_assertion_classification_from_evidence() computes it. NULL when the row has no derivation evidence.';

-- True when the row already has derivation evidence to derive from.
CREATE OR REPLACE FUNCTION assertion_has_derivation_evidence(p_assertion_id uuid)
RETURNS boolean
SET search_path = rye, pg_catalog
AS $$
    SELECT EXISTS (
        SELECT 1 FROM assertion_evidence ae
        WHERE ae.assertion_id = p_assertion_id AND ae.kind = 'derivation'
    );
$$ LANGUAGE sql STABLE;

-- --------------------------------------------------------------------------
-- 2. A direct INSERT lands as a candidate, it is not refused
-- --------------------------------------------------------------------------
--
-- Refusing would break merge_nodes(), which inserts the duplicate's assertions
-- onto the canonical node directly, and it would throw away what a caller said.
-- So the guard demotes exactly where record_assertion() demotes: under a strict
-- review policy, and under candidates_only when the basis is not observed.
--
-- record_assertion()'s insert is not told apart from a raw one, because it
-- cannot be. It does not need to be: record_assertion() has already applied the
-- same rule, so this is a no-op on its own writes.
--
-- One exemption, confined to one tuple. A row stays accepted when an assertion
-- ON THE SAME subject_ref, assertion_type AND assertion_key is already
-- superseded, was accepted, and names this row as its replacement.
-- supersede_assertion(), record_distillation() and record_assertion() all mark
-- that incumbent before inserting its replacement, and demoting the replacement
-- would leave that key with no accepted value at all, which is the erasure this
-- migration exists to prevent.
--
-- The tuple test is load-bearing, not tidiness. Without it a caller supersedes
-- a row in an open scope, names a fresh id, and inserts that id as accepted on
-- a subject in a strict scope; and merge_nodes() reaches the same result by
-- accident when the duplicate is in an open scope and the canonical in a strict
-- one. With it, a merge_nodes() copy is judged by the canonical node's review
-- policy, which is the answer obligation 11 asks for.
--
-- There is no "the incumbent pre-dates the transaction" test, because nothing
-- in the row records when it was written that a caller could not also write.
-- What the exemption leaves open is exactly what supersede_assertion() already
-- lets the same caller do on that same tuple, so it adds nothing.
--
-- Two consequences, both stated in the contract. A merge under a strict scope
-- moves the copied assertions into review instead of carrying them across
-- accepted; the content is preserved and an admin accepts it from review_queue.
-- And the scope is resolved without a witness, because evidence is written
-- after the assertion, so a scope reached only through scope_governs_source
-- does not demote a raw insert.
CREATE OR REPLACE FUNCTION assertions_insert_review_guard() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_policy      text;
    v_scope       uuid;
    -- subject_ref is a STORED generated column, and PostgreSQL computes it
    -- AFTER BEFORE triggers run, so NEW.subject_ref is null here. Compute it
    -- with the same expression the column uses.
    v_subject_ref text := coalesce(
        'n:' || NEW.subject_node_id::text, 'e:' || NEW.subject_edge_id::text
    );
BEGIN
    -- Exactly one subject, refused first and at any status. assertion_has_subject
    -- is OR, not XOR, so a row carrying both columns is insertable, and
    -- governing_scope() raises on it. Skipping the review rules for such a row
    -- let a caller write an accepted assertion onto a node in a strict scope:
    -- subject_ref resolves to the node, so it is the node's row in
    -- current_valid_assertions, but the gate never looked at it.
    --
    -- Refusing loses nothing. record_assertion() already raises "Exactly one of
    -- subject_node_id or subject_edge_id is required", so no helper writes this
    -- shape and nothing legitimate depends on it. Existing rows are untouched:
    -- this is INSERT only, and the UPDATE guard refuses only a status change.
    IF (NEW.subject_node_id IS NULL) = (NEW.subject_edge_id IS NULL) THEN
        RAISE EXCEPTION
            'Exactly one of subject_node_id or subject_edge_id is required on an assertion';
    END IF;

    IF NEW.status IS DISTINCT FROM 'accepted' THEN
        RETURN NEW;
    END IF;

    -- Every branch of governing_scope() returns a non-archived onboarding_scope
    -- node, so with none there is nothing to decide and the policy is open.
    -- This is the hot path on an ordinary instance, and it is not a weakening:
    -- record_assertion() resolves the same scope from the same rows and lands
    -- the same answer.
    IF NOT EXISTS (
        SELECT 1 FROM nodes
        WHERE node_type = 'onboarding_scope' AND archived_at IS NULL
    ) THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
        SELECT 1 FROM assertions incumbent
        WHERE incumbent.superseded_by = NEW.id
          AND incumbent.superseded_at IS NOT NULL
          AND incumbent.status = 'accepted'
          AND incumbent.subject_ref = v_subject_ref
          AND incumbent.assertion_type = NEW.assertion_type
          AND incumbent.assertion_key = NEW.assertion_key
    ) THEN
        RETURN NEW;
    END IF;

    v_scope := governing_scope(
        NEW.subject_node_id, NEW.subject_edge_id, NEW.assertion_type, NULL
    );
    v_policy := scope_review_policy(v_scope);

    IF v_policy = 'strict'
       OR (v_policy = 'candidates_only' AND NEW.basis IS DISTINCT FROM 'observed')
    THEN
        NEW.status := 'candidate';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION assertions_insert_review_guard() IS
    'Refuse an assertion that does not carry exactly one subject, at any status, because governing_scope() cannot read that shape and no helper writes it. Otherwise judge a direct INSERT of an accepted assertion by the same review policy record_assertion() applies, and demote it to candidate where that policy demotes. Nothing said is lost. Exempts a row that an already superseded, formerly accepted assertion on the same subject_ref, assertion_type and assertion_key names as its replacement, so supersede-then-insert does not strand that key with no accepted value. The exemption does not carry across tuples, so a merge_nodes() copy is judged by the canonical node''s policy.';

DROP TRIGGER IF EXISTS trg_assertions_insert_review ON assertions;
CREATE TRIGGER trg_assertions_insert_review
    BEFORE INSERT ON assertions
    FOR EACH ROW
    EXECUTE FUNCTION assertions_insert_review_guard();

-- --------------------------------------------------------------------------
-- 3. The per-column UPDATE rules
-- --------------------------------------------------------------------------
--
-- assertions_immutable_guard() is replaced in place, keeping its trigger
-- trg_assertions_immutable from 0002. Every rule is re-derived from OLD, NEW,
-- rows that already exist, and app.current_role. app.current_role is read only
-- to refuse, never to permit.
--
-- Trigger order on assertions: BEFORE row triggers fire alphabetically, and
-- trg_assertion_settle_gate (0023) sorts before trg_assertions_immutable and
-- trg_assertions_insert_review in both the C and en_US.UTF-8 collations. That
-- is load-bearing: tests/conformance/30_configuration_gate.sql matches the
-- settle gate's own message on writes this guard would otherwise refuse first
-- with a different message. trg_assertions_insert_review is INSERT-only and
-- trg_assertions_immutable is UPDATE-only, so they never sort against each
-- other.
CREATE OR REPLACE FUNCTION assertions_immutable_guard() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_derived text;
    v_instant timestamptz;
    v_policy  text;
    v_replacement assertions;
    v_role    text := lower(coalesce(current_setting('app.current_role', true), ''));
    v_scope   uuid;
    -- subject_ref is a STORED generated column, computed after BEFORE triggers
    -- run, so NEW.subject_ref is null here. OLD's is populated, but the subject
    -- columns are immutable below, so the two agree. Compute it anyway.
    v_subject_ref text := coalesce(
        'n:' || NEW.subject_node_id::text, 'e:' || NEW.subject_edge_id::text
    );
    v_witness uuid;
BEGIN
    -- ----------------------------------------------------------------------
    -- Never. No role, no setting, no helper changes any of these.
    -- ----------------------------------------------------------------------
    IF NEW.claim IS DISTINCT FROM OLD.claim
       OR NEW.assertion_type IS DISTINCT FROM OLD.assertion_type
       OR NEW.assertion_key IS DISTINCT FROM OLD.assertion_key
       OR NEW.subject_node_id IS DISTINCT FROM OLD.subject_node_id
       OR NEW.subject_edge_id IS DISTINCT FROM OLD.subject_edge_id
       OR NEW.asserted_at IS DISTINCT FROM OLD.asserted_at
       OR NEW.effective_at IS DISTINCT FROM OLD.effective_at
       OR NEW.basis IS DISTINCT FROM OLD.basis
       OR NEW.confidence IS DISTINCT FROM OLD.confidence
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION
            'Assertion content is immutable: claim, type, key, subject, asserted_at, effective_at, basis, confidence and created_at are written once. Record a correction with record_assertion() or supersede_assertion().';
    END IF;

    -- ----------------------------------------------------------------------
    -- status: candidate to accepted only, and only in a shape acceptance
    -- could have produced.
    -- ----------------------------------------------------------------------
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        -- A two-subject row is refused before any other status rule, for the
        -- same reason the insert guard refuses it: governing_scope() cannot
        -- read it, so the agent capability check would be skipped and an agent
        -- could promote under a strict policy. Only a status change is refused,
        -- so a row that pre-dates this migration can still be superseded and
        -- labelled.
        IF (NEW.subject_node_id IS NULL) = (NEW.subject_edge_id IS NULL) THEN
            RAISE EXCEPTION
                'Assertion % carries both a node and an edge subject and cannot be accepted. Record it with record_assertion(), which requires exactly one.',
                NEW.id;
        END IF;
        IF OLD.status <> 'candidate' OR NEW.status <> 'accepted' THEN
            RAISE EXCEPTION
                'Assertion status may only move candidate to accepted. An accepted assertion is replaced, never demoted.';
        END IF;
        IF OLD.superseded_at IS NOT NULL OR NEW.superseded_at IS NOT NULL THEN
            RAISE EXCEPTION
                'Assertion % is not a live candidate and cannot be promoted', NEW.id;
        END IF;

        -- The rival test is taken at one instant: the one this row takes
        -- effect at, never earlier than now. It is never skipped.
        --
        -- accept_assertion() takes its incumbent from current_valid_assertions,
        -- which is accepted, unsuperseded and covering now, and supersedes it
        -- before the promotion whatever the candidate's own effective_at, so it
        -- still passes here: an incumbent with an open effective_to covers the
        -- future instant too and is already gone by the time this runs. What is
        -- refused is a promotion into an instant a SCHEDULED accepted row holds,
        -- which accept_assertion() does not supersede and which would leave two
        -- accepted rows covering one instant on one tuple.
        v_instant := greatest(coalesce(NEW.effective_at, now()), now());
        IF EXISTS (
            SELECT 1 FROM assertions rival
            WHERE rival.id <> NEW.id
              AND rival.subject_ref = v_subject_ref
              AND rival.assertion_type = NEW.assertion_type
              AND rival.assertion_key = NEW.assertion_key
              AND rival.status = 'accepted'
              AND rival.superseded_at IS NULL
              AND (rival.effective_at IS NULL OR rival.effective_at <= v_instant)
              AND (rival.effective_to IS NULL OR rival.effective_to > v_instant)
        ) THEN
            RAISE EXCEPTION
                'Assertion % cannot be promoted while an accepted assertion already covers % on %/%. Use accept_assertion(), which supersedes the incumbent.',
                NEW.id, v_instant, NEW.assertion_type, NEW.assertion_key;
        END IF;

        -- accept_assertion() refuses an inferred candidate that would displace
        -- a non-inferred accepted holder. A raw promoter who superseded the
        -- holder itself must be refused for the same reason.
        IF NEW.basis = 'inferred'
           AND EXISTS (
               SELECT 1 FROM assertions displaced
               WHERE displaced.superseded_by = NEW.id
                 AND displaced.status = 'accepted'
                 AND displaced.basis <> 'inferred'
                 AND displaced.assertion_type = NEW.assertion_type
                 AND displaced.assertion_key = NEW.assertion_key
           )
        THEN
            RAISE EXCEPTION
                'Inferred assertion % cannot displace a non-inferred accepted assertion on %/%',
                NEW.id, NEW.assertion_type, NEW.assertion_key;
        END IF;

        -- Acceptance follows authority. This re-derives the rule
        -- accept_assertion() applies, from the same witness query, and it reads
        -- the role only in order to refuse. Only agent:* callers are
        -- policy-gated on promotion, because that is the rule the helper
        -- applies; this guard does not invent a wider role model.
        IF v_role LIKE 'agent:%' THEN
            SELECT ae.witness_node_id INTO v_witness
            FROM assertion_evidence ae
            WHERE ae.assertion_id = NEW.id
              AND ae.kind IN ('source', 'corroboration')
              AND ae.witness_node_id IS NOT NULL
            ORDER BY CASE ae.kind WHEN 'source' THEN 0 ELSE 1 END, ae.recorded_at, ae.id
            LIMIT 1;

            v_scope := governing_scope(
                NEW.subject_node_id, NEW.subject_edge_id, NEW.assertion_type, v_witness
            );
            v_policy := scope_review_policy(v_scope);

            IF (v_policy IN ('candidates_only', 'strict')
                OR NEW.assertion_type = 'pattern_claim')
               AND NOT agent_can_promote_in_scope(v_scope)
            THEN
                RAISE EXCEPTION
                    'Agent acceptance requires rye.authoritative.promote capability for scope %', v_scope;
            END IF;
        END IF;
    END IF;

    -- ----------------------------------------------------------------------
    -- superseded_at and superseded_by: set once, together on an accepted row.
    -- An accepted assertion never ends with nothing replacing it. A candidate
    -- may still be closed with superseded_by null, which is how
    -- reject_candidate() records a rejection.
    -- ----------------------------------------------------------------------
    IF OLD.superseded_at IS NOT NULL
       AND NEW.superseded_at IS DISTINCT FROM OLD.superseded_at
    THEN
        RAISE EXCEPTION
            'Assertion % is already superseded; superseded_at is written once and never cleared', NEW.id;
    END IF;
    IF OLD.superseded_by IS NOT NULL
       AND NEW.superseded_by IS DISTINCT FROM OLD.superseded_by
    THEN
        RAISE EXCEPTION
            'Assertion % already names its replacement; superseded_by is written once', NEW.id;
    END IF;
    IF NEW.superseded_by IS NOT NULL AND NEW.superseded_at IS NULL THEN
        RAISE EXCEPTION
            'Assertion % names a replacement without ending; superseded_by requires superseded_at', NEW.id;
    END IF;
    IF NEW.superseded_by IS NOT NULL AND NEW.superseded_by = NEW.id THEN
        RAISE EXCEPTION 'Assertion % cannot supersede itself', NEW.id;
    END IF;

    IF OLD.superseded_at IS NULL AND NEW.superseded_at IS NOT NULL THEN
        IF (OLD.status = 'accepted' OR NEW.status = 'accepted')
           AND NEW.superseded_by IS NULL
        THEN
            RAISE EXCEPTION
                'An accepted assertion cannot be ended with nothing replacing it. Use supersede_assertion(), which writes the replacement, or reject_candidate() on a candidate.';
        END IF;

        -- The decoy case: a replacement that already exists but is not one.
        -- The forward-reference case, where the helper points at a row it has
        -- not inserted yet, is checked at commit by
        -- trg_assertions_transition_complete.
        IF NEW.superseded_by IS NOT NULL THEN
            SELECT * INTO v_replacement FROM assertions WHERE id = NEW.superseded_by;
            IF FOUND
               AND (v_replacement.assertion_type IS DISTINCT FROM OLD.assertion_type
                    OR v_replacement.assertion_key IS DISTINCT FROM OLD.assertion_key)
            THEN
                RAISE EXCEPTION
                    'Replacement % is %/%, not %/%; a replacement carries the same assertion_type and assertion_key',
                    NEW.superseded_by, v_replacement.assertion_type, v_replacement.assertion_key,
                    OLD.assertion_type, OLD.assertion_key;
            END IF;
        END IF;
    END IF;

    -- ----------------------------------------------------------------------
    -- effective_to: narrowing only, to a future instant inside the old window.
    -- The successor that must start where the window now ends is checked at
    -- commit, because record_assertion() inserts it after the narrowing.
    -- ----------------------------------------------------------------------
    IF NEW.effective_to IS DISTINCT FROM OLD.effective_to THEN
        IF NEW.effective_to IS NULL THEN
            RAISE EXCEPTION 'Assertion effective_to may be narrowed, never opened';
        END IF;
        IF OLD.effective_to IS NOT NULL AND NEW.effective_to >= OLD.effective_to THEN
            RAISE EXCEPTION 'Assertion effective_to may be narrowed, never extended';
        END IF;
        IF OLD.effective_at IS NOT NULL AND NEW.effective_to <= OLD.effective_at THEN
            RAISE EXCEPTION 'Assertion effective_to must stay after effective_at';
        END IF;
        IF NEW.effective_to <= now() THEN
            RAISE EXCEPTION
                'Assertion effective_to may only be narrowed to a future instant; history is not rewritten';
        END IF;
    END IF;

    -- ----------------------------------------------------------------------
    -- attrs: only as an outcome label. Shape-constrained, not role-constrained:
    -- a caller may still label an outcome by hand, and the contract says so.
    -- ----------------------------------------------------------------------
    IF NEW.attrs IS DISTINCT FROM OLD.attrs THEN
        IF jsonb_typeof(OLD.attrs) <> 'object' OR jsonb_typeof(NEW.attrs) <> 'object' THEN
            RAISE EXCEPTION 'Assertion attrs must be a JSON object';
        END IF;
        IF EXISTS (
            SELECT 1 FROM jsonb_object_keys(OLD.attrs) AS k(key)
            WHERE NOT NEW.attrs ? k.key
        ) THEN
            RAISE EXCEPTION 'Assertion attrs keys are never dropped';
        END IF;
        IF EXISTS (
            SELECT 1 FROM jsonb_each(OLD.attrs) AS o(key, value)
            WHERE NEW.attrs -> o.key IS DISTINCT FROM o.value
              AND NOT (o.key = ANY(assertion_outcome_label_keys()))
        ) THEN
            RAISE EXCEPTION
                'Assertion attrs may only change as an outcome label; an existing key keeps its value';
        END IF;
        -- Null-safe on purpose. `NOT (NULL = ANY(...))` is NULL, not true, so
        -- an attrs rewrite with no `outcome` key at all would fall through.
        IF coalesce(NEW.attrs->>'outcome', '') <> ALL(assertion_outcome_values()) THEN
            RAISE EXCEPTION
                'Assertion attrs may only change as an outcome label; the result must name an outcome in %',
                array_to_string(assertion_outcome_values(), ', ');
        END IF;
    END IF;

    -- ----------------------------------------------------------------------
    -- classification: only the value derived from the row's own derivation
    -- evidence, which is what propagate_assertion_classification_from_evidence()
    -- writes. Nothing else, for anyone.
    -- ----------------------------------------------------------------------
    IF NEW.classification IS DISTINCT FROM OLD.classification THEN
        IF NOT assertion_has_derivation_evidence(NEW.id) THEN
            RAISE EXCEPTION
                'Assertion % has no derivation evidence, so it has no derived classification to move to',
                NEW.id;
        END IF;
        v_derived := assertion_derived_classification(NEW.id);
        IF NEW.classification IS DISTINCT FROM v_derived THEN
            RAISE EXCEPTION
                'Assertion classification may only become the value derived from its evidence (%), not %',
                coalesce(v_derived, 'null'), coalesce(NEW.classification, 'null');
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION assertions_immutable_guard() IS
    'Per-column UPDATE rules for assertions, re-derived from OLD, NEW, rows that already exist, and app.current_role. Reads the role only to refuse, never to permit, and has no admin exemption. app.write_path is not consulted: a caller can set it. Three consequences that become true after the statement are checked at commit by trg_assertions_transition_complete.';

-- --------------------------------------------------------------------------
-- 4. The consequences, checked at commit
-- --------------------------------------------------------------------------
--
-- Three facts a helper makes true after the statement that needs them:
-- the acceptance event, the replacement's identity, and the successor of a
-- narrowed window. Deferral is not a preference. supersede_assertion() must
-- mark the incumbent before inserting the replacement or idx_assertions_active_unique
-- rejects the pair, which is why superseded_by's foreign key is already
-- DEFERRABLE INITIALLY DEFERRED. trg_assertion_evidence_required (0009) is the
-- precedent for the shape.
--
-- These checks run at commit as the caller, under RLS, outside any SECURITY
-- DEFINER frame, and all three FAIL CLOSED. A row the caller cannot read back
-- is not a fact the caller may rely on: it raises, exactly as a wrong one does.
--
-- This was the other way round once, and it was erasure. As a viewer: forge the
-- supersede settings, end an accepted row naming a fresh id, then insert that
-- id as a candidate of another type and key classified above your own read
-- level. The check could not see the replacement, so it passed, and the tuple
-- was left with no accepted value. "Not visible" has to mean no.
--
-- The cost is small and knowable. supersede_assertion(), record_distillation(),
-- merge_nodes() and record_assertion() all give the replacement a
-- classification the caller can already read -- copied from the incumbent, or
-- derived from evidence the caller had to see to cite. The one call this
-- refuses is a caller passing record_assertion() a p_classification above its
-- own read level over an accepted incumbent: the write is now refused at COMMIT
-- instead of blinding the writer to its own row.
--
-- Not every read in this migration fails closed. The conflict searches do not:
-- an invisible accepted rival does not block a promotion, and an invisible
-- witness does not change the policy answer. Inverting that would refuse every
-- promotion to a caller who cannot see the whole tuple. The cost is disclosed
-- in the contract as a stated limit: a caller who cannot read an accepted rival
-- can promote a visible candidate on the same tuple and leave two accepted rows
-- covering one instant, and the inferred-displacement search shares the cause.
-- accept_assertion() does not read rivals the same way -- it is SECURITY
-- DEFINER, so where the table owner is a superuser (the Docker install) it
-- reads past RLS and ends the hidden incumbent, while on Supabase, where the
-- owner is bound by RLS, helper and raw path agree. A SECURITY DEFINER reader
-- here was rejected: it would reveal that a hidden row exists, it is a no-op
-- where the owner is bound by RLS, and it is the route deployment.md refuses.
-- idx_assertions_active_unique is not RLS-filtered and still refuses the
-- identical-window pair.
CREATE OR REPLACE FUNCTION assertions_transition_complete() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_replacement assertions;
BEGIN
    IF TG_OP = 'UPDATE'
       AND OLD.status = 'candidate' AND NEW.status = 'accepted'
       AND NOT EXISTS (
           SELECT 1 FROM events e
           WHERE e.event_type = 'assertion_accepted'
             AND e.properties->>'assertion_id' = NEW.id::text
       )
    THEN
        RAISE EXCEPTION
            'Assertion % became accepted with no assertion_accepted event naming it. Acceptance is recorded, not assumed: use accept_assertion().',
            NEW.id;
    END IF;

    IF NEW.superseded_by IS NOT NULL
       AND (TG_OP = 'INSERT' OR OLD.superseded_by IS NULL)
    THEN
        SELECT * INTO v_replacement FROM assertions WHERE id = NEW.superseded_by;
        -- Not visible is refused, but only for a row that was accepted: a
        -- candidate closed with a replacement is not holding a value anyone
        -- can lose, and reject_candidate() passes no replacement at all.
        IF FOUND THEN
            IF v_replacement.assertion_type IS DISTINCT FROM NEW.assertion_type
               OR v_replacement.assertion_key IS DISTINCT FROM NEW.assertion_key
            THEN
                RAISE EXCEPTION
                    'Replacement % is %/%, not %/%; a replacement carries the same assertion_type and assertion_key',
                    NEW.superseded_by, v_replacement.assertion_type, v_replacement.assertion_key,
                    NEW.assertion_type, NEW.assertion_key;
            END IF;
        ELSIF (TG_OP = 'UPDATE' AND OLD.status = 'accepted')
              OR (TG_OP = 'INSERT' AND NEW.status = 'accepted')
        THEN
            RAISE EXCEPTION
                'Assertion % was ended naming replacement %, which is not readable by this caller. An assertion is not replaced by something the writer cannot see.',
                NEW.id, NEW.superseded_by;
        END IF;
    END IF;

    -- Already closed: NOT EXISTS is false for an invisible successor too, so a
    -- narrowing whose successor the caller cannot read back raises here.
    IF TG_OP = 'UPDATE'
       AND NEW.effective_to IS DISTINCT FROM OLD.effective_to
       AND NOT EXISTS (
           SELECT 1 FROM assertions successor
           WHERE successor.id <> NEW.id
             AND successor.subject_ref = NEW.subject_ref
             AND successor.assertion_type = NEW.assertion_type
             AND successor.assertion_key = NEW.assertion_key
             AND successor.status = 'accepted'
             AND successor.superseded_at IS NULL
             AND successor.effective_at = NEW.effective_to
       )
    THEN
        RAISE EXCEPTION
            'Assertion % had its window narrowed to % with no accepted assertion on %/% starting then. A window closes because something follows it.',
            NEW.id, NEW.effective_to, NEW.assertion_type, NEW.assertion_key;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION assertions_transition_complete() IS
    'At commit: a promotion has an assertion_accepted event naming the row, a superseded_by names a row of the same assertion_type and assertion_key, and a narrowed effective_to has a successor accepted assertion starting where the window now ends. All three fail closed under the caller''s RLS: a row the writer cannot read back is refused, because otherwise an accepted assertion could be ended by naming an invisible replacement. Deferred because the helpers write those facts after the statement that needs them.';

DROP TRIGGER IF EXISTS trg_assertions_transition_complete ON assertions;
CREATE CONSTRAINT TRIGGER trg_assertions_transition_complete
    AFTER INSERT OR UPDATE ON assertions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION assertions_transition_complete();
