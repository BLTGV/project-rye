-- Review policy holds on every route.
--
-- Work item: work/010-review-policy-holds.md
-- Contract:  contracts/sql-surface.md, "Review policy holds on every route"
-- Decision:  docs/decisions/0010-review-policy-holds-on-every-route.md
--
-- A scope's review policy says whether a write lands accepted. Two routes went
-- around it.
--
-- supersede_assertion() never consulted it. It inserted the replacement with
-- status accepted, unconditionally, so any caller landed an accepted row under
-- a strict scope by superseding one -- while record_assertion() for the same
-- caller and the same claim landed a candidate.
--
-- And governing_scope() broke ties with ORDER BY scope.id. merge_nodes()
-- re-points the duplicate's scope_governs_subject edge onto the canonical node,
-- so after a cross-scope merge two scopes govern it and the lowest uuid won. A
-- node in a strict area could silently become open.
--
-- What this migration does, in four parts:
--   1. scope_review_policy_rank(), a read-only ranking that never raises.
--   2. governing_scope() orders candidate scopes by that rank, most restrictive
--      first, with scope.id only as a tie-break.
--   3. supersede_assertion() applies the same predicate record_assertion()
--      applies. Where that predicate demotes, the replacement lands as a
--      candidate, the incumbent stays accepted and unsuperseded, and the row
--      carries attrs.review_gate. resolve_knowledge_gap() follows it.
--   4. assertions_insert_review_guard() loses 0025's insert exemption, because
--      the helper it existed for no longer ends an incumbent it is about to
--      replace with a candidate.
--
-- Signatures are unchanged, no table is added, and every function declares its
-- own search_path. Authorization is session variables only: nothing here reads
-- current_user, session_user, or pg_has_role().

SET search_path = rye, pg_catalog, public;

