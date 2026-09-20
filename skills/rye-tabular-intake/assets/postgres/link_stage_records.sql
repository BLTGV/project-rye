SET search_path = rye, public, pg_catalog;

-- link_record() writes nodes and node_source_map, so this session needs a role
-- that may write. A session with no role set writes nothing, and no role is
-- hard-coded here: pass one in.
--
--   psql "$DATABASE_URL" -v rye_role=team_member -f link_stage_records.sql
--
-- Through a SQL tool that has no psql variables, replace :'rye_role' with the
-- role in quotes. set_config() rather than SET, because SET app.current_role
-- fails through some of those tools.
SELECT set_config('app.current_role', :'rye_role', false) IS NOT NULL AS role_set;
SELECT set_config('app.current_user_id', 'rye-tabular-intake:' || :'rye_role', false) IS NOT NULL AS user_set;

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
