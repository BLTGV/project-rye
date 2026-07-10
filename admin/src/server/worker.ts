import { Hono, type Context } from "hono";
import { cors } from "hono/cors";
import { z } from "zod";
import { zValidator } from "@hono/zod-validator";
import { type Env, loadInstances, pickInstance, sqlFor } from "./db";
import {
  acceptCrmStagePlanCandidate,
  acceptPmMilestonePlanCandidate,
  acceptPmTaskPlanCandidate,
  acceptSourcePolicyCandidate,
  authenticateAgentToken,
  authorizeAgentAction,
  createAgentKnowledgeCandidate,
  createKnowledgeCandidate,
  fetchAgentAuditActions,
  fetchAgentContextPack,
  fetchActiveDisputes,
  fetchActivityTimeline,
  fetchAssertionComposition,
  fetchCatalog,
  fetchCountyRollup,
  fetchCrmWorkspace,
  fetchCandidateAccessEnvelope,
  fetchDashboardKpis,
  fetchDomains,
  fetchExtractionTimeline,
  fetchKnowledgeKpis,
  fetchKnowledgeMap,
  fetchCandidateReviewQueue,
  fetchPmWorkspace,
  fetchSupersessions,
  fetchTopParticipants,
  fetchTopSubjects,
  fetchNeighborhood,
  fetchNodeDetail,
  fetchNodeKnowledge,
  fetchQuoteTimeline,
  fetchReconKpis,
  fetchRecentEvents,
  fetchTopClients,
  fetchTopLessees,
  fetchTopOwners,
  promoteKnowledgeCandidate,
  searchNodes,
  setKnowledgeCandidateStatus,
  submitAgentObservation,
  type AgentAuthContext,
} from "./queries";

type AppVariables = {
  instance: ReturnType<typeof pickInstance>;
  auth: AgentAuthContext | null;
};
type RyeContext = Context<{ Bindings: Env; Variables: AppVariables }>;

const app = new Hono<{ Bindings: Env; Variables: AppVariables }>();

app.use("*", async (c, next) => {
  const origins = parseAllowedOrigins(c.env.RYE_API_ALLOWED_ORIGINS);
  return cors({ origin: origins.length > 0 ? origins : "*" })(c, next);
});

const uuidSchema = z.string().uuid();

const candidateKindSchema = z.enum([
  "fact",
  "task",
  "edge",
  "decision",
  "procedure",
  "preference",
  "risk",
]);

const candidateStatusSchema = z.enum([
  "proposed",
  "accepted",
  "rejected",
  "needs_review",
  "duplicate",
  "superseded",
]);

const jsonRecordSchema = z.record(z.string(), z.unknown());
const optionalJsonRecordSchema = jsonRecordSchema.optional();
const optionalStringArraySchema = z.array(z.string().trim().min(1)).optional();

const createCandidateSchema = z.object({
  candidate_kind: candidateKindSchema,
  statement: z.string().trim().min(1),
  target_payload: jsonRecordSchema.optional(),
  domain_keys: z.array(z.string().trim().min(1)).optional(),
  source_scope: z.string().trim().min(1).nullable().optional(),
  impact_scope: z.string().trim().min(1).nullable().optional(),
  authority_basis: z.string().trim().min(1).nullable().optional(),
  speech_act: z.string().trim().min(1).nullable().optional(),
  current_or_future: z.enum(["current", "future", "planned", "historical", "superseded"]).optional(),
  evidence_refs: z.unknown().optional(),
  review_context_ids: z.array(uuidSchema).optional(),
  normalized_key: z.string().trim().min(1).nullable().optional(),
  created_by: z.string().trim().min(1).nullable().optional(),
  source_node_ids: z.array(uuidSchema).optional(),
  derived_from_node_ids: z.array(uuidSchema).optional(),
  confidence: z.number().min(0).max(1).nullable().optional(),
});

const setCandidateStatusSchema = z.object({
  status: candidateStatusSchema,
  reason: z.string().nullable().optional(),
  actor: z.string().trim().min(1).nullable().optional(),
});

