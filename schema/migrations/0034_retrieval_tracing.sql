-- Retrieval tracing: a step on the event.
--
-- Work item: work/015-retrieval-eval-and-tracing.md (closes the production
--            half of issue 21).
-- Contract:  contracts/sql-surface.md, "Retrieval tracing".
-- Decision:  docs/decisions/0011-retrieval-tracing-is-a-step-on-the-event.md.
-- Tests:     tests/conformance/40_retrieval_tracing.sql.
--
-- An agent's retrieval is a loop -- reformulate, narrow by type, judge
-- candidates -- so one question produces N `agent_query` events and nothing
-- joins them. The final answer looks the same whether the agent never
-- generated a matching phrasing, generated one the trigram threshold rejected,
-- reached the node and misjudged it, or the knowledge is absent. Those four
-- have four different fixes and only the grouped steps separate them.
--
-- WHAT THIS MIGRATION CHANGES. Exactly two objects:
--
--   1. log_agent_query(text, text, text, uuid[]) is DROPped and recreated with
--      a fifth parameter, p_trace jsonb DEFAULT NULL -- the same shape 0018
--      used for record_assertion() and 0019 for accept_assertion(). A
--      four-argument overload is deliberately NOT created beside it: both
--      would match a four-argument call and PostgreSQL would raise
--      "function ... is not unique" at call time, which is a breakage rather
--      than a compatibility measure. Every existing four-argument call site
--      (skills/rye-agent-ops, tests/scenarios/05, tests/conformance/26)
--      resolves and behaves exactly as before and writes no trace key.
--
--   2. agent_query_trace, a new security_invoker view, groups the traced
--      events of one loop and orders them by seq.
--
-- It touches no object 0031, 0032, 0033, 0035, or 0036 touches.
--
-- NO NEW TABLE AND NO NEW EVENT TYPE. Issue 21 rules both out. The trace rides
-- in the event's properties under one reserved key, `properties.trace`, whose
-- field names are the ones eval/retrieval/trace_format.md already uses, so one
-- analysis reads a harness trace and a production trace alike:
--
--   properties.trace = {
--     "trace_id": "<non-empty text, the caller's id for one loop>",
--     "seq":      <integer >= 1, unique within the trace>,
--     "tool":     "find_nodes" | "find_paths" | "neighborhood" | "sql" | ...,
--     "intent":   "<why this phrasing was tried>",
--     "args":     { ... as passed ... },
--     "results":  [ {node_id, score, match_reason, used} ... ],
--     "selected": {node_id, from_seq, from_phrasing}
--   }
--
-- properties.query still holds the phrasing, so `selected` needs to carry only
-- from_seq to name which phrasing produced the candidate that was used.
-- Everything except trace_id and seq is optional.
--
-- WHAT IS VALIDATED, AND WHY ONLY THAT. A non-null p_trace must be a jsonb
-- object with a non-empty trace_id and an integer seq of at least 1, or the
-- call raises. A trace that cannot be grouped or ordered is worse than no
-- trace, because it looks like data. Nothing else is validated: tool, intent,
-- args, results, and selected are the caller's vocabulary and a schema here
-- would freeze it. `unique within the trace` stays a convention -- the steps of
-- one loop can span transactions, so the database cannot cheaply hold it, and
-- a duplicate seq degrades the order rather than corrupting the group.
--
-- ORDERING IS BY seq, NOT BY TIME. record_event() defaults p_occurred_at to
-- now(), which is transaction start, so every call in one loop inside one
-- transaction lands on the identical timestamp. seq is therefore required
-- rather than optional and is the first sort key after trace_id; occurred_at
-- and event_id break ties only so the order is total.
--
-- OPT-IN AND CALLER-DRIVEN. Nothing auto-logs. No read surface calls
-- log_agent_query(), and none ever will: a read must not write (issue 19).
-- The caller emits its own step, because `intent` -- the field that classifies
-- a miss -- exists nowhere in the executed SQL, and a statement log records
-- faithfully what ran and cannot record why.
--
-- THE WRITE GATE IS UNCHANGED AND STILL GOVERNS. log_agent_query() stays
-- SECURITY INVOKER and reaches record_event(), so trg_events_gate_may_write
-- (0026) refuses a viewer, an unset role, and any role whose
-- role_classification_access.may_write is false with 42501 -- traced or not.
-- A read-only agent therefore cannot trace, which is exactly why the eval
-- harness must not depend on production tracing. A SECURITY DEFINER
-- log_agent_query() was rejected: it would hand a viewer a write, and on a
-- non-superuser owner it would not even work.
--
-- RETENTION IS THE CALLER'S. Events are immutable and Rye deletes none, so a
-- trace written is a trace kept. There is no pruning path today and adding one
-- is a new migration and an edit to contracts/sql-surface.md first, as with
-- agent_action_log. The lever that exists is that tracing is per call: trace
-- the loops you will read, not every read. Callers are expected to cap
-- `results` -- ten per step is plenty -- because an unbounded candidate list in
-- an immutable event is a storage decision nobody asked for.
--
-- node_salience is untouched: it reads properties->>'agent_id' and the
-- participants, which tracing does not touch. It improves as a side effect,
-- since more traced reads mean more cooperative attention signal.
--
-- DROPPING A FUNCTION DROPS ITS GRANTS AND ANY DEPENDENT OBJECT. So this file
-- captures proacl first, refuses to proceed if anything depends on the
-- function (rather than silently CASCADEing it away), and re-issues the grants
-- after the CREATE. On a fresh install proacl is null and the default applies;
-- on a database where scripts/conformance.sh has already granted EXECUTE to
-- rye_conformance, that grant is restored.

