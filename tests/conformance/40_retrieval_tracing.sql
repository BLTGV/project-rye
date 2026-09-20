-- Retrieval tracing: a step on the event.
--
-- Contract:  contracts/sql-surface.md, "Retrieval tracing".
-- Decision:  docs/decisions/0011-retrieval-tracing-is-a-step-on-the-event.md.
-- Work item: work/015-retrieval-eval-and-tracing.md. Migration 0034.
--
-- The eight numbered obligations from the decision, in order, plus the static
-- guard that keeps every read surface out of the write path.
--
-- Every case runs under a role RLS applies to: scripts/conformance.sh runs SQL
-- suites under RYE_TEST_ROLE when the connection is a superuser, and under
-- ./scripts/test-nonsuperuser-owner.sh they run as an owner that is NOSUPERUSER
-- NOBYPASSRLS. Obligation 0 refuses to let the suite pass vacuously under
-- either.
--
-- Negative control: without 0034 this suite fails at obligation 0, because
-- neither the five-argument log_agent_query() nor agent_query_trace exists.
--
-- `SET app.current_role = ...` is a syntax error because current_role is a
-- reserved word, so every case uses set_config() and asserts the read-back.
--
-- The whole suite is one transaction, which is the point of obligation 4:
-- record_event() stamps occurred_at with now(), which is transaction start, so
-- every event below shares a timestamp and only seq can order a loop.
--
-- Invented names only: Fenn, Odile, Halvard, Brannoc.

SET search_path = rye, public, pg_catalog;

BEGIN;

CREATE TEMP TABLE rt_fixture (k text PRIMARY KEY, v uuid);

-- --------------------------------------------------------------------------
-- Obligation 0. Refuse to pass vacuously, and fail without 0034.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_bypass boolean;
    v_node   uuid;
    v_probe  uuid;
    v_role   text;
    v_seen   integer;
    v_super  boolean;
BEGIN
    SELECT rolsuper, rolbypassrls INTO v_super, v_bypass
    FROM pg_roles WHERE rolname = current_user;
    IF coalesce(v_super, false) THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: % is a superuser and bypasses RLS. Run this suite as scripts/conformance.sh does.',
            current_user;
    END IF;
    IF coalesce(v_bypass, false) THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: % has BYPASSRLS, so every policy below is inert.',
            current_user;
    END IF;
    IF current_setting('row_security', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'Refusing to pass vacuously: row_security is %',
            current_setting('row_security', true);
    END IF;

    -- The negative control. Both objects 0034 adds, by exact signature.
    IF to_regprocedure('rye.log_agent_query(text, text, text, uuid[], jsonb)') IS NULL THEN
        RAISE EXCEPTION
            'log_agent_query(text, text, text, uuid[], jsonb) is missing: migration 0034 is not applied';
    END IF;
    IF to_regclass('rye.agent_query_trace') IS NULL THEN
        RAISE EXCEPTION
            'the agent_query_trace view is missing: migration 0034 is not applied';
    END IF;

    -- And no four-argument overload beside it, or every existing call would
    -- raise "function log_agent_query(...) is not unique" at call time.
    IF to_regprocedure('rye.log_agent_query(text, text, text, uuid[])') IS NOT NULL THEN
        RAISE EXCEPTION
            'a four-argument log_agent_query overload still exists; both would match a four-argument call and PostgreSQL would refuse it as ambiguous';
    END IF;

    -- The security setting and search_path 0002 had, unchanged by the DROP
    -- and CREATE. A SECURITY DEFINER log_agent_query() would hand a viewer a
    -- write and obligation 6 would be untestable.
    IF EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'rye' AND p.proname = 'log_agent_query' AND p.prosecdef
    ) THEN
        RAISE EXCEPTION 'log_agent_query is SECURITY DEFINER; 0002 had it SECURITY INVOKER and the write gate depends on that';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'rye' AND p.proname = 'log_agent_query'
          AND 'search_path=rye, pg_catalog' = ANY(coalesce(p.proconfig, '{}'::text[]))
    ) THEN
        RAISE EXCEPTION 'log_agent_query does not declare search_path=rye, pg_catalog as 0002 did';
    END IF;

    -- The view is security_invoker, or obligation 7 proves nothing.
    IF NOT EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'rye' AND c.relname = 'agent_query_trace'
          AND 'security_invoker=true' = ANY(coalesce(c.reloptions, '{}'::text[]))
    ) THEN
        RAISE EXCEPTION 'agent_query_trace is not security_invoker';
    END IF;

    -- Every role this suite uses must read back from the setting it was set
    -- with, or a case could silently run as the previous role.
    FOREACH v_role IN ARRAY ARRAY['admin', 'team_member', 'viewer', 'agent:trace40', ''] LOOP
        PERFORM set_config('app.current_role', v_role, true);
        IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
            RAISE EXCEPTION
                'Refusing to pass vacuously: app.current_role did not read back as "%", it reads "%"',
                v_role, current_setting('app.current_role', true);
        END IF;
    END LOOP;

    -- The write gate this suite leans on must be the rule the instance holds.
    PERFORM set_config('app.current_role', 'viewer', true);
    IF rye_role_may_write() THEN
        RAISE EXCEPTION 'Refusing to pass vacuously: rye_role_may_write() is true for a viewer';
    END IF;
    PERFORM set_config('app.current_role', '', true);
    IF rye_role_may_write() THEN
        RAISE EXCEPTION 'Refusing to pass vacuously: rye_role_may_write() is true for an unset role';
    END IF;

    -- Behavioural proof that RLS filters for this connection at all.
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:retrieval-tracing', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Brannoc', '{"suite":"retrieval_tracing"}')
    RETURNING id INTO v_node;
    v_probe := record_assertion(
        'compensation', '{"value":"rls probe"}', v_node,
        p_assertion_key := 'retrieval_tracing:probe', p_basis := 'assumed'
    );

    PERFORM set_config('app.current_role', 'viewer', true);
    SELECT count(*) INTO v_seen FROM assertions WHERE id = v_probe;
    IF v_seen <> 0 THEN
        RAISE EXCEPTION
            'Refusing to pass vacuously: a viewer can read a read-gated assertion type, so RLS is not in force';
    END IF;
    PERFORM set_config('app.current_role', 'admin', true);
