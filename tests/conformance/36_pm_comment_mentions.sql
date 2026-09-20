-- add_comment() links the codes a comment mentions.
--
-- Work item: work/011-loose-ends.md (work/009 Verifier MEDIUM, third pass).
-- Migration: schema/migrations/0124_profile_pm_code_width.sql.
--
-- The pattern was written `\\d` inside a dollar-quoted body. The body is
-- dollar-quoted but the pattern is an ordinary string literal inside it, so
-- with standard_conforming_strings on the stored pattern asked for a literal
-- backslash followed by `d`. No comment contains one, so mention linking has
-- never linked anything, for any code width. Nothing measured it, because
-- nothing tested add_comment() at all.
--
-- This suite measures the participants, not the pattern: a comment naming a
-- four-digit code, a five-digit code, a code no node carries, and the
-- commented task's own code twice.
--
-- Negative control: on f5529c8 (or any tree without 0124's single backslashes)
-- the first assertion fails with 0 mentioned participants.
--
-- pm profile only. An instance installed without it has no add_comment(), and
-- this suite says so and stops rather than failing.

SET search_path = rye, public, pg_catalog;

BEGIN;

DO $$
DECLARE
    v_bypass    boolean;
    v_code_four text;
    v_code_five text;
    v_event     uuid;
    v_four      uuid;
    v_five      uuid;
    v_mentions  uuid[];
    v_own       text;
    v_owner     uuid;
    v_super     boolean;
    v_task      uuid;
    v_yymm      text := to_char(now(), 'YYMM');
BEGIN
    SELECT rolsuper, rolbypassrls INTO v_super, v_bypass
    FROM pg_roles WHERE rolname = current_user;
    IF coalesce(v_super, false) OR coalesce(v_bypass, false) THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: % is rolsuper=% rolbypassrls=% and is not bound by RLS. Run this suite as scripts/conformance.sh and scripts/test-nonsuperuser-owner.sh do.',
            current_user, v_super, v_bypass;
    END IF;
    IF current_setting('row_security', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'Refusing to pass vacuously: row_security is %',
            current_setting('row_security', true);
    END IF;

    IF to_regprocedure('rye.add_comment(uuid,text,text,uuid)') IS NULL THEN
        RAISE NOTICE 'SKIP: the pm profile is not installed, so there is no add_comment()';
        RETURN;
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:comment-mentions', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Wren', '{"suite":"comment_mentions"}')
    RETURNING id INTO v_owner;

    -- An ordinary writing role writes the comment, not only an admin.
    PERFORM set_config('app.current_role', 'team_member', true);
    v_task := create_task(p_title := 'Comment mentions task', p_assigned_to_id := v_owner);
    SELECT properties->>'code' INTO v_own FROM nodes WHERE id = v_task;

    -- One mentioned task with an ordinary four-digit code, and one with a
    -- five-digit code, which is what generate_crm_code() issues past 9999
    -- (0029). The wide one is written directly, because walking a counter to
    -- 10000 belongs to tests/conformance/35_supporting_tables_rls.sql and this
    -- suite is about what the pattern sees.
    v_four := create_task(p_title := 'Four digit mentioned task', p_assigned_to_id := v_owner);
    SELECT properties->>'code' INTO v_code_four FROM nodes WHERE id = v_four;

    v_code_five := 'TSK-' || v_yymm || '-10000';
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('task', 'Five digit mentioned task',
            jsonb_build_object('suite', 'comment_mentions', 'code', v_code_five))
    RETURNING id INTO v_five;

    IF v_own IS NULL OR v_code_four IS NULL OR v_own = v_code_four THEN
        RAISE EXCEPTION 'Premise broken: the fixture codes are % and %', v_own, v_code_four;
    END IF;
    IF length(split_part(v_code_four, '-', 3)) <> 4
       OR length(split_part(v_code_five, '-', 3)) <> 5 THEN
        RAISE EXCEPTION 'Premise broken: the fixture codes are not four and five digits';
    END IF;

    -- The comment names, in order: a code no node carries, the four-digit
    -- code, the five-digit code, and the commented task's own code twice.
    v_event := add_comment(
        v_task,
        format(
            'Blocked on %s (which nobody created), see %s and %s. Filed under %s, and again %s.',
            'TSK-' || v_yymm || '-9998', v_code_four, v_code_five, v_own, v_own
        ),
        'test:comment-mentions'
    );

    SELECT array_agg(node_id ORDER BY node_id) INTO v_mentions
    FROM event_participants
    WHERE event_id = v_event AND role = 'mentioned';

    IF v_mentions IS NULL THEN
        RAISE EXCEPTION
            'add_comment() linked no mentioned participants: the code pattern matches nothing';
    END IF;
    IF NOT (v_four = ANY(v_mentions)) THEN
        RAISE EXCEPTION 'The four-digit code % was not linked', v_code_four;
    END IF;
    IF NOT (v_five = ANY(v_mentions)) THEN
        RAISE EXCEPTION 'The five-digit code % was not linked', v_code_five;
    END IF;
    IF cardinality(v_mentions) <> 2 THEN
        RAISE EXCEPTION
            'add_comment() linked % mentioned participants, expected exactly the two codes that name a node: %',
            cardinality(v_mentions), v_mentions;
    END IF;
    IF v_task = ANY(v_mentions) THEN
        RAISE EXCEPTION 'The commented task was linked as a mention of itself';
    END IF;

    -- The same code twice in one body is one participant, and a second
    -- comment repeating a mention is a second event with its own row.
    v_event := add_comment(v_task, format('Again: %s %s', v_code_four, v_code_four),
                           'test:comment-mentions');
    IF (SELECT count(*) FROM event_participants
        WHERE event_id = v_event AND role = 'mentioned') <> 1 THEN
        RAISE EXCEPTION 'A code named twice in one comment linked % participants',
            (SELECT count(*) FROM event_participants
             WHERE event_id = v_event AND role = 'mentioned');
    END IF;

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
END
$$;

ROLLBACK;
