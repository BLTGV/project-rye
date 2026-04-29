SET search_path = rye, public, pg_catalog;

INSERT INTO public.demo_invoices (
    invoice_number,
    customer_external_id,
    invoice_date,
    currency,
    line_count,
    total_amount
)
SELECT
    payload->'record'->>'invoice_number' AS invoice_number,
    payload->'record'->>'customer_external_id' AS customer_external_id,
    (payload->'record'->>'invoice_date')::date AS invoice_date,
    payload->'record'->>'currency' AS currency,
    (payload->'record'->>'line_count')::integer AS line_count,
    (payload->'record'->>'total_amount')::numeric(12,2) AS total_amount
FROM public.demo_tabular_mapped_records
WHERE scenario = 'invoice-lines-many-to-one'
  AND payload->>'destination_table' = 'demo_invoices'
ON CONFLICT (invoice_number) DO UPDATE
SET customer_external_id = EXCLUDED.customer_external_id,
    invoice_date = EXCLUDED.invoice_date,
    currency = EXCLUDED.currency,
    line_count = EXCLUDED.line_count,
    total_amount = EXCLUDED.total_amount;

INSERT INTO public.demo_invoice_lines (
    invoice_number,
    line_number,
    sku,
    description,
    quantity,
    unit_price
)
SELECT
    payload->'record'->>'invoice_number',
    (payload->'record'->>'line_number')::integer,
    payload->'record'->>'sku',
    payload->'record'->>'description',
    (payload->'record'->>'quantity')::integer,
    (payload->'record'->>'unit_price')::numeric(12,2)
FROM public.demo_tabular_mapped_records
WHERE scenario = 'invoice-lines-many-to-one'
  AND payload->>'destination_table' = 'demo_invoice_lines'
ON CONFLICT (invoice_number, line_number) DO UPDATE
SET sku = EXCLUDED.sku,
    description = EXCLUDED.description,
    quantity = EXCLUDED.quantity,
    unit_price = EXCLUDED.unit_price;
