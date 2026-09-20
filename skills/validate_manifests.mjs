#!/usr/bin/env node
// Every skill and plugin manifest validates against the schema beside it.
// contracts/plugin-manifest.md calls those two schema files normative and a
// manifest that fails one a build failure, so this is the check that makes the
// sentence true. Nothing else in the repository validated them.
//
// ajv comes from skills/rye-source-context-intake/node_modules, which is the
// one place in skills/ with dependencies; that is why this runs from that
// package's `check` script rather than standing alone.
//
//   node skills/validate_manifests.mjs [repo-root]
//
// Prints one line per manifest and exits non-zero on the first invalid one.

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const skillsDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(process.argv[2] ?? path.join(skillsDir, ".."));

const require = createRequire(
  path.join(repoRoot, "skills", "rye-source-context-intake", "package.json"),
);

let Ajv2020;
let addFormats;
try {
  const ajvModule = require("ajv/dist/2020.js");
  Ajv2020 = ajvModule.default ?? ajvModule;
  addFormats = require("ajv-formats");
} catch {
  console.error(
    "validate_manifests: ajv is not installed. Run `npm ci --prefix skills/rye-source-context-intake`,\n" +
      "or ./scripts/bootstrap-worktree.sh in a worktree.",
  );
  process.exit(2);
}

const kinds = [
  {
    dir: "skills",
    manifest: "rye-skill.json",
    schema: path.join(repoRoot, "skills", "rye-skill.schema.json"),
  },
  {
    dir: "plugins",
    manifest: "rye-plugin.json",
    schema: path.join(repoRoot, "plugins", "rye-plugin.schema.json"),
  },
];

let checked = 0;
let failures = 0;

for (const kind of kinds) {
  const schema = JSON.parse(fs.readFileSync(kind.schema, "utf8"));
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  const root = path.join(repoRoot, kind.dir);
  const entries = fs
    .readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort();

  for (const name of entries) {
    const file = path.join(root, name, kind.manifest);
    if (!fs.existsSync(file)) {
      continue;
    }
    checked += 1;

    let data;
    try {
      data = JSON.parse(fs.readFileSync(file, "utf8"));
    } catch (error) {
      failures += 1;
      console.log(`FAIL ${kind.dir}/${name}/${kind.manifest}`);
      console.log(`     not JSON: ${error instanceof Error ? error.message : String(error)}`);
      continue;
    }

    // Validated as written, $schema included: the schema decides what is
    // allowed, and stripping a key here would hide exactly what it forbids.
    if (validate(data)) {
      console.log(`ok   ${kind.dir}/${name}/${kind.manifest}`);
    } else {
      failures += 1;
      console.log(`FAIL ${kind.dir}/${name}/${kind.manifest}`);
      for (const error of validate.errors ?? []) {
        console.log(`     ${error.instancePath || "/"} ${error.message}`);
      }
    }
  }
}

if (checked === 0) {
  console.error(`validate_manifests: no manifests found under ${repoRoot}`);
  process.exit(2);
}

if (failures > 0) {
  console.error(`${failures} of ${checked} manifests are invalid`);
  process.exit(1);
}

console.log(`${checked} manifests valid`);
