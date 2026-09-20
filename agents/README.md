# Agent roles

One human. One Lead session the human talks to. Five roles the Lead
dispatches. Everything a role needs arrives as files; nothing arrives as a
transcript.

| Role | Owns | Answers | Writes code? |
|---|---|---|---|
| Lead | `work/`, the loop, what to ask the human | what next, who does it | no |
| Product | `docs/product.md`, `docs/glossary.md` | should we, what does done mean | no |
| Architect | `docs/architecture.md`, `docs/areas.md`, `contracts/`, `docs/decisions/` | where does it go, what is the interface | contracts only |
| Builder:area | the paths listed for its area in `docs/areas.md` | how | yes, in its area |
| Verifier | nothing | does the diff meet the work item and contracts | never edits |
| Operator | `infra/`, CI, deploy scripts, `docs/runbooks/` | how does it run | infra only |

Builders are generated, one per area in `docs/areas.md`. The other five are
fixed. The prompts in this directory are the single source; the files under
`.claude/agents/`, `.opencode/agents/`, and `.codex/` are rendered from them
by `scripts/gen-agents`.

## Files

```
BRIEF.md                 the human's intent, in prose (written by the human)
docs/product.md          users, goals, non-goals, stories with acceptance criteria
docs/glossary.md         the business's words, one line each
docs/architecture.md     components, data flow, key decisions
docs/areas.md            the areas; drives builder generation
docs/areas/<area>.md     the area record: what a stranger would need to know
docs/decisions/NNNN-*.md one paragraph per decision
contracts/<name>.md      one interface between areas per file
work/NNN-<slug>.md       one work item per task
agents/<role>.md         role prompts (this directory)
scripts/gen-agents       renders role prompts into each tool's format
```

## Bootstrap from scratch

1. Human writes `BRIEF.md`.
2. Lead dispatches Product with the brief. Product writes `docs/product.md`
   and `docs/glossary.md` and returns questions. Human answers by editing
   the brief.
3. Lead dispatches Architect. Architect writes `docs/architecture.md`,
   `docs/areas.md`, `contracts/`, and the first decision record.
4. Lead runs `scripts/gen-agents`. One builder per area now exists.
5. Lead dispatches Operator to set up the test runner, CI, and one deploy path.
6. Work begins.

Rerun `scripts/gen-agents` whenever `docs/areas.md` or a role prompt changes.

## The loop

1. Human gives the Lead a task.
2. Lead writes `work/NNN-<slug>.md` from `work/TEMPLATE.md`. If acceptance
   criteria are unclear, Product is dispatched first.
3. If a contract changes, Architect edits it first and writes a decision.
4. Lead dispatches one Builder per area, in parallel, isolated on a worktree
   or branch, each with the work item, its area record, and the contracts it
   touches.
5. Lead dispatches Verifier with the diff and the work item. On fail, the
   builder gets only the findings. Two fails and the human gets the PR.
6. Operator handles CI and deploy when affected.
7. Lead appends what builders learned to `docs/areas/<area>.md` and closes
   the work item.

The human is interrupted at three points only: ambiguous intent, a tradeoff
with business consequences, or verification failing twice.

## Report format

Every role returns one report and nothing else:

```
## Result
one line: done / blocked / failed

## Changed
files, or "none"

## Tested
commands run and their result, or "none"

## Learned
facts about this area a stranger would not know; dated; or "none"

## Questions
each with the answer you would assume if nobody replies; or "none"
```

Under 300 words. The Lead copies "Learned" into the area record.

## Areas format

`docs/areas.md` is parsed by the generator. One `##` heading per area, slug
only, then `- key: value` lines. `invariants`, `publishes`, and `consumes`
may be lists.

```
## billing
- purpose: Invoices and payments for organizations.
- paths: src/billing/**, tests/billing/**
- invariants:
  - Never double-charge; every charge is idempotent by invoice id.
- publishes: contracts/invoice-events.md
- consumes: contracts/metering-feed.md
- test: npm test -- billing
```

An area earns existence when it has its own paths, its own test command, and
an interface something else calls. Start with one to three. Split when a
builder's briefing exceeds a page or its paths span two deploy units. Merge
two when most work items touch both.

## Per tool

**Claude Code.** `CLAUDE.md` imports `AGENTS.md` and `agents/lead.md`, so the
main session is the Lead. Roles are `.claude/agents/<role>.md`, dispatched
with the Agent tool. Use worktree isolation for parallel builders.

**OpenCode.** `AGENTS.md` is read automatically. The Lead is
`.opencode/agents/lead.md` with `mode: primary`; select it in the TUI. Roles
are subagents, invoked by `@role` or the Task tool.

**Codex.** `AGENTS.md` is read automatically. Roles are the standalone
files in `.codex/agents/<role>.toml` (name, description, developer
instructions), which Codex discovers on its own; `.codex/config.toml` only
turns multi-agent on. The interactive session is the Lead and spawns roles
with the spawn-agent tool.

**Limits to know.** No tool lets a prompt file restrict which paths an agent
may edit, so "writes only under docs/" is an instruction, not an enforced
permission. The Verifier's shell access could in principle write files; it
is told not to. Claude Code worktree isolation is chosen by the Lead at
dispatch time, not in the agent file.