END
$$;

-- --------------------------------------------------------------------------
-- Fixtures, as admin. Nothing here is classified except the node obligation 7
-- needs hidden, so every other row is visible to every role below.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_fenn    uuid;
    v_odile   uuid;
    v_halvard uuid;
    v_hidden  uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:retrieval-tracing', true);
    PERFORM set_config('app.current_teams', '', true);

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Fenn', '{"suite":"retrieval_tracing"}') RETURNING id INTO v_fenn;
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('org', 'Odile Instruments', '{"suite":"retrieval_tracing"}') RETURNING id INTO v_odile;
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('person', 'Halvard', '{"suite":"retrieval_tracing"}') RETURNING id INTO v_halvard;

    -- A node no session below can read: classified, and fenced to a team none
    -- of them carries. The classification is required because a node with
    -- teams and no classification is refused by trigger. The id is generated
    -- before the INSERT because INSERT ... RETURNING on an RLS table needs the
    -- SELECT policy to admit the new row, and the whole point of this row is
    -- that it does not.
    v_hidden := gen_random_uuid();
    INSERT INTO nodes (id, node_type, label, properties, attrs)
    VALUES (v_hidden, 'person', 'Odile Keeper', '{"suite":"retrieval_tracing"}',
            '{"classification":"restricted","teams":["retrieval-tracing-sealed"]}');

    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES ('employs', v_odile, v_fenn, '{"suite":"retrieval_tracing"}');

    PERFORM record_assertion(
        'rt_role', '{"value":"instrument fitter"}', v_fenn,
        p_assertion_key := 'retrieval_tracing:role',
        p_status := 'accepted', p_basis := 'assumed'
    );

    INSERT INTO rt_fixture (k, v) VALUES
        ('fenn', v_fenn), ('odile', v_odile),
        ('halvard', v_halvard), ('hidden', v_hidden);
END
$$;

