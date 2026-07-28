-- Agent INSERT policies and artifact helper.

SET search_path = rye, pg_catalog, public;

DROP POLICY IF EXISTS node_insert_policy ON nodes;
CREATE POLICY node_insert_policy ON nodes
    FOR INSERT
    WITH CHECK (true);

DROP POLICY IF EXISTS edge_insert_policy ON edges;
CREATE POLICY edge_insert_policy ON edges
    FOR INSERT
    WITH CHECK (true);

DROP POLICY IF EXISTS artifact_insert_policy ON artifacts;
CREATE POLICY artifact_insert_policy ON artifacts
    FOR INSERT
    WITH CHECK (true);

CREATE OR REPLACE FUNCTION propagate_digest_artifact_classification()
RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_classification text;
    v_digest_id uuid;
BEGIN
    v_digest_id := coalesce(
        nullif(NEW.attrs->>'digest_assertion_id', '')::uuid,
        nullif(NEW.content->>'digest_assertion_id', '')::uuid
    );

    IF v_digest_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT classification
    INTO v_classification
    FROM assertions
    WHERE id = v_digest_id
      AND assertion_type = 'digest';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Digest assertion % not found for narrative artifact', v_digest_id;
    END IF;

    IF NEW.attrs ? 'classification'
       AND NEW.attrs->>'classification' IS DISTINCT FROM v_classification
    THEN
        RAISE EXCEPTION
            'Narrative artifact classification must match digest assertion classification';
    END IF;

    NEW.attrs := coalesce(NEW.attrs, '{}'::jsonb)
        || jsonb_build_object('classification', v_classification);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_artifact_digest_classification ON artifacts;
CREATE TRIGGER trg_artifact_digest_classification
    BEFORE INSERT OR UPDATE ON artifacts
    FOR EACH ROW
    EXECUTE FUNCTION propagate_digest_artifact_classification();

CREATE OR REPLACE FUNCTION record_artifact(
    p_artifact_type text,
    p_content jsonb,
    p_source_event_id uuid DEFAULT NULL,
    p_source_node_id uuid DEFAULT NULL,
    p_related_node_ids uuid[] DEFAULT '{}',
    p_location jsonb DEFAULT NULL,
    p_content_hash text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_artifact_id uuid;
    v_attrs jsonb := '{}';
BEGIN
    IF p_content_hash IS NOT NULL THEN
        SELECT id INTO v_artifact_id
        FROM artifacts
        WHERE artifact_type = p_artifact_type
          AND attrs->>'content_hash' = p_content_hash;

        IF v_artifact_id IS NOT NULL THEN
            RETURN v_artifact_id;
        END IF;

        v_attrs := jsonb_build_object('content_hash', p_content_hash);
    END IF;

    INSERT INTO artifacts (
        artifact_type,
        content,
        source_event_id,
        source_node_id,
        related_node_ids,
        location,
        attrs
    ) VALUES (
        p_artifact_type,
        p_content,
        p_source_event_id,
        p_source_node_id,
        p_related_node_ids,
        p_location,
        v_attrs
    )
    RETURNING id INTO v_artifact_id;

    RETURN v_artifact_id;
END;
$$ LANGUAGE plpgsql;
