#!/usr/bin/env bash
# Prepares a fresh git worktree for ./scripts/test-all.sh by making sure
# admin/node_modules, site/node_modules, and
# skills/rye-source-context-intake/node_modules exist and match their
# package-lock.json.
#
# For each directory, in order:
#   1. If node_modules is already present and stamped with the current
#      lock file's hash, do nothing (idempotent no-op).
#   2. Else, if the main checkout (parent of `git rev-parse --git-common-dir`)
#      has a node_modules for a package-lock.json with the same hash, copy
#      it — hard-linked (cp -al) when the worktree and the main checkout
#      share a filesystem, otherwise a full copy (cp -a). Never symlinked:
#      some of these tools (sharp, astro, tsx) resolve real paths, and a
#      symlinked node_modules can break native-binary and postinstall
#      lookups in ways a copy does not.
#   3. Else, fall back to `npm ci` in that directory and say so plainly —
#      this is the path that can end up building sharp from source in
#      admin/, which is slow and sometimes fails outright.
#
# Never writes into the main checkout: it only ever reads there.
# Never uses /tmp.
set -euo pipefail
trap 'echo "bootstrap-worktree.sh: FAILED at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DIRS=(admin site skills/rye-source-context-intake)

# Resolve the main checkout without a pipeline a downstream command could
# close early: `git worktree list --porcelain | awk '...{exit}'` sends
# git SIGPIPE the moment awk exits after its first match, which — under
# `pipefail` — makes the whole pipeline's exit status 141 and aborts the
# script before anything runs. It is timing dependent (git has to still be
# writing when awk exits), so it does not fail every run. `--git-common-dir`
# is a single command with no pipe: it always points at the main worktree's
# .git directory, whichever worktree you run it from.
MAIN_GIT_COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
MAIN_CHECKOUT="$(dirname "$MAIN_GIT_COMMON_DIR")"
if [[ -z "$MAIN_CHECKOUT" || ! -d "$MAIN_CHECKOUT" ]]; then
  echo "bootstrap-worktree.sh: could not determine main checkout from 'git rev-parse --git-common-dir'" >&2
  exit 1
fi

FAILED=()

same_filesystem() {
  # True if the two paths live on the same device (hard links possible).
  local dev_a dev_b
  dev_a="$(stat -c %d "$1" 2>/dev/null || true)"
  dev_b="$(stat -c %d "$2" 2>/dev/null || true)"
  [[ -n "$dev_a" && "$dev_a" == "$dev_b" ]]
}

for dir in "${DIRS[@]}"; do
  LOCK="$REPO_ROOT/$dir/package-lock.json"
  NM="$REPO_ROOT/$dir/node_modules"
  STAMP="$NM/.bootstrap-worktree-lock-hash"

  if [[ ! -f "$LOCK" ]]; then
    echo "== $dir: no package-lock.json found, skipping =="
    continue
  fi

  HASH="$(sha256sum "$LOCK" | awk '{print $1}')"

  if [[ -d "$NM" && -f "$STAMP" ]] && [[ "$(cat "$STAMP")" == "$HASH" ]]; then
    echo "== $dir: node_modules already matches package-lock.json, nothing to do =="
    continue
  fi

  MAIN_LOCK="$MAIN_CHECKOUT/$dir/package-lock.json"
  MAIN_NM="$MAIN_CHECKOUT/$dir/node_modules"
  COPIED=0

  if [[ "$REPO_ROOT" != "$MAIN_CHECKOUT" && -d "$MAIN_NM" && -f "$MAIN_LOCK" ]]; then
    MAIN_HASH="$(sha256sum "$MAIN_LOCK" | awk '{print $1}')"
    if [[ "$MAIN_HASH" == "$HASH" ]]; then
      rm -rf "$NM"
      if same_filesystem "$REPO_ROOT/$dir" "$MAIN_CHECKOUT/$dir"; then
        cp -al "$MAIN_NM" "$NM"
        echo "== $dir: hard-linked node_modules from main checkout ($MAIN_CHECKOUT), same lock hash =="
      else
        cp -a "$MAIN_NM" "$NM"
        echo "== $dir: copied node_modules from main checkout ($MAIN_CHECKOUT), same lock hash =="
      fi
      echo "$HASH" > "$STAMP"
      COPIED=1
    fi
  fi

  if [[ "$COPIED" -eq 0 ]]; then
    echo "== $dir: no usable node_modules to copy (main checkout missing one, or its lock hash differs); running npm ci =="
    if npm ci --prefix "$REPO_ROOT/$dir"; then
      echo "$HASH" > "$STAMP"
      echo "== $dir: npm ci succeeded =="
    else
      echo "== $dir: npm ci FAILED. This is the path that tries to build native deps (e.g. sharp in admin/) from source." >&2
      echo "== $dir: fix is usually to get a usable node_modules onto the main checkout ($MAIN_CHECKOUT/$dir) first, then re-run this script. ==" >&2
      FAILED+=("$dir")
    fi
  fi
done

echo
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "bootstrap-worktree.sh: FAILED: ${FAILED[*]}"
  exit 1
fi

echo "bootstrap-worktree.sh: all directories ready."
