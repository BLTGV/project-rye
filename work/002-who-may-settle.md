# 002 who-may-settle

- status: open
- opened: 2026-09-19
- areas: schema, agent-kit
- contracts: contracts/sql-surface.md, contracts/plugin-manifest.md

## Goal
An agent can ask Rye who may settle a claim, and get the same answer every
other agent would get. The answer comes from one lookup: a recorded grant
for that kind of claim, then the relationship between the speaker and the
subject, then the owner of the area. With that answer the agent either
records the statement as accepted or records a suggestion and knows whom to
check with. This is the first item of v0.4 (BRIEF.md) and step 3 of the
order of work in design/proposals/human-agent-scaling.md.

## Intent excerpt (BRIEF.md)
"Who may settle a claim comes from one lookup: a recorded grant for that
kind of claim, then the relationship (yourself, your manager, the owner of
the thing), then the owner of the area. Nothing a person says is refused or
lost. If they cannot settle it, it is recorded as a suggestion and their
agent checks with someone who can."

## Acceptance criteria
- [ ] Given a speaker, a subject, a kind of claim, and an area, one request returns the people who may settle it and which step of the lookup produced the answer (grant, relationship, area owner).
- [ ] A person is returned as a settler for claims about themselves with no setup.
- [ ] With a reporting line recorded from John to Bob, Bob is returned as the settler of an expectation on John, and John is not. With the reporting line ended, Bob is no longer returned.
- [ ] With an ownership relationship recorded, the owner is returned as the settler of claims about the thing they own.
- [ ] A recorded grant for a kind of claim wins over the relationship. A grant naming a system or a source identity is returned as such.
- [ ] A kind of claim with no grant and no relationship returns the area owner. An area with no owner returns no settler and says so; it is not an error.
- [ ] An agent identity is never returned as a settler.
- [ ] Reporting lines and ownership are relationships declared by the `rye-org` plugin as `reports_to` and `owns`, visible through the category discovery request from work/001.
- [ ] The answer is reconstructible for a past date: asking "as of" a date uses the relationships and grants in effect then.
- [ ] The request is reachable from the CLI, and the agent-operations skill tells an agent to make it before recording a statement as accepted.
- [ ] A conformance test covers each case above. A replay scenario covers the manager and report case end to end with no Rye vocabulary in what the person sees.

## Constraints
- SQL and bash only in schema. Additive: a new numbered migration; applied migrations are not edited; existing functions keep their signatures.
- No new core-table columns. Relationships are edges with `effective_from` and `effective_to`. Grants stay in `domain_authorities`; its shape does not change.
- The lookup is read-only and advisory in this item. It is not yet called from any acceptance path. Enforcement for API callers is a later item.
- Authorization stays session variables only.
- Internals keep canonical vocabulary. Anything a person sees uses the glossary.
- No customer names in fixtures or scenarios. The proposal's invented names are fine.
- No fixed caps or clocks anywhere in the skill guidance.

## Decided by the human
- 2026-09-19, Casey: the authority model is the five relationship defaults composed with `domain_authorities` as the exceptions and topical-grants mechanism, in a three-step lookup.
- 2026-09-19, Casey: the conventions live in the `rye-org` plugin as `reports_to` and `owns`.
- 2026-09-19, Casey: an unbound channel identity settles nothing unless specifically authorized by a grant naming that source identity.
- 2026-09-19, Casey: enforcement applies to API callers only; direct database users are trusted by construction.
- 2026-09-19, Casey: no hard values for silence or question counts.

## Assumed by default
- The area owner is `owner_node_id` on the knowledge domain. Overturn: Architect.
- The reporting line and ownership edges are themselves settled by the area owner. Overturn: Casey.
- A grant can narrow a default as well as add to it; how narrowing is expressed in the existing table is the Architect's call. Overturn: Architect.
- "Kind of claim" maps to `claim_types` on the grant and to assertion type on the claim. Overturn: Architect.
- Objections, the questions-owed request, and the write echo are separate work items that follow this one. Overturn: Casey.
- When the owner of an area is the person a reporting line is about, the Rye admin is asked instead, since nobody settles a claim about their own authority. Raised by Product. Overturn: Casey.
- A person's asking preferences bind only their own agents. Raised by Product. Overturn: Casey.
- An unsettled objection never expires; it stays visible as unsettled. Raised by Product. Overturn: Casey.
- A lone person's decisions, agreements, and unclassified statements settle through area ownership, so the first area must exist with that person as owner. "No setup" means none the person does: the agent creates the first area in its first conversation. That onboarding step is a later work item. Overturn: Casey.
- The v0.3 non-goal "tokens" means the forecasting-era stake concept, not the credential an agent presents to the API. Raised by Product. Overturn: Casey.