-- --------------------------------------------------------------------------
-- 40.1 Every pre-existing call shape still works.
--
-- Positional four arguments is the shape of every in-repo caller
-- (tests/scenarios/05, tests/conformance/26,
-- skills/rye-agent-ops/references/sql-patterns.md). Named arguments and the
-- bare four-argument SELECT form are checked too, because a client outside the
-- repo may use either and a widened signature has to resolve all three.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_fenn  uuid;
    v_event uuid;
    v_named uuid;
    v_sel   uuid;
    v_row   record;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    SELECT v INTO v_fenn FROM rt_fixture WHERE k = 'fenn';

    -- The shape every existing caller uses.
    v_event := log_agent_query(
        'trace40-legacy',
        'Who works at Odile Instruments?',
        'Found 1 person',
        ARRAY[v_fenn]
    );
    IF v_event IS NULL THEN
        RAISE EXCEPTION '40.1: a four-argument log_agent_query returned no event id';
    END IF;

    -- Anti-vacuity: the row exists, it is an agent_query, and the properties
    -- are the ones 0002 wrote.
    SELECT event_type, properties, summary INTO v_row
    FROM events WHERE id = v_event;
    IF NOT FOUND THEN
        RAISE EXCEPTION '40.1: the event log_agent_query returned does not exist';
    END IF;
    IF v_row.event_type <> 'agent_query' THEN
        RAISE EXCEPTION '40.1: event_type is %, not agent_query', v_row.event_type;
    END IF;
    IF v_row.properties->>'query' <> 'Who works at Odile Instruments?' THEN
        RAISE EXCEPTION '40.1: properties.query is %', v_row.properties->>'query';
    END IF;
    IF v_row.properties->>'agent_id' <> 'trace40-legacy' THEN
        RAISE EXCEPTION '40.1: properties.agent_id is %', v_row.properties->>'agent_id';
    END IF;
    IF v_row.summary <> 'Found 1 person' THEN
        RAISE EXCEPTION '40.1: summary is %', v_row.summary;
    END IF;
    IF v_row.properties ? 'trace' THEN
        RAISE EXCEPTION '40.1: an untraced call wrote a trace key: %', v_row.properties->'trace';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM event_participants
        WHERE event_id = v_event AND node_id = v_fenn AND role = 'queried'
    ) THEN
        RAISE EXCEPTION '40.1: the queried participant was not recorded';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM events WHERE id = v_event AND actor_system = 'agent:trace40-legacy') THEN
        RAISE EXCEPTION '40.1: actor_system is not agent:trace40-legacy';
    END IF;

    -- Named arguments, by the parameter names 0002 published.
    v_named := log_agent_query(
        p_agent_id         := 'trace40-named',
        p_query_text       := 'Who works at Odile Instruments?',
        p_result_summary   := 'Found 1 person',
        p_nodes_referenced := ARRAY[v_fenn]
    );
    IF (SELECT properties ? 'trace' FROM events WHERE id = v_named) THEN
        RAISE EXCEPTION '40.1: a named four-argument call wrote a trace key';
    END IF;
    IF (SELECT properties->>'agent_id' FROM events WHERE id = v_named) <> 'trace40-named' THEN
        RAISE EXCEPTION '40.1: a named four-argument call did not record its agent_id';
    END IF;

    -- And the bare SELECT form with an empty node array.
    SELECT log_agent_query('trace40-empty', 'nothing matched', 'no rows', ARRAY[]::uuid[])
    INTO v_sel;
    IF (SELECT event_type FROM events WHERE id = v_sel) <> 'agent_query' THEN
        RAISE EXCEPTION '40.1: a call with no participants did not write an agent_query event';
    END IF;

    RAISE NOTICE '40.1 four-argument callers are unchanged';
END
$$;

