-- Core Model v2: distillation, evidence, gaps, registry, and confidence.

SET search_path = rye, public, pg_catalog;
SELECT set_config('app.current_role', 'admin', false);
SELECT set_config('app.current_user_id', 'conformance:core-model-v2', false);
SELECT set_config('app.current_teams', 'alpha,beta', false);

CREATE TEMP TABLE v2_ids (
    key text PRIMARY KEY,
    id uuid NOT NULL
);

DO $$
DECLARE
    v_artifact uuid;
    v_digest uuid;
    v_event uuid;
    v_mixed_a uuid;
    v_mixed_b uuid;
    v_node uuid;
    v_source_a uuid;
    v_source_b uuid;
BEGIN
    INSERT INTO nodes (node_type, label, attrs)
    VALUES (
        'project',
        'V2 Digest Subject',
        '{"teams":["alpha"],"classification":"internal"}'
    )
    RETURNING id INTO v_node;
    INSERT INTO v2_ids VALUES ('digest_node', v_node);

    INSERT INTO nodes (node_type, label, attrs)
    VALUES (
        'source_item',
        'V2 Source A',
        '{"teams":["alpha"],"classification":"internal"}'
    )
    RETURNING id INTO v_mixed_a;
    INSERT INTO nodes (node_type, label, attrs)
    VALUES (
        'source_item',
        'V2 Source B',
        '{"teams":["alpha"],"classification":"confidential"}'
    )
    RETURNING id INTO v_mixed_b;

    v_source_a := record_assertion(
        p_assertion_type := 'source_claim',
        p_assertion_key := 'a',
        p_subject_node_id := v_mixed_a,
        p_claim := '{"value":"a"}',
        p_basis := 'assumed',
        p_classification := 'internal'
    );
    v_source_b := record_assertion(
        p_assertion_type := 'source_claim',
        p_assertion_key := 'b',
        p_subject_node_id := v_mixed_b,
        p_claim := '{"value":"b"}',
        p_basis := 'assumed',
        p_classification := 'confidential'
    );
    INSERT INTO v2_ids VALUES ('source_a', v_source_a), ('source_b', v_source_b);

    BEGIN
        PERFORM record_distillation(
            p_subject_node_id := v_node,
            p_subject_edge_id := NULL,
            p_assertion_key := 'empty',
            p_claim := '{"summary":"empty"}',
            p_source_assertion_ids := '{}'::uuid[],
            p_source_event_ids := '{}'::uuid[],
            p_agent := 'conformance:core-model-v2'
        );
        RAISE EXCEPTION 'Expected empty-source distillation refusal';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'record_distillation requires at least one source assertion%' THEN
            RAISE;
        END IF;
    END;

    v_digest := record_distillation(
        p_subject_node_id := v_node,
        p_subject_edge_id := NULL,
        p_assertion_key := 'overview',
        p_claim := '{"summary":"A and B"}',
        p_source_assertion_ids := ARRAY[v_source_a, v_source_b],
        p_source_event_ids := '{}'::uuid[],
        p_agent := 'conformance:core-model-v2'
    );
    INSERT INTO v2_ids VALUES ('digest', v_digest);

    IF (SELECT classification FROM assertions WHERE id = v_digest) <> 'confidential' THEN
        RAISE EXCEPTION 'Distillation did not propagate maximum classification';
    END IF;
    IF (SELECT count(*) FROM assertion_evidence
        WHERE assertion_id = v_digest AND kind = 'derivation') <> 2
    THEN
        RAISE EXCEPTION 'Distillation did not write derivation evidence';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM events
        WHERE event_type = 'distillation'
          AND properties->>'digest_assertion_id' = v_digest::text
    ) THEN
        RAISE EXCEPTION 'Distillation event missing';
    END IF;

    v_artifact := record_artifact(
        p_artifact_type := 'digest_narrative',
        p_content := jsonb_build_object(
            'digest_assertion_id', v_digest,
            'narrative', 'A and B'
        ),
        p_source_node_id := v_node
    );
    IF (SELECT attrs->>'classification' FROM artifacts WHERE id = v_artifact)
       <> 'confidential'
    THEN
        RAISE EXCEPTION 'Digest narrative artifact did not inherit classification';
    END IF;
    INSERT INTO v2_ids VALUES ('digest_artifact', v_artifact);

    -- A fact asserted after the digest watermark makes it stale.
    INSERT INTO assertions (
        assertion_type,
        assertion_key,
        subject_node_id,
        claim,
        asserted_at,
        basis
    ) VALUES (
        'project_update',
        'after-digest',
        v_node,
        '{"value":"new"}',
        clock_timestamp() + interval '1 millisecond',
        'assumed'
    );

    IF NOT EXISTS (
        SELECT 1 FROM stale_digests
        WHERE digest_assertion_id = v_digest
          AND newer_subject_assertion
    ) THEN
        RAISE EXCEPTION 'stale_digests missed newer subject assertion';
    END IF;

    -- Mixed team populations have no common reader and must be refused.
    INSERT INTO nodes (node_type, label, attrs)
    VALUES (
        'source_item',
        'V2 Mixed Beta',
        '{"teams":["beta"],"classification":"confidential"}'
    )
    RETURNING id INTO v_mixed_b;
    v_source_b := record_assertion(
        p_assertion_type := 'source_claim',
        p_assertion_key := 'mixed-beta',
        p_subject_node_id := v_mixed_b,
        p_claim := '{"value":"beta"}',
        p_basis := 'assumed',
        p_classification := 'confidential'
    );

    BEGIN
        PERFORM record_distillation(
            p_subject_node_id := v_node,
            p_subject_edge_id := NULL,
            p_assertion_key := 'mixed',
            p_claim := '{"summary":"mixed"}',
            p_source_assertion_ids := ARRAY[v_source_a, v_source_b],
            p_source_event_ids := '{}'::uuid[],
            p_agent := 'conformance:core-model-v2'
        );
        RAISE EXCEPTION 'Expected mixed-access distillation refusal';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'Cannot derive assertion from mixed-access sources%' THEN
            RAISE;
        END IF;
    END;
