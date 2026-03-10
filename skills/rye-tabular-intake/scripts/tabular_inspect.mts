#!/usr/bin/env node
import { getInteger, getRequiredString, getString, runCli, type HelpSpec } from "./lib/cli.mts";
import { loadSource, selectTable, summarizeRows } from "./lib/input.mts";

const help: HelpSpec = {
  name: "tabular_inspect.mts",
  summary: "Inspect a CSV or XLSX source and report discovered tables, headers, and sample rows.",
  usage: [
    "node skills/rye-tabular-intake/scripts/tabular_inspect.mts --input <path> [--sheet <name-or-index>]",
  ],
  options: [
    { flag: "--input <path>", description: "CSV, TSV, or XLSX file to inspect." },
    { flag: "--sheet <value>", description: "Optional sheet name or 1-based index for focused inspection." },
    { flag: "--header-row <n>", description: "Header row to preview. Default: 1." },
    { flag: "--sample <n>", description: "Number of sample rows to show. Default: 5." },
    { flag: "--help", description: "Print command help." },
  ],
  examples: [
    "node skills/rye-tabular-intake/scripts/tabular_inspect.mts --input data/customers.xlsx",
    "node skills/rye-tabular-intake/scripts/tabular_inspect.mts --input data/customers.xlsx --sheet Customers --header-row 2",
  ],
};

await runCli(help, async (args) => {
  const input = getRequiredString(args, "input", help.name);
  const headerRow = getInteger(args, "header-row", 1);
  const sample = getInteger(args, "sample", 5);
  const sheet = getString(args, "sheet");

  const source = await loadSource(input);
  const focus = sheet ? selectTable(source, sheet) : undefined;
  const tables = (focus ? [focus] : source.tables).map((table) => ({
    name: table.name,
    sheet_name: table.sheet_name,
    ...summarizeRows(table.rows, sample, headerRow),
  }));

  process.stdout.write(
    `${JSON.stringify(
      {
        kind: "tabular_source_inspection",
        source: {
          path: source.path,
          format: source.format,
        },
        tables,
      },
      null,
      2,
    )}\n`,
  );
});
