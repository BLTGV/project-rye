## 1. Is the six-role model useful or ceremony?

**The durable area records are useful. Six mandatory roles are ceremony.** You have nine generated agents before completing one real feature. The design partitions Builders by knowledge but surrounds them with five roles partitioned by verbs.

Keep Lead, area Builders, and an independent Verifier. Fold `agents/product.md` and `agents/architect.md` into optional checklists used by `agents/lead.md`. Retain `agents/operator.md` for deployment work; ordinary CI fixes should belong to the implementing Builder.

In [agents/README.md](/home/casey/git/project-rye/agents/README.md), replace mandatory parallel dispatch with one Builder per coherent change, allowing multiple areas when necessary. Permit Lead to make small fixes directly. Independence matters most at verification.

Keep `work/TEMPLATE.md`, area records, and short reports. Turn `contracts/docs-content.md` into site documentation. Reserve decision records for consequential choices, rather than requiring Architect dispatch for every interface adjustment.

## 2. Are the four areas right?

**They are a reasonable repository map, but deploy units are the wrong justification for knowledge boundaries.** The v0.3 mission needs two central bodies of knowledge:

- **schema:** lifecycle, authorization, identity resolution, query behavior, and database validation.
- **agent-kit:** vocabulary discovery, categorization guidance, skills, manifests, and behavioral evaluations.

Keep admin and site as secondary areas invoked when affected. Do not create separate discover, classify, and resolve Builders: understanding those steps together is essential.

Fix [docs/areas.md](/home/casey/git/project-rye/docs/areas.md) and decision `0001`: API and MCP integration tests should follow the behavior they test. Owning different test files does not require owning different runners. Assign `21_api_security.sh` to admin and `22_secure_mcp_simulation.sh` to agent-kit; classify the remaining integration coverage similarly.

The current split explicitly prevents agents from updating their own strongest tests. That is manufactured coordination cost.

## 3. Where will the loop break?

**It already broke at intent capture.** `work/000-bootstrap.md` closes successfully while unanswered defaults establish a required screen, remote onboarding targets, and source-sampling policy. File existence and passing existing tests do not establish alignment with your mission.

Next comes contract fiction: `contracts/plugin-manifest.md` promises invalid manifests never sync, while the area record admits no validator enforces that promise. `docs/product.md` permits accepted agent writes under policy; agent-kit’s invariant categorically forbids them.

Change [agents/lead.md](/home/casey/git/project-rye/agents/lead.md) and the work template to distinguish owner decisions, provisional assumptions, and verified behavior. Give Builders the relevant intent excerpt and permission to inspect neighboring code. Area records should guide investigation, not replace it.

The integration step is also missing: specify base revision, returned commits, merge owner, and verification of the combined result. Worktrees do not isolate Docker’s fixed port `54329`.

Replace “two FAILs” with escalation after two unsuccessful fixes to the same substantive problem. Environment failures need diagnosis. Curate and supersede area learnings; blindly appending creates contradictory instructions.

## 4. What should the first three work items be?

1. **`work/001-v03-mission-and-baseline.md` — Establish the actual target.** Put the August 19 framing into `BRIEF.md`; revise `docs/product.md` and `docs/roadmap.md`. Add a small replay fixture demonstrating the missing discovery/classification behavior and existing resolution capability. Distinguish business categorization from security classification. **Touches:** Lead-owned product documents, agent-kit, schema.

2. **`work/002-discover-categorization-context.md` — Make available categories inspectable.** Extend existing catalogs/context where needed to expose enabled vocabulary, meanings, expected properties, and validation constraints, including categories with no instances yet. An agent must distinguish unavailable, unknown, and disabled categories. Validate manifests before synchronization. **Touches:** schema and agent-kit; SQL, CLI, and manifest contracts.

3. **`work/003-classify-then-resolve.md` — Complete one usable loop.** Given an item, a freshly started agent discovers categories, explains its classification, validates the proposed shape, and invokes existing resolution before proposing creation. Replay cases must cover an existing entity, a new entity, ambiguity, invalid properties, and no matching category. Require abstention when evidence is insufficient. **Touches:** agent-kit and schema. Add admin work only if this exercise demonstrates a concrete need.

## 5. Will the generated adapters work?

**Do not accept “TOML parses” as adapter validation.**

- **Claude/OpenCode:** All eight generated Builder Markdown files fail standard YAML parsing: descriptions contain unquoted `: `. I reproduced this locally. Quote descriptions in [scripts/gen-agents](/home/casey/git/project-rye/scripts/gen-agents). Both tools document YAML frontmatter. [Claude documentation](https://code.claude.com/docs/en/subagents), [OpenCode documentation](https://opencode.ai/docs/agents/).
- **All adapters:** `area_block()` splits invariant sentences into individual word bullets. Preserve list entries intact.
- **Codex:** Current documentation discovers standalone `.codex/agents/*.toml` files requiring `name`, `description`, and `developer_instructions`. These files omit the first two; the generator uses the older registration layout. Its global `enabled` and `max_concurrent_threads_per_session` settings are valid. Remove the absolute-path requirement. [Codex documentation](https://learn.chatgpt.com/docs/agent-configuration/subagents).
- **Isolation/permissions:** Claude Builders omit `isolation: worktree`. Verifier’s Bash access permits writes; Codex ignores the source `edit: deny` when rendering. OpenCode’s `./scripts/*` allowance includes installation scripts, while actual build commands can prompt. These are unenforced intentions.

Provider model availability and live dispatch remain unverified.

**Directional verdict:** Keep the area memory, concrete work items, and independent verification. Cut compulsory handoffs, repair the adapters, and make discover→classify→resolve the organizing product test. The branch currently formalizes assumptions faster than it validates them.