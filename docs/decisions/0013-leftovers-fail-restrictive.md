# 0013 Leftovers fail restrictive

Date: 2026-09-20. Work item: `work/018-session-leftovers.md`.
Contracts: `contracts/sql-surface.md`, `contracts/admin-api.md`,
`contracts/category-vocabulary.md`. Areas: schema, admin, agent-kit.
Migration: `0036`. Conformance: `42`.

Five things were recorded as "known, left open" while items 001 to 011 closed.
Each is ruled here. Two of them are dismissed rather than fixed, with the reason
written down so nobody re-opens them from the same evidence.

## A. The settle gate judges the written name as well as the canonical one

`0028` refuses a new `registry_entry` whose key is
`type_alias:assertion_type:<T>` when `T` has a `settle` row, so an alias out of
a gated type cannot be recorded today. An alias recorded **before** the type was
gated is untouched by that rule and still stands. `record_assertion()` (live in
`0030`) canonicalizes at line 86 and again at 133, then reads
`assertion_settle_roles(v_assertion_type)` — the canonical spelling — so a
caller writing `review_policy` under such an alias is judged on the alias
target, which has no `settle` row, and the gate never fires.

Two ways out were on the table.

**Refuse to gate a type while an alias from it stands.** Rejected. It checks a
condition at one administrative moment, which is the wrong moment: the hole is
already open on an instance that has the alias, so the upgrade would have to
either refuse to install the gate or install it and leave the hole. And the
check itself is blind-unsafe. `canonical_type()` reads
`current_valid_assertions` under the caller's RLS and through `DEFAULT_SCOPE`,
so an alias that is classified above the gating admin's read level, or that
lives in another scope, is an alias the check cannot see — and "unrecognized" is
what a blind caller sees, which is the trap
`docs/areas/schema.md` has recorded since 2026-09-19.

**The gate judges the written name too.** Chosen. In `record_assertion()` the
settle roles become

```
v_settle_roles := coalesce(
    assertion_settle_roles(v_assertion_type),                -- canonical
    assertion_settle_roles(nullif(trim(p_assertion_type), '')) -- as written
);
```

so a type is gated when **either** spelling is gated, and the demotion's
`attrs.settle_gate` gains `gated_as`, naming the spelling that gated it, so a
reviewer can see why a write of an apparently ungated type is waiting. An alias
*into* a gated type is unaffected, because canonicalization already gated it.
`settle_gate(p_assertion_type)` answers by the same rule and gains `gated_as`
beside `gated`, so a client can still ask before it writes.

Everything else is left alone deliberately. The trigger,
`assertion_settle_gate_guard()`, keeps judging the stored spelling: it never
sees the name a caller wrote, and the stored spelling is the only one
`registry_value()` and `governing_scope()` read as configuration.
`supersede_assertion()` takes the type from the incumbent row, so there is no
written name to judge. `record_distillation()` canonicalizes and inserts an
accepted row, which the trigger refuses under the stored name; under a standing
pre-gate alias it writes the alias target instead, and the residual is stated
rather than closed: that row is an ordinary assertion of another type, Rye does
not read it as configuration, and the write is a no-op for policy rather than an
escalation.

**What an upgrade does to an instance that already holds such an alias.**
Nothing at install time: no data is rewritten, no migration refuses, and the
alias keeps resolving for every other purpose. From the first write after
`0036`, a non-admin naming the gated type gets a candidate carrying
`attrs.settle_gate` with `gated_as` set, where before it got an accepted row of
the alias target. An admin sees no change. There is nothing to clean up, and an
admin who wants the alias gone supersedes it like any other registry entry.

## B. An unsupported review policy is treated as strict, and cannot be recorded

`scope_review_policy()` (live in `0018`) raises `Unsupported review_policy % on
scope %` for any stored value outside `open`, `candidates_only`, `strict`.
Because every helper that inserts an assertion calls it, one scope carrying a
typo refuses every write it governs — and `0027` had to write
`scope_review_policy_rank()` around the raise so that one broken scope could not
refuse writes near it. A configuration mistake should make Rye careful, not
make it stop.

Five sites, and what each becomes in `0036`:

| site | now |
|---|---|
| `scope_review_policy(uuid)` (`0018`) | **replaced.** An unrecognised stored value returns `strict`. A scope with no `review_policy` assertion still returns `open`, as today: absent is not broken. It no longer raises, for any input. |
| `scope_review_policy_rank(uuid)` (`0027`) | **replaced.** `strict` 0, `candidates_only` 1, `open` 2, **anything else 0**, so ordering and selection agree. No row at all still ranks 2. |
| `effective_review_policy(...)` (`0027`) | unchanged. It composes the two above and inherits both. |
| `record_scope_policy(...)` (`0015`) | **replaced.** When `p_policy_type` is `review_policy`, a claim whose policy value is outside the three raises `Unsupported review_policy "%": use open, candidates_only, or strict` before it writes anything. A helper refusing plainly is better than a row nobody can read back. |
| `assertion_settle_gate_guard()` (`0028`) | unchanged. The value rule is not the settle gate's business and adding it there would put two unrelated refusals behind one name. |