const promoteCandidateSchema = z.discriminatedUnion("target_type", [
  z.object({
    target_type: z.literal("assertion"),
    subject_node_id: uuidSchema,
    assertion_type: z.string().trim().min(1),
    assertion_key: z.string().trim().min(1).nullable().optional(),
    claim: jsonRecordSchema,
    effective_at: z.string().nullable().optional(),
    effective_to: z.string().nullable().optional(),
    confidence: z.number().min(0).max(1).nullable().optional(),
    actor: z.string().trim().min(1).nullable().optional(),
  }),
  z.object({
    target_type: z.literal("task"),
    label: z.string().trim().min(1),
    properties: jsonRecordSchema.optional(),
    actor: z.string().trim().min(1).nullable().optional(),
  }),
  z.object({
    target_type: z.literal("edge"),
    source_id: uuidSchema,
    target_id: uuidSchema,
    edge_type: z.string().trim().min(1),
    properties: jsonRecordSchema.optional(),
    effective_from: z.string().nullable().optional(),
    effective_to: z.string().nullable().optional(),
    actor: z.string().trim().min(1).nullable().optional(),
  }),
]);

const acceptSourcePolicyCandidateSchema = z.object({
  scope_id: uuidSchema,
  status_domains: z.array(z.string().trim().min(1)).min(1),
  authoritative_source: z.string().trim().min(1),
  effective_at: z.string().nullable().optional(),
  review_gate: z.string().trim().min(1).nullable().optional(),
  evidence_allowed: optionalStringArraySchema,
  supersedes: z.string().trim().min(1).nullable().optional(),
  notes: z.string().trim().min(1).nullable().optional(),
  actor: z.string().trim().min(1).nullable().optional(),
});

const acceptCrmStagePlanCandidateSchema = z.object({
  opportunity_id: uuidSchema,
  stage: z.string().trim().min(1),
  effective_at: z.string().trim().min(1),
  reason: z.string().trim().min(1).nullable().optional(),
  actor: z.string().trim().min(1).nullable().optional(),
  plan_properties: optionalJsonRecordSchema,
});

const acceptPmTaskPlanCandidateSchema = z.object({
  task_id: uuidSchema,
  status: z.string().trim().min(1),
  effective_at: z.string().trim().min(1),
  reason: z.string().trim().min(1).nullable().optional(),
  actor: z.string().trim().min(1).nullable().optional(),
  plan_properties: optionalJsonRecordSchema,
});

const acceptPmMilestonePlanCandidateSchema = z.object({
  milestone_id: uuidSchema,
  status: z.string().trim().min(1),
  effective_at: z.string().trim().min(1),
  reason: z.string().trim().min(1).nullable().optional(),
  actor: z.string().trim().min(1).nullable().optional(),
  plan_properties: optionalJsonRecordSchema,
});

const observationSchema = z.object({
  statement: z.string().trim().min(1).max(4000),
  domain_keys: z.array(z.string().trim().min(1)).optional(),
  source_scope: z.string().trim().min(1).nullable().optional(),
  impact_scope: z.string().trim().min(1).nullable().optional(),
  evidence_refs: z.unknown().optional(),
  observed_at: z.string().trim().min(1).nullable().optional(),
  properties: jsonRecordSchema.optional(),
});

function boolQuery(value: string | undefined): boolean {
  return value === "1" || value === "true" || value === "yes" || value === "on";
}

function parseAllowedOrigins(value: string | undefined): string[] {
  return (value ?? "")
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean);
}

function apiAuthRequired(env: Env): boolean {
  return (env.RYE_API_AUTH_MODE ?? "off").toLowerCase() === "required";
}

function bearerToken(req: Request): string | null {
  const header = req.headers.get("authorization") ?? "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() || null;
}

function domainKeysFromQuery(value: string | undefined): string[] {
  return (value ?? "")
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
}

function domainKeysFromCandidateInput(input: z.infer<typeof createCandidateSchema>): string[] {
  if (input.domain_keys?.length) return input.domain_keys;
  const payloadDomainKeys = input.target_payload?.domain_keys;
  if (Array.isArray(payloadDomainKeys)) {
    return payloadDomainKeys.filter((value): value is string => typeof value === "string" && value.trim() !== "");
  }
  return [];
}