SET search_path = rye, pg_catalog, public;

-- --------------------------------------------------------------------------
-- Capture the grants that the DROP is about to destroy.
-- --------------------------------------------------------------------------
-- to_regprocedure matches on argument types alone. pg_get_function_identity_arguments
-- renders the parameter NAMES too, so it is not a signature and does not match here.
CREATE TEMP TABLE rye_0034_saved_grants AS
SELECT
    a.privilege_type,
    CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END AS grantee,
    a.is_grantable
FROM pg_proc p
CROSS JOIN LATERAL aclexplode(p.proacl) a
LEFT JOIN pg_roles r ON r.oid = a.grantee
WHERE p.oid = to_regprocedure('rye.log_agent_query(text, text, text, uuid[])');

-- --------------------------------------------------------------------------
-- Refuse to drop a function something else depends on.
-- --------------------------------------------------------------------------
DO $check$
DECLARE
    v_oid  oid;
    v_deps text;
BEGIN
    v_oid := to_regprocedure('rye.log_agent_query(text, text, text, uuid[])');

    IF v_oid IS NULL THEN
        RAISE EXCEPTION
            'rye.log_agent_query(text, text, text, uuid[]) is not installed; 0002 must be applied before 0034';
    END IF;

    SELECT string_agg(DISTINCT pg_describe_object(d.classid, d.objid, d.objsubid), ', ')
    INTO v_deps
    FROM pg_depend d
    WHERE d.refobjid = v_oid
      AND d.refclassid = 'pg_proc'::regclass
      AND d.deptype <> 'i'
      AND d.classid <> 'pg_proc'::regclass;

    IF v_deps IS NOT NULL THEN
        RAISE EXCEPTION
            'Refusing to drop rye.log_agent_query: these objects depend on it and DROP would take them with it: %',
            v_deps;
    END IF;
END
$check$;

-- --------------------------------------------------------------------------
-- The widened function. Security setting (INVOKER), search_path, language,
-- volatility, and body are 0002's, with one parameter and one branch added.
-- --------------------------------------------------------------------------
DROP FUNCTION rye.log_agent_query(text, text, text, uuid[]);