## Verified
- filled in at close

## Reports
Paste each role's report here as it arrives.

### Product, 2026-09-19 (v0.4 product definition, serves 002 and 003)
Result: done. Changed: docs/product.md (added "Part two: v0.4" with users,
goals, non-goals, stories S10 to S17; v0.3 text unaltered), docs/glossary.md
(new "Authority and settling" section, ten terms). Tested: none, docs only.
Learned: the brief's v0.4 done list maps onto eight stories with the five
replay cases under S10 to S13; stage 3 and 4 material appears only as
non-goals; work items and glossary now agree on "settle", "grant", "area
owner", "kind of claim". Questions: four, all answered under "Assumed by
default" above.

### Architect, 2026-09-19
Result: done. Changed: contracts/sql-surface.md (new "Settlement lookup"
section: `rye_settlers()` signature, answer shape, three steps, agent
exclusion, versioning, freshness, failure), contracts/plugin-manifest.md
(new "Declared relationships the schema reads": `reports_to` and `owns`
direction, temporal rule, who settles them, how they surface in category
discovery), contracts/rye-cli.md (`settlers` subcommand, `--json`, exit
zero on no settler), docs/architecture.md (one sentence),
docs/decisions/0005-who-may-settle-lookup.md. Tested: none. Learned:
knowledge_domains and domain_authorities have no RLS at all; only
agent_api_tokens is protected in 0016 (Lead verified; flagged as a separate
task, out of scope here). `authority_ref` is free text by convention
`person:<slug>` and resolves to no node today; resolution rules are now in
the contract. `rye_categories()` ignores `effective_to`, so an ended
`reports_to` still appears in discovery counts; that is vocabulary, not
truth. The plugin manifest schema has additionalProperties false and
edge_types is a bare string array, so edge semantics live in the contract.
Questions, both accepted by Lead: the agent-kit builder adds `owns` to
rye-org `contributes.edge_types` and `expectation` to `assertion_types`;
settler `kind` keeps a sixth value `other` for an area owner node that is
not a person, team, role, or system.

### Builder agent-kit, 2026-09-19
Result: done. Branch worktree-agent-a7f18ff71cb202bfc, commit a5b42c9.
Changed: plugins/rye-org/rye-plugin.json (`owns`, `expectation`),
skills/rye-agent-ops/SKILL.md (new "Ask Who May Settle It Before You
Accept"), skills/rye-agent-ops/rye-skill.json (`rye_settlers` in requires
and entrypoints), docs/agent-ops-guide.md, docs/conventions-catalog.md,
eval/skill_replay/README.md, eval/skill_replay/scenarios/manager-expectation/
(ground_truth, persona_brief_bob, persona_brief_john, rubric, setup.sql).
Tested: intake skill check passed. 22_secure_mcp_simulation.sh not run:
environment failure, DATABASE_URL required and the Docker daemon rejects
this user (Lead diagnosed: user not in docker group, service inactive, sudo
needs a password). Nothing in the repo validates plugin or skill manifests
against their JSON schemas, and eval/skill_replay has no runner; builder
used a throwaway validator and all 9 plugin and 10 skill manifests pass.
Learned: see docs/areas/agent-kit.md entries dated 2026-09-19. Questions,
all accepted by Lead: the scenario lands as "designed, not yet run" until
rye_settlers() and the CLI subcommand merge; the scenario's domain key and
owner are scenario-local; adding rye_settlers to the skill's requires
follows the rye_categories precedent.

