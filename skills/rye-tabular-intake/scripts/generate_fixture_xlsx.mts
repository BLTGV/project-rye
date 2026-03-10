#!/usr/bin/env node
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

import { CliError, getRequiredString, runCli, type HelpSpec } from "./lib/cli.mts";

const execFileAsync = promisify(execFile);

const help: HelpSpec = {
  name: "generate_fixture_xlsx.mts",
  summary: "Build a minimal XLSX workbook from a JSON fixture spec.",
  usage: [
    "node skills/rye-tabular-intake/scripts/generate_fixture_xlsx.mts --spec <json> --output <xlsx>",
  ],
  options: [
    { flag: "--spec <path>", description: "Workbook spec JSON file with sheet_name and rows." },
    { flag: "--output <path>", description: "Output XLSX file to write." },
    { flag: "--help", description: "Print command help." },
  ],
  examples: [
    "node skills/rye-tabular-intake/scripts/generate_fixture_xlsx.mts --spec skills/rye-tabular-intake/assets/fixtures/org-profiles-one-to-many/source/org_profiles.workbook.json --output tmp/org_profiles.xlsx",
  ],
};

await runCli(help, async (args) => {
  const specPath = path.resolve(getRequiredString(args, "spec", help.name));
  const outputPath = path.resolve(getRequiredString(args, "output", help.name));
  const spec = validateSpec(JSON.parse(await fs.readFile(specPath, "utf8")));

  await fs.mkdir(path.dirname(outputPath), { recursive: true });

  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "rye-xlsx-"));
  try {
    await writeWorkbook(tempDir, spec);
    await execFileAsync("zip", ["-qr", outputPath, "."], { cwd: tempDir });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown XLSX generation error";
    throw new CliError(
      "xlsx_generation_failed",
      `Failed to generate workbook at ${outputPath}.`,
      message,
      [`Check that the zip command is available.`, `Validate the workbook spec JSON.`],
    );
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true });
  }
});

interface WorkbookSpec {
  sheet_name: string;
  rows: string[][];
}

function validateSpec(value: unknown): WorkbookSpec {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new CliError("invalid_workbook_spec", "Workbook spec must be a JSON object.");
  }

  const spec = value as Record<string, unknown>;
  if (typeof spec.sheet_name !== "string" || spec.sheet_name.trim() === "") {
    throw new CliError("invalid_workbook_spec", "Workbook spec requires a non-empty sheet_name.");
  }

  if (!Array.isArray(spec.rows) || spec.rows.some((row) => !Array.isArray(row))) {
    throw new CliError("invalid_workbook_spec", "Workbook spec requires rows as an array of arrays.");
  }

  return {
    sheet_name: spec.sheet_name,
    rows: spec.rows.map((row) => row.map((cell) => String(cell ?? ""))),
  };
}

async function writeWorkbook(rootDir: string, spec: WorkbookSpec): Promise<void> {
  await fs.mkdir(path.join(rootDir, "_rels"), { recursive: true });
  await fs.mkdir(path.join(rootDir, "xl", "_rels"), { recursive: true });
  await fs.mkdir(path.join(rootDir, "xl", "worksheets"), { recursive: true });

  await fs.writeFile(
    path.join(rootDir, "[Content_Types].xml"),
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
</Types>
`,
    "utf8",
  );

  await fs.writeFile(
    path.join(rootDir, "_rels", ".rels"),
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
`,
    "utf8",
  );

  await fs.writeFile(
    path.join(rootDir, "xl", "workbook.xml"),
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
    <sheet name="${escapeXml(spec.sheet_name)}" sheetId="1" r:id="rId1"/>
  </sheets>
</workbook>
`,
    "utf8",
  );

  await fs.writeFile(
    path.join(rootDir, "xl", "_rels", "workbook.xml.rels"),
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>
`,
    "utf8",
  );

  const rowXml = spec.rows
    .map((row, rowIndex) => {
      const cells = row
        .map((value, cellIndex) => {
          const ref = `${columnName(cellIndex)}${rowIndex + 1}`;
          return `      <c r="${ref}" t="inlineStr"><is><t>${escapeXml(value)}</t></is></c>`;
        })
        .join("\n");

      return `    <row r="${rowIndex + 1}">
${cells}
    </row>`;
    })
    .join("\n");

  await fs.writeFile(
    path.join(rootDir, "xl", "worksheets", "sheet1.xml"),
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
${rowXml}
  </sheetData>
</worksheet>
`,
    "utf8",
  );
}

function escapeXml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;")
    .replaceAll("'", "&apos;");
}

function columnName(index: number): string {
  let current = index + 1;
  let result = "";

  while (current > 0) {
    const remainder = (current - 1) % 26;
    result = String.fromCharCode(65 + remainder) + result;
    current = Math.floor((current - 1) / 26);
  }

  return result;
}
