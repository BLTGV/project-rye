/**
 * Static check that every database call in the admin Worker goes through
 * `ryeQuery()` in `admin/src/server/db.ts`. Needs no database.
 *
 *   cd admin && npm run check:db
 *
 * `ryeQuery()` (see db.ts) sets `app.current_role` as its own first
 * statement inside a transaction, before any RLS-filtered scan. Anything
 * that reaches Postgres another way — a raw `sql.unsafe(...)` call, a
 * hand-written `set_config(...)`, the retired `withAdminCte()` shape, a
 * second postgres.js client constructed outside `db.ts`, or a tagged
 * template `sql\`...\`` query — skips that ordering guarantee and can read
 * across instances or return rows RLS should have hidden.
 *
 * This is a plain text scan, not a parser: comments are blanked out (same
 * length, so line numbers stay correct) before matching, so a comment that
 * merely mentions one of these tokens does not fail the check. A string
 * literal that happens to contain one of these tokens would still trip it;
 * none does today.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const SRC_ROOT = join(import.meta.dirname, "..", "src");
// The one file allowed to talk to postgres directly.
const EXEMPT = join(SRC_ROOT, "server", "db.ts");

function listSourceFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      out.push(...listSourceFiles(full));
    } else if (/\.tsx?$/.test(entry)) {
      out.push(full);
    }
  }
  return out;
}

// Blank out comment bodies with spaces, preserving length and line breaks,
// so byte offsets (and therefore line numbers) still match the original.
function blankComments(src: string): string {
  let out = src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
  out = out.replace(/(^|[^:])\/\/[^\n]*/gm, (m, pre: string) => pre + " ".repeat(m.length - pre.length));
  return out;
}

function lineAt(text: string, index: number): number {
  return text.slice(0, index).split("\n").length;
}

interface Pattern {
  name: string;
  re: RegExp;
  message: string;
}

const PATTERNS: Pattern[] = [
  {
    name: "sql.unsafe",
    re: /\.unsafe\s*\(/g,
    message: "raw .unsafe(...) call bypasses ryeQuery()",
  },
  {
    name: "set_config",
    re: /set_config\s*\(/g,
    message: "raw set_config(...) call bypasses ryeQuery()'s statement ordering",
  },
  {
    name: "withAdminCte",
    re: /\bwithAdminCte\b/g,
    message: "withAdminCte() was retired by work/004 (it leaked the role and could run after the RLS filter); use ryeQuery()",
  },
  {
    name: "postgres-client-import",
    // A runtime (non type-only) default or named import of the `postgres`
    // package. `import type postgres from "postgres"` (used for the Sql
    // type) is fine and is not matched here.
    re: /import\s+(?!type\b)[^;]*\bfrom\s+["']postgres["']/g,
    message: "a second postgres.js client outside db.ts bypasses ryeQuery()",
  },
  {
    name: "tagged-sql-template",
    re: /\bsql\s*`/g,
    message: "tagged-template sql`...` query bypasses ryeQuery()",
  },
];

let failures = 0;

for (const file of listSourceFiles(SRC_ROOT)) {
  if (file === EXEMPT) continue;
  const original = readFileSync(file, "utf8");
  const scanned = blankComments(original);
  const relPath = relative(join(import.meta.dirname, ".."), file);
  for (const pattern of PATTERNS) {
    pattern.re.lastIndex = 0;
    let match: RegExpExecArray | null;
    while ((match = pattern.re.exec(scanned))) {
      const line = lineAt(scanned, match.index);
      console.log(`FAIL ${relPath}:${line}: ${pattern.message} (${pattern.name})`);
      failures += 1;
    }
  }
}

console.log(
  failures === 0
    ? "db-usage check passed: no raw database access outside admin/src/server/db.ts"
    : `${failures} failure(s)`
);
process.exit(failures === 0 ? 0 : 1);
