-- add_comment() reads codes wider than four digits.
--
-- Work item: work/011-loose-ends.md (work/009 Verifier MEDIUM, second pass).
-- Companion to schema/migrations/0029_supporting_tables_rls.sql, which makes
-- generate_crm_code() widen a sequence past 9999 instead of truncating it.
--
-- add_comment() links codes mentioned in a comment body, and its pattern
-- assumed exactly four sequence digits, so it would stop seeing a code the
-- moment a month passed 9999. It lives here rather than in 0029 because
-- scripts/migrate.sh applies files in name order and 0110 would overwrite a
-- 0029 definition on a fresh install.
--
-- Carried forward from 0110 unchanged except that one quantifier.

SET search_path = rye, pg_catalog, public;

CREATE OR REPLACE FUNCTION add_comment(
    p_task_id uuid,
    p_body text,
    p_actor text DEFAULT NULL,
    p_reply_to_event_id uuid DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog, public
AS $$
DECLARE
    v_event_id uuid;
    v_task_code text;
    v_code_pattern text := '(?:OPP|TSK|PRJ|CON|MIL|SPR)-\\d{4}-\\d{4,}';
    v_match text;
    v_mentioned_id uuid;
BEGIN
    SELECT properties->>'code' INTO v_task_code
    FROM nodes
    WHERE id = p_task_id;

    v_event_id := record_event(
        p_event_type        := 'comment',
        p_summary           := format('Comment on %s', v_task_code),
        p_properties        := jsonb_build_object('body', p_body, 'reply_to', p_reply_to_event_id),
        p_participant_ids   := ARRAY[p_task_id],
        p_participant_roles := ARRAY['subject'],
        p_actor             := p_actor
    );

    FOR v_match IN
        SELECT (regexp_matches(p_body, v_code_pattern, 'g'))[1]
    LOOP
        SELECT id INTO v_mentioned_id
        FROM nodes
        WHERE properties->>'code' = v_match
          AND archived_at IS NULL
        LIMIT 1;

        IF v_mentioned_id IS NOT NULL AND v_mentioned_id <> p_task_id THEN
            INSERT INTO event_participants (event_id, node_id, role)
            VALUES (v_event_id, v_mentioned_id, 'mentioned')
            ON CONFLICT (event_id, node_id, role) DO NOTHING;
        END IF;
    END LOOP;

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;