END;
$$;

SELECT set_config('app.current_role', 'team_member', false);
SELECT set_config('app.current_user_id', 'conformance:artifact-reader', false);
SELECT set_config('app.current_teams', 'alpha', false);
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM artifacts
        WHERE id = (SELECT id FROM v2_ids WHERE key = 'digest_artifact')
    ) THEN
        RAISE EXCEPTION 'Classified digest narrative leaked through artifact RLS';
    END IF;
END;
$$;
SELECT set_config('app.current_role', 'admin', false);
SELECT set_config('app.current_user_id', 'conformance:core-model-v2', false);
SELECT set_config('app.current_teams', 'alpha,beta', false);

DO $$
DECLARE
    v_plugin uuid;
    v_scope uuid;
BEGIN
    INSERT INTO nodes (node_type, label, external_id, external_source)
    VALUES ('onboarding_scope', 'V2 Registry Scope', gen_random_uuid()::text, 'conformance:v2')
    RETURNING id INTO v_scope;
    INSERT INTO nodes (node_type, label, external_id, external_source)
    VALUES ('plugin', 'V2 Registry Plugin', 'v2-registry-plugin', 'conformance:v2')
    RETURNING id INTO v_plugin;
    INSERT INTO edges (edge_type, source_id, target_id)
    VALUES ('scope_enables_plugin', v_scope, v_plugin);

    PERFORM record_assertion(
        p_assertion_type := 'registry_entry',
        p_assertion_key := 'registry_precedence:plugin',
        p_subject_node_id := v_plugin,
        p_claim := '{"value":"plugin","layer":"plugin"}',
        p_basis := 'assumed'
    );
    IF registry_value('registry_precedence:plugin', v_scope) <> '"plugin"'::jsonb THEN
        RAISE EXCEPTION 'registry_value did not resolve plugin default';
    END IF;

    PERFORM record_assertion(
        p_assertion_type := 'registry_entry',
        p_assertion_key := 'registry_precedence:plugin',
        p_subject_node_id := v_scope,
        p_claim := '{"value":"scope","layer":"scope"}',
        p_basis := 'assumed'
    );
    IF registry_value('registry_precedence:plugin', v_scope) <> '"scope"'::jsonb THEN
        RAISE EXCEPTION 'registry_value did not prefer scope override';
    END IF;
END;
$$;

DO $$
DECLARE
    v_answer uuid;
    v_gap uuid;
    v_resolved uuid;
