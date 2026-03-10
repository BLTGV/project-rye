import { spawn } from "node:child_process";

import { CliError } from "./cli.mts";

export type PsqlTarget =
  | { kind: "db_url"; dbUrl: string }
  | { kind: "docker"; container: string; user: string; database: string };

export function buildPsqlTarget(config: {
  dbUrl?: string;
  dockerContainer?: string;
  dockerUser: string;
  dockerDb: string;
}): PsqlTarget {
  if (Boolean(config.dbUrl) === Boolean(config.dockerContainer)) {
    throw new CliError(
      "psql_target_required",
      "Pass exactly one of --db-url or --docker-container.",
      "The command needs either a direct PostgreSQL URL or a running Docker container name.",
      [`Use --db-url for a host-accessible database.`, `Use --docker-container when Postgres is only reachable via docker exec.`],
    );
  }

  if (config.dbUrl) {
    return { kind: "db_url", dbUrl: config.dbUrl };
  }

  return {
    kind: "docker",
    container: config.dockerContainer as string,
    user: config.dockerUser,
    database: config.dockerDb,
  };
}

export async function runPsql(target: PsqlTarget, args: string[], input?: string, cwd?: string): Promise<{ stdout: string; stderr: string }> {
  const command =
    target.kind === "db_url"
      ? {
          file: "psql",
          args: [target.dbUrl, ...args],
        }
      : {
          file: "docker",
          args: [
            "exec",
            "-i",
            target.container,
            "psql",
            "-U",
            target.user,
            "-d",
            target.database,
            ...args,
          ],
        };

  return await runProcess(command.file, command.args, input, cwd);
}

export async function runPsqlCapture(target: PsqlTarget, args: string[], input?: string, cwd?: string): Promise<string> {
  const result = await runPsql(target, args, input, cwd);
  return result.stdout;
}

export function sqlText(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

export function sqlNullableText(value: string | null | undefined): string {
  return value == null ? "NULL" : sqlText(value);
}

export function sqlJson(value: string): string {
  return `${sqlText(value)}::jsonb`;
}

async function runProcess(file: string, args: string[], input?: string, cwd?: string): Promise<{ stdout: string; stderr: string }> {
  return await new Promise((resolve, reject) => {
    const child = spawn(file, args, {
      cwd,
      stdio: ["pipe", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve({ stdout, stderr });
        return;
      }
      reject(new Error(stderr.trim() || `Process ${file} exited with code ${code}`));
    });

    if (input !== undefined) {
      child.stdin.write(input);
    }
    child.stdin.end();
  });
}
