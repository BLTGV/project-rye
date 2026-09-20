-- The last two tables with no row-level security.
--
-- Work item: work/011-loose-ends.md (work/009 Verifier finding, LOW + INFO).
-- Contract:  contracts/sql-surface.md, "Who may write", and AGENTS.md's
--            "RLS is enabled and forced on all core and supporting tables",
--            which these two tables were the exceptions to.
--
-- `crm_code_counters` had no RLS at all, so a `viewer` -- a role that may not
-- write anything else -- could run
--   UPDATE rye.crm_code_counters SET next_val = next_val - 1 WHERE prefix = 'TSK'
-- and the next create_task() collided on idx_nodes_external_unique, or
--   DELETE FROM rye.crm_code_counters WHERE prefix = 'TSK'
-- and the series restarted at 0001. A read-only session could jam every
-- code-issuing helper. `node_merges` had no RLS either: a read-only session
-- could forge a merge record and delete real ones. Nothing reads it in the
-- schema, so the cost there is erased history rather than a wrong answer.
--
-- The mechanism is the one 0026 established, and nothing new: RLS policies for
-- the RLS-bound owner, plus a BEFORE ROW trigger so the same rule binds a
-- superuser owner and any SECURITY DEFINER helper. No new session variable is
-- introduced. app.write_path is deliberately not used here: it is forgeable,
-- and a rule that reads it would hand a read-only session exactly the write
-- this migration takes away.
--
-- The counter: a writing role may move a counter, and only by the step
-- generate_crm_code() takes. The trigger is what makes "through the function"
-- true without naming the function -- there is no signal a helper can produce
-- that a caller cannot (docs/decisions/0008), so the rule is about the row:
-- prefix and year_month never change, next_val only ever moves to
-- next_val + 1, and no row is ever deleted. A caller that forges nothing and
-- calls the function repeatedly can already do that, so a forger gains
-- nothing, and a rewind -- the only move that breaks code uniqueness -- is
-- refused for everyone, admin included.
--
-- generate_crm_code() stays SECURITY INVOKER. Making it DEFINER would put a
-- writer past RLS for a caller who may not write, which is the route
-- design/model/deployment.md refuses; it is also unnecessary, because the
-- caller's own role is allowed to do exactly this one thing.
--
-- What changes for callers: a session with no app.current_role can no longer
-- draw a code. It could before. It also cannot create the task or the
-- opportunity the code would name (0026), so nothing that used to work end to
-- end stops working. tests/concurrency/01_code_generation.sh now sets a role,
-- as tests/concurrency/02_record_distillation.sh already did.

SET search_path = rye, pg_catalog, public;

-- ---------------------------------------------------------------------------
-- 0. May this session write this table at all
-- ---------------------------------------------------------------------------
--
-- rye_role_may_write() answers "does this session write", and it says yes to
-- system:cdc, because 0026 gives that reserved role a row in
-- role_classification_access. What keeps system:cdc to events and
-- event_participants is a second test inside rye_gate_may_write(), which only
-- the seven core tables carry. A session that sets app.current_role to
-- system:cdc by hand would therefore have drawn a code, stepped a counter, and
-- forged a merge record on the two tables below.
--
-- So the table question gets its own answer, in one place. The reserved role
-- name is written once, here, rather than in every policy and trigger that
-- has to honour it.
CREATE OR REPLACE FUNCTION rye_may_write_table(p_table_name text)
RETURNS boolean
SET search_path = rye, pg_catalog
AS $$
    SELECT rye_role_may_write()
       AND (
           current_setting('app.current_role', true) IS DISTINCT FROM 'system:cdc'
           OR p_table_name IN ('events', 'event_participants')
       );
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION rye_may_write_table(text) IS
    'True when app.current_role may write this table: rye_role_may_write(), and system:cdc only for events and event_participants. The contract rule that system:cdc records domain changes and does nothing else, anywhere, in one expression. STABLE, SECURITY INVOKER, session variables only.';

-- ---------------------------------------------------------------------------
-- 1. crm_code_counters
-- ---------------------------------------------------------------------------

ALTER TABLE crm_code_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_code_counters FORCE ROW LEVEL SECURITY;

-- Every role reads it. The counter is not knowledge about the world, it holds
-- no subject, and generate_crm_code() needs the read for its
-- ON CONFLICT ... RETURNING. field_classifications reads the same way and for
-- the same reason.
DROP POLICY IF EXISTS ccc_read_policy ON crm_code_counters;
CREATE POLICY ccc_read_policy ON crm_code_counters
    FOR SELECT
    USING (true);