-- --------------------------------------------------------------------------
-- 40.2 A trace lands whole.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_fenn  uuid;
    v_odile uuid;
    v_event uuid;
    v_trace jsonb;
    v_view  record;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    SELECT v INTO v_fenn FROM rt_fixture WHERE k = 'fenn';
    SELECT v INTO v_odile FROM rt_fixture WHERE k = 'odile';

    v_trace := jsonb_build_object(
        'trace_id', 'trace40-whole',
        'seq', 2,
        'tool', 'find_nodes',
        'intent', 'narrow the first phrasing to people',
        'args', jsonb_build_object('query', 'fitter at Odile', 'p_node_types', jsonb_build_array('person')),
        'results', jsonb_build_array(
            jsonb_build_object('node_id', v_fenn, 'score', 0.91, 'match_reason', 'trigram_label', 'used', true),
            jsonb_build_object('node_id', v_odile, 'score', 0.42, 'match_reason', 'trigram_label', 'used', false)
        ),
        'selected', jsonb_build_object('node_id', v_fenn, 'from_seq', 1, 'from_phrasing', 'instrument fitter')
    );

    v_event := log_agent_query(
        'trace40-whole-agent', 'fitter at Odile', 'Found Fenn', ARRAY[v_fenn], v_trace
    );

    IF (SELECT properties->'trace' FROM events WHERE id = v_event) IS DISTINCT FROM v_trace THEN
        RAISE EXCEPTION '40.2: properties.trace is not what was passed: %',
            (SELECT properties->'trace' FROM events WHERE id = v_event);
    END IF;
    -- The phrasing still lives where it always did.
    IF (SELECT properties->>'query' FROM events WHERE id = v_event) <> 'fitter at Odile' THEN
        RAISE EXCEPTION '40.2: the trace displaced properties.query';
    END IF;

    -- trace_id reads as text and seq as an integer, through the view.
    SELECT * INTO v_view FROM agent_query_trace WHERE event_id = v_event;
    IF NOT FOUND THEN
        RAISE EXCEPTION '40.2: the traced event is absent from agent_query_trace';
    END IF;
    IF v_view.trace_id <> 'trace40-whole' THEN
        RAISE EXCEPTION '40.2: trace_id reads as %', v_view.trace_id;
    END IF;
    IF v_view.seq <> 2 THEN
        RAISE EXCEPTION '40.2: seq reads as %', v_view.seq;
    END IF;
    IF pg_typeof(v_view.seq)::text <> 'integer' THEN
        RAISE EXCEPTION '40.2: seq is typed %, not integer', pg_typeof(v_view.seq);
    END IF;
    IF v_view.tool <> 'find_nodes'
       OR v_view.intent <> 'narrow the first phrasing to people'
       OR v_view.args->>'query' <> 'fitter at Odile'
       OR jsonb_array_length(v_view.results) <> 2
       OR v_view.selected->>'from_seq' <> '1' THEN
        RAISE EXCEPTION '40.2: the view lost a trace field: tool=% intent=% args=% results=% selected=%',
            v_view.tool, v_view.intent, v_view.args, v_view.results, v_view.selected;
    END IF;
    IF v_view.agent_id <> 'trace40-whole-agent' OR v_view.query <> 'fitter at Odile'
       OR v_view.summary <> 'Found Fenn' THEN
        RAISE EXCEPTION '40.2: the view lost an event field';
    END IF;
    IF v_view.node_ids <> ARRAY[v_fenn] THEN
        RAISE EXCEPTION '40.2: node_ids is %, expected the one participant', v_view.node_ids;
    END IF;

    -- Rejected candidates are recorded: the one that was not used is in
    -- results with its score and its reason, which is what separates "never
    -- returned" from "returned at rank 2 and passed over".
    IF NOT EXISTS (
        SELECT 1 FROM agent_query_trace t,
             LATERAL jsonb_array_elements(t.results) r
        WHERE t.event_id = v_event
          AND (r->>'node_id')::uuid = v_odile
          AND (r->>'used')::boolean = false
          AND r->>'match_reason' IS NOT NULL
          AND (r->>'score')::numeric > 0
    ) THEN
        RAISE EXCEPTION '40.2: the rejected candidate is not readable from results';
    END IF;

    -- And the cap is the caller's, so a caller that caps at ten writes ten.
    v_event := log_agent_query(
        'trace40-cap-agent', 'many candidates', 'capped at ten', ARRAY[v_fenn],
        jsonb_build_object(
            'trace_id', 'trace40-cap',
            'seq', 1,
            'results', (
                SELECT jsonb_agg(jsonb_build_object(
                    'node_id', v_odile, 'score', 1.0 / i, 'match_reason', 'trigram_label',
                    'used', i = 1))
                FROM generate_series(1, 10) i
            )
        )
    );
    IF (SELECT jsonb_array_length(results) FROM agent_query_trace WHERE event_id = v_event) <> 10 THEN
        RAISE EXCEPTION '40.2: a capped candidate list did not land whole';
    END IF;

    RAISE NOTICE '40.2 a trace lands whole, rejected candidates included';
END
$$;

