import { execFile } from "node:child_process";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export interface XlsxSheet {
  name: string;
  rows: string[][];
}

export async function readXlsxWorkbook(filePath: string): Promise<XlsxSheet[]> {
  const workbookXml = await unzipText(filePath, "xl/workbook.xml");
  const relsXml = await unzipText(filePath, "xl/_rels/workbook.xml.rels");
  const sharedStringsXml = await unzipTextOptional(filePath, "xl/sharedStrings.xml");

  const sharedStrings = sharedStringsXml ? parseSharedStrings(sharedStringsXml) : [];
  const relationshipMap = parseRelationships(relsXml);
  const sheets = parseWorkbookSheets(workbookXml);

  const results: XlsxSheet[] = [];
  for (const sheet of sheets) {
    const target = relationshipMap.get(sheet.relationship_id);
    if (!target) {
      continue;
    }
    const entry = path.posix.normalize(path.posix.join("xl", target));
    const xml = await unzipText(filePath, entry);
    results.push({
      name: sheet.name,
      rows: parseSheetRows(xml, sharedStrings),
    });
  }

  return results;
}

async function unzipText(filePath: string, entry: string): Promise<string> {
  try {
    const result = await execFileAsync("unzip", ["-p", filePath, entry], {
      maxBuffer: 64 * 1024 * 1024,
      encoding: "utf8",
    });
    return result.stdout;
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown unzip failure";
    throw new Error(`Failed to read ${entry} from ${filePath}: ${message}`);
  }
}

async function unzipTextOptional(filePath: string, entry: string): Promise<string | null> {
  try {
    return await unzipText(filePath, entry);
  } catch {
    return null;
  }
}

function parseRelationships(xml: string): Map<string, string> {
  const map = new Map<string, string>();
  const regex = /<Relationship\b([^>]*)\/>/g;
  for (const match of xml.matchAll(regex)) {
    const attrs = parseAttributes(match[1]);
    if (attrs.Id && attrs.Target) {
      map.set(attrs.Id, attrs.Target);
    }
  }
  return map;
}

function parseWorkbookSheets(xml: string): Array<{ name: string; relationship_id: string }> {
  const sheets: Array<{ name: string; relationship_id: string }> = [];
  const regex = /<sheet\b([^>]*)\/>/g;
  for (const match of xml.matchAll(regex)) {
    const attrs = parseAttributes(match[1]);
    if (attrs.name && attrs["r:id"]) {
      sheets.push({ name: decodeXml(attrs.name), relationship_id: attrs["r:id"] });
    }
  }
  return sheets;
}

function parseSharedStrings(xml: string): string[] {
  const strings: string[] = [];
  const regex = /<si\b[^>]*>([\s\S]*?)<\/si>/g;
  for (const match of xml.matchAll(regex)) {
    strings.push(extractText(match[1]));
  }
  return strings;
}

function parseSheetRows(xml: string, sharedStrings: string[]): string[][] {
  const rows: string[][] = [];
  let rowIndex = 0;

  const rowRegex = /<row\b([^>]*)>([\s\S]*?)<\/row>/g;
  for (const rowMatch of xml.matchAll(rowRegex)) {
    const rowAttrs = parseAttributes(rowMatch[1]);
    const targetIndex = rowAttrs.r ? Number.parseInt(rowAttrs.r, 10) - 1 : rowIndex;
    while (rows.length < targetIndex) {
      rows.push([]);
    }
    const row = parseCells(rowMatch[2], sharedStrings);
    rows[targetIndex] = trimTrailingEmpty(row);
    rowIndex = targetIndex + 1;
  }

  return rows;
}

function parseCells(xml: string, sharedStrings: string[]): string[] {
  const row: string[] = [];
  const cellRegex = /<c\b([^>]*)\/>|<c\b([^>]*)>([\s\S]*?)<\/c>/g;
  let nextColumn = 0;

  for (const match of xml.matchAll(cellRegex)) {
    const attrText = match[1] ?? match[2] ?? "";
    const body = match[3] ?? "";
    const attrs = parseAttributes(attrText);
    const columnIndex = attrs.r ? columnIndexFromRef(attrs.r) : nextColumn;
    row[columnIndex] = extractCellValue(attrs.t, body, sharedStrings);
    nextColumn = columnIndex + 1;
  }

  return row.map((value) => value ?? "");
}

function extractCellValue(cellType: string | undefined, body: string, sharedStrings: string[]): string {
  if (!body) {
    return "";
  }

  if (cellType === "inlineStr") {
    return extractText(body);
  }

  const valueMatch = body.match(/<v\b[^>]*>([\s\S]*?)<\/v>/);
  const value = valueMatch ? decodeXml(valueMatch[1]) : "";

  if (cellType === "s") {
    const index = Number.parseInt(value, 10);
    return sharedStrings[index] ?? "";
  }

  if (cellType === "b") {
    return value === "1" ? "true" : "false";
  }

  return value;
}

function extractText(xml: string): string {
  const fragments = [...xml.matchAll(/<t\b[^>]*>([\s\S]*?)<\/t>/g)].map((match) => decodeXml(match[1]));
  if (fragments.length > 0) {
    return fragments.join("");
  }
  const plain = xml.replace(/<[^>]+>/g, "");
  return decodeXml(plain);
}

function parseAttributes(fragment: string): Record<string, string> {
  const attrs: Record<string, string> = {};
  const regex = /([A-Za-z_:][A-Za-z0-9_.:-]*)="([^"]*)"/g;
  for (const match of fragment.matchAll(regex)) {
    attrs[match[1]] = decodeXml(match[2]);
  }
  return attrs;
}

function columnIndexFromRef(reference: string): number {
  const letters = reference.replace(/[0-9]/g, "").toUpperCase();
  let index = 0;
  for (const letter of letters) {
    index = index * 26 + (letter.charCodeAt(0) - 64);
  }
  return Math.max(index - 1, 0);
}

function trimTrailingEmpty(row: string[]): string[] {
  const copy = [...row];
  while (copy.length > 0 && copy[copy.length - 1] === "") {
    copy.pop();
  }
  return copy;
}

function decodeXml(text: string): string {
  return text.replace(/&(#x?[0-9A-Fa-f]+|amp|lt|gt|quot|apos);/g, (full, entity) => {
    switch (entity) {
      case "amp":
        return "&";
      case "lt":
        return "<";
      case "gt":
        return ">";
      case "quot":
        return "\"";
      case "apos":
        return "'";
      default:
        if (entity.startsWith("#x")) {
          return String.fromCodePoint(Number.parseInt(entity.slice(2), 16));
        }
        if (entity.startsWith("#")) {
          return String.fromCodePoint(Number.parseInt(entity.slice(1), 10));
        }
        return full;
    }
  });
}