The helper's refusal is not the rule, because Rye's rule is that the row is the
gate. A new trigger function `assertion_review_policy_value_guard()`, on
`assertions`, `BEFORE INSERT OR UPDATE ... FOR EACH ROW`, trigger
`trg_assertions_review_policy_value`, refuses any assertion whose stored
`assertion_type` is `review_policy` — or whose canonical type is, for the
caller who can resolve it — and whose policy value, extracted exactly as
`scope_review_policy()` extracts it (`claim->>'review_policy'`, then
`claim->>'value'`, then a string claim), is outside the three. It refuses **at
every status**, candidate included, so an unsupported value cannot be parked as
a suggestion and accepted later, and for **every role**, because it reads no
role at all. The name sorts after the existing guards, so a caller who is also
refused by an earlier one sees that message instead, which is fine: both are
refusals.

**An instance that already holds one** keeps the row — no migration rewrites
data — and reads `strict` for that scope from the first call after `0036`.
Writes it governs land as candidates in `review_queue` instead of being refused
with a raise, which is strictly more useful and loses nothing. The fix is an
admin recording a supported value with `record_scope_policy()`, and that works
even under the new `strict`, because `governing_scope()` returns null for a
scope node's own policy assertions.

## C. The grant-expiry gap on the domains `properties` field is dismissed

`docs/areas/admin.md` has carried "the `rye.domain.admin` gate on the domains
`properties` field does not check grant expiry" as open since 2026-09-19. On
today's tree it is **not a defect**, and the reason is one layer up.
`admin/src/server/worker.ts:544` tests
`auth.capabilities.some(g => g.capability === 'rye.domain.admin')` with no
expiry test, but `auth.capabilities` has exactly one source —
`authenticate_agent_token()` (`0016`), whose grant subquery is already
`WHERE g.agent_id = ... AND g.active = true AND (g.expires_at IS NULL OR
g.expires_at > now())`. An expired or deactivated grant is never in the array
the gate reads, so `properties` is not exposed on one.

What is true is that the safety lives in the schema and nothing pins it: delete
that `WHERE` clause and every capability test in the Worker silently widens,
including the one at line 544 and `holdsInstanceWide()`, whose own expiry test
is belt and braces. So the ruling is a test, not a fix — obligation 42.7 — and
the stale entry in `docs/areas/admin.md` is corrected rather than carried.

## D. A schema helper for "holds an instance-wide grant" is dismissed

`contracts/admin-api.md` records the one authorization question the API answers
itself, and `docs/decisions/0006-agent-tokens-deny-by-default.md` records why.
A schema helper would not remove the exception, it would move it: the API needs
the answer for the token it has just authenticated, it already holds that
token's grant rows from `authenticate_agent_token()`, and a helper would cost a
round trip per request to re-read rows the Worker has in hand. The exception is
bounded — one predicate, over data the schema returned, in the same
authorization model — and it is already written down in the contract, which is
the condition under which an exception is acceptable at all.

So no helper, no migration, and the sentence in `contracts/admin-api.md` that
says the exception "is removed when a schema helper expresses the narrower
question" stands as a standing offer rather than a plan. What the ruling does
add is obligation 42.8: the row filter is pinned from the outside, so a token
whose only `rye.review.read` grant names an area does not see area-less
candidates, whichever layer answers the question.

## E. A repeat `describe_category()` works for an agent

`describe_category()` (`0020`) upserts the category node with `ON CONFLICT ...
DO UPDATE`, and `node_update_policy` admits an `agent:*` caller's `UPDATE` only
with `app.write_path = 'update_node_properties'`. So the first description by an
agent succeeds and the second is refused, and conformance 28 never saw it
because it runs as `admin`. An agent must not set the named gate itself — the
contract is explicit that a client never sets `app.write_path` — so the function
does it: `0036` replaces `describe_category()` so that it sets
`app.write_path = 'update_node_properties'` transaction-locally around its own
upsert and clears it on the normal and the exception path, which is the
established mechanism `record_agent_action()` and `agent_create_candidate()`
already use. Nothing else about the function changes, and a `viewer` or an
unset role is still refused by the write gate, one layer below.

## F. An unknown `--scope` never falls back

`scope_sql_expr()` in `scripts/rye` turns a `--scope` key into a subquery and
passes its result straight to `rye_categories()` / `rye_agent_context()`. A key
that matches nothing yields `NULL`, which those functions read as "no scope
given" and answer with automatic scope selection — a different scope's answer,
returned without a word. An unknown uuid, by contrast, answers `scope_found:
false`, which is what `contracts/category-vocabulary.md` promises.

The rule: **an unknown `--scope` value is answered, not substituted.** The CLI
coalesces an unresolved key to the nil uuid
(`00000000-0000-0000-0000-000000000000`), so a key and a uuid take the identical
path and the function gives its documented empty answer with `scope_found`
false. `--json` prints that answer verbatim; without `--json` the CLI prints
`scope not found: <value>`; both exit non-zero, because the caller asked about
something that does not exist. The same applies to `context --scope`.