function sourceScopeFromCandidateInput(input: z.infer<typeof createCandidateSchema>): string | null {
  if (input.source_scope) return input.source_scope;
  const payloadSourceScope = input.target_payload?.source_scope;
  return typeof payloadSourceScope === "string" && payloadSourceScope.trim() !== ""
    ? payloadSourceScope
    : null;
}

async function enforceCapability(
  c: RyeContext,
  opts: {
    action: string;
    capability: string;
    domainKeys?: string[];
    scopeRef?: string | null;
    targetRef?: string | null;
    request?: Record<string, unknown>;
  }
): Promise<Response | null> {
  if (!apiAuthRequired(c.env)) return null;
  const auth = c.get("auth");
  if (!auth) return c.json({ error: "missing bearer token" }, 401);
  const sql = sqlFor(c.get("instance"));
  const result = await authorizeAgentAction(sql, {
    agentId: auth.agent_id,
    action: opts.action,
    capability: opts.capability,
    domainKeys: opts.domainKeys ?? [],
    scopeRef: opts.scopeRef ?? null,
    targetRef: opts.targetRef ?? null,
    request: opts.request ?? {},
  });
  if (!result.allowed) {
    return c.json({ error: "forbidden", reason: result.reason }, 403);
  }
  return null;
}

function authActor(c: RyeContext): string | null {
  return apiAuthRequired(c.env) ? c.get("auth")?.agent_key ?? null : null;
}

/**
 * Auth-required mode is the scoped agent plane. Keep this as an explicit
 * allowlist so a newly added administrative route is closed to agent tokens
 * until it is deliberately backed by a capability- and domain-scoped query.
 */
function isScopedAgentRoute(method: string, path: string): boolean {
  if (method === "GET") {
    return [
      "/api/agent/me",
      "/api/domains",
      "/api/context-pack",
      "/api/review-queue",
      "/api/audit/actions",
      "/api/candidates/review",
    ].includes(path);
  }

  if (method !== "POST") return false;
  if (path === "/api/observations" || path === "/api/candidates") return true;

  return /^\/api\/candidates\/[^/]+\/(status|promote|accept-source-policy|accept-crm-stage-plan|accept-pm-task-plan|accept-pm-milestone-plan)$/.test(
    path
  );
}

// Resolve which Rye instance every API call targets.
app.use("/api/*", async (c, next) => {
  const requested = c.req.query("instance") ?? c.req.header("x-rye-instance") ?? null;
  try {
    const instance = pickInstance(c.env, requested);
    c.set("instance", instance);
  } catch (e) {
    return c.json({ error: (e as Error).message }, 400);
  }
  await next();
});

app.use("/api/*", async (c, next) => {
  if (!apiAuthRequired(c.env)) {
    c.set("auth", null);
    await next();
    return;
  }

  if (c.req.path === "/api/health" || c.req.path === "/api/instances") {
    c.set("auth", null);
    await next();
    return;
  }

  const token = bearerToken(c.req.raw);
  if (!token) {
    return c.json({ error: "missing bearer token" }, 401);
  }

  const sql = sqlFor(c.get("instance"));
  const auth = await authenticateAgentToken(sql, token);
  if (!auth) {
    return c.json({ error: "invalid bearer token" }, 401);
  }

  c.set("auth", auth);

  if (!isScopedAgentRoute(c.req.method, c.req.path)) {
    return c.json(
      {
        error: "forbidden",
        reason: "agent tokens cannot access administrative routes",
      },
      403
    );
  }

  await next();
});

app.get("/api/instances", (c) => {
  const all = loadInstances(c.env);
  return c.json({
    default: c.env.DEFAULT_INSTANCE,
    instances: all.map((i) => ({ id: i.id, label: i.label, blurb: i.blurb })),
  });
});

app.get("/api/agent/me", (c) => {
  return c.json({
    auth_required: apiAuthRequired(c.env),
    agent: c.get("auth") ?? null,
  });
});

