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

## Close
