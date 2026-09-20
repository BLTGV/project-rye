-- Who may write.
--
-- Contract:  contracts/sql-surface.md, "Who may write".
-- Decision:  docs/decisions/0009-who-may-write.md.
-- Work item: work/009-who-may-write.md.
--
-- Rye never said what each role may write. A `viewer`, and a session with no
-- role set at all, could insert assertions, archive an onboarding_scope node,
-- archive or delete the edge that says which scope governs a subject, and merge
-- nodes. Any of those turns a strict area into an open one for helpers and raw
-- writes alike. This migration says who may write, in four parts:
--
--   A. the role list is the write list (`may_write` + `rye_role_may_write()`),
--      enforced by `rye_gate_may_write()` -- one BEFORE ROW trigger on each of
--      the seven core tables -- with the same test as a conjunct on every
--      INSERT/UPDATE/DELETE policy as the second line;
--   B. the governance structure is configuration, so it is admin-only — the
--      test is row-local, on the row's own `node_type` or `edge_type`, so it
--      reads no table and cannot recurse;
--   C. `merge_nodes()` and `update_node_properties()` refuse before they lock,
--      because SELECT ... FOR UPDATE applies the UPDATE policy as a silent
--      filter and would otherwise report a visible row as missing;
--   D. `capture_domain_change()` records under the reserved `system:cdc` role,
--      so a tracked domain table still produces its CDC event when the
--      application's session sets no Rye role -- the normal overlay case.
--
-- Why a trigger and not a policy alone: the first cut of this migration was a
-- policy conjunct only, and on the Docker install, whose table owner is a
-- superuser, a `viewer` still accepted a candidate through accept_assertion(),
-- closed one through reject_candidate(), and rewrote attrs through
-- mark_assertion_outcome(). All three are SECURITY DEFINER owned by that
-- superuser, so RLS never ran and the conjunct never ran with it. A trigger
-- fires for a superuser, inside a SECURITY DEFINER function, and on a raw write
-- alike, and it needs no list of helpers to keep up to date.
--
-- What this protects and what it does not: session variables are Rye's only
-- authorization. Every rule here reads the role in order to permit, because a
-- role model is what it is. It protects deployments where a trusted backend
-- sets the session variables, and agents that state their role honestly. It is
-- not a defence against a hostile caller with a raw connection.

SET search_path = rye, pg_catalog, public;

-- scripts/migrate.sh runs each migration in its own psql session, so this file
-- sets its own role before any DML. The policies below are live the moment
-- they are created, including for the statements further down this file.
SELECT set_config('app.current_role', 'admin', false);

-- ============================================================================
-- A. THE ROLE LIST IS THE WRITE LIST
-- ============================================================================
-- role_classification_access is already the instance's role vocabulary, it is
-- already readable by every session for redact_properties(), and it is level 0
-- in the policy read order, so a helper that reads it is safe to call from a
-- policy on any table. A new read-only role is an INSERT, and widening a role
-- later is an UPDATE. Neither is a migration.

ALTER TABLE role_classification_access
    ADD COLUMN IF NOT EXISTS may_write boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN role_classification_access.may_write IS
    'Whether a session whose app.current_role is this role_name may write the core tables. Seeded true for every role except viewer. An agent-shaped role is a writer without a row here; see rye_role_may_write().';

-- The table had an INSERT policy and no UPDATE policy, so "widening a role
-- later is an UPDATE" was not true of it, and on an owner RLS binds not even
-- this migration could seed the viewer row. It is true now, for an admin only.
DROP POLICY IF EXISTS rca_update_policy ON role_classification_access;
CREATE POLICY rca_update_policy ON role_classification_access
    FOR UPDATE
    USING (current_setting('app.current_role', true) = 'admin')
    WITH CHECK (current_setting('app.current_role', true) = 'admin');

-- The seeded read-only role. `viewer` has always meant this; now it is a row.
UPDATE role_classification_access
   SET may_write = false
 WHERE role_name = 'viewer';

-- The whole definition of a writing session. Reads app.current_role and
-- role_classification_access, and nothing else.
--
-- Agent-shaped is decided from the session variable alone, without reading
-- agent_identities, because a policy on `nodes` may not depend on a table whose
-- own policy depends on `nodes`. A session can therefore call itself `agent:`
-- anything and write what an agent may write; that is unchanged from every
-- other agent test in the schema and is not what this migration closes.
CREATE OR REPLACE FUNCTION rye_role_may_write()
RETURNS boolean
SET search_path = rye, pg_catalog
AS $$
    SELECT rye_current_agent_key() IS NOT NULL
        OR EXISTS (
            SELECT 1
            FROM role_classification_access rca
            WHERE rca.role_name = current_setting('app.current_role', true)
              AND rca.may_write
        );
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION rye_role_may_write() IS
    'True when app.current_role is agent-shaped, or names a role_classification_access row whose may_write is true. False for viewer, for an unknown role name, and for an unset role. STABLE, SECURITY INVOKER, reads only app.current_role and role_classification_access (level 0), so it is safe in a policy on any table.';