### Builder schema, 2026-09-19
Result: done. Branch worktree-agent-ae27942de1b4935c1, commit 1c8c386.
Changed: schema/migrations/0021_settlement_lookup.sql (new: rye_settlers()
plus helpers rye_settler_resolve_ref, rye_settler_is_agent,
rye_settler_node_kind), tests/conformance/29_settlement_lookup.sql (new),
scripts/rye (`settlers` subcommand), scripts/verify.sh, docs/cli.md,
docs/data-dictionary.md. Tested: the area test command could NOT run
(Docker refuses this user; no PostgreSQL server installed). Substitute, all
passing: PostgreSQL 16.2 from the `pgserver` PyPI wheel, a prelude
extracted verbatim from 0001/0013/0016, then 0021 applied and test 29 run
unmodified; a deliberately flipped copy failed, so assertions fire. Checked
not SECURITY DEFINER, STABLE, own search_path, verify.sh signatures
resolve, CLI human and --json output, exit 0 with no settler. UNVERIFIED:
RLS interaction, migration ordering in a full install, every other suite.
Learned: see docs/areas/schema.md entries dated 2026-09-19. Questions: an
unknown explicit domain key short-circuits to step `none` and suppresses
even the self default, as the contract is written (Lead: accepted as the
safe failure; noted for Architect); three additive `reason` values
area_owner_not_visible, area_owner_is_agent, no_settler_found (Lead:
accepted, contract to be amended at close); fixtures create the edges
directly so nothing depends on the agent-kit manifest edit (Lead: agreed).

### Verifier, 2026-09-19, pass on 1c8c386 (schema) and a5b42c9 (agent-kit): FAIL
Schema diff clean against the contract. Executed on PostgreSQL 16.2
(pgserver stand-in, own instance): prelude from 0001/0013/0016, then 0021,
then tests/conformance/29_settlement_lookup.sql passed; a mutated copy
failed, so not vacuous. Criteria 1-7 and 9 verified by execution; 8
(discovery visibility) by reading; 10 CLI executed, skill read. Function is
SECURITY INVOKER, STABLE, own search_path, no current_user or pg_has_role,
no dynamic SQL, no new tables or columns. Findings, both agent-kit: (1)
HIGH: the replay fixture inserts knowledge_domains directly with key
'sales-operations'; rye_settlers() slugifies explicit keys to
'sales_operations', so the lookup returns step none, domain_not_found, the
inverse of the scenario's ground truth. Reproduced by execution; using
ensure_knowledge_domain() fixes it. (2) LOW: skill and guide say setup_gap
means no owner, but the function also sets it for area_owner_is_agent.
Still unexecuted: the area test command and the full suite, pending Docker.
Outstanding for Architect: amend the contract for the three extra reason
values and the unknown-explicit-key short-circuit. Lead: findings sent to
the agent-kit builder as fix attempt 1.

