import postgres from "postgres";

export interface InstanceConfig {
  id: string;
  label: string;
  databaseUrl: string;
  /** Optional human-readable description shown in the picker. */
  blurb?: string;
}

export interface Env {
  DEFAULT_INSTANCE: string;
  RYE_INSTANCES?: string;
  RYE_API_AUTH_MODE?: string;
  RYE_API_ALLOWED_ORIGINS?: string;
  ASSETS: Fetcher;
}

export function loadInstances(env: Env): InstanceConfig[] {
  if (!env.RYE_INSTANCES) {
    return [];
  }
  try {
    const parsed = JSON.parse(env.RYE_INSTANCES);
    if (!Array.isArray(parsed)) throw new Error("RYE_INSTANCES must be an array");
    return parsed as InstanceConfig[];
  } catch (e) {
    throw new Error(`RYE_INSTANCES is not valid JSON: ${(e as Error).message}`);
  }
}

export function pickInstance(env: Env, requested: string | null): InstanceConfig {
  const all = loadInstances(env);
  if (all.length === 0) throw new Error("No Rye instances configured");
  const id = requested || env.DEFAULT_INSTANCE || all[0]?.id;
  const match = all.find((i) => i.id === id);
  if (!match) throw new Error(`Unknown Rye instance: ${id}`);
  return match;
}

// A thin per-request SQL client. postgres.js handles pooling internally.
const clients = new Map<string, ReturnType<typeof postgres>>();

export function sqlFor(instance: InstanceConfig) {
  let client = clients.get(instance.id);
  if (!client) {
    // A local Docker Postgres speaks plaintext; Supabase requires TLS but
    // workerd/Node may not trust its CA. So: disable TLS for localhost or any
    // sslmode=disable URL, otherwise connect with relaxed verification.
    // Production should front Postgres with Cloudflare Hyperdrive.
    const url = new URL(instance.databaseUrl);
    const isLocal =
      url.hostname === "localhost" ||
      url.hostname === "127.0.0.1" ||
      url.searchParams.get("sslmode") === "disable";
    client = postgres(instance.databaseUrl, {
      ssl: isLocal ? false : { rejectUnauthorized: false },
      max: 4,
      idle_timeout: 20,
      connect_timeout: 10,
      prepare: false, // PgBouncer/Supabase pooler compatibility
    });
    clients.set(instance.id, client);
  }
  return client;
}

/**
 * Wraps a query so the rye RLS `app.current_role` session var is set within
 * the same statement. The Composio recon showed multi-statement set_config
 * is rejected and a bare SELECT under RLS returns no rows.
 *
 * Usage: ryeQuery(sql, sql`SELECT n.id FROM rye.nodes n, cfg LIMIT 5`)
 * The query MUST join `, cfg` once so the CTE is referenced.
 */
export function withAdminCte(role: "admin" | "reader" = "admin") {
  return `WITH cfg AS (SELECT set_config('app.current_role','${role}',false)) `;
}
