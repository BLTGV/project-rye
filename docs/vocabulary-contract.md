# Rye Vocabulary Contract

Status: **adopted convention**. Ported from the pre-v2 agent-access design
(PR #1) and restated against the merged Core Model v2 vocabulary. This
contract governs every surface where Rye or its agents address people; it
changes no schema or function behavior.

## Principle

Machine identifiers are canonical. Plain language is a presentation register
at the human boundary, not an alternate authorization or storage contract.

- Schema names, function names, API fields, categorical values, and reason
  strings use canonical internal identifiers everywhere durable: migrations,
  helper functions, API payloads, audit records, conformance tests.
- Durable records may contain human labels, statements, summaries, and
  reasons. That text is explanatory and never substitutes for the canonical
  code or structured value used to make a decision.
- When an agent addresses a non-technical person — chat, review requests,
  reports, or exception explanations — it renders internal concepts through
  one versioned lexicon and maps plain-language instructions back to
  canonical operations before calling CLI, API, MCP, or SQL helpers.
- A decision shown as "this needs a person to accept it" retains its
  canonical grounds (review policy, capability, scope). Where replay of the
  exact rendering matters, record the lexicon version alongside the rendered
  text.
- The repository owns the default lexicon. Agent-facing adapters use the
  same version; the database does not require every human sentence to come
  from it.
- Scopes may localize display terms through the existing convention
  registry (`register_scope_convention`). Internal identifiers never
  localize.

## Starter lexicon (v2 vocabulary)

| Internal | Plain register |
|---|---|
| event | something that happened |
| assertion (`status = 'accepted'`) | accepted knowledge |
| assertion (`status = 'candidate'`) | suggestion |
| `accept_assertion` / acceptance | accepting a suggestion |
| `reject_candidate` | declining a suggestion |
| competing candidates on one tuple | an open disagreement |
| supersession | replaced by a newer fact |
| `basis` (`observed` / `reported` / `inferred` / `assumed` / `unknown`) | how Rye knows it (seen directly / heard from someone / worked out / taken on faith / unclear) |
| evidence (`source` / `corroboration` / `derivation`) | where it came from / what backs it up / what it was built from |
| `effective_confidence()` | how sure Rye is |
| effective time | when it is true |
| knowledge time (bitemporal read) | what Rye believed at the time |
| digest | summary |
| stale digest | a summary that newer facts have outdated |
| knowledge gap | an open question |
| scope | area of the business |
| `review_policy = 'open'` | agents may record accepted knowledge here |
| `review_policy = 'candidates_only'` | agents suggest; people accept |
| `review_policy = 'strict'` | everything waits for a person |
| capability | permission |
| `review_queue` | suggestions waiting for a person |
| salience | what people ask about most |
| prediction / calibration | a forecast / how good the forecasts have been |
| pattern (induction) | a suggested rule of thumb, not yet confirmed |
| source identity | an account or identity observed in a source; confirmation that it is a specific person is separate |

## Conformance

- Every categorical value or reason string shown on a human surface has a
  versioned plain rendering; an unmapped value reaching a human surface is a
  defect.
- Agent-facing adapters map equivalent plain-language instructions to the
  same canonical operation and payload ("accept this suggestion" →
  `accept_assertion`, regardless of wrapper).
- Wrapper responses and audit records retain canonical values even when
  they also contain human summaries; no plain-register string is ever the
  stored value.
- Rendered decision snapshots identify the lexicon version when exact
  replay is required.
