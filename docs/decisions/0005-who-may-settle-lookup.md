# 0005 — Who may settle a claim is one advisory read

Date: 2026-09-19. Status: accepted. Decided by: Architect, for work item 002.

**One function answers it, and it answers nothing else.** `rye_settlers()`
takes a subject, a claim type, an optional speaker, an optional domain, an
optional speech act, and an `as_of`, and returns the settlers with the step
that produced each one. It is `SECURITY INVOKER`, writes nothing, and refuses
nothing; the caller decides what to do with the answer. The rejected
alternative was folding the lookup into the write path straight away, so
`record_assertion()` would accept or downgrade a claim on its own. It was
declined because the constraint in the work item is deliberate: under direct
database access any session can set its own role, so an enforcing version
would be theatre until a trusted layer sets the session variables, and the
skills need to be exercised against a stable answer before anything depends on
it. Making it enforcing later is a contract break, recorded as one.

**The kind of claim is the assertion type, and nothing else.** `p_claim_type`
is matched verbatim against `domain_authorities.claim_types`, so a grant that
names `account_status` covers assertions of type `account_status` and no
registration step exists. The rejected alternative was a claim-type table
mapping topical names to assertion types, which reads tidier and would let one
grant cover a family. It was declined because it adds a vocabulary that can
drift out of step with the assertions actually written, against the project's
rule that new types are values rather than migrations, and because the fixtures
already use assertion-type-shaped claim types.

**A grant narrows by existing, and narrows further through `properties`.** If
any grant matches the claim type in the domain, the relationship defaults do
not run at all; the grant holders are the answer. Subject narrowing, which the
table has no column for, is expressed as `properties.subjects` and
`properties.subject_node_types` on the grant row, so "Bob sets expectations for
John but not for Mary" is one row with two keys in a jsonb column. The rejected
alternative was adding `subject_node_id` and `subject_node_type` columns to
`domain_authorities`. It was declined because the shape is stable and consumed
by `agent_get_context_pack()` already, because jsonb narrowing costs nothing to
add and nothing to ignore, and because a column would invite a foreign key out
of a governance table into `nodes` that the overlay rule does not want. The
honest cost is that nothing validates the keys; a typo in `subjects` makes a
grant match everything rather than nothing, which is why the contract states
that absent means all.

**Which relationship default applies is selected by the speech act, not by the
claim type.** Self, manager, and owner cannot all be right for the same
subject, and the difference between "John's commitment" and "an expectation set
on John" is not in the assertion type, it is in what was said. Speech acts are
a closed set an agent classifies anyway, so the function can own the mapping,
while claim types stay open. A null or unrecognized speech act returns the
union of whichever defaults apply rather than raising. The rejected alternative
was a per-claim-type settlement map, either seeded in a new table or declared
in the `rye-org` manifest and synced. It was declined because a manifest-synced
map makes "a person settles claims about themselves" depend on whether
`sync_plugin_metadata.sh` has run, and a seeded table makes every new claim
type a configuration step, both of which break the zero-setup requirement.

**`reports_to` and `owns` are plugin-declared edge types whose meaning is
pinned in the contract, and neither end settles them.** The manifest carries
only the name, so direction, temporal reading, and settler are stated in
`contracts/plugin-manifest.md`: `reports_to` points from the report to the
manager, `owns` from the owner to the thing, both bounded by
`effective_from`/`effective_to` and never deleted. A claim about either edge
type falls through the relationship step to the area owner, which is how the
reporting line gets settled by the area rather than by the manager who benefits
from it. The rejected alternative was recording reporting and ownership as
assertions rather than edges, which would have given them the candidate and
supersession lifecycle for free. It was declined because the lookup has to
answer "in effect on a date" cheaply and repeatedly, which is what an edge's
effective window is for, and because the graph already treats relationships as
edges everywhere else.

**A source identity is a settler only when a grant names it, and an agent is
never a settler at all.** A grant with `authority_kind` `source` and an
`authority_ref` such as `slack:U0123` is returned with `bound` false, which is
exactly the statement that an unbound channel identity is specifically
authorized; a caller passes its own speaker's source identity as
`p_speaker_ref` and compares. Agent refs are dropped before a step is chosen,
so a grant whose only holder is an agent does not count as a match and the
lookup continues, with the count kept in `excluded_agents`. The rejected
alternative was letting the caller filter agents out itself, which was declined
because the one rule the whole model rests on, that agents settle nothing,
should not be re-implemented in every skill.

**An area with no owner returns no settler and says so.** The answer carries
`step` `none`, a reason, and `setup_gap`, and exits zero from the CLI. The
rejected alternative was raising, which would have made the gap impossible to
ignore. It was declined because an exception from an advisory read teaches
callers to wrap it in a catch, and because the same empty answer arrives when
RLS hides the settler, which is not an error either. The cost is that a caller
has to read `reason` rather than trusting an empty list, and the contract says
so in as many words.

## Amendments after implementation

Date: 2026-09-19. The contract was amended to match the verified behaviour of
`schema/migrations/0021_settlement_lookup.sql`, which the Lead accepted as
written.

**`reason` is six values, not three, and only two of them are setup gaps.**
The contract named `domain_not_found`, `domain_not_resolved`, and
`area_has_no_owner`; the implementation also returns `area_owner_not_visible`,
`area_owner_is_agent`, and the fallback `no_settler_found`. They are kept
because each one tells a caller something different about who to go and fix:
the two domain reasons are the caller's own wrong or ambiguous key,
`area_has_no_owner` and `area_owner_is_agent` are an instance that was never
set up and carry `setup_gap` true, and `area_owner_not_visible` may be nothing
wrong at all beyond this caller's RLS. The rejected alternative was to collapse
the owner reasons into `area_has_no_owner`, which keeps the published set
small. It was declined because the collapsed answer sends a Rye admin to set an
owner that is already set, and because `setup_gap` would then be true for a
case that is not a gap. `reason` is typed `text` and documented as additive, so
a seventh value is not a break and callers must not switch exhaustively on it.

**An unknown explicit area key stops the lookup before the relationship step.**
Supplying `p_domain_key` that names no active area short-circuits to `step`
`none` with `domain_not_found`, so even the zero-setup self default, which
needs no area at all, is suppressed. The rejected alternative was to skip only
the grant step and let the relationship defaults answer, which is more helpful
and is what a caller who fat-fingered a key probably wanted. It was declined
because it fails open in the one situation where the caller has already
demonstrated a mistake: the statement would be recorded as accepted under a
self default, on behalf of an area that does not exist. Failing closed turns it
into a suggestion instead, which is recoverable. A caller who wants the
relationship defaults passes no area key.

**Keys are slugs, and that is a real trap worth writing down.**
`rye_slugify_key()` folds every run of characters outside `a-z0-9` to an
underscore, and both `ensure_knowledge_domain()` and the lookup apply it, so
`sales-operations` and `sales_operations` are one key. The cost is that a
`knowledge_domains` row inserted directly with a hyphenated key is unreachable:
no argument slugifies back to it, so every lookup against it answers
`domain_not_found`. The same applies to `create_agent_identity()`, where a
grant `authority_ref` of `agent:my-agent` matches no stored `my_agent` and is
therefore returned as an ordinary settler rather than excluded as an agent. The
rejected alternative was to have the lookup fall back to a literal key match
when the slug misses, which would rescue the hand-written row. It was declined
because two keys for one area is worse than one unreachable area: it would let
`sales-operations` and `sales_operations` hold different owners and different
grants. The contract now states that areas are created with
`ensure_knowledge_domain()` and that refs are written against the stored slug.
