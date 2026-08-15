# Observed And Authoritative Process

Status: **design contract, not yet implemented**. Ported from the pre-v2
agent-access design (PR #1) and restated against the merged Core Model v2.
This is the foundation for any future process-governance work (the
direction PR #3 explored on pre-v2 primitives). Nothing here changes v2
semantics; it constrains how process knowledge must be modeled when it is
built.

## Two stances

Process knowledge exists in two stances that must coexist without merging:

- **Observed** process describes how work actually flowed: which states
  occurred, which transitions happened, who initiated and who decided
  them. Events and evidence preserve the record. A derived observed
  assertion is descriptive knowledge and makes no claim about what is
  permitted.
- **Authoritative** process prescribes how work must flow. Only it may
  bind any future enforcement or evaluation. It is established by feeding
  structured sources such as an org chart or process document, or by
  activating a proposed rule — in both cases only through an actor with
  the applicable acceptance authority for the governing scope.

Both stances share a comparison vocabulary normalized to
`(process_key, from_state, to_state)`, but use stance-specific claim
shapes, assertion keys, and assertion types, so neither lineage can
masquerade as the other. Any evaluator binds to the authoritative lineage
only, by construction.

## Required properties

1. **Order independence.** Observation may begin before any authoritative
   process exists, authoritative knowledge may be fed before any
   observation exists, and either may arrive later. Neither writes to the
   other's lineage.
2. **Observed knowledge accumulates under an unknown process.** Source
   observations and immutable events accumulate before any process is
   known. A derived observed-process assertion follows the normal v2
   lifecycle: it enters as `status = 'candidate'` with `basis` reflecting
   its derivation, carries derivation evidence, and is accepted under the
   governing scope's `review_policy`. There is no second, more lenient
   path.
3. **Observed never becomes authoritative automatically.** Discovery may
   emit authoritative-process candidates from the observed lineage.
   Activation requires human acceptance (or an explicitly granted
   promotion capability) in the governing scope. Drafts are presented as
   observed practice, not recommended governance.
4. **Fed knowledge is verifiable, not privileged.** An org chart or
   process document enters through the normal intake path with source
   evidence. Once active it is subject to the same divergence reporting as
   any other authoritative claim, so a stale org chart is detectable
   rather than silently trusted.
5. **Both lineages are temporal.** A bitemporal read
   (`assertions_as_of`) reconstructs what behavior was believed and what
   the rules were at any past time, independently.

## Divergence

Divergence between the lineages is a derived read model, not an error
state. For a window and process, classify:

- observed transitions covered by active policy: **routine**
- observed transitions absent from active policy: **unmodeled
  transitions** — candidate noncompliance, or evidence that the documented
  process is wrong
- policy transitions not observed during a window with known
  opportunities: **unobserved policy transitions** — possible process debt
  or training gaps
- observed deciders absent from active authority: **authority
  divergence** — candidate noncompliance, or a stale org chart

A persistent divergence with acceptable outcomes is input for a
policy-change candidate. A divergence report never mutates either lineage
and never blocks operational writes by itself.

## v2 mapping notes

The original contract predates Core Model v2 and referenced a promotion
evaluator with `allow`/`review`/`deny` decisions and `policy_set`
authority. Under v2 the equivalent machinery is:

- candidate/accepted `status` on assertions plus `accept_assertion`, in
  place of a separate promotion pipeline;
- `governing_scope()` resolution and `review_policy`
  (`open`/`candidates_only`/`strict`) as the acceptance gate;
- capability grants (e.g. agent acceptance rights) as the authority
  input;
- `assertion_evidence` derivation rows as the link from an observed
  process claim back to the events that support it.

Induction (`record_pattern`, migration 0019) already honors property 3 in
spirit: pattern claims are candidate-only. A future process-governance
implementation should treat observed-process claims the same way.
