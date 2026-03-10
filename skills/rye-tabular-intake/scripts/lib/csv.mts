export function detectDelimiter(text: string): string {
  const sample = text
    .split(/\r?\n/)
    .filter((line) => line.trim().length > 0)
    .slice(0, 5);

  const candidates = [",", "\t", ";", "|"];
  let winner = ",";
  let score = -1;

  for (const candidate of candidates) {
    const counts = sample.map((line) => countDelimiter(line, candidate));
    const currentScore = counts.reduce((sum, value) => sum + value, 0);
    if (currentScore > score) {
      score = currentScore;
      winner = candidate;
    }
  }

  return winner;
}

function countDelimiter(line: string, delimiter: string): number {
  let total = 0;
  let inQuotes = false;
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    if (char === "\"") {
      if (line[index + 1] === "\"") {
        index += 1;
        continue;
      }
      inQuotes = !inQuotes;
      continue;
    }
    if (!inQuotes && char === delimiter) {
      total += 1;
    }
  }
  return total;
}

export function parseCsv(text: string, delimiter: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let inQuotes = false;

  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    const next = text[index + 1];

    if (char === "\"") {
      if (inQuotes && next === "\"") {
        cell += "\"";
        index += 1;
        continue;
      }
      inQuotes = !inQuotes;
      continue;
    }

    if (!inQuotes && char === delimiter) {
      row.push(cell);
      cell = "";
      continue;
    }

    if (!inQuotes && (char === "\n" || char === "\r")) {
      if (char === "\r" && next === "\n") {
        index += 1;
      }
      row.push(cell);
      rows.push(row);
      row = [];
      cell = "";
      continue;
    }

    cell += char;
  }

  if (cell.length > 0 || row.length > 0) {
    row.push(cell);
    rows.push(row);
  }

  return rows;
}
