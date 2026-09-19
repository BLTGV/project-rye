# Cookbook: Small Product Team

## Two Developers, GitHub Issues and PRs, and Feedback From Calls, Chat, and Email

---

## The Problem

Quillstone is two developers. Ines Vaz and Tomas Reeder build an API together.
Work lives in GitHub: issues, pull requests, release tags. Feedback arrives
somewhere else. A customer mentions something on a Fathom call. Another types
it into a shared Slack channel. A third emails support.

Each of those is read once and then gone. Four questions have no answer:

- Why did we build this?
- Who asked for it?
- What did we promise that customer?
- What is asked for most often and has no issue at all?

GitHub holds the work, not the reasons. Rye records the reasons and points at
the work.

Examples below use `'<...>'::uuid` where a real script would pass an id it
already holds. The sections run in order: section 3 creates the people,
components, area, and agents that everything after it refers to.

Set the session context once, at the top of the session. Plain `SET`, not
`SET LOCAL`:

```sql
SET search_path = rye, public, pg_catalog;
SET "app.current_user_id" = 'user:ines';
SET "app.current_teams" = 'product';
SET "app.current_role" = 'operator';
```

`SET LOCAL` only lasts for the current transaction, so pasted outside a
`BEGIN` it warns and sets nothing, and every later statement runs with no
role. Use `SET LOCAL` inside an explicit `BEGIN` block. With a pooled or
per-call SQL tool, neither form carries over: set the context with
`set_config()` in the same call as the query. See the Supabase notes in
`AGENTS.md`.

---

## 1. What Lives Where

GitHub stays the system of record for work. Rye never mirrors an issue body or
a comment thread. It records identity and lifecycle, and points back.

| Thing | Where it lives | What Rye holds |
|---|---|---|
| Issue text, comments, labels | GitHub | Nothing |
| PR diff, review threads | GitHub | Nothing |
| Issue identity and lifecycle | GitHub | A `task` node, a source mapping, events |
| Release tag | GitHub | A `release` node, a source mapping |
| Call, chat, and email material | Fathom, Slack, the mailbox | An artifact with a content hash |
| What a customer asked for | Nowhere today | An assertion with the excerpt as evidence |
| Which customer asked | Nowhere today | `reported_by` edges |
| Why we chose this design | A PR comment, at best | An accepted assertion on the component |
| What we promised a customer | A call recording | A `commitment` assertion on the developer |

### The GitHub mapping convention

| `source_schema` | `source_table` | `source_id` |
|---|---|---|
| `github` | `issue` | `quillstone/api#412` |
| `github` | `pull_request` | `quillstone/api#419` |
| `github` | `release` | `quillstone/api@v0.9.0` |

`link_record()` writes the node and the mapping in one call. This is the call
step 5 of the walk makes when the issue is opened, shown here for its shape:

```sql
SELECT link_record(
    p_source_schema  := 'github',
    p_source_table   := 'issue',
    p_source_id      := 'quillstone/api#412',
    p_node_type      := 'task',
    p_label          := 'CSV export times out above 10k rows',
    p_properties     := '{"code": "quillstone/api#412", "task_type": "bug",
                          "repo": "quillstone/api", "number": 412}',
    p_source_id_type := 'text'
);
```

**`link_record()` does not require a local table.** It never looks at
`p_source_schema.p_source_table`. It reads `node_source_map`, falls back to
`nodes.external_id` with `nodes.external_source`, then creates the node and
upserts the mapping. `github` is not a schema in this database and nothing
checks. Only `track_table()` needs a real table, because it attaches a trigger.

Two consequences:

- Call `link_record()` **instead of** `create_task()`, not after it.
  `create_task()` sets `external_id` to its own `TSK-` code and
  `external_source` to `internal`, so a later `link_record()` finds no match
  and creates a second node for the same issue. No helper attaches a source
  mapping to a node that already exists, and a raw `INSERT INTO node_source_map`
  is the only way. That is a gap. Use `link_record()` first, then add what
  `create_task()` would have given you: the initial `task_status` assertion,
  shown in step 5.
- A node from `link_record()` carries no `attrs.teams`, so the classification
  trigger has nothing to enforce. Set `attrs` yourself if the repo is not
  visible to everyone.

