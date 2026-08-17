#!/usr/bin/env node
// Scores retrieval traces against a scenario's ground truth.
//
//   node eval/retrieval/score_retrieval.mjs [--write] [--trace <path>]
//
// Reads traces from traces/*.json (or one named with --trace), matches each to
// its scenario, and reports the metrics that decide the open retrieval
// questions in issue #17. --write refreshes report.md.
//
// No database and no dependencies: the trace is the input. See trace_format.md.

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const root = new URL(".", import.meta.url).pathname;
const scenarioRoot = path.join(root, "scenarios");
const traceRoot = path.join(root, "traces");

const argv = process.argv.slice(2);
const writeReport = argv.includes("--write");
const traceArg = argv.indexOf("--trace");
const tracePaths =
  traceArg !== -1 && argv[traceArg + 1]
    ? [path.resolve(argv[traceArg + 1])]
    : fs
        .readdirSync(traceRoot)
        .filter((f) => f.endsWith(".json"))
        .map((f) => path.join(traceRoot, f))
        .sort();

// A call budget, not a hard limit. Loop recall is reported both ways so a
// pass that took nine reformulations is visible as expensive rather than
// silently counted as a win.
const CALL_BUDGET = 3;

const reports = tracePaths.map(scoreTrace);

if (writeReport) {
  fs.writeFileSync(path.join(root, "report.md"), renderReport(reports), "utf8");
}

console.log(JSON.stringify(reports, null, 2));

// ---------------------------------------------------------------------------

function scoreTrace(tracePath) {
  const trace = readJson(tracePath);
  const questionsPath = path.join(scenarioRoot, trace.scenario, "questions.json");
  if (!fs.existsSync(questionsPath)) {
    throw new Error(`Trace ${path.basename(tracePath)} names unknown scenario '${trace.scenario}'`);
  }
  const spec = readJson(questionsPath);
  const byId = new Map(spec.questions.map((q) => [q.id, q]));
  const seen = new Set();

  const scored = [];
  for (const result of trace.results ?? []) {
    const question = byId.get(result.question_id);
    if (!question) {
      throw new Error(`Trace references unknown question '${result.question_id}'`);
    }
    seen.add(question.id);
    scored.push(scoreQuestion(question, result));
  }

  const unattempted = spec.questions.filter((q) => !seen.has(q.id)).map((q) => q.id);
  return {
    trace: path.basename(tracePath),
    arm: trace.arm,
    scenario: trace.scenario,
    run_id: trace.run_id ?? null,
    metrics: aggregate(scored),
    unattempted,
    questions: scored,
  };
}

function scoreQuestion(question, result) {
  const steps = result.steps ?? [];
  const answer = result.answer ?? {};
  const expectedEntry = question.entry?.expected_node_ids ?? [];

  // --- entry point -------------------------------------------------------
  // Which step first surfaced an expected entry node anywhere in its results.
  let entryStep = null;
  for (const step of steps) {
    const ids = nodeIdsIn(step);
    if (expectedEntry.some((id) => ids.has(id))) {
      entryStep = step.seq ?? steps.indexOf(step) + 1;
      break;
    }
  }
  const entryRequired = expectedEntry.length > 0;
  const entryFound = !entryRequired || entryStep !== null;
  const callsToEntry = entryStep;

  // --- evidence ----------------------------------------------------------
  const expectedEdges = question.evidence?.expected_edge_ids ?? [];
  const expectedAssertions = question.evidence?.expected_assertions ?? [];
  const returnedEdges = new Set(steps.flatMap((s) => edgeIdsIn(s)));

  // Was the expected evidence ever RETURNED by a call? Distinguishes "the
  // agent could not find it" from "the agent found it and did not use it".
  const evidenceReturned =
    expectedEdges.length === 0 || expectedEdges.every((id) => returnedEdges.has(id));

  const citedEdges = new Set(answer.cited_edge_ids ?? []);
  const citedAssertions = (answer.cited_assertions ?? []).map(assertionKey);
  const citedAssertionSet = new Set(citedAssertions);

  const edgesCited = expectedEdges.every((id) => citedEdges.has(id));
  const assertionsCited = expectedAssertions.every((a) => citedAssertionSet.has(assertionKey(a)));

  // Forbidden evidence is the co-occurrence-as-causation trap.
  const forbidden = question.forbidden_evidence?.edge_ids ?? [];
  const forbiddenCited = forbidden.filter((id) => citedEdges.has(id));

  // Provenance is only meaningful for questions that expect support, and it
  // fails outright if a forbidden edge was offered as support.
  const provenanceApplicable = expectedEdges.length > 0 || expectedAssertions.length > 0;
  const provenanceCorrect =
    provenanceApplicable && edgesCited && assertionsCited && forbiddenCited.length === 0;

  // --- answer ------------------------------------------------------------
  const refused = answer.refused === true;
  let answerCorrect;
  if (forbiddenCited.length > 0) {
    // Reaching a true conclusion through co-occurrence is still wrong. "X
    // caused Y, because X and Y are mentioned together" does not become right
    // when X did in fact cause Y — and letting it score as correct would hide
    // the failure this fixture exists to catch.
    answerCorrect = false;
  } else if (question.answerable === false) {
    answerCorrect = refused;
  } else if (question.expected_behavior === "report_ambiguity") {
    answerCorrect = (answer.node_ids ?? []).length > 1 && !refused;
  } else if (question.expected_behavior === "report_no_causal_link") {
    answerCorrect = !refused && (answer.node_ids ?? []).length === 0 && forbiddenCited.length === 0;
  } else {
    const wantNodes = question.answer?.expected_node_ids ?? [];
    const gotNodes = new Set(answer.node_ids ?? []);
    const nodesOk = wantNodes.length === 0 || wantNodes.every((id) => gotNodes.has(id));
    const wantText = question.answer?.expected_claim_contains;
    const textOk =
      !wantText || (answer.text ?? "").toLowerCase().includes(wantText.toLowerCase());
    answerCorrect = !refused && nodesOk && textOk;
  }

  return {
    id: question.id,
    class: question.class,
    difficulty: question.entry?.difficulty ?? null,
    answerable: question.answerable !== false,
    answer_correct: answerCorrect,
    entry_required: entryRequired,
    entry_found: entryFound,
    calls_to_entry: callsToEntry,
    within_budget: callsToEntry !== null && callsToEntry <= CALL_BUDGET,
    evidence_returned: evidenceReturned,
    provenance_applicable: provenanceApplicable,
    provenance_correct: provenanceCorrect,
    forbidden_evidence_cited: forbiddenCited,
    refused,
    steps: steps.length,
    tokens: result.tokens ?? null,
    latency_ms: result.latency_ms ?? null,
    failure_bucket: bucket({
      question,
      answerCorrect,
      entryFound,
      entryRequired,
      evidenceReturned,
      refused,
      forbiddenCited,
    }),
  };
}

