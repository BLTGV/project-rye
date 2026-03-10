SET search_path = rye, public, pg_catalog;

INSERT INTO public.demo_orgs (
    org_code,
    legal_name,
    industry,
    is_active
)
SELECT
    payload->'record'->>'org_code',
    payload->'record'->>'legal_name',
    payload->'record'->>'industry',
    (payload->'record'->>'is_active')::boolean
FROM public.demo_tabular_mapped_records
WHERE scenario = 'org-profiles-one-to-many'
  AND payload->>'destination_table' = 'demo_orgs'
ON CONFLICT (org_code) DO UPDATE
SET legal_name = EXCLUDED.legal_name,
    industry = EXCLUDED.industry,
    is_active = EXCLUDED.is_active;

INSERT INTO public.demo_locations (
    location_code,
    org_code,
    location_type,
    street,
    city,
    state
)
SELECT
    payload->'record'->>'location_code',
    payload->'record'->>'org_code',
    payload->'record'->>'location_type',
    payload->'record'->>'street',
    payload->'record'->>'city',
    payload->'record'->>'state'
FROM public.demo_tabular_mapped_records
WHERE scenario = 'org-profiles-one-to-many'
  AND payload->>'destination_table' = 'demo_locations'
ON CONFLICT (location_code) DO UPDATE
SET org_code = EXCLUDED.org_code,
    location_type = EXCLUDED.location_type,
    street = EXCLUDED.street,
    city = EXCLUDED.city,
    state = EXCLUDED.state;