BEGIN
    v_gap := record_assertion(
        p_assertion_type := 'knowledge_gap',
        p_assertion_key := 'owner',
        p_subject_node_id := (SELECT id FROM v2_ids WHERE key = 'digest_node'),
        p_claim := '{"question":"Who owns this?","status":"open"}',
        p_basis := 'assumed'
    );
    v_answer := record_assertion(
        p_assertion_type := 'project_owner',
        p_assertion_key := 'default',
        p_subject_node_id := (SELECT id FROM v2_ids WHERE key = 'digest_node'),
        p_claim := '{"owner":"Avery"}',
        p_basis := 'assumed'
    );

    PERFORM resolve_knowledge_gap(v_gap, v_answer, 'conformance:core-model-v2');
    SELECT superseded_by INTO v_resolved FROM assertions WHERE id = v_gap;

    IF v_resolved IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM assertions
           WHERE id = v_resolved
             AND assertion_type = 'knowledge_gap'
             AND assertion_key = 'owner'
             AND claim->>'answer_assertion_id' = v_answer::text
       )
    THEN
        RAISE EXCEPTION 'resolve_knowledge_gap did not close its own tuple';
    END IF;
    IF EXISTS (SELECT 1 FROM open_gaps WHERE id IN (v_gap, v_resolved)) THEN
        RAISE EXCEPTION 'Resolved knowledge gap remained open';
    END IF;
END;
$$;

DO $$
DECLARE
    v_assertion uuid;
    v_event uuid;
    v_evidence uuid;
    v_hidden uuid;
    v_subject uuid;
    v_updated int;
BEGIN
    INSERT INTO nodes (node_type, label, attrs)
    VALUES ('project', 'V2 Evidence Subject', '{"classification":"public"}')
    RETURNING id INTO v_subject;
    INSERT INTO nodes (node_type, label, attrs)
    VALUES (
        'source_item',
        'V2 Hidden Evidence End',
        '{"teams":["beta"],"classification":"internal"}'
    )
    RETURNING id INTO v_hidden;

    v_event := record_event(
        p_event_type := 'hidden_source',
        p_summary := 'Hidden evidence event',
        p_participant_ids := ARRAY[v_hidden],
        p_participant_roles := ARRAY['source'],
        p_actor := 'conformance:core-model-v2'
    );
    v_assertion := record_assertion(
        p_assertion_type := 'evidence_visibility',
        p_subject_node_id := v_subject,
        p_claim := '{"value":"visible assertion"}',
        p_basis := 'reported',
        p_evidence := ARRAY[
            jsonb_build_object('kind', 'source', 'event_id', v_event)
        ]
    );
    SELECT id INTO v_evidence
    FROM assertion_evidence
    WHERE assertion_id = v_assertion;

    PERFORM set_config('app.current_role', 'viewer', false);
    PERFORM set_config('app.current_teams', 'alpha', false);
    IF EXISTS (SELECT 1 FROM assertion_evidence WHERE id = v_evidence) THEN
        RAISE EXCEPTION 'Evidence RLS did not enforce referenced-event visibility';
    END IF;

    PERFORM set_config('app.current_role', 'admin', false);
    PERFORM set_config('app.current_teams', 'alpha,beta', false);
    UPDATE assertion_evidence SET attrs = '{"tampered":true}' WHERE id = v_evidence;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated <> 0 THEN
        RAISE EXCEPTION 'Evidence UPDATE was not denied';
    END IF;
    DELETE FROM assertion_evidence WHERE id = v_evidence;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated <> 0 THEN
        RAISE EXCEPTION 'Evidence DELETE was not denied';
    END IF;

    BEGIN
        INSERT INTO assertion_evidence (
            assertion_id, kind, event_id, source_assertion_id
        ) VALUES (
            v_assertion, 'source', v_event, v_assertion
        );
        RAISE EXCEPTION 'Expected assertion_evidence reference-shape CHECK failure';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
END;
$$;

DO $$
DECLARE
    v_assertion uuid;
    v_duplicate_event uuid;
    v_event uuid;
    v_future uuid;
    v_subject uuid;
    v_witness_one uuid;
    v_witness_two uuid;
    v_weight numeric;
