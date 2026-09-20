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
 * second postgres.js client, or a tagged-template query issued directly on
 * the raw client — skips that ordering guarantee and can read across
 * instances or return rows RLS should have hidden.
 *
 * `db.ts` exports `sqlFor(instance)`, which returns the raw postgres.js
 * client. That export cannot be removed: every call site needs the client
 * itself so it can hand it to `ryeQuery(sql, ...)`. So the two things this
 * check can still enforce outside db.ts are (a) nothing else in admin/src
 * ever reaches the `postgres` package by any route, and (b) the client
 * `sqlFor()` returns is never renamed to a different identifier — every
 * call site in this codebase binds it as `const sql = sqlFor(...)` and
 * passes that same `sql` straight into `ryeQuery()`. Assigning it (or a
 * bare reference to an existing `sql`) to any other name is exactly the
 * shape of "hold the client somewhere `sql\`...\`` won't be searched for",
 * so it is flagged at the point of assignment rather than at the point of
 * use.
 *
 * This is a plain text scan, not a parser: comments are blanked out (same
 * length, so line numbers stay correct) before matching, so a comment that
 * merely mentions one of these tokens does not fail the check. A string
 * literal that happens to contain one of these tokens would still trip it;
 * none does today.
 *
 * Out of scope: this cannot and does not try to stop deliberate
 * obfuscation of a call already reachable from a variable holding the raw
 * client — `c.unsafe.call(c, ...)`, `c["un" + "safe"](...)`, computed
 * member access, `eval`, or anything else built to defeat a text search.
 * Closing that requires a real linter with type information (e.g. an
 * eslint rule with type-aware "no calling methods on the postgres.js Sql
 * type outside db.ts"), not a grep-shaped script. This check closes the
 * shapes an honest change is likely to produce by accident, not an
 * adversarial one.
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
  // Optional extra filter over the match (e.g. to read a captured group and
  // decide whether this particular hit is worth flagging).
  accept?: (m: RegExpExecArray) => boolean;
}

// A module specifier that names the `postgres` package itself or a subpath
// of it (e.g. "postgres/cjs/src/index.js"), not some unrelated package that
// merely starts with those letters.
const POSTGRES_SPEC = String.raw`postgres(?:\/[^"'\`]*)?`;

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
    name: "postgres-static-import",
    // A runtime (non type-only) import from "postgres" or any "postgres/..."
    // subpath. `import type postgres from "postgres"` (used for the Sql
    // type) is fine and is not matched here.
    re: new RegExp(String.raw`import\s+(?!type\b)[^;]*\bfrom\s+["']${POSTGRES_SPEC}["']`, "g"),
    message: "a static import of the postgres package outside db.ts bypasses ryeQuery()",
  },
  {
    name: "postgres-require",
    re: new RegExp(String.raw`require\s*\(\s*["']${POSTGRES_SPEC}["']\s*\)`, "g"),
    message: "require(\"postgres\") outside db.ts bypasses ryeQuery()",
  },
  {
    name: "postgres-dynamic-import",
    re: new RegExp(String.raw`\bimport\s*\(\s*["']${POSTGRES_SPEC}["']\s*\)`, "g"),
    message: "dynamic import(\"postgres\") outside db.ts bypasses ryeQuery()",
  },
  {
    name: "tagged-sql-template",
    // Any tagged-template call on an identifier literally named `sql`,
    // whatever module it came from.
    re: /\bsql\s*`/g,
    message: "tagged-template sql`...` query bypasses ryeQuery()",
  },
  {
    name: "raw-client-aliased",
    // `const <name> = sqlFor(...)` or `const <name> = sql` where <name> is
    // anything other than `sql`. Every legitimate call site names the raw
    // client `sql`; a different name is how you'd dodge a `sql\`` search
    // while still holding the same tagged-template-callable client.
    re: /\b(?:const|let|var)\s+(\w+)\s*=\s*(?:sqlFor\s*\(|sql\b(?!\s*[.(\w]))/g,
    message: "raw postgres.js client aliased to a name other than `sql`; ryeQuery() call sites all use `sql`",
    accept: (m) => m[1] !== "sql",
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
      if (pattern.accept && !pattern.accept(match)) continue;
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
