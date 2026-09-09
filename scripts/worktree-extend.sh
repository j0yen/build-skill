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
#   integrate [--project-root <rel>] <repo> <slug> <bump> <tldr-file>
#       SERIAL. Takes the per-repo integration lock. Refuses if <repo>'s main
#       working tree is dirty (exit 3) — never merges into a dirty tree.
#       Merges autobuilder/<slug> into main (--no-ff), then bumps the version
#       (<bump>) and prepends the CHANGELOG from <tldr-file> via
#       extend-handler.sh, committing the bump with the Joe Yen identity.
#       Exit 4 on merge conflict (merge aborted; branch left for next tick).
#       On success, runs `cleanup` (branch kept) so the worktree and its
#       cargo target-dir are freed the moment the branch lands — the freed
#       path is named in stderr (stdout stays the bare new version, for
#       existing `newver=$(...)` callers).
#       --project-root <rel>: for repos whose Cargo.toml lives under a
#       subdirectory of <repo> (nested crate root, e.g. post-source-unify
#       split repos) — passed through to extend-handler.sh's bump-version
#       and current-version calls, same flag/semantics as extend-gate.sh's
#       and intent-card-refresh.sh's own --project-root. Omit for the
#       common case (Cargo.toml at repo root); behavior is unchanged.
#
#   cleanup <repo> <slug>
#       Remove the worktree dir AND its cargo target-dir (named by the
#       worktree's `.cargo/config.toml`, or recomputed from the current
#       target-root convention if that file is gone). Keeps the branch
#       unless --drop-branch given (branch is kept when integration was
#       deferred, so work resumes).
#
#   prune-landed <repo>
#       For every autobuilder/<slug> worktree of <repo> whose branch tip is
#       an ancestor of origin/main, run `cleanup` (worktree + target dir).
#       Branches not yet merged are left untouched. PRD-build-worktree-targets-off-root:
#       run this before a gate/build tick opens a new worktree on a repo
#       that's been accumulating landed-but-uncleaned worktrees.
#
#   list <repo>
#       Show this repo's autobuilder worktrees.
#
# All paths absolute. Identity for the bump commit is Joe Yen (wintermute repo
# convention). Worktrees live under $WT_ROOT (default ~/.cache/build-worktrees).
#
# Cargo target-dir isolation (PRD-build-worktree-targets-off-root, 2026-09-08):
# a rust worktree's `target/` can be 50G+, and worktrees live under $WT_ROOT
# (root filesystem by default) — two landed-but-uncleaned worktrees filled
# root to 100% and killed a truth-tier measure run. `add` now writes
# `<worktree>/.cargo/config.toml` pointing `target-dir` at
# $BUILD_TARGET_ROOT/<repo>-<slug> (default /mnt/data/jsy/cargo-targets when
# /mnt/data exists, else ~/.cache/cargo-targets — see target_root() below),
# and excludes `.cargo/` from the branch via the repo's (shared,
# never-committed) `.git/info/exclude`. `cleanup`/`integrate`/`prune-landed`
# all remove that directory along with the worktree.
set -uo pipefail

WT_ROOT="${BUILD_WT_ROOT:-$HOME/.cache/build-worktrees}"
EXTEND="$(dirname "$0")/extend-handler.sh"
SIDECAR="$(dirname "$0")/manifest-sidecar.sh"
SERIAL_FALLBACK="$(dirname "$0")/loom-serial-fallback.sh"
GIT_ID=(-c user.email=jyen.tech@gmail.com -c user.name="Joe Yen")

die() { echo "worktree-extend: $2" >&2; exit "$1"; }
need() { [ -n "${1:-}" ] || die 1 "$2"; }

wt_path() { echo "$WT_ROOT/$(basename "$1")-$2"; }

# Root for worktree cargo target-dirs. $BUILD_TARGET_ROOT wins when set;
# otherwise /mnt/data/jsy/cargo-targets when the data drive is mounted here,
# else $HOME/.cache/cargo-targets (root filesystem, but at least a fresh box
# with no /mnt/data still works). Kept in sync with
# ~/dotfiles/.local/lib/vibeloop-target-root.sh's cargo_target_root() for the
# measure loop's tag build — same convention, separate repo.
target_root() {
  if [ -n "${BUILD_TARGET_ROOT:-}" ]; then
    printf '%s\n' "$BUILD_TARGET_ROOT"
  elif [ -d /mnt/data ]; then
    printf '%s\n' /mnt/data/jsy/cargo-targets
  else
    printf '%s\n' "$HOME/.cache/cargo-targets"
  fi
}