app.get("/api/domains", async (c) => {
  const blocked = await enforceCapability(c, {
    action: "domains_list",
    capability: "rye.context.read",
    request: { path: c.req.path },
  });
  if (blocked) return blocked;

  const auth = c.get("auth");
  const includeProperties =
    !apiAuthRequired(c.env) ||
    !!auth?.capabilities.some((grant) => grant.capability === "rye.domain.admin");
  const sql = sqlFor(c.get("instance"));
  return c.json(await fetchDomains(sql, { includeProperties }));
});

app.get("/api/context-pack", async (c) => {
  const auth = c.get("auth");
  if (apiAuthRequired(c.env) && !auth) {
    return c.json({ error: "missing bearer token" }, 401);
  }
  if (!auth) {
    return c.json({ error: "context packs require an authenticated agent" }, 400);
  }

  const sql = sqlFor(c.get("instance"));
  const blocked = await enforceCapability(c, {
    action: "context_pack_read",
    capability: "rye.context.read",
    domainKeys: domainKeysFromQuery(c.req.query("domain_keys")),
    scopeRef: c.req.query("scope_ref") ?? auth.default_scope_ref ?? null,
    targetRef: c.req.query("channel_ref") ?? null,
    request: { path: c.req.path },
  });
  if (blocked) return blocked;

  return c.json(
    await fetchAgentContextPack(sql, auth.agent_id, {
      scopeRef: c.req.query("scope_ref") ?? auth.default_scope_ref ?? null,
      channelRef: c.req.query("channel_ref") ?? null,
      domainKeys: domainKeysFromQuery(c.req.query("domain_keys")),
    })
  );
});

app.post("/api/observations", zValidator("json", observationSchema), async (c) => {
  const auth = c.get("auth");
  if (apiAuthRequired(c.env) && !auth) {
    return c.json({ error: "missing bearer token" }, 401);
  }
  if (!auth) {
    return c.json({ error: "observation submission requires an authenticated agent" }, 400);
  }

  const sql = sqlFor(c.get("instance"));
  const input = c.req.valid("json");
  const blocked = await enforceCapability(c, {
    action: "observation_create",
    capability: "rye.observation.create",
    domainKeys: input.domain_keys ?? [],
    scopeRef: input.source_scope ?? null,
    targetRef: input.impact_scope ?? null,
    request: { statement: input.statement },
  });
  if (blocked) return blocked;

  const result = await submitAgentObservation(sql, auth.agent_id, input);
  return c.json(result, 201);
});

app.get(
  "/api/review-queue",
  zValidator(
    "query",
    z.object({
      status: z.string().optional(),
      kind: z.string().optional(),
      q: z.string().optional(),
      include_closed: z.string().optional(),
      limit: z.coerce.number().int().min(1).max(200).optional(),
      offset: z.coerce.number().int().min(0).optional(),
      instance: z.string().optional(),
    })
  ),
  async (c) => {
    const blocked = await enforceCapability(c, {
      action: "review_queue_read",
      capability: "rye.review.read",
      request: { path: c.req.path },
    });
    if (blocked) return blocked;

    const sql = sqlFor(c.get("instance"));
    const q = c.req.valid("query");
    return c.json(
      await fetchCandidateReviewQueue(sql, {
        status: q.status ?? null,
        kind: q.kind ?? null,
        q: q.q ?? null,
        includeClosed: boolQuery(q.include_closed),
        limit: q.limit,
        offset: q.offset,
      })
    );
  }
);

app.get("/api/audit/actions", async (c) => {
  const blocked = await enforceCapability(c, {
    action: "audit_actions_read",
    capability: "rye.audit.read",
    request: { path: c.req.path },
  });
  if (blocked) return blocked;

  const sql = sqlFor(c.get("instance"));
  const limit = Math.min(Number(c.req.query("limit") ?? "100"), 500);
  return c.json(await fetchAgentAuditActions(sql, limit));
});

app.get("/api/catalog", async (c) => {
  const sql = sqlFor(c.get("instance"));
  return c.json(await fetchCatalog(sql));
});

