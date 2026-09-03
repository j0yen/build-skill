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
SIDECAR="$(dirname "$0")/manifest-sidecar.sh"
SERIAL_FALLBACK="$(dirname "$0")/loom-serial-fallback.sh"
GIT_ID=(-c user.email=jyen.tech@gmail.com -c user.name="Joe Yen")

die() { echo "worktree-extend: $2" >&2; exit "$1"; }
need() { [ -n "${1:-}" ] || die 1 "$2"; }

wt_path() { echo "$WT_ROOT/$(basename "$1")-$2"; }

# Treat Cargo.lock as a generated artifact, not a hand-merged file. The `ours`
# built-in merge driver keeps main's side instead of conflicting; the lockfile
# is then regenerated canonically after the merge (see lock_regen). Idempotent:
# adds the .gitattributes line only when absent, never duplicates it.
lock_merge_setup() {
  local repo="$1" ga="$1/.gitattributes" line="Cargo.lock merge=ours"
  # Enable the built-in `ours` driver on this repo before any merge runs.
  git -C "$repo" config merge.ours.driver true
  if [ ! -f "$ga" ] || ! grep -qxF "$line" "$ga"; then
    printf '%s\n' "$line" >>"$ga"
  fi
}

# After a successful source merge, regenerate Cargo.lock so the committed
# lockfile is canonical for the merged Cargo.toml. --offline first to stay
# deterministic under the serial integrate flock (no surprise network). If a
# genuinely new (uncached) dep needs the network, do NOT commit a stale lock:
# signal the caller (return 7) so integrate records lockfile-regen-needs-net.
# No-op (return 0) for repos without a Cargo.toml or Cargo.lock churn.
lock_regen() {
  local repo="$1"
  [ -f "$repo/Cargo.toml" ] || return 0          # not a cargo repo: no-op
  [ -f "$repo/Cargo.lock" ] || return 0          # no lockfile to regenerate
  command -v cargo >/dev/null 2>&1 || return 0   # no cargo: leave as merged
  if ( cd "$repo" && cargo generate-lockfile --offline >/dev/null 2>&1 ); then
    return 0
  fi
  # --offline could not satisfy the merged Cargo.toml from cache. Try an
  # offline build as a fallback (resolves via the cache without re-fetching).
  if ( cd "$repo" && cargo build --offline --quiet >/dev/null 2>&1 ); then
    return 0
  fi
  # Genuinely needs network for a new/uncached dependency: do not commit stale.
  return 7
}

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
  base="$(git -C "$repo" rev-parse --verify -q main 2>/dev/null || git -C "$repo" rev-parse HEAD)"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo" worktree add "$wt" "$branch" >&2 || die 2 "worktree add (existing branch) failed"
  else
    git -C "$repo" worktree add -b "$branch" "$wt" "$base" >&2 || die 2 "worktree add (new branch) failed"
  fi
  echo "$wt"
}

