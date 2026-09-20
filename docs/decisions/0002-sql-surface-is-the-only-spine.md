# 0002 — The SQL surface is the only spine

Date: 2026-09-07. Status: accepted. Decided by: Architect, at bootstrap.

**Every area is a client of the `rye` schema; no area holds state the schema
does not hold.** The admin console, the CLI, and an agent's raw `psql`
session all reach the same helper functions and the same views, and none of
them caches, mirrors, or re-derives what the database already knows. The
rejected alternative was making the admin API the canonical interface and
having agents go through it — the usual shape, and it would have given us one
place to enforce rules. It was declined because Rye's whole claim is that it
installs into a customer's existing database and leaves nothing else running:
an API that must be deployed before the data is usable would make the console
a dependency of the product rather than a view onto it. The cost is that
enforcement has to live in the database — RLS, triggers, and refusing helpers
— which is harder to write than application-tier checks and is the reason the
conformance suite is as large as it is.

**Authorization is session variables, in one model, with the admin API's
bearer tokens layered on top rather than beside.** A token authenticates an
agent and then sets `app.current_role`, `app.current_user_id`, and
`app.current_teams`; it never grants what those variables would not. The
rejected alternative was letting the API hold its own permission table and
query as a privileged role, which is faster to build and would have let the
console show a reviewer everything. It was declined because two
authorization models eventually disagree, and the one that disagrees silently
is the one in the app tier.

**Contracts are written for the four interfaces that already have two sides,
and no others.** `sql-surface`, `rye-cli`, `admin-api`, `plugin-manifest`,
and `docs-content` each have a named publisher and a named consumer with a
test that crosses the seam. The rejected alternative was writing a contract
per component — including one for `surfaces/` and one for the eval harness —
which was declined because nobody consumes them; a contract with one side is
documentation pretending to be a promise. `docs-content` is the marginal
case, kept only because the site's build reads directories two other areas
own, so a documentation edit really can break a deploy.

**Breaking changes to a contract require the contract edited first, then a
decision record, then the code.** All five contracts are additive by default:
new routes, new functions, new manifest fields, new pages. Removal, renaming,
and narrowing are the breaking set. The rejected alternative was versioning
the interfaces — a `/v2/` API path, a `rye_v2` schema — which was declined at
this stage because there is one consumer of each interface and it lives in
this repository; versioning buys nothing until someone outside it depends on
a shape we want to change.
