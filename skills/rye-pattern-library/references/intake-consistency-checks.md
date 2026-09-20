# Intake Consistency Checks

Reads that find the four intake defects blind reconstruction caught. Each one
is a query. None of them writes. Run them as any role that may see the rows; a
reviewer's role sees what a reviewer may act on.

The rules these enforce are stated in `docs/agent-ops-guide.md` under "Intake
consistency" and repeated in the ingesting skills. This file is about finding
existing breakage, not about writing correctly in the first place.

The same queries, executable, are `eval/intake_consistency/checks.sql`, with a
fixture that violates each one. Edit both files together or they drift.

Each check says what it decides and what it does not. A check that returns no
rows means the query found nothing, not that the graph is consistent.

## What each one reads

| Check | Reads |
|---|---|
| 1 | accepted knowledge only, through `current_valid_assertions` |
| 1s | accepted knowledge and live suggestions |
| 2, 3, 4a, 4b | every live row, suggestions included |

This matters under a review policy. When an agent's departure write is demoted
to a suggestion, check 1 goes quiet — `current_valid_assertions` does not show
it — while the edges stay open. Check 1s is the one to run then, and its
`departure_status` column says whether a person has accepted the departure yet.
Checks 2, 3 and 4 filter on `superseded_at IS NULL` and see suggestions
already, so a pending suggestion that breaks one of those rules is reported
whatever the policy is.

---

## 1. Departed people with an open employs or role edge

Recording that someone departed and leaving their `employs` edge open leaves
the graph contradicting its own accepted knowledge: the claim says gone, the
relationship says current.

### The edge type list

The list in the query is derived from `plugins/*/rye-plugin.json`. To re-derive
it: read `contributes.edge_types` from every plugin manifest, keep the types
that attach a person to an organization, a team, a piece of work, or an
account, and drop the rest. Today that is:

| Plugin | Types kept | Disposition |
|---|---|---|
| rye-crm | `employs`, `affiliated_with`, `assigned_to`, `pipeline_member`, `territory_member`, `primary_contact`, `secondary_contact` | close |
| rye-org | `member_of`, `reports_to` | close |
| rye-org | `owns`, `responsible_for` | handoff |
| rye-project-management | `assigned_to`, `project_member`, `sprint_member` | close |

Dropped as not person-role edges: `campaign_target`, `targets`, `referral`,
`contains`, `subtask_of`, `blocks`, `depends_on`, `milestone_target`,
`regarding`, `originated_from`, and everything contributed by
rye-source-context, rye-logging, rye-evidence-anchor, rye-change-tracking,
rye-tabular-intake and rye-declared-knowledge.

**Close and handoff are different.** A membership or an assignment ends when
the person leaves. Something they *own* does not: closing an `owns` edge
leaves the thing unowned, which is a worse record than a stale one. The check
reports both, with a `disposition` column. Only the `close` rows may be ended
in one statement. A `handoff` row needs a person to name the successor; then
the new edge opens and the old one ends on the same date.

`type_vocabulary_report` says what this instance actually uses. A plugin that
adds its own person-role type has to be added to the list; nothing derives it
at runtime.

### Check 1 — accepted departures

```sql
WITH role_edge_type(edge_type, disposition) AS (
    VALUES ('employs', 'close'), ('affiliated_with', 'close'),
           ('reports_to', 'close'), ('member_of', 'close'),
           ('assigned_to', 'close'), ('project_member', 'close'),
           ('sprint_member', 'close'), ('pipeline_member', 'close'),
           ('territory_member', 'close'),
           ('primary_contact', 'close'), ('secondary_contact', 'close'),
           ('owns', 'handoff'), ('responsible_for', 'handoff')
),
departed AS (
    SELECT a.subject_node_id AS person_id,
           a.id              AS departure_assertion_id,
           a.effective_at    AS departed_at
    FROM current_valid_assertions a
    WHERE a.assertion_type = 'employment_status'
      AND a.claim->>'status' = 'departed'
      AND a.subject_node_id IS NOT NULL
)
SELECT n.label        AS person,
       d.departed_at,
       e.id           AS open_edge_id,
       e.edge_type,
       r.disposition,
       e.effective_to,
       d.departure_assertion_id
FROM departed d
JOIN nodes n ON n.id = d.person_id
JOIN edges e ON e.source_id = d.person_id OR e.target_id = d.person_id
JOIN role_edge_type r ON r.edge_type = e.edge_type
WHERE e.archived_at IS NULL
  AND (e.effective_to IS NULL
       OR d.departed_at IS NULL
       OR e.effective_to > d.departed_at)
ORDER BY n.label, e.edge_type;
```

