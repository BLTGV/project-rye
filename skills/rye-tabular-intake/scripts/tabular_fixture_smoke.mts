#!/usr/bin/env node
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

import {
  CliError,
  getString,
  runCli,
  type HelpSpec,
} from "./lib/cli.mts";
import {
  buildPsqlTarget,
  runPsql,
  runPsqlCapture,
  sqlJson,
  sqlText,
  type PsqlTarget,
} from "./lib/psql_target.mts";
import { RYE_TABULAR_INTAKE } from "./lib/rye_contracts.mts";

const execFileAsync = promisify(execFile);
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const skillRoot = path.resolve(scriptDir, "..");
const repoRoot = path.resolve(skillRoot, "..", "..");

const help: HelpSpec = {
  name: "tabular_fixture_smoke.mts",
  summary: "Run tabular-intake fixtures against a Rye-installed PostgreSQL database.",
  usage: [
    "node skills/rye-tabular-intake/scripts/tabular_fixture_smoke.mts (--db-url <postgresql://...> | --docker-container <name>)",
  ],
  options: [
    { flag: "--db-url <url>", description: "Target PostgreSQL database URL. Rye must already be installed." },
    { flag: "--docker-container <name>", description: "Run psql through docker exec against a running Postgres container." },
    { flag: "--docker-user <name>", description: "Database user for --docker-container. Default: rye." },
    { flag: "--docker-db <name>", description: "Database name for --docker-container. Default: rye." },
    { flag: "--output-dir <path>", description: "Directory for generated NDJSON and XLSX outputs. Default: tmp/rye-tabular-intake-smoke." },
    { flag: "--help", description: "Print command help." },
  ],
  examples: [
    "node skills/rye-tabular-intake/scripts/tabular_fixture_smoke.mts --db-url postgresql://rye:rye@127.0.0.1:54329/rye",
    "node skills/rye-tabular-intake/scripts/tabular_fixture_smoke.mts --docker-container rye-fixture-db",
  ],
};

await runCli(help, async (args) => {
  const dbUrl = getString(args, "db-url");
  const dockerContainer = getString(args, "docker-container");
  const outputDir = path.resolve(getString(args, "output-dir") ?? path.join(repoRoot, "tmp", "rye-tabular-intake-smoke"));
  const target = buildPsqlTarget({
    dbUrl,
    dockerContainer,
    dockerUser: getString(args, "docker-user") ?? "rye",
    dockerDb: getString(args, "docker-db") ?? "rye",
  });

  await fs.mkdir(outputDir, { recursive: true });

  const scenarios = await buildScenarioOutputs(outputDir);
  await prepareDatabase(target);
  await loadScenarioOutputs(target, scenarios);
  await loadRyeIntermediates(target, scenarios);
  await runMaterialization(target);
  const summary = await fetchSummary(target);

  process.stdout.write(
    `${JSON.stringify(
      {
        kind: "tabular_fixture_smoke_summary",
        output_dir: outputDir,
        scenarios: scenarios.map((scenario) => ({
          name: scenario.name,
          source_input: scenario.sourceInput,
          source_rows: scenario.sourceCount,
          mapped_records: scenario.mappedCount,
          grouped_records: scenario.groupedCount,
          stage_records: scenario.stageCount,
        })),
        database_summary: summary,
      },
      null,
      2,
    )}\n`,
  );
});

interface ScenarioRun {
  name: string;
  sourceInput: string;
  sourceRowsPath: string;
  mappedRecordsPath: string;
  stageRowsPath: string;
  sourceCount: number;
  mappedCount: number;
  groupedCount: number;
  stageCount: number;
}

