import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const siteRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = path.resolve(siteRoot, "..");
const outputRoot = path.join(siteRoot, "src", "content", "docs");

const sources = [
  { section: "getting-started", sourceDir: path.join(repoRoot, "design", "getting-started") },
  {
    section: "getting-started",
    sourceDir: path.join(repoRoot, "docs"),
    files: [path.join(repoRoot, "docs", "onboarding.md")],
  },
  {
    section: "reference",
    sourceDir: path.join(repoRoot, "docs"),
    // onboarding.md is published under getting-started above; skip it here so
    // the same page does not appear in two sections.
    exclude: [path.join(repoRoot, "docs", "onboarding.md")],
  },
  { section: "model", sourceDir: path.join(repoRoot, "design", "model") },
  { section: "layers", sourceDir: path.join(repoRoot, "design", "layers") },
  { section: "cookbooks", sourceDir: path.join(repoRoot, "design", "cookbooks") },
  {
    section: "evaluations",
    sourceDir: path.join(repoRoot, "eval", "business_replay_scenarios"),
    files: [path.join(repoRoot, "eval", "business_replay_scenarios", "report.md")],
  },
];

const outcomeDescriptionsBySourcePath = {
  "docs/agent-ops-guide.md":
    "Execute agent reads and writes safely with repeatable SQL patterns that preserve auditability.",
  "docs/conventions-catalog.md":
    "Adopt consistent conventions so Rye stays extensible without schema migrations.",
  "docs/core-contract.md":
    "Understand the guarantees Rye enforces so behavior stays predictable in production.",
  "docs/cli.md":
    "Use the Rye CLI to install, inspect catalogs, create scopes, and return agent context.",
  "docs/data-dictionary.md":
    "Get a clear purpose for every table, view, and function to accelerate implementation.",
  "docs/onboarding.md":
    "Set up scope-first onboarding, source context, plugin policy, and context-gap review.",
  "docs/roadmap.md":
    "Review the capability roadmap for onboarding, plugins, evidence, retention, admin, and graph quality.",
  "design/model/core-contract-and-conformance.md":
    "Validate your deployment against Rye's core contract before production rollout.",
  "design/model/deployment.md":
    "Deploy Rye with clear schema boundaries, secure function paths, and reliable operational setup.",
  "design/model/functions.md":
    "Use proven Rye functions to create events, evolve assertions, and query graph context safely.",
  "design/model/integration.md":
    "Connect existing domain tables to Rye without replacing operational systems.",
  "design/model/overview.md":
    "See how Rye unifies entities, relationships, events, and assertions for better decisions.",
  "design/model/schema.md":
    "Reference the full Rye schema so implementation remains consistent and production-ready.",
  "design/model/security.md":
    "Apply RLS, redaction, and session-context authorization to keep data access controlled.",
  "design/layers/crm.md":
    "Run CRM workflows directly on Rye's core model with shared context across teams.",
  "design/layers/pm.md":
    "Model tasks, projects, and sprints in Rye to align delivery data with broader business context.",
  "design/cookbooks/mineral-rights.md":
    "Unify parcel, owner, and title context so acquisition teams act on complete deal intelligence.",
  "design/cookbooks/product-development.md":
    "Trace incidents, releases, and decisions end-to-end to reduce regression response time.",
  "design/getting-started/installation.md":
    "Go from zero to a running Rye instance with PostgreSQL, session variables, and optional profiles.",
  "design/getting-started/quickstart.md":
    "Start agent-led onboarding, choose a PostgreSQL target, and create the first scoped context.",
  "design/cookbooks/recruiting-pipeline.md":
    "Track candidate progress with full history so hiring decisions are consistent and explainable.",
  "design/cookbooks/saas-customer-operations.md":
    "Connect support, billing, and product signals to improve retention and customer operations.",
  "eval/business_replay_scenarios/report.md":
    "Review the business replay evaluation that tested source intake, SME review, future assertions, and CRM/PM surfaces.",
};