### Check 1s — suggestions counted too

Same query with the `departed` CTE reading `assertions` directly, and a
`departure_status` column:

```sql
departed AS (
    SELECT a.subject_node_id AS person_id,
           a.id              AS departure_assertion_id,
           a.status          AS departure_status,
           a.effective_at    AS departed_at
    FROM assertions a
    WHERE a.assertion_type = 'employment_status'
      AND a.claim->>'status' = 'departed'
      AND a.subject_node_id IS NOT NULL
      AND a.status IN ('accepted', 'candidate')
      AND a.superseded_at IS NULL
)
```

A rejected suggestion keeps status `candidate` and gets `superseded_at`, so the
filter above leaves it out. Full text in `eval/intake_consistency/checks.sql`.

Decides: an edge of a listed type that is still open, or open past the
departure date, on a person Rye knows to have departed.

Does not decide:

- Edge types outside the list, including any a future plugin adds.
- A departure recorded under another assertion type or another claim word
  (`left`, `terminated`, `inactive`). Only `employment_status` with
  `status = 'departed'` is matched.
- A future-dated departure, for check 1: `current_valid_assertions` shows what
  is effective now. Check 1s sees it.
- Whether a `handoff` row should end at all, or who should take the thing.
- An edge closed *before* the departure. Left alone on purpose: a role can end
  before employment does.
- A departure with `effective_at` NULL. The row is reported — the date column
  is just empty — and no repair can clear it, because there is no date to
  close the edge on. Get the date.

Fixing a `close` row is a person's write. An agent-shaped session cannot update
an edge: the row is outside its policy, so the `UPDATE` reports `UPDATE 0` and
changes nothing. It does not raise. An agent reports the finding and names the
edge.

---

## 2. Digest claim keys no source assertion covers

A digest rests on its source assertions. A key in the digest claim that no
source claim carries is the digest saying more than it was given.

```sql
WITH digest AS (
    SELECT a.id, a.assertion_key, a.claim
    FROM assertions a
    WHERE a.assertion_type = 'digest'
      AND a.superseded_at IS NULL
      AND jsonb_typeof(a.claim) = 'object'
),
digest_key AS (
    SELECT d.id, d.assertion_key, k.key AS claim_key
    FROM digest d
    CROSS JOIN LATERAL jsonb_object_keys(d.claim) AS k(key)
    WHERE k.key NOT IN ('as_of', 'summary', 'narrative', 'source_window')
),
source_key AS (
    SELECT ae.assertion_id AS id, k.key AS claim_key
    FROM assertion_evidence ae
    JOIN assertions s ON s.id = ae.source_assertion_id
    CROSS JOIN LATERAL jsonb_object_keys(s.claim) AS k(key)
    WHERE ae.kind = 'derivation'
      AND jsonb_typeof(s.claim) = 'object'
)
SELECT dk.id AS digest_assertion_id,
       dk.assertion_key AS facet,
       dk.claim_key AS uncovered_key
FROM digest_key dk
WHERE NOT EXISTS (
    SELECT 1 FROM source_key sk
    WHERE sk.id = dk.id AND sk.claim_key = dk.claim_key
)
ORDER BY dk.id, dk.claim_key;
```

Decides: key coverage. `record_distillation()` writes one `derivation`
evidence row per source assertion, so the source claims are always joinable
from the digest.

Does not decide, and this is the larger part:

- Whether a value is supported. A digest can carry `status` with a value no
  source states and pass this check.
- Prose. `summary` and `narrative` are skipped because a sentence has no keys
  to compare. A narrative that goes beyond its sources is not findable by
  query. It needs a reader.