async function buildScenarioOutputs(outputDir: string): Promise<ScenarioRun[]> {
  const fixtureRoot = path.join(skillRoot, "assets", "fixtures");
  const contactsFixture = path.join(fixtureRoot, "contacts-basic");
  const orgFixture = path.join(fixtureRoot, "org-profiles-one-to-many");
  const invoiceFixture = path.join(fixtureRoot, "invoice-lines-many-to-one");

  const orgOutputDir = path.join(outputDir, "org-profiles-one-to-many");
  await fs.mkdir(orgOutputDir, { recursive: true });
  const orgWorkbookPath = path.join(orgOutputDir, "org_profiles.xlsx");

  await runNodeScript("generate_fixture_xlsx.mts", [
    "--spec",
    path.join(orgFixture, "source", "org_profiles.workbook.json"),
    "--output",
    orgWorkbookPath,
  ]);

  return [
    await runScenario({
      name: "contacts-basic",
      sourceInput: path.join(contactsFixture, "source", "customers.csv"),
      extractArgs: ["--blank-as-null"],
      mapArgs: [
        "--config",
        path.join(contactsFixture, "mappings", "customers_to_demo_contacts.json"),
      ],
      outputDir,
    }),
    await runScenario({
      name: "org-profiles-one-to-many",
      sourceInput: orgWorkbookPath,
      extractArgs: ["--sheet", "Org Profiles", "--blank-as-null"],
      mapArgs: [
        "--module",
        path.join(orgFixture, "mappings", "org_profiles_to_demo_entities.mts"),
      ],
      outputDir,
    }),
    await runScenario({
      name: "invoice-lines-many-to-one",
      sourceInput: path.join(invoiceFixture, "source", "invoice_lines.csv"),
      extractArgs: ["--blank-as-null"],
      mapArgs: [
        "--config",
        path.join(invoiceFixture, "mappings", "invoice_rows_to_demo_invoice_lines.json"),
      ],
      groupArgs: [
        "--module",
        path.join(invoiceFixture, "mappings", "invoice_rows_to_demo_invoices.mts"),
      ],
      outputDir,
    }),
  ];
}

async function runScenario(config: {
  name: string;
  sourceInput: string;
  extractArgs: string[];
  mapArgs: string[];
  groupArgs?: string[];
  outputDir: string;
}): Promise<ScenarioRun> {
  const scenarioDir = path.join(config.outputDir, config.name);
  await fs.mkdir(scenarioDir, { recursive: true });

  const sourceRowsPath = path.join(scenarioDir, "source_rows.ndjson");
  const mappedRecordsPath = path.join(scenarioDir, "mapped_records.ndjson");
  const stageRowsPath = path.join(scenarioDir, "stage_rows.ndjson");

  const extractArgs = ["--input", config.sourceInput, ...config.extractArgs];
  const sourceRows = await runNodeScript("tabular_extract.mts", extractArgs);
  await fs.writeFile(sourceRowsPath, sourceRows, "utf8");

  const mappedRows = await runNodeScript("tabular_map.mts", [...config.mapArgs, "--input", sourceRowsPath]);
  const groupedRows = config.groupArgs
    ? await runNodeScript("tabular_group.mts", [...config.groupArgs, "--input", sourceRowsPath])
    : "";
  const combinedMappedRows = joinNdjson(mappedRows, groupedRows);
  await fs.writeFile(mappedRecordsPath, combinedMappedRows, "utf8");

  const stageRows = await runNodeScript("tabular_stage_rye.mts", ["--input", sourceRowsPath, "--status", "extracted"]);
  await fs.writeFile(stageRowsPath, stageRows, "utf8");

  return {
    name: config.name,
    sourceInput: config.sourceInput,
    sourceRowsPath,
    mappedRecordsPath,
    stageRowsPath,
    sourceCount: countNdjson(sourceRows),
    mappedCount: countNdjson(combinedMappedRows),
    groupedCount: countNdjson(groupedRows),
    stageCount: countNdjson(stageRows),
  };
}

