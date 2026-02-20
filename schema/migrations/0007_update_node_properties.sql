-- Agent-safe node property updates via update_node_properties()
-- Relaxes node_update_policy to allow agents through an approved write path,
-- then provides a controlled function that merges properties, optionally updates
-- the label, and records an audit event.

SET search_path = rye, pg_catalog;

-- ============================================================================
-- 1. RELAX NODE UPDATE POLICY — allow agents via write-path gate
-- ============================================================================
-- Non-agent roles: unrestricted (same as before).
-- Agent roles: only allowed when app.write_path = 'update_node_properties'.

DROP POLICY IF EXISTS node_update_policy ON nodes;
CREATE POLICY node_update_policy ON nodes
    FOR UPDATE
    USING (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
        OR current_setting('app.write_path', true) = 'update_node_properties'
    )
    WITH CHECK (
        coalesce(current_setting('app.current_role', true), '') NOT LIKE 'agent:%'
        OR current_setting('app.write_path', true) = 'update_node_properties'
    );

-- ============================================================================
-- 2. update_node_properties() — merge properties + optional label + audit event
-- ============================================================================

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
BEGIN
    -- Open the write-path gate early: FOR UPDATE requires both SELECT and
    -- UPDATE policies to pass, so agents need the gate open for the lock.
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
