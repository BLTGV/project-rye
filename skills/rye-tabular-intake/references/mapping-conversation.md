# Mapping Conversation

Use this pattern when the user wants help configuring mappings interactively.

## Conversation Checklist

Ask only what is needed to write a deterministic mapping config or module:

1. What source sheet or file should be used?
2. What destination table or tables should each row feed?
3. Which source columns map to which destination fields?
4. What conversions are needed?
5. What values should be defaulted, dropped, or treated as null?
6. Should invalid rows fail, be skipped, or be emitted with issues?

## Prefer Declarative Config When

- the user is renaming columns
- the user is trimming, casing, parsing booleans, numbers, or dates
- the user is setting defaults
- the user is doing straightforward value maps such as `"Y" -> true`

## Prefer TypeScript Module When

- one source row becomes multiple destination records
- mapping depends on multiple condition branches
- the transform depends on prior `mapped_record` output
- the user wants custom dedupe, lookups, or cross-field logic

## Suggested Prompt Shape

After `tabular_inspect.mts`, summarize the source columns and ask for only the unresolved decisions. Example:

`I found columns Customer ID, Name, Email, Status, and Created At. I need the destination table, the target field names, and whether Status should become a boolean or stay textual.`

## Output Artifacts

Capture the agreed mapping in one of:

- `mappings/<name>.json` for declarative config
- `mappings/<name>.mts` for custom transform logic

Treat that file as the durable mapping contract for repeat runs.
