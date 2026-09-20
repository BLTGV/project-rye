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

export type RyeSessionRole = "admin" | "reader";

type Sql = ReturnType<typeof postgres>;
type UnsafeParams = Parameters<Sql["unsafe"]>[1];

/**
 * The `cfg` relation every rye query still joins. It sets nothing and returns
 * exactly one row, so `, cfg` and `FROM cfg` keep their meaning while the
 * planner is free to place it anywhere.
 *
 * It used to be `SELECT set_config('app.current_role','admin',false)`, on the
 * assumption that a CTE runs before the rest of the statement. It does not:
 * PostgreSQL may evaluate an RLS qual on a scanned table before the CTE is
 * executed (EXPLAIN ANALYZE shows `CTE cfg -> Result (never executed)` next to
 * `Rows Removed by Filter`), so every governance query returned zero rows once
 * RLS was forced and the table owner was not a superuser. A
 * `FROM (SELECT set_config(...)) cfg CROSS JOIN LATERAL (...)` shape has the
 * same hole — the subquery is pulled up and the join commuted. Only an
 * aggregate or LIMIT in between hides it, which is why some call sites
 * appeared to work.
 */
const CFG_CTE = "WITH cfg AS (SELECT 1 AS rye_cfg) ";
const CFG_CTE_RECURSIVE = "WITH RECURSIVE cfg AS (SELECT 1 AS rye_cfg) ";

/**
 * Runs one rye query with `app.current_role` reliably set before any
 * RLS-filtered scan.
 *
 * The role is set by its own statement, first, inside a transaction:
 *
 *   BEGIN; SELECT set_config('app.current_role', $1, true); <query>; COMMIT;
 *
 * Statement order is not a planner decision, so this holds no matter how the
 * query is planned. Three properties make it safe on a pooler:
 *
 * - it is not the multi-statement form the pooler rejects; each statement is
 *   sent on its own, in one transaction;
 * - a transaction pooler pins one server connection for the life of a
 *   transaction, so the setting is still there for the second statement;
 * - `is_local = true` makes the setting transaction-local, so COMMIT discards
 *   it and the admin role cannot ride a pooled connection into another
 *   tenant's session. The old `false` could.
 *
 * Pass `recursive: true` when the query's own CTE list needs `WITH RECURSIVE`.
 */
export async function ryeQuery<T extends any[] = (postgres.Row & Iterable<postgres.Row>)[]>(
  sql: Sql,
  text: string,
  params?: UnsafeParams,
  opts: { role?: RyeSessionRole; recursive?: boolean } = {}
): Promise<postgres.RowList<T>> {
  const role: RyeSessionRole = opts.role ?? "admin";
  const header = opts.recursive ? CFG_CTE_RECURSIVE : CFG_CTE;
  // Wrapped in an object: postgres.js Promise.all's an array returned from
  // begin(), which would strip RowList off the result.
  const out = await sql.begin(async (tx) => {
    await tx.unsafe("SELECT set_config('app.current_role', $1, true)", [role]);
    const rows = await tx.unsafe<T>(header + text, params);
    return { rows };
  });
  return out.rows;
}
