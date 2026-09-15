#!/usr/bin/env bash
# install-repo-hooks.sh — point a build_into repo's core.hooksPath at the
# shared scripts/repo-hooks/ directory (PRD-build-main-push-gate
# requirement 4).
#
# One directory, not a per-repo copy: every build_into repo's
# core.hooksPath resolves to the SAME absolute path,
# ~/.claude/skills/build/scripts/repo-hooks — which is itself the
# ~/.claude/skills/build symlink onto this repo's own checkout (see
# SKILL.md's "Self-mod distribution" section), so a hook fix here reaches
# every installed repo the next time that repo's hook fires, with no
# reinstall step. worktree-extend.sh's `add` calls this once per
# <build_into> repo, the first time it sees core.hooksPath unset there.
#
# Usage: install-repo-hooks.sh <repo>
#
# Idempotent: a repo whose core.hooksPath already equals the target path
# is left untouched and this exits 0 without printing anything new.
# Refuses (exit 3) to overwrite a DIFFERENT existing core.hooksPath rather
# than silently stomping some other hook wiring — pass --force to override.
#
# Exit: 0 ok (installed or already installed) | 2 usage | 3 refused
#       (different hooksPath already set, no --force) | 4 repo not found
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: install-repo-hooks.sh <repo> [--force]" >&2; }

repo=""
force=false
for arg in "$@"; do
  case "$arg" in
    --force) force=true ;;
    -h|--help) usage; exit 0 ;;
    *) repo="$arg" ;;
  esac
done
[ -n "$repo" ] || { usage; exit 2; }
[ -d "$repo/.git" ] || { echo "install-repo-hooks: not a git repo: $repo" >&2; exit 4; }

target_hooks_dir="$HOME/.claude/skills/build/scripts/repo-hooks"
[ -d "$target_hooks_dir" ] || target_hooks_dir="$HERE/repo-hooks"

current="$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)"

if [ "$current" = "$target_hooks_dir" ]; then
  echo "install-repo-hooks: already installed for $repo"
  exit 0
fi

if [ -n "$current" ] && [ "$current" != "$target_hooks_dir" ] && ! $force; then
  echo "install-repo-hooks: refusing to overwrite existing core.hooksPath ($current) for $repo — pass --force" >&2
  exit 3
fi

git -C "$repo" config core.hooksPath "$target_hooks_dir"
echo "install-repo-hooks: $repo core.hooksPath -> $target_hooks_dir"