### Feedback sources are sources

Register Fathom, the Slack workspace, and the support mailbox before any of
their material becomes a claim.

```bash
node skills/rye-source-context-intake/scripts/source_context_commit_rye.mts \
  --input ./intake/quillstone-sources.ndjson --db-url "$DATABASE_URL"

./scripts/rye sources inventory
./scripts/rye sources pending-context
```

Each account and container starts at `needs_confirmation`. A channel named
`#wandercrate-shared` is a routing hint and nothing more. Connector metadata is
evidence, not confirmed context. Until a person confirms what a source is for,
what contexts its material may route to, and what must never be inferred from
it, that container supplies no default meaning. Excerpts land as artifacts with
a content hash, so a re-sync never counts the same complaint twice.

---

## 2. Entity and Relationship Mapping

| Real-world thing | `node_type` | Key properties |
|---|---|---|
| Developer, customer contact | `person` | `email`, `github_login` |
| Customer company | `org` | `plan`, `seats` |
| GitHub issue | `task` | `code`, `task_type: "bug"` or `"feature"`, `repo`, `number` |
| GitHub pull request | `task` | `code`, `task_type: "pull_request"`, `repo`, `number` |
| Release tag | `release` | `version`, `tag`, `released_at` |
| Part of the codebase | `component` | `name`, `path` |

| Relationship | `edge_type` | Direction |
|---|---|---|
| Issue asked for by a customer | `reported_by` | task -> person, task -> org |
| PR closes an issue | `resolves` | task (PR) -> task (issue) |
| Issue touches a component | `affects` | task -> component |
| Developer owns a component | `owns` | person -> component |
| Person reports to a manager | `reports_to` | person -> person |
| Release contains an issue | `contains` | release -> task |

This reuses the PM profile's `task` node type, its `task_status` assertion
type, and `advance_task_status()`, so install with `--profiles pm`. It does not
use `create_task()`, for the reason in section 1.

`reported_by` and `resolves` are new values, not new tables. A `node_type` or
`edge_type` needs no migration. `owns` and `reports_to` are the two the
settlement lookup reads, and `contracts/plugin-manifest.md` pins their
direction: `owns` runs from the owner to the thing owned, `reports_to` from the
report to the manager.

Two developers means nobody reports to anybody. `reports_to` stays empty, the
manager default never fires, and all the weight lands on `owns` and on the
owner of the area.

---

## 3. Setup: The Area, The People, And The Agents

Order matters here. `grant_agent_capability()` raises
`Knowledge domain product not found` if the area does not exist yet, and
`ensure_knowledge_domain()` needs its owner's node. So: people and components
first, then the area, then the agents.

```sql
-- The two developers, the two customers, and one component.
INSERT INTO nodes (node_type, label, external_source, external_id, properties) VALUES
('person',    'Ines Vaz',            'quillstone_people', 'ines',      '{"github_login": "inesv"}'),
('person',    'Tomas Reeder',        'quillstone_people', 'tomas',     '{"github_login": "treeder"}'),
('org',       'Wandercrate Ltd',     'quillstone_orgs',   'wandercrate', '{"plan": "team"}'),
('org',       'Bellwether Bakeries', 'quillstone_orgs',   'bellwether',  '{"plan": "team"}'),
('component', 'exporter',            'quillstone_code',   'exporter',  '{"path": "src/export"}');

-- The area, owned by Ines. Every grant below names it.
SELECT ensure_knowledge_domain(
    p_domain_key    := 'product',
    p_label         := 'Quillstone product',
    p_purpose       := 'Decide what we build, why, and what we told customers.',
    p_owner_node_id := (SELECT id FROM nodes WHERE external_source = 'quillstone_people'
                                               AND external_id = 'ines')
);
```

Three agents, and they are not alike.

**Each developer's coding agent.** Runs in the editor with direct database
access and the Rye skills loaded. It carries the authority of the developer it
is talking to and none of its own.

```sql
SELECT create_agent_identity('ines-coding',  'Ines coding agent',  'claude-code', 'product');
SELECT create_agent_identity('tomas-coding', 'Tomas coding agent', 'claude-code', 'product');
```