BEGIN
    INSERT INTO nodes (node_type, label, attrs)
    VALUES ('project', 'V2 Confidence Subject', '{"classification":"public"}')
    RETURNING id INTO v_subject;
    INSERT INTO nodes (node_type, label, attrs)
    VALUES ('source', 'Witness One', '{"classification":"public"}')
    RETURNING id INTO v_witness_one;
    INSERT INTO nodes (node_type, label, attrs)
    VALUES ('source', 'Witness Two', '{"classification":"public"}')
    RETURNING id INTO v_witness_two;

    v_event := record_event(
        p_event_type := 'source_report',
        p_summary := 'Initial observed report',
        p_participant_ids := ARRAY[v_subject, v_witness_one],
        p_participant_roles := ARRAY['subject', 'witness']
    );
    v_assertion := record_assertion(
        p_assertion_type := 'confidence_test',
        p_subject_node_id := v_subject,
        p_claim := '{"value":"supported"}',
        p_basis := 'observed',
        p_evidence := ARRAY[
            jsonb_build_object(
                'kind', 'source',
                'event_id', v_event,
                'witness_node_id', v_witness_one
            )
        ]
    );

    v_duplicate_event := record_event(
        p_event_type := 'corroboration',
        p_summary := 'Duplicate witness corroboration',
        p_participant_ids := ARRAY[v_subject, v_witness_one],
        p_participant_roles := ARRAY['subject', 'witness']
    );
    PERFORM append_assertion_evidence(v_assertion, ARRAY[
        jsonb_build_object(
            'kind', 'corroboration',
            'event_id', v_duplicate_event,
            'witness_node_id', v_witness_one
        )
    ]);
    v_event := record_event(
        p_event_type := 'corroboration',
        p_summary := 'Independent witness corroboration',
        p_participant_ids := ARRAY[v_subject, v_witness_two],
        p_participant_roles := ARRAY['subject', 'witness']
    );
    PERFORM append_assertion_evidence(v_assertion, ARRAY[
        jsonb_build_object(
            'kind', 'corroboration',
            'event_id', v_event,
            'witness_node_id', v_witness_two
        )
    ]);

    IF NOT EXISTS (
        SELECT 1 FROM assertion_evidence
        WHERE assertion_id = v_assertion
          AND event_id = v_duplicate_event
          AND attrs->>'independent' = 'false'
    ) THEN
        RAISE EXCEPTION 'Duplicate witness was not flagged non-independent';
    END IF;

    PERFORM record_assertion(
        p_assertion_type := 'confidence_test',
        p_subject_node_id := v_subject,
        p_claim := '{"value":"competitor"}',
        p_status := 'candidate',
        p_basis := 'assumed'
    );

    SELECT effective_confidence INTO v_weight
    FROM current_assertions_weighted
    WHERE id = v_assertion;
    IF abs(v_weight - 0.912) > 0.0001 THEN
        RAISE EXCEPTION 'Unexpected null-confidence/no-half-life result: %', v_weight;
    END IF;

    PERFORM record_assertion(
        p_assertion_type := 'registry_entry',
        p_assertion_key := 'half_life:future_signal',
        p_subject_node_id := (
            SELECT id FROM nodes
            WHERE external_source = 'rye_registry' AND external_id = 'core'
        ),
        p_claim := '{"value":"1 day","layer":"core"}',
        p_basis := 'assumed'
    );
    INSERT INTO assertions (
        assertion_type,
        assertion_key,
        subject_node_id,
        claim,
        confidence,
        asserted_at,
        basis
    ) VALUES (
        'future_signal',
        'default',
        v_subject,
        '{"value":"future"}',
        0.5,
        clock_timestamp() + interval '1 day',
        'assumed'
    )
    RETURNING id INTO v_future;

    SELECT effective_confidence(a) INTO v_weight
    FROM assertions a
    WHERE id = v_future;
    IF abs(v_weight - 0.5) > 0.0001 THEN
        RAISE EXCEPTION 'Negative age was not clamped to zero';
    END IF;
END;
$$;

DO $$
DECLARE
    v_digest uuid := (SELECT id FROM v2_ids WHERE key = 'digest');
    v_source uuid := (SELECT id FROM v2_ids WHERE key = 'source_a');
BEGIN
    PERFORM supersede_assertion(
        p_old_assertion_id := v_source,
        p_new_assertion_type := 'source_claim',
        p_new_subject_node_id := (SELECT subject_node_id FROM assertions WHERE id = v_source),
        p_new_subject_edge_id := NULL,
        p_new_claim := '{"value":"overturned"}',
        p_new_assertion_key := 'a',
        p_new_basis := 'assumed'
    );

    IF NOT EXISTS (
        SELECT 1 FROM stale_digests
        WHERE digest_assertion_id = v_digest
          AND overturned_source
    ) THEN
        RAISE EXCEPTION 'stale_digests missed overturned derivation source';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM (VALUES
            ('review_queue'),
            ('stale_digests'),
            ('open_gaps'),
            ('assertion_support'),
            ('competing_candidates'),
            ('current_assertions_weighted')
        ) required(view_name)
        WHERE NOT EXISTS (
            SELECT 1
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'rye'
              AND c.relname = required.view_name
              AND 'security_invoker=true' = ANY(coalesce(c.reloptions, '{}'::text[]))
        )
    ) THEN
        RAISE EXCEPTION 'One or more v2 views are not security_invoker';
    END IF;
END;
$$;