DROP POLICY IF EXISTS ccc_insert_policy ON crm_code_counters;
CREATE POLICY ccc_insert_policy ON crm_code_counters
    FOR INSERT
    WITH CHECK (rye_may_write_table('crm_code_counters'));

DROP POLICY IF EXISTS ccc_update_policy ON crm_code_counters;
CREATE POLICY ccc_update_policy ON crm_code_counters
    FOR UPDATE
    USING (rye_may_write_table('crm_code_counters'))
    WITH CHECK (rye_may_write_table('crm_code_counters'));

-- A counter is never removed. Removing one restarts the series, which is the
-- same damage as rewinding it.
DROP POLICY IF EXISTS ccc_delete_policy ON crm_code_counters;
CREATE POLICY ccc_delete_policy ON crm_code_counters
    FOR DELETE
    USING (false);

CREATE OR REPLACE FUNCTION rye_crm_code_counter_gate() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'crm_code_counters rows are never deleted: the series would restart and re-issue codes that already name a node.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT rye_may_write_table('crm_code_counters') THEN
        RAISE EXCEPTION
            'A session that may not write crm_code_counters attempted to % it. Set app.current_role to a role the instance allows to write; system:cdc only records domain changes.',
            lower(TG_OP)
            USING ERRCODE = '42501';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF NEW.prefix IS DISTINCT FROM OLD.prefix
           OR NEW.year_month IS DISTINCT FROM OLD.year_month
        THEN
            RAISE EXCEPTION
                'A code counter keeps its prefix and month: % % cannot become % %.',
                OLD.prefix, OLD.year_month, NEW.prefix, NEW.year_month
                USING ERRCODE = '42501';
        END IF;
        IF NEW.next_val IS DISTINCT FROM OLD.next_val + 1 THEN
            RAISE EXCEPTION
                'A code counter moves forward one code at a time: %-% is at %, and % is not the next value. Draw a code with generate_crm_code().',
                OLD.prefix, OLD.year_month, OLD.next_val, NEW.next_val
                USING ERRCODE = '42501';
        END IF;
    -- A new row is held to the shape generate_crm_code() writes on first use,
    -- for the same reason an update is: the function inserts
    -- (prefix, to_char(now(), 'YYMM'), 2) -- it has just drawn code 0001 and
    -- says the next one is 2. Anything else starts a series somewhere of the
    -- caller's choosing, and a series started high re-collides as soon as it
    -- passes the width of the code. The month is the function's own
    -- expression, so a row for a month that has not begun is refused too.
    ELSIF NEW.year_month IS DISTINCT FROM to_char(now(), 'YYMM')
          OR NEW.next_val IS DISTINCT FROM 2
    THEN
        RAISE EXCEPTION
            'A code counter starts where generate_crm_code() starts it: (%, %, 2) for the current month, not (%, %, %). Draw the first code with generate_crm_code().',
            NEW.prefix, to_char(now(), 'YYMM'),
            NEW.prefix, NEW.year_month, NEW.next_val
            USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION rye_crm_code_counter_gate() IS
    'BEFORE ROW trigger on crm_code_counters. No delete, ever. No write at all by a role that may not write. On update, prefix and year_month are immutable and next_val may only become next_val + 1, which is the step generate_crm_code() takes -- so a counter never rewinds and never restarts, for any caller, on either owner type.';

DROP TRIGGER IF EXISTS trg_crm_code_counters_gate ON crm_code_counters;
CREATE TRIGGER trg_crm_code_counters_gate
    BEFORE INSERT OR UPDATE OR DELETE ON crm_code_counters
    FOR EACH ROW EXECUTE FUNCTION rye_crm_code_counter_gate();

-- ---------------------------------------------------------------------------
-- 2. node_merges
-- ---------------------------------------------------------------------------

ALTER TABLE node_merges ENABLE ROW LEVEL SECURITY;
ALTER TABLE node_merges FORCE ROW LEVEL SECURITY;

-- Node visibility is the anchor, as it is for edges: a merge record names two
-- nodes, so a caller that cannot see both is not told the merge happened. An
-- admin reads the whole trail, including merges whose duplicate is archived.
DROP POLICY IF EXISTS nm_read_policy ON node_merges;
CREATE POLICY nm_read_policy ON node_merges
    FOR SELECT
    USING (
        current_setting('app.current_role', true) = 'admin'
        OR (
            EXISTS (SELECT 1 FROM nodes WHERE id = node_merges.duplicate_id)
            AND EXISTS (SELECT 1 FROM nodes WHERE id = node_merges.canonical_id)
        )
    );

