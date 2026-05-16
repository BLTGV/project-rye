---
name: rye-import-inspector
description: Validate Rye-tracked import and update runs before or after target writes. Use when Codex needs deterministic checks for source_row, mapped_record, change-plan, metadata, Rye audit, old-value traceability, table declarations, approvals, touched IDs, or post-write verification evidence.
---

# Rye Import Inspector

Use this skill as the generic validation gate for imports that rely on Rye for traceability. It checks process evidence; domain policy belongs in a consuming compliance skill.

## Workflow

1. Run the inspector after mapping and change planning:
   - `node skills/rye-import-inspector/scripts/inspect_import_run.mjs --source /tmp/source.ndjson --mapped /tmp/mapped.ndjson --change-plan /tmp/change-plan.json --metadata /tmp/import-metadata.json --phase prewrite`
2. Fix all `blocker` findings before target writes.
3. Emit a Rye-stageable report when the inspection result must become part of the run trace:
   - `node skills/rye-import-inspector/scripts/inspect_import_run.mjs --mapped /tmp/mapped.ndjson --change-plan /tmp/change-plan.json --metadata /tmp/import-metadata.json --phase prewrite --emit-stage > /tmp/import-inspection-stage.ndjson`
4. Include the emitted stage record in the Rye audit NDJSON before `tabular_commit_rye.mts`.
5. After target writes, run with `--phase postwrite` and metadata that includes touched IDs plus verification results.

## Metadata Contract

Use a small JSON object for process facts that are not already present in mapped records:

```json
{
  "run_id": "recon-aco-update:example",
  "source_reference": "https://...",
  "source_sha1": "abc123",
  "target_tables": ["acquisition_opportunity"],
  "operation_types": ["update"],
  "approval": { "status": "approved", "approved_by": "Casey", "approved_at": "2026-05-16T12:00:00Z" },
  "rye": { "audit_ndjson": "/tmp/recon-rye-audit.ndjson", "committed": true, "run_id": "recon-aco-update:example" },
  "touched_ids": { "acquisition_opportunity": [102238] },
  "verification": { "readback": true, "idempotency": true }
}
```

## Rules

- Local files are inputs only. Rye is the durable traceability record.
- Source rows must preserve source descriptors, raw row fields, and lineage.
- Mapped records must declare destination table, operation, record payload, lineage, and source set.
- Update records must carry old values in mapped metadata or have a change plan with `before` evidence.
- Target tables and operation types must be declared before production writes.
- Unresolved `needs_review` or `possible_merge` findings block writes unless an approval decision is present.
- Post-write checks require touched IDs and readback verification evidence.

The report JSON is the stable interface for downstream compliance skills.