**One scheduled intake agent.** Runs nightly against Fathom, Slack, and the
mailbox through the API, with a token instead of a connection string. It
watches and proposes. It never opens an issue and it never accepts anything.

```sql
SELECT create_agent_identity(
    p_agent_key := 'feedback-intake',
    p_label     := 'Nightly feedback intake',
    p_runtime   := 'api'
);

SELECT grant_agent_capability('feedback-intake', 'rye.context.read',       'product');
SELECT grant_agent_capability('feedback-intake', 'rye.observation.create', 'product');
SELECT grant_agent_capability(
    p_agent_key  := 'feedback-intake',
    p_capability := 'rye.candidate.create',
    p_domain_key := 'product',
    p_expires_at := now() + interval '180 days'
);
```

Three grants out of five. It holds neither `rye.authoritative.promote` nor
`rye.admin.manage`, so the only two things it can write are an observation and
a suggestion. That part is enforced. See section 7.

**A GitHub sync.** A scheduled job on the webhook feed. Identity and lifecycle
only: `link_record()` for issues, PRs, and tags, `record_event()` for opened,
merged, and closed, and the `resolves` and `contains` edges. It writes no
claims.

```bash
./scripts/rye agents create --key github-sync --label "GitHub sync" --runtime api
./scripts/rye agents grant  --key github-sync --capability rye.observation.create --domain product
./scripts/rye agents issue-token --key github-sync --label "webhook worker" \
  --expires-at 2027-01-01T00:00:00Z
```

---

## 4. Authority With Two Developers

The area from section 3 names Ines as its owner. That owner is the last resort
of the lookup: anything nobody else is recorded for settles with her. On top of
that, three rules:

1. Each developer settles their own commitments. `commitment` is a core
   self-settled type, so this needs no configuration at all.
2. Each developer settles facts about the components they own. One `owns` edge
   per component.
3. A decision crossing both components needs both to agree, or a named
   tie-breaker recorded as a grant.

```sql
-- Ines owns the exporter.
INSERT INTO edges (edge_type, source_id, target_id, properties, effective_from)
VALUES ('owns', '<ines_uuid>'::uuid, '<exporter_uuid>'::uuid,
        '{"basis": "agreed at setup"}', now());

-- Roadmap calls cross both components, so one of them is the tie-breaker.
SELECT grant_domain_authority(
    p_domain_key     := 'product',
    p_authority_kind := 'person',
    p_authority_ref  := 'quillstone_people:ines',
    p_claim_types    := ARRAY['roadmap_decision'],
    p_speech_acts    := ARRAY['decided'],
    p_properties     := '{"agreed_by": ["Ines Vaz", "Tomas Reeder"], "review": "annual"}'
);
```

Customers settle nothing. A customer is outside the company, so their words are
evidence and never authority. The lookup makes that literal: a claim carried by
the speech act `outside_report` selects no relationship default and falls
through to the owner of the area.

### Two lookups and their answers

A design fact about a component Ines owns:

```sql
SELECT rye_settlers(
    p_subject_id := '<exporter_uuid>'::uuid,
    p_claim_type := 'design_decision',
    p_speaker_id := '<ines_uuid>'::uuid,
    p_domain_key := 'product',
    p_speech_act := 'statement_about_thing'
);
```

Expected: `step` `relationship`, one settler with `relationship` `owner` and
`via` `relationship`, carrying the `owns` edge id, and `speaker.is_settler`
`true`. Ines may record this as accepted.

A roadmap call, which is topical and has no subject node:

```sql
SELECT rye_settlers(
    p_subject_id := NULL,
    p_claim_type := 'roadmap_decision',
    p_speaker_id := '<tomas_uuid>'::uuid,
    p_domain_key := 'product',
    p_speech_act := 'decision'
);
```

Expected: `step` `grant`, one settler with `ref` `quillstone_people:ines` and
`settles_acts` including `decided`, and `speaker.is_settler` `false`. Tomas's
roadmap call is recorded as a suggestion and routed to Ines. He hears "That's
Ines's call. I'll check with her and let you know." He does not hear the word
authority.

---

## 5. One Piece of Feedback, End to End

Jo Fenn works at Wandercrate Ltd. Amir Dost works at Bellwether Bakeries. Both
are customers.

### Step 1. Jo says on a call that exports are slow

