-- Agent-guided onboarding policy helpers.
--
-- These helpers keep setup knowledge convention-based on onboarding scopes.
-- They do not add new core tables. They standardize the policies that fresh
-- agents need most: reusable conventions, source-of-truth policy, and
-- process-improvement cycles.

SET search_path = rye, pg_catalog, public;

CREATE OR REPLACE FUNCTION rye_slugify_key(p_value text) RETURNS text
SET search_path = rye, pg_catalog
AS $$
    SELECT nullif(
        regexp_replace(
            regexp_replace(lower(trim(coalesce(p_value, ''))), '[^a-z0-9]+', '_', 'g'),
            '^_+|_+$',
            '',
            'g'
        ),
        ''
    );
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION register_scope_convention(
    p_scope_id uuid,
    p_label text,
    p_description text DEFAULT NULL,
    p_aliases text[] DEFAULT '{}'::text[],
    p_use_when text DEFAULT NULL,
    p_avoid_when text DEFAULT NULL,
    p_status text DEFAULT 'proposed',
    p_owning_plugin_id text DEFAULT NULL,
    p_actor text DEFAULT NULL,
    p_assertion_key text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_id uuid;
    v_key text;
    v_label text;
    v_status text;
BEGIN
    v_label := nullif(trim(p_label), '');
    IF v_label IS NULL THEN
        RAISE EXCEPTION 'label is required';
    END IF;

    v_status := lower(coalesce(nullif(trim(p_status), ''), 'proposed'));
    IF NOT (v_status = ANY(ARRAY[
        'observed',
        'proposed',
        'accepted',
        'deprecated',
        'plugin_owned'
    ])) THEN
        RAISE EXCEPTION 'Unsupported convention status: %', p_status;
    END IF;

    v_key := coalesce(rye_slugify_key(p_assertion_key), rye_slugify_key(v_label));
    IF v_key IS NULL THEN
        RAISE EXCEPTION 'assertion key could not be derived from label';
    END IF;

    v_assertion_id := record_scope_policy(
        p_scope_id      := p_scope_id,
        p_policy_type   := 'convention_registry',
        p_assertion_key := v_key,
        p_claim         := jsonb_build_object(
            'label', v_label,
            'description', p_description,
            'aliases', to_jsonb(coalesce(p_aliases, '{}'::text[])),
            'use_when', p_use_when,
            'avoid_when', p_avoid_when,
            'status', v_status,
            'owning_plugin_id', nullif(trim(coalesce(p_owning_plugin_id, '')), '')
        ),
        p_actor         := p_actor
    );

    RETURN v_assertion_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_source_of_truth_policy(
    p_scope_id uuid,
    p_status_domain text,
    p_authoritative_source text,
    p_effective_at timestamptz DEFAULT NULL,
    p_review_gate text DEFAULT NULL,
    p_evidence_allowed text[] DEFAULT '{}'::text[],
    p_supersedes text DEFAULT NULL,
    p_notes text DEFAULT NULL,
    p_actor text DEFAULT NULL,
    p_assertion_key text DEFAULT NULL
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_id uuid;
    v_domain text;
    v_key text;
    v_source text;
BEGIN
    v_domain := nullif(trim(p_status_domain), '');
    v_source := nullif(trim(p_authoritative_source), '');

    IF v_domain IS NULL THEN
        RAISE EXCEPTION 'status_domain is required';
    END IF;

    IF v_source IS NULL THEN
        RAISE EXCEPTION 'authoritative_source is required';
    END IF;

    v_key := coalesce(rye_slugify_key(p_assertion_key), rye_slugify_key(v_domain));
    IF v_key IS NULL THEN
        RAISE EXCEPTION 'assertion key could not be derived from status_domain';
    END IF;

    v_assertion_id := record_scope_policy(
        p_scope_id      := p_scope_id,
        p_policy_type   := 'source_of_truth_policy',
        p_assertion_key := v_key,
        p_claim         := jsonb_build_object(
            'status_domain', v_domain,
            'authoritative_source', v_source,
            'effective_at', p_effective_at,
            'review_gate', p_review_gate,
            'evidence_allowed', to_jsonb(coalesce(p_evidence_allowed, '{}'::text[])),
            'supersedes', nullif(trim(coalesce(p_supersedes, '')), ''),
            'notes', p_notes
        ),
        p_actor         := p_actor
    );

    RETURN v_assertion_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_improvement_cycle(
    p_scope_id uuid,
    p_goal text,
    p_current_constraint text,
    p_exploit text[] DEFAULT '{}'::text[],
    p_subordinate text[] DEFAULT '{}'::text[],
    p_elevate text[] DEFAULT '{}'::text[],
    p_repeat_trigger text DEFAULT NULL,
    p_metrics jsonb DEFAULT '[]'::jsonb,
    p_next_constraint text DEFAULT NULL,
    p_actor text DEFAULT NULL,
    p_assertion_key text DEFAULT 'current'
) RETURNS uuid
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_assertion_id uuid;
    v_constraint text;
    v_goal text;
    v_key text;
BEGIN
    v_goal := nullif(trim(p_goal), '');
    v_constraint := nullif(trim(p_current_constraint), '');

    IF v_goal IS NULL THEN
        RAISE EXCEPTION 'goal is required';
    END IF;

    IF v_constraint IS NULL THEN
        RAISE EXCEPTION 'current_constraint is required';
    END IF;

    IF p_metrics IS NOT NULL AND jsonb_typeof(p_metrics) <> 'array' THEN
        RAISE EXCEPTION 'metrics must be a JSON array';
    END IF;

    v_key := coalesce(rye_slugify_key(p_assertion_key), 'current');

    v_assertion_id := record_scope_policy(
        p_scope_id      := p_scope_id,
        p_policy_type   := 'improvement_cycle',
        p_assertion_key := v_key,
        p_claim         := jsonb_build_object(
            'goal', v_goal,
            'Identify', v_constraint,
            'Exploit', to_jsonb(coalesce(p_exploit, '{}'::text[])),
            'Subordinate', to_jsonb(coalesce(p_subordinate, '{}'::text[])),
            'Elevate', to_jsonb(coalesce(p_elevate, '{}'::text[])),
            'Repeat', p_repeat_trigger,
            'metrics', coalesce(p_metrics, '[]'::jsonb),
            'next_constraint', nullif(trim(coalesce(p_next_constraint, '')), '')
        ),
        p_actor         := p_actor
    );

    PERFORM record_scope_policy(
        p_scope_id      := p_scope_id,
        p_policy_type   := 'process_constraint',
        p_assertion_key := v_key,
        p_claim         := jsonb_build_object(
            'goal', v_goal,
            'current_constraint', v_constraint,
            'next_constraint', nullif(trim(coalesce(p_next_constraint, '')), ''),
            'metrics', coalesce(p_metrics, '[]'::jsonb)
        ),
        p_actor         := p_actor
    );

    RETURN v_assertion_id;
END;
$$ LANGUAGE plpgsql;
