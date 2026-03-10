SET search_path = rye, public, pg_catalog;

SELECT rye.link_record(
    p_source_schema := 'public',
    p_source_table := 'demo_intake_stage',
    p_source_id := s.id::text,
    p_node_type := COALESCE(s.payload->>'node_type', 'rye_tabular_intake_stage_row'),
    p_label := COALESCE(s.payload->>'label', s.scenario || ' stage row ' || s.id::text),
    p_properties := COALESCE(s.payload->'properties', '{}'::jsonb) || jsonb_build_object(
        'scenario', s.scenario,
        'stage_kind', COALESCE(s.payload->>'kind', 'rye_stage_record')
    ),
    p_source_id_type := 'int'
)
FROM public.demo_intake_stage s
WHERE NOT EXISTS (
    SELECT 1
    FROM rye.node_source_map nsm
    WHERE nsm.source_schema = 'public'
      AND nsm.source_table = 'demo_intake_stage'
      AND nsm.source_id = s.id::text
);