-- --------------------------------------------------------------------------
-- 40.3 An ungroupable trace is refused.
--
-- A trace that cannot be grouped or ordered is worse than no trace, because it
-- looks like data. Each refusal is asserted twice: the call raised, and no new
-- agent_query event carries the agent id it would have written. The second
-- check is reinforced rather than established by the EXCEPTION block's
-- subtransaction rollback, so the first check -- that it raised at all, with
-- our own message -- is the load-bearing one.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_fenn   uuid;
    v_case   record;
    v_failed boolean;
    v_msg    text;
    v_before bigint;
    v_after  bigint;
    v_dummy  uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    SELECT v INTO v_fenn FROM rt_fixture WHERE k = 'fenn';

    FOR v_case IN
        SELECT * FROM (VALUES
            ('no trace_id',        '{"seq": 1}'::jsonb),
            ('blank trace_id',     '{"trace_id": "   ", "seq": 1}'::jsonb),
            ('empty trace_id',     '{"trace_id": "", "seq": 1}'::jsonb),
            ('non-text trace_id',  '{"trace_id": 7, "seq": 1}'::jsonb),
            ('no seq',             '{"trace_id": "trace40-bad"}'::jsonb),
            ('seq of 0',           '{"trace_id": "trace40-bad", "seq": 0}'::jsonb),
            ('negative seq',       '{"trace_id": "trace40-bad", "seq": -3}'::jsonb),
            ('fractional seq',     '{"trace_id": "trace40-bad", "seq": 1.5}'::jsonb),
            ('non-numeric seq',    '{"trace_id": "trace40-bad", "seq": "two"}'::jsonb),
            ('a jsonb array',      '[{"trace_id": "trace40-bad", "seq": 1}]'::jsonb),
            ('a jsonb string',     '"trace40-bad"'::jsonb),
            ('a jsonb number',     '1'::jsonb)
        ) AS c(label, trace)
    LOOP
        SELECT count(*) INTO v_before FROM events
        WHERE event_type = 'agent_query' AND properties->>'agent_id' = 'trace40-refused';

        v_failed := false;
        BEGIN
            v_dummy := log_agent_query(
                'trace40-refused', 'a question', 'a summary', ARRAY[v_fenn], v_case.trace
            );
        EXCEPTION WHEN others THEN
            v_failed := true;
            v_msg := SQLERRM;
        END;

        IF NOT v_failed THEN
            RAISE EXCEPTION '40.3: log_agent_query accepted an ungroupable trace (%): %',
                v_case.label, v_case.trace;
        END IF;
        IF v_msg NOT LIKE '%p_trace%' THEN
            RAISE EXCEPTION '40.3: (%) raised for the wrong reason: %', v_case.label, v_msg;
        END IF;

        SELECT count(*) INTO v_after FROM events
        WHERE event_type = 'agent_query' AND properties->>'agent_id' = 'trace40-refused';
        IF v_after <> v_before THEN
            RAISE EXCEPTION '40.3: (%) left an agent_query event behind', v_case.label;
        END IF;
    END LOOP;

    -- An explicit jsonb null is the same as passing nothing: it is not a
    -- malformed trace, it is no trace.
    v_dummy := log_agent_query(
        'trace40-jsonnull', 'a question', 'a summary', ARRAY[v_fenn], 'null'::jsonb
    );
    IF (SELECT properties ? 'trace' FROM events WHERE id = v_dummy) THEN
        RAISE EXCEPTION '40.3: a jsonb null trace wrote a trace key';
    END IF;

    RAISE NOTICE '40.3 an ungroupable trace is refused, and nothing is written';
END
$$;

-- --------------------------------------------------------------------------
-- 40.4 Ordering survives a timestamp tie.
--
-- The three calls are made out of order (3, 1, 2) so that neither insertion
-- order nor event_id can produce the right answer by accident.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_fenn   uuid;
    v_ids    uuid[] := ARRAY[]::uuid[];
    v_seqs   int[] := ARRAY[]::int[];
    v_row    record;
    v_stamps bigint;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    SELECT v INTO v_fenn FROM rt_fixture WHERE k = 'fenn';

    v_ids := v_ids || log_agent_query('trace40-loop', 'third phrasing', 'settled', ARRAY[v_fenn],
        jsonb_build_object('trace_id', 'trace40-order', 'seq', 3, 'intent', 'judge the candidate'));
    v_ids := v_ids || log_agent_query('trace40-loop', 'first phrasing', 'nothing', ARRAY[v_fenn],
        jsonb_build_object('trace_id', 'trace40-order', 'seq', 1, 'intent', 'locate by label'));
    v_ids := v_ids || log_agent_query('trace40-loop', 'second phrasing', 'two candidates', ARRAY[v_fenn],
        jsonb_build_object('trace_id', 'trace40-order', 'seq', 2, 'intent', 'reformulate'));

    -- Anti-vacuity: the three timestamps really are equal, or the test proves
    -- nothing about ordering by seq.
    SELECT count(DISTINCT occurred_at) INTO v_stamps FROM events WHERE id = ANY(v_ids);
    IF v_stamps <> 1 THEN
        RAISE EXCEPTION
            '40.4: the three events do not share occurred_at (% distinct values), so the tie this obligation is about did not happen',
            v_stamps;
    END IF;

    -- No outer ORDER BY: the order below is the view's own.
    FOR v_row IN SELECT seq, query FROM agent_query_trace WHERE trace_id = 'trace40-order' LOOP
        v_seqs := v_seqs || v_row.seq;
    END LOOP;

    IF v_seqs <> ARRAY[1, 2, 3] THEN
        RAISE EXCEPTION '40.4: agent_query_trace returned the loop in seq order %, expected {1,2,3}', v_seqs;
    END IF;

    -- And the loop is grouped: three rows, one trace_id, and the phrasing of
    -- step 1 is readable from step 3's row through selected.from_seq.
    IF (SELECT count(*) FROM agent_query_trace WHERE trace_id = 'trace40-order') <> 3 THEN
        RAISE EXCEPTION '40.4: the loop does not group into three rows';
    END IF;
    IF (SELECT query FROM agent_query_trace WHERE trace_id = 'trace40-order' AND seq = 1)
       <> 'first phrasing' THEN
        RAISE EXCEPTION '40.4: step 1 does not carry its own phrasing';
    END IF;

    RAISE NOTICE '40.4 seq orders a loop whose timestamps tie';
