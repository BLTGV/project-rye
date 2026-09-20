#!/usr/bin/env bash
# Prepares a fresh git worktree for ./scripts/test-all.sh by making sure
# admin/node_modules, site/node_modules, and
# skills/rye-source-context-intake/node_modules exist and match their
# package-lock.json.
#
# Usage:
#   scripts/bootstrap-worktree.sh [--dry-run] [--copy]
#
#   --dry-run   print what would happen per directory; change nothing.
#   --copy      always use a full copy (cp -a), never a hard link, even
#               when the worktree and the main checkout share a filesystem.
#               Use this before running any tool that rewrites node_modules
#               files in place (npm rebuild, patch-package, etc.) — see the
#               hard-link warning below.
#
# In the MAIN checkout (the repo you cloned, not a `git worktree add`
# checkout): there is nothing to bootstrap from, so this script prints that
# and exits 0 without touching anything. It never runs `npm ci` there.
# Dependencies in the main checkout are installed by hand the normal way
# (`npm ci` in admin/, site/, skills/rye-source-context-intake/ directly).
#
# In a WORKTREE, for each of the three directories, in order:
#   1. If node_modules is already present and stamped with the current
#      lock file's hash, do nothing (idempotent no-op).
#   2. Else, if the main checkout has a node_modules for a package-lock.json
#      with the same hash, copy it — hard-linked (cp -al) when the worktree
#      and the main checkout share a filesystem (unless --copy forces a
#      full copy), otherwise cp -a. Never symlinked: some of these tools
#      (sharp, astro, tsx) resolve real paths, and a symlinked node_modules
#      can break native-binary and postinstall lookups in ways a copy does
#      not.
#
#      WARNING: a hard-linked copy shares inodes with the main checkout's
#      node_modules. Deleting or replacing a file (what a normal install
#      does) is safe — the link is simply dropped. But rewriting a file's
#      contents in place (npm rebuild, patch-package, editing a file under
#      node_modules) changes the main checkout's copy too. Use --copy in a
#      worktree before running anything like that.
#   3. Else, fall back to `npm ci` in that directory. Before doing so, any
#      existing node_modules is moved aside to a `.bak` sibling in the same
#      directory; if npm ci fails it is moved back, so a failed install
#      never leaves the directory empty. This is also the path that can end
#      up building sharp from source in admin/, which is slow and
#      sometimes fails outright.
#
# Never writes into the main checkout: it only ever reads there.
# Never uses /tmp.
set -euo pipefail
trap 'echo "bootstrap-worktree.sh: FAILED at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

DRY_RUN=0
COPY_MODE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --copy) COPY_MODE=1 ;;
    -h|--help)
      sed -n '2,48p' "$0"
      exit 0
      ;;
    *)
      echo "bootstrap-worktree.sh: unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

# Resolve the current checkout's toplevel and the main checkout without a
# pipeline a downstream command could close early: a prior version used
# `git worktree list --porcelain | awk '...{exit}'`, which sends git
# SIGPIPE the moment awk exits after its first match — under `pipefail`
# that makes the whole pipeline's exit status 141 and aborts the script
# before anything runs. It was timing dependent (git has to still be
# writing when awk exits), so it did not fail every run. `--show-toplevel`
# and `--git-common-dir` are each a single command with no pipe, and
# `--git-common-dir` always points at the main worktree's .git directory,
# whichever worktree (or the main checkout itself) you run it from.
TOPLEVEL="$(git rev-parse --path-format=absolute --show-toplevel)"
MAIN_GIT_COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
MAIN_CHECKOUT="$(dirname "$MAIN_GIT_COMMON_DIR")"
if [[ -z "$MAIN_CHECKOUT" || ! -d "$MAIN_CHECKOUT" ]]; then
  echo "bootstrap-worktree.sh: could not determine main checkout from 'git rev-parse --git-common-dir'" >&2
  exit 1
fi

if [[ "$TOPLEVEL" == "$MAIN_CHECKOUT" ]]; then
  echo "bootstrap-worktree.sh: this is the main checkout ($MAIN_CHECKOUT) — there is no other checkout to bootstrap from."
  echo "bootstrap-worktree.sh: dependencies here are installed by hand (npm ci in admin/, site/, skills/rye-source-context-intake/). Not running npm ci automatically. Exiting without touching anything."
  exit 0
fi

REPO_ROOT="$TOPLEVEL"
cd "$REPO_ROOT"

DIRS=(admin site skills/rye-source-context-intake)

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
  BAK="$NM.bak"

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
  USE_MAIN=0

  if [[ -d "$MAIN_NM" && -f "$MAIN_LOCK" ]]; then
    MAIN_HASH="$(sha256sum "$MAIN_LOCK" | awk '{print $1}')"
    [[ "$MAIN_HASH" == "$HASH" ]] && USE_MAIN=1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$USE_MAIN" -eq 1 ]]; then
      if [[ "$COPY_MODE" -eq 0 ]] && same_filesystem "$REPO_ROOT/$dir" "$MAIN_CHECKOUT/$dir"; then
        echo "[dry-run] $dir: would hard-link node_modules from main checkout ($MAIN_CHECKOUT)"
      else
        echo "[dry-run] $dir: would copy node_modules from main checkout ($MAIN_CHECKOUT)"
      fi
    else
      echo "[dry-run] $dir: would run npm ci (no usable node_modules to copy)"
    fi
    continue
  fi

  COPIED=0
  if [[ "$USE_MAIN" -eq 1 ]]; then
    rm -rf "$NM"
    if [[ "$COPY_MODE" -eq 0 ]] && same_filesystem "$REPO_ROOT/$dir" "$MAIN_CHECKOUT/$dir"; then
      cp -al "$MAIN_NM" "$NM"
      echo "== $dir: hard-linked node_modules from main checkout ($MAIN_CHECKOUT), same lock hash =="
    else
      cp -a "$MAIN_NM" "$NM"
      echo "== $dir: copied node_modules from main checkout ($MAIN_CHECKOUT), same lock hash =="
    fi
    echo "$HASH" > "$STAMP"
    COPIED=1
  fi

  if [[ "$COPIED" -eq 0 ]]; then
    echo "== $dir: no usable node_modules to copy (main checkout missing one, or its lock hash differs); running npm ci =="
    [[ -e "$BAK" ]] && rm -rf "$BAK"
    HAD_EXISTING=0
    if [[ -d "$NM" ]]; then
      mv "$NM" "$BAK"
      HAD_EXISTING=1
      echo "== $dir: moved existing node_modules aside to $(basename "$BAK") before npm ci =="
    fi
    if npm ci --prefix "$REPO_ROOT/$dir"; then
      echo "$HASH" > "$STAMP"
      echo "== $dir: npm ci succeeded =="
      [[ "$HAD_EXISTING" -eq 1 ]] && rm -rf "$BAK"
    else
      rm -rf "$NM"
      if [[ "$HAD_EXISTING" -eq 1 ]]; then
        mv "$BAK" "$NM"
        echo "== $dir: npm ci FAILED; restored the previous node_modules from $(basename "$BAK") so the directory is not left empty. ==" >&2
      else
        echo "== $dir: npm ci FAILED. There was no existing node_modules to restore." >&2
      fi
      echo "== $dir: this is the path that tries to build native deps (e.g. sharp in admin/) from source." >&2
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

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "bootstrap-worktree.sh: dry run complete; nothing was changed."
else
  echo "bootstrap-worktree.sh: all directories ready."
fi