### Builder agent-kit, 2026-09-19, fix attempt 1 (commit d63b88e)
Result: done. Changed: scenario setup.sql (area created with
ensure_knowledge_domain(); nodes and edges stay direct because no general
helper exists), ground_truth.md (stored key sales_operations, either
spelling accepted, lookup table marked executed), SKILL.md,
docs/agent-ops-guide.md, docs/conventions-catalog.md (setup_gap reworded;
all six reason values covered; domain_not_found and domain_not_resolved are
the agent's own mistake, never said to the person). Tested by execution on
the PostgreSQL 16.2 stand-in with 0021 from the schema branch: Bob setting
the expectation returns step relationship, one settler Bob via reports_to,
speaker.is_settler true; John objecting returns the same settlers with
speaker.is_settler false; unchanged with the area key omitted except
domain.mode. Intake check passes; 19 of 19 manifests valid (ad hoc);
22_secure_mcp_simulation.sh still blocked by Docker. Learned: see
docs/areas/agent-kit.md entries dated 2026-09-19; notably rye_settlers()
has six reason values, not the contract's three. Questions: ground truth
must be re-run if the schema branch changes before merge (Lead: will re-run
once after integration); the scenario cannot run end to end until the CLI
subcommand merges (Lead: agreed).

### Verifier, 2026-09-19, second pass on d63b88e (agent-kit): PASS-STATIC
Findings: none. Both first-pass findings fixed; no regressions. Verified by
execution on a fresh stand-in PostgreSQL 16.2 with 0021 from 1c8c386 and
the corrected setup.sql: Bob as speaker returns step relationship, one
settler Bob (manager, reports_to), is_settler true, in all three key forms
(sales-operations, sales_operations, omitted); John as speaker returns the
same settlers with is_settler false; setup.sql is idempotent. The six
reason values in the skill, guide, and catalog match the function source
exactly; setup_gap is true for exactly area_has_no_owner and
area_owner_is_agent. Criterion 11 now verified by execution. Criterion 8
remains verified by reading. Still unexecuted: the area test commands and
the full suite, pending Docker.

### Lead, 2026-09-19, integration
Base revision 69daeb7. Merged worktree-agent-ae27942de1b4935c1 (1c8c386)
and worktree-agent-a7f18ff71cb202bfc (a5b42c9, d63b88e) into agent-roles
with no conflicts. From the merged tree, on the PostgreSQL 16.2 stand-in
with the Verifier's prelude: migration 0021 applies; tests/conformance/
29_settlement_lookup.sql passes; the manager-expectation fixture loads; Bob
as speaker returns step relationship with is_settler true, John returns
the same settler with is_settler false. `bash -n` on scripts/rye and
scripts/verify.sh passes; the intake skill check passes; all 19 plugin and
skill manifests validate (ad hoc validator). NOT run: the area test command
`./scripts/docker-test.sh test --reset --profiles crm,pm`,
22_secure_mcp_simulation.sh, and the combined suite, so RLS interaction,
migration ordering in a full install, and category discovery of
`reports_to` and `owns` (criterion 8) are unverified by execution. Docker
refuses this user. The item stays open until they run.

### Architect, 2026-09-19, contract amendments
Result: done. Changed: contracts/sql-surface.md ("Settlement lookup": six
`reason` values with setup_gap semantics; "An unknown area key stops the
lookup"; "Area keys and agent keys are slugs"), docs/decisions/0005
("Amendments after implementation"). Learned: `no_settler_found` is
unreachable in 0021, documented as the generic fallback. FOUND A BUG:
rye_settler_is_agent() compares a ref to agent_identities.agent_key
verbatim while create_agent_identity() slugifies on write, so a grant ref
`agent:my-agent` escapes the agent exclusion and is returned as a settler.
Architect proposed a separate item. Lead overruled: "an agent identity is
never returned as a settler" is an acceptance criterion of this item.
Lead reproduced it on the stand-in: agent stored as `my_agent`, grant ref
`agent:my-agent`, result step grant, excluded_agents 0, one settler.
Sent to the schema builder as fix attempt 1.

### Lead, 2026-09-19, first full suite run under Docker (tree 1749342)
`./scripts/docker-test.sh test --reset --profiles crm,pm`: the whole
conformance suite passed in a real install, including
29_settlement_lookup.sql, migration ordering through 0021, RLS-enabled
tables, security, concurrency, and scenarios. The run then failed in the
host-run 21_api_security.sh, which belongs to work/003. This tree predates
the agent-exclusion fix.

### Builder schema, 2026-09-19, fix attempt 1 (commit 54dcde4)
Result: done. Changed: 0021 (rye_settler_is_agent() fails closed on an
`agent:` prefix, case-insensitive and trimmed, and otherwise compares
rye_slugify_key(ref) to the stored agent_key; the check now also receives
the ref of node-derived settlers; authority_kind 'agent' guarded),
29_settlement_lookup.sql (six new cases), docs/data-dictionary.md. Tested
on the stand-in: before the fix all five agent refs returned step grant,
excluded_agents 0, one agent settler; after, step relationship,
excluded_agents 1, settler Bob; area-owner-is-agent answers step none,
area_owner_is_agent, setup_gap true; test 29 fails on the pre-fix migration
and passes on the fixed one. Questions: the amended contract paragraph
documented the bug as behavior (Lead: sent back to Architect to correct);
authority_kind has a CHECK that already forbids 'agent', guard kept without
a test (Lead: accepted). Lead: sent to Verifier for an adversarial recheck.

### Architect, 2026-09-19, contract correction (commit 2144f23)
The earlier amendment had recorded the verbatim-match defect as behavior.
contracts/sql-surface.md now states: an `agent:` prefix excludes whether
or not an identity row exists; otherwise a ref is an agent when its slug
equals a stored agent_key; an inactive identity is still an agent; the
test covers grant and node-derived settlers alike and authority_kind
`agent`; exclusions are counted and the lookup continues. Decision 0005
records the defect as found at contract review and fixed inside work/002.
Acknowledged cost: `agent:` is now a reserved ref prefix.

### Verifier, 2026-09-19, third pass on 54dcde4 (schema): PASS-STATIC
Criterion 7 verified by execution, including the hyphenated-key case. Test
29 passes on the fixed 0021 and fails at the first new case on the pre-fix
0021, so the new cases are not vacuous. Ten hostile refs tried: excluded
were AGENT:my-agent, `agent:`, agent:no-such-identity, an inactive
identity, and bare "My Agent". Node-derived paths with actor_kind agent
(manager, owner, self-commitment, area owner) all excluded correctly.
`person:my-agent` is correctly NOT excluded, so a real person is never
excluded for sharing a slug with an agent. Finding, LOW: trim() strips
spaces only, so a tab or non-breaking-space prefix, or `agent :x`, dodges
the prefix rule and survives as an unbound settler; no agent is returned as
itself. Lead: sent to the builder to harden and pin with tests; lookalike
unicode letters declared out of scope.

### Builder schema, 2026-09-19, whitespace hardening (commit ecea31a)
Result: done. rye_settler_is_agent() btrims space, tab, CR, LF, form feed,
vertical tab, U+00A0 and tests the prefix with a case-insensitive regex
that ignores whitespace before the colon. Four new cases in test 29. Five
malformed refs that returned an agent settler before now return step
relationship, excluded_agents 1. person:probe-bot stays a person. Test 29
fails at bot_claim_tab on 54dcde4 and passes on ecea31a.

### Verifier, 2026-09-19, fourth pass on ecea31a: PASS, conditional on the suite
Criterion 7 verified by execution across every whitespace and case
spelling. No over-exclusion: agents:team-x, agent-smith, management:ops,
"Agent Smith", agentic:team all return as ordinary settlers. No
backtracking: 200k whitespace characters answered in 4 ms. Functions still
SECURITY INVOKER with own search_path, no dynamic SQL. One low finding for
the Architect: the contract's "after trimming" under-specifies what the
code now does.

### Lead, 2026-09-19, combined suite on the final tree 4701e1a: PASSED
Base 8d8342c plus merge of worktree-agent-ae27942de1b4935c1 (54dcde4,
ecea31a). `./scripts/test-all.sh`: Docker flow passed (install,
conformance including 29_settlement_lookup.sql, security, concurrency,
scenarios, host-run 21, 22, 23), admin build and check:routes passed, site
build passed. Criterion 8 then verified by execution on a fresh full
install: with the fixture loaded and an `owns` edge added,
rye_categories() lists `reports_to` and `owns` under person as_source and
`owns` under org as_target.

### Lead, 2026-09-19, FOUND BY EXECUTION: a fail-open path. Item stays open.
On the same full install, `./scripts/rye settlers --claim expectation
--subject <John> --speaker <John> --domain sales-operations` WITHOUT
--speech-act returns settlers John (self) and Bob (manager) with
speaker.is_settler true. With --speech-act expectation it returns Bob only,
is_settler false. The contract says a null or unrecognized speech act gives
the union of self, owner, and manager, so the code matches the contract and
the contract is wrong: an agent that omits one optional flag is told John
may settle the expectation set on him. That contradicts acceptance
criterion 3 and is the first failure the model must prevent. Test 29 and
the replay fixture always pass the speech act, so they never saw it. Routed
to the Architect to decide the rule (Lead's recommendation: the claim type
selects the default where it can; a null or unrecognized speech act never
widens who may settle; zero-setup self statements must survive; the
objection path for other claim types is named as not covered). Then the
schema builder implements, the agent-kit builder updates the skill, and the
Verifier rechecks.

### Architect, 2026-09-19, rule for the relationship step (fail-open path closed in the contract)
contracts/sql-surface.md step 2 is now five ordered rules, first match
wins: (0) claim type reports_to or owns: no default, fall through; (1)
claim type in the set-on-a-person set (`expectation`) OR speech act
`expectation`: manager only, self never returned; (2) recognized speech
act: self_commitment and self_report give self; statement_about_other
gives the subject then the subject's manager; statement_about_thing gives
the owner; agreement, decision, outside_report, agent_inference fall
through; (3) claim type in the self set (commitment, self_commitment,
self_report): self only; (4) otherwise fall through to the area owner. The
union is deleted. Sets are literal strings in the function, additive.
Consumers must not accept while speech_act_recognized is false. New
section "What the lookup does not answer" names the objection path for
other claim types as not covered. The `agent:` prefix rule is now precise
enough to reimplement. Expected fixture answers given for five calls.
Learned: an unclassified statement now needs an area owner or returns step
none. Lead: accepted. Assumption added below.

### Builder agent-kit, 2026-09-19, claim-type-first skill text (commit 35e5b47)
Result: done. SKILL.md, agent-ops-guide, conventions-catalog: union wording
replaced with the claim-type-first rule; set-on-a-person and self claim
type lists; the nine recognized speech acts; always pass both;
speech_act_recognized false blocks an accepted write; new "What the lookup
does not tell you" with a standing-claim check. Scenario ground truth now
has four lookup rows; speech act omitted and unrecognized both give Bob
only, marked "per contract, not yet executed". Rubric fails an agent that
forgot the speech act and then accepted John's objection. Tested: intake
check passes; 19 of 19 manifests valid. Learned: rye_settlers() reads no
assertion, so is_settler true is not permission to replace a standing
claim; the guard is skill discipline, not enforcement. Questions: the two
new rows stand on the contract until executed (Lead: will execute after the
schema merge); the guard could not fire on rows with no recorded
authorizer (Lead: NOT accepted, sent back to fail closed: replace only when
the recorded authorizer is the speaker).

### Builder agent-kit, 2026-09-19, standing-claim guard fails closed (commit 320d361)
Result: done. The guard is now four cases in SKILL.md, the guide, and the
catalog: no accepted row, accept; authorizer is the speaker, accept with
the one-line echo; authorizer is someone else, suggestion; no authorizer
recorded, suggestion, run the lookup, confirm with a settler other than the
speaker or the area owner. An unrecorded authorizer reads as unknown, never
as unauthorized and never as open. Rubric P3e: John's agent must not accept
or supersede the standing expectation Bob authorized even if the lookup had
returned John. Tested: intake check passes; 19 of 19 manifests valid.
Learned: phrase the guard as "the authorizer is the speaker" and let
everything else fall to a suggestion; "someone other than the speaker"
fails open on every row written before the convention.

### Builder schema, 2026-09-19, five-rule relationship step (commit dc91cc1)
Result: done. 0021 rewritten to the five ordered rules with literal
c_other_set and c_self_set arrays; union deleted; COMMENT rewritten; three
raw VT and NBSP bytes in E'' literals converted to explicit escapes. Test
29 extended; CLI help, docs/cli.md, docs/data-dictionary.md updated.
Tested: `./scripts/docker-test.sh test --reset --profiles crm,pm` passed
end to end; database torn down. Test 29 fails on 71908a1 at the first new
case with exactly the reported answer and passes after. Five calls executed
through `./scripts/rye --json settlers` on a live install (John reports_to
Bob, area owned by Dana): John/expectation/no act: [Bob], is_settler false;
John/expectation/self_commitment: [Bob], false, recognized true;
John/commitment/no act: [John], true; Bob/expectation/no act: [Bob], true;
John/expectation/banana: [Bob], false, recognized false. All match the
Architect's expected answers.

### Lead, 2026-09-19, integration of the corrected lookup
Base revision 01758a1. Merged worktree-agent-ae27942de1b4935c1 (dc91cc1)
and worktree-agent-a7f18ff71cb202bfc (35e5b47, 320d361) with no conflicts.
Final tree 716692f. Combined suite and Verifier pass in progress.

### Lead, 2026-09-19, combined suite on 716692f: PASSED. Scenario rows executed.
`./scripts/test-all.sh` on the merged tree 716692f: Docker flow OK
(including 29_settlement_lookup.sql with the new cases, and host-run 21,
22, 23), admin build plus check:routes OK, site build OK. Then on a fresh
full install with the scenario's own setup.sql, through `./scripts/rye
--json settlers --claim expectation --subject <John> --domain
sales-operations`: speaker Bob, act expectation: [Bob Ferris], is_settler
true, recognized true. Speaker John, act expectation: [Bob Ferris], false,
true. Speaker John, act omitted: [Bob Ferris], false, recognized false.
Speaker John, act banana: [Bob Ferris], false, recognized false. The
agent-kit builder marked all four rows executed (commit ef3cff2, merged at
52eda43, docs only).

### Verifier, 2026-09-19, fifth pass on dc91cc1, 35e5b47, 320d361: PASS, conditional on the suite (which passed)
The fail-open path is closed; criterion 3 verified by execution and now
independent of the speech act; criterion 7 re-verified under the new rule
order; test 29 fails at the first new case on ecea31a. Rule-order attacks
all held: a grant beats rule 1; reports_to and owns fall through;
unclassified with no act goes to the area owner, never self; no owner gives
step none without error; zero setup survives; statement_about_other
returns the subject then the manager, never the speaker. Skill sets, the
nine acts, function literals, COMMENT, CLI help, and docs agree. The guard
is a positive truth table. Finding, LOW: claim-type matching is
case-sensitive and the contract does not say so; `Expectation` with
self_commitment returns the subject, judged safe as a different stored
type.

### Lead, 2026-09-19: the low finding is wider than case. Item stays open one more round.
Rye does not fold case, so `Expectation` is a different type. But Rye has
type aliases: canonical_type('assertion_type', v) follows registry entries
type_alias:assertion_type:<v>, and governing_scope(), the salience views,
and 0019 match on the canonical type. rye_settlers() compares the raw
string, and so does the skill's standing-claim guard. Where an organization
aliases `requirement` to `expectation`, a call with claim type
`requirement` and speech act self_commitment skips rule 1 and returns the
subject as settler, and the guard would not see the manager's accepted
`expectation`. Same fail-open shape, reachable through a documented
feature. Sent to: schema builder (canonicalize the claim type and grants'
claim_types before matching; report the canonical type additively; tests
with a registered alias), agent-kit builder (guard compares canonical
types), Architect (contract states alias resolution, case sensitivity, and
the consumer obligation).

### Alias round, 2026-09-19: Architect (4caea84), agent-kit 002b4e4, schema 247365e
Architect: contract states p_claim_type and grants' claim_types are
resolved with canonical_type('assertion_type', ...) before any rule or
grant is tested; matching is case-sensitive after resolution; an alias
cycle raises; claim.canonical_claim_type is an additive key; consumers
compare canonical types before replacing a standing claim. Rejected
alternative recorded: folding case in the lookup. Learned: resolution
follows the DEFAULT_SCOPE registry value, so it is scope-dependent.
Agent-kit: the standing-claim query wraps both sides in canonical_type();
agents write the canonical type the lookup reports; type names are
case-sensitive. Chose the function over a view because the only view with
canonical types aggregates by type and cannot answer per subject and key.
Schema: rye_settlers() resolves the claim type and grant claim_types
through canonical_type(); chose it over the scoped variant because the
contracted signature has no onboarding-scope argument. Test 29 fails on
52eda43 at the first alias case with exactly the reported answer and passes
after. Full Docker flow passed on the builder's branch. Executed through
the CLI with requirement->expectation and promise->commitment aliases and
Mara granted `promise`: John/requirement/self_commitment: [Bob], false;
John/requirement/no act: [Bob], false; John/promise/no act: step grant,
[Mara], false; Mara/commitment/no act: step grant, [Mara], true;
John/Expectation/self_commitment: [John], true (pinned as documented:
case-sensitive, a different type). Learned: canonical_type() reads
current_valid_assertions, so an alias hidden by RLS or still a candidate
does not apply. Lead: asked the Verifier to check whether an agent role can
fail to see an alias and so get the raw, more permissive answer.

### Lead, 2026-09-19, integration of the alias round
Base revision 4caea84. Merged worktree-agent-ae27942de1b4935c1 (247365e)
and worktree-agent-a7f18ff71cb202bfc (002b4e4), no conflicts. Final tree
858eae2. Combined suite running.

## Close