-- --------------------------------------------------------------------------
-- 1. Ranking a review policy without raising
-- --------------------------------------------------------------------------
--
-- scope_review_policy() raises on a stored value it does not recognise. That is
-- right when the scope is the one selected, and wrong in an ORDER BY: one
-- broken scope would refuse every write near any scope in the same branch. So
-- ordering uses this instead. It reads the same row the same way and answers
-- 0 for strict, 1 for candidates_only, 2 for everything else -- including a
-- null scope, a scope with no review_policy assertion, and a scope carrying a
-- value nobody supports, which therefore sorts as open. If such a scope is the
-- one selected, scope_review_policy() still raises on it, so today's failure
-- surface stays exactly where it was.
CREATE OR REPLACE FUNCTION scope_review_policy_rank(p_scope_id uuid)
RETURNS int
SET search_path = rye, pg_catalog
AS $$
    SELECT coalesce(
        (
            SELECT CASE lower(coalesce(
                        nullif(a.claim->>'review_policy', ''),
                        nullif(a.claim->>'value', ''),
                        CASE WHEN jsonb_typeof(a.claim) = 'string' THEN a.claim #>> '{}' END,
                        'open'
                    ))
                    WHEN 'strict' THEN 0
                    WHEN 'candidates_only' THEN 1
                    ELSE 2
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
    'How restrictive a scope''s review policy is, for ordering only: 0 strict, 1 candidates_only, 2 everything else. Never raises, so one scope carrying an unsupported review_policy value cannot refuse writes on a neighbouring subject; scope_review_policy() still raises on that scope if it is the one selected.';

-- --------------------------------------------------------------------------
-- 2. The most restrictive governing scope wins
-- --------------------------------------------------------------------------
--
-- Replaces the 0018 definition. The only change is the ORDER BY in the three
-- branches that could return more than one scope: restrictiveness first,
-- scope.id only as a tie-break, so the answer is still deterministic and no
-- longer depends on which uuid happened to sort first.
--
-- What does NOT change:
--   * The branch order still decides first -- direct subject coverage, then
--     inheritance through has_step, then type coverage, then the witness, then
--     DEFAULT_SCOPE. Restrictiveness orders the candidates WITHIN the branch
--     that matched.
--   * For an edge subject the source endpoint still beats the target endpoint
--     before restrictiveness is consulted, because that rule chooses which
--     subject is being governed, not which scope governs it.
--   * Type coverage still raises on two active scopes claiming one type. That
--     is an administrative error someone has to fix, and silently picking the
--     stricter one would hide it.
--   * The signature, and that exactly one scope id comes back. Callers use the
--     id for more than the policy: agent_can_promote_in_scope() takes it, the
--     explicit p_scope_node_id mismatch test compares against it,
--     canonical_type_in_scope() resolves in it, registry_value() reads from it.
--
-- After a cross-scope merge_nodes() both scopes govern the surviving node and
-- the stricter one now wins in either id order, which is what lets a test drop
-- its pinned uuids.
CREATE OR REPLACE FUNCTION governing_scope(
    p_subject_node_id uuid,
    p_subject_edge_id uuid,
    p_assertion_type text,
    p_witness_node_id uuid
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_type text := canonical_type('assertion_type', p_assertion_type);
    v_count int;
    v_default jsonb;
    v_scope uuid;
BEGIN
    IF (p_subject_node_id IS NULL) = (p_subject_edge_id IS NULL) THEN
        RAISE EXCEPTION 'Exactly one governing-scope subject is required';
    END IF;

    -- Direct subject coverage. Edge subjects use source endpoint before target,
    -- and within one endpoint the most restrictive policy wins.
    WITH subject_nodes AS (
        SELECT p_subject_node_id AS node_id, 0 AS endpoint_priority
        WHERE p_subject_node_id IS NOT NULL
        UNION ALL
        SELECT e.source_id, 0 FROM edges e WHERE e.id = p_subject_edge_id
        UNION ALL
        SELECT e.target_id, 1 FROM edges e WHERE e.id = p_subject_edge_id
    )
    SELECT coverage.source_id
    INTO v_scope
    FROM subject_nodes subject
    JOIN edges coverage
      ON coverage.target_id = subject.node_id
     AND coverage.edge_type = 'scope_governs_subject'
     AND coverage.archived_at IS NULL
     AND (coverage.effective_from IS NULL OR coverage.effective_from <= now())
     AND (coverage.effective_to IS NULL OR coverage.effective_to > now())
    JOIN nodes scope ON scope.id = coverage.source_id
    WHERE scope.node_type = 'onboarding_scope'
      AND scope.archived_at IS NULL
      AND EXISTS (
          SELECT 1 FROM current_valid_assertions status
          WHERE status.subject_node_id = scope.id
            AND status.assertion_type = 'scope_status'
            AND status.claim->>'status' = 'active'
      )
    ORDER BY subject.endpoint_priority, scope_review_policy_rank(scope.id), scope.id
    LIMIT 1;
    IF v_scope IS NOT NULL THEN
        RETURN v_scope;
    END IF;

    -- A governed process/project also governs its immediate has_step children.
    WITH subject_nodes AS (
        SELECT p_subject_node_id AS node_id, 0 AS endpoint_priority
        WHERE p_subject_node_id IS NOT NULL
        UNION ALL
        SELECT e.source_id, 0 FROM edges e WHERE e.id = p_subject_edge_id
        UNION ALL
        SELECT e.target_id, 1 FROM edges e WHERE e.id = p_subject_edge_id
    )
    SELECT coverage.source_id
    INTO v_scope
    FROM subject_nodes subject
    JOIN edges step
      ON step.target_id = subject.node_id
     AND step.edge_type = 'has_step'
     AND step.archived_at IS NULL
     AND (step.effective_from IS NULL OR step.effective_from <= now())
     AND (step.effective_to IS NULL OR step.effective_to > now())
    JOIN edges coverage
      ON coverage.target_id = step.source_id
     AND coverage.edge_type = 'scope_governs_subject'
     AND coverage.archived_at IS NULL
     AND (coverage.effective_from IS NULL OR coverage.effective_from <= now())
     AND (coverage.effective_to IS NULL OR coverage.effective_to > now())
    JOIN nodes scope ON scope.id = coverage.source_id
    WHERE scope.node_type = 'onboarding_scope'
      AND scope.archived_at IS NULL
      AND EXISTS (
          SELECT 1 FROM current_valid_assertions status
          WHERE status.subject_node_id = scope.id
            AND status.assertion_type = 'scope_status'
            AND status.claim->>'status' = 'active'
      )
    ORDER BY subject.endpoint_priority, scope_review_policy_rank(scope.id), scope.id
    LIMIT 1;
    IF v_scope IS NOT NULL THEN
        RETURN v_scope;
    END IF;

    -- Type coverage is intentionally strict: multiple active claims are an
    -- administrative ambiguity and must fail at write time. Restrictiveness
    -- does not break that tie, because it is not a tie.
    SELECT count(DISTINCT scope.id), (array_agg(scope.id ORDER BY scope.id))[1]
    INTO v_count, v_scope
    FROM nodes scope
    JOIN current_valid_assertions status
      ON status.subject_node_id = scope.id
     AND status.assertion_type = 'scope_status'
     AND status.claim->>'status' = 'active'
    JOIN current_valid_assertions governed
      ON governed.subject_node_id = scope.id
     AND governed.assertion_type = 'registry_entry'
     AND governed.assertion_key = 'governed_type:' || v_assertion_type
    WHERE scope.node_type = 'onboarding_scope'
      AND scope.archived_at IS NULL;

    IF v_count > 1 THEN
        RAISE EXCEPTION 'Ambiguous governing scope for assertion type %: % active scopes claim it', v_assertion_type, v_count;
    ELSIF v_count = 1 THEN
        RETURN v_scope;
    END IF;

    -- Source coverage via the primary witness, most restrictive first.
    IF p_witness_node_id IS NOT NULL THEN
        SELECT scope.id
        INTO v_scope
        FROM edges coverage
        JOIN nodes scope ON scope.id = coverage.source_id
        WHERE coverage.edge_type = 'scope_governs_source'
          AND coverage.target_id = p_witness_node_id
          AND coverage.archived_at IS NULL
          AND (coverage.effective_from IS NULL OR coverage.effective_from <= now())
          AND (coverage.effective_to IS NULL OR coverage.effective_to > now())
          AND scope.node_type = 'onboarding_scope'
          AND scope.archived_at IS NULL
          AND EXISTS (
              SELECT 1 FROM current_valid_assertions status
              WHERE status.subject_node_id = scope.id
                AND status.assertion_type = 'scope_status'
                AND status.claim->>'status' = 'active'
          )
        ORDER BY scope_review_policy_rank(scope.id), scope.id
        LIMIT 1;
        IF v_scope IS NOT NULL THEN
            RETURN v_scope;
        END IF;
    END IF;

    v_default := registry_value('DEFAULT_SCOPE', NULL);
    IF v_default IS NOT NULL AND jsonb_typeof(v_default) <> 'null' THEN
        BEGIN
            v_scope := (v_default #>> '{}')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'DEFAULT_SCOPE registry value must be a scope UUID';
        END;

        IF EXISTS (
            SELECT 1 FROM nodes scope
            WHERE scope.id = v_scope
              AND scope.node_type = 'onboarding_scope'
              AND scope.archived_at IS NULL
              AND EXISTS (
                  SELECT 1 FROM current_valid_assertions status
                  WHERE status.subject_node_id = scope.id
                    AND status.assertion_type = 'scope_status'
                    AND status.claim->>'status' = 'active'
              )
        ) THEN
            RETURN v_scope;
        END IF;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION governing_scope(uuid,uuid,text,uuid) IS
    'The one scope that governs a subject. Branch order decides first: direct scope_governs_subject coverage, inheritance through has_step, type coverage, the primary witness, then DEFAULT_SCOPE. Within the branch that matched the most restrictive review policy wins -- strict over candidates_only over open -- with scope.id only as a tie-break, so a subject two scopes govern no longer depends on uuid order. For an edge subject the source endpoint still beats the target endpoint first. Two active scopes claiming one assertion type still raise.';

-- --------------------------------------------------------------------------
-- 3. supersede_assertion() files a suggestion instead of erasing one
-- --------------------------------------------------------------------------
--
-- Replaces the 0017 definition. Under a scope where record_assertion() would
-- land this caller's write as a candidate -- strict, or candidates_only with a
-- replacement basis other than observed -- this helper now writes the
-- replacement as a CANDIDATE and does NOT call mark_assertion_superseded().
-- The incumbent stays accepted and unsuperseded.
--
-- The predicate is deliberately the same one record_assertion() applies,
-- resolved from the incumbent's own subject, type, and primary witness, using
-- the same witness query accept_assertion() uses. That is not tidiness; it is
-- the acceptance criterion, which is written as "under a scope where
-- record_assertion() would land a caller's write as a candidate".
--
-- Demote, do not refuse: refusing throws away a correction someone took the
-- trouble to state. Demote WITHOUT ending the incumbent: demoting and ending it
-- would leave the key with no accepted value and let any caller delete a fact
-- by proposing a replacement to it, which is a worse hole than the one being
-- closed. The tuple then carries one accepted row and one candidate, which is
-- what review_queue and competing_candidates are for, and accept_assertion() on
-- the candidate supersedes the incumbent then -- the ordinary acceptance path,
-- with the ordinary rival check and the ordinary acceptance event.
--
-- HOW THE CALLER IS TOLD. The signature and the return type do not change: the
-- new row's id comes back whether it is accepted or a candidate. The return
-- value does not say what happened; the row does. The candidate carries
-- attrs.review_gate, deliberately the same shape as the attrs.settle_gate
-- marker 0023 writes for the other demotion, so a client has one thing to look
-- for and not two. A NOTICE names the incumbent and the policy for an
-- interactive caller.
--
-- There is no role exemption. record_assertion() demotes for every role, and
-- inventing a role test here would contradict 0008's rule that no rule permits
-- on the basis of a claimed role. An admin under strict gets a candidate too.
CREATE OR REPLACE FUNCTION supersede_assertion(
    p_old_assertion_id uuid,
    p_new_assertion_type text,
    p_new_subject_node_id uuid,
    p_new_subject_edge_id uuid,
    p_new_claim jsonb,
    p_new_assertion_key text DEFAULT NULL,
    p_new_effective_at timestamptz DEFAULT NULL,
    p_new_effective_to timestamptz DEFAULT NULL,
    p_new_confidence numeric DEFAULT NULL,
    p_new_basis text DEFAULT NULL,
    p_new_evidence jsonb[] DEFAULT NULL,
    p_new_attrs jsonb DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_attrs jsonb;
    v_basis text;
    v_evidence jsonb[];
    v_new_id uuid := gen_random_uuid();
    v_old assertions;
    v_policy text;
    v_scope uuid;
    v_status text := 'accepted';
    v_witness uuid;
BEGIN
    PERFORM set_config('app.write_path', 'supersede_assertion', true);
    PERFORM set_config('app.supersede_assertion_id', p_old_assertion_id::text, true);

    SELECT * INTO v_old
    FROM assertions
    WHERE id = p_old_assertion_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Assertion % not found', p_old_assertion_id;
    END IF;
    IF v_old.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION 'Assertion % is already superseded', p_old_assertion_id;
    END IF;
    IF v_old.status <> 'accepted' THEN
        RAISE EXCEPTION 'Only accepted assertions may be superseded; reject candidates instead';
    END IF;
    IF coalesce(p_new_assertion_type, v_old.assertion_type) IS DISTINCT FROM v_old.assertion_type
       OR coalesce(nullif(trim(p_new_assertion_key), ''), v_old.assertion_key)
          IS DISTINCT FROM v_old.assertion_key
       OR coalesce(p_new_subject_node_id, v_old.subject_node_id)
          IS DISTINCT FROM v_old.subject_node_id
       OR coalesce(p_new_subject_edge_id, v_old.subject_edge_id)
          IS DISTINCT FROM v_old.subject_edge_id
    THEN
        RAISE EXCEPTION
            'Cross-tuple supersession is not allowed; subject, assertion_type, and assertion_key must match';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        v_old.subject_ref || ':' || v_old.assertion_type || ':' || v_old.assertion_key,
        0
    ));

    v_evidence := coalesce(
        p_new_evidence,
        ARRAY[jsonb_build_object(
            'kind', 'derivation',
            'source_assertion_id', v_old.id
        )]
    );

    -- The review policy, resolved from the incumbent's own tuple. The witness
    -- query is accept_assertion()'s: source or corroboration, source first,
    -- then recorded_at, then id.
    SELECT ae.witness_node_id INTO v_witness
    FROM assertion_evidence ae
    WHERE ae.assertion_id = v_old.id
      AND ae.kind IN ('source', 'corroboration')
      AND ae.witness_node_id IS NOT NULL
    ORDER BY CASE ae.kind WHEN 'source' THEN 0 ELSE 1 END, ae.recorded_at, ae.id
    LIMIT 1;

    v_scope := governing_scope(
        v_old.subject_node_id, v_old.subject_edge_id, v_old.assertion_type, v_witness
    );
    v_policy := scope_review_policy(v_scope);
    v_basis := lower(coalesce(nullif(trim(p_new_basis), ''), v_old.basis));
    v_attrs := coalesce(p_new_attrs, v_old.attrs, '{}'::jsonb);

    IF v_policy = 'strict'
       OR (v_policy = 'candidates_only' AND v_basis IS DISTINCT FROM 'observed')
    THEN
        v_status := 'candidate';
        v_attrs := v_attrs || jsonb_build_object(
            'review_gate', jsonb_build_object(
                'pending', true,
                'requested_status', 'accepted',
                'review_policy', v_policy,
                'scope_node_id', v_scope,
                'incumbent_assertion_id', v_old.id
            )
        );
        RAISE NOTICE
            'Review policy % on scope %: assertion % is waiting in review_queue. Assertion % still stands and was not superseded. A settler accepts the replacement with accept_assertion().',
            v_policy, coalesce(v_scope::text, 'none'), v_new_id, v_old.id;
    ELSE
        -- The incumbent is ended first, because idx_assertions_active_unique
        -- refuses two accepted unsuperseded rows on one tuple. superseded_by's
        -- foreign key is deferrable for exactly this order.
        PERFORM mark_assertion_superseded(v_old.id, v_new_id);
    END IF;

    INSERT INTO assertions (
        id,
        assertion_type,
        assertion_key,
        status,
        basis,
        classification,
        subject_node_id,
        subject_edge_id,
        claim,
        effective_at,
        effective_to,
        confidence,
        attrs
    ) VALUES (
        v_new_id,
        v_old.assertion_type,
        v_old.assertion_key,
        v_status,
        coalesce(p_new_basis, v_old.basis),
        v_old.classification,
        v_old.subject_node_id,
        v_old.subject_edge_id,
        p_new_claim,
        coalesce(p_new_effective_at, v_old.effective_at),
        coalesce(p_new_effective_to, v_old.effective_to),
        coalesce(p_new_confidence, v_old.confidence),
        v_attrs
    );

    PERFORM append_assertion_evidence(v_new_id, v_evidence);
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.supersede_assertion_id', '', true);
    RETURN v_new_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.write_path', '', true);
    PERFORM set_config('app.supersede_assertion_id', '', true);
    RAISE;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION supersede_assertion(uuid,text,uuid,uuid,jsonb,text,timestamptz,timestamptz,numeric,text,jsonb[],jsonb) IS
    'Replace an accepted assertion on its own subject, type and key. Under a scope where record_assertion() would demote this caller''s write -- strict, or candidates_only with a basis other than observed -- the replacement lands as a candidate instead, the accepted incumbent is left standing and unsuperseded, the new row carries attrs.review_gate, and a NOTICE names both. The return type does not change: the new row''s id comes back either way, and the row says what happened. Accepting the candidate with accept_assertion() supersedes the incumbent then.';

-- resolve_knowledge_gap() follows supersede_assertion(), because it is the one
-- in-repo helper that calls it. Under a demoting policy the resolved gap is
-- filed as a candidate, the knowledge_gap assertion stays open and stays in
-- open_gaps until a settler accepts, and the knowledge_gap_resolved event gains
-- pending_review and review_policy so a reader is not told the gap closed when
-- it did not. The event type is unchanged, because the act did happen and
-- consumers match on the type. The signature is unchanged.
--
-- One limit, disclosed rather than fixed: the replacement is written with basis
-- inferred, and accept_assertion() refuses an inferred candidate displacing a
-- non-inferred accepted incumbent. So under a demoting policy, a gap recorded
-- with some other basis produces a candidate no settler can accept. Record gaps
-- with basis inferred, which is what a gap is, or reject the resolution
-- candidate and record the resolved gap with record_assertion().
CREATE OR REPLACE FUNCTION resolve_knowledge_gap(
    p_gap_assertion_id uuid,
    p_answer_assertion_id uuid,
    p_actor text DEFAULT NULL
) RETURNS void
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_answer assertions;
    v_gap assertions;
    v_new_id uuid;
    v_pending boolean;
    v_policy text;
    v_witness uuid;
BEGIN
    SELECT * INTO v_gap
    FROM current_valid_assertions
    WHERE id = p_gap_assertion_id
      AND assertion_type = 'knowledge_gap';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Open knowledge gap assertion % not found', p_gap_assertion_id;
    END IF;

    SELECT * INTO v_answer
    FROM current_valid_assertions
    WHERE id = p_answer_assertion_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Accepted answer assertion % not found', p_answer_assertion_id;
    END IF;

    -- The same resolution supersede_assertion() is about to make, so the event
    -- reports the policy that actually applied rather than a second guess.
    SELECT ae.witness_node_id INTO v_witness
    FROM assertion_evidence ae
    WHERE ae.assertion_id = v_gap.id
      AND ae.kind IN ('source', 'corroboration')
      AND ae.witness_node_id IS NOT NULL
    ORDER BY CASE ae.kind WHEN 'source' THEN 0 ELSE 1 END, ae.recorded_at, ae.id
    LIMIT 1;
    v_policy := scope_review_policy(governing_scope(
        v_gap.subject_node_id, v_gap.subject_edge_id, v_gap.assertion_type, v_witness
    ));

    v_new_id := supersede_assertion(
        p_old_assertion_id := v_gap.id,
        p_new_assertion_type := v_gap.assertion_type,
        p_new_subject_node_id := v_gap.subject_node_id,
        p_new_subject_edge_id := v_gap.subject_edge_id,
        p_new_claim := v_gap.claim || jsonb_build_object(
            'status', 'resolved',
            'resolved', true,
            'answer_assertion_id', v_answer.id,
            'resolved_at', now(),
            'resolved_by', coalesce(p_actor, current_setting('app.current_user_id', true))
        ),
        p_new_assertion_key := v_gap.assertion_key,
        p_new_basis := 'inferred',
        p_new_evidence := ARRAY[
            jsonb_build_object('kind', 'derivation', 'source_assertion_id', v_gap.id),
            jsonb_build_object('kind', 'derivation', 'source_assertion_id', v_answer.id)
        ],
        p_new_attrs := v_gap.attrs || jsonb_build_object('resolved_gap', true)
    );

    -- The row says what happened, so read it rather than re-deriving it.
    SELECT status = 'candidate' AND attrs ? 'review_gate'
    INTO v_pending
    FROM assertions WHERE id = v_new_id;

    PERFORM record_event(
        p_event_type := 'knowledge_gap_resolved',
        p_summary := CASE
            WHEN coalesce(v_pending, false)
                THEN 'Knowledge gap resolution filed for review'
            ELSE 'Knowledge gap resolved by accepted assertion'
        END,
        p_properties := jsonb_build_object(
            'gap_assertion_id', v_gap.id,
            'resolved_gap_assertion_id', v_new_id,
            'answer_assertion_id', v_answer.id,
            'pending_review', coalesce(v_pending, false),
            'review_policy', v_policy
        ),
        p_participant_ids := CASE
            WHEN v_gap.subject_node_id IS NOT NULL THEN ARRAY[v_gap.subject_node_id]
            ELSE '{}'::uuid[]
        END,
        p_participant_roles := CASE
            WHEN v_gap.subject_node_id IS NOT NULL THEN ARRAY['subject']
            ELSE '{}'::text[]
        END,
        p_actor := p_actor
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION resolve_knowledge_gap(uuid,uuid,text) IS
    'Close a knowledge gap on its own tuple with the answer that resolves it. Under a demoting review policy the resolution is filed as a candidate, the gap stays open and stays in open_gaps until a settler accepts, and the knowledge_gap_resolved event carries pending_review true with the policy that applied. Because the resolution is written with basis inferred, accept_assertion() will not let it displace a non-inferred accepted gap: record gaps with basis inferred, or reject the candidate and record the resolved gap with record_assertion().';

-- --------------------------------------------------------------------------
-- 4. The insert exemption follows the helper, which means it goes
-- --------------------------------------------------------------------------
--
-- 0025 left a row accepted when an assertion on the same subject_ref,
-- assertion_type and assertion_key was already superseded, was accepted, and
-- named this row as its replacement. 0008 justified it in one sentence: what it
-- leaves open is exactly what supersede_assertion() already lets that caller do
-- on that tuple, so it adds nothing. Now that the helper demotes, that sentence
-- is false, and the exemption is the last accepted-under-strict route left.
--
-- So it is removed, not narrowed. Checked against every helper that inserts an
-- assertion, which is the only reason it existed:
--   * supersede_assertion() under a demoting policy no longer ends the
--     incumbent and inserts a candidate, so the demotion branch below is never
--     reached on its writes. Under a non-demoting policy it ends the incumbent
--     and inserts accepted, and this guard does not demote either.
--   * record_assertion() applies the policy before it supersedes, so it never
--     ends an incumbent for a write it is about to demote.
--   * record_distillation() does the same.
--   * merge_nodes() inserts the copy BEFORE it marks the duplicate's row, so
--     the exemption never applied to it in the first place. The copy is judged
--     by the canonical node's policy.
--   * accept_assertion() does not insert.
--
-- The one direction that could strand a key is this guard being stricter than
-- the helper. It resolves the scope with a null witness while the helpers pass
-- one, and the witness branch of governing_scope() runs only after the subject,
-- inheritance and type branches have produced nothing, so the guard's scope is
-- the helper's scope or a witness-free fallback. That asymmetry is unchanged
-- from 0025 and is still a stated limit in the contract.
--
-- The consequence for a raw supersede-and-replace under a demoting policy is a
-- refusal rather than a demotion: the incumbent was ended, the replacement is
-- demoted to candidate, the tuple carries nothing accepted, and
-- trg_assertions_transition_complete refuses the transaction at commit. Nothing
-- is lost. The incumbent still stands after the rollback, and
-- supersede_assertion() records the same statement as a suggestion beside it.
-- Under a non-demoting policy the same shape still commits accepted.
CREATE OR REPLACE FUNCTION assertions_insert_review_guard() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_policy      text;
    v_scope       uuid;
BEGIN
    -- Exactly one subject, refused first and at any status. assertion_has_subject
    -- is OR, not XOR, so a row carrying both columns is insertable, and
    -- governing_scope() raises on it. Skipping the review rules for such a row
    -- let a caller write an accepted assertion onto a node in a strict scope.
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
    'Refuse an assertion that does not carry exactly one subject, at any status, because governing_scope() cannot read that shape and no helper writes it. Otherwise judge a direct INSERT of an accepted assertion by the same review policy record_assertion() applies, and demote it to candidate where that policy demotes. Nothing said is lost. There is no exemption: 0025''s supersede-then-insert exemption was removed by 0027, because every helper that inserts a replacement now applies the review policy itself and never ends an incumbent it is about to replace with a candidate. A raw supersede-and-replace under a demoting policy is therefore refused at commit by trg_assertions_transition_complete rather than landing accepted.';