- Same key, different meaning. Two sources using `status` for different things
  count as coverage here.
- A digest whose claim is not a JSON object.
- A digest over a subject whose sources were later superseded. Read
  `stale_digests` for that; it is a different question.

So this check is a floor, not a verdict. Read the digest against
`assertion_support` before trusting it.

---

## 3. Assertions whose effective date disagrees with the edge window

A claim about a relationship and the relationship's own window have to tell
one story. When they disagree, a question about who owned what in June gets
two answers depending on which one is read.

```sql
WITH named_edge AS MATERIALIZED (
    SELECT a.id, a.assertion_type, a.assertion_key, a.effective_at,
           a.subject_edge_id AS edge_id
    FROM assertions a
    WHERE a.superseded_at IS NULL
      AND a.subject_edge_id IS NOT NULL
      AND a.effective_at IS NOT NULL
    UNION ALL
    SELECT a.id, a.assertion_type, a.assertion_key, a.effective_at,
           (a.attrs->>'edge_id')::uuid
    FROM assertions a
    WHERE a.superseded_at IS NULL
      AND a.subject_edge_id IS NULL
      AND a.effective_at IS NOT NULL
      AND a.attrs->>'edge_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
)
SELECT ne.id AS assertion_id,
       ne.assertion_type,
       ne.assertion_key,
       ne.effective_at,
       e.id AS edge_id,
       e.edge_type,
       e.effective_from,
       e.effective_to
FROM named_edge ne
JOIN edges e ON e.id = ne.edge_id
WHERE (e.effective_from IS NOT NULL AND ne.effective_at < e.effective_from)
   OR (e.effective_to   IS NOT NULL AND ne.effective_at >= e.effective_to)
ORDER BY ne.id;
```

Decides: a live assertion whose `effective_at` falls outside the window of the
edge it is about, for the two ways an assertion names an edge — as
`subject_edge_id`, or through the `attrs.edge_id` convention for a claim whose
subject is a node but whose meaning is a relationship.

Does not decide:

- **An edge with `effective_from` and `effective_to` both NULL.** There is no
  window to disagree with, so a claim dated 2020 on such an edge is never
  flagged. An unbounded edge is a real modeling choice, not a defect, and the
  query cannot tell the two apart. `eval/intake_consistency/` plants one of
  these on purpose; it is silent before and after repair.
- Which one is wrong. The assertion may be misdated, or the edge may be. Both
  need reading.
- An assertion about a relationship that names no edge at all. Nothing joins
  it. This is why `attrs.edge_id` is worth writing.
- An `attrs.edge_id` that is not a uuid, or points at an edge that does not
  exist. Both are skipped rather than reported.
- Whether the edge is the right edge. A claim pointed at the wrong edge whose
  window happens to contain the date passes.
- An assertion with no `effective_at`. Undated claims are excluded, not
  approved.

---

## 4. Numeric claims and their source window

A derived number without the window it was computed over cannot be checked or
recomputed. Two shapes are findable: a window that is missing, and a window
that does not contain the sources it claims to cover.

The convention: a claim carrying a computed number also carries
`attrs.source_window = {"from": <timestamptz>, "to": <timestamptz>}`, in ISO
8601, covering the material the number came from.

### 4a. No window cited

```sql
WITH not_a_measurement(assertion_type) AS (
    VALUES ('registry_entry'), ('review_policy'), ('scope_status')
),
numeric_claim AS (
    SELECT a.id, a.assertion_type, a.assertion_key, a.basis, a.attrs
    FROM assertions a
    WHERE a.superseded_at IS NULL
      AND jsonb_typeof(a.claim) = 'object'
      AND a.assertion_type NOT IN (SELECT assertion_type FROM not_a_measurement)
      AND EXISTS (
          SELECT 1 FROM jsonb_each(a.claim) v
          WHERE jsonb_typeof(v.value) = 'number'
      )
)
SELECT c.id AS assertion_id,
       c.assertion_type,
       c.assertion_key,
       c.basis,
       c.attrs->'source_window' AS cited_window
FROM numeric_claim c
WHERE c.attrs#>>'{source_window,from}' IS NULL
   OR c.attrs#>>'{source_window,to}'   IS NULL
   OR c.attrs#>>'{source_window,from}' !~ '^\d{4}-\d{2}-\d{2}'
   OR c.attrs#>>'{source_window,to}'   !~ '^\d{4}-\d{2}-\d{2}'
ORDER BY c.assertion_type, c.id;
```

