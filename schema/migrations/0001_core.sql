-- Rye core schema (PostgreSQL 15+)

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "btree_gin";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

CREATE SCHEMA IF NOT EXISTS rye;
SET search_path = rye, pg_catalog, public;

CREATE TABLE IF NOT EXISTS nodes (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    node_type       text NOT NULL,
    label           text,
    external_id     text,
    external_source text,
    properties      jsonb NOT NULL DEFAULT '{}',
    attrs           jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    archived_at     timestamptz
);

CREATE INDEX IF NOT EXISTS idx_nodes_type       ON nodes (node_type);
CREATE INDEX IF NOT EXISTS idx_nodes_external   ON nodes (external_source, external_id);
CREATE INDEX IF NOT EXISTS idx_nodes_label      ON nodes USING gin (label gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_nodes_properties ON nodes USING gin (properties);
CREATE INDEX IF NOT EXISTS idx_nodes_attrs      ON nodes USING gin (attrs);
CREATE INDEX IF NOT EXISTS idx_nodes_created    ON nodes (created_at);
CREATE INDEX IF NOT EXISTS idx_nodes_active     ON nodes (node_type) WHERE archived_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_nodes_external_unique
    ON nodes (external_source, external_id)
    WHERE external_id IS NOT NULL AND archived_at IS NULL;

CREATE TABLE IF NOT EXISTS edges (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    edge_type       text NOT NULL,
    source_id       uuid NOT NULL REFERENCES nodes(id),
    target_id       uuid NOT NULL REFERENCES nodes(id),
    properties      jsonb NOT NULL DEFAULT '{}',
    effective_from  timestamptz,
    effective_to    timestamptz,
    weight          numeric DEFAULT 1.0,
    attrs           jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    archived_at     timestamptz
);

CREATE INDEX IF NOT EXISTS idx_edges_type        ON edges (edge_type);
CREATE INDEX IF NOT EXISTS idx_edges_source      ON edges (source_id);
CREATE INDEX IF NOT EXISTS idx_edges_target      ON edges (target_id);
CREATE INDEX IF NOT EXISTS idx_edges_source_type ON edges (source_id, edge_type);
CREATE INDEX IF NOT EXISTS idx_edges_target_type ON edges (target_id, edge_type);
CREATE INDEX IF NOT EXISTS idx_edges_properties  ON edges USING gin (properties);
CREATE INDEX IF NOT EXISTS idx_edges_effective   ON edges (effective_from, effective_to);
CREATE INDEX IF NOT EXISTS idx_edges_active      ON edges (edge_type) WHERE archived_at IS NULL;

CREATE TABLE IF NOT EXISTS events (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type      text NOT NULL,
    occurred_at     timestamptz NOT NULL,
    recorded_at     timestamptz NOT NULL DEFAULT now(),
    summary         text,
    properties      jsonb NOT NULL DEFAULT '{}',
    actor_node_id   uuid REFERENCES nodes(id),
    actor_system    text,
    attrs           jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_events_type       ON events (event_type);
CREATE INDEX IF NOT EXISTS idx_events_occurred   ON events (occurred_at);
CREATE INDEX IF NOT EXISTS idx_events_recorded   ON events (recorded_at);
CREATE INDEX IF NOT EXISTS idx_events_actor      ON events (actor_node_id);
CREATE INDEX IF NOT EXISTS idx_events_properties ON events USING gin (properties);

CREATE TABLE IF NOT EXISTS event_participants (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id        uuid NOT NULL REFERENCES events(id),
    node_id         uuid NOT NULL REFERENCES nodes(id),
    role            text NOT NULL,
    properties      jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (event_id, node_id, role)
);

CREATE INDEX IF NOT EXISTS idx_ep_event ON event_participants (event_id);
CREATE INDEX IF NOT EXISTS idx_ep_node  ON event_participants (node_id);
CREATE INDEX IF NOT EXISTS idx_ep_role  ON event_participants (role);

CREATE TABLE IF NOT EXISTS assertions (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    assertion_type  text NOT NULL,
    assertion_key   text NOT NULL DEFAULT 'default',
    status           text NOT NULL DEFAULT 'accepted'
                     CHECK (status IN ('candidate', 'accepted')),
    basis            text NOT NULL DEFAULT 'unknown'
                     CHECK (basis IN ('observed', 'reported', 'inferred', 'assumed', 'unknown')),
    classification   text,
    subject_node_id uuid REFERENCES nodes(id),
    subject_edge_id uuid REFERENCES edges(id),
    subject_ref     text GENERATED ALWAYS AS (
        COALESCE('n:' || subject_node_id::text, 'e:' || subject_edge_id::text)
    ) STORED,
    claim           jsonb NOT NULL,
    asserted_at     timestamptz NOT NULL DEFAULT now(),
    effective_at    timestamptz,
    effective_to    timestamptz,
    superseded_at   timestamptz,
    superseded_by   uuid REFERENCES assertions(id) DEFERRABLE INITIALLY DEFERRED,
    confidence      numeric CHECK (confidence BETWEEN 0 AND 1),
    attrs           jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT assertion_has_subject CHECK (
        subject_node_id IS NOT NULL OR subject_edge_id IS NOT NULL
    ),
    CONSTRAINT assertion_key_not_blank CHECK (length(trim(assertion_key)) > 0)
);

CREATE INDEX IF NOT EXISTS idx_assertions_type      ON assertions (assertion_type);
CREATE INDEX IF NOT EXISTS idx_assertions_node      ON assertions (subject_node_id)
    WHERE subject_node_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_assertions_edge      ON assertions (subject_edge_id)
    WHERE subject_edge_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_assertions_claim     ON assertions USING gin (claim);
CREATE INDEX IF NOT EXISTS idx_assertions_asserted  ON assertions (asserted_at);
CREATE INDEX IF NOT EXISTS idx_assertions_effective ON assertions (effective_at);
CREATE INDEX IF NOT EXISTS idx_assertions_current_subject_asserted
    ON assertions (subject_ref, asserted_at)
    WHERE superseded_at IS NULL AND status = 'accepted';

CREATE UNIQUE INDEX IF NOT EXISTS idx_assertions_active_unique
    ON assertions (
        subject_ref,
        assertion_type,
        assertion_key,
        coalesce(effective_at, '-infinity'::timestamptz),
        coalesce(effective_to, 'infinity'::timestamptz)
    )
    WHERE superseded_at IS NULL AND status = 'accepted';

CREATE TABLE IF NOT EXISTS assertion_evidence (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    assertion_id        uuid NOT NULL REFERENCES assertions(id),
    kind                text NOT NULL
                        CHECK (kind IN ('source', 'corroboration', 'derivation')),
    event_id            uuid REFERENCES events(id),
    source_assertion_id uuid REFERENCES assertions(id),
    witness_node_id     uuid REFERENCES nodes(id),
    recorded_at         timestamptz NOT NULL DEFAULT now(),
    attrs               jsonb NOT NULL DEFAULT '{}',
    CHECK (
        ((kind = 'derivation') = (source_assertion_id IS NOT NULL))
        AND ((kind <> 'derivation') = (event_id IS NOT NULL))
    )
);

CREATE INDEX IF NOT EXISTS idx_assertion_evidence_assertion
    ON assertion_evidence (assertion_id);
CREATE INDEX IF NOT EXISTS idx_assertion_evidence_source_assertion
    ON assertion_evidence (source_assertion_id)
    WHERE source_assertion_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_assertion_evidence_event
    ON assertion_evidence (event_id)
    WHERE event_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS artifacts (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    artifact_type    text NOT NULL,
    source_event_id  uuid REFERENCES events(id),
    source_node_id   uuid REFERENCES nodes(id),
    content          jsonb NOT NULL DEFAULT '{}',
    location         jsonb,
    related_node_ids uuid[],
    attrs            jsonb NOT NULL DEFAULT '{}',
    created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_artifacts_type      ON artifacts (artifact_type);
CREATE INDEX IF NOT EXISTS idx_artifacts_source_ev ON artifacts (source_event_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_source_nd ON artifacts (source_node_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_content   ON artifacts USING gin (content);
CREATE INDEX IF NOT EXISTS idx_artifacts_related   ON artifacts USING gin (related_node_ids);

CREATE TABLE IF NOT EXISTS access_grants (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    grantee       text NOT NULL,
    grant_type    text NOT NULL,
    resource_type text NOT NULL,
    access_level  text NOT NULL,
    scope         jsonb NOT NULL,
    active        boolean DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ag_grantee ON access_grants (grantee, resource_type);
CREATE INDEX IF NOT EXISTS idx_ag_scope   ON access_grants USING gin (scope);

CREATE TABLE IF NOT EXISTS field_classifications (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    node_type      text NOT NULL,
    field_path     text NOT NULL,
    classification text NOT NULL,
    min_role       text NOT NULL,
    UNIQUE (node_type, field_path)
);

CREATE TABLE IF NOT EXISTS node_source_map (
    node_id        uuid NOT NULL REFERENCES nodes(id),
    source_schema  text NOT NULL,
    source_table   text NOT NULL,
    source_id      text NOT NULL,
    source_id_type text DEFAULT 'int',
    synced_at      timestamptz DEFAULT now(),
    PRIMARY KEY (node_id, source_schema, source_table)
);

CREATE INDEX IF NOT EXISTS idx_nsm_source
    ON node_source_map (source_schema, source_table, source_id);

CREATE TABLE IF NOT EXISTS node_merges (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    duplicate_id uuid NOT NULL REFERENCES nodes(id),
    canonical_id uuid NOT NULL REFERENCES nodes(id),
    merged_at    timestamptz NOT NULL DEFAULT now(),
    merged_by    text,
    confidence   numeric,
    properties   jsonb DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_merges_dup ON node_merges (duplicate_id);
CREATE INDEX IF NOT EXISTS idx_merges_can ON node_merges (canonical_id);

CREATE TABLE IF NOT EXISTS crm_code_counters (
    prefix     text NOT NULL,
    year_month text NOT NULL,
    next_val   int NOT NULL DEFAULT 1,
    PRIMARY KEY (prefix, year_month)
);

-- Classification enforcement: nodes with teams must have classification set.
-- Without this, team-scoped nodes default to NULL classification which makes
-- them visible to all users, defeating team isolation.
CREATE OR REPLACE FUNCTION enforce_classification_with_teams() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
BEGIN
    IF NEW.attrs ? 'teams'
       AND jsonb_typeof(NEW.attrs->'teams') = 'array'
       AND jsonb_array_length(NEW.attrs->'teams') > 0
       AND (NEW.attrs->>'classification') IS NULL
    THEN
        RAISE EXCEPTION 'Nodes with teams must have classification set in attrs (e.g. "internal", "confidential", "restricted")';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_nodes_classification_check ON nodes;
CREATE TRIGGER trg_nodes_classification_check
    BEFORE INSERT OR UPDATE ON nodes
    FOR EACH ROW
    EXECUTE FUNCTION enforce_classification_with_teams();

CREATE OR REPLACE VIEW current_valid_assertions
WITH (security_invoker = true) AS
SELECT *
FROM assertions
WHERE status = 'accepted'
  AND superseded_at IS NULL
  AND (effective_at IS NULL OR effective_at <= now())
  AND (effective_to IS NULL OR effective_to > now());

CREATE OR REPLACE VIEW current_assertions
WITH (security_invoker = true) AS
SELECT * FROM current_valid_assertions;

CREATE OR REPLACE VIEW node_context
WITH (security_invoker = true) AS
SELECT
    n.id AS node_id,
    n.node_type,
    n.label,
    n.properties,
    coalesce(
        json_agg(DISTINCT jsonb_build_object(
            'edge_id', eo.id,
            'edge_type', eo.edge_type,
            'target_id', eo.target_id,
            'properties', eo.properties
        )) FILTER (WHERE eo.id IS NOT NULL),
        '[]'::json
    ) AS outbound_edges,
    coalesce(
        json_agg(DISTINCT jsonb_build_object(
            'edge_id', ei.id,
            'edge_type', ei.edge_type,
            'source_id', ei.source_id,
            'properties', ei.properties
        )) FILTER (WHERE ei.id IS NOT NULL),
        '[]'::json
    ) AS inbound_edges,
    coalesce(
        json_agg(DISTINCT jsonb_build_object(
            'assertion_id', a.id,
            'assertion_type', a.assertion_type,
            'assertion_key', a.assertion_key,
            'claim', a.claim,
            'asserted_at', a.asserted_at,
            'confidence', a.confidence,
            'basis', a.basis,
            'classification', a.classification
        )) FILTER (WHERE a.id IS NOT NULL),
        '[]'::json
    ) AS current_assertions
FROM nodes n
LEFT JOIN edges eo ON eo.source_id = n.id AND eo.archived_at IS NULL
LEFT JOIN edges ei ON ei.target_id = n.id AND ei.archived_at IS NULL
LEFT JOIN current_valid_assertions a ON a.subject_node_id = n.id
WHERE n.archived_at IS NULL
GROUP BY n.id, n.node_type, n.label, n.properties;
