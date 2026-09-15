#!/usr/bin/env bash
# teardown_ac7_idle_guard_wrapper_deferred.sh — PRD-build-burst-teardown-
# evidence AC7 (P0).
#
# Given burst-idle-guard.sh after this PRD, when its body is read, then it
# contains no age or runs arithmetic and execs `burst-lane.sh idle-guard`.
#
# DEFERRED: burst-idle-guard.sh lives in ~/dotfiles (see the PRD's own
# Migration/compatibility section), a separate repo from this PRD's
# build_into (~/wintermute/build-skill) — this build cannot edit it. The
# PRD's Deploy note (added to the PRD file itself) records the exact
# one-line replacement for the operator to commit in dotfiles:
#   exec "$(dirname "$0")/../../wintermute/build-skill/scripts/burst-lane.sh" idle-guard "$@"
# (or the equivalent absolute path burst-lane.sh already resolves in
# production). Re-run this wrapper for real once dotfiles carries the thin
# wrapper.
set -uo pipefail
echo "FAIL teardown AC7: DEFERRED, out of this PRD's build_into scope — burst-idle-guard.sh lives in ~/dotfiles, a separate repo this PRD's build_into does not cover; see this PRD's own Deploy note for the one-line replacement the operator applies there." >&2
exit 1
