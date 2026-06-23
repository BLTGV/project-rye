/**
 * Node dev runner. The Worker entry (`worker.ts`) is the same Hono app that
 * ships to Cloudflare; here we just mount it under @hono/node-server so
 * connecting to Supabase via TLS uses Node's CA bundle (workerd's bundle does
 * not include the chain Supabase's Postgres endpoint uses).
 *
 * Production deployment still goes through `wrangler deploy` with Hyperdrive
 * in front of Postgres — Hyperdrive handles the TLS chain there.
 */
import "dotenv/config";
import { readFile, stat } from "node:fs/promises";
import { join, normalize } from "node:path";
import { serve } from "@hono/node-server";
import app from "./worker";
import type { Env } from "./db";

// Load .dev.vars (KEY=VALUE lines) on top of process.env so the Hono app's
// `c.env` mirrors what wrangler dev would provide.
async function loadDevVars() {
  try {
    const text = await readFile(new URL("../../.dev.vars", import.meta.url), "utf8");
    for (const line of text.split(/\r?\n/)) {
      const m = line.match(/^([A-Z0-9_]+)\s*=\s*(.*)$/);
      if (!m) continue;
      const [, k, raw] = m;
      let v = raw.trim();
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
        v = v.slice(1, -1);
      }
      process.env[k] = v;
    }
  } catch {
    /* no .dev.vars, fine */
  }
}

const ASSETS_DIR = new URL("../../dist/client/", import.meta.url);

const CONTENT_TYPES: Record<string, string> = {
  html: "text/html; charset=utf-8",
  js: "application/javascript",
  mjs: "application/javascript",
  css: "text/css",
  svg: "image/svg+xml",
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  ico: "image/x-icon",
  json: "application/json",
  woff: "font-woff",
  woff2: "font-woff2",
};

function contentType(path: string) {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  return CONTENT_TYPES[ext] ?? "application/octet-stream";
}

const assets: Env["ASSETS"] = {
  async fetch(input: RequestInfo | URL): Promise<Response> {
    const req = input instanceof Request ? input : new Request(input);
    const url = new URL(req.url);
    const safe = normalize(url.pathname).replace(/^\/+/, "");
    const candidates =
      safe === "" || safe.endsWith("/")
        ? [safe + "index.html"]
        : [safe, safe + "/index.html", "index.html"];
    for (const cand of candidates) {
      const full = join(ASSETS_DIR.pathname, cand);
      try {
        const s = await stat(full);
        if (!s.isFile()) continue;
        const body = await readFile(full);
        return new Response(body, {
          status: 200,
          headers: { "content-type": contentType(cand) },
        });
      } catch {
        /* keep trying */
      }
    }
    return new Response("Not found", { status: 404 });
  },
} as unknown as Env["ASSETS"];

await loadDevVars();
const env: Env = {
  DEFAULT_INSTANCE: process.env.DEFAULT_INSTANCE ?? "",
  RYE_INSTANCES: process.env.RYE_INSTANCES,
  ASSETS: assets,
};

const port = Number(process.env.RYE_ADMIN_API_PORT ?? process.env.PORT ?? 8799);
const hostname = process.env.HOST ?? "0.0.0.0";
const advertisedHosts = (process.env.RYE_ADMIN_PUBLIC_HOSTS ?? "127.0.0.1")
  .split(",")
  .map((host) => host.trim())
  .filter(Boolean);

serve(
  {
    fetch: (req) => app.fetch(req, env),
    port,
    hostname,
  },
  (info) => {
    console.log(`Rye admin (node dev) listening on http://${info.address}:${info.port}`);
    for (const host of advertisedHosts) {
      console.log(`  • http://${host}:${info.port}`);
    }
  }
);