const outcomeDescriptionsByTitle = {
  "Rye Agent Operations Guide":
    "Execute agent reads and writes safely with repeatable SQL patterns that preserve auditability.",
  "Rye Conventions Catalog":
    "Adopt consistent conventions so Rye stays extensible without schema migrations.",
  "Rye Core Contract (Implemented)":
    "Understand the guarantees Rye enforces so behavior stays predictable in production.",
  "Rye CLI Reference":
    "Use the Rye CLI to install, inspect catalogs, create scopes, and return agent context.",
  "Rye Data Dictionary":
    "Get a clear purpose for every table, view, and function to accelerate implementation.",
  "Rye Onboarding Scopes and Plugin Metadata":
    "Set up scope-first onboarding, source context, plugin policy, and context-gap review.",
  "Rye Roadmap":
    "Review the capability roadmap for onboarding, plugins, evidence, retention, admin, and graph quality.",
  "Rye — Core Contract and Conformance Kit":
    "Validate your deployment against Rye's core contract before production rollout.",
  "Deployment Architecture":
    "Deploy Rye with clear schema boundaries, secure function paths, and reliable operational setup.",
  "Rye — Functions Reference":
    "Use proven Rye functions to create events, evolve assertions, and query graph context safely.",
  "Rye — Integration":
    "Connect existing domain tables to Rye without replacing operational systems.",
  "Rye — Overview":
    "See how Rye unifies entities, relationships, events, and assertions for better decisions.",
  "Rye — Schema Reference":
    "Reference the full Rye schema so implementation remains consistent and production-ready.",
  "Rye — Security":
    "Apply RLS, redaction, and session-context authorization to keep data access controlled.",
  "CRM Conventions":
    "Run CRM workflows directly on Rye's core model with shared context across teams.",
  "PM Conventions":
    "Model tasks, projects, and sprints in Rye to align delivery data with broader business context.",
  "Cookbook: Mineral Rights Acquisition":
    "Unify parcel, owner, and title context so acquisition teams act on complete deal intelligence.",
  "Cookbook: Product Development":
    "Trace incidents, releases, and decisions end-to-end to reduce regression response time.",
  Installation:
    "Go from zero to a running Rye instance with PostgreSQL, session variables, and optional profiles.",
  Quickstart:
    "Start agent-led onboarding, choose a PostgreSQL target, and create the first scoped context.",
  "Cookbook: Recruiting Pipeline":
    "Track candidate progress with full history so hiring decisions are consistent and explainable.",
  "Cookbook: SaaS Customer Operations":
    "Connect support, billing, and product signals to improve retention and customer operations.",
  "Rye Business Replay Evaluation Report":
    "Review the business replay evaluation that tested source intake, SME review, future assertions, and CRM/PM surfaces.",
};

function toPosix(value) {
  return value.split(path.sep).join("/");
}

function escapeYaml(value) {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function normalizeTitle(raw) {
  return raw
    .replace(/[`*_#]/g, "")
    .replace(/\[(.*?)\]\((.*?)\)/g, "$1")
    .trim();
}

function inferTitle(content, fallback) {
  const heading = content.match(/^#\s+(.+)$/m);
  if (heading && heading[1]) {
    return normalizeTitle(heading[1]);
  }

  return fallback
    .replace(/\.md$/i, "")
    .replace(/[-_]/g, " ")
    .replace(/\b\w/g, (char) => char.toUpperCase());
}

function inferDescription(content) {
  const lines = content.split("\n").map((line) => line.trim());

  for (const line of lines) {
    if (!line) continue;
    if (line.startsWith("#")) continue;
    if (line.startsWith("---")) continue;
    if (line.startsWith("```")) continue;
    if (line.startsWith("|")) continue;

    const cleaned = line.replace(/[`*_]/g, "").trim();
    if (cleaned.length > 24) {
      return cleaned.slice(0, 220);
    }
  }

  return "Rye documentation reference.";
}

async function walkMarkdownFiles(dir) {
  const entries = await fs.readdir(dir, { withFileTypes: true });
  const files = [];

  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);

    if (entry.isDirectory()) {
      files.push(...(await walkMarkdownFiles(fullPath)));
      continue;
    }

    if (entry.isFile() && entry.name.toLowerCase().endsWith(".md")) {
      files.push(fullPath);
    }
  }

  return files;
}

async function ensureDirectory(filePath) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
}

async function copyFileWithMetadata(filePath, section, sourceDir) {
  const input = await fs.readFile(filePath, "utf8");
  const relativePath = path.relative(sourceDir, filePath);
  const destination = path.join(outputRoot, section, relativePath);
  const sourcePath = toPosix(path.relative(repoRoot, filePath));

  let output = input;
  if (!input.startsWith("---\n")) {
    const title = inferTitle(input, path.basename(filePath));
    const description =
      outcomeDescriptionsByTitle[title] ??
      outcomeDescriptionsBySourcePath[sourcePath] ??
      inferDescription(input);

    output = [
      "---",
      `title: "${escapeYaml(title)}"`,
      `description: "${escapeYaml(description)}"`,
      `section: "${section}"`,
      `sourcePath: "${escapeYaml(sourcePath)}"`,
      "---",
      "",
      input.trimStart(),
      "",
    ].join("\n");
  }

  await ensureDirectory(destination);
  await fs.writeFile(destination, output, "utf8");
}

async function main() {
  await fs.rm(outputRoot, { recursive: true, force: true });
  await fs.mkdir(outputRoot, { recursive: true });

  let total = 0;
  for (const source of sources) {
    let files = source.files ?? (await walkMarkdownFiles(source.sourceDir));
    if (source.exclude) {
      files = files.filter((filePath) => !source.exclude.includes(filePath));
    }
    for (const filePath of files) {
      await copyFileWithMetadata(filePath, source.section, source.sourceDir);
      total += 1;
    }
  }

  console.log(`Synced ${total} Markdown files into src/content/docs`);
}

main().catch((error) => {
  console.error("Failed to sync Markdown content:", error);
  process.exit(1);
});
