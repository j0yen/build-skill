#!/usr/bin/env bash
# main-verdict-pin-gate.sh — PRD-build-main-verdict-pinned-to-landing
# R1/R2/R3: the one entrypoint a post-land re-verify or archive/
# verified-completed main-green question calls for a landed slug S in a
# `push_via_branch=true` repo, instead of ever gating the checkout's
# current HEAD. This is the fix for the 2026-09-17 05:15:46Z regression
# (gate-debt-4f1112d re-checked at HEAD=e70af61 — one PRD later than its
# own merge at 98eb6f5 — producing `ci-checks — head_sha mismatch`).
#
# usage: main-verdict-pin-gate.sh <repo> <slug> [extend-gate.sh args...]
#
# <repo> is the build_into main checkout (a real path, already resolved by
# the caller — same contract as gate-then-land.sh's own <repo> arg).
# Anything after <slug> is passed straight through to extend-gate.sh
# (e.g. --project-root <rel>), same convention gate-then-land.sh's
# $pr_args uses.
#
# Sequence:
#   1. landing-verdict-resolve.sh <repo> <slug> -> M (R1; R7 on failure —
#      this script never falls back to gating HEAD when M can't be
#      resolved, propagating R7's exit 4 unchanged).
#   2. M's first parent (`git rev-parse M^`) -> B, the base the reviewer
#      and rollback-plan review against (Technical considerations: "M's
#      first parent on main ... squash merges are single-parent commits").
#   3. A DETACHED worktree at M, under worktree-extend.sh's own root
#      (`$BUILD_WT_ROOT`, default ~/.cache/build-worktrees), named
#      `<repo>-<slug>-verify` (Technical considerations) — never the
#      ordinary `<repo>-<slug>` branch worktree, so a concurrent branch
#      gate for the same slug never collides with this read-only verify.
#   4. extend-gate.sh <worktree> --head M --scope main --slug S --base B
#      --pinned-landing (R3: this flag widens the main-scope journal line
#      to name the slug and mark it pinned, and makes the intent-card
#      pre-gate refresh run for S at main scope too — see extend-gate.sh's
#      own comments at each site).
#   5. The detached worktree is removed either way (pass or block) — it
#      is read-only evidence, never a branch anything lands on.
#
# R4: extend-gate.sh's own tree-keyed verdict cache lives at
# <worktree>/target/autobuilder/last-verdict.json — INSIDE the worktree
# step 5 just deleted, so without help a repeat question for the same
# slug/M would pay a full run every time. `--verdict-cache-mirror
# state/main-verdict-cache/<repo>/<slug>.json` (a stable path this script
# owns, never removed) is passed through: extend-gate.sh seeds its cache
# from it before checking for a hit, and refreshes it after every write
# (hit or fresh run) — see that script's own R4 comments. "M's tree is
# immutable, so a hit is a hit forever" (Technical considerations).
#
# Exit codes:
#   0/1  whatever extend-gate.sh itself returned (pass/block) — this
#        script adds no verdict logic of its own.
#   1    usage error, or M's first parent could not be resolved
#   2    missing dependency (landing-verdict-resolve.sh / extend-gate.sh
#        not found or not executable), or the detached worktree could not
#        be created
#   4    landing-verdict-resolve.sh's own R7: landing-record-unusable
#        (propagated unchanged — its own journal line already named the
#        field/sha that was missing; this script does not journal a
#        second line for the same failure)
#   *    any other extend-gate.sh infra exit, propagated unchanged
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
WT_ROOT="${BUILD_WT_ROOT:-$HOME/.cache/build-worktrees}"
LANDING_VERDICT_RESOLVE="${MAIN_VERDICT_PIN_GATE_LANDING_VERDICT_RESOLVE:-$HERE/landing-verdict-resolve.sh}"
EXTEND_GATE="${MAIN_VERDICT_PIN_GATE_EXTEND_GATE:-$HERE/extend-gate.sh}"

die() { echo "main-verdict-pin-gate: $2" >&2; exit "$1"; }
usage() { echo "usage: main-verdict-pin-gate.sh <repo> <slug> [extend-gate.sh args...]" >&2; }

[ $# -ge 2 ] || { usage; die 1 "missing <repo>/<slug>"; }
repo_arg="$1"; slug="$2"; shift 2
extra_args=("$@")

[ -x "$LANDING_VERDICT_RESOLVE" ] || die 2 "missing $LANDING_VERDICT_RESOLVE"
[ -x "$EXTEND_GATE" ] || die 2 "missing $EXTEND_GATE"

repo="$(cd "$repo_arg" 2>/dev/null && pwd)" || { usage; die 1 "no such directory: $repo_arg"; }
repo_slug="$(basename "$repo")"

# --- R1: resolve M (or propagate R7 unchanged) --------------------------
merge_sha="$("$LANDING_VERDICT_RESOLVE" "$repo" "$slug")"
resolve_rc=$?
[ "$resolve_rc" -eq 0 ] && [ -n "$merge_sha" ] || exit "$resolve_rc"

# --- Technical considerations: M's first parent is the review base -----
base_sha="$(git -C "$repo" rev-parse --verify "${merge_sha}^" 2>/dev/null)" \
  || die 1 "cannot resolve first parent of $merge_sha in $repo"

# --- R2: a detached worktree at M, never the checkout ------------------
mkdir -p "$WT_ROOT"
wt_dir="$WT_ROOT/${repo_slug}-${slug}-verify"
cleanup() {
  git -C "$repo" worktree remove --force "$wt_dir" >/dev/null 2>&1 || true
  rm -rf "$wt_dir"
}
trap cleanup EXIT
# A prior crashed run can leave this path registered — clear it before
# `worktree add` refuses a path git still thinks is in use.
git -C "$repo" worktree remove --force "$wt_dir" >/dev/null 2>&1 || true
rm -rf "$wt_dir"
git -C "$repo" worktree add --detach "$wt_dir" "$merge_sha" >/dev/null 2>&1 \
  || die 2 "git worktree add --detach $wt_dir $merge_sha failed"

# --- R4: a stable mirror (outside the worktree this trap removes) so a
# repeat question for the same slug/M is a cache hit, not a full re-run.
# Mirrors state/landings/<repo>/<slug>.json's own path convention.
mkdir -p "$STATE_DIR/main-verdict-cache/$repo_slug"
verdict_cache_mirror="$STATE_DIR/main-verdict-cache/$repo_slug/$slug.json"

# --- R3: gate M in that worktree, pinned -------------------------------
"$EXTEND_GATE" "$wt_dir" --head "$merge_sha" --scope main --slug "$slug" \
  --base "$base_sha" --pinned-landing --verdict-cache-mirror "$verdict_cache_mirror" "${extra_args[@]}"
gate_rc=$?
exit "$gate_rc"