async function prepareDatabase(target: PsqlTarget): Promise<void> {
  const setupSql = path.join(skillRoot, "assets", "postgres", "setup_demo_tables.sql");
  await runPsqlFile(target, setupSql);
  await runPsqlCommand(
    target,
    `DELETE FROM rye.artifacts
     WHERE artifact_type = ${sqlText(RYE_TABULAR_INTAKE.sourceFileArtifactType)};`,
  );
  await runPsqlCommand(
    target,
    `DELETE FROM rye.assertions
     WHERE assertion_type IN (
       ${sqlText(RYE_TABULAR_INTAKE.sourceRowAssertionType)},
       ${sqlText(RYE_TABULAR_INTAKE.mappedRecordAssertionType)},
       ${sqlText(RYE_TABULAR_INTAKE.stageRecordAssertionType)}
     );`,
  );
  await runPsqlCommand(
    target,
    `DELETE FROM rye.event_participants
     WHERE event_id IN (
       SELECT id FROM rye.events WHERE event_type LIKE 'rye_tabular_intake_%'
     );`,
  );
  await runPsqlCommand(
    target,
    `DELETE FROM rye.events
     WHERE event_type LIKE 'rye_tabular_intake_%';`,
  );
  await runPsqlCommand(
    target,
    `DELETE FROM rye.node_source_map
     WHERE source_schema = 'rye'
       AND source_table IN ('tabular_intake_run', 'tabular_intake_row');`,
  );
  await runPsqlCommand(
    target,
    `DELETE FROM rye.nodes
     WHERE external_source IN (
       ${sqlText(RYE_TABULAR_INTAKE.runExternalSource)},
       ${sqlText(RYE_TABULAR_INTAKE.rowExternalSource)}
     );`,
  );
  await runPsqlCommand(
    target,
    `DELETE FROM rye.node_source_map
     WHERE source_schema = 'public'
       AND source_table = 'demo_intake_stage';`,
  );
  await runPsqlCommand(
    target,
    `TRUNCATE TABLE
      public.demo_tabular_source_rows,
      public.demo_tabular_mapped_records,
      public.demo_intake_stage,
      public.demo_invoice_lines,
      public.demo_invoices,
      public.demo_locations,
      public.demo_orgs,
      public.demo_contacts
    RESTART IDENTITY CASCADE;`,
  );
}

async function loadScenarioOutputs(target: PsqlTarget, scenarios: ScenarioRun[]): Promise<void> {
  for (const scenario of scenarios) {
    await insertNdjson(target, "public.demo_tabular_source_rows", scenario.name, scenario.sourceRowsPath);
    await insertNdjson(target, "public.demo_tabular_mapped_records", scenario.name, scenario.mappedRecordsPath);
    await insertNdjson(target, "public.demo_intake_stage", scenario.name, scenario.stageRowsPath);
  }
}

async function loadRyeIntermediates(target: PsqlTarget, scenarios: ScenarioRun[]): Promise<void> {
  for (const scenario of scenarios) {
    await runCommitScript(target, scenario.sourceRowsPath, scenario.name, `${scenario.name}:extract`);
    await runCommitScript(target, scenario.mappedRecordsPath, scenario.name, `${scenario.name}:map`);
    await runCommitScript(target, scenario.stageRowsPath, scenario.name, `${scenario.name}:stage`);
  }
}

async function runMaterialization(target: PsqlTarget): Promise<void> {
  const sqlRoot = path.join(skillRoot, "assets", "postgres");
  await runPsqlFile(target, path.join(sqlRoot, "materialize_demo_contacts.sql"));
  await runPsqlFile(target, path.join(sqlRoot, "materialize_demo_orgs_and_locations.sql"));
  await runPsqlFile(target, path.join(sqlRoot, "materialize_demo_invoices.sql"));
  await runPsqlFile(target, path.join(sqlRoot, "link_stage_records.sql"));
}

