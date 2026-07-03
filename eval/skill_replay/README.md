# Rye Skill Replay Evals

Interview-driven, clean-room evaluation of Rye skills. Scenario designs here
are tracked artifacts; run outputs (transcripts, judge reports, DB snapshots)
are disposable and live under `tmp/skill-evals/runs/` (gitignored).

Proven scenarios: `scenarios/meridian-fence` — regression-tested.
Run 1 (2026-07-02): caught vague-date elicitation gap + fabricated-midpoint
value; fixed via rye-onboarding "Interviewing Discipline" and rye-agent-ops
uncertain-values pattern. Run 2 (2026-07-02, post-fix): strictly better on
every rubric section (Must 10/10, reader 7/7, process 5/5); confirmed both
fixes changed behavior; caught a new low-severity gap (scope revision left
scope_boundary assertion stale) fixed via rye-onboarding "Scope Revisions
Must Stay Consistent". Scenario is now a stable regression gate.

Closed-loop, clean-room testing of Rye skills: can an agent with ONLY the
skill files as context onboard a realistic business via interview, and can a
second agent with ONLY the reader skill answer business questions from what
was stored?

## Artifacts per scenario

- `ground_truth.md` — full business reality. Grader-only. Never shown to
  intake or reader agents.
- `persona_brief.md` — what the interviewee knows, voice, quirks
  (deliberate vagueness, one uncertain value, a tangent). The persona is a
  lossy, human-shaped interface to the ground truth.
- `rubric.md` — three sections: (A) must/should/must-not DB state,
  (B) blind reader questions with expected answers, (C) process
  observations from the transcript.

## Run layout (untracked, disposable)

- `workspace/` — clean-room consumer dir: skill copies (no repo docs),
  `scripts/rye` + `sync_plugin_metadata.sh`, `plugins/`, `.rye.env`
  pointing at a throwaway Postgres (NOT the developer's local instance).
- `runs/<scenario>/<n>/` — interview transcript, reader answers, judge
  report, DB snapshot.

## Pipeline

1. Fresh throwaway Postgres; install Rye via `init remote` with
   `RYE_ENV_FILE` pointing into the workspace.
2. Interview: intake agent (skills: rye-onboarding + rye-agent-ops ONLY)
   interviews the persona agent (persona_brief ONLY). Orchestrator relays
   messages and appends every exchange to the transcript. Cap ~6 rounds;
   agent batches questions.
3. Blind read: reader agent (rye-knowledge-reader ONLY) answers the rubric's
   question list — questions only, never the expected answers.
4. Judge: grades DB state against rubric A, reader answers against rubric B,
   transcript against rubric C. Output: per-item PASS/PARTIAL/FAIL + evidence.
5. Triage before editing skills: rerun or read the transcript to separate
   skill gaps from model noise / scenario ambiguity. Fix skills with
   generalizable principles, not scenario-specific instructions. Rerun the
   same scenario to confirm.

## Hard-won rules

- Embed the persona brief VERBATIM in the persona agent's spawn prompt. Do
  not tell it to read the brief from disk — a role-play agent may skip the
  read and improvise a whole different business (observed in run 1).
- Require the intake agent to write to the DB incrementally, not at the end.
  If the orchestrator or agent dies mid-interview, completed rounds survive;
  recover by checking DB state and resuming the agent with an operator note
  listing what already exists (observed in run 1).

## Known limitations

- Clean-room is enforced by instruction (agents share the host); a stricter
  version runs in an empty dir outside the repo with `npx skills add`.
- One run is one sample; treat single failures as leads, not verdicts.
