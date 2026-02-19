-- Rye CRM profile

SET search_path = rye, pg_catalog, public;

CREATE OR REPLACE FUNCTION create_opportunity(
    p_name text,
    p_pipeline_code text,
    p_assigned_to_id uuid,
    p_properties jsonb DEFAULT '{}',
    p_teams text[] DEFAULT '{}'
) RETURNS uuid
SET search_path = rye, pg_catalog, public
AS $$
DECLARE
    v_opp_id uuid;
    v_code text;
    v_pipeline_id uuid;
    v_default_stage text;
BEGIN
    v_code := generate_crm_code('OPP');

    SELECT id, properties->>'default_stage'
    INTO v_pipeline_id, v_default_stage
    FROM nodes
    WHERE node_type = 'pipeline'
      AND properties->>'code' = p_pipeline_code
      AND archived_at IS NULL
    LIMIT 1;

    IF v_pipeline_id IS NULL THEN
        RAISE EXCEPTION 'Pipeline with code % not found', p_pipeline_code;
    END IF;

    INSERT INTO nodes (node_type, label, properties, attrs, external_id, external_source)
    VALUES (
        'opportunity',
        p_name,
        p_properties || jsonb_build_object('name', p_name, 'code', v_code),
        jsonb_build_object('teams', to_jsonb(p_teams))
        || CASE WHEN array_length(p_teams, 1) > 0
                THEN jsonb_build_object('classification', 'internal')
                ELSE '{}'::jsonb
           END,
        v_code,
        'internal'
    )
    RETURNING id INTO v_opp_id;

    INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
    VALUES (
        'deal_stage',
        'default',
        v_opp_id,
        jsonb_build_object('stage', v_default_stage, 'pipeline', p_pipeline_code),
        1.0
    );

    INSERT INTO edges (edge_type, source_id, target_id, properties)
    VALUES (
        'pipeline_member',
        v_opp_id,
        v_pipeline_id,
        jsonb_build_object('entered_at', now())
    );

    IF p_assigned_to_id IS NOT NULL THEN
        INSERT INTO edges (edge_type, source_id, target_id, properties, effective_from)
        VALUES ('assigned_to', v_opp_id, p_assigned_to_id, '{"role": "owner"}', now());
    END IF;

    -- Record creation event (parallel to create_task's task_created)
    PERFORM record_event(
        p_event_type        := 'opportunity_created',
        p_summary           := format('Created %s: %s', v_code, p_name),
        p_properties        := jsonb_build_object(
            'opp_code', v_code,
            'pipeline', p_pipeline_code,
            'initial_stage', v_default_stage
        ),
        p_participant_ids   := ARRAY[v_opp_id],
        p_participant_roles := ARRAY['subject']
    );

    RETURN v_opp_id;
END;
$$ LANGUAGE plpgsql;

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
    FROM current_assertions
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

    IF v_old_assertion_id IS NULL THEN
        INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, source_event_id, confidence)
        VALUES (
            'deal_stage',
            'default',
            p_opp_id,
            jsonb_build_object('stage', p_new_stage, 'pipeline', v_pipeline, 'reason', p_reason),
            v_event_id,
            1.0
        )
        RETURNING id INTO v_new_assertion_id;

        RETURN v_new_assertion_id;
    END IF;

    v_new_assertion_id := supersede_assertion(
        p_old_assertion_id := v_old_assertion_id,
        p_new_assertion_type := 'deal_stage',
        p_new_subject_node_id := p_opp_id,
        p_new_subject_edge_id := NULL,
        p_new_claim := jsonb_build_object(
            'stage', p_new_stage,
            'pipeline', coalesce(v_pipeline, 'unknown'),
            'moved_from', v_old_stage,
            'reason', p_reason
        ),
        p_new_assertion_key := 'default',
        p_new_source_event_id := v_event_id,
        p_new_confidence := 1.0
    );

    RETURN v_new_assertion_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION log_crm_activity(
    p_event_type text,
    p_summary text,
    p_properties jsonb,
    p_actor text,
    p_participant_ids uuid[] DEFAULT '{}',
    p_participant_roles text[] DEFAULT '{}',
    p_occurred_at timestamptz DEFAULT now()
) RETURNS uuid
SET search_path = rye, pg_catalog, public
AS $$
BEGIN
    RETURN record_event(
        p_event_type        := p_event_type,
        p_summary           := p_summary,
        p_properties        := p_properties,
        p_participant_ids   := p_participant_ids,
        p_participant_roles := p_participant_roles,
        p_actor             := p_actor,
        p_occurred_at       := p_occurred_at
    );
END;
$$ LANGUAGE plpgsql;

CREATE MATERIALIZED VIEW IF NOT EXISTS opportunities_active AS
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
LEFT JOIN current_assertions stg
    ON stg.subject_node_id = n.id
   AND stg.assertion_type = 'deal_stage'
   AND stg.assertion_key = 'default'
LEFT JOIN current_assertions val
    ON val.subject_node_id = n.id
   AND val.assertion_type = 'deal_value'
LEFT JOIN current_assertions wp
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
      AND own_e.effective_to IS NULL
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

CREATE MATERIALIZED VIEW IF NOT EXISTS contacts_directory AS
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
      AND emp.effective_to IS NULL
    LIMIT 1
) org ON true
LEFT JOIN current_assertions ci
    ON ci.subject_node_id = n.id
   AND ci.assertion_type = 'contact_info'
LEFT JOIN current_assertions sent
    ON sent.subject_node_id = n.id
   AND sent.assertion_type = 'sentiment'
WHERE n.node_type = 'person'
  AND n.archived_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_cd_node ON contacts_directory (node_id);
CREATE INDEX IF NOT EXISTS idx_cd_code         ON contacts_directory (code);
CREATE INDEX IF NOT EXISTS idx_cd_name         ON contacts_directory (last_name, first_name);
CREATE INDEX IF NOT EXISTS idx_cd_org          ON contacts_directory (org_id);
