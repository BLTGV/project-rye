SET search_path = rye, public, pg_catalog;

CREATE TABLE IF NOT EXISTS public.demo_tabular_source_rows (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scenario text NOT NULL,
    payload jsonb NOT NULL,
    loaded_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.demo_tabular_mapped_records (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scenario text NOT NULL,
    payload jsonb NOT NULL,
    loaded_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.demo_intake_stage (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scenario text NOT NULL,
    payload jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.demo_contacts (
    external_id text PRIMARY KEY,
    full_name text NOT NULL,
    email text,
    lifecycle text,
    created_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.demo_orgs (
    org_code text PRIMARY KEY,
    legal_name text NOT NULL,
    industry text,
    is_active boolean NOT NULL
);

CREATE TABLE IF NOT EXISTS public.demo_locations (
    location_code text PRIMARY KEY,
    org_code text NOT NULL REFERENCES public.demo_orgs(org_code) ON DELETE CASCADE,
    location_type text NOT NULL,
    street text,
    city text,
    state text
);

CREATE TABLE IF NOT EXISTS public.demo_invoices (
    invoice_number text PRIMARY KEY,
    customer_external_id text NOT NULL,
    invoice_date date NOT NULL,
    currency text NOT NULL,
    line_count integer NOT NULL,
    total_amount numeric(12,2) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.demo_invoice_lines (
    invoice_number text NOT NULL REFERENCES public.demo_invoices(invoice_number) ON DELETE CASCADE,
    line_number integer NOT NULL,
    sku text NOT NULL,
    description text,
    quantity integer NOT NULL,
    unit_price numeric(12,2) NOT NULL,
    PRIMARY KEY (invoice_number, line_number)
);