async function fetchSummary(target: PsqlTarget): Promise<Record<string, unknown>> {
  const sql = `
SELECT json_build_object(
  'schema_type', 'rye.tabular_intake.fixture_smoke_summary.v1',
  'schema_version', 1,
  'demo_contacts', (SELECT count(*) FROM public.demo_contacts),
  'demo_orgs', (SELECT count(*) FROM public.demo_orgs),
  'demo_locations', (SELECT count(*) FROM public.demo_locations),
  'demo_invoices', (SELECT count(*) FROM public.demo_invoices),
  'demo_invoice_lines', (SELECT count(*) FROM public.demo_invoice_lines),
  'demo_tabular_source_rows', (SELECT count(*) FROM public.demo_tabular_source_rows),
  'demo_tabular_mapped_records', (SELECT count(*) FROM public.demo_tabular_mapped_records),
  'demo_intake_stage', (SELECT count(*) FROM public.demo_intake_stage),
  'tabular_run_nodes', (
    SELECT count(*) FROM rye.nodes WHERE external_source = ${sqlText(RYE_TABULAR_INTAKE.runExternalSource)}
  ),
  'tabular_row_nodes', (
    SELECT count(*) FROM rye.nodes WHERE external_source = ${sqlText(RYE_TABULAR_INTAKE.rowExternalSource)}
  ),
  'tabular_source_row_assertions', (
    SELECT count(*) FROM rye.current_assertions WHERE assertion_type = ${sqlText(RYE_TABULAR_INTAKE.sourceRowAssertionType)}
  ),
  'tabular_mapped_record_assertions', (
    SELECT count(*) FROM rye.current_assertions WHERE assertion_type = ${sqlText(RYE_TABULAR_INTAKE.mappedRecordAssertionType)}
  ),
  'tabular_stage_record_assertions', (
    SELECT count(*) FROM rye.current_assertions WHERE assertion_type = ${sqlText(RYE_TABULAR_INTAKE.stageRecordAssertionType)}
  ),
  'tabular_events', (
    SELECT count(*) FROM rye.events WHERE event_type LIKE 'rye_tabular_intake_%'
  ),
  'rye_stage_nodes', (
    SELECT count(*)
    FROM rye.node_source_map
    WHERE source_schema = 'public'
      AND source_table = 'demo_intake_stage'
  )
);`;

  const stdout = await runPsqlCapture(target, ["-Atqc", sql]);

  return JSON.parse(stdout.trim());
}

async function insertNdjson(target: PsqlTarget, tableName: string, scenario: string, ndjsonPath: string): Promise<void> {
  const text = await fs.readFile(ndjsonPath, "utf8");
  const lines = text.split(/\r?\n/).filter((line) => line.trim().length > 0);
  if (lines.length === 0) {
    return;
  }

  const values = lines
    .map((line) => `(${sqlText(scenario)}, ${sqlJson(line)})`)
    .join(",\n");

  const sql = `
INSERT INTO ${tableName} (scenario, payload)
VALUES
${values};`;

  await runPsqlCommand(target, sql);
}

async function runNodeScript(scriptName: string, args: string[]): Promise<string> {
  const scriptPath = path.join(scriptDir, scriptName);
  try {
    const { stdout } = await execFileAsync("node", [scriptPath, ...args], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
    });
    return stdout;
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown child process failure";
    throw new CliError(
      "fixture_script_failed",
      `Failed while running ${scriptName}.`,
      message,
      [`Run \`node ${scriptPath} --help\` for usage details.`],
    );
  }
}

async function runCommitScript(target: PsqlTarget, inputPath: string, scenario: string, runId: string): Promise<void> {
  const args = [
    "--input",
    inputPath,
    "--scenario",
    scenario,
    "--run-id",
    runId,
  ];

  if (target.kind === "db_url") {
    args.unshift("--db-url", target.dbUrl);
  } else {
    args.unshift("--docker-db", target.database);
    args.unshift("--docker-user", target.user);
    args.unshift("--docker-container", target.container);
  }

  await runNodeScript("tabular_commit_rye.mts", args);
}

async function runPsqlFile(target: PsqlTarget, filePath: string): Promise<void> {
  const sql = await fs.readFile(filePath, "utf8");
  try {
    await runPsql(target, ["-v", "ON_ERROR_STOP=1", "-f", "-"], sql, repoRoot);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown psql error";
    throw new CliError(
      "psql_file_failed",
      `Failed while running SQL file ${filePath}.`,
      message,
      [`Check that Rye is installed in the target database.`, `Inspect the SQL file for invalid syntax.`],
    );
  }
}

async function runPsqlCommand(target: PsqlTarget, sql: string): Promise<void> {
  try {
    await runPsql(target, ["-v", "ON_ERROR_STOP=1", "-c", sql], undefined, repoRoot);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown psql error";
    throw new CliError(
      "psql_command_failed",
      "Failed while running a PostgreSQL command.",
      message,
      [`Check the database URL.`, `Confirm Rye and the demo tables exist.`],
    );
  }
}

function countNdjson(text: string): number {
  return text.split(/\r?\n/).filter((line) => line.trim().length > 0).length;
}

function joinNdjson(...chunks: string[]): string {
  const lines = chunks
    .flatMap((chunk) => chunk.split(/\r?\n/))
    .filter((line) => line.trim().length > 0);
  return lines.length > 0 ? `${lines.join("\n")}\n` : "";
}