CREATE FUNCTION log_agent_query(
    p_agent_id text,
    p_query_text text,
    p_result_summary text,
    p_nodes_referenced uuid[],
    p_trace jsonb DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_roles      text[];
    v_properties jsonb;
    v_seq        numeric;
BEGIN
    v_properties := jsonb_build_object('query', p_query_text, 'agent_id', p_agent_id);

    IF p_trace IS NOT NULL AND jsonb_typeof(p_trace) <> 'null' THEN
        IF jsonb_typeof(p_trace) <> 'object' THEN
            RAISE EXCEPTION
                'p_trace must be a jsonb object, not a %. A retrieval trace is one step: {"trace_id": "...", "seq": 1, ...}.',
                jsonb_typeof(p_trace);
        END IF;

        -- Null-safe on purpose: a missing key makes p_trace->'trace_id' SQL
        -- NULL, and `NULL <> 'string'` is NULL, which does not fire an IF. A
        -- trace with no trace_id at all would sail through the obvious
        -- spelling.
        IF coalesce(jsonb_typeof(p_trace->'trace_id'), 'missing') <> 'string'
           OR coalesce(btrim(p_trace->>'trace_id'), '') = '' THEN
            RAISE EXCEPTION
                'p_trace needs a non-empty text trace_id naming the loop this step belongs to; got %.',
                coalesce((p_trace->'trace_id')::text, 'nothing');
        END IF;

        IF coalesce(jsonb_typeof(p_trace->'seq'), 'missing') <> 'number' THEN
            RAISE EXCEPTION
                'p_trace needs an integer seq of at least 1 ordering this step within the loop; got %. Timestamps tie inside one transaction, so seq is what orders a trace.',
                coalesce((p_trace->'seq')::text, 'nothing');
        END IF;

        v_seq := (p_trace->>'seq')::numeric;
        IF v_seq < 1 OR v_seq <> trunc(v_seq) THEN
            RAISE EXCEPTION
                'p_trace seq must be a whole number of at least 1; got %.',
                p_trace->>'seq';
        END IF;
        -- agent_query_trace reads seq as an integer, and an event is
        -- immutable. A caller that reaches for an epoch in milliseconds or a
        -- snowflake id would otherwise write one row that no reader could
        -- ever get past.
        IF v_seq > 2147483647 THEN
            RAISE EXCEPTION
                'p_trace seq must be at most 2147483647; got %. seq numbers a step within one loop -- 1, 2, 3 -- it is not a timestamp and not an id.',
                p_trace->>'seq';
        END IF;

        v_properties := v_properties || jsonb_build_object('trace', p_trace);
    END IF;

    v_roles := array_fill('queried'::text, ARRAY[coalesce(array_length(p_nodes_referenced, 1), 0)]);

    RETURN record_event(
        p_event_type        := 'agent_query',
        p_summary           := p_result_summary,
        p_properties        := v_properties,
        p_participant_ids   := p_nodes_referenced,
        p_participant_roles := v_roles,
        p_actor             := 'agent:' || p_agent_id
    );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION log_agent_query(text, text, text, uuid[], jsonb) IS
    'Record an agent_query event. Called by the client, never by a read. p_trace is optional; when given it must be a jsonb object with a non-empty trace_id and an integer seq of at least 1, and it lands whole at properties.trace for agent_query_trace to group. A four-argument call behaves exactly as it did before 0034 and writes no trace key. The write gate governs: a viewer or a role-less session is refused 42501, traced or not.';

-- --------------------------------------------------------------------------
-- Restore the grants the DROP destroyed.
-- --------------------------------------------------------------------------
DO $regrant$
DECLARE
    v_row record;
BEGIN
    FOR v_row IN SELECT * FROM rye_0034_saved_grants LOOP
        EXECUTE format(
            'GRANT %s ON FUNCTION rye.log_agent_query(text, text, text, uuid[], jsonb) TO %s%s',
            v_row.privilege_type,
            v_row.grantee,
            CASE WHEN v_row.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END
        );
    END LOOP;
END
$regrant$;

DROP TABLE rye_0034_saved_grants;

-- --------------------------------------------------------------------------
-- Reading a loop back: one row per traced step, ordered by seq.
--
-- security_invoker, so RLS applies as everywhere. event_read_policy (0003)
-- shows an event only when it has a visible participant or the caller is
-- admin, and event_participants filters by node visibility, so an event whose
-- participants this caller cannot see is absent from the view. A short trace
-- therefore never means a short loop.
--
-- EVERY FIELD IS READ DEFENSIVELY, AND THIS IS THE LOAD-BEARING PART. The
-- helper validates, but `events.properties` is a jsonb column and any session
-- that may write can call record_event() with a hand-built properties.trace.
-- An event is immutable and Rye deletes none, so a single bad row that made
-- this view raise would make the feature's only read surface unreadable for
-- every role, for good -- an out-of-range seq did exactly that before this
-- guard, with `integer out of range` for admin too. So no stored value of any
-- shape may produce an error here: a huge number, a negative, a fraction, a
-- numeric string, `1e400`, an object where text was expected. Each degrades to
-- a null column, and a null trace_id or seq sorts last, where it is visible as
-- the garbage it is.
--
-- Mechanically: the extraction happens once in a LATERAL, guarded by
-- jsonb_typeof, and only the THEN branch of a CASE ever casts. AND does not
-- short-circuit in SQL -- the planner may evaluate operands in any order -- so
-- a cast may never sit in the same AND chain as the test that makes it safe.
--
-- `->>` itself cannot raise, so agent_id and query stay as node_salience reads
-- them. The trace's own fields are typed by the contract, so a value of the
-- wrong json type reads as null rather than as its JSON text.
--
-- security_invoker, so RLS applies as everywhere. event_read_policy (0003)
-- shows an event only when it has a visible participant or the caller is
-- admin, and event_participants filters by node visibility, so an event whose
-- participants this caller cannot see is absent from the view. A short trace
-- therefore never means a short loop.
-- --------------------------------------------------------------------------
CREATE OR REPLACE VIEW agent_query_trace
WITH (security_invoker = true) AS
SELECT
    g.trace_id,
    CASE
        WHEN g.seq_num >= 1
         AND g.seq_num <= 2147483647
         AND g.seq_num = trunc(g.seq_num)
        THEN g.seq_num::integer
    END AS seq,
    e.id AS event_id,
    e.occurred_at,
    e.properties->>'agent_id' AS agent_id,
    e.properties->>'query' AS query,
    e.summary,
    g.tool,
    g.intent,
    g.args,
    g.results,
    g.selected,
    ARRAY(
        SELECT ep.node_id
        FROM event_participants ep
        WHERE ep.event_id = e.id
        ORDER BY ep.node_id
    ) AS node_ids
FROM events e
CROSS JOIN LATERAL (SELECT e.properties->'trace' AS t) tr
CROSS JOIN LATERAL (
    SELECT
        CASE WHEN jsonb_typeof(tr.t->'trace_id') = 'string'
             THEN tr.t->>'trace_id' END                              AS trace_id,
        CASE WHEN jsonb_typeof(tr.t->'seq') = 'number'
             THEN (tr.t->>'seq')::numeric END                        AS seq_num,
        CASE WHEN jsonb_typeof(tr.t->'tool') = 'string'
             THEN tr.t->>'tool' END                                  AS tool,
        CASE WHEN jsonb_typeof(tr.t->'intent') = 'string'
             THEN tr.t->>'intent' END                                AS intent,
        CASE WHEN jsonb_typeof(tr.t->'args') = 'object'
             THEN tr.t->'args' END                                   AS args,
        CASE WHEN jsonb_typeof(tr.t->'results') = 'array'
             THEN tr.t->'results' END                                AS results,
        CASE WHEN jsonb_typeof(tr.t->'selected') = 'object'
             THEN tr.t->'selected' END                               AS selected
) g
WHERE e.event_type = 'agent_query'
  AND jsonb_typeof(e.properties->'trace') = 'object'
ORDER BY 1, 2, 4, 3;

COMMENT ON VIEW agent_query_trace IS
    'One row per agent_query event carrying properties.trace: the steps of an agent retrieval loop, grouped by trace_id and ordered by seq, then occurred_at and event_id. security_invoker, so an event whose participants the caller cannot see is absent and a short trace never means a short loop. Ordering is by seq and not by time because record_event() stamps occurred_at with transaction start, so every step of one loop in one transaction shares it. Every trace field is type-guarded and seq is range-guarded: a hand-built trace written straight through record_event() degrades to null columns and never makes this view raise, because an event is immutable and one such row would otherwise close the read surface for every role.';