target_dir_for() { echo "$(target_root)/$(basename "$1")-$2"; }

# Write <worktree>/.cargo/config.toml pointing target-dir at
# target_dir_for(repo,slug), creating the target dir, and exclude `.cargo/`
# from the branch via the repo's info/exclude (shared across worktrees;
# `git -C <worktree> rev-parse --git-path` resolves it correctly even though
# a worktree's own `.git` is a file, not a directory — info/exclude is not
# per-worktree). Idempotent: safe to call again on an existing worktree.
write_target_config() {
  local wt="$1" repo="$2" slug="$3" tdir
  tdir="$(target_dir_for "$repo" "$slug")"
  mkdir -p "$tdir" || die 2 "could not create cargo target dir: $tdir"
  mkdir -p "$wt/.cargo" || die 2 "could not create $wt/.cargo"
  printf '[build]\ntarget-dir = "%s"\n' "$tdir" > "$wt/.cargo/config.toml"
  local gp; gp="$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null)"
  if [ -n "$gp" ]; then
    mkdir -p "$(dirname "$gp")"
    grep -qxF '.cargo/' "$gp" 2>/dev/null || printf '%s\n' '.cargo/' >> "$gp"
  fi
}

# Read the target-dir a worktree's own .cargo/config.toml names (empty if the
# worktree or file is gone). Preferred over recomputing from the CURRENT
# target_root(), since $BUILD_TARGET_ROOT may have changed since `add`.
read_target_dir() {
  local f="$1/.cargo/config.toml" line
  [ -f "$f" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      *target-dir*=*\"*\"*)
        line="${line#*\"}"; printf '%s\n' "${line%%\"*}"; return 0 ;;
    esac
  done < "$f"
}

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
#
# PRD-extend-gate-lock-cloexec (2026-09-05 incident class): called from
# cmd_integrate while fd 9 holds the integration lock. Both cargo
# invocations below close fd 9 (`9>&-`) in their subshell before exec'ing
# cargo, so an autostarted sccache daemon never inherits the lock fd and
# outlives this script holding it hostage for the next gate/integrate run.
lock_regen() {
  local repo="$1"
  [ -f "$repo/Cargo.toml" ] || return 0          # not a cargo repo: no-op
  [ -f "$repo/Cargo.lock" ] || return 0          # no lockfile to regenerate
  command -v cargo >/dev/null 2>&1 || return 0   # no cargo: leave as merged
  if ( cd "$repo" && cargo generate-lockfile --offline >/dev/null 2>&1 ) 9>&-; then
    return 0
  fi
  # --offline could not satisfy the merged Cargo.toml from cache. Try an
  # offline build as a fallback (resolves via the cache without re-fetching).
  if ( cd "$repo" && cargo build --offline --quiet >/dev/null 2>&1 ) 9>&-; then
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
    write_target_config "$wt" "$repo" "$slug"
    print_cargo_budget_path_reminder >&2
    print_burst_lane_path_reminder "$repo" >&2
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
  write_target_config "$wt" "$repo" "$slug"
  print_cargo_budget_path_reminder >&2
  print_burst_lane_path_reminder "$repo" >&2
  echo "$wt"
}

# PRD-build-cargo-concurrency-budget: a worktree's `cargo test`/`clippy`/
# `build --release`/`deny`/`nextest` must route through the host-wide
# cargo concurrency budget (cargo-budget.sh) so a wide tick's worktree
# branches don't each assume they own RedBaron (the 2026-09-09 OOM: load
# 21,466 with the same-target sub-cap at only 3). Printed to stderr (not
# stdout, which stays the bare worktree path for any caller doing
# `wt=$(worktree-extend.sh add ...)`); SKILL.md's branch dispatch prompt
# requires the branch agent actually run this export.
print_cargo_budget_path_reminder() {
  echo "worktree-extend: cargo-budget — before any cargo command in this worktree, run:" >&2
  echo "  export PATH=\"\$HOME/.claude/skills/build/scripts/cargo-budget-bin:\$PATH\"" >&2
  echo "worktree-extend: this routes cargo test/clippy/build --release/deny/nextest through" >&2
  echo "the shared concurrency budget; cargo check/metadata bypass it (PRD-build-cargo-concurrency-budget)." >&2
}

# PRD-build-burst-lane-ccx53 requirement 4: rust branches must be able to
# route cargo through the Hetzner CCX53 burst lane when a session is up.
# The burst-lane cargo shim (scripts/burst-lane-bin/cargo) has to sit AHEAD
# of cargo-budget-bin on PATH (its own header comment: it inserts itself
# ahead of that chain without disturbing it) so BURST_LANE=1 routes to the
# box first and only falls through to the local budget shim when no session
# exists. Printed to stderr, gated on the repo actually being a cargo repo
# (same test cargo-budget's reminder uses) so a non-rust worktree gets no
# irrelevant burst-lane noise. SKILL.md's branch dispatch prompt requires
# the branch agent actually run this export for rust branches.
print_burst_lane_path_reminder() {
  local repo="${1:?print_burst_lane_path_reminder: missing repo arg}"
  [ -f "$repo/Cargo.toml" ] || return 0
  echo "worktree-extend: burst-lane — before any cargo command in this worktree, run:" >&2
  echo "  export PATH=\"\$HOME/.claude/skills/build/scripts/burst-lane-bin:\$PATH\" BURST_LANE=1" >&2
  echo "worktree-extend: (prepend AFTER cargo-budget-bin so burst-lane-bin resolves first —" >&2
  echo "PATH=\"burst-lane-bin:cargo-budget-bin:\$PATH\") this routes cargo build/test/clippy/" >&2
  echo "deny/nextest to the CCX53 burst lane when 'burst-lane.sh status' reports a session," >&2
  echo "and falls through to cargo-budget-bin's local routing otherwise (PRD-build-burst-lane-ccx53)." >&2
}

cmd_integrate() {
  local no_rebase="" ensure_main="" project_root=""
  # --no-rebase: skip rebase-retry, reproduce old abort-immediately behaviour.
  # --ensure-main: if main branch is absent, create it from the default branch HEAD.
  # --project-root <rel>: nested crate root, passed through to extend-handler.sh
  # (see the subcommand doc comment above).
  while true; do
    case "${1:-}" in
      --no-rebase)    no_rebase=1; shift ;;
      --ensure-main)  ensure_main=1; shift ;;
      --project-root) project_root="${2:?worktree-extend: --project-root needs a value}"; shift 2 ;;
      *) break ;;
    esac
  done
  local -a project_root_args=()
  [ -n "$project_root" ] && project_root_args=(--project-root "$project_root")
  local repo="${1:-}" slug="${2:-}" bump="${3:-minor}" tldr="${4:-}"
  need "$repo" "usage: integrate [--no-rebase] [--ensure-main] [--project-root <rel>] <repo> <slug> <bump> <tldr-file>"; need "$slug" "missing slug"
  local branch="autobuilder/$slug"
  local wt; wt="$(wt_path "$repo" "$slug")"
  # PRD-extend-gate-lock-cloexec (2026-09-05 incident class): every cargo
  # invocation below (lock_regen, the post-rebase `cargo check` guard)
  # closes fd 9 (`9>&-`) in its own subshell before exec'ing cargo, so an
  # autostarted sccache daemon never inherits this lock fd and holds it
  # past this script's exit. Same convention as extend-gate.sh.
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
    # edits that reference each other in a non-compiling way. fd 9 (the
    # integration lock, held since cmd_integrate started — see
    # PRD-extend-gate-lock-cloexec) is closed in the subshell so an
    # autostarted sccache daemon cannot inherit and outlive it.
    if [ -f "$wt/Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
      if ! ( cd "$wt" && cargo check --offline --quiet 2>&1 ) 9>&-; then
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
  "$EXTEND" bump-version "$repo" "$bump" "${project_root_args[@]}" >&2 || die 6 "bump-version failed"
  local newver; newver="$("$EXTEND" current-version "$repo" "${project_root_args[@]}")"
  if [ -n "$tldr" ] && [ -f "$tldr" ]; then
    "$EXTEND" changelog-prepend "$repo" "$newver" "$tldr" "${project_root_args[@]}" >&2 || die 6 "changelog-prepend failed"
  fi
  git -C "$repo" add -A >&2
  git -C "$repo" "${GIT_ID[@]}" commit -q -m "$(basename "$repo"): v$newver — $slug (parallel integrate)" >&2 \
    || die 6 "version-bump commit failed"
  # TAG OWNERSHIP (corrected 2026-09-09, second 5-whys): the CURRENT version's
  # tag belongs to the GATE — its redeploy-tag model places v<ver> on the green
  # HEAD as the redeploy point; integrate tagging its own bump commit stole the
  # name and blocked every gate ("tag exists on a different commit"). Historical
  # versions (superseded by a later bump) are backfilled by extend-gate's
  # lineage self-heal. Integrate therefore creates NO tag.
  # Executable "shipped" contract (see scripts/ship-postconditions.sh header for
  # the 5-whys). Non-fatal here — the bump commit already exists and the gate
  # hard-fails on the same contract — but loud and sidecar-recorded.
  if ! "$(dirname "$0")/ship-postconditions.sh" "$repo" >&2; then
    echo "worktree-extend: $slug: SHIP-POSTCONDITIONS FAILED after integrate — gate will block until healed" >&2
    [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" last_error=ship-postconditions-failed >&2 || true
  fi
  # Clean integrate: reset conflict streak for this repo so parallel fan-out resumes.
  [ -x "$SERIAL_FALLBACK" ] && "$SERIAL_FALLBACK" streak-reset "$repo" >&2 || true
  # PRD-build-worktree-targets-off-root: the branch is merged, its worktree
  # (and 50G+ cargo target) has served its purpose — free it now rather than
  # waiting on a caller-remembered `cleanup` or a later `prune-landed` sweep.
  # Keep the branch (no --drop-branch): that decision stays with the caller's
  # own cleanup/--drop-branch step, same as the non-parallel path.
  local cleanup_out; cleanup_out="$(cmd_cleanup "$repo" "$slug")"
  echo "worktree-extend: $slug: integrate: $cleanup_out" >&2
  echo "$newver"
}

cmd_cleanup() {
  local repo="${1:-}" slug="${2:-}" drop=""; need "$repo" "usage: cleanup <repo> <slug> [--drop-branch]"; need "$slug" "missing slug"
  [ "${3:-}" = "--drop-branch" ] && drop=1
  local wt branch tdir; wt="$(wt_path "$repo" "$slug")"; branch="autobuilder/$slug"
  # Prefer the target-dir the worktree's own config names (read BEFORE
  # removing the worktree); fall back to recomputing it if the worktree/file
  # is already gone (e.g. re-running cleanup, or a worktree that pre-dates
  # this config).
  tdir="$(read_target_dir "$wt")"
  [ -n "$tdir" ] || tdir="$(target_dir_for "$repo" "$slug")"
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null
  git -C "$repo" worktree prune 2>/dev/null
  [ -n "$tdir" ] && rm -rf "$tdir"
  [ -n "$drop" ] && git -C "$repo" branch -D "$branch" 2>/dev/null
  echo "cleaned $wt${drop:+ (+branch)}; freed target $tdir"
}

# For each autobuilder/<slug> worktree of <repo> whose branch tip is an
# ancestor of origin/main, run cleanup (worktree + target dir; branch is left
# alone — it's already merged, dropping it is a separate/optional step).
# Unmerged sibling worktrees are untouched.
cmd_prune_landed() {
  local repo="${1:-}"; need "$repo" "usage: prune-landed <repo>"
  [ -d "$repo/.git" ] || git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die 2 "not a git repo: $repo"
  git -C "$repo" fetch -q origin >/dev/null 2>&1 || true
  if ! git -C "$repo" show-ref --verify --quiet refs/remotes/origin/main; then
    echo "worktree-extend: prune-landed: no origin/main in $repo, nothing to compare against" >&2
    return 0
  fi
  local prefix="$WT_ROOT/$(basename "$repo")-"
  local wt="" branch="" line
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) wt="${line#worktree }"; branch="" ;;
      branch\ *)   branch="${line#branch }"; branch="${branch#refs/heads/}" ;;
      '')
        if [ -n "$wt" ] && [ -n "$branch" ] && [ "${wt#"$prefix"}" != "$wt" ]; then
          local tip; tip="$(git -C "$repo" rev-parse --verify -q "refs/heads/$branch" 2>/dev/null)"
          if [ -n "$tip" ] && git -C "$repo" merge-base --is-ancestor "$tip" refs/remotes/origin/main 2>/dev/null; then
            local slug="${branch#autobuilder/}"
            echo "worktree-extend: prune-landed: $branch landed on origin/main, cleaning $slug" >&2
            cmd_cleanup "$repo" "$slug" >&2
          fi
        fi
        wt=""; branch=""
        ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain; echo)
}

cmd_list() { local repo="${1:-}"; need "$repo" "usage: list <repo>"; git -C "$repo" worktree list | grep -F "$WT_ROOT/$(basename "$repo")-" || echo "(no autobuilder worktrees)"; }

case "${1:-}" in
  add)          shift; cmd_add "$@" ;;
  integrate)    shift; cmd_integrate "$@" ;;
  cleanup)      shift; cmd_cleanup "$@" ;;
  prune-landed) shift; cmd_prune_landed "$@" ;;
  list)         shift; cmd_list "$@" ;;
  *) echo "usage: worktree-extend.sh {add|integrate|cleanup|prune-landed|list} ..." >&2; exit 1 ;;
esac
