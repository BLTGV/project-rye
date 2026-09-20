---
name: rye-gardener
description: Audit Rye type vocabulary, duplicate-node signals, and intake consistency, then prepare human-reviewable type-alias and merge proposals without rewriting history or calling merge_nodes directly.
---

# Rye Gardener

Use this skill when Rye vocabulary has drifted, near-duplicate type names have
appeared, nodes may represent the same entity, or an intake run may have left
the graph contradicting itself.

## Hard boundary

Gardening is review-gated.

- Never update existing `node_type`, `edge_type`, or `assertion_type` values.
- Never call `merge_nodes()` directly. A merge is irreversible, and the
  database refuses it anyway: an agent-shaped session gets `42501` and a
  sentence naming who may merge, a Rye admin or a team member. Do not retry it
  under another role.
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
10. Run the four intake consistency checks below and report every finding with
    the rule it breaks and what the check could not decide.

## Intake Consistency Audit

Vocabulary drift is not the only thing that rots. Four intake defects leave
findable traces, and the four reads that find them are in
`skills/rye-pattern-library/references/intake-consistency-checks.md`, with an
executable copy in `eval/intake_consistency/checks.sql` and a fixture that
violates each one.

Run them as a standing audit. They are reads. Report each finding with the row
the query returned and the rule it breaks:

1. A person Rye knows to have departed with an `employs` or role edge still
   open. Recording the departure was meant to end those edges on the same date.
   **Run both check 1 and check 1s.** Check 1 reads accepted knowledge only, so
   under a review policy that demotes agent writes it goes quiet while the
   departure waits for a person and the edges stay open. Check 1s counts live
   suggestions and has a `departure_status` column that says which case you are
   looking at. Checks 2, 3 and 4 already see suggestions.
2. A digest claim key no cited source assertion carries. The digest asserted
   more than it was given.
3. A live assertion whose `effective_at` falls outside the window of the edge
   it is about. The claim and the relationship tell two stories.
4. A claim carrying a number with no `attrs.source_window`, or with a window
   that does not contain the sources it cites. Check 4a has no basis filter on
   purpose, so it lists attributes as well as measurements. Triage by reading
   the type and say in the report which rows you set aside and why.

What you do with a finding is what you do with every other one: evidence, then
a proposal, then stop. Specifically:

- Finding 1 needs a person. You cannot close an edge — an agent-shaped session
  has no `UPDATE` on `edges`, so the statement reports `UPDATE 0`, changes
  nothing, and raises nothing. Name the edges and the date. A row whose
  `disposition` is `handoff` — `owns`, `responsible_for` — is not a closing
  job at all: ask who takes the thing. A row with no departure date cannot be
  repaired by anyone until the date is found; report that as the finding.
- Findings 2 and 4 are corrected by replacing the claim. Against an accepted
  assertion that is `supersede_assertion()`. Against a pending suggestion it is
  `reject_candidate()` on the wrong one plus a fresh suggestion;
  `supersede_assertion()` raises on a candidate. Reject only suggestions you
  wrote.
- Finding 3 needs a reading first. The claim may be misdated or the edge may
  be. Say which you believe and why; do not pick silently.

Each check states what it cannot decide, and those limits are part of your
report. A check returning no rows means the query found nothing, not that the
graph is consistent. Prose in a digest, an undated claim, a claim on an edge
with no window at all, a relationship claim that names no edge, and a number
computed from uncited material are all outside what a query settles.

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

The proposal is not permission to merge, and you have none: the person who
accepts the proposal runs the merge. Report the candidate ID and the exact
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
