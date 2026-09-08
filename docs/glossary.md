# Rye Glossary

The words the business uses, one line each. These are the plain-register terms
from `docs/vocabulary-contract.md`, extended with the setup and source words
from `docs/onboarding.md`. Agents use these when addressing people; internal
identifiers stay canonical everywhere durable.

## Knowledge

- **Something that happened** — a record of an occurrence at a point in time; never changes once written.
- **Accepted knowledge** — a fact Rye will answer with, because a person accepted it or policy allowed an agent to record it.
- **Suggestion** — something an agent proposes; it does not answer questions until a person accepts it.
- **Accepting a suggestion** — a person turns a suggestion into accepted knowledge, replacing whatever it supersedes.
- **Declining a suggestion** — a person rejects a suggestion with a reason; it stays readable but never answers questions.
- **Open disagreement** — two or more suggestions that claim different things about the same subject.
- **Replaced by a newer fact** — the older version stops answering current questions but stays in the history.
- **How Rye knows it** — seen directly, heard from someone, worked out, taken on faith, or unclear.
- **Where it came from** — the original material a fact was drawn from.
- **What backs it up** — independent support for a fact, counted once per distinct original witness.
- **What it was built from** — the accepted facts a derived fact or summary rests on.
- **How sure Rye is** — Rye's current certainty about a fact, given its basis, support, age, and any open disagreement.
- **When it is true** — the period in the world during which a fact holds.
- **What Rye believed at the time** — the answer Rye would have given on a past date, ignoring anything learned since.
- **Summary** — a short account of a subject, derived from the facts and material behind it, stating as of when.
- **A summary that newer facts have outdated** — a summary Rye flags as stale because something behind it changed.
- **An open question** — something Rye knows it does not know, recorded rather than guessed.
- **A forecast** — a stated expectation about the future, kept separate from facts scheduled to become true.
- **How good the forecasts have been** — the track record of past forecasts against what happened.
- **A suggested rule of thumb** — a pattern Rye noticed, offered for confirmation, not yet treated as knowledge.
- **What people ask about most** — which subjects draw attention, used to prioritize review and summarizing.

## Categorizing what arrives

- **Category** — what type of thing something is, in the business's terms: a customer, a quote, a meeting. Called a node type or an assertion predicate internally. Not the same as who may see it.
- **Category description** — what a category means in this organization, kept in the graph so it can be improved by review rather than by editing a skill file.
- **Type profile** — everything an agent needs to use one category: its description, the properties it carries and which are required, the relationships it takes part in, and whether it is turned on in this area.
- **Discover** — the first step of the loop: asking the database which categories exist here and what each one carries, before proposing anything.
- **Classify** — the second step: deciding which category an item belongs to and stating why, then having the proposed shape checked. This is the business sense of sorting, not the security sense of classification.
- **Resolve** — the third step: checking whether the thing already exists in the graph before proposing to create it.
- **Abstain** — the agent recording that it could not decide, and why, instead of guessing or staying silent. An abstention is an outcome, not a failure.
- **Who may see it** — the sensitivity label on a fact or record that decides who it can be shown to. Called classification internally; unrelated to categories.

## Setup and governance

- **Area of the business** — the limited function or workflow Rye is assisting, with its own sources, plugins, policies, and boundary. Called a scope on the admin surface.
- **Purpose** — what an area of the business is meant to improve, in the organization's own words.
- **Boundary** — what is deliberately in scope and out of scope for an area.
- **Review policy** — one of: agents may record accepted knowledge here; agents suggest and people accept; everything waits for a person.
- **Suggestions waiting for a person** — the single list a reviewer works through.
- **Permission** — a named thing an agent is allowed to do in an area.
- **Rye admin** — the person who sets up areas, sources, and policies, and decides how much agents may do.
- **Reviewer** — the person who accepts, declines, and settles what agents propose.
- **Revisiting the scope** — a proposal to change an area's purpose or boundary, raised by recurring evidence and decided by a person.
- **Improvement cycle** — the recorded loop of goal, current constraint, and the steps being taken about it.
- **Which source is authoritative** — the recorded decision about which source settles a given kind of fact.
- **Local term** — a word this organization uses its own way, recorded so fresh agents reuse it.

## Sources and material

- **Source** — where material originated: an account, a workspace, a mailbox, a system.
- **Container** — a grouping inside a source, such as a channel, folder, or database.
- **Item** — one piece of material from a source: a message, a thread, a file, a row, a log line.
- **How Rye retrieved it** — the channel used to fetch or observe material, kept separate from where it came from.
- **Intake profile** — how a given source and channel should be collected, classified, kept, and promoted for an area.
- **Expected contexts** — the routing Rye expects for material from a source; a starting expectation, not a whitelist.
- **Holding place** — where material goes when it does not match expectations and needs a person to place it.
- **Evidence** — source material kept because a fact rests on it, or because it may be needed to replay a decision.
- **Retention class** — how long a kind of material is kept and why.
- **Source identity** — an account or name seen in a source; connecting it to a specific person is a separate, confirmed step.

## Structure

- **Plugin** — a loadable pack of vocabulary and behavior for an industry, tool, or workflow; everything not core arrives this way.
- **Skill** — an instruction pack an agent loads to work with Rye correctly.
- **Overlay** — Rye lives alongside existing systems and is never pointed at by them; removing it leaves them working.
- **Nothing is edited in place** — corrections are recorded as new entries; records of what happened never change.
