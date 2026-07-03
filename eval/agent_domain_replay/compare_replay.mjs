#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const root = new URL(".", import.meta.url).pathname;
const scenarioDirs = fs
  .readdirSync(root, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => path.join(root, entry.name))
  .sort();

const writeReports = process.argv.includes("--write");
const results = scenarioDirs.map(scoreScenario);

if (writeReports) {
  for (const result of results) {
    fs.writeFileSync(path.join(result.dir, "comparison_report.md"), renderReport(result), "utf8");
  }
}

console.log(JSON.stringify(results.map(({ dir, ...result }) => ({ scenario: path.basename(dir), ...result })), null, 2));

function scoreScenario(dir) {
  const oracle = readJson(path.join(dir, "hidden_oracle.json"));
  const output = readJson(path.join(dir, "isolated_agent_output.json"));
  const expected = oracle.expected_facts ?? [];
  const candidates = output.candidates ?? [];
  const byId = new Map(expected.map((fact) => [fact.id, fact]));

  const matched = candidates.filter((candidate) => byId.has(candidate.oracle_ref));
  const matchedRefs = new Set(matched.map((candidate) => candidate.oracle_ref));
  const missing = expected.filter((fact) => !matchedRefs.has(fact.id));
  const falsePositives = candidates.filter((candidate) => !byId.has(candidate.oracle_ref));
  const authorityErrors = [];
  const temporalErrors = [];
  const domainRoutingErrors = [];

  for (const candidate of matched) {
    const fact = byId.get(candidate.oracle_ref);
    if (!fact) continue;
    if ((candidate.authority_ref ?? null) !== (fact.authority_ref ?? null)) {
      authorityErrors.push({ candidate_id: candidate.id, expected: fact.authority_ref, actual: candidate.authority_ref });
    }
    if ((candidate.current_or_future ?? null) !== (fact.current_or_future ?? null)) {
      temporalErrors.push({ candidate_id: candidate.id, expected: fact.current_or_future, actual: candidate.current_or_future });
    }
    if ((candidate.domain_key ?? null) !== (fact.domain_key ?? null)) {
      domainRoutingErrors.push({ candidate_id: candidate.id, expected: fact.domain_key, actual: candidate.domain_key });
    }
  }

  const coverage = expected.length === 0 ? 1 : matchedRefs.size / expected.length;
  const precision = candidates.length === 0 ? 1 : matched.length / candidates.length;
  const score = Number(
    (
      coverage * 45 +
      precision * 25 -
      authorityErrors.length * 8 -
      temporalErrors.length * 10 -
      domainRoutingErrors.length * 7
    ).toFixed(2),
  );

  return {
    dir,
    expected_count: expected.length,
    candidate_count: candidates.length,
    matched_count: matched.length,
    coverage,
    precision,
    score: Math.max(0, score),
    missing: missing.map((fact) => fact.id),
    false_positives: falsePositives.map((candidate) => candidate.id),
    authority_errors: authorityErrors,
    temporal_errors: temporalErrors,
    domain_routing_errors: domainRoutingErrors,
  };
}

function renderReport(result) {
  return `# Comparison Report

- Expected facts: ${result.expected_count}
- Candidate facts: ${result.candidate_count}
- Matched facts: ${result.matched_count}
- Coverage: ${(result.coverage * 100).toFixed(1)}%
- Precision: ${(result.precision * 100).toFixed(1)}%
- Score: ${result.score}

## Gaps

- Missing oracle facts: ${result.missing.length ? result.missing.join(", ") : "none"}
- False positives: ${result.false_positives.length ? result.false_positives.join(", ") : "none"}
- Authority errors: ${result.authority_errors.length ? JSON.stringify(result.authority_errors) : "none"}
- Temporal errors: ${result.temporal_errors.length ? JSON.stringify(result.temporal_errors) : "none"}
- Domain-routing errors: ${result.domain_routing_errors.length ? JSON.stringify(result.domain_routing_errors) : "none"}
`;
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}