// The point of the whole harness: a mechanical cause for each failure.
function bucket({
  question,
  answerCorrect,
  entryFound,
  entryRequired,
  evidenceReturned,
  refused,
  forbiddenCited,
}) {
  if (answerCorrect) return null;

  if (question.answerable === false) return refused ? null : "confabulated";
  if (forbiddenCited.length > 0) return "co_occurrence_as_causation";
  // Before refused_answerable: an agent that honestly declines because it
  // never found the entity has an entry-point problem, not a refusal problem.
  // Naming it a refusal would hide the only actionable cause.
  if (entryRequired && !entryFound) return "entry_missed";
  if (refused) return "refused_answerable";
  if (question.class === "cross_subject") return "cross_subject";
  if (!evidenceReturned) return "path_not_found";
  return "misjudged";
}

function aggregate(scored) {
  const answerable = scored.filter((q) => q.answerable);
  const unanswerable = scored.filter((q) => !q.answerable);
  const entryScored = scored.filter((q) => q.entry_required);
  const provenance = scored.filter((q) => q.provenance_applicable);

  const buckets = {};
  for (const q of scored) {
    if (q.failure_bucket) buckets[q.failure_bucket] = (buckets[q.failure_bucket] ?? 0) + 1;
  }

  const byDifficulty = {};
  for (const q of scored) {
    // Questions with no expected entry node (cross-subject ones) carry a
    // nominal difficulty but never exercise entry-point lookup. Counting them
    // as found would inflate exactly the metric that decides whether a
    // semantic index is worth building.
    if (!q.difficulty || !q.entry_required) continue;
    const d = (byDifficulty[q.difficulty] ??= { total: 0, entry_found: 0 });
    d.total += 1;
    if (q.entry_found) d.entry_found += 1;
  }

  const callCounts = scored.map((q) => q.calls_to_entry).filter((n) => n !== null);

  return {
    answered: scored.length,
    answer_correctness: ratio(scored.filter((q) => q.answer_correct).length, scored.length),
    loop_recall: ratio(entryScored.filter((q) => q.entry_found).length, entryScored.length),
    loop_recall_within_budget: ratio(
      entryScored.filter((q) => q.within_budget).length,
      entryScored.length
    ),
    mean_calls_to_entry: callCounts.length
      ? Number((callCounts.reduce((a, b) => a + b, 0) / callCounts.length).toFixed(2))
      : null,
    provenance_correctness: ratio(
      provenance.filter((q) => q.provenance_correct).length,
      provenance.length
    ),
    correct_refusal: ratio(unanswerable.filter((q) => q.refused).length, unanswerable.length),
    confabulation: ratio(unanswerable.filter((q) => !q.refused).length, unanswerable.length),
    answerable_correctness: ratio(
      answerable.filter((q) => q.answer_correct).length,
      answerable.length
    ),
    entry_found_by_difficulty: byDifficulty,
    failure_buckets: buckets,
    tokens_per_correct_answer: tokensPerCorrect(scored),
  };
}