The intake agent resolves the person and the company **before** it stores
anything. It never creates a person from a connector display name.

```sql
-- Resolve first. Only create on no match.
SELECT id, label, node_type FROM nodes
WHERE archived_at IS NULL
  AND (properties->>'email' = 'jo@wandercrate.example' OR label ILIKE 'Jo Fenn');

INSERT INTO nodes (node_type, label, external_source, external_id, properties)
VALUES ('person', 'Jo Fenn', 'quillstone_people', 'jo-fenn',
        '{"email": "jo@wandercrate.example"}');

INSERT INTO edges (edge_type, source_id, target_id, effective_from)
VALUES ('employs', '<wandercrate_uuid>'::uuid, '<jo_uuid>'::uuid, now());
```

### Step 2. Store the utterance and the excerpt

```sql
SELECT record_event(
    p_event_type        := 'feedback_received',
    p_summary           := 'Jo Fenn said CSV exports time out on their monthly report',
    p_properties        := '{"channel": "fathom", "recording": "fathom:recording:88214"}',
    p_participant_ids   := ARRAY['<jo_uuid>', '<wandercrate_uuid>', '<exporter_uuid>']::uuid[],
    p_participant_roles := ARRAY['speaker', 'regarding', 'regarding'],
    p_actor             := 'agent:feedback-intake',
    p_occurred_at       := '2026-03-04T15:20:00Z'::timestamptz
);

SELECT record_artifact(
    p_artifact_type    := 'feedback_excerpt',
    p_content          := '{"text": "The monthly export just spins. We gave up after two minutes.",
                            "speaker": "Jo Fenn", "start_seconds": 742}',
    p_source_event_id  := '<call_event_uuid>'::uuid,
    p_source_node_id   := '<jo_uuid>'::uuid,
    p_related_node_ids := ARRAY['<wandercrate_uuid>', '<exporter_uuid>']::uuid[],
    p_location         := '{"url": "https://fathom.video/share/88214?t=742"}',
    p_content_hash     := 'sha256:6f1c4a...'
);
```

`record_artifact()` looks for an artifact of the same type with the same hash
in `attrs->>'content_hash'` and returns that id if one exists. Re-sync the
recording tomorrow and you get the same artifact back, not a second one.

### Step 3. Record the suggestion

The claim is about the exporter, not about Jo. Jo is the witness.

```sql
SELECT record_assertion(
    p_assertion_type  := 'feature_request',
    p_claim           := '{"value": "CSV export must finish for reports above 10k rows"}',
    p_subject_node_id := '<exporter_uuid>'::uuid,
    p_assertion_key   := 'exporter:large_export_completes',
    p_status          := 'candidate',
    p_basis           := 'reported',
    p_confidence      := 0.7,
    p_evidence        := ARRAY[jsonb_build_object(
        'kind', 'source',
        'event_id', '<call_event_uuid>',
        'witness_node_id', '<jo_uuid>',
        'attrs', jsonb_build_object(
            'channel', 'fathom',
            'artifact_id', '<excerpt_artifact_uuid>',
            'reporting_org', 'Wandercrate Ltd',
            'executor', 'agent:feedback-intake')
    )],
    p_attrs           := '{"settlers": ["Ines Vaz"], "settled_via": "area_owner"}'
);
```

A suggestion, not accepted knowledge. The intake agent holds no acceptance
authority, and a customer is not a settler in any case. Nobody hears anything
yet. The agent is not in a conversation.

### Step 4. Amir says the same thing in Slack, two days later

This is not a second request. It is a second person backing the same one. The
agent resolves Amir the way it resolved Jo in step 1, stores the message and
its excerpt the way step 2 does, then appends the evidence to the claim that
already exists.

