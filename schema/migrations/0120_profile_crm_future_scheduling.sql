-- Future-safe CRM scheduling helpers.

SET search_path = rye, pg_catalog, public;

CREATE OR REPLACE FUNCTION advance_deal_stage(
    p_opp_id uuid,
    p_new_stage text,
    p_reason text DEFAULT NULL,
    p_actor text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog, public
AS $$
DECLARE
    v_old_assertion_id uuid;
    v_old_stage text;
    v_pipeline text;
    v_new_assertion_id uuid;
    v_event_id uuid;
BEGIN
    SELECT id, claim->>'stage', claim->>'pipeline'
    INTO v_old_assertion_id, v_old_stage, v_pipeline
    FROM current_valid_assertions
    WHERE subject_node_id = p_opp_id
      AND assertion_type = 'deal_stage'
      AND assertion_key = 'default'
    LIMIT 1;

    v_event_id := record_event(
        p_event_type        := 'stage_change',
        p_summary           := format('Stage: %s -> %s', coalesce(v_old_stage, 'none'), p_new_stage),
        p_properties        := jsonb_build_object('from_stage', v_old_stage, 'to_stage', p_new_stage, 'reason', p_reason),
        p_participant_ids   := ARRAY[p_opp_id],
        p_participant_roles := ARRAY['subject'],
        p_actor             := p_actor
    );

    v_new_assertion_id := record_assertion(
        p_assertion_type := 'deal_stage',
        p_assertion_key := 'default',
        p_subject_node_id := p_opp_id,
        p_claim := jsonb_build_object(
            'stage', p_new_stage,
            'pipeline', coalesce(v_pipeline, 'unknown'),
            'moved_from', v_old_stage,
            'reason', p_reason
        ),
        p_evidence         := ARRAY[jsonb_build_object('kind', 'source', 'event_id', v_event_id)],
        p_basis            := 'reported',
        p_confidence := 1.0,
        p_attrs := jsonb_build_object('source', 'rye-crm', 'stage_change', true)
    );

    RETURN v_new_assertion_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION schedule_deal_stage_change(
    p_opp_id uuid,
    p_stage text,
    p_effective_at timestamptz,
    p_reason text DEFAULT NULL,
    p_actor text DEFAULT NULL,
    p_plan_properties jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
SET search_path = rye, pg_catalog, public
AS $$
DECLARE
    v_current_stage text;
    v_pipeline text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM nodes
        WHERE id = p_opp_id
          AND node_type = 'opportunity'
          AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Opportunity % not found', p_opp_id;
    END IF;

    SELECT claim->>'stage', claim->>'pipeline'
    INTO v_current_stage, v_pipeline
    FROM current_valid_assertions
    WHERE subject_node_id = p_opp_id
      AND assertion_type = 'deal_stage'
      AND assertion_key = 'default'
    LIMIT 1;

    RETURN schedule_assertion_change(
        p_subject_node_id := p_opp_id,
        p_subject_edge_id := NULL,
        p_assertion_type := 'deal_stage',
        p_assertion_key := 'default',
        p_claim := jsonb_build_object(
            'stage', p_stage,
            'pipeline', coalesce(v_pipeline, 'unknown'),
            'planned_from', v_current_stage,
            'reason', p_reason
        ),
        p_effective_at := p_effective_at,
        p_reason := p_reason,
        p_actor := p_actor,
        p_basis := 'reported',
        p_confidence := 1.0,
        p_attrs := jsonb_build_object(
            'source', 'rye-crm',
            'plan_properties', coalesce(p_plan_properties, '{}'::jsonb)
        )
    );
END;
$$ LANGUAGE plpgsql;

DROP MATERIALIZED VIEW IF EXISTS opportunities_active;

CREATE MATERIALIZED VIEW opportunities_active AS
SELECT
    n.id AS node_id,
    n.label,
    n.properties->>'code' AS code,
    n.properties->>'name' AS name,
    n.properties->>'estimated_value' AS estimated_value,
    n.attrs->'teams' AS teams,
    stg.claim->>'stage' AS stage,
    stg.claim->>'pipeline' AS pipeline,
    stg.asserted_at AS stage_since,
    val.claim->>'amount' AS current_value,
    wp.claim->>'probability' AS win_probability,
    pc.label AS primary_contact_name,
    pc.id AS primary_contact_id,
    owner.label AS assigned_to_name,
    owner.id AS assigned_to_id,
    n.created_at
FROM nodes n
LEFT JOIN current_valid_assertions stg
    ON stg.subject_node_id = n.id
   AND stg.assertion_type = 'deal_stage'
   AND stg.assertion_key = 'default'
LEFT JOIN current_valid_assertions val
    ON val.subject_node_id = n.id
   AND val.assertion_type = 'deal_value'
LEFT JOIN current_valid_assertions wp
    ON wp.subject_node_id = n.id
   AND wp.assertion_type = 'win_probability'
LEFT JOIN LATERAL (
    SELECT pc_n.id, pc_n.label
    FROM edges pc_e
    JOIN nodes pc_n ON pc_n.id = pc_e.target_id
    WHERE pc_e.source_id = n.id
      AND pc_e.edge_type = 'primary_contact'
      AND pc_e.archived_at IS NULL
    ORDER BY pc_e.created_at
    LIMIT 1
) pc ON true
LEFT JOIN LATERAL (
    SELECT own_n.id, own_n.label
    FROM edges own_e
    JOIN nodes own_n ON own_n.id = own_e.target_id
    WHERE own_e.source_id = n.id
      AND own_e.edge_type = 'assigned_to'
      AND own_e.properties->>'role' = 'owner'
      AND own_e.archived_at IS NULL
      AND (own_e.effective_from IS NULL OR own_e.effective_from <= now())
      AND (own_e.effective_to IS NULL OR own_e.effective_to > now())
    ORDER BY own_e.effective_from DESC NULLS LAST
    LIMIT 1
) owner ON true
WHERE n.node_type = 'opportunity'
  AND n.archived_at IS NULL
  AND (
      stg.claim->>'stage' IS NULL
      OR stg.claim->>'stage' NOT IN ('closed_won', 'closed_lost', 'dead')
  );

CREATE UNIQUE INDEX IF NOT EXISTS idx_oa_node  ON opportunities_active (node_id);
CREATE INDEX IF NOT EXISTS idx_oa_code         ON opportunities_active (code);
CREATE INDEX IF NOT EXISTS idx_oa_stage        ON opportunities_active (stage);
CREATE INDEX IF NOT EXISTS idx_oa_owner        ON opportunities_active (assigned_to_id);

DROP MATERIALIZED VIEW IF EXISTS contacts_directory;

CREATE MATERIALIZED VIEW contacts_directory AS
SELECT
    n.id AS node_id,
    n.label,
    n.properties->>'code' AS code,
    n.properties->>'first_name' AS first_name,
    n.properties->>'last_name' AS last_name,
    n.properties->>'email' AS email,
    n.properties->>'phone' AS phone,
    n.properties->>'title' AS title,
    org.label AS organization,
    org.id AS org_id,
    ci.claim AS current_contact_info,
    sent.claim AS current_sentiment,
    n.created_at
FROM nodes n
LEFT JOIN LATERAL (
    SELECT o.id, o.label
    FROM edges emp
    JOIN nodes o ON o.id = emp.source_id
    WHERE emp.target_id = n.id
      AND emp.edge_type = 'employs'
      AND emp.archived_at IS NULL
      AND (emp.effective_from IS NULL OR emp.effective_from <= now())
      AND (emp.effective_to IS NULL OR emp.effective_to > now())
    LIMIT 1
) org ON true
LEFT JOIN current_valid_assertions ci
    ON ci.subject_node_id = n.id
   AND ci.assertion_type = 'contact_info'
LEFT JOIN current_valid_assertions sent
    ON sent.subject_node_id = n.id
   AND sent.assertion_type = 'sentiment'
WHERE n.node_type = 'person'
  AND n.archived_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_cd_node ON contacts_directory (node_id);
CREATE INDEX IF NOT EXISTS idx_cd_code         ON contacts_directory (code);
CREATE INDEX IF NOT EXISTS idx_cd_name         ON contacts_directory (last_name, first_name);
CREATE INDEX IF NOT EXISTS idx_cd_org          ON contacts_directory (org_id);