-- The reserved role capture_domain_change() swaps in around its record_event()
-- call, and nothing else uses. It is an ordinary row in the role list rather
-- than a forgeable named gate, which is why it is acceptable here and why
-- app.write_path was not: the most a caller who sets it by hand can do is
-- insert an event and a participant, which is strictly less than they could do
-- by setting team_member. `public` is the narrowest classification set there
-- is, and all it needs -- record_event() generates the event id before
-- inserting, so it never reads events back, ep_insert_policy admits a
-- participant without reading the node, and nothing on the path redacts.
INSERT INTO role_classification_access (role_name, classifications, may_write)
VALUES ('system:cdc', ARRAY['public'], true)
ON CONFLICT (role_name) DO NOTHING;

-- ---------------------------------------------------------------------------
-- The gate itself. BEFORE ROW on each of the seven core tables, so it runs
-- where RLS does not: for a superuser, and inside a SECURITY DEFINER function
-- owned by one.
--
-- Row-level and not statement-level: a BEFORE STATEMENT trigger fires before
-- every BEFORE ROW trigger whatever it is named, which would take
-- trg_assertion_settle_gate's message away from
-- tests/conformance/30_configuration_gate.sql, where it is load-bearing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rye_gate_may_write() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
BEGIN
    IF NOT rye_role_may_write() THEN
        RAISE EXCEPTION
            'A session that may not write attempted to % %. Set app.current_role to a role the instance allows to write.',
            lower(TG_OP), TG_TABLE_NAME
            USING ERRCODE = '42501';
    END IF;

    -- system:cdc is Rye recording a domain change, not a writing role.
    IF current_setting('app.current_role', true) = 'system:cdc'
       AND NOT (TG_OP = 'INSERT'
                AND TG_TABLE_NAME IN ('events', 'event_participants'))
    THEN
        RAISE EXCEPTION
            'system:cdc may only insert events and event participants; it attempted to % %.',
            lower(TG_OP), TG_TABLE_NAME
            USING ERRCODE = '42501';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION rye_gate_may_write() IS
    'BEFORE ROW trigger on the seven core tables. Raises 42501 when rye_role_may_write() is false, and when app.current_role is system:cdc and the write is not an INSERT into events or event_participants. Fires for a superuser and inside a SECURITY DEFINER function, which is where the RLS conjunct does not.';

DROP TRIGGER IF EXISTS trg_nodes_gate_may_write ON nodes;
CREATE TRIGGER trg_nodes_gate_may_write
    BEFORE INSERT OR UPDATE OR DELETE ON nodes
    FOR EACH ROW EXECUTE FUNCTION rye_gate_may_write();

DROP TRIGGER IF EXISTS trg_edges_gate_may_write ON edges;
CREATE TRIGGER trg_edges_gate_may_write
    BEFORE INSERT OR UPDATE OR DELETE ON edges
    FOR EACH ROW EXECUTE FUNCTION rye_gate_may_write();

DROP TRIGGER IF EXISTS trg_events_gate_may_write ON events;
CREATE TRIGGER trg_events_gate_may_write
    BEFORE INSERT OR UPDATE OR DELETE ON events
    FOR EACH ROW EXECUTE FUNCTION rye_gate_may_write();

DROP TRIGGER IF EXISTS trg_event_participants_gate_may_write ON event_participants;
CREATE TRIGGER trg_event_participants_gate_may_write
    BEFORE INSERT OR UPDATE OR DELETE ON event_participants
    FOR EACH ROW EXECUTE FUNCTION rye_gate_may_write();

-- The name on assertions is a decision, not a convention: triggers fire in
-- name order, and this one must fall after trg_assertion_settle_gate -- whose
-- '%is Rye configuration%' message test 30 asserts -- and before
-- trg_assertions_immutable and trg_assertions_insert_review, so the shape
-- guards still run after the role is settled. Verified under C and en_US.UTF-8.
DROP TRIGGER IF EXISTS trg_assertions_gate_may_write ON assertions;
CREATE TRIGGER trg_assertions_gate_may_write
    BEFORE INSERT OR UPDATE OR DELETE ON assertions
    FOR EACH ROW EXECUTE FUNCTION rye_gate_may_write();

DROP TRIGGER IF EXISTS trg_assertion_evidence_gate_may_write ON assertion_evidence;
CREATE TRIGGER trg_assertion_evidence_gate_may_write
    BEFORE INSERT OR UPDATE OR DELETE ON assertion_evidence
    FOR EACH ROW EXECUTE FUNCTION rye_gate_may_write();