## G. What 0036 replaces

`scope_review_policy(uuid)`, `scope_review_policy_rank(uuid)`,
`record_scope_policy(...)`, `record_assertion(...)`, `settle_gate(text)`,
`describe_category(...)`; new: `assertion_review_policy_value_guard()` and its
trigger. Outside the schema: `scripts/rye` (`scope_sql_expr`).

It replaces nothing that `0031` (`node_source_map`, `merge_nodes`,
`link_record`), `0032` (`find_nodes`, `find_nodes_batch`, `find_paths`,
`neighborhood`, `edge_semantics`), `0033` (`resolve_node_identity`), `0034`
(`log_agent_query`, `agent_query_trace`), or `0035` (the
`effective_confidence` family and the review views) replaces. `0035` and `0036`
both concern candidates and both leave `record_assertion()` to `0036` and the
views to `0035`.

## Test obligations, conformance 42

Each runs under a non-superuser role and under
`scripts/test-nonsuperuser-owner.sh`, and fails rather than skips without
`0036`.

1. **42.1 A pre-gate alias no longer routes past the gate.** As `admin`, record
   an accepted `type_alias:assertion_type:review_policy` registry entry
   *before* the alias rule can see a gate — by seeding it in a transaction that
   first removes the `settle` row and restores it — then, as `team_member`,
   `record_assertion(..., 'review_policy', ...)` with status `accepted`. The row
   lands `candidate` with `attrs.settle_gate.gated_as = 'review_policy'`.
   Anti-vacuity: assert the alias resolves (`canonical_type('assertion_type',
   'review_policy')` is not `review_policy`) and that the same call as `admin`
   lands accepted.
2. **42.2 Aliasing out of a gated type is still refused.** `0028`'s rule is
   unchanged: recording that alias with the gate in place raises, at candidate
   status too.
3. **42.3 `settle_gate()` agrees.** For a gated type it reports `gated` true;
   `gated_as` is null when the given spelling is itself the gated one, and
   names the gated spelling when the given name only reaches a gated type
   through an alias (the contract's rule; corrected 2026-09-20 after
   verification, the earlier wording here said the opposite). For an ungated
   type it reports `gated` false and `gated_as` null.
4. **42.4 A broken policy value is strict, not an error.** Seed a scope whose
   `review_policy` claim is `'srtict'` by direct insert as `admin` before
   `0036`'s guard exists — or by `ALTER TABLE ... DISABLE TRIGGER` under the
   owner, whichever the suite can do honestly — then assert
   `scope_review_policy()` returns `strict`, `scope_review_policy_rank()`
   returns 0, and `record_assertion()` on a subject that scope governs lands a
   candidate with `attrs.review_gate.review_policy = 'strict'` rather than
   raising. Anti-vacuity: assert the stored claim is still the broken value.
5. **42.5 An unsupported value cannot be recorded.** `record_scope_policy(scope,
   'review_policy', '{"review_policy":"srtict"}')` raises; a direct
   `INSERT INTO assertions` of the same claim raises at status `accepted` and at
   status `candidate`; an `UPDATE` that rewrites a good value into a bad one
   raises or affects zero rows. Anti-vacuity: the same shapes with `strict`
   succeed, and no `review_policy` assertion with the bad value exists
   afterwards.
6. **42.6 A repeat description works for an agent.** Under `agent:<key>`, call
   `describe_category()` twice for one node type; both succeed, the second
   updates the existing `category` node, and `app.write_path` is empty after the
   call. Anti-vacuity: assert the category node's `updated_at` advanced and that
   the same caller's direct `UPDATE` of that node without the gate is still
   refused. Under `viewer`, both calls are refused.
7. **42.7 Expired grants reach nothing.** With `RYE_API_AUTH_MODE=required`, a
   token whose `rye.domain.admin` grant has `expires_at` in the past gets
   `GET /api/domains` without a `properties` field; with the grant unexpired it
   gets one. In `tests/conformance/21_api_security.sh`. Anti-vacuity: assert the
   unexpired case returns `properties` on the same area.
8. **42.8 The instance-wide predicate is pinned from outside.** A token whose
   only `rye.review.read` grant names an area does not see a candidate carrying
   no area keys; a token whose grant names no area does. Anti-vacuity: assert
   both tokens see the same area-keyed candidate.
9. **42.9 An unknown `--scope` answers rather than substitutes.**
   `./scripts/rye categories --scope no-such-key --json` reports
   `scope.scope_found` false with `categories` empty and exits non-zero, and its
   output differs from `./scripts/rye categories --json` on an instance with one
   active scope. Anti-vacuity: assert the unscoped call returns at least one
   category. Same for `context --scope`.

## Cost

`record_assertion()` gains one `assertion_settle_roles()` lookup per call, of a
table every session already reads. The value guard is a row-local test on
`assertions` that returns immediately for every type but one. The policy
functions get cheaper, because a branch that raised now returns. `describe_category()`
gains two `set_config()` calls. The CLI change is a `coalesce`. Nothing here
narrows a signature or moves a view column, so no contract version moves.
