# 015 retrieval-eval-and-tracing

- status: open
- opened: 2026-09-20
- areas: agent-kit (eval/ and skills), schema (one convention)
- contracts: contracts/sql-surface.md (one paragraph, Architect)
- base revision: 6aabedd on main
- supersedes: pull request 22 (branch eval/retrieval-harness). Closes issue 21. Part of issue 17.

## Goal
Retrieval can be measured. An agent's search is a loop, so the final answer cannot say why it failed; the trace can. Pull request 22 adds the eval-time half: a harness that scores a recorded trace and assigns a mechanical cause to each miss. Issue 21 asks for the production half too: a way to group the `agent_query` events of one reformulation loop, opt-in, without making any read surface write.

## Acceptance criteria
- [ ] Pull request 22's harness lands under eval/retrieval/ as written, runs against a database that has work/013's functions, and its scorer's buckets are demonstrated on the example trace and on at least one failing trace per bucket.
- [ ] The harness writes nothing to the database and does not depend on production tracing, so a read-only agent can be evaluated.
- [ ] Production tracing is a convention on `log_agent_query()`: a correlation id and a sequence number within it, and which phrasing produced the candidate that was used, carried in the event's properties. Opt-in and caller-driven. Signature-compatible: existing callers keep working. Under the write gate a viewer or role-less session cannot log, and the skill says a read-only agent does not.
- [ ] Nothing auto-logs inside find_nodes, find_paths, or the neighborhood read; a test pins it.
- [ ] Issue 21's open questions are answered in the contract paragraph: capture layer, ordering, whether rejected candidates are recorded, retention.
- [ ] The knowledge-reader and agent-ops skills describe the convention in plain words. ./scripts/test-all.sh passes.

## Constraints
- Migration 0034 and conformance 40 only if the convention needs schema; if it is properties-only, say so and add no migration. Depends on work/013 being on the tree.
- No applied migration is edited: 0001 to 0030 and 0100 to 0124 are applied on main. Every function declares search_path. Authorization is session variables only: no current_user, session_user, or pg_has_role().
- Write gate (work/009): viewer and role-less sessions write nothing; new supporting-table rules call rye_may_write_table(). Review policy holds on every route (work/010). Tests run under a non-superuser role AND under scripts/test-nonsuperuser-owner.sh, fail without the new migration, and refuse to pass vacuously.
- No GitHub Actions and no .github/ files. The gate is ./scripts/test-all.sh run locally with your own COMPOSE_PROJECT_NAME and RYE_POSTGRES_PORT. Run ./scripts/bootstrap-worktree.sh first in a worktree, never in the main checkout. No /tmp scratch. No push; the Lead opens the pull request.
- No customer names. Invented names only.

## Decided by the human
- 2026-09-20, Casey: take all outstanding issues and merge them to main through issues and pull requests.
- Issue 21: production tracing cannot be mandatory; no new events table; no auto-logging in read surfaces.

## Assumed by default
- Cohort digests and the optional semantic index stay open on issue 17: the issue gates them on numbers from this harness on real tenant data, and no production instance is touched. Overturn: Casey.

## Verified
- filled in at close

## Reports

## Close
status line and date
