#!/usr/bin/env bash
# worktree-extend.sh — isolate same-target rust-extend branches so a /build
# tick can advance several PRDs that share one `build_into` repo in parallel
# without racing the git index or cargo `target/`.
#
# Model: the EXPENSIVE work (cargo build/clippy/test/deny) runs in parallel,
# each branch in its own git worktree off the target's `main` HEAD. The CHEAP
# work (merge back + version bump + changelog) is SERIAL, guarded by a
# per-repo integration flock, so sequential branches get clean incrementing
# versions and a linear history.
#
# Subcommands:
#   add <repo> <slug>
#       Create (or reuse) an isolated worktree of <repo> on branch
#       autobuilder/<slug>, based on <repo>'s current `main` HEAD. The branch
#       agent then cwd's into the printed path, edits src/tests, runs the
#       gate, and commits its IMPLEMENTATION there (no version bump — that
#       happens at integration). Prints the worktree path on stdout.
#
#   integrate <repo> <slug> <bump> <tldr-file>
#       SERIAL. Takes the per-repo integration lock. Refuses if <repo>'s main
#       working tree is dirty (exit 3) — never merges into a dirty tree.
#       Merges autobuilder/<slug> into main (--no-ff), then bumps the version
#       (<bump>) and prepends the CHANGELOG from <tldr-file> via
#       extend-handler.sh, committing the bump with the Joe Yen identity.
#       Exit 4 on merge conflict (merge aborted; branch left for next tick).
#
#   cleanup <repo> <slug>
#       Remove the worktree dir. Keeps the branch unless --drop-branch given
#       (branch is kept when integration was deferred, so work resumes).
#
#   list <repo>
#       Show this repo's autobuilder worktrees.
#
# All paths absolute. Identity for the bump commit is Joe Yen (wintermute repo
# convention). Worktrees live under $WT_ROOT (default ~/.cache/build-worktrees).
set -uo pipefail

WT_ROOT="${BUILD_WT_ROOT:-$HOME/.cache/build-worktrees}"
EXTEND="$(dirname "$0")/extend-handler.sh"
GIT_ID=(-c user.email=jyen.tech@gmail.com -c user.name="Joe Yen")

die() { echo "worktree-extend: $2" >&2; exit "$1"; }
need() { [ -n "${1:-}" ] || die 1 "$2"; }

wt_path() { echo "$WT_ROOT/$(basename "$1")-$2"; }

cmd_add() {
  local repo="${1:-}" slug="${2:-}"; need "$repo" "usage: add <repo> <slug>"; need "$slug" "missing slug"
  [ -d "$repo/.git" ] || git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die 2 "not a git repo: $repo"
  local wt branch base; wt="$(wt_path "$repo" "$slug")"; branch="autobuilder/$slug"
  mkdir -p "$WT_ROOT"
  # Resume if the worktree already exists (multi-tick build).
  if git -C "$repo" worktree list --porcelain | grep -qxF "worktree $wt"; then
    echo "$wt"; return 0
  fi
  # Base the branch on main's HEAD (clean commit), ignoring any dirty files in
  # the main working tree.
  base="$(git -C "$repo" rev-parse main 2>/dev/null || git -C "$repo" rev-parse HEAD)"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo" worktree add "$wt" "$branch" >&2 || die 2 "worktree add (existing branch) failed"
  else
    git -C "$repo" worktree add -b "$branch" "$wt" "$base" >&2 || die 2 "worktree add (new branch) failed"
  fi
  echo "$wt"
}

cmd_integrate() {
  local repo="${1:-}" slug="${2:-}" bump="${3:-minor}" tldr="${4:-}"
  need "$repo" "usage: integrate <repo> <slug> <bump> <tldr-file>"; need "$slug" "missing slug"
  local branch="autobuilder/$slug"
  exec 9>"$repo/.git/autobuilder-integrate.lock"
  flock -w 120 9 || die 5 "could not acquire integration lock for $repo"

  # Never merge into a dirty tree.
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    die 3 "target tree dirty; refusing to integrate $slug (commit-or-revert the working tree first)"
  fi
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" || die 2 "no branch $branch to integrate"
  git -C "$repo" checkout main >&2 2>/dev/null || git -C "$repo" checkout -q main
  if ! git -C "$repo" "${GIT_ID[@]}" merge --no-ff --no-edit "$branch" >&2; then
    git -C "$repo" merge --abort 2>/dev/null
    die 4 "merge conflict integrating $slug; aborted (branch kept for next tick)"
  fi
  # Serial version bump + changelog so stacked branches increment cleanly.
  "$EXTEND" bump-version "$repo" "$bump" >&2 || die 6 "bump-version failed"
  local newver; newver="$("$EXTEND" current-version "$repo")"
  if [ -n "$tldr" ] && [ -f "$tldr" ]; then
    "$EXTEND" changelog-prepend "$repo" "$newver" "$tldr" >&2 || die 6 "changelog-prepend failed"
  fi
  git -C "$repo" add -A >&2
  git -C "$repo" "${GIT_ID[@]}" commit -q -m "$(basename "$repo"): v$newver — $slug (parallel integrate)" >&2 \
    || die 6 "version-bump commit failed"
  echo "$newver"
}

cmd_cleanup() {
  local repo="${1:-}" slug="${2:-}" drop=""; need "$repo" "usage: cleanup <repo> <slug> [--drop-branch]"; need "$slug" "missing slug"
  [ "${3:-}" = "--drop-branch" ] && drop=1
  local wt branch; wt="$(wt_path "$repo" "$slug")"; branch="autobuilder/$slug"
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null
  git -C "$repo" worktree prune 2>/dev/null
  [ -n "$drop" ] && git -C "$repo" branch -D "$branch" 2>/dev/null
  echo "cleaned $wt${drop:+ (+branch)}"
}

cmd_list() { local repo="${1:-}"; need "$repo" "usage: list <repo>"; git -C "$repo" worktree list | grep -F "$WT_ROOT/$(basename "$repo")-" || echo "(no autobuilder worktrees)"; }

case "${1:-}" in
  add)       shift; cmd_add "$@" ;;
  integrate) shift; cmd_integrate "$@" ;;
  cleanup)   shift; cmd_cleanup "$@" ;;
  list)      shift; cmd_list "$@" ;;
  *) echo "usage: worktree-extend.sh {add|integrate|cleanup|list} ..." >&2; exit 1 ;;
esac
