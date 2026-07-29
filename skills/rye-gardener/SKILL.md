---
name: rye-gardener
description: Audit Rye type vocabulary and duplicate-node signals, then prepare human-reviewable type-alias and merge proposals without rewriting history or calling merge_nodes directly.
---

# Rye Gardener

Use this skill when Rye vocabulary has drifted, near-duplicate type names have
appeared, or nodes may represent the same entity.

## Hard boundary

Gardening is review-gated.

- Never update existing `node_type`, `edge_type`, or `assertion_type` values.
- Never call `merge_nodes()` directly. A merge is irreversible.
- Never activate a type alias without human approval.
- Do not treat spelling similarity alone as proof that two concepts are the
  same.
- Keep salience advisory. It may order review work, but it cannot justify
  hiding, deleting, retaining, or merging data.

## Workflow

1. Set the Rye session context and read `type_vocabulary_report`.
2. Group rows by `kind`. Compare usage counts, first/last seen dates, labels,
   properties, plugin conventions, and domain meaning.
3. Detect possible near-duplicates outside SQL. Use normalized spelling,
   token overlap, edit distance, and semantic context. Do not add a database
   extension for this step.
4. Classify each finding:
   - harmless variation that should remain distinct
   - deprecated spelling that should alias to a canonical value
   - unclear vocabulary requiring an owner decision
   - possible duplicate nodes requiring entity-resolution evidence
5. Present evidence and the expected effect before staging anything.
6. With approval, stage an alias as a candidate `registry_entry` assertion on
   the appropriate scope/plugin/core registry. Its key is
   `type_alias:<kind>:<deprecated_value>` and its claim is
   `{"value":"<canonical_value>"}`. A reviewer activates it with
   `accept_assertion()`.
7. With approval, stage a node-merge proposal as a structural
   `knowledge_candidate` (use candidate kind `decision`) whose target payload
   names the duplicate, canonical node, supporting evidence, conflicts, and
   the proposed `merge_nodes(duplicate, canonical)` call.
8. Stop at the review boundary. A human or capability-granted promotion path
   decides whether to accept the alias or execute the merge.
9. Re-read `type_vocabulary_report`, `review_queue`, and the candidate node to
   verify the proposal is visible and no historical row changed.

## Alias proposal shape

```sql
SELECT record_assertion(
    p_assertion_type := 'registry_entry',
    p_assertion_key := 'type_alias:assertion_type:deprecated_spelling',
    p_subject_node_id := '<registry_node_id>',
    p_claim := '{"value":"canonical_spelling"}',
    p_status := 'candidate',
    p_basis := 'assumed',
    p_attrs := jsonb_build_object(
      'proposal_kind', 'type_alias',
      'review_required', true,
      'reason', '<evidence-backed reason>'
    )
);
```

Scope registry entries take precedence over enabled-plugin defaults, which
take precedence over the core registry. Use the narrowest registry that owns
the convention. Alias chains are allowed, but `canonical_type()` must resolve
the full chain and raises on cycles.

## Merge proposal shape

```sql
SELECT create_knowledge_candidate(
    p_candidate_kind := 'decision',
    p_statement := 'Review possible duplicate nodes before merge',
    p_target_payload := jsonb_build_object(
      'action', 'merge_nodes',
      'duplicate_id', '<duplicate_uuid>',
      'canonical_id', '<canonical_uuid>',
      'supporting_evidence', '<summary>',
      'conflicts', '<summary>'
    ),
    p_review_context_ids := ARRAY['<review_context_uuid>']::uuid[],
    p_source_node_ids := ARRAY['<duplicate_uuid>', '<canonical_uuid>']::uuid[]
);
```

The proposal is not permission to merge. Report the candidate ID and the exact
evidence a reviewer should verify.

## Output

Return:

- vocabulary findings, separated by kind
- proposed canonical value and deprecated value
- usage count and first/last seen evidence
- semantic risks or reasons to keep values distinct
- staged candidate IDs, if the user approved writes
- explicit confirmation that no merge ran and no historical type row changed

Use the audit prompt in `prompts/vocabulary-audit.md` for read-only review and
the proposal prompt in `prompts/review-proposals.md` when the user authorizes
candidate creation.