END
$$;

-- --------------------------------------------------------------------------
-- 40.5 No read surface writes.
--
-- Two halves. The static half greps pg_proc.prosrc and is signature-agnostic,
-- so it covers find_nodes, find_paths, find_nodes_batch and neighborhood the
-- moment migration 0032 lands, without this file knowing their arguments. The
-- behavioural half counts events across the read surfaces that exist today and
-- can be called here.
--
-- Read surfaces absent from this tree are NOTICEd by name, never skipped in
-- silence: re-run this suite after 0032 merges.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_surface text;
    v_missing text[] := ARRAY[]::text[];
    v_culprit text;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);

    -- Nothing in the rye schema calls log_agent_query except log_agent_query
    -- itself. Tracing is something a caller does, not something a read does.
    SELECT string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
    INTO v_culprit
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'rye'
      AND p.proname <> 'log_agent_query'
      AND p.prosrc LIKE '%log_agent_query%';
    IF v_culprit IS NOT NULL THEN
        RAISE EXCEPTION
            '40.5: these rye functions call log_agent_query, so something auto-logs: %. Tracing is caller-driven.',
            v_culprit;
    END IF;

    -- And the named read surfaces write nothing at all: no event helper, no
    -- INSERT. Checked by body, so it holds for whatever arguments 0032 gives
    -- them.
    FOREACH v_surface IN ARRAY ARRAY[
        'find_nodes', 'find_nodes_batch', 'find_paths', 'neighborhood', 'agent_node_summary'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'rye' AND p.proname = v_surface
        ) THEN
            v_missing := v_missing || v_surface;
            CONTINUE;
        END IF;
        IF EXISTS (
            SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'rye' AND p.proname = v_surface
              AND (p.prosrc ILIKE '%record_event%'
                   OR p.prosrc ILIKE '%log_agent_query%'
                   OR p.prosrc ~* 'insert\s+into')
        ) THEN
            RAISE EXCEPTION
                '40.5: the read surface % writes: its body records an event or inserts a row', v_surface;
        END IF;
    END LOOP;

    IF array_length(v_missing, 1) IS NOT NULL THEN
        RAISE NOTICE
            '40.5: NOT YET COVERED BEHAVIOURALLY -- these read surfaces are absent from this tree: %. They arrive with migration 0032 (work/013); re-run tests/conformance/40_retrieval_tracing.sql after it merges.',
            array_to_string(v_missing, ', ');
    END IF;
END
$$;

DO $$
DECLARE
    v_fenn    uuid;
    v_before  bigint;
    v_after   bigint;
    v_summary jsonb;
    v_rows    bigint;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    SELECT v INTO v_fenn FROM rt_fixture WHERE k = 'fenn';

    SELECT count(*) INTO v_before FROM events;

    -- agent_node_summary: anti-vacuity is that it actually found the node.
    v_summary := agent_node_summary(v_fenn, 10);
    IF v_summary->'node' IS NULL OR jsonb_typeof(v_summary->'node') = 'null' THEN
        RAISE EXCEPTION '40.5: agent_node_summary returned nothing for the fixture node, so it proves nothing';
    END IF;

    -- node_context: same.
    SELECT count(*) INTO v_rows FROM node_context WHERE node_id = v_fenn;
    IF v_rows < 1 THEN
        RAISE EXCEPTION '40.5: node_context returned no row for the fixture node, so it proves nothing';
    END IF;

    -- node_salience and agent_query_trace are reads too.
    PERFORM count(*) FROM node_salience;
    SELECT count(*) INTO v_rows FROM agent_query_trace;
    IF v_rows < 1 THEN
        RAISE EXCEPTION '40.5: agent_query_trace returned no rows, so reading it proves nothing';
    END IF;

    SELECT count(*) INTO v_after FROM events;
    IF v_after <> v_before THEN
        RAISE EXCEPTION '40.5: reading wrote % event(s)', v_after - v_before;
    END IF;

    RAISE NOTICE '40.5 no read surface writes';
