SET search_path = rye, public, pg_catalog;

INSERT INTO public.demo_contacts (
    external_id,
    full_name,
    email,
    lifecycle,
    created_at
)
SELECT
    payload->'record'->>'external_id',
    payload->'record'->>'full_name',
    payload->'record'->>'email',
    payload->'record'->>'lifecycle',
    NULLIF(payload->'record'->>'created_at', '')::timestamptz
FROM public.demo_tabular_mapped_records
WHERE scenario = 'contacts-basic'
  AND payload->>'destination_table' = 'demo_contacts'
ON CONFLICT (external_id) DO UPDATE
SET full_name = EXCLUDED.full_name,
    email = EXCLUDED.email,
    lifecycle = EXCLUDED.lifecycle,
    created_at = EXCLUDED.created_at;
