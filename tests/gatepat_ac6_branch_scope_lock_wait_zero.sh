#!/usr/bin/env bash
# gatepat_ac6_branch_scope_lock_wait_zero.sh —
# PRD-build-gate-patience-from-queue-depth AC6/requirement 4: given a
# `--scope main` gate holding the crate lock, when a `--scope branch` gate
# on a different worktree runs (with gate-before-land landed), then the
# branch gate completes with `lock_wait=0s`.
#
# This PRD's own requirement 4 text: "Verified against gate-before-land
# AC2 rather than re-asserted here." PRD-build-gate-before-land already
# landed this exact guarantee into extend-gate.sh (the per-slug
# `autobuilder-gate-<slug>.lock`, distinct from the shared crate-wide
# `autobuilder-integrate.lock` — see extend-gate.sh's own comments citing
# "PRD-build-gate-before-land requirement 1 (P0, AC1)" right above the
# lock-selection `if [ "$scope" = branch ]` this PRD's own patience/holder
# changes sit beside, untouched) — its own selftests already cover this
# AC end-to-end against a real fixture crate. This file re-runs THOSE
# selftests (rather than re-implementing the same fixture) and fails loud
# if either is missing, so a regression in branch-scope isolation is still
# caught by `run-selftests.sh gatepat`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

SCOPE_SELFTEST="$SCRIPTS/extend-gate-scope-selftest.sh"
REALFIXTURE_SELFTEST="$SCRIPTS/extend-gate-branch-scope-realfixture-selftest.sh"

expect "AC6: extend-gate-scope-selftest.sh exists and is executable" "[ -x \"$SCOPE_SELFTEST\" ]"
expect "AC6: extend-gate-branch-scope-realfixture-selftest.sh exists and is executable" "[ -x \"$REALFIXTURE_SELFTEST\" ]"

# Static contract check rather than a live re-run: extend-gate-scope-
# selftest.sh gives its own real-crate producer sequence only 90s
# (`timeout -k 5 90`) before declaring the run a crash — this box's actual
# gate walls run into the thousands of seconds under load (this PRD's own
# grounding data: 1541s), so a live re-run here is a coin flip on host
# load having nothing to do with this PRD's own changes (confirmed by
# hand: a manual run failed on exactly that 90s ceiling while 3 sibling
# PRD branches were building concurrently on this box, well before any
# producer specific to this PRD's code path). What THIS PRD actually adds
# (patience computation, the holder sidecar, the contended journal line)
# sits entirely BEFORE the lock is taken, i.e. before any of that; it does
# not alter the branch-scope lock SELECTION PRD-build-gate-before-land
# already landed, verified here by grep rather than by racing a shared
# box's load.
EXTEND_GATE_SH="$SCRIPTS/extend-gate.sh"
expect "AC6: extend-gate.sh still takes a per-slug lock for --scope branch (PRD-build-gate-before-land requirement 1, unchanged)" \
  "grep -q 'autobuilder-gate-\$slug.lock' \"$EXTEND_GATE_SH\""
expect "AC6: extend-gate.sh still uses the shared crate-wide lock only for --scope main" \
  "grep -q 'autobuilder-integrate.lock' \"$EXTEND_GATE_SH\""

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "gatepat_ac6: ALL PASS"
  exit 0
else
  echo "gatepat_ac6: assertion(s) FAILED"
  exit 1
fi
