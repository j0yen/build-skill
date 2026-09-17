#!/usr/bin/env bash
# main-health-gate.sh — PRD-build-main-verdict-pinned-to-landing R6/AC8:
# the tick's own entrypoint for "is main green right now", independent of
# any particular PRD's landing. Companion to main-verdict-pin-gate.sh
# (which pins a gate to a LANDED slug's merge sha M in a detached
# worktree) — this one gates the checkout's own CURRENT HEAD, directly,
# no worktree, no slug, no PRD card.
#
# usage: main-health-gate.sh <repo> [gate-launch.sh args...]
#
# <repo> is the build_into main checkout (a real path, already resolved
# by the caller — same contract as main-verdict-pin-gate.sh's own <repo>
# arg). Anything after <repo> is passed straight through to
# gate-launch.sh (e.g. --wait, or --project-root via extend-gate.sh's own
# passthrough) — this script adds exactly one thing gate-launch.sh cannot
# do for itself: resolving <repo>'s own current HEAD to pass as --head.
#
# Sequence:
#   1. `git -C <repo> rev-parse HEAD` -> N, the sha this run gates. Never
#      a landed PRD's merge sha (that is main-verdict-pin-gate.sh's job) —
#      whatever the checkout's default branch currently points at, PRD
#      work in flight or not.
#   2. gate-launch.sh <repo> --head N --scope main --slug main-health
#      --main-health (survives the invoking tick's own cgroup teardown,
#      same as every other gate-launch.sh caller) — --main-health there
#      is a plain extend-gate.sh passthrough flag (unlike
#      --pinned-landing, it does not reroute to a different entrypoint):
#      reviewer-agent and intent-card-refresh are scope-deferred inside
#      extend-gate.sh (no PRD card to review against), ci-checks reads
#      straight from Actions runs at N.
#
# "Once per new sha" (R6/AC8: "a second tick at the same N launches
# nothing"): this script keeps no cache of its own. extend-gate.sh's own
# tree-keyed verdict cache (R4, already generalized past pinned-landing —
# see that script's cache-hit block) already makes a repeat call at an
# unchanged tree a near-instant `(cached tree=...)` journal line instead
# of a full 25-producer run; a caller that runs this once per tick gets
# "once per new sha" for free from that, with no extra bookkeeping here.
#
# Exit codes: whatever gate-launch.sh itself returned — this script adds
# no verdict logic of its own (same convention as main-verdict-pin-gate.sh).
#   1  usage error, or <repo>'s HEAD could not be resolved
#   2  missing dependency (gate-launch.sh not found or not executable)
#   *  any other gate-launch.sh/extend-gate.sh exit, propagated unchanged
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GATE_LAUNCH="${MAIN_HEALTH_GATE_GATE_LAUNCH:-$HERE/gate-launch.sh}"

die() { echo "main-health-gate: $2" >&2; exit "$1"; }
usage() { echo "usage: main-health-gate.sh <repo> [gate-launch.sh args...]" >&2; }

[ $# -ge 1 ] || { usage; die 1 "missing <repo>"; }
repo_arg="$1"; shift
extra_args=("$@")

[ -x "$GATE_LAUNCH" ] || die 2 "missing $GATE_LAUNCH"

repo="$(cd "$repo_arg" 2>/dev/null && pwd)" || { usage; die 1 "no such directory: $repo_arg"; }

head_now="$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null)" \
  || die 1 "cannot resolve HEAD in $repo"

"$GATE_LAUNCH" "$repo" --head "$head_now" --scope main --slug main-health --main-health "${extra_args[@]}"
exit $?