cmd_integrate() {
  local no_rebase="" ensure_main=""
  # --no-rebase: skip rebase-retry, reproduce old abort-immediately behaviour.
  # --ensure-main: if main branch is absent, create it from the default branch HEAD.
  while true; do
    case "${1:-}" in
      --no-rebase)    no_rebase=1; shift ;;
      --ensure-main)  ensure_main=1; shift ;;
      *) break ;;
    esac
  done
  local repo="${1:-}" slug="${2:-}" bump="${3:-minor}" tldr="${4:-}"
  need "$repo" "usage: integrate [--no-rebase] [--ensure-main] <repo> <slug> <bump> <tldr-file>"; need "$slug" "missing slug"
  local branch="autobuilder/$slug"
  local wt; wt="$(wt_path "$repo" "$slug")"
  exec 9>"$repo/.git/autobuilder-integrate.lock"
  flock -w 120 9 || die 5 "could not acquire integration lock for $repo"

  # --ensure-main: create main from the default-branch HEAD if it does not exist.
  # This handles repos where a prior tick's branch was never landed (no main yet).
  if [ -n "$ensure_main" ] && ! git -C "$repo" show-ref --verify --quiet "refs/heads/main"; then
    local default_head; default_head="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || die 2 "--ensure-main: cannot resolve HEAD in $repo"
    git -C "$repo" "${GIT_ID[@]}" branch main "$default_head" >&2 \
      || die 2 "--ensure-main: failed to create main branch from HEAD in $repo"
    echo "worktree-extend: created main branch from HEAD ($default_head) in $repo" >&2
  fi

  # Never merge into a dirty tree.
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    die 3 "target tree dirty; refusing to integrate $slug (commit-or-revert the working tree first)"
  fi
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" || die 2 "no branch $branch to integrate"
  git -C "$repo" checkout main >&2 2>/dev/null || git -C "$repo" checkout -q main
  # Cargo.lock is a generated artifact: keep main's side on merge (ours driver),
  # then regenerate canonically below. Set up before the merge so it takes effect.
  lock_merge_setup "$repo"
  if ! git -C "$repo" "${GIT_ID[@]}" merge --no-ff --no-edit "$branch" >&2; then
    git -C "$repo" merge --abort 2>/dev/null
    # --- rebase-retry path ---
    if [ -n "$no_rebase" ] || [ ! -d "$wt" ]; then
      # Collect conflicting paths before aborting for streak telemetry.
      local _early_cf; _early_cf="$(git -C "$repo" diff --name-only --diff-filter=U 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')"
      [ -z "$_early_cf" ] && _early_cf="unknown"
      [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "last_error=integrate-conflict:${_early_cf}" >&2 || true
      [ -x "$SERIAL_FALLBACK" ] && "$SERIAL_FALLBACK" streak-record "$repo" "$_early_cf" >&2 || true
      die 4 "merge conflict integrating $slug; aborted (branch kept for next tick)"
    fi
    echo "worktree-extend: $slug: merge conflict — attempting rebase onto current main HEAD" >&2
    local main_head; main_head="$(git -C "$repo" rev-parse main)"
    # Rebase runs in the branch's worktree (branch checked out there); main is not
    # checked out in the worktree so the primary tree stays on main and clean.
    if ! git -C "$wt" "${GIT_ID[@]}" rebase "$main_head" >&2; then
      git -C "$wt" rebase --abort 2>/dev/null
      # Collect conflicting paths for sidecar telemetry.
      local conflict_files; conflict_files="$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
      [ -z "$conflict_files" ] && conflict_files="unknown"
      [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "last_error=integrate-conflict:${conflict_files}" >&2 || true
      [ -x "$SERIAL_FALLBACK" ] && "$SERIAL_FALLBACK" streak-record "$repo" "$conflict_files" >&2 || true
      die 4 "rebase conflict integrating $slug; aborted (branch kept for next tick)"
    fi
    # Rebase succeeded. Cheap post-rebase guard: cargo check to catch auto-resolved
    # edits that reference each other in a non-compiling way.
    if [ -f "$wt/Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
      if ! ( cd "$wt" && cargo check --offline --quiet 2>&1 ); then
        git -C "$wt" rebase --abort 2>/dev/null || true
        [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "last_error=rebase-broke-build" >&2 || true
        [ -x "$SERIAL_FALLBACK" ] && "$SERIAL_FALLBACK" streak-record "$repo" "rebase-broke-build" >&2 || true
        die 4 "rebase-broke-build integrating $slug; cargo check failed after rebase (branch kept)"
      fi
    fi
    # Retry the merge now that the branch sits cleanly on top of main.
    if ! git -C "$repo" "${GIT_ID[@]}" merge --no-ff --no-edit "$branch" >&2; then
      git -C "$repo" merge --abort 2>/dev/null
      local _retry_cf; _retry_cf="$(git -C "$repo" diff --name-only --diff-filter=U 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')"
      [ -z "$_retry_cf" ] && _retry_cf="unknown"
      [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "last_error=integrate-conflict:${_retry_cf}" >&2 || true
      [ -x "$SERIAL_FALLBACK" ] && "$SERIAL_FALLBACK" streak-record "$repo" "$_retry_cf" >&2 || true
      die 4 "merge still conflicted after rebase integrating $slug; aborted (branch kept)"
    fi
    echo "worktree-extend: $slug: rebase-retry succeeded" >&2
  fi
  # Post-merge: regenerate Cargo.lock for the merged Cargo.toml. The trailing
  # `git add -A` stages it into the single bump commit. If a new uncached dep
  # needs the network, flag the sidecar rather than committing a stale lock.
  if ! lock_regen "$repo"; then
    echo "worktree-extend: $slug: lockfile-regen-needs-net (committing merged source; lock left as merged)" >&2
    [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" last_error=lockfile-regen-needs-net >&2 || true
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
  # Clean integrate: reset conflict streak for this repo so parallel fan-out resumes.
  [ -x "$SERIAL_FALLBACK" ] && "$SERIAL_FALLBACK" streak-reset "$repo" >&2 || true
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