```sql
INSERT INTO nodes (node_type, label, external_source, external_id, properties)
VALUES ('person', 'Amir Dost', 'quillstone_people', 'amir-dost',
        '{"email": "amir@bellwether.example"}');

INSERT INTO edges (edge_type, source_id, target_id, effective_from)
VALUES ('employs', '<bellwether_uuid>'::uuid, '<amir_uuid>'::uuid, now());

SELECT record_event(
    p_event_type        := 'feedback_received',
    p_summary           := 'Amir Dost said the same about CSV exports in Slack',
    p_properties        := '{"channel": "slack", "permalink": "https://quillstone.slack.com/archives/C04/p17410"}',
    p_participant_ids   := ARRAY['<amir_uuid>', '<bellwether_uuid>', '<exporter_uuid>']::uuid[],
    p_participant_roles := ARRAY['speaker', 'regarding', 'regarding'],
    p_actor             := 'agent:feedback-intake',
    p_occurred_at       := '2026-03-06T09:12:00Z'::timestamptz
);

SELECT record_artifact(
    p_artifact_type    := 'feedback_excerpt',
    p_content          := '{"text": "Same here. Our end-of-month CSV never finishes.",
                            "speaker": "Amir Dost"}',
    p_source_event_id  := '<slack_event_uuid>'::uuid,
    p_source_node_id   := '<amir_uuid>'::uuid,
    p_related_node_ids := ARRAY['<bellwether_uuid>', '<exporter_uuid>']::uuid[],
    p_content_hash     := 'sha256:b30e77...'
);

SELECT append_assertion_evidence(
    p_assertion_id := '<request_assertion_uuid>'::uuid,
    p_evidence     := ARRAY[jsonb_build_object(
        'kind', 'corroboration',
        'event_id', '<slack_event_uuid>',
        'witness_node_id', '<amir_uuid>',
        'attrs', jsonb_build_object(
            'channel', 'slack',
            'artifact_id', '<slack_artifact_uuid>',
            'reporting_org', 'Bellwether Bakeries',
            'executor', 'agent:feedback-intake')
    )]
);
```

`append_assertion_evidence()` checks whether this witness already backs the
claim and writes `attrs.independent` accordingly. Amir is a distinct witness,
so it records `true`. Jo repeating herself next week would record `false`. That
is how "two customers want this" stays different from "one customer said it
twice".

### Step 5. Ines's agent raises it

In conversation, in plain words, with no Rye vocabulary:

> Two customers have now said CSV exports give up on big reports. Wandercrate
> on a call Tuesday, Bellwether in chat this morning. There is no issue for it.
> Want me to open one?

Ines says yes. The agent opens the issue, then records identity and links:

```bash
gh issue create --repo quillstone/api \
  --title "CSV export times out above 10k rows" --label bug --label from-customer
```

The `link_record()` call for the issue is the one in section 1. Then the rest:

```sql
SELECT record_event(
    p_event_type        := 'issue_opened',
    p_summary           := 'Opened quillstone/api#412 from customer feedback',
    p_properties        := '{"repo": "quillstone/api", "number": 412}',
    p_participant_ids   := ARRAY['<issue_412_uuid>', '<ines_uuid>']::uuid[],
    p_participant_roles := ARRAY['subject', 'actor'],
    p_actor             := 'agent:ines-coding'
);

-- link_record() writes no status assertion. Write the one create_task() would.
SELECT record_assertion(
    p_assertion_type  := 'task_status',
    p_claim           := '{"status": "backlog"}',
    p_subject_node_id := '<issue_412_uuid>'::uuid,
    p_basis           := 'reported',
    p_confidence      := 1.0,
    p_evidence        := ARRAY[jsonb_build_object(
        'kind', 'source', 'event_id', '<issue_opened_event_uuid>')]
);

-- Who asked, through which channel, backing which claim.
INSERT INTO edges (edge_type, source_id, target_id, properties) VALUES
('reported_by', '<issue_412_uuid>'::uuid, '<wandercrate_uuid>'::uuid,
 '{"channel": "fathom", "claim_key": "exporter:large_export_completes"}'),
('reported_by', '<issue_412_uuid>'::uuid, '<bellwether_uuid>'::uuid,
 '{"channel": "slack",  "claim_key": "exporter:large_export_completes"}'),
('affects',     '<issue_412_uuid>'::uuid, '<exporter_uuid>'::uuid, '{}');
```

Ines owns the exporter, so she settles the request itself. The suggestion
becomes accepted knowledge on her word, with her as the authorizer and her
agent as the executor:

