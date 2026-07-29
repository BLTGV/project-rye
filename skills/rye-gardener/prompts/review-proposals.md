# Gardener proposal prompt

Turn approved gardening findings into reviewable candidates.

- Stage type aliases as candidate `registry_entry` assertions using
  `type_alias:<kind>:<deprecated_value>` and a scalar string `claim.value`.
- Stage possible entity merges as `decision` knowledge candidates whose target
  payload contains duplicate and canonical UUIDs, evidence, conflicts, and the
  proposed `merge_nodes()` call.
- Never accept the registry candidate in the same workflow.
- Never call `merge_nodes()`.
- Verify candidates are visible in `review_queue` or as active
  `knowledge_candidate` nodes.
- Verify existing type rows retain their stored spelling.

Report created IDs and the exact human decision required for each.
