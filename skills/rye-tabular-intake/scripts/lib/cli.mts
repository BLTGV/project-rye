export interface HelpOption {
  flag: string;
  description: string;
}

export interface HelpSpec {
  name: string;
  summary: string;
  usage: string[];
  options: HelpOption[];
  examples?: string[];
}

export class CliError extends Error {
  code: string;
  detail?: string;
  nextSteps: string[];

  constructor(code: string, message: string, detail?: string, nextSteps: string[] = []) {
    super(message);
    this.name = "CliError";
    this.code = code;
    this.detail = detail;
    this.nextSteps = nextSteps;
  }
}

export interface ParsedArgs {
  flags: Map<string, string[]>;
  positionals: string[];
}

export function parseArgs(argv: string[]): ParsedArgs {
  const flags = new Map<string, string[]>();
  const positionals: string[] = [];

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) {
      positionals.push(token);
      continue;
    }

    if (token === "--") {
      positionals.push(...argv.slice(index + 1));
      break;
    }

    const [flag, inlineValue] = token.slice(2).split("=", 2);
    if (inlineValue !== undefined) {
      pushFlag(flags, flag, inlineValue);
      continue;
    }

    const next = argv[index + 1];
    if (next !== undefined && !next.startsWith("--")) {
      pushFlag(flags, flag, next);
      index += 1;
      continue;
    }

    pushFlag(flags, flag, "true");
  }

  return { flags, positionals };
}

function pushFlag(flags: Map<string, string[]>, key: string, value: string): void {
  const existing = flags.get(key) ?? [];
  existing.push(value);
  flags.set(key, existing);
}

export function hasFlag(args: ParsedArgs, flag: string): boolean {
  return args.flags.has(flag);
}

export function getString(args: ParsedArgs, flag: string): string | undefined {
  const values = args.flags.get(flag);
  return values?.[values.length - 1];
}

export function getRequiredString(args: ParsedArgs, flag: string, commandName: string): string {
  const value = getString(args, flag);
  if (!value || value === "true") {
    throw new CliError(
      `${commandName}.missing_${flag}`,
      `Missing required --${flag} value.`,
      `The command needs --${flag} to know what input or module to use.`,
      [`Run \`node ${commandName} --help\`.`, `Provide --${flag} <value>.`],
    );
  }
  return value;
}

export function getInteger(args: ParsedArgs, flag: string, fallback: number): number {
  const value = getString(args, flag);
  if (!value || value === "true") {
    return fallback;
  }
  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new CliError(
      `invalid_${flag}`,
      `Invalid integer for --${flag}: ${value}`,
      `Expected a positive whole number.`,
      [`Use --${flag} 1 or another positive integer.`],
    );
  }
  return parsed;
}

export function printHelp(spec: HelpSpec): void {
  const lines: string[] = [];
  lines.push(`${spec.name}`);
  lines.push(`${spec.summary}`);
  lines.push("");
  lines.push("Usage:");
  for (const usage of spec.usage) {
    lines.push(`  ${usage}`);
  }
  if (spec.options.length > 0) {
    lines.push("");
    lines.push("Options:");
    for (const option of spec.options) {
      lines.push(`  ${option.flag.padEnd(24)} ${option.description}`);
    }
  }
  if (spec.examples && spec.examples.length > 0) {
    lines.push("");
    lines.push("Examples:");
    for (const example of spec.examples) {
      lines.push(`  ${example}`);
    }
  }
  process.stdout.write(`${lines.join("\n")}\n`);
}

export async function runCli(spec: HelpSpec, main: (args: ParsedArgs) => Promise<void>): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  if (hasFlag(args, "help")) {
    printHelp(spec);
    return;
  }

  try {
    await main(args);
  } catch (error) {
    const normalized = normalizeError(error);
    const lines = [`ERROR ${normalized.code}`, `Message: ${normalized.message}`];
    if (normalized.detail) {
      lines.push(`Detail: ${normalized.detail}`);
    }
    if (normalized.nextSteps.length > 0) {
      lines.push("Next:");
      for (const step of normalized.nextSteps) {
        lines.push(`- ${step}`);
      }
    }
    process.stderr.write(`${lines.join("\n")}\n`);
    process.exitCode = 1;
  }
}

function normalizeError(error: unknown): CliError {
  if (error instanceof CliError) {
    return error;
  }
  if (error instanceof Error) {
    return new CliError("unexpected_error", error.message);
  }
  return new CliError("unexpected_error", "Unknown error");
}