```sql
SELECT accept_assertion(
    p_assertion_id := '<request_assertion_uuid>'::uuid,
    p_evidence     := ARRAY[jsonb_build_object(
        'kind', 'source',
        'event_id', '<issue_opened_event_uuid>',
        'witness_node_id', '<ines_uuid>',
        'attrs', jsonb_build_object(
            'authorizer', '<ines_uuid>',
            'executor', 'agent:ines-coding',
            'settled_via', 'relationship',
            'settled_relationship', 'owner')
    )],
    p_reason       := 'Owner of the exporter confirmed the request and opened #412',
    p_actor        := 'agent:ines-coding'
);
```

She hears one line: **"Opened #412, and I have it down that Wandercrate and
Bellwether both asked for it."**

### Step 6. A PR references the issue

The sync sees `Closes #412` on PR #419. It records the PR as a task of type
`pull_request`, the `resolves` edge, and the merge event. No diff, no review
threads.

```sql
SELECT link_record('github', 'pull_request', 'quillstone/api#419', 'task',
    'Paginate CSV export',
    '{"code": "quillstone/api#419", "task_type": "pull_request",
      "repo": "quillstone/api", "number": 419, "merged": true}', 'text');

INSERT INTO edges (edge_type, source_id, target_id, properties)
VALUES ('resolves', '<pr_419_uuid>'::uuid, '<issue_412_uuid>'::uuid,
        '{"declared_in": "pr_body"}');

SELECT record_event(
    p_event_type        := 'pr_merged',
    p_summary           := 'Merged quillstone/api#419, closes #412',
    p_properties        := '{"repo": "quillstone/api", "number": 419, "closes": [412]}',
    p_participant_ids   := ARRAY['<pr_419_uuid>', '<issue_412_uuid>', '<tomas_uuid>']::uuid[],
    p_participant_roles := ARRAY['subject', 'regarding', 'actor'],
    p_actor             := 'agent:github-sync'
);

SELECT advance_task_status(
    p_task_id    := '<issue_412_uuid>'::uuid,
    p_new_status := 'done',
    p_reason     := 'Closed by quillstone/api#419',
    p_actor      := 'agent:github-sync'
);
```

### Step 7. Ines says why

> We're paginating rather than streaming.

That is a statement about a thing she owns. Her agent records what she said,
then runs the first lookup from section 4 and gets `is_settler` `true`. Before
accepting, it checks for a standing claim, because the lookup reads no
assertion and never says whether one exists:

```sql
SELECT record_event(
    p_event_type        := 'statement_made',
    p_summary           := 'Ines: we are paginating the export rather than streaming',
    p_participant_ids   := ARRAY['<ines_uuid>', '<exporter_uuid>']::uuid[],
    p_participant_roles := ARRAY['speaker', 'regarding'],
    p_actor             := 'agent:ines-coding'
);

SELECT a.id, e.attrs->>'authorizer' AS authorizer
FROM current_valid_assertions a
LEFT JOIN assertion_evidence e ON e.assertion_id = a.id
WHERE a.subject_node_id = '<exporter_uuid>'::uuid
  AND canonical_type('assertion_type', a.assertion_type)
    = canonical_type('assertion_type', 'design_decision')
  AND a.assertion_key = 'exporter:large_export_strategy';
```

Nothing stands, so nothing is being replaced. Record it:

```sql
SELECT record_assertion(
    p_assertion_type  := 'design_decision',
    p_claim           := '{"value": "Paginate the CSV export. Do not stream.",
                           "rejected": ["chunked streaming"],
                           "reason": "Clients buffer the whole response anyway."}',
    p_subject_node_id := '<exporter_uuid>'::uuid,
    p_assertion_key   := 'exporter:large_export_strategy',
    p_status          := 'accepted',
    p_basis           := 'reported',
    p_confidence      := 1.0,
    p_evidence        := ARRAY[jsonb_build_object(
        'kind', 'source',
        'event_id', '<utterance_event_uuid>',
        'witness_node_id', '<ines_uuid>',
        'attrs', jsonb_build_object(
            'authorizer', '<ines_uuid>',
            'executor', 'agent:ines-coding',
            'settled_via', 'relationship',
            'settled_relationship', 'owner',
            'resolves_task', 'quillstone/api#412')
    )]
);
```

`authorizer` is the person. `executor` is the agent. Two fields because they
are two different facts, and a year from now "Ines decided this, her agent
wrote it down" is still reconstructible.