app.get("/api/dashboard", async (c) => {
  const sql = sqlFor(c.get("instance"));
  const catalog = await fetchCatalog(sql);
  const isRecon = !!catalog.node_types["parcel"];
  if (isRecon) {
    const [kpis, owners, lessees, counties, extraction, recent] = await Promise.all([
      fetchReconKpis(sql),
      fetchTopOwners(sql, 10),
      fetchTopLessees(sql, 10),
      fetchCountyRollup(sql, 12),
      fetchExtractionTimeline(sql),
      fetchRecentEvents(sql, 12),
    ]);
    return c.json({
      kind: "recon",
      catalog,
      kpis,
      topOwners: owners,
      topLessees: lessees,
      counties,
      extraction,
      recent,
    });
  }
  // Quote-driven shape (instances that track quote_created events)
  if (catalog.event_types?.["quote_created"]) {
    const [kpis, timeline, topClients, recent] = await Promise.all([
      fetchDashboardKpis(sql),
      fetchQuoteTimeline(sql, 90),
      fetchTopClients(sql, 8),
      fetchRecentEvents(sql, 10),
    ]);
    return c.json({ kind: "quotes", catalog, kpis, timeline, topClients, recent });
  }

  // Generic knowledge-graph shape: people↔events, accumulated + superseded
  // facts, disputes. Works for any instance that isn't recon/quote-specific.
  const [kpis, topParticipants, timeline, composition, topSubjects, supersessions, disputes, recent] =
    await Promise.all([
      fetchKnowledgeKpis(sql),
      fetchTopParticipants(sql, 10),
      fetchActivityTimeline(sql),
      fetchAssertionComposition(sql),
      fetchTopSubjects(sql, 10),
      fetchSupersessions(sql, 8),
      fetchActiveDisputes(sql, 10),
      fetchRecentEvents(sql, 12),
    ]);
  return c.json({
    kind: "knowledge",
    catalog,
    kpis,
    topParticipants,
    timeline,
    composition,
    topSubjects,
    supersessions,
    disputes,
    recent,
  });
});

app.get("/api/knowledge-map", async (c) => {
  const sql = sqlFor(c.get("instance"));
  return c.json(await fetchKnowledgeMap(sql));
});

app.get("/api/workspace/crm", async (c) => {
  const sql = sqlFor(c.get("instance"));
  return c.json(await fetchCrmWorkspace(sql));
});

app.get("/api/workspace/pm", async (c) => {
  const sql = sqlFor(c.get("instance"));
  return c.json(await fetchPmWorkspace(sql));
});

app.get(
  "/api/candidates/review",
  zValidator(
    "query",
    z.object({
      status: z.string().optional(),
      kind: z.string().optional(),
      q: z.string().optional(),
      include_closed: z.string().optional(),
      limit: z.coerce.number().int().min(1).max(200).optional(),
      offset: z.coerce.number().int().min(0).optional(),
      instance: z.string().optional(),
    })
  ),
  async (c) => {
    const blocked = await enforceCapability(c, {
      action: "candidate_review_read",
      capability: "rye.review.read",
      request: { path: c.req.path },
    });
    if (blocked) return blocked;

    const sql = sqlFor(c.get("instance"));
    const q = c.req.valid("query");
    return c.json(
      await fetchCandidateReviewQueue(sql, {
        status: q.status ?? null,
        kind: q.kind ?? null,
        q: q.q ?? null,
        includeClosed: boolQuery(q.include_closed),
        limit: q.limit,
        offset: q.offset,
      })
    );
  }
);

app.get(
  "/api/nodes",
  zValidator(
    "query",
    z.object({
      q: z.string().optional(),
      type: z.string().optional(),
      limit: z.coerce.number().int().min(1).max(200).optional(),
      offset: z.coerce.number().int().min(0).optional(),
      instance: z.string().optional(),
    })
  ),
  async (c) => {
    const sql = sqlFor(c.get("instance"));
    const q = c.req.valid("query");
    const result = await searchNodes(sql, q);
    return c.json(result);
  }
);

