-- Prediction scoring works when the database owner is not a superuser.
--
-- Work item: work/006-calibration-nonsuperuser-owner.md
-- Contract:  contracts/sql-surface.md (read; no rule changed)
--
-- score_due_predictions() drove its loop from
--
--     SELECT a.* FROM assertions a WHERE ... FOR UPDATE OF a
--
-- `FOR UPDATE` makes PostgreSQL apply the UPDATE policy's USING clause to
-- every candidate row, as a filter, in addition to the SELECT policy.
-- assertion_update_policy admits a row only while app.write_path names one
-- of the five helper write paths and the matching id variable holds that
-- row's id. At the moment the cursor opens no gate is set -- the gate is
-- opened later, inside mark_assertion_outcome(), around its own UPDATE. So
-- the USING clause was false for every row, the cursor returned nothing, and
-- the function returned 0 without scoring anything. It reported success and
-- left every prediction unlabeled, so calibration_report and the prediction
-- columns of source_reliability stayed empty.
--
-- This was invisible on the Docker test database because its owner `rye` is
-- a superuser: the SECURITY DEFINER function ran with RLS bypassed and the
-- lock filter never applied. On Supabase, where the owner `postgres` is
-- NOSUPERUSER, and on any install owned by an ordinary role, FORCE ROW LEVEL
-- SECURITY applies the policy to the definer too.
--
-- The fix keeps the lock and moves it inside the gate, which is the pattern
-- supersede_assertion() and accept_assertion() already use: drive the loop
-- from an unlocked read that sees exactly what the calling session may see,
-- then, for one prediction at a time, open the assertion_outcome gate for
-- that id, take the row lock, and close the gate again. Re-reading the row
-- under the lock also makes concurrent scorers safe: a prediction another
-- session labeled while we queued is skipped instead of scored twice.
--
-- Nothing here widens visibility. The driving read uses the same predicate
-- as before under the same SELECT policy, and the gate is opened for one
-- already-visible id at a time.

SET search_path = rye, pg_catalog, public;

CREATE OR REPLACE FUNCTION score_due_predictions()
RETURNS int
SECURITY DEFINER
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_actual assertions;
    v_count int := 0;
    v_event_id uuid;
    v_outcome text;
    v_prediction assertions;
    v_prediction_id uuid;
    v_prediction_type text;
    v_prediction_key text;
    v_probability numeric;
BEGIN
    FOR v_prediction_id IN
        SELECT a.id
        FROM assertions a
        WHERE a.assertion_type = 'prediction'
          AND a.status = 'accepted'
          AND a.superseded_at IS NULL
          AND (a.effective_at IS NULL OR a.effective_at <= now())
          AND (a.effective_to IS NULL OR a.effective_to > now())
          AND NOT (a.attrs ? 'outcome')
          AND (a.claim->>'horizon')::timestamptz <= now()
        ORDER BY (a.claim->>'horizon')::timestamptz, a.id
    LOOP
        -- Take the row lock inside the same write-path gate that admits the
        -- outcome UPDATE. FOR UPDATE evaluates assertion_update_policy's
        -- USING clause, so without the gate the row is filtered away.
        v_prediction := NULL;
        BEGIN
            PERFORM set_config('app.write_path', 'assertion_outcome', true);
            PERFORM set_config('app.outcome_assertion_id', v_prediction_id::text, true);

            SELECT a.* INTO v_prediction
            FROM assertions a
            WHERE a.id = v_prediction_id
              AND a.status = 'accepted'
              AND a.superseded_at IS NULL
              AND NOT (a.attrs ? 'outcome')
            FOR UPDATE;

            PERFORM set_config('app.write_path', '', true);
            PERFORM set_config('app.outcome_assertion_id', '', true);
        EXCEPTION WHEN OTHERS THEN
            PERFORM set_config('app.write_path', '', true);
            PERFORM set_config('app.outcome_assertion_id', '', true);
            RAISE;
        END;

        -- Another session scored or superseded it while we queued.
        CONTINUE WHEN v_prediction.id IS NULL;

        v_prediction_type := split_part(v_prediction.claim->>'outcome_key', ':', 1);
        v_prediction_key := substr(
            v_prediction.claim->>'outcome_key',
            strpos(v_prediction.claim->>'outcome_key', ':') + 1
        );
        v_probability := (v_prediction.claim->>'probability')::numeric;

        v_actual := NULL;
        SELECT outcome.* INTO v_actual
        FROM assertions_as_of((v_prediction.claim->>'horizon')::timestamptz, now()) outcome
        WHERE outcome.subject_ref = v_prediction.subject_ref
          AND outcome.assertion_type = canonical_type('assertion_type', v_prediction_type)
          AND outcome.assertion_key = v_prediction_key
        ORDER BY outcome.asserted_at DESC, outcome.effective_at DESC NULLS LAST, outcome.id
        LIMIT 1;

        IF NOT FOUND THEN
            v_outcome := 'unresolvable';
        ELSIF v_actual.claim @> (v_prediction.claim->'predicted_value') THEN
            v_outcome := 'correct';
        ELSE
            v_outcome := 'incorrect';
        END IF;

        v_event_id := record_event(
            p_event_type := 'prediction_scored',
            p_summary := format('Prediction %s scored %s', v_prediction.id, v_outcome),
            p_properties := jsonb_build_object(
                'prediction_assertion_id', v_prediction.id,
                'outcome', v_outcome,
                'outcome_assertion_id', v_actual.id,
                'probability', v_probability,
                'brier_score', CASE
                    WHEN v_outcome = 'unresolvable' THEN NULL
                    ELSE power(v_probability - CASE WHEN v_outcome = 'correct' THEN 1 ELSE 0 END, 2)
                END,
                'horizon', v_prediction.claim->>'horizon'
            ),
            p_participant_ids := CASE
                WHEN v_prediction.subject_node_id IS NOT NULL THEN ARRAY[v_prediction.subject_node_id]
                ELSE '{}'::uuid[]
            END,
            p_participant_roles := CASE
                WHEN v_prediction.subject_node_id IS NOT NULL THEN ARRAY['subject']
                ELSE '{}'::text[]
            END,
            p_actor := 'system:prediction-scorer'
        );

        PERFORM mark_assertion_outcome(
            v_prediction.id,
            v_outcome,
            jsonb_build_object(
                'prediction_scored_event_id', v_event_id,
                'outcome_assertion_id', v_actual.id,
                'brier_score', CASE
                    WHEN v_outcome = 'unresolvable' THEN NULL
                    ELSE power(v_probability - CASE WHEN v_outcome = 'correct' THEN 1 ELSE 0 END, 2)
                END
            )
        );
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION score_due_predictions() IS
    'Label every accepted prediction whose horizon has passed with correct, incorrect, or unresolvable, and record a prediction_scored event for each. Returns the number scored. Reads what the calling session may read; locks each row inside the assertion_outcome write-path gate so the lock is not filtered away by assertion_update_policy when the database owner is not a superuser.';
