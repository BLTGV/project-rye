-- Settlement lookup: rye_settlers().
-- Contract: contracts/sql-surface.md, section "Settlement lookup".
-- Work item: work/002-who-may-settle.md.
--
-- Invented names only: Bob, John, Priya, Dana, Mara.

SET search_path = rye, public, pg_catalog;

BEGIN;

DO $$
DECLARE
    v_answer      jsonb;
    v_settler     jsonb;
    v_agent_id    uuid;
    v_agent_node  uuid;
    v_case        text;
    v_delegate    uuid;
    v_delegate_edge uuid;
    v_bot_two     uuid;
    v_bob         uuid;
    v_dana        uuid;
    v_domain      uuid;
    v_edge        uuid;
    v_john        uuid;
    v_mara        uuid;
    v_orphan      uuid;
    v_press       uuid;
    v_priya       uuid;
    v_then        timestamptz := now() - interval '30 days';
BEGIN
    PERFORM set_config('app.current_role', 'admin', true);
    PERFORM set_config('app.current_user_id', 'test:settlers', true);

    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('person', 'Bob', 'conformance_org', 'bob')
    RETURNING id INTO v_bob;

    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('person', 'John', 'conformance_org', 'john')
    RETURNING id INTO v_john;

    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('person', 'Priya', 'conformance_org', 'priya')
    RETURNING id INTO v_priya;

    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('person', 'Dana', 'conformance_org', 'dana')
    RETURNING id INTO v_dana;

    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('person', 'Mara', 'conformance_org', 'mara')
    RETURNING id INTO v_mara;

    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('equipment', 'Press Line 3', 'conformance_org', 'press-line-3')
    RETURNING id INTO v_press;

    -- An area with an owner, and a second area with none.
    v_domain := ensure_knowledge_domain(
        p_domain_key    := 'conformance-settling',
        p_label         := 'Conformance Settling',
        p_purpose       := 'Validate the settlement lookup.',
        p_owner_node_id := v_dana
    );

    v_orphan := ensure_knowledge_domain(
        p_domain_key := 'conformance-settling-orphan',
        p_label      := 'Conformance Settling, Unowned',
        p_purpose    := 'An area nobody owns yet.'
    );

    -- ------------------------------------------------------------------
    -- A person settles claims about themselves, with no setup at all.
    -- ------------------------------------------------------------------
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'availability',
        p_speaker_id := v_john,
        p_domain_key := 'conformance-settling',
        p_speech_act := 'self_commitment'
    );

    IF (v_answer->>'contract_version')::int <> 1 THEN
        RAISE EXCEPTION 'Expected contract_version 1, got %', v_answer->'contract_version';
    END IF;

    IF (v_answer->>'advisory')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Expected the lookup to report itself advisory, got %', v_answer;
    END IF;

    IF v_answer->>'step' <> 'relationship'
       OR (v_answer->>'settler_count')::int <> 1
       OR v_answer->'settlers'->0->>'node_id' <> v_john::text
       OR v_answer->'settlers'->0->>'relationship' <> 'self'
       OR v_answer->'settlers'->0->>'kind' <> 'person'
       OR v_answer->'settlers'->0->>'ref' <> 'conformance_org:john'
       OR (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION 'Expected John to settle a claim about himself, got %', v_answer;
    END IF;

    IF v_answer->'claim'->>'assertion_type' <> 'availability'
       OR (v_answer->'claim'->>'speech_act_recognized')::boolean IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION 'Expected the claim block to echo the assertion type, got %', v_answer->'claim';
    END IF;

    -- ------------------------------------------------------------------
    -- A reporting line: John reports to Bob. Bob settles an expectation on
    -- John; John does not settle it himself.
    -- ------------------------------------------------------------------
    INSERT INTO edges (edge_type, source_id, target_id, effective_from)
    VALUES ('reports_to', v_john, v_bob, v_then)
    RETURNING id INTO v_edge;

    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'expectation',
        p_speaker_id := v_bob,
        p_domain_key := 'conformance-settling',
        p_speech_act := 'expectation'
    );

    IF v_answer->>'step' <> 'relationship'
       OR (v_answer->>'settler_count')::int <> 1
       OR v_answer->'settlers'->0->>'node_id' <> v_bob::text
       OR v_answer->'settlers'->0->>'relationship' <> 'manager'
       OR v_answer->'settlers'->0->>'edge_id' <> v_edge::text
       OR v_answer->'settlers'->0->>'edge_type' <> 'reports_to'
       OR (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION 'Expected Bob to settle an expectation on John, got %', v_answer;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_answer->'settlers') AS s(value)
        WHERE s.value->>'node_id' = v_john::text
    ) THEN
        RAISE EXCEPTION 'John must not settle an expectation set on him, got %', v_answer;
    END IF;

    -- John asking about his own expectation is told he may not settle it.
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'expectation',
        p_speaker_id := v_john,
        p_domain_key := 'conformance-settling',
        p_speech_act := 'expectation'
    );

    IF (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'Expected John not to be the settler of his own expectation, got %', v_answer->'speaker';
    END IF;

    -- ------------------------------------------------------------------
    -- The reporting line ends. Bob is no longer returned, and the lookup
    -- falls through to the owner of the area.
    -- ------------------------------------------------------------------
    UPDATE edges SET effective_to = now() - interval '1 day' WHERE id = v_edge;

    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'expectation',
        p_domain_key := 'conformance-settling',
        p_speech_act := 'expectation'
    );

    IF v_answer->>'step' <> 'area_owner'
       OR (v_answer->>'settler_count')::int <> 1
       OR v_answer->'settlers'->0->>'node_id' <> v_dana::text
       OR v_answer->'settlers'->0->>'via' <> 'area_owner'
       OR v_answer->'settlers'->0->>'domain_id' <> v_domain::text
    THEN
        RAISE EXCEPTION 'Expected an ended reporting line to fall through to the area owner, got %', v_answer;
    END IF;

    -- ------------------------------------------------------------------
    -- As of a date while the line was in effect, Bob is still the settler.
    -- The past answer is reconstructible.
    -- ------------------------------------------------------------------
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'expectation',
        p_domain_key := 'conformance-settling',
        p_speech_act := 'expectation',
        p_as_of      := now() - interval '10 days'
    );

    IF v_answer->>'step' <> 'relationship'
       OR v_answer->'settlers'->0->>'node_id' <> v_bob::text
    THEN
        RAISE EXCEPTION 'Expected an as-of date inside the line to return Bob, got %', v_answer;
    END IF;

    -- Before the line began, Bob is not a settler either.
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'expectation',
        p_domain_key := 'conformance-settling',
        p_speech_act := 'expectation',
        p_as_of      := now() - interval '90 days'
    );

    IF v_answer->>'step' <> 'area_owner' THEN
        RAISE EXCEPTION 'Expected an as-of date before the line to fall through, got %', v_answer;
    END IF;

    -- Put the line back in effect for the remaining cases.
    UPDATE edges SET effective_to = NULL WHERE id = v_edge;

    -- ------------------------------------------------------------------
    -- A claim about a thing is settled by whoever owns the thing.
    -- ------------------------------------------------------------------
    INSERT INTO edges (edge_type, source_id, target_id, effective_from)
    VALUES ('owns', v_priya, v_press, v_then);

    v_answer := rye_settlers(
        p_subject_id := v_press,
        p_claim_type := 'maintenance_window',
        p_speaker_id := v_priya,
        p_domain_key := 'conformance-settling',
        p_speech_act := 'statement_about_thing'
    );

    IF v_answer->>'step' <> 'relationship'
       OR (v_answer->>'settler_count')::int <> 1
       OR v_answer->'settlers'->0->>'node_id' <> v_priya::text
       OR v_answer->'settlers'->0->>'relationship' <> 'owner'
       OR v_answer->'settlers'->0->>'edge_type' <> 'owns'
       OR (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION 'Expected Priya to settle a claim about what she owns, got %', v_answer;
    END IF;

    -- ------------------------------------------------------------------
    -- Rule 0. A claim about the relationship itself has no relationship
    -- default: the area settles that a reporting line or an ownership
    -- exists, not either end of it.
    -- ------------------------------------------------------------------
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'reports_to',
        p_domain_key := 'conformance-settling'
    );

    IF v_answer->>'step' <> 'area_owner'
       OR v_answer->'settlers'->0->>'node_id' <> v_dana::text
    THEN
        RAISE EXCEPTION 'Expected a reports_to claim to be settled by the area owner, got %', v_answer;
    END IF;

    -- Even with a speech act that would otherwise select a relationship.
    v_answer := rye_settlers(
        p_subject_id := v_press,
        p_claim_type := 'owns',
        p_domain_key := 'conformance-settling',
        p_speech_act := 'statement_about_thing'
    );

    IF v_answer->>'step' <> 'area_owner'
       OR v_answer->'settlers'->0->>'node_id' <> v_dana::text
    THEN
        RAISE EXCEPTION 'Expected an owns claim to be settled by the area owner, got %', v_answer;
    END IF;

    -- ------------------------------------------------------------------
    -- Rule 1. The claim type carries the safety on its own. An expectation
    -- is set on a person by someone else, so the person it is set on is
    -- never its settler — whatever the speech act says, and above all when
    -- the optional speech act is not said at all. This is the one path that
    -- must never fail open: it is John's "no" winning because it was said
    -- last.
    -- ------------------------------------------------------------------
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'expectation',
        p_speaker_id := v_john,
        p_domain_key := 'conformance-settling'
    );

    IF v_answer->>'step' <> 'relationship'
       OR (v_answer->>'settler_count')::int <> 1
       OR v_answer->'settlers'->0->>'node_id' <> v_bob::text
       OR v_answer->'settlers'->0->>'relationship' <> 'manager'
       OR (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM false
    THEN
        RAISE EXCEPTION 'An expectation with no speech act must settle to the manager alone, got %', v_answer;
    END IF;

    -- A mislabelled speech act cannot open that door either.
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'expectation',
        p_speaker_id := v_john,
        p_domain_key := 'conformance-settling',
        p_speech_act := 'self_commitment'
    );

    IF v_answer->>'step' <> 'relationship'
       OR (v_answer->>'settler_count')::int <> 1
       OR v_answer->'settlers'->0->>'node_id' <> v_bob::text
       OR (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM false
       OR (v_answer->'claim'->>'speech_act_recognized')::boolean IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION 'A mislabelled expectation must still settle to the manager, got %', v_answer;
    END IF;

    -- Nor can a speech act nobody recognises.
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'expectation',
        p_speaker_id := v_john,
        p_domain_key := 'conformance-settling',
        p_speech_act := 'banana'
    );

    IF v_answer->>'step' <> 'relationship'
       OR (v_answer->>'settler_count')::int <> 1
       OR v_answer->'settlers'->0->>'node_id' <> v_bob::text
       OR (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM false
       OR (v_answer->'claim'->>'speech_act_recognized')::boolean IS DISTINCT FROM false
    THEN
        RAISE EXCEPTION 'An unrecognised speech act on an expectation must settle to the manager, got %', v_answer;
    END IF;

    -- The manager asking about the same expectation is told yes.
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'expectation',
        p_speaker_id := v_bob,
        p_domain_key := 'conformance-settling'
    );

    IF (v_answer->>'settler_count')::int <> 1
       OR v_answer->'settlers'->0->>'node_id' <> v_bob::text
       OR (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION 'Bob must settle the expectation he set on John, got %', v_answer;
    END IF;

    -- ------------------------------------------------------------------
    -- Rule 3. A person's own commitment settles with no speech act, so the
    -- zero-setup case survives the removal of the union.
    -- ------------------------------------------------------------------
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'commitment',
        p_speaker_id := v_john,
        p_domain_key := 'conformance-settling'
    );

    IF v_answer->>'step' <> 'relationship'
       OR (v_answer->>'settler_count')::int <> 1
       OR v_answer->'settlers'->0->>'node_id' <> v_john::text
       OR v_answer->'settlers'->0->>'relationship' <> 'self'
       OR (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION 'John must settle his own commitment with no speech act, got %', v_answer;
    END IF;

    -- And with no area at all: a self-set claim type, and a recognized self
    -- speech act, each reach the person on their own.
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'self_report',
        p_speaker_id := v_john
    );

    IF v_answer->>'step' <> 'relationship'
       OR v_answer->'settlers'->0->>'node_id' <> v_john::text
       OR (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION 'A self-set claim type must settle with no area at all, got %', v_answer;
    END IF;

    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'anything_at_all',
        p_speaker_id := v_john,
        p_speech_act := 'self_report'
    );

    IF v_answer->>'step' <> 'relationship'
       OR v_answer->'settlers'->0->>'node_id' <> v_john::text
       OR (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION 'A self speech act must settle with no area at all, got %', v_answer;
    END IF;

    -- ------------------------------------------------------------------
    -- Rule 4. There is no union. A claim type in neither set, with no
    -- speech act or an unrecognized one, selects no relationship at all and
    -- falls through to the area owner. Saying less buys a smaller answer.
    -- ------------------------------------------------------------------
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'availability',
        p_speaker_id := v_john,
        p_domain_key := 'conformance-settling'
    );

    IF v_answer->>'step' <> 'area_owner'
       OR (v_answer->>'settler_count')::int <> 1
       OR v_answer->'settlers'->0->>'node_id' <> v_dana::text
       OR (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM false
    THEN
        RAISE EXCEPTION 'An unclassified claim with no speech act must reach the area owner, got %', v_answer;
    END IF;

    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'availability',
        p_domain_key := 'conformance-settling',
        p_speech_act := 'muttered_in_passing'
    );

    IF (v_answer->'claim'->>'speech_act_recognized')::boolean IS DISTINCT FROM false
       OR v_answer->>'step' <> 'area_owner'
       OR v_answer->'settlers'->0->>'node_id' <> v_dana::text
    THEN
        RAISE EXCEPTION 'An unrecognized speech act must select nothing, got %', v_answer;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_answer->'settlers') AS s(value)
        WHERE s.value->>'node_id' = v_john::text
    ) THEN
        RAISE EXCEPTION 'Rule 4 must never return the subject itself, got %', v_answer;
    END IF;

    -- The same question against an area nobody owns is an answer, not an
    -- error: the fall-through has nowhere to land and says so.
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'availability',
        p_speaker_id := v_john,
        p_domain_key := 'conformance-settling-orphan'
    );

    IF v_answer->>'step' <> 'none'
       OR (v_answer->>'settler_count')::int <> 0
       OR v_answer->>'reason' <> 'area_has_no_owner'
       OR (v_answer->>'setup_gap')::boolean IS DISTINCT FROM true
       OR (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM false
    THEN
        RAISE EXCEPTION 'Rule 4 with no area owner must answer no settler, got %', v_answer;
    END IF;

    -- ------------------------------------------------------------------
    -- A grant for this kind of claim wins over the relationship. Priya is
    -- granted expectations in this area; Bob's reporting line is not
    -- consulted at all.
    -- ------------------------------------------------------------------
    PERFORM grant_domain_authority(
        p_domain_key     := 'conformance-settling',
        p_authority_kind := 'person',
        p_authority_ref  := 'conformance_org:priya',
        p_claim_types    := ARRAY['expectation'],
        p_effective_at   := v_then
    );

    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'expectation',
        p_speaker_id := v_priya,
        p_domain_key := 'conformance-settling',
        p_speech_act := 'expectation'
    );

    IF v_answer->>'step' <> 'grant'
       OR (v_answer->>'settler_count')::int <> 1
       OR v_answer->'settlers'->0->>'node_id' <> v_priya::text
       OR v_answer->'settlers'->0->>'kind' <> 'person'
       OR v_answer->'settlers'->0->>'via' <> 'grant'
       OR (v_answer->'settlers'->0->>'bound')::boolean IS DISTINCT FROM true
       OR v_answer->'settlers'->0->'grant_id' IS NULL
       OR (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION 'Expected a grant to win over the reporting line, got %', v_answer;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_answer->'settlers') AS s(value)
        WHERE s.value->>'node_id' = v_bob::text
    ) THEN
        RAISE EXCEPTION 'The relationship step must not run once a grant matched, got %', v_answer;
    END IF;

    -- And it wins with no speech act at all, where rule 1 would otherwise
    -- have chosen the manager.
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'expectation',
        p_speaker_id := v_priya,
        p_domain_key := 'conformance-settling'
    );

    IF v_answer->>'step' <> 'grant'
       OR (v_answer->>'settler_count')::int <> 1
       OR v_answer->'settlers'->0->>'node_id' <> v_priya::text
       OR (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION 'A grant must win over rule 1 with no speech act, got %', v_answer;
    END IF;

    -- A grant only covers the claim types it names. Another kind of claim
    -- still falls to the relationship.
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'availability',
        p_domain_key := 'conformance-settling',
        p_speech_act := 'expectation'
    );

    IF v_answer->>'step' <> 'relationship'
       OR v_answer->'settlers'->0->>'node_id' <> v_bob::text
    THEN
        RAISE EXCEPTION 'Expected an ungranted claim type to fall to the relationship, got %', v_answer;
    END IF;

    -- ------------------------------------------------------------------
    -- A grant may name a system or a source identity. Both come back as
    -- such, and a source identity is unbound: it is not a person record.
    -- ------------------------------------------------------------------
    PERFORM grant_domain_authority(
        p_domain_key     := 'conformance-settling',
        p_authority_kind := 'system',
        p_authority_ref  := 'billing-of-record',
        p_claim_types    := ARRAY['account_status'],
        p_effective_at   := v_then
    );

    PERFORM grant_domain_authority(
        p_domain_key     := 'conformance-settling',
        p_authority_kind := 'source',
        p_authority_ref  := 'chat:U0123',
        p_claim_types    := ARRAY['account_status'],
        p_effective_at   := v_then
    );

    v_answer := rye_settlers(
        p_subject_id  := v_john,
        p_claim_type  := 'account_status',
        p_speaker_ref := 'chat:U0123',
        p_domain_key  := 'conformance-settling'
    );

    IF v_answer->>'step' <> 'grant' OR (v_answer->>'settler_count')::int <> 2 THEN
        RAISE EXCEPTION 'Expected both grants to answer, got %', v_answer;
    END IF;

    SELECT s.value INTO v_settler
    FROM jsonb_array_elements(v_answer->'settlers') AS s(value)
    WHERE s.value->>'kind' = 'source';

    IF v_settler IS NULL
       OR v_settler->>'ref' <> 'chat:U0123'
       OR (v_settler->>'bound')::boolean IS DISTINCT FROM false
    THEN
        RAISE EXCEPTION 'Expected the source identity to be returned unbound, got %', v_answer->'settlers';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_answer->'settlers') AS s(value)
        WHERE s.value->>'kind' = 'system' AND s.value->>'ref' = 'billing-of-record'
    ) THEN
        RAISE EXCEPTION 'Expected the system grant to be returned as a system, got %', v_answer->'settlers';
    END IF;

    -- An unbound channel identity settles only what a grant names it for:
    -- the speaker ref matched here.
    IF (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Expected the named source identity to be its own settler, got %', v_answer->'speaker';
    END IF;

    -- A different channel identity is not.
    v_answer := rye_settlers(
        p_subject_id  := v_john,
        p_claim_type  := 'account_status',
        p_speaker_ref := 'chat:U9999',
        p_domain_key  := 'conformance-settling'
    );

    IF (v_answer->'speaker'->>'is_settler')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'Expected an unnamed channel identity to settle nothing, got %', v_answer->'speaker';
    END IF;

    -- ------------------------------------------------------------------
    -- A grant narrows by naming its subjects in properties.
    -- ------------------------------------------------------------------
    PERFORM grant_domain_authority(
        p_domain_key     := 'conformance-settling',
        p_authority_kind := 'person',
        p_authority_ref  := 'conformance_org:mara',
        p_claim_types    := ARRAY['shift_plan'],
        p_effective_at   := v_then,
        p_properties     := jsonb_build_object('subjects', jsonb_build_array(v_john::text))
    );

    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'shift_plan',
        p_domain_key := 'conformance-settling'
    );

    IF v_answer->>'step' <> 'grant'
       OR v_answer->'settlers'->0->>'node_id' <> v_mara::text
    THEN
        RAISE EXCEPTION 'Expected the narrowed grant to match its named subject, got %', v_answer;
    END IF;

    v_answer := rye_settlers(
        p_subject_id := v_priya,
        p_claim_type := 'shift_plan',
        p_domain_key := 'conformance-settling',
        p_speech_act := 'expectation'
    );

    IF v_answer->>'step' = 'grant' THEN
        RAISE EXCEPTION 'A narrowed grant must not match a subject it does not name, got %', v_answer;
    END IF;

    -- ------------------------------------------------------------------
    -- An agent identity is never a settler. A grant whose only holder is an
    -- agent is not a match; the lookup continues and counts the exclusion.
    -- ------------------------------------------------------------------
    v_agent_id := create_agent_identity(
        p_agent_key := 'conformance_settler_agent',
        p_label     := 'Conformance Settler Agent',
        p_runtime   := 'conformance'
    );

    PERFORM grant_domain_authority(
        p_domain_key     := 'conformance-settling',
        p_authority_kind := 'person',
        p_authority_ref  := 'agent:conformance_settler_agent',
        p_claim_types    := ARRAY['handoff_note'],
        p_effective_at   := v_then
    );

    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'handoff_note',
        p_domain_key := 'conformance-settling',
        p_speech_act := 'expectation'
    );

    IF v_answer->>'step' <> 'relationship'
       OR v_answer->'settlers'->0->>'node_id' <> v_bob::text
       OR (v_answer->>'excluded_agents')::int <> 1
    THEN
        RAISE EXCEPTION 'Expected an agent-only grant to be skipped and counted, got %', v_answer;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_answer->'settlers') AS s(value)
        WHERE s.value->>'ref' LIKE 'agent:%'
    ) THEN
        RAISE EXCEPTION 'An agent identity must never be returned as a settler, got %', v_answer;
    END IF;

    -- Agent keys are slugs. create_agent_identity() stores
    -- rye_slugify_key(agent_key), so the identity above is stored as
    -- conformance_settler_agent. A ref spelled any other way is the same
    -- agent and must be excluded just the same. Each case below falls
    -- through to Bob, the manager, and counts exactly one exclusion.
    PERFORM grant_domain_authority(
        p_domain_key     := 'conformance-settling',
        p_authority_kind := 'person',
        p_authority_ref  := 'agent:conformance-settler-agent',
        p_claim_types    := ARRAY['bot_claim_hyphen'],
        p_effective_at   := v_then
    );

    PERFORM grant_domain_authority(
        p_domain_key     := 'conformance-settling',
        p_authority_kind := 'person',
        p_authority_ref  := 'conformance-settler-agent',
        p_claim_types    := ARRAY['bot_claim_bare'],
        p_effective_at   := v_then
    );

    PERFORM grant_domain_authority(
        p_domain_key     := 'conformance-settling',
        p_authority_kind := 'person',
        p_authority_ref  := '  Agent:Conformance-Settler-Agent  ',
        p_claim_types    := ARRAY['bot_claim_mixed_case'],
        p_effective_at   := v_then
    );

    -- Fail closed: a ref that says it is an agent never settles, whether or
    -- not an agent_identities row backs it.
    PERFORM grant_domain_authority(
        p_domain_key     := 'conformance-settling',
        p_authority_kind := 'person',
        p_authority_ref  := 'agent:no-such-identity-anywhere',
        p_claim_types    := ARRAY['bot_claim_unbacked'],
        p_effective_at   := v_then
    );

    -- An inactive agent identity is still an agent.
    v_bot_two := create_agent_identity(
        p_agent_key := 'conformance-retired-agent',
        p_label     := 'Conformance Retired Agent',
        p_runtime   := 'conformance'
    );
    UPDATE agent_identities SET active = false WHERE id = v_bot_two;

    PERFORM grant_domain_authority(
        p_domain_key     := 'conformance-settling',
        p_authority_kind := 'person',
        p_authority_ref  := 'conformance-retired-agent',
        p_claim_types    := ARRAY['bot_claim_inactive'],
        p_effective_at   := v_then
    );

    -- Whitespace PostgreSQL's trim() does not strip must not smuggle an agent
    -- past the prefix rule, and neither must a space before the colon.
    PERFORM grant_domain_authority(
        p_domain_key     := 'conformance-settling',
        p_authority_kind := 'person',
        p_authority_ref  := E'\tagent:conformance-settler-agent',
        p_claim_types    := ARRAY['bot_claim_tab'],
        p_effective_at   := v_then
    );

    PERFORM grant_domain_authority(
        p_domain_key     := 'conformance-settling',
        p_authority_kind := 'person',
        p_authority_ref  := E' agent:conformance-settler-agent',
        p_claim_types    := ARRAY['bot_claim_nbsp'],
        p_effective_at   := v_then
    );

    PERFORM grant_domain_authority(
        p_domain_key     := 'conformance-settling',
        p_authority_kind := 'person',
        p_authority_ref  := 'agent :conformance-settler-agent',
        p_claim_types    := ARRAY['bot_claim_space_colon'],
        p_effective_at   := v_then
    );

    FOREACH v_case IN ARRAY ARRAY[
        'bot_claim_hyphen',
        'bot_claim_bare',
        'bot_claim_mixed_case',
        'bot_claim_unbacked',
        'bot_claim_inactive',
        'bot_claim_tab',
        'bot_claim_nbsp',
        'bot_claim_space_colon'
    ] LOOP
        v_answer := rye_settlers(
            p_subject_id := v_john,
            p_claim_type := v_case,
            p_domain_key := 'conformance-settling',
            p_speech_act := 'expectation'
        );

        IF (v_answer->>'excluded_agents')::int <> 1 THEN
            RAISE EXCEPTION 'Expected % to exclude exactly one agent, got %',
                v_case, v_answer;
        END IF;

        IF EXISTS (
            SELECT 1
            FROM jsonb_array_elements(v_answer->'settlers') AS s(value)
            WHERE lower(coalesce(s.value->>'ref', '')) LIKE '%agent%'
        ) THEN
            RAISE EXCEPTION 'An agent must never be returned as a settler for %, got %',
                v_case, v_answer;
        END IF;

        IF v_answer->>'step' <> 'relationship'
           OR (v_answer->>'settler_count')::int <> 1
           OR v_answer->'settlers'->0->>'node_id' <> v_bob::text
        THEN
            RAISE EXCEPTION 'Expected % to fall through to the manager, got %',
                v_case, v_answer;
        END IF;
    END LOOP;

    -- The other direction: a person never loses authority for sharing a slug
    -- with an agent. `person:conformance-settler-agent` is not an agent
    -- prefix, and the whole ref slugifies to person_conformance_settler_agent,
    -- which no identity has. The grant stands.
    PERFORM grant_domain_authority(
        p_domain_key     := 'conformance-settling',
        p_authority_kind := 'person',
        p_authority_ref  := 'person:conformance-settler-agent',
        p_claim_types    := ARRAY['person_claim_lookalike'],
        p_effective_at   := v_then
    );

    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'person_claim_lookalike',
        p_domain_key := 'conformance-settling',
        p_speech_act := 'expectation'
    );

    IF v_answer->>'step' <> 'grant'
       OR (v_answer->>'settler_count')::int <> 1
       OR v_answer->'settlers'->0->>'ref' <> 'person:conformance-settler-agent'
       OR (v_answer->>'excluded_agents')::int <> 0
    THEN
        RAISE EXCEPTION 'A person must not be excluded for sharing a slug with an agent, got %', v_answer;
    END IF;

    -- A node that is an agent by attrs->>'actor_kind' rather than by
    -- node_type is excluded wherever it stands, here as a second manager.
    INSERT INTO nodes (node_type, label, external_source, external_id, attrs)
    VALUES ('person', 'Delegate', 'conformance_org', 'delegate',
            '{"actor_kind": "agent"}'::jsonb)
    RETURNING id INTO v_delegate;

    INSERT INTO edges (edge_type, source_id, target_id, effective_from)
    VALUES ('reports_to', v_john, v_delegate, v_then)
    RETURNING id INTO v_delegate_edge;

    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'availability',
        p_domain_key := 'conformance-settling',
        p_speech_act := 'expectation'
    );

    IF (v_answer->>'settler_count')::int <> 1
       OR v_answer->'settlers'->0->>'node_id' <> v_bob::text
       OR (v_answer->>'excluded_agents')::int <> 1
    THEN
        RAISE EXCEPTION 'Expected an actor_kind agent manager to be dropped and counted, got %', v_answer;
    END IF;

    UPDATE edges SET archived_at = now() WHERE id = v_delegate_edge;

    -- An agent node standing in a relationship is dropped the same way.
    INSERT INTO nodes (node_type, label, external_source, external_id)
    VALUES ('agent', 'Standing Assistant', 'conformance_org', 'standing-assistant')
    RETURNING id INTO v_agent_node;

    INSERT INTO edges (edge_type, source_id, target_id, effective_from)
    VALUES ('owns', v_agent_node, v_press, v_then);

    v_answer := rye_settlers(
        p_subject_id := v_press,
        p_claim_type := 'maintenance_window',
        p_domain_key := 'conformance-settling',
        p_speech_act := 'statement_about_thing'
    );

    IF (v_answer->>'settler_count')::int <> 1
       OR v_answer->'settlers'->0->>'node_id' <> v_priya::text
       OR (v_answer->>'excluded_agents')::int <> 1
    THEN
        RAISE EXCEPTION 'Expected an agent owner to be dropped and counted, got %', v_answer;
    END IF;

    -- ------------------------------------------------------------------
    -- An area with no owner returns no settler and says so. It is not an
    -- error: no exception, empty list, a reason, and a setup gap.
    -- ------------------------------------------------------------------
    v_answer := rye_settlers(
        p_subject_id := v_press,
        p_claim_type := 'budget_line',
        p_domain_key := 'conformance-settling-orphan',
        p_speech_act := 'decision'
    );

    IF v_answer->>'step' <> 'none'
       OR v_answer->'settlers' <> '[]'::jsonb
       OR (v_answer->>'settler_count')::int <> 0
       OR v_answer->>'reason' <> 'area_has_no_owner'
       OR (v_answer->>'setup_gap')::boolean IS DISTINCT FROM true
       OR (v_answer->'domain'->>'domain_found')::boolean IS DISTINCT FROM true
       OR (v_answer->'domain'->>'has_owner')::boolean IS DISTINCT FROM false
    THEN
        RAISE EXCEPTION 'Expected an unowned area to answer no settler, got %', v_answer;
    END IF;

    -- ------------------------------------------------------------------
    -- An area whose owner is an agent has no settler either. The agent is
    -- dropped at the last step as at every other, counted, and reported as a
    -- setup gap for a person to close.
    PERFORM ensure_knowledge_domain(
        p_domain_key    := 'conformance-settling-botrun',
        p_label         := 'Conformance Settling, Agent-Owned',
        p_purpose       := 'An area whose owner node is an agent.',
        p_owner_node_id := v_agent_node
    );

    v_answer := rye_settlers(
        p_subject_id := v_press,
        p_claim_type := 'budget_line',
        p_domain_key := 'conformance-settling-botrun',
        p_speech_act := 'decision'
    );

    IF v_answer->>'step' <> 'none'
       OR (v_answer->>'settler_count')::int <> 0
       OR v_answer->>'reason' <> 'area_owner_is_agent'
       OR (v_answer->>'excluded_agents')::int <> 1
       OR (v_answer->>'setup_gap')::boolean IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION 'Expected an agent area owner to settle nothing, got %', v_answer;
    END IF;

    -- ------------------------------------------------------------------
    -- An unknown area key is an answer too, not an exception.
    -- ------------------------------------------------------------------
    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'expectation',
        p_domain_key := 'conformance-settling-nowhere'
    );

    IF v_answer->>'step' <> 'none'
       OR (v_answer->'domain'->>'domain_found')::boolean IS DISTINCT FROM false
       OR v_answer->>'reason' <> 'domain_not_found'
       OR v_answer->'domain'->>'mode' <> 'explicit'
    THEN
        RAISE EXCEPTION 'Expected an unknown area key to answer domain_not_found, got %', v_answer;
    END IF;

    -- ------------------------------------------------------------------
    -- An unknown subject reads as not found and skips the relationship
    -- step, falling through to the area owner rather than raising.
    -- ------------------------------------------------------------------
    v_answer := rye_settlers(
        p_subject_id := '00000000-0000-0000-0000-0000000000ff'::uuid,
        p_claim_type := 'availability',
        p_domain_key := 'conformance-settling'
    );

    IF (v_answer->'subject'->>'subject_found')::boolean IS DISTINCT FROM false
       OR v_answer->>'step' <> 'area_owner'
    THEN
        RAISE EXCEPTION 'Expected an unknown subject to skip the relationship step, got %', v_answer;
    END IF;

    -- ------------------------------------------------------------------
    -- An archived edge is gone at every as-of, unlike one that ended.
    -- ------------------------------------------------------------------
    UPDATE edges SET archived_at = now() WHERE id = v_edge;

    v_answer := rye_settlers(
        p_subject_id := v_john,
        p_claim_type := 'availability',
        p_domain_key := 'conformance-settling',
        p_speech_act := 'expectation',
        p_as_of      := now() - interval '10 days'
    );

    IF v_answer->>'step' <> 'area_owner' THEN
        RAISE EXCEPTION 'Expected an archived reporting line to be gone at every as-of, got %', v_answer;
    END IF;
END
$$;

ROLLBACK;
