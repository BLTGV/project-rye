#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import * as z from "zod/v4";

import {
  buildPsqlTarget,
  runPsqlCapture,
  sqlText,
  type PsqlTarget,
} from "../../rye-tabular-intake/scripts/lib/psql_target.mts";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const sourceContextCli = path.join(scriptDir, "source_context_commit_rye.mts");
const repoRoot = path.resolve(scriptDir, "..", "..", "..");

const targetSchema = {
  db_url: z.string().optional().describe("Target PostgreSQL URL. Defaults to RYE_DATABASE_URL or DATABASE_URL."),
  docker_container: z.string().optional().describe("Docker container running Postgres, used when db_url is not provided."),
  docker_user: z.string().default("rye").optional(),
  docker_db: z.string().default("rye").optional(),
};

const recordArraySchema = z.array(z.record(z.string(), z.unknown())).min(1);

const server = new McpServer(
  {
    name: "rye-instance",
    version: "0.1.0",
  },
  {
    capabilities: {
      logging: {},
    },
  },
);

server.registerTool(
  "rye.catalog",
  {
    title: "Rye Catalog",
    description: "Return node, edge, assertion, table, and count metadata from the connected Rye instance.",
    inputSchema: targetSchema,
    annotations: {
      readOnlyHint: true,
      openWorldHint: false,
    },
  },
  async (input) => jsonToolResult(await queryJson(resolveTarget(input), "SELECT rye.rye_catalog();")),
);

server.registerTool(
  "rye.search_nodes",
  {
    title: "Search Rye Nodes",
    description: "Search Rye nodes by label, type, external id, or properties text.",
    inputSchema: {
      ...targetSchema,
      query: z.string().min(1),
      node_type: z.string().optional(),
      limit: z.number().int().min(1).max(100).default(20).optional(),
    },
    annotations: {
      readOnlyHint: true,
      openWorldHint: false,
    },
  },
  async (input) => {
    const limit = input.limit ?? 20;
    const pattern = `%${escapeLike(input.query)}%`;
    const nodeTypeSql = input.node_type ? `AND node_type = ${sqlText(input.node_type)}` : "";
    const sql = `
SELECT coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb)
FROM (
  SELECT id, node_type, label, external_source, external_id, properties, created_at, updated_at
  FROM rye.nodes
  WHERE archived_at IS NULL
    ${nodeTypeSql}
    AND (
      label ILIKE ${sqlText(pattern)} ESCAPE '\\'
      OR node_type ILIKE ${sqlText(pattern)} ESCAPE '\\'
      OR coalesce(external_id, '') ILIKE ${sqlText(pattern)} ESCAPE '\\'
      OR properties::text ILIKE ${sqlText(pattern)} ESCAPE '\\'
    )
  ORDER BY created_at DESC
  LIMIT ${limit}
) q;`;
    return jsonToolResult(await queryJson(resolveTarget(input), sql));
  },
);

server.registerTool(
  "rye.node_summary",
  {
    title: "Rye Node Summary",
    description: "Return compact relationships, assertions, and recent activity for one Rye node.",
    inputSchema: {
      ...targetSchema,
      node_id: z.string().uuid(),
      max_items: z.number().int().min(1).max(100).default(15).optional(),
    },
    annotations: {
      readOnlyHint: true,
      openWorldHint: false,
    },
  },
  async (input) => {
    const sql = `SELECT rye.agent_node_summary(${sqlText(input.node_id)}::uuid, ${input.max_items ?? 15});`;
    return jsonToolResult(await queryJson(resolveTarget(input), sql));
  },
);

server.registerTool(
  "rye.source_inventory",
  {
    title: "Rye Source Inventory",
    description: "Return source accounts, containers, confirmation status, and item counts.",
    inputSchema: targetSchema,
    annotations: {
      readOnlyHint: true,
      openWorldHint: false,
    },
  },
  async (input) => {
    const sql = `
SELECT coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb)
FROM (
  SELECT
    n.id,
    n.node_type,
    n.label,
    n.external_source,
    n.external_id,
    n.properties->>'confirmation_status' AS confirmation_status,
    n.properties->>'source_account_id' AS source_account_id,
    count(e.id) FILTER (WHERE e.edge_type = 'contains_item' AND child.node_type = 'source_item') AS source_item_count,
    n.properties
  FROM rye.nodes n
  LEFT JOIN rye.edges e ON e.source_id = n.id AND e.archived_at IS NULL
  LEFT JOIN rye.nodes child ON child.id = e.target_id AND child.archived_at IS NULL
  WHERE n.archived_at IS NULL
    AND n.node_type IN ('source_account', 'source_container')
  GROUP BY n.id
  ORDER BY n.node_type, n.label
) q;`;
    return jsonToolResult(await queryJson(resolveTarget(input), sql));
  },
);