END
$$;

-- --------------------------------------------------------------------------
-- 40.6 The write gate covers tracing.
--
-- A refused INSERT raises 42501, so each case asserts the SQLSTATE and that no
-- event carrying that agent id exists afterwards.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_fenn   uuid;
    v_role   text;
    v_traced boolean;
    v_trace  jsonb;
    v_failed boolean;
    v_state  text;
    v_msg    text;
    v_dummy  uuid;
    v_agent  text;
BEGIN
    SELECT v INTO v_fenn FROM rt_fixture WHERE k = 'fenn';

    FOREACH v_role IN ARRAY ARRAY['viewer', ''] LOOP
        FOREACH v_traced IN ARRAY ARRAY[false, true] LOOP
            v_agent := 'trace40-gate-' || coalesce(nullif(v_role, ''), 'unset')
                       || '-' || v_traced::text;
            v_trace := CASE WHEN v_traced
                THEN jsonb_build_object('trace_id', 'trace40-gate', 'seq', 1)
                ELSE NULL END;

            PERFORM set_config('app.current_role', v_role, true);
            IF current_setting('app.current_role', true) IS DISTINCT FROM v_role THEN
                RAISE EXCEPTION '40.6: app.current_role did not read back as "%"', v_role;
            END IF;

            v_failed := false;
            BEGIN
                v_dummy := log_agent_query(v_agent, 'a read', 'a summary', ARRAY[v_fenn], v_trace);
            EXCEPTION WHEN others THEN
                v_failed := true;
                v_state := SQLSTATE;
                v_msg := SQLERRM;
            END;

            IF NOT v_failed THEN
                RAISE EXCEPTION
                    '40.6: role "%" logged a % query; a read-only session must not be able to log',
                    v_role, CASE WHEN v_traced THEN 'traced' ELSE 'an untraced' END;
            END IF;
            IF v_state <> '42501' THEN
                RAISE EXCEPTION
                    '40.6: role "%" was refused with % (%), expected 42501', v_role, v_state, v_msg;
            END IF;

            PERFORM set_config('app.current_role', 'admin', true);
            IF EXISTS (SELECT 1 FROM events WHERE properties->>'agent_id' = v_agent) THEN
                RAISE EXCEPTION '40.6: role "%" left an event behind', v_role;
            END IF;
        END LOOP;
    END LOOP;

    -- An agent-shaped session may write and may trace.
    PERFORM set_config('app.current_role', 'agent:trace40', true);
    v_dummy := log_agent_query('trace40-agent', 'a read', 'a summary', ARRAY[v_fenn]);
    IF v_dummy IS NULL THEN
        RAISE EXCEPTION '40.6: an agent-shaped session could not log an untraced query';
    END IF;
    v_dummy := log_agent_query('trace40-agent', 'a read', 'a summary', ARRAY[v_fenn],
        jsonb_build_object('trace_id', 'trace40-agent-loop', 'seq', 1, 'tool', 'sql'));
    IF v_dummy IS NULL THEN
        RAISE EXCEPTION '40.6: an agent-shaped session could not log a traced query';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM agent_query_trace WHERE trace_id = 'trace40-agent-loop') THEN
        RAISE EXCEPTION '40.6: an agent-shaped session traced but the trace is not readable';
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    RAISE NOTICE '40.6 a viewer and a role-less session cannot log, traced or not';
END
$$;

