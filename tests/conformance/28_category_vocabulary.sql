-- Category vocabulary: rye_categories() and describe_category().
-- Contract: contracts/category-vocabulary.md

SET search_path = rye, public, pg_catalog;

BEGIN;

DO $$
DECLARE
    v_answer jsonb;
    v_candidate uuid;
    v_category jsonb;
    v_gadget uuid;
    v_scope uuid;
    v_widget uuid;
    v_widget_plain uuid;
    v_widget_second uuid;
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:categories', true);

    v_scope := create_onboarding_scope(
        p_scope_key := 'conformance:categories',
        p_label     := 'Conformance Category Scope',
        p_purpose   := 'Validate the category vocabulary surface.',
        p_boundary  := '{"in_scope": ["conformance"], "out_of_scope": ["business_ops"]}',
        p_owner     := 'test:categories'
    );

    -- conformance_widget and conformance_declared are on here;
    -- conformance_gadget is deliberately left out so it must read as off.
    PERFORM record_scope_policy(
        p_scope_id    := v_scope,
        p_policy_type := 'allowed_node_types',
        p_claim       := '{"types": ["conformance_widget", "conformance_declared"]}',
        p_actor       := 'test:categories'
    );

    -- A plugin the scope enables declares a type with no rows anywhere.
    PERFORM enable_plugin_for_scope(
        p_scope_id  := v_scope,
        p_plugin_id := 'conformance-categories-plugin',
        p_label     := 'Conformance Categories',
        p_manifest  := '{"version": "0.0.1", "contributes": {"node_types": ["conformance_declared"]}}',
        p_actor     := 'test:categories'
    );

    -- A type in use, with observed properties and a relationship.
    INSERT INTO nodes (node_type, label, properties)
    VALUES ('conformance_widget', 'Widget One', '{"sku": "W-1", "color": "blue"}')
    RETURNING id INTO v_widget;

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('conformance_widget', 'Widget Two', '{"sku": "W-2", "color": "green"}')
    RETURNING id INTO v_widget_second;

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('conformance_widget', 'Widget Three', '{"sku": "W-3"}')
    RETURNING id INTO v_widget_plain;

    INSERT INTO nodes (node_type, label, properties)
    VALUES ('conformance_gadget', 'Gadget One', '{"serial": "G-1"}')
    RETURNING id INTO v_gadget;

    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('conformance_links_to', v_widget, v_gadget);

    -- ------------------------------------------------------------------
    -- A type in use: properties and relationships come from the rows.
    -- ------------------------------------------------------------------
    v_answer := rye_categories(v_scope);

    IF (v_answer->>'contract_version')::int <> 1 THEN
        RAISE EXCEPTION 'Expected contract_version 1, got %', v_answer->'contract_version';
    END IF;

    IF coalesce((v_answer->>'empty')::boolean, true) IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'Expected a populated scope answer to report empty false, got %', v_answer->'empty';
    END IF;

    IF v_answer->'scope'->>'scope_found' <> 'true'
       OR v_answer->'scope'->>'mode' <> 'explicit'
       OR v_answer->'scope'->>'scope_key' <> 'conformance:categories'
       OR v_answer->'scope'->>'type_policy' <> 'present'
    THEN
        RAISE EXCEPTION 'Unexpected scope block: %', v_answer->'scope';
    END IF;

    SELECT c INTO v_category
    FROM jsonb_array_elements(v_answer->'categories') AS c
    WHERE c->>'name' = 'conformance_widget';

    IF v_category IS NULL THEN
        RAISE EXCEPTION 'Expected conformance_widget in the category list';
    END IF;

    IF v_category->>'kind' <> 'node_type'
       OR (v_category->>'usage_count')::int <> 3
       OR v_category->>'enabled' <> 'on'
    THEN
        RAISE EXCEPTION 'Unexpected conformance_widget category: %', v_category;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_category->'properties'->'observed') AS p
        WHERE p->>'key' = 'sku'
          AND (p->>'count')::int = 3
          AND (p->>'frequency')::numeric = 1
    ) THEN
        RAISE EXCEPTION 'Expected observed property sku on every widget, got %',
            v_category->'properties'->'observed';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_category->'properties'->'observed') AS p
        WHERE p->>'key' = 'color'
          AND (p->>'count')::int = 2
          AND (p->>'frequency')::numeric = 0.667
    ) THEN
        RAISE EXCEPTION 'Expected observed property color on two of three widgets, got %',
            v_category->'properties'->'observed';
    END IF;

    IF v_category->'properties'->'required' <> '[]'::jsonb
       OR v_category->'properties'->>'required_source' <> 'none'
    THEN
        RAISE EXCEPTION 'Expected no declared required keys in v0.3, got %',
            v_category->'properties';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_category->'relationships'->'as_source') AS r
        WHERE r->>'edge_type' = 'conformance_links_to'
          AND (r->>'count')::int = 1
          AND r->'other_types' ? 'conformance_gadget'
    ) THEN
        RAISE EXCEPTION 'Expected widget to be the source of conformance_links_to, got %',
            v_category->'relationships';
    END IF;

    -- ------------------------------------------------------------------
    -- A type an enabled plugin declares, with no rows.
    -- ------------------------------------------------------------------
    SELECT c INTO v_category
    FROM jsonb_array_elements(v_answer->'categories') AS c
    WHERE c->>'name' = 'conformance_declared';

    IF v_category IS NULL THEN
        RAISE EXCEPTION 'Expected a plugin-declared type with no rows to be listed';
    END IF;

    IF (v_category->>'usage_count')::int <> 0
       OR v_category->'properties'->'observed' <> '[]'::jsonb
       OR v_category->'relationships'->'as_source' <> '[]'::jsonb
       OR v_category->>'enabled' <> 'on'
       OR NOT (v_category->'declared_by' ? 'conformance-categories-plugin')
    THEN
        RAISE EXCEPTION 'Unexpected conformance_declared category: %', v_category;
    END IF;

    -- ------------------------------------------------------------------
    -- A type the scope does not enable is listed as off, not omitted.
    -- ------------------------------------------------------------------
    SELECT c INTO v_category
    FROM jsonb_array_elements(v_answer->'categories') AS c
    WHERE c->>'name' = 'conformance_gadget';

    IF v_category IS NULL THEN
        RAISE EXCEPTION 'Expected a disabled type to be listed, not omitted';
    END IF;

    IF v_category->>'enabled' <> 'off'
       OR (v_category->>'usage_count')::int <> 1
    THEN
        RAISE EXCEPTION 'Expected conformance_gadget to read off, got %', v_category;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_category->'relationships'->'as_target') AS r
        WHERE r->>'edge_type' = 'conformance_links_to'
          AND r->'other_types' ? 'conformance_widget'
    ) THEN
        RAISE EXCEPTION 'Expected gadget to be the target of conformance_links_to, got %',
            v_category->'relationships';
    END IF;

    -- A disabled type is exactly what validate_candidate_against_scope refuses.
    IF coalesce(
        (validate_candidate_against_scope(v_scope, 'node', 'conformance_gadget')->>'valid')::boolean,
        true
    ) IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'Expected the scope to refuse a category reported as off';
    END IF;

    -- ------------------------------------------------------------------
    -- An unknown scope id answers empty rather than raising.
    -- ------------------------------------------------------------------
    v_answer := rye_categories('ffffffff-ffff-4fff-8fff-ffffffffffff'::uuid);

    IF v_answer->'categories' <> '[]'::jsonb
       OR (v_answer->>'category_count')::int <> 0
       OR (v_answer->>'empty')::boolean IS DISTINCT FROM true
       OR v_answer->'scope'->>'scope_found' <> 'false'
       OR v_answer->'scope'->>'mode' <> 'explicit'
       OR v_answer->'scope'->>'requested_scope_id' <> 'ffffffff-ffff-4fff-8fff-ffffffffffff'
    THEN
        RAISE EXCEPTION 'Expected an unknown scope to answer empty, got %', v_answer;
    END IF;

    -- ------------------------------------------------------------------
    -- A description written through describe_category is visible next call.
    -- ------------------------------------------------------------------
    PERFORM describe_category(
        p_node_type   := 'conformance_widget',
        p_description := 'A widget as this conformance scope means it.',
        p_scope_id    := v_scope,
        p_actor       := 'test:categories'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM nodes
        WHERE node_type = 'category'
          AND external_source = 'rye_category'
          AND external_id = 'conformance_widget'
          AND archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Expected describe_category() to create the category node';
    END IF;

    v_answer := rye_categories(v_scope);

    SELECT c INTO v_category
    FROM jsonb_array_elements(v_answer->'categories') AS c
    WHERE c->>'name' = 'conformance_widget';

    IF v_category->>'description' <> 'A widget as this conformance scope means it.' THEN
        RAISE EXCEPTION 'Expected the recorded description on the next call, got %',
            v_category->'description';
    END IF;

    IF v_category->'description_source'->>'assertion_key' <> v_scope::text THEN
        RAISE EXCEPTION 'Expected the description keyed by the scope uuid, got %',
            v_category->'description_source';
    END IF;

    -- The category node stands for a category; it is also an ordinary node
    -- type, so 'category' itself is now in use.
    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_answer->'categories') AS c
        WHERE c->>'name' = 'category'
    ) THEN
        RAISE EXCEPTION 'Expected the category node type itself to be in use';
    END IF;

    -- ------------------------------------------------------------------
    -- Under review, an unaccepted description stays invisible until accepted.
    -- ------------------------------------------------------------------
    PERFORM record_scope_policy(
        p_scope_id    := v_scope,
        p_policy_type := 'review_policy',
        p_claim       := '{"review_policy": "strict"}',
        p_actor       := 'test:categories'
    );

    v_candidate := describe_category(
        p_node_type   := 'conformance_gadget',
        p_description := 'A gadget as this conformance scope means it.',
        p_scope_id    := v_scope,
        p_actor       := 'test:categories'
    );

    IF NOT EXISTS (
        SELECT 1 FROM assertions WHERE id = v_candidate AND status = 'candidate'
    ) THEN
        RAISE EXCEPTION 'Expected a reviewing scope to hold the description as a candidate';
    END IF;

    v_answer := rye_categories(v_scope);

    SELECT c INTO v_category
    FROM jsonb_array_elements(v_answer->'categories') AS c
    WHERE c->>'name' = 'conformance_gadget';

    IF v_category->'description' IS DISTINCT FROM 'null'::jsonb
       OR v_category->'description_source' IS DISTINCT FROM 'null'::jsonb
    THEN
        RAISE EXCEPTION 'Expected an unaccepted description to stay invisible, got %', v_category;
    END IF;

    PERFORM accept_assertion(
        p_assertion_id := v_candidate,
        p_actor        := 'test:categories'
    );

    v_answer := rye_categories(v_scope);

    SELECT c INTO v_category
    FROM jsonb_array_elements(v_answer->'categories') AS c
    WHERE c->>'name' = 'conformance_gadget';

    IF v_category->>'description' <> 'A gadget as this conformance scope means it.' THEN
        RAISE EXCEPTION 'Expected the accepted description to become visible, got %',
            v_category->'description';
    END IF;

    -- ------------------------------------------------------------------
    -- Nothing in the graph: an empty list, and it says so, rather than an
    -- error. Every membership source is empty once no node is live, so this
    -- is done last; the outer ROLLBACK puts the rows back.
    -- ------------------------------------------------------------------
    UPDATE nodes SET archived_at = now() WHERE archived_at IS NULL;

    v_answer := rye_categories();

    IF v_answer->'categories' <> '[]'::jsonb
       OR (v_answer->>'category_count')::int <> 0
       OR (v_answer->>'empty')::boolean IS DISTINCT FROM true
       OR v_answer->'scope'->>'mode' <> 'none'
       OR v_answer->'scope'->>'scope_found' <> 'false'
    THEN
        RAISE EXCEPTION 'Expected an empty graph to answer an empty list, got %', v_answer;
    END IF;
END
$$;

ROLLBACK;
