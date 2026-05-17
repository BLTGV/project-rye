# Common Rye Patterns

Use these as starting points. Rename types for the customer's domain, but keep the structure and write rules intact.

## Source-Backed Entity

Use when a row in an existing table is the system of record.

Contract:

- domain table owns operational fields
- Rye node represents the entity in the graph
- `node_source_map` connects `(schema, table, source_id)` to the node
- `link_record()` is the write boundary
- `track_table()` can attach CDC after rows are linked

Sketch:

```sql
SELECT link_record(
  p_source_schema := 'public',
  p_source_table  := '<table>',
  p_source_id     := '<primary-key>',
  p_node_type     := '<entity_type>',
  p_label         := '<human label>',
  p_properties    := '{"external_status": "active"}'
);
```

## Temporal Relationship

Use when a relationship is true for a period of time.

Contract:

- edge uses `effective_from` and optional `effective_to`
- active relationship is `archived_at IS NULL` and `effective_to IS NULL`
- relationship details go in edge `properties`
- do not delete old edges to change history

Examples: assignment, employment, ownership link, membership, delegation.

## Membership Or Containment

Use when one node groups other nodes.

Contract:

- parent node points to child node with a stable edge type
- use `contains` for structural containment
- use `member_of` or a domain-specific equivalent for membership
- include `added_at`, `role`, `order`, or `source` in edge `properties` when useful

This pattern is for graph traversal. If the parent-child relation is the operational source of truth, keep that in a domain table and connect it with source-backed nodes.

## Current State Assertion

Use when the current value matters, but history must remain available.

Contract:

- `assertion_key = 'default'`
- one active assertion per `(assertion_type, subject_node_id, assertion_key)`
- replace with `supersede_assertion()`
- state-change event should be recorded with `record_event()`

Good fits: status, stage, health, priority, current title opinion.

Initial insert:

```sql
INSERT INTO assertions (assertion_type, assertion_key, subject_node_id, claim, confidence)
VALUES ('<state_type>', 'default', '<node_uuid>', '{"state": "new"}', 1.0);
```

Replacement:

```sql
SELECT supersede_assertion(
  p_old_assertion_id     := '<old_assertion_uuid>',
  p_new_assertion_type   := '<state_type>',
  p_new_subject_node_id  := '<node_uuid>',
  p_new_subject_edge_id  := NULL,
  p_new_claim            := '{"state": "reviewed"}',
  p_new_assertion_key    := 'default',
  p_new_source_event_id  := '<event_uuid>',
  p_new_confidence       := 1.0
);
```

## Multi-Valued Assertion Set

Use when a node can have many active claims of the same type.

Contract:

- key each claim with a stable domain key
- do not use `default`
- supersede only the claim with the same key
- put enough identity in the key to prevent accidental replacement

Key examples:

- `owner:<owner_node_id>`
- `source:<system>:<external_id>`
- `role:<role_code>`
- `period:<yyyy-mm>`

## Evidence-Backed Claim

Use when an assertion comes from a source document, import, or event.

Contract:

- create or reuse an artifact with `record_artifact()`
- record an event for the extraction, review, or import
- insert assertions with `source_event_id`
- include source identifiers in the assertion claim, not just in the artifact
- use `confidence` to reflect extraction or review quality

Use this when an agent may need to explain why a claim exists.

## Document Or Artifact Reference

Use when source material should be queryable but is not itself the operational entity.

Contract:

- document-like thing can be a `document` node when it participates in the graph
- extracted or parsed content belongs in `artifacts`
- use `record_artifact()` with `p_content_hash` for deduplication
- link document nodes to referenced nodes with `references` edges

Choose a document node when people will ask about the document as an object. Choose only an artifact when the content is just provenance for another claim.

## Activity Event

Use when something happened and one or more nodes participated.

Contract:

- create events only with `record_event()`
- pass participant IDs and roles together
- put event-specific details in event `properties`
- use participant roles that explain why each node matters

Sketch:

```sql
SELECT record_event(
  p_event_type        := '<event_type>',
  p_summary           := '<short summary>',
  p_properties        := '{"source": "agent"}',
  p_participant_ids   := ARRAY['<node_uuid>'::uuid],
  p_participant_roles := ARRAY['subject'],
  p_actor             := 'agent:<name>'
);
```

## Dispute Pattern

Use when new information conflicts with an existing assertion and the winner is not known.

Contract:

- do not supersede the existing assertion yet
- call `contest_assertion()`
- review unresolved conflicts through `active_disputes`
- call `resolve_dispute()` when a winner is chosen

This is for uncertainty. If the new value is known to be correct, use normal supersession.

## Tabular Intake Boundary

Use when source data starts in CSV or XLSX.

Contract:

- inspect first
- preserve source row lineage
- map or group rows outside the database
- commit through `tabular_commit_rye.mts`
- use `--emit-sql` when the target only supports SQL execution

Keep customer-specific import rules in a consuming skill or mapping module.