DROP TRIGGER IF EXISTS trg_artifacts_gate_may_write ON artifacts;
CREATE TRIGGER trg_artifacts_gate_may_write
    BEFORE INSERT OR UPDATE OR DELETE ON artifacts
    FOR EACH ROW EXECUTE FUNCTION rye_gate_may_write();

-- ============================================================================
-- B. THE GOVERNANCE STRUCTURE IS ADMIN-ONLY
-- ============================================================================
-- governing_scope() and scope_review_policy() decide which review policy covers
-- a subject. A caller who can end what they read can turn a strict area into an
-- open one. The rows they read are an onboarding_scope node and edges of type
-- scope_governs_subject and scope_governs_source; scope_enables_plugin joins
-- them because compile_scope_policy() and the scoped registry reads use it to
-- decide which vocabulary a scope permits.
--
-- RLS applies USING to the old row and WITH CHECK to the new one, so one rule
-- covers archiving, ending, deleting, and re-pointing in both directions: a
-- non-admin can neither promote an ordinary edge into a governance edge nor
-- demote a governance edge into an ordinary one.
--
-- has_step is deliberately not in the set. Every process step in the PM profile
-- has one, so gating it would gate ordinary work to protect an inherited scope.
-- Archiving a has_step edge therefore still drops a step's inherited
-- governance; a subject that must stay governed gets its own
-- scope_governs_subject edge, which is admin-only.

-- ---------------------------------------------------------------------------
-- nodes
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS node_insert_policy ON nodes;
CREATE POLICY node_insert_policy ON nodes
    FOR INSERT
    WITH CHECK (
        rye_role_may_write()
        AND (
            nodes.node_type <> 'onboarding_scope'
            OR current_setting('app.current_role', true) = 'admin'
        )
    );

-- Non-agent roles that may write: unrestricted, except governance rows.
-- Agent roles: only through the update_node_properties() write path, and never
-- a governance row.
DROP POLICY IF EXISTS node_update_policy ON nodes;
CREATE POLICY node_update_policy ON nodes
    FOR UPDATE
    USING (
        (
            coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
            OR current_setting('app.write_path', true) = 'update_node_properties'
        )
        AND rye_role_may_write()
        AND (
            nodes.node_type <> 'onboarding_scope'
            OR current_setting('app.current_role', true) = 'admin'
        )
    )
    WITH CHECK (
        (
            coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
            OR current_setting('app.write_path', true) = 'update_node_properties'
        )
        AND rye_role_may_write()
        AND (
            nodes.node_type <> 'onboarding_scope'
            OR current_setting('app.current_role', true) = 'admin'
        )
    );

DROP POLICY IF EXISTS node_delete_policy ON nodes;
CREATE POLICY node_delete_policy ON nodes
    FOR DELETE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
        AND rye_role_may_write()
        AND (
            nodes.node_type <> 'onboarding_scope'
            OR current_setting('app.current_role', true) = 'admin'
        )
    );

-- ---------------------------------------------------------------------------
-- edges
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS edge_insert_policy ON edges;
CREATE POLICY edge_insert_policy ON edges
    FOR INSERT
    WITH CHECK (
        rye_role_may_write()
        AND (
            edges.edge_type NOT IN (
                'scope_governs_subject', 'scope_governs_source', 'scope_enables_plugin'
            )
            OR current_setting('app.current_role', true) = 'admin'
        )
    );

DROP POLICY IF EXISTS edge_update_policy ON edges;
CREATE POLICY edge_update_policy ON edges
    FOR UPDATE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
        AND rye_role_may_write()
        AND (
            edges.edge_type NOT IN (
                'scope_governs_subject', 'scope_governs_source', 'scope_enables_plugin'
            )
            OR current_setting('app.current_role', true) = 'admin'
        )
    )
    WITH CHECK (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
        AND rye_role_may_write()
        AND (
            edges.edge_type NOT IN (
                'scope_governs_subject', 'scope_governs_source', 'scope_enables_plugin'
            )
            OR current_setting('app.current_role', true) = 'admin'
        )
    );

DROP POLICY IF EXISTS edge_delete_policy ON edges;
CREATE POLICY edge_delete_policy ON edges
    FOR DELETE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
        AND rye_role_may_write()
        AND (
            edges.edge_type NOT IN (
                'scope_governs_subject', 'scope_governs_source', 'scope_enables_plugin'
            )
            OR current_setting('app.current_role', true) = 'admin'
        )
    );

-- ---------------------------------------------------------------------------
-- events. Immutable: nobody updates or deletes one, admin included. The
-- conjunct is written into those two policies anyway so the rule is uniform
-- and greppable; `false` already decides them.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS event_insert_policy ON events;
CREATE POLICY event_insert_policy ON events
    FOR INSERT
    WITH CHECK (rye_role_may_write());

