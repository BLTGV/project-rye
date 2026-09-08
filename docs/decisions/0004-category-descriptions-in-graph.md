# 0004 — Category descriptions live in the graph

Date: 2026-09-08. Status: accepted. Decided by: Architect, for work item 001.

**What a category means here is an assertion on a `category` node, per scope,
not a field in a file.** One node of type `category` stands for each node type
(`external_source` `rye_category`, `external_id` the type name), and its
description is a `category_description` assertion whose `assertion_key` is the
scope's uuid, with `default` as the organization-wide fallback. That buys the
whole lifecycle for free: an agent proposes a description as a candidate, a
reviewer accepts it, a correction supersedes rather than overwrites, the
history says who changed the words and why, and `rye_categories()` reads
`current_valid_assertions` so the next call shows the accepted text — no new
table, no migration to change a description, and no way for an unaccepted
proposal to leak into what an agent reads. The rejected alternative was a
declared schema registry in files: a `categories/*.json` set beside the plugin
manifests, or a richer `contributes.node_types` entry carrying description and
required keys. It reads well in a pull request and would have given us declared
required properties immediately, which is why `properties.required` is empty in
v0.3. It was declined because it puts vocabulary back in git, against the
brief's split — procedure lives in git, vocabulary lives in the graph — and
because it makes the thing an organization most wants to tune the thing only a
developer with repository access can change, on a redeploy cycle, per install
rather than per scope. A file-declared registry can still arrive later as a
seed that writes these same assertions; nothing here forecloses it.
