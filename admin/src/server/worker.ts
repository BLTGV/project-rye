import { Hono } from "hono";
import { cors } from "hono/cors";
import { z } from "zod";
import { zValidator } from "@hono/zod-validator";
import { type Env, loadInstances, pickInstance, sqlFor } from "./db";
import {
  createKnowledgeCandidate,
  fetchActiveDisputes,
  fetchActivityTimeline,
  fetchAssertionComposition,
  fetchCatalog,
  fetchCountyRollup,
  fetchDashboardKpis,
  fetchExtractionTimeline,
  fetchKnowledgeKpis,
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
} from "./queries";

const app = new Hono<{ Bindings: Env; Variables: { instance: ReturnType<typeof pickInstance> } }>();

app.use("*", cors());

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

const createCandidateSchema = z.object({
  candidate_kind: candidateKindSchema,
  statement: z.string().trim().min(1),
  target_payload: jsonRecordSchema.optional(),
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

function boolQuery(value: string | undefined): boolean {
  return value === "1" || value === "true" || value === "yes" || value === "on";
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

app.get("/api/instances", (c) => {
  const all = loadInstances(c.env);
  return c.json({
    default: c.env.DEFAULT_INSTANCE,
    instances: all.map((i) => ({ id: i.id, label: i.label, blurb: i.blurb })),
  });
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
  const result = await createKnowledgeCandidate(sql, c.req.valid("json"));
  return c.json(result, 201);
});

app.post(
  "/api/candidates/:id/status",
  zValidator("param", z.object({ id: uuidSchema })),
  zValidator("json", setCandidateStatusSchema),
  async (c) => {
    const sql = sqlFor(c.get("instance"));
    return c.json(await setKnowledgeCandidateStatus(sql, c.req.valid("param").id, c.req.valid("json")));
  }
);

app.post(
  "/api/candidates/:id/promote",
  zValidator("param", z.object({ id: uuidSchema })),
  zValidator("json", promoteCandidateSchema),
  async (c) => {
    const sql = sqlFor(c.get("instance"));
    return c.json(await promoteKnowledgeCandidate(sql, c.req.valid("param").id, c.req.valid("json")));
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