DROP POLICY IF EXISTS event_update_policy ON events;
CREATE POLICY event_update_policy ON events
    FOR UPDATE
    USING (false AND rye_role_may_write())
    WITH CHECK (false AND rye_role_may_write());

DROP POLICY IF EXISTS event_delete_policy ON events;
CREATE POLICY event_delete_policy ON events
    FOR DELETE
    USING (false AND rye_role_may_write());

-- ---------------------------------------------------------------------------
-- event_participants
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS ep_insert_policy ON event_participants;
CREATE POLICY ep_insert_policy ON event_participants
    FOR INSERT
    WITH CHECK (rye_role_may_write());

DROP POLICY IF EXISTS ep_update_policy ON event_participants;
CREATE POLICY ep_update_policy ON event_participants
    FOR UPDATE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
        AND rye_role_may_write()
    )
    WITH CHECK (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
        AND rye_role_may_write()
    );

DROP POLICY IF EXISTS ep_delete_policy ON event_participants;
CREATE POLICY ep_delete_policy ON event_participants
    FOR DELETE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
        AND rye_role_may_write()
    );

-- ---------------------------------------------------------------------------
-- assertions. The type gate from 0006 and the write-path gate from 0019 are
-- preserved exactly; the role conjunct is added beside them. The row rules in
-- 0023 and 0025 still sit on top as triggers, and a `no` from either is still
-- a `no` — an admin is not exempt from them.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS assertion_insert_policy ON assertions;
CREATE POLICY assertion_insert_policy ON assertions
    FOR INSERT
    WITH CHECK (
        rye_role_may_write()
        AND (
            NOT EXISTS (
                SELECT 1 FROM assertion_type_access ata
                WHERE ata.assertion_type = assertions.assertion_type
                  AND ata.operation = 'write'
            )
            OR EXISTS (
                SELECT 1 FROM assertion_type_access ata
                WHERE ata.assertion_type = assertions.assertion_type
                  AND ata.operation = 'write'
                  AND current_setting('app.current_role', true) = ANY(ata.allowed_roles)
            )
        )
    );

DROP POLICY IF EXISTS assertion_update_policy ON assertions;
CREATE POLICY assertion_update_policy ON assertions
    FOR UPDATE
    USING (
        rye_role_may_write()
        AND (
            (current_setting('app.write_path', true) = 'supersede_assertion'
             AND id::text = current_setting('app.supersede_assertion_id', true))
            OR (current_setting('app.write_path', true) = 'assertion_effective_window'
                AND id::text = current_setting('app.effective_window_assertion_id', true))
            OR (current_setting('app.write_path', true) = 'accept_assertion'
                AND id::text = current_setting('app.accept_assertion_id', true))
            OR (current_setting('app.write_path', true) = 'assertion_classification'
                AND id::text = current_setting('app.classification_assertion_id', true))
            OR (current_setting('app.write_path', true) = 'assertion_outcome'
                AND id::text = current_setting('app.outcome_assertion_id', true))
        )
    )
    WITH CHECK (
        rye_role_may_write()
        AND (
            (current_setting('app.write_path', true) = 'supersede_assertion'
             AND id::text = current_setting('app.supersede_assertion_id', true))
            OR (current_setting('app.write_path', true) = 'assertion_effective_window'
                AND id::text = current_setting('app.effective_window_assertion_id', true))
            OR (current_setting('app.write_path', true) = 'accept_assertion'
                AND id::text = current_setting('app.accept_assertion_id', true))
            OR (current_setting('app.write_path', true) = 'assertion_classification'
                AND id::text = current_setting('app.classification_assertion_id', true))
            OR (current_setting('app.write_path', true) = 'assertion_outcome'
                AND id::text = current_setting('app.outcome_assertion_id', true))
        )
    );

DROP POLICY IF EXISTS assertion_delete_policy ON assertions;
CREATE POLICY assertion_delete_policy ON assertions
    FOR DELETE
    USING (false AND rye_role_may_write());

-- ---------------------------------------------------------------------------
-- assertion_evidence. Append-only; the visibility conditions from 0003 are
-- preserved exactly.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS assertion_evidence_insert_policy ON assertion_evidence;
CREATE POLICY assertion_evidence_insert_policy ON assertion_evidence
    FOR INSERT
    WITH CHECK (
        rye_role_may_write()
        AND EXISTS (SELECT 1 FROM assertions a WHERE a.id = assertion_evidence.assertion_id)
        AND (
            (event_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM events e WHERE e.id = assertion_evidence.event_id
            ))
            OR
            (source_assertion_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM assertions a WHERE a.id = assertion_evidence.source_assertion_id
            ))
        )
        AND (
            witness_node_id IS NULL
            OR EXISTS (SELECT 1 FROM nodes n WHERE n.id = assertion_evidence.witness_node_id)
        )
    );

