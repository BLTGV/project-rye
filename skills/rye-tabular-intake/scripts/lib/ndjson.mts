import fs from "node:fs";
import readline from "node:readline";

import { CliError } from "./cli.mts";

export async function* readNdjson(inputPath?: string): AsyncGenerator<unknown> {
  const stream = inputPath ? fs.createReadStream(inputPath, "utf8") : process.stdin;
  const rl = readline.createInterface({
    input: stream,
    crlfDelay: Infinity,
  });

  let lineNumber = 0;
  for await (const line of rl) {
    lineNumber += 1;
    if (!line.trim()) {
      continue;
    }
    try {
      yield JSON.parse(line);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Invalid JSON";
      throw new CliError(
        "invalid_ndjson",
        `Failed to parse line ${lineNumber} as JSON.`,
        message,
        [`Validate the upstream command output.`, `Inspect the failing line in ${inputPath ?? "stdin"}.`],
      );
    }
  }
}

export function writeNdjson(value: unknown): void {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}