-- merge_nodes() is SECURITY INVOKER, so its insert runs as the caller and this
-- is the same role test the merge itself already applies.
DROP POLICY IF EXISTS nm_insert_policy ON node_merges;
CREATE POLICY nm_insert_policy ON node_merges
    FOR INSERT
    WITH CHECK (rye_may_write_table('node_merges'));

DROP POLICY IF EXISTS nm_update_policy ON node_merges;
CREATE POLICY nm_update_policy ON node_merges
    FOR UPDATE
    USING (false);

DROP POLICY IF EXISTS nm_delete_policy ON node_merges;
CREATE POLICY nm_delete_policy ON node_merges
    FOR DELETE
    USING (false);

CREATE OR REPLACE FUNCTION rye_node_merge_gate() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION
            'node_merges is history: a merge record is never changed or removed (attempted %).',
            lower(TG_OP)
            USING ERRCODE = '42501';
    END IF;

    IF NOT rye_may_write_table('node_merges') THEN
        RAISE EXCEPTION
            'A session that may not write node_merges attempted to record a node merge. Set app.current_role to a role the instance allows to write; system:cdc only records domain changes.'
            USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION rye_node_merge_gate() IS
    'BEFORE ROW trigger on node_merges. A merge record is inserted by a role that may write and is never updated or deleted by anyone, admin included: it is the dedup audit trail. Fires for a superuser owner and inside a SECURITY DEFINER helper, where the policies do not.';

DROP TRIGGER IF EXISTS trg_node_merges_gate ON node_merges;
CREATE TRIGGER trg_node_merges_gate
    BEFORE INSERT OR UPDATE OR DELETE ON node_merges
    FOR EACH ROW EXECUTE FUNCTION rye_node_merge_gate();

-- ---------------------------------------------------------------------------
-- 3. The code itself: a sequence past 9999 widens, it does not truncate
-- ---------------------------------------------------------------------------
--
-- lpad(v_seq::text, 4, '0') pads a short number and TRUNCATES a long one, so
-- the 10000th code of a month was 'TSK-2511-1000' -- a code the 1000th task
-- already has, and idx_nodes_external_unique refuses the second one. It is a
-- latent defect independent of who writes the counter: a busy month reaches it
-- through generate_crm_code() alone. The format {PREFIX}-{YYMM}-{SEQ} is
-- unchanged for every sequence that fits in four digits, which is every code
-- any instance has issued, and past that the sequence widens: 10000, 10001.
-- Codes stay unique, and they stay lexically ordered within a run of the same
-- width, which is what the four-digit padding was for.
--
-- Carried forward from 0002 unchanged except that one expression.
CREATE OR REPLACE FUNCTION generate_crm_code(p_prefix text) RETURNS text
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_yymm text;
    v_seq int;
BEGIN
    v_yymm := to_char(now(), 'YYMM');

    INSERT INTO crm_code_counters (prefix, year_month, next_val)
    VALUES (p_prefix, v_yymm, 2)
    ON CONFLICT (prefix, year_month)
    DO UPDATE SET next_val = crm_code_counters.next_val + 1
    RETURNING next_val - 1 INTO v_seq;

    RETURN p_prefix || '-' || v_yymm || '-' ||
           CASE WHEN length(v_seq::text) < 4
                THEN lpad(v_seq::text, 4, '0')
                ELSE v_seq::text
           END;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION generate_crm_code(text) IS
    'Next human-readable code for a prefix in the current month, {PREFIX}-{YYMM}-{SEQ}. The sequence is zero-padded to four digits and widens past 9999 rather than truncating. SECURITY INVOKER: the counter moves as the caller, under the rules on crm_code_counters.';

COMMENT ON TABLE crm_code_counters IS
    'Per prefix and month counter behind generate_crm_code(). RLS enabled and forced: readable by every role, movable only forward by one, only by a role that may write, and never deleted.';

COMMENT ON TABLE node_merges IS
    'Dedup audit trail written by merge_nodes(). RLS enabled and forced: readable by an admin or by a caller who can see both nodes, insertable by a role that may write, never updated and never deleted.';
