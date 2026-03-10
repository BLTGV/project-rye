#!/usr/bin/env node
import { getInteger, getRequiredString, getString, hasFlag, runCli, type HelpSpec } from "./lib/cli.mts";
import { buildSourceRows, loadSource, selectTable } from "./lib/input.mts";
import { writeNdjson } from "./lib/ndjson.mts";

const help: HelpSpec = {
  name: "tabular_extract.mts",
  summary: "Extract a CSV or XLSX table into one NDJSON source_row object per data row.",
  usage: [
    "node skills/rye-tabular-intake/scripts/tabular_extract.mts --input <path> [--sheet <name-or-index>]",
  ],
  options: [
    { flag: "--input <path>", description: "CSV, TSV, or XLSX file to extract." },
    { flag: "--sheet <value>", description: "Optional sheet name or 1-based index for XLSX." },
    { flag: "--header-row <n>", description: "Header row number. Default: 1." },
    { flag: "--columns <csv>", description: "Override extracted headers with an explicit comma-separated list." },
    { flag: "--table-name <name>", description: "Override the emitted table_name in source metadata." },
    { flag: "--blank-as-null", description: "Emit null instead of empty strings." },
    { flag: "--help", description: "Print command help." },
  ],
  examples: [
    "node skills/rye-tabular-intake/scripts/tabular_extract.mts --input data/customers.csv",
    "node skills/rye-tabular-intake/scripts/tabular_extract.mts --input data/customers.xlsx --sheet Customers --blank-as-null",
  ],
};

await runCli(help, async (args) => {
  const input = getRequiredString(args, "input", help.name);
  const headerRow = getInteger(args, "header-row", 1);
  const sheet = getString(args, "sheet");
  const tableName = getString(args, "table-name");
  const columns = getString(args, "columns")?.split(",").map((value) => value.trim()).filter(Boolean);
  const blankAsNull = hasFlag(args, "blank-as-null");

  const source = await loadSource(input);
  const table = selectTable(source, sheet);
  const rows = buildSourceRows(source, table, {
    headerRow,
    sheet,
    tableName,
    columns,
    blankAsNull,
  });

  for (const row of rows) {
    writeNdjson(row);
  }
});