server.registerTool(
  "rye.pending_context_confirmations",
  {
    title: "Pending Source Context Confirmations",
    description: "Return source accounts and containers that still need source-context confirmation.",
    inputSchema: targetSchema,
    annotations: {
      readOnlyHint: true,
      openWorldHint: false,
    },
  },
  async (input) => {
    const sql = `
SELECT coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb)
FROM (
  SELECT id, node_type, label, external_source, external_id, properties
  FROM rye.nodes
  WHERE archived_at IS NULL
    AND node_type IN ('source_account', 'source_container')
    AND coalesce(properties->>'confirmation_status', properties#>>'{context_confirmation,status}', 'needs_confirmation') = 'needs_confirmation'
  ORDER BY node_type, label
) q;`;
    return jsonToolResult(await queryJson(resolveTarget(input), sql));
  },
);

server.registerTool(
  "rye.validate_source_context_update",
  {
    title: "Validate Source Context Update",
    description: "Validate connector-neutral source-context records without writing to Rye.",
    inputSchema: {
      records: recordArraySchema,
      run_id: z.string().optional(),
    },
    annotations: {
      readOnlyHint: true,
      openWorldHint: false,
    },
  },
  async (input) => jsonToolResult(await runSourceContextCli(input.records, ["--validate-only"], input.run_id)),
);

server.registerTool(
  "rye.commit_source_context_update",
  {
    title: "Commit Source Context Update",
    description: "Validate and commit connector-neutral source-context records into Rye, or emit SQL for an MCP/SQL console to run.",
    inputSchema: {
      ...targetSchema,
      records: recordArraySchema,
      run_id: z.string().optional(),
      emit_sql: z.boolean().default(false).optional(),
    },
    annotations: {
      readOnlyHint: false,
      destructiveHint: false,
      openWorldHint: false,
    },
  },
  async (input) => {
    const args = input.emit_sql ? ["--emit-sql"] : targetArgs(input);
    return textToolResult(await runSourceContextCli(input.records, args, input.run_id));
  },
);

const transport = new StdioServerTransport();
await server.connect(transport);

function resolveTarget(input: {
  db_url?: string;
  docker_container?: string;
  docker_user?: string;
  docker_db?: string;
}): PsqlTarget {
  return buildPsqlTarget({
    dbUrl: input.db_url ?? process.env.RYE_DATABASE_URL ?? process.env.DATABASE_URL,
    dockerContainer: input.docker_container,
    dockerUser: input.docker_user ?? "rye",
    dockerDb: input.docker_db ?? "rye",
  });
}

function targetArgs(input: {
  db_url?: string;
  docker_container?: string;
  docker_user?: string;
  docker_db?: string;
}): string[] {
  const dbUrl = input.db_url ?? process.env.RYE_DATABASE_URL ?? process.env.DATABASE_URL;
  if (dbUrl) {
    return ["--db-url", dbUrl];
  }
  if (input.docker_container) {
    return [
      "--docker-container",
      input.docker_container,
      "--docker-user",
      input.docker_user ?? "rye",
      "--docker-db",
      input.docker_db ?? "rye",
    ];
  }
  throw new Error("Provide db_url, docker_container, RYE_DATABASE_URL, or DATABASE_URL.");
}

async function queryJson(target: PsqlTarget, sql: string): Promise<unknown> {
  const wrapped = `
SELECT set_config('app.current_role', 'admin', false);
SELECT set_config('app.current_user_id', 'rye-mcp', false);
SELECT set_config('app.current_teams', 'system', false);
SET search_path = rye, public, pg_catalog;
${sql}`;
  const stdout = await runPsqlCapture(target, ["-Atq", "-v", "ON_ERROR_STOP=1", "-c", wrapped], undefined, repoRoot);
  const lines = stdout.trim().split("\n").filter(Boolean);
  const payload = lines[lines.length - 1] ?? "null";
  return JSON.parse(payload);
}

async function runSourceContextCli(records: Record<string, unknown>[], extraArgs: string[], runId?: string): Promise<unknown> {
  const dir = await fs.promises.mkdtemp(path.join(os.tmpdir(), "rye-source-context-"));
  const inputPath = path.join(dir, "input.ndjson");
  const ndjson = records.map((record) => JSON.stringify(record)).join("\n") + "\n";
  await fs.promises.writeFile(inputPath, ndjson, "utf8");

  const args = [sourceContextCli, "--input", inputPath, ...extraArgs];
  if (runId) {
    args.push("--run-id", runId);
  }
  const result = await runProcess(process.execPath, args, repoRoot);
  const text = result.stdout.trim();
  if (extraArgs.includes("--emit-sql")) {
    return text;
  }
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

async function runProcess(file: string, args: string[], cwd: string): Promise<{ stdout: string; stderr: string }> {
  return await new Promise((resolve, reject) => {
    const child = spawn(file, args, {
      cwd,
      stdio: ["ignore", "pipe", "pipe"],
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
  });
}

function jsonToolResult(value: unknown) {
  return {
    content: [
      {
        type: "text" as const,
        text: JSON.stringify(value, null, 2),
      },
    ],
  };
}

function textToolResult(value: unknown) {
  return {
    content: [
      {
        type: "text" as const,
        text: typeof value === "string" ? value : JSON.stringify(value, null, 2),
      },
    ],
  };
}

function escapeLike(value: string): string {
  return value.replaceAll("\\", "\\\\").replaceAll("%", "\\%").replaceAll("_", "\\_");
}