DROP POLICY IF EXISTS assertion_evidence_update_policy ON assertion_evidence;
CREATE POLICY assertion_evidence_update_policy ON assertion_evidence
    FOR UPDATE
    USING (false AND rye_role_may_write())
    WITH CHECK (false AND rye_role_may_write());

DROP POLICY IF EXISTS assertion_evidence_delete_policy ON assertion_evidence;
CREATE POLICY assertion_evidence_delete_policy ON assertion_evidence
    FOR DELETE
    USING (false AND rye_role_may_write());

-- ---------------------------------------------------------------------------
-- artifacts
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS artifact_insert_policy ON artifacts;
CREATE POLICY artifact_insert_policy ON artifacts
    FOR INSERT
    WITH CHECK (rye_role_may_write());

DROP POLICY IF EXISTS artifact_update_policy ON artifacts;
CREATE POLICY artifact_update_policy ON artifacts
    FOR UPDATE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
        AND rye_role_may_write()
    )
    WITH CHECK (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
        AND rye_role_may_write()
    );

DROP POLICY IF EXISTS artifact_delete_policy ON artifacts;
CREATE POLICY artifact_delete_policy ON artifacts
    FOR DELETE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
        AND rye_role_may_write()
    );

-- ---------------------------------------------------------------------------
-- The scope's own status assertion joins registry_entry and review_policy on
-- the settle gate. 0007-configuration-writes-need-an-admin left scope_status
-- out because demoting it fails open — an inactive scope governs nothing — so
-- gating it would have left a non-admin onboarding run weaker than before.
-- That reason is gone now that creating the scope node is admin-only:
-- activating a scope nobody but an admin could create is not a path a
-- non-admin was on.
-- ---------------------------------------------------------------------------
INSERT INTO assertion_type_access (assertion_type, operation, allowed_roles)
VALUES ('scope_status', 'settle', ARRAY['admin'])
ON CONFLICT (assertion_type, operation) DO NOTHING;

-- ============================================================================
-- C. THE TWO HELPERS THAT REFUSE BEFORE THEY LOCK
-- ============================================================================
-- The rule above is one policy, so a helper does not escape it and does not
-- need its own copy. These two get an explicit refusal anyway, and only because
-- RLS would otherwise lie about why: SELECT ... FOR UPDATE applies the UPDATE
-- policy's USING clause as a silent filter, so the caller would be told a node
-- it can see is missing. Gate first, then lock — the order recorded for
-- score_due_predictions() in 0024.