app.get("/api/nodes/:id/knowledge", async (c) => {
  const sql = sqlFor(c.get("instance"));
  return c.json(
    await fetchNodeKnowledge(sql, c.req.param("id"), {
      asOf: c.req.query("as_of") || null,
      includeStale: boolQuery(c.req.query("include_stale")),
      includeSuperseded: boolQuery(c.req.query("include_superseded")),
      includeRejected: boolQuery(c.req.query("include_rejected")),
      includeRawEvidence: boolQuery(c.req.query("include_raw_evidence")),
    })
  );
});

app.get("/api/nodes/:id", async (c) => {
  const sql = sqlFor(c.get("instance"));
  return c.json(await fetchNodeDetail(sql, c.req.param("id")));
});

app.get("/api/nodes/:id/graph", async (c) => {
  const sql = sqlFor(c.get("instance"));
  const hops = Number(c.req.query("hops") ?? "1");
  return c.json(await fetchNeighborhood(sql, c.req.param("id"), hops));
});

app.post("/api/candidates", zValidator("json", createCandidateSchema), async (c) => {
  const sql = sqlFor(c.get("instance"));
  const input = c.req.valid("json");
  const auth = c.get("auth");
  if (apiAuthRequired(c.env) && auth) {
    const blocked = await enforceCapability(c, {
      action: "candidate_create",
      capability: "rye.candidate.create",
      domainKeys: domainKeysFromCandidateInput(input),
      scopeRef: sourceScopeFromCandidateInput(input),
      request: { candidate_kind: input.candidate_kind, statement: input.statement },
    });
    if (blocked) return blocked;
  }
  const result =
    apiAuthRequired(c.env) && auth
      ? await createAgentKnowledgeCandidate(sql, auth.agent_id, input, c.req.header("idempotency-key"))
      : await createKnowledgeCandidate(sql, input);
  return c.json(result, 201);
});

app.post(
  "/api/candidates/:id/status",
  zValidator("param", z.object({ id: uuidSchema })),
  zValidator("json", setCandidateStatusSchema),
  async (c) => {
    const sql = sqlFor(c.get("instance"));
    const candidateId = c.req.valid("param").id;
    const envelope = await fetchCandidateAccessEnvelope(sql, candidateId);
    const input = c.req.valid("json");
    const blocked = await enforceCapability(c, {
      action: "candidate_status_set",
      capability: "rye.candidate.adjudicate",
      domainKeys: envelope.domain_keys,
      scopeRef: envelope.source_scope,
      targetRef: candidateId,
      request: { status: input.status },
    });
    if (blocked) return blocked;

    return c.json(
      await setKnowledgeCandidateStatus(sql, candidateId, {
        ...input,
        actor: input.actor ?? authActor(c),
      })
    );
  }
);

app.post(
  "/api/candidates/:id/promote",
  zValidator("param", z.object({ id: uuidSchema })),
  zValidator("json", promoteCandidateSchema),
  async (c) => {
    const sql = sqlFor(c.get("instance"));
    const candidateId = c.req.valid("param").id;
    const envelope = await fetchCandidateAccessEnvelope(sql, candidateId);
    const input = c.req.valid("json");
    const blocked = await enforceCapability(c, {
      action: "candidate_promote",
      capability: "rye.authoritative.promote",
      domainKeys: envelope.domain_keys,
      scopeRef: envelope.source_scope,
      targetRef: candidateId,
      request: { target_type: input.target_type },
    });
    if (blocked) return blocked;

    return c.json(
      await promoteKnowledgeCandidate(sql, candidateId, {
        ...input,
        actor: input.actor ?? authActor(c),
      })
    );
  }
);

