#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import * as z from "zod/v4";

const apiUrl = requiredEnv("RYE_API_URL").replace(/\/+$/, "");
const agentToken = requiredEnv("RYE_AGENT_TOKEN");
const maxPayloadBytes = Number(process.env.RYE_MCP_MAX_PAYLOAD_BYTES ?? "65536");

type AgentCapability = {
  capability: string;
  domain_key?: string | null;
  scope_ref?: string | null;
  expires_at?: string | null;
};

type AgentMeResponse = {
  auth_required: boolean;
  agent: {
    agent_id: string;
    agent_key: string;
    label: string;
    runtime: string;
    default_scope_ref: string | null;
    capabilities: AgentCapability[];
  } | null;
};

const me = await apiGet<AgentMeResponse>("/api/agent/me");
if (!me.agent) {
  throw new Error("RYE_AGENT_TOKEN did not authenticate to the Rye API.");
}

const capabilities = me.agent.capabilities ?? [];
const toolNames: string[] = [];

const server = new McpServer(
  {
    name: "rye-secure-api",
    version: "0.1.0",
  },
  {
    capabilities: {
      logging: {},
    },
  },
);

if (hasCapability("rye.context.read")) {
  registerTool("rye.get_context_pack", {
    title: "Get Rye Context Pack",
    description: "Return the scoped Rye context pack visible to this authenticated agent.",
    inputSchema: {
      scope_ref: z.string().min(1).max(300).optional(),
      channel_ref: z.string().min(1).max(300).optional(),
      domain_keys: z.array(z.string().min(1).max(120)).max(20).optional(),
    },
    annotations: {
      readOnlyHint: true,
      openWorldHint: false,
    },
  }, async (input) => {
    const query = new URLSearchParams();
    if (input.scope_ref) query.set("scope_ref", input.scope_ref);
    if (input.channel_ref) query.set("channel_ref", input.channel_ref);
    if (input.domain_keys?.length) query.set("domain_keys", input.domain_keys.join(","));
    return jsonToolResult(await apiGet(`/api/context-pack?${query.toString()}`));
  });

  registerTool("rye.list_domains", {
    title: "List Rye Knowledge Domains",
    description: "List business knowledge domains and authority summaries visible to this agent.",
    inputSchema: {},
    annotations: {
      readOnlyHint: true,
      openWorldHint: false,
    },
  }, async () => jsonToolResult(await apiGet("/api/domains")));
}

if (hasCapability("rye.observation.create")) {
  registerTool("rye.submit_observation", {
    title: "Submit Rye Observation",
    description: "Store a raw observed source fact as an observation, not as authoritative business truth.",
    inputSchema: {
      statement: z.string().min(1).max(4000),
      domain_keys: z.array(z.string().min(1).max(120)).max(20).optional(),
      source_scope: z.string().min(1).max(300).optional(),
      impact_scope: z.string().min(1).max(300).optional(),
      evidence_refs: z.unknown().optional(),
      observed_at: z.string().min(1).max(80).optional(),
      properties: z.record(z.string(), z.unknown()).optional(),
    },
    annotations: {
      readOnlyHint: false,
      destructiveHint: false,
      openWorldHint: false,
    },
  }, async (input) => jsonToolResult(await apiPost("/api/observations", input)));
}

if (hasCapability("rye.candidate.create")) {
  registerTool("rye.propose_candidate_fact", {
    title: "Propose Rye Candidate Fact",
    description: "Create a candidate business fact for later human or authoritative review.",
    inputSchema: {
      candidate_kind: z.enum(["fact", "task", "edge", "decision", "procedure", "preference", "risk"]).default("fact").optional(),
      statement: z.string().min(1).max(4000),
      target_payload: z.record(z.string(), z.unknown()).optional(),
      domain_keys: z.array(z.string().min(1).max(120)).min(1).max(20),
      source_scope: z.string().min(1).max(300).optional(),
      impact_scope: z.string().min(1).max(300).optional(),
      authority_basis: z.string().min(1).max(500).optional(),
      speech_act: z.string().min(1).max(80).optional(),
      current_or_future: z.enum(["current", "future", "planned", "historical", "superseded"]).default("current").optional(),
      evidence_refs: z.unknown().optional(),
      normalized_key: z.string().min(1).max(300).optional(),
      source_node_ids: z.array(z.string().uuid()).max(100).optional(),
      derived_from_node_ids: z.array(z.string().uuid()).max(100).optional(),
      confidence: z.number().min(0).max(1).optional(),
      idempotency_key: z.string().min(1).max(200).optional(),
    },
    annotations: {
      readOnlyHint: false,
      destructiveHint: false,
      openWorldHint: false,
    },
  }, async (input) => {
    const { idempotency_key: idempotencyKey, ...body } = input;
    return jsonToolResult(await apiPost("/api/candidates", body, idempotencyKey));
  });
}