function tokensPerCorrect(scored) {
  const withTokens = scored.filter((q) => q.tokens);
  if (withTokens.length === 0) return null;
  const total = withTokens.reduce(
    (sum, q) => sum + (q.tokens.in ?? 0) + (q.tokens.out ?? 0),
    0
  );
  const correct = withTokens.filter((q) => q.answer_correct).length;
  return correct === 0 ? null : Math.round(total / correct);
}

// ---------------------------------------------------------------------------

function nodeIdsIn(step) {
  const ids = new Set();
  for (const r of step.results ?? []) {
    if (r.node_id) ids.add(r.node_id);
    for (const id of r.node_path ?? []) ids.add(id);
    for (const id of r.node_ids ?? []) ids.add(id);
    for (const n of r.nodes ?? []) if (n.node_id) ids.add(n.node_id);
  }
  return ids;
}

function edgeIdsIn(step) {
  const ids = [];
  for (const r of step.results ?? []) {
    for (const id of r.edge_path ?? []) ids.push(id);
    if (r.edge_id) ids.push(r.edge_id);
    for (const e of r.edges ?? []) if (e.edge_id) ids.push(e.edge_id);
  }
  return ids;
}

// Declarations, not const arrows: the top-level scoring pass runs before the
// bottom of the module is evaluated.
function assertionKey(a) {
  return `${a.subject_node_id}|${a.assertion_type}|${a.assertion_key ?? "default"}`;
}

function ratio(n, d) {
  return d === 0 ? null : Number((n / d).toFixed(3));
}

function pct(v) {
  return v === null ? "n/a" : `${(v * 100).toFixed(1)}%`;
}

function readJson(p) {
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

function renderReport(reports) {
  const lines = [
    "# Retrieval Eval Report",
    "",
    "Generated by `node eval/retrieval/score_retrieval.mjs --write`.",
    "",
    "Thresholds are proposals, not settled. See README.md for what each metric decides.",
    "",
  ];

  for (const r of reports) {
    const m = r.metrics;
    lines.push(`## ${r.arm} — ${r.scenario}`);
    lines.push("");
    if (r.run_id) lines.push(`Run: \`${r.run_id}\``, "");
    lines.push("| Metric | Value |", "|---|---:|");
    lines.push(`| Answer correctness | ${pct(m.answer_correctness)} |`);
    lines.push(`| Answerable-only correctness | ${pct(m.answerable_correctness)} |`);
    lines.push(`| Loop recall | ${pct(m.loop_recall)} |`);
    lines.push(`| Loop recall within ${CALL_BUDGET} calls | ${pct(m.loop_recall_within_budget)} |`);
    lines.push(`| Mean calls to entry | ${m.mean_calls_to_entry ?? "n/a"} |`);
    lines.push(`| Provenance correctness | ${pct(m.provenance_correctness)} |`);
    lines.push(`| Correct refusal | ${pct(m.correct_refusal)} |`);
    lines.push(`| Confabulation | ${pct(m.confabulation)} |`);
    lines.push(`| Tokens per correct answer | ${m.tokens_per_correct_answer ?? "n/a"} |`);
    lines.push("");

    if (Object.keys(m.entry_found_by_difficulty).length) {
      lines.push("### Entry point by difficulty", "", "| Difficulty | Found | Total |", "|---|---:|---:|");
      for (const [d, v] of Object.entries(m.entry_found_by_difficulty)) {
        lines.push(`| ${d} | ${v.entry_found} | ${v.total} |`);
      }
      lines.push("");
    }

    if (Object.keys(m.failure_buckets).length) {
      lines.push("### Failure buckets", "", "| Bucket | Count |", "|---|---:|");
      for (const [b, c] of Object.entries(m.failure_buckets).sort((a, b) => b[1] - a[1])) {
        lines.push(`| \`${b}\` | ${c} |`);
      }
      lines.push("");
    }

    const failures = r.questions.filter((q) => q.failure_bucket);
    if (failures.length) {
      lines.push("### Failures", "", "| Question | Class | Bucket | Calls to entry |", "|---|---|---|---:|");
      for (const q of failures) {
        lines.push(
          `| \`${q.id}\` | ${q.class} | \`${q.failure_bucket}\` | ${q.calls_to_entry ?? "—"} |`
        );
      }
      lines.push("");
    }

    if (r.unattempted.length) {
      lines.push(`### Unattempted (${r.unattempted.length})`, "");
      lines.push(r.unattempted.map((id) => `\`${id}\``).join(", "), "");
      lines.push("Unattempted questions are excluded from every metric above.", "");
    }
  }

  return lines.join("\n");
}