-- --------------------------------------------------------------------------
-- 40.7 The view is invisible-safe.
--
-- event_read_policy shows an event only when it has a visible participant or
-- the caller is admin, and ep_read_policy filters participants by node
-- visibility. So a traced event whose only participant is a sealed node is
-- absent for a team_member and present for admin: a short trace never means a
-- short loop.
--
-- The step is logged by a session that CAN see the node, because
-- record_event() inserts participants with ON CONFLICT ... DO NOTHING and
-- PostgreSQL applies the SELECT policy to that form: a caller cannot record a
-- participant it cannot read. So the writer carries the sealed team and the
-- readers do not, which is the real shape anyway.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_hidden uuid;
    v_event  uuid;
    v_seen   bigint;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_teams', 'retrieval-tracing-sealed', true);
    SELECT v INTO v_hidden FROM rt_fixture WHERE k = 'hidden';
    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = v_hidden) THEN
        RAISE EXCEPTION '40.7: the writer cannot see the sealed node, so it cannot log against it';
    END IF;

    v_event := log_agent_query(
        'trace40-sealed', 'who keeps the instruments?', 'one sealed person',
        ARRAY[v_hidden],
        jsonb_build_object('trace_id', 'trace40-sealed-loop', 'seq', 1)
    );

    -- Drop the team: from here on, no session below can read the node.
    PERFORM set_config('app.current_teams', '', true);
    IF EXISTS (SELECT 1 FROM nodes WHERE id = v_hidden) THEN
        RAISE EXCEPTION '40.7: the node is still visible without the team, so it is not sealed';
    END IF;

    -- Anti-vacuity: admin sees the row at all.
    SELECT count(*) INTO v_seen FROM agent_query_trace WHERE event_id = v_event;
    IF v_seen <> 1 THEN
        RAISE EXCEPTION '40.7: admin cannot see the traced event, so the case below proves nothing';
    END IF;
    -- And the hidden node really is hidden from a team_member.
    PERFORM set_config('app.current_role', 'team_member', true);
    IF EXISTS (SELECT 1 FROM nodes WHERE id = v_hidden) THEN
        RAISE EXCEPTION '40.7: the sealed node is visible to a team_member, so it is not sealed';
    END IF;

    SELECT count(*) INTO v_seen FROM agent_query_trace WHERE event_id = v_event;
    IF v_seen <> 0 THEN
        RAISE EXCEPTION
            '40.7: a team_member reads a trace step whose only participant it cannot see';
    END IF;
    SELECT count(*) INTO v_seen FROM agent_query_trace WHERE trace_id = 'trace40-sealed-loop';
    IF v_seen <> 0 THEN
        RAISE EXCEPTION '40.7: the sealed loop is readable by trace_id';
    END IF;

    PERFORM set_config('app.current_role', 'admin', true);
    RAISE NOTICE '40.7 agent_query_trace hides a step the caller cannot see';
END
$$;

-- --------------------------------------------------------------------------
-- 40.8 Salience is undisturbed.
--
-- node_salience reads properties->>'agent_id' and the participants, which
-- tracing does not touch. Halvard is used by nothing else in this suite.
-- --------------------------------------------------------------------------
DO $$
DECLARE
    v_halvard uuid;
    v_row     record;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    SELECT v INTO v_halvard FROM rt_fixture WHERE k = 'halvard';

    IF EXISTS (SELECT 1 FROM node_salience WHERE node_id = v_halvard) THEN
        RAISE EXCEPTION '40.8: Halvard already carries salience, so the counts below mean nothing';
    END IF;

    PERFORM log_agent_query('trace40-sal-untraced', 'who is Halvard?', 'one person', ARRAY[v_halvard]);
    SELECT * INTO v_row FROM node_salience WHERE node_id = v_halvard;
    IF NOT FOUND OR v_row.query_count <> 1 OR v_row.distinct_agents <> 1 THEN
        RAISE EXCEPTION '40.8: an untraced query did not count once';
    END IF;

    PERFORM log_agent_query('trace40-sal-traced', 'who is Halvard?', 'one person', ARRAY[v_halvard],
        jsonb_build_object('trace_id', 'trace40-salience', 'seq', 1, 'tool', 'find_nodes'));
    SELECT * INTO v_row FROM node_salience WHERE node_id = v_halvard;
    IF v_row.query_count <> 2 OR v_row.distinct_agents <> 2 OR v_row.salience_score <= 0 THEN
        RAISE EXCEPTION
            '40.8: a traced query counts differently: query_count=% distinct_agents=%',
            v_row.query_count, v_row.distinct_agents;
    END IF;

    RAISE NOTICE '40.8 node_salience counts a traced query exactly as an untraced one';
END
$$;

DO $$
BEGIN
    RAISE NOTICE 'Retrieval tracing: all obligations passed';
END
$$;

ROLLBACK;
