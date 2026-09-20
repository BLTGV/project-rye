# Intake Consistency Checks

Four reads that find the four intake defects blind reconstruction caught. Each
one is a query. None of them writes. Run them as any role that may see the
rows; a reviewer's role sees what a reviewer may act on.

The rules these enforce are stated in `docs/agent-ops-guide.md` under "Intake
consistency" and repeated in the ingesting skills. This file is about finding
existing breakage, not about writing correctly in the first place.

The same four queries, executable, are `eval/intake_consistency/checks.sql`,
with a fixture that violates each one. Edit both files together or they drift.

Each check says what it decides and what it does not. A check that returns no
rows means the query found nothing, not that the graph is consistent.

---

## 1. Departed people with an open employs or role edge

Recording that someone departed and leaving their `employs` edge open leaves
the graph contradicting its own accepted knowledge: the claim says gone, the
relationship says current.

```sql
WITH role_edge_type(edge_type) AS (
    VALUES ('employs'), ('reports_to'), ('assigned_to'),
           ('member_of'), ('project_member'), ('affiliated_with')
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
       e.effective_to,
       d.departure_assertion_id
FROM departed d
JOIN nodes n ON n.id = d.person_id
JOIN edges e ON e.source_id = d.person_id OR e.target_id = d.person_id
JOIN role_edge_type r ON r.edge_type = e.edge_type
WHERE e.archived_at IS NULL
  AND (e.effective_to IS NULL OR e.effective_to > d.departed_at)
ORDER BY n.label, e.edge_type;
```

Decides: an edge of a listed type that is still open, or open past the
departure date, on a person whose current accepted `employment_status` is
`departed`.

Does not decide:

- Edge types outside the list. The list is the core and CRM vocabulary; a
  plugin that adds its own role edge must be added to it. Read
  `type_vocabulary_report` for what this instance actually uses.
- A departure recorded under another assertion type or another claim word
  (`left`, `terminated`, `inactive`). Only `employment_status` with
  `status = 'departed'` is matched.
- A future-dated departure. `current_valid_assertions` shows what is effective
  now, so a departure taking effect next month is not in the result yet.
- An edge closed *before* the departure. That is left alone on purpose: a role
  can end before employment does.

Fixing it is a person's write. An agent-shaped session cannot update an edge:
the row is outside its policy, so the `UPDATE` reports `UPDATE 0` and changes
nothing. It does not raise. An agent reports the finding and names the edge.

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

- Which one is wrong. The assertion may be misdated, or the edge may be. Both
  need reading.
- An assertion about a relationship that names no edge at all. Nothing joins
  it. This is why `attrs.edge_id` is worth writing.
- Whether the edge is the right edge. A claim pointed at the wrong edge whose
  window happens to contain the date passes.
- An assertion with no `effective_at`. Undated claims are excluded, not
  approved.

---

## 4. Derived numeric claims and their source window

A derived number without the window it was computed over cannot be checked or
recomputed. Two shapes are findable: a window that is missing, and a window
that does not contain the sources it claims to cover.

The convention: a derived claim carries
`attrs.source_window = {"from": <timestamptz>, "to": <timestamptz>}`, in ISO
8601, covering the material the number came from.

### 4a. No window cited

```sql
WITH derived AS (
    SELECT a.id, a.assertion_type, a.assertion_key, a.claim, a.attrs
    FROM assertions a
    WHERE a.superseded_at IS NULL
      AND (a.basis = 'inferred' OR a.assertion_type = 'digest')
      AND jsonb_typeof(a.claim) = 'object'
      AND EXISTS (
          SELECT 1 FROM jsonb_each(a.claim) v
          WHERE jsonb_typeof(v.value) = 'number'
      )
)
SELECT d.id AS assertion_id,
       d.assertion_type,
       d.assertion_key,
       d.attrs->'source_window' AS cited_window
FROM derived d
WHERE d.attrs#>>'{source_window,from}' IS NULL
   OR d.attrs#>>'{source_window,to}'   IS NULL
   OR d.attrs#>>'{source_window,from}' !~ '^\d{4}-\d{2}-\d{2}'
   OR d.attrs#>>'{source_window,to}'   !~ '^\d{4}-\d{2}-\d{2}'
ORDER BY d.id;
```

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

Decides: a live derived claim carrying a JSON number whose cited window is
absent, incomplete, or not shaped like a date; and a cited window that does not
contain the time of a source it cites.

Does not decide:

- A derived measurement rendered as text. `{"peak_hour":"09:00Z"}` is a string,
  so 4a does not see it. The rule still binds; the query catches the numeric
  part of it. Write the number as a number.
- Whether the number is right. A window can be correct and the arithmetic
  wrong.
- Whether the window is the *intended* one. A window covering both September
  and a stray August source passes 4b while being wider than what was counted.
- Material that is not recorded as evidence. A number computed from an artifact
  nobody cited has nothing to compare, and nothing in the schema requires the
  citation.