if (hasCapability("rye.review.read")) {
  registerTool("rye.list_review_queue", {
    title: "List Rye Review Queue",
    description: "Return candidate knowledge awaiting review.",
    inputSchema: {
      status: z.string().min(1).max(80).optional(),
      kind: z.string().min(1).max(80).optional(),
      q: z.string().min(1).max(300).optional(),
      include_closed: z.boolean().optional(),
      limit: z.number().int().min(1).max(200).default(80).optional(),
      offset: z.number().int().min(0).default(0).optional(),
    },
    annotations: {
      readOnlyHint: true,
      openWorldHint: false,
    },
  }, async (input) => {
    const query = new URLSearchParams();
    if (input.status) query.set("status", input.status);
    if (input.kind) query.set("kind", input.kind);
    if (input.q) query.set("q", input.q);
    if (input.include_closed !== undefined) query.set("include_closed", String(input.include_closed));
    if (input.limit !== undefined) query.set("limit", String(input.limit));
    if (input.offset !== undefined) query.set("offset", String(input.offset));
    return jsonToolResult(await apiGet(`/api/review-queue?${query.toString()}`));
  });
}

if (hasCapability("rye.audit.read")) {
  registerTool("rye.audit_actions", {
    title: "Read Rye Agent Audit Actions",
    description: "Return recent allowed and denied agent actions.",
    inputSchema: {
      limit: z.number().int().min(1).max(500).default(100).optional(),
    },
    annotations: {
      readOnlyHint: true,
      openWorldHint: false,
    },
  }, async (input) => {
    const query = new URLSearchParams();
    if (input.limit !== undefined) query.set("limit", String(input.limit));
    return jsonToolResult(await apiGet(`/api/audit/actions?${query.toString()}`));
  });
}

if (process.env.RYE_MCP_PRINT_TOOLS === "1") {
  console.log(JSON.stringify({ agent_key: me.agent.agent_key, tools: toolNames }, null, 2));
  process.exit(0);
}

const transport = new StdioServerTransport();
await server.connect(transport);

function registerTool<Input extends z.ZodRawShape>(
  name: string,
  config: {
    title: string;
    description: string;
    inputSchema: Input;
    annotations?: {
      readOnlyHint?: boolean;
      destructiveHint?: boolean;
      openWorldHint?: boolean;
    };
  },
  handler: (input: z.infer<z.ZodObject<Input>>) => Promise<{ content: { type: "text"; text: string }[] }>,
) {
  toolNames.push(name);
  server.registerTool(name, config, handler);
}

function hasCapability(capability: string): boolean {
  return capabilities.some((grant) => grant.capability === capability);
}

async function apiGet<T = unknown>(path: string): Promise<T> {
  const response = await fetch(apiUrl + path, {
    headers: {
      authorization: `Bearer ${agentToken}`,
      accept: "application/json",
    },
  });
  return parseResponse<T>(response);
}

async function apiPost<T = unknown>(path: string, body: unknown, idempotencyKey?: string): Promise<T> {
  ensurePayloadSize(body);
  const headers: Record<string, string> = {
    authorization: `Bearer ${agentToken}`,
    accept: "application/json",
    "content-type": "application/json",
  };
  if (idempotencyKey) headers["idempotency-key"] = idempotencyKey;
  const response = await fetch(apiUrl + path, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  return parseResponse<T>(response);
}

async function parseResponse<T>(response: Response): Promise<T> {
  const text = await response.text();
  let payload: unknown = text;
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = { error: text };
    }
  }
  if (!response.ok) {
    throw new Error(`Rye API ${response.status}: ${JSON.stringify(payload)}`);
  }
  return payload as T;
}

function ensurePayloadSize(value: unknown) {
  const bytes = Buffer.byteLength(JSON.stringify(value), "utf8");
  if (bytes > maxPayloadBytes) {
    throw new Error(`Tool payload is ${bytes} bytes; limit is ${maxPayloadBytes} bytes.`);
  }
}

function requiredEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required.`);
  return value;
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
