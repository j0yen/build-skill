#!/usr/bin/env bash
# burst-lane_ac2_run_routes_and_pulls_target.sh — PRD-build-burst-lane-ccx53 AC2.
#
# Given a session up, when burst-lane.sh run <worktree> -- cargo test is
# invoked, then the worktree is synced, the remote cargo runs with
# RUSTC_WRAPPER=sccache (asserted structurally: cmd_run's remote command
# always exports it — see scripts/burst-lane.sh), its exit code is
# returned, and target/ in the worktree contains the remote build's
# artifacts afterwards.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"

# Structural check: cmd_run's remote command line must export
# RUSTC_WRAPPER=sccache unconditionally (no fake can observe an env var
# inside its own eval'd "remote" shell any more honestly than reading the
# literal command burst-lane.sh constructs).
BL="$HERE/../scripts/burst-lane.sh"
grep -q 'RUSTC_WRAPPER=sccache' "$BL" || { echo "FAIL: burst-lane.sh no longer sets RUSTC_WRAPPER=sccache on the remote command" >&2; exit 1; }
echo "ok  remote command always exports RUSTC_WRAPPER=sccache"

run_suite_and_expect_labels \
  "ok  run propagates the remote exit code" \
  "ok  run pulled target/ back to the worktree" \
  "ok  run journaled the routed call"