**There is deliberately no basis filter.** An earlier draft restricted this to
`basis = 'inferred'` or `assertion_type = 'digest'`, and it hid the defect it
was written for: a message count read off a week's export, recorded with basis
`observed`, escaped entirely. Basis says how Rye came to know a number. It says
nothing about whether the number was computed over a period.

The price is noise. Every live claim carrying a JSON number is listed, and most
of them are attributes rather than measurements: `deal_value {"amount": ...}`,
`lead_score {"score": ...}`, `win_probability`, a headcount, a floor number.
None of those need a window. Triage by reading the type: a number that is a
property of the subject at a point in time needs no window; a number computed
over a period does. The query cannot tell them apart, and a list that has to be
read is better than a filter that hides the one row that mattered.

`not_a_measurement` exists so the install's own rows do not drown the result —
Rye's configuration types carry numbers (the basis priors are
`registry_entry` claims) and are settings, not claims about the world. Add
local attribute types to it when the noise is not worth reading, and say in the
report which types were excluded.

### 4b. Window cited, sources outside it

```sql
WITH windowed AS MATERIALIZED (
    SELECT a.id,
           (a.attrs#>>'{source_window,from}')::timestamptz AS window_from,
           (a.attrs#>>'{source_window,to}')::timestamptz   AS window_to
    FROM assertions a
    WHERE a.superseded_at IS NULL
      AND a.attrs#>>'{source_window,from}' ~ '^\d{4}-\d{2}-\d{2}'
      AND a.attrs#>>'{source_window,to}'   ~ '^\d{4}-\d{2}-\d{2}'
),
source_time AS (
    SELECT ae.assertion_id AS id, 'event' AS source_kind,
           ev.id AS source_id, ev.occurred_at AS source_at
    FROM assertion_evidence ae
    JOIN events ev ON ev.id = ae.event_id
    WHERE ae.kind IN ('source', 'corroboration')
      AND coalesce(ae.attrs->>'role', '') <> 'distillation_record'
    UNION ALL
    SELECT ae.assertion_id, 'assertion',
           s.id, coalesce(s.effective_at, s.asserted_at)
    FROM assertion_evidence ae
    JOIN assertions s ON s.id = ae.source_assertion_id
    WHERE ae.kind = 'derivation'
)
SELECT w.id AS assertion_id,
       st.source_kind,
       st.source_id,
       st.source_at,
       w.window_from,
       w.window_to
FROM windowed w
JOIN source_time st ON st.id = w.id
WHERE st.source_at < w.window_from
   OR st.source_at > w.window_to
ORDER BY w.id, st.source_at;
```

The `distillation_record` exclusion matters: `record_distillation()` attaches
the distillation event itself as source evidence, and that event happened when
the digest was written, not during the period the digest covers.

Decides: a live claim carrying a JSON number whose cited window is absent,
incomplete, or not shaped like a date; and a cited window that does not contain
the time of a source it cites.

Does not decide:

- Which listed rows are measurements. See the noise note above.
- A derived measurement rendered as text. `{"peak_hour":"09:00Z"}` is a string,
  so 4a does not see it. The rule still binds; the query catches the numeric
  part of it. Write the number as a number.
- A number nested inside an array or a sub-object. `jsonb_each` reads
  top-level values only.
- Whether the number is right. A window can be correct and the arithmetic
  wrong.
- Whether the window is the *intended* one. A window covering both September
  and a stray August source passes 4b while being wider than what was counted.
- Material that is not recorded as evidence. A number computed from an artifact
  nobody cited has nothing to compare, and nothing in the schema requires the
  citation.
- A malformed window that does not start with a date. 4a reports it; 4b skips
  it rather than raising on the cast.