CREATE OR REPLACE FUNCTION update_node_properties(
    p_node_id    uuid,
    p_properties jsonb,
    p_label      text DEFAULT NULL,
    p_summary    text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_old_properties jsonb;
    v_old_label      text;
    v_archived_at    timestamptz;
    v_new_properties jsonb;
    v_changed        jsonb;
    v_event_id       uuid;
    v_updated        int;
    v_role           text := coalesce(current_setting('app.current_role', true), '');
BEGIN
    -- Gate before the lock. Both refusals are evaluated before any read that
    -- the UPDATE policy would filter.
    IF NOT rye_role_may_write() THEN
        RAISE EXCEPTION
            'update_node_properties requires a role that may write; "%" may only read.', v_role
            USING ERRCODE = '42501';
    END IF;

    IF v_role <> 'admin'
       AND EXISTS (
           SELECT 1 FROM nodes n
           WHERE n.id = p_node_id AND n.node_type = 'onboarding_scope'
       )
    THEN
        RAISE EXCEPTION
            'Updating an onboarding_scope node requires a Rye admin ("%" is not).', v_role
            USING ERRCODE = '42501';
    END IF;

    -- Open the write-path gate: FOR UPDATE requires both SELECT and UPDATE
    -- policies to pass, so agents need the gate open for the lock.
    PERFORM set_config('app.write_path', 'update_node_properties', true);

    -- Guard: node must exist and not be archived
    SELECT properties, label, archived_at
      INTO v_old_properties, v_old_label, v_archived_at
      FROM nodes
     WHERE id = p_node_id
       FOR UPDATE;

    IF NOT FOUND THEN
        PERFORM set_config('app.write_path', '', true);
        RAISE EXCEPTION 'Node % not found', p_node_id;
    END IF;

    IF v_archived_at IS NOT NULL THEN
        PERFORM set_config('app.write_path', '', true);
        RAISE EXCEPTION 'Cannot update archived node %', p_node_id;
    END IF;

    -- Merge: new keys overlay old (same semantics as link_record)
    v_new_properties := v_old_properties || p_properties;

    -- Build the diff for the audit event
    v_changed := jsonb_build_object(
        'properties_before', v_old_properties,
        'properties_after',  v_new_properties,
        'properties_added',  p_properties
    );

    IF p_label IS NOT NULL AND p_label IS DISTINCT FROM v_old_label THEN
        v_changed := v_changed || jsonb_build_object(
            'label_before', v_old_label,
            'label_after',  p_label
        );
    END IF;

    -- Perform the update (gate already open)
    UPDATE nodes
       SET properties = v_new_properties,
           label      = coalesce(p_label, label),
           updated_at = now()
     WHERE id = p_node_id;

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    -- Close the gate immediately
    PERFORM set_config('app.write_path', '', true);

    IF v_updated = 0 THEN
        RAISE EXCEPTION 'Node % update blocked by policy', p_node_id;
    END IF;

    -- Record audit event
    v_event_id := record_event(
        p_event_type     := 'node_properties_updated',
        p_summary        := coalesce(p_summary, 'Node properties updated'),
        p_properties     := jsonb_build_object('changed_fields', v_changed),
        p_participant_ids  := ARRAY[p_node_id],
        p_participant_roles := ARRAY['subject']
    );

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION update_node_properties(uuid, jsonb, text, text) IS
    'Merge properties onto a node, optionally change its label, and record a node_properties_updated event. Refuses a role that may not write, and a non-admin editing an onboarding_scope node, before it takes its row lock. After that, "Node % not found" means absent or invisible and nothing else.';

-- A merge is irreversible, it moves one subject's history onto another, and it
-- crosses review policies. It is for people.
CREATE OR REPLACE FUNCTION merge_nodes(
    p_duplicate_id uuid,
    p_canonical_id uuid,
    p_merged_by text DEFAULT 'system'
) RETURNS void
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_dupe nodes;
    v_canon nodes;
    v_assertion assertions;
    v_replacement_id uuid;
    v_role text := coalesce(current_setting('app.current_role', true), '');
BEGIN
    -- Every refusal is evaluated before the first FOR UPDATE. Under an agent
    -- role on an owner RLS binds, the lock is filtered to zero rows and the
    -- old ordering reported "Duplicate node % not found" about a node the
    -- caller could see.
    IF NOT rye_role_may_write() THEN
        RAISE EXCEPTION
            'merge_nodes requires a role that may write; "%" may only read. A Rye admin or a team member merges.', v_role
            USING ERRCODE = '42501';
    END IF;

    IF rye_current_agent_key() IS NOT NULL THEN
        RAISE EXCEPTION
            'merge_nodes is not available to an agent ("%"). Record the duplicate and ask a person; a Rye admin or a team member merges.', v_role
            USING ERRCODE = '42501';
    END IF;

    IF v_role = 'system:cdc' THEN
        RAISE EXCEPTION
            'merge_nodes is not available to system:cdc, which only records domain changes. A Rye admin or a team member merges.'
            USING ERRCODE = '42501';
    END IF;

    IF p_duplicate_id = p_canonical_id THEN
        RAISE EXCEPTION 'duplicate_id and canonical_id must be different';
    END IF;

    -- A merge re-points the duplicate's edges and archives the duplicate. If
    -- either is part of the governance structure, only an admin may do it; a
    -- silent zero-row UPDATE would otherwise leave a governance edge pointing
    -- at an archived node.
    IF v_role <> 'admin' THEN
        IF EXISTS (
            SELECT 1 FROM nodes n
            WHERE n.id = p_duplicate_id AND n.node_type = 'onboarding_scope'
        ) OR EXISTS (
            SELECT 1 FROM edges e
            WHERE (e.source_id = p_duplicate_id OR e.target_id = p_duplicate_id)
              AND e.edge_type IN (
                  'scope_governs_subject', 'scope_governs_source', 'scope_enables_plugin'
              )
              AND e.archived_at IS NULL
              AND (e.effective_from IS NULL OR e.effective_from <= now())
              AND (e.effective_to IS NULL OR e.effective_to > now())
        ) THEN
            RAISE EXCEPTION
                'Merging a node a scope governs requires a Rye admin ("%" is not).', v_role
                USING ERRCODE = '42501';
        END IF;
    END IF;

    SELECT * INTO v_dupe FROM nodes WHERE id = p_duplicate_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Duplicate node % not found', p_duplicate_id;
    END IF;

    SELECT * INTO v_canon FROM nodes WHERE id = p_canonical_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Canonical node % not found', p_canonical_id;
    END IF;

    IF v_dupe.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'Duplicate node % is already archived', p_duplicate_id;
    END IF;

    INSERT INTO node_merges (duplicate_id, canonical_id, merged_by)
    VALUES (p_duplicate_id, p_canonical_id, p_merged_by);

    -- Record merge event BEFORE redirecting participations,
    -- so both nodes are still valid participants
    PERFORM record_event(
        p_event_type        := 'node_merge',
        p_summary           := format('Merged "%s" into "%s"', v_dupe.label, v_canon.label),
        p_properties        := jsonb_build_object(
            'duplicate_id', p_duplicate_id,
            'canonical_id', p_canonical_id,
            'duplicate_label', v_dupe.label,
            'canonical_label', v_canon.label,
            'duplicate_type', v_dupe.node_type,
            'merged_by', p_merged_by
        ),
        p_participant_ids   := ARRAY[p_canonical_id, p_duplicate_id],
        p_participant_roles := ARRAY['canonical', 'duplicate'],
        p_actor             := p_merged_by
    );

    UPDATE edges
    SET source_id = p_canonical_id
    WHERE source_id = p_duplicate_id
      AND target_id <> p_canonical_id;

    UPDATE edges
    SET target_id = p_canonical_id
    WHERE target_id = p_duplicate_id
      AND source_id <> p_canonical_id;

    UPDATE edges
    SET archived_at = now()
    WHERE source_id = p_canonical_id
      AND target_id = p_canonical_id
      AND archived_at IS NULL;

    FOR v_assertion IN
        SELECT *
        FROM current_valid_assertions
        WHERE subject_node_id = p_duplicate_id
    LOOP
        SELECT id
        INTO v_replacement_id
        FROM current_valid_assertions
        WHERE subject_node_id = p_canonical_id
          AND assertion_type = v_assertion.assertion_type
          AND assertion_key = v_assertion.assertion_key
        LIMIT 1;

        IF v_replacement_id IS NULL THEN
            INSERT INTO assertions (
                assertion_type,
                assertion_key,
                subject_node_id,
                subject_edge_id,
                claim,
                effective_at,
                effective_to,
                status,
                basis,
                classification,
                confidence,
                attrs
            ) VALUES (
                v_assertion.assertion_type,
                v_assertion.assertion_key,
                p_canonical_id,
                v_assertion.subject_edge_id,
                v_assertion.claim,
                v_assertion.effective_at,
                v_assertion.effective_to,
                v_assertion.status,
                v_assertion.basis,
                v_assertion.classification,
                v_assertion.confidence,
                v_assertion.attrs
            )
            RETURNING id INTO v_replacement_id;

            PERFORM append_assertion_evidence(
                v_replacement_id,
                ARRAY[jsonb_build_object(
                    'kind', 'derivation',
                    'source_assertion_id', v_assertion.id
                )]
            );
        END IF;

        PERFORM mark_assertion_superseded(v_assertion.id, v_replacement_id);
    END LOOP;

    UPDATE event_participants
    SET node_id = p_canonical_id
    WHERE node_id = p_duplicate_id
      AND NOT EXISTS (
          SELECT 1
          FROM event_participants ep2
          WHERE ep2.event_id = event_participants.event_id
            AND ep2.node_id = p_canonical_id
            AND ep2.role = event_participants.role
      );

    DELETE FROM event_participants
    WHERE node_id = p_duplicate_id;

    UPDATE artifacts
    SET source_node_id = p_canonical_id
    WHERE source_node_id = p_duplicate_id;

    UPDATE artifacts
    SET related_node_ids = array_replace(related_node_ids, p_duplicate_id, p_canonical_id)
    WHERE p_duplicate_id = ANY(related_node_ids);

    DELETE FROM node_source_map nsm_dup
    WHERE nsm_dup.node_id = p_duplicate_id
      AND EXISTS (
          SELECT 1
          FROM node_source_map nsm_can
          WHERE nsm_can.node_id = p_canonical_id
            AND nsm_can.source_schema = nsm_dup.source_schema
            AND nsm_can.source_table = nsm_dup.source_table
      );

    UPDATE node_source_map
    SET node_id = p_canonical_id
    WHERE node_id = p_duplicate_id;

    UPDATE nodes
    SET properties = (SELECT properties FROM nodes WHERE id = p_duplicate_id) || properties,
        updated_at = now()
    WHERE id = p_canonical_id;

    UPDATE nodes
    SET archived_at = now(),
        updated_at = now()
    WHERE id = p_duplicate_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION merge_nodes(uuid, uuid, text) IS
    'Merge a duplicate node into a canonical one. Refuses, before it takes any lock and with SQLSTATE 42501: a role that may not write, an agent-shaped role, system:cdc, and a non-admin merging a node the governance structure touches. After those gates, "Duplicate node % not found" means absent or invisible and nothing else.';

-- ============================================================================
-- D. CDC RECORDS UNDER A SYSTEM ROLE
-- ============================================================================
-- capture_domain_change() runs inside the application's own transaction on its
-- own domain table, in a session that may set no Rye role at all -- which is
-- the normal overlay deployment, not an edge case. Refusing its record_event()
-- would fail the application's INSERT and put Rye in the way of the system of
-- record; skipping the event would turn off the feature track_table() exists
-- for. So it does neither.
--
-- The node lookup stays where it was, before the swap, under the calling
-- session's own role and app.current_teams: node visibility is exactly what it
-- was, and a mapped node the session cannot see still skips silently. Only the
-- record_event() call runs as system:cdc, and the caller's value is restored on
-- the normal path and in a re-raising EXCEPTION block. Rolling the
-- subtransaction back would restore it anyway; the block is belt and braces.
--
-- An unset variable restores as the empty string, which matches no role row and
-- is therefore the same "unknown" shape it was. `PERFORM set_config` resets
-- FOUND, so nothing after the swap tests FOUND from before it -- the node
-- lookup is already tested by its own variable.
--
-- The audit trail keeps the real caller: actor_system stays system:cdc, as it
-- already was, and properties gain one additive key, session_role, carrying the
-- caller's app.current_role before the swap, or null when none was set.

CREATE OR REPLACE FUNCTION capture_domain_change() RETURNS trigger
SET search_path = rye, pg_catalog, public
AS $$
DECLARE
    v_node_id uuid;
    v_change_type text;
    v_old_data jsonb;
    v_new_data jsonb;
    v_record_id text;
    v_pk_col text;
    v_prev_role text;
BEGIN
    -- Determine the record identifier:
    -- 1. Try the 'id' column (most common)
    -- 2. Fall back to looking up from node_source_map via primary key
    v_old_data := CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END;
    v_new_data := CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END;

    -- Use the row data to find the record_id from the appropriate column
    IF TG_OP = 'DELETE' THEN
        -- For DELETE, try 'id' field from OLD row
        v_record_id := v_old_data->>'id';
        IF v_record_id IS NULL THEN
            -- Look up the PK column from pg_index
            SELECT a.attname INTO v_pk_col
            FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME)::regclass
              AND i.indisprimary
            LIMIT 1;

            IF v_pk_col IS NOT NULL THEN
                v_record_id := v_old_data->>v_pk_col;
            END IF;
        END IF;
    ELSE
        v_record_id := v_new_data->>'id';
        IF v_record_id IS NULL THEN
            SELECT a.attname INTO v_pk_col
            FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME)::regclass
              AND i.indisprimary
            LIMIT 1;

            IF v_pk_col IS NOT NULL THEN
                v_record_id := v_new_data->>v_pk_col;
            END IF;
        END IF;
    END IF;

    IF v_record_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    -- Under the caller's own role, before any swap.
    SELECT node_id INTO v_node_id
    FROM node_source_map
    WHERE source_schema = TG_TABLE_SCHEMA
      AND source_table = TG_TABLE_NAME
      AND source_id = v_record_id;

    -- No graph node mapped, or the caller cannot see the mapping; skip silently
    IF v_node_id IS NULL THEN RETURN COALESCE(NEW, OLD); END IF;

    v_change_type := lower(TG_OP);
    v_prev_role := current_setting('app.current_role', true);

    BEGIN
        PERFORM set_config('app.current_role', 'system:cdc', true);

        PERFORM record_event(
            p_event_type        := 'domain_change',
            p_summary           := format('%s.%s %s (record %s)', TG_TABLE_SCHEMA, TG_TABLE_NAME, v_change_type, v_record_id),
            p_properties        := jsonb_build_object(
                'schema', TG_TABLE_SCHEMA,
                'table', TG_TABLE_NAME,
                'operation', v_change_type,
                'record_id', v_record_id,
                'session_role', nullif(v_prev_role, ''),
                'old', v_old_data,
                'new', v_new_data,
                'changed_fields', CASE
                    WHEN TG_OP = 'UPDATE' THEN (
                        SELECT jsonb_object_agg(key, jsonb_build_object('old', v_old_data->key, 'new', value))
                        FROM jsonb_each(v_new_data)
                        WHERE v_old_data->key IS DISTINCT FROM v_new_data->key
                    )
                    ELSE NULL
                END
            ),
            p_participant_ids   := ARRAY[v_node_id],
            p_participant_roles := ARRAY['subject'],
            p_actor             := 'system:cdc'
        );

        PERFORM set_config('app.current_role', coalesce(v_prev_role, ''), true);
    EXCEPTION WHEN OTHERS THEN
        PERFORM set_config('app.current_role', coalesce(v_prev_role, ''), true);
        RAISE;
    END;

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION capture_domain_change() IS
    'CDC trigger for tracked domain tables. Resolves the source node under the calling session''s own role, then records the domain_change event as the reserved system:cdc role and restores the caller''s role on every exit path. A tracked table''s writes never fail because of Rye''s role rules, and a tracked table always produces its event. properties.session_role carries the caller''s role, or null when none was set; actor_system stays system:cdc.';