She hears: **"Got it. Exports paginate, not stream, and that is on the record
against #412."**

### Step 8. The release ships

```sql
SELECT link_record('github', 'release', 'quillstone/api@v0.9.0', 'release', 'v0.9.0',
    '{"version": "0.9.0", "tag": "v0.9.0", "released_at": "2026-03-19T09:00:00Z"}', 'text');

INSERT INTO edges (edge_type, source_id, target_id)
VALUES ('contains', '<release_090_uuid>'::uuid, '<issue_412_uuid>'::uuid);
```

The agent offers. It does not send.

> v0.9.0 is out with the export fix. Wandercrate and Bellwether both asked for
> this one. Want me to draft a note to each?

---

## 6. The Four Questions

### Why did we build this?

```sql
SELECT t.properties->>'code'   AS issue,
       a.claim->>'value'       AS decision,
       a.claim->>'reason'      AS reason,
       ev.attrs->>'authorizer' AS decided_by,
       a.asserted_at           AS decided_at
FROM nodes t
JOIN edges aff ON aff.source_id = t.id AND aff.edge_type = 'affects'
              AND aff.archived_at IS NULL
JOIN current_valid_assertions a ON a.subject_node_id = aff.target_id
                               AND a.assertion_type = 'design_decision'
LEFT JOIN assertion_evidence ev ON ev.assertion_id = a.id AND ev.kind = 'source'
WHERE t.properties->>'code' = 'quillstone/api#412';
```

### Who asked for it?

```sql
SELECT t.properties->>'code'    AS issue,
       o.label                  AS customer,
       r.properties->>'channel' AS heard_on,
       min(ev.recorded_at)      AS first_heard
FROM nodes t
JOIN edges r ON r.source_id = t.id AND r.edge_type = 'reported_by'
            AND r.archived_at IS NULL
JOIN nodes o ON o.id = r.target_id AND o.node_type = 'org'
LEFT JOIN assertions a ON a.assertion_key = r.properties->>'claim_key'
                      AND a.assertion_type = 'feature_request'
LEFT JOIN assertion_evidence ev ON ev.assertion_id = a.id
                               AND ev.attrs->>'reporting_org' = o.label
WHERE t.properties->>'code' = 'quillstone/api#412'
GROUP BY 1, 2, 3
ORDER BY first_heard;
```

### What did we promise that customer?

A promise is a `commitment` assertion whose subject is **the developer who made
it**, not the customer. `commitment` is a core self-settled type, so a
developer settles their own on their own word with no configuration. Two keys
in `p_attrs` carry the rest: `promised_to`, the customer org's label, and
`tracked_as`, the issue code when there is one.

```sql
SELECT dev.label             AS promised_by,
       a.claim->>'value'     AS promise,
       a.effective_at        AS promised_for,
       t.properties->>'code' AS tracked_as,
       st.claim->>'status'   AS status
FROM current_valid_assertions a
JOIN nodes dev ON dev.id = a.subject_node_id AND dev.node_type = 'person'
LEFT JOIN nodes t ON t.external_id = a.attrs->>'tracked_as'
LEFT JOIN current_valid_assertions st ON st.subject_node_id = t.id
                                     AND st.assertion_type = 'task_status'
WHERE a.assertion_type = 'commitment'
  AND a.attrs->>'promised_to' = 'Wandercrate Ltd'
ORDER BY a.effective_at;
```

### What is asked for most and has no issue?

```sql
SELECT c.label                                    AS component,
       a.claim->>'value'                          AS request,
       a.assertion_key                            AS claim_key,
       count(DISTINCT ev.witness_node_id)         AS distinct_askers,
       count(DISTINCT ev.attrs->>'reporting_org') AS distinct_companies,
       max(ev.recorded_at)                        AS last_heard
FROM assertions a
JOIN nodes c ON c.id = a.subject_node_id AND c.node_type = 'component'
JOIN assertion_evidence ev ON ev.assertion_id = a.id
                          AND ev.kind IN ('source', 'corroboration')
WHERE a.assertion_type = 'feature_request'
  AND a.superseded_at IS NULL
  AND NOT EXISTS (
      SELECT 1 FROM edges r
      WHERE r.edge_type = 'reported_by' AND r.archived_at IS NULL
        AND r.properties->>'claim_key' = a.assertion_key)
GROUP BY 1, 2, 3
ORDER BY distinct_companies DESC, distinct_askers DESC, last_heard DESC;
```

