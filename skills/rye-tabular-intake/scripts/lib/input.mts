import fs from "node:fs/promises";
import path from "node:path";

import { CliError } from "./cli.mts";
import { parseCsv, detectDelimiter } from "./csv.mts";
import type { SourceRow, TabularFormat } from "./contracts.mts";
import { readXlsxWorkbook } from "./xlsx.mts";

export interface TabularTable {
  name: string;
  sheet_name: string | null;
  rows: string[][];
}

export interface LoadedSource {
  path: string;
  format: TabularFormat;
  tables: TabularTable[];
}

export interface ExtractOptions {
  headerRow: number;
  sheet?: string;
  tableName?: string;
  columns?: string[];
  blankAsNull: boolean;
}

export async function loadSource(inputPath: string): Promise<LoadedSource> {
  const resolvedPath = path.resolve(inputPath);
  const extension = path.extname(resolvedPath).toLowerCase();

  if (extension !== ".csv" && extension !== ".tsv" && extension !== ".xlsx") {
    throw new CliError(
      "unsupported_input_format",
      `Unsupported input file: ${resolvedPath}`,
      `Expected a .csv, .tsv, or .xlsx file.`,
      [`Convert the file to .xlsx or .csv before extracting it.`],
    );
  }

  if (extension === ".xlsx") {
    const sheets = await readXlsxWorkbook(resolvedPath);
    return {
      path: resolvedPath,
      format: "xlsx",
      tables: sheets.map((sheet) => ({
        name: sheet.name,
        sheet_name: sheet.name,
        rows: sheet.rows,
      })),
    };
  }

  const text = await fs.readFile(resolvedPath, "utf8");
  const delimiter = extension === ".tsv" ? "\t" : detectDelimiter(text);
  const rows = parseCsv(text, delimiter);
  return {
    path: resolvedPath,
    format: "csv",
    tables: [
      {
        name: path.basename(resolvedPath, path.extname(resolvedPath)),
        sheet_name: null,
        rows,
      },
    ],
  };
}

export function selectTable(source: LoadedSource, selector?: string): TabularTable {
  if (source.tables.length === 0) {
    throw new CliError(
      "no_tables_found",
      `No tables were found in ${source.path}.`,
      `The file parsed successfully but no sheets or rows were available.`,
      [`Inspect the source file manually.`, `Try another input file.`],
    );
  }

  if (!selector) {
    return source.tables[0];
  }

  const asIndex = Number.parseInt(selector, 10);
  if (Number.isInteger(asIndex) && asIndex >= 1 && asIndex <= source.tables.length) {
    return source.tables[asIndex - 1];
  }

  const byName = source.tables.find((table) => table.name === selector || table.sheet_name === selector);
  if (!byName) {
    throw new CliError(
      "sheet_not_found",
      `No table or sheet matched "${selector}".`,
      `Available values: ${source.tables.map((table) => table.name).join(", ")}`,
      [`Run tabular_inspect.mts first to list tables and sheets.`],
    );
  }

  return byName;
}

export function buildSourceRows(source: LoadedSource, table: TabularTable, options: ExtractOptions): SourceRow[] {
  const headerIndex = options.headerRow - 1;
  if (headerIndex < 0 || headerIndex >= table.rows.length) {
    throw new CliError(
      "header_row_out_of_range",
      `Header row ${options.headerRow} is outside the available rows.`,
      `The selected table has ${table.rows.length} rows.`,
      [`Use tabular_inspect.mts to confirm the correct header row.`],
    );
  }

  const rawHeaders = options.columns && options.columns.length > 0 ? options.columns : table.rows[headerIndex] ?? [];
  const headers = normalizeHeaders(rawHeaders);
  const lineageStep = `extract:${options.tableName ?? table.name}`;
  const output: SourceRow[] = [];

  let recordNumber = 0;
  for (let rowOffset = headerIndex + 1; rowOffset < table.rows.length; rowOffset += 1) {
    const values = table.rows[rowOffset] ?? [];
    if (isRowEmpty(values)) {
      continue;
    }

    const row: Record<string, string | null> = {};
    for (let index = 0; index < headers.length; index += 1) {
      const value = values[index] ?? "";
      row[headers[index]] = options.blankAsNull && value === "" ? null : value;
    }

    recordNumber += 1;
    output.push({
      kind: "source_row",
      source: {
        path: source.path,
        format: source.format,
        table_name: options.tableName ?? table.name,
        sheet_name: table.sheet_name,
        header_row: options.headerRow,
        row_number: rowOffset + 1,
        record_number: recordNumber,
      },
      lineage: [lineageStep],
      row,
      raw: headers.map((_, index) => {
        const value = values[index] ?? "";
        return options.blankAsNull && value === "" ? null : value;
      }),
    });
  }

  return output;
}

export function normalizeHeaders(headers: string[]): string[] {
  const seen = new Map<string, number>();
  return headers.map((value, index) => {
    const trimmed = String(value ?? "").trim();
    const base = trimmed.length > 0 ? trimmed : `column_${index + 1}`;
    const existing = seen.get(base) ?? 0;
    seen.set(base, existing + 1);
    if (existing === 0) {
      return base;
    }
    return `${base}_${existing + 1}`;
  });
}

export function summarizeRows(rows: string[][], sampleSize: number, headerRow: number): Record<string, unknown> {
  const safeHeaderRow = Math.max(1, headerRow);
  const header = rows[safeHeaderRow - 1] ?? [];
  const sampleRows = rows.slice(safeHeaderRow, safeHeaderRow + sampleSize);
  const nonEmptyRowCount = rows.filter((row) => !isRowEmpty(row)).length;
  return {
    row_count: rows.length,
    non_empty_row_count: nonEmptyRowCount,
    header_row: safeHeaderRow,
    header_preview: normalizeHeaders(header),
    sample_rows: sampleRows,
  };
}

function isRowEmpty(row: string[]): boolean {
  return row.every((value) => String(value ?? "").trim() === "");
}