app.post(
  "/api/candidates/:id/accept-source-policy",
  zValidator("param", z.object({ id: uuidSchema })),
  zValidator("json", acceptSourcePolicyCandidateSchema),
  async (c) => {
    const sql = sqlFor(c.get("instance"));
    const candidateId = c.req.valid("param").id;
    const envelope = await fetchCandidateAccessEnvelope(sql, candidateId);
    const input = c.req.valid("json");
    const blocked = await enforceCapability(c, {
      action: "source_policy_accept",
      capability: "rye.authoritative.promote",
      domainKeys: envelope.domain_keys,
      scopeRef: envelope.source_scope,
      targetRef: candidateId,
      request: { target_type: "source_policy" },
    });
    if (blocked) return blocked;

    return c.json(
      await acceptSourcePolicyCandidate(sql, candidateId, {
        ...input,
        actor: input.actor ?? authActor(c),
      })
    );
  }
);

app.post(
  "/api/candidates/:id/accept-crm-stage-plan",
  zValidator("param", z.object({ id: uuidSchema })),
  zValidator("json", acceptCrmStagePlanCandidateSchema),
  async (c) => {
    const sql = sqlFor(c.get("instance"));
    const candidateId = c.req.valid("param").id;
    const envelope = await fetchCandidateAccessEnvelope(sql, candidateId);
    const input = c.req.valid("json");
    const blocked = await enforceCapability(c, {
      action: "crm_stage_plan_accept",
      capability: "rye.authoritative.promote",
      domainKeys: envelope.domain_keys,
      scopeRef: envelope.source_scope,
      targetRef: candidateId,
      request: { target_type: "crm_stage_plan" },
    });
    if (blocked) return blocked;

    return c.json(
      await acceptCrmStagePlanCandidate(sql, candidateId, {
        ...input,
        actor: input.actor ?? authActor(c),
      })
    );
  }
);

app.post(
  "/api/candidates/:id/accept-pm-task-plan",
  zValidator("param", z.object({ id: uuidSchema })),
  zValidator("json", acceptPmTaskPlanCandidateSchema),
  async (c) => {
    const sql = sqlFor(c.get("instance"));
    const candidateId = c.req.valid("param").id;
    const envelope = await fetchCandidateAccessEnvelope(sql, candidateId);
    const input = c.req.valid("json");
    const blocked = await enforceCapability(c, {
      action: "pm_task_plan_accept",
      capability: "rye.authoritative.promote",
      domainKeys: envelope.domain_keys,
      scopeRef: envelope.source_scope,
      targetRef: candidateId,
      request: { target_type: "pm_task_plan" },
    });
    if (blocked) return blocked;

    return c.json(
      await acceptPmTaskPlanCandidate(sql, candidateId, {
        ...input,
        actor: input.actor ?? authActor(c),
      })
    );
  }
);

app.post(
  "/api/candidates/:id/accept-pm-milestone-plan",
  zValidator("param", z.object({ id: uuidSchema })),
  zValidator("json", acceptPmMilestonePlanCandidateSchema),
  async (c) => {
    const sql = sqlFor(c.get("instance"));
    const candidateId = c.req.valid("param").id;
    const envelope = await fetchCandidateAccessEnvelope(sql, candidateId);
    const input = c.req.valid("json");
    const blocked = await enforceCapability(c, {
      action: "pm_milestone_plan_accept",
      capability: "rye.authoritative.promote",
      domainKeys: envelope.domain_keys,
      scopeRef: envelope.source_scope,
      targetRef: candidateId,
      request: { target_type: "pm_milestone_plan" },
    });
    if (blocked) return blocked;

    return c.json(
      await acceptPmMilestonePlanCandidate(sql, candidateId, {
        ...input,
        actor: input.actor ?? authActor(c),
      })
    );
  }
);

app.get("/api/disputes", async (c) => {
  const sql = sqlFor(c.get("instance"));
  return c.json(await fetchActiveDisputes(sql));
});

app.get("/api/events", async (c) => {
  const sql = sqlFor(c.get("instance"));
  const limit = Math.min(Number(c.req.query("limit") ?? "100"), 500);
  return c.json(await fetchRecentEvents(sql, limit));
});

app.get("/api/health", (c) => c.json({ ok: true, at: new Date().toISOString() }));

app.all("/api/*", (c) => c.json({ error: "not found" }, 404));

// SPA fallback: hand any unmatched request to the static asset binding.
app.all("*", (c) => c.env.ASSETS.fetch(c.req.raw));

export default app;