That last one is the report the team never had. It reads the suggestions the
intake agent filed and nobody turned into work.

Run against the walk above it returns nothing, and that is the right answer.
The one request there got an issue in step 5, so it has `reported_by` edges and
the `NOT EXISTS` clause excludes it. Rows appear once the intake agent has been
running for a week and has filed requests nobody has acted on.

---

## 7. What Is Enforced and What Is Discipline

Be clear about which rules the database holds and which the skills follow.

**Discipline, not enforcement.** Both coding agents hold a direct database
connection. Rye authorizes on session variables, and anyone with a connection
sets their own. `SET "app.current_role" = 'admin'` is one line. Every
rule in section 4 is a rule the skills follow, not a boundary the database
holds. Two developers who trust each other lose nothing by this. A third person
who should be restricted gains nothing from it until the connection string goes
away.

Setup is not gated either. The whole of section 3 runs under a non-admin role:
`ensure_knowledge_domain()`, `create_agent_identity()`, and
`grant_agent_capability()` all succeed for an `operator`. Whoever can reach the
database can create an area, mint an agent identity, and grant it capabilities.

**`rye_settlers()` is advisory.** It is `SECURITY INVOKER`, it writes nothing,
and **no write path calls it**. Neither `record_assertion()` nor
`accept_assertion()` consults it. An agent that skips the lookup and records an
accepted claim is refused nothing.

**The standing-claim guard is manual.** The lookup reads no assertion, so
`is_settler` `true` is not permission to replace something already accepted.
The check in step 7 is the guard, and the agent has to run it itself.

**Routing is proposed, not built.** "Tell Ines that Tomas suggested this" has
no mechanism. `review_queue` is the durable backing and a person still has to
go look at it. Confirmations routed to whatever agent a settler is talking to,
and objections routed by their reason, are in
`design/proposals/human-agent-scaling.md` and are not built.

**Configuration is writable by non-admins.** Under review policy `open`, which
is also the answer when no policy is recorded, `record_assertion()` leaves an
accepted assertion accepted for any role. That includes a `registry_entry`,
which holds type aliases and the list of claim types a person settles about
themselves, and those decide who may settle a claim. An agent that writes one
alias can change the answer in section 4. `work/005` is open for it. Until it
closes, treat registry writes as an admin's job by convention.

**Actually enforced.** These hold whatever the caller does:

- The intake agent through the API can only submit observations and create
  candidates. `agent_submit_observation()` and `agent_create_candidate()` check
  `has_agent_capability()` and log the denial. With no
  `rye.authoritative.promote` grant there is no path from its token to an
  accepted claim.
- An assertion with a basis other than `assumed` and no evidence raises.
- A node with `attrs.teams` and no `attrs.classification` raises.
- Events are never deleted and accepted assertions are never mutated in place.
- Under review policy `strict`, or `candidates_only` with a basis other than
  `observed`, an accepted write is stored as a candidate instead.

---

## 8. What to Build First

Two things, in this order.

1. **The intake agent.** Register Fathom, Slack, and the mailbox as sources.
   Confirm what each is for. Store excerpts as hashed artifacts and file
   suggestions against components. That alone answers the fourth question in
   week one, because the suggestions pile up whether or not anything else
   exists.

2. **The GitHub sync.** Issues, PRs, tags, and the three events. Identity and
   lifecycle only. Resist mirroring issue bodies. The moment you mirror them
   you own a stale copy of GitHub.

Then prove the loop once, on one piece of feedback, exactly as section 5 walks
it. One full circuit is worth more than six months of collected material nobody
followed through.

Objectives, forecasts, and a roadmap built from request counts come later. They
rest on the feedback-to-issue loop, and the loop has to be real first.

---

## Related

- [Product Development](/docs/cookbooks/product-development/) for incidents, ADRs, and larger teams
- [Agent Operations](/docs/reference/agent-ops-guide/) for the settlement lookup and the echo rules
- [Quickstart](/docs/getting-started/quickstart/) for installing Rye and creating the first area
