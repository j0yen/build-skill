#!/usr/bin/env bash
# chained-tick_ac5_kernel_excluded.sh — PRD-build-chained-tick-actions AC5.
#
# Given a kernel-extend fixture, When selection runs, Then it is never
# chained. (Requirement 5 — kernel-extend and the tick's ≤1 Phase-6 reflect
# candidate keep the one-action-per-tick invariant unchanged.)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CG="$HERE/../scripts/chain-guard.sh"
[ -x "$CG" ] || { echo "ac5: $CG not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/chained-tick-ac5.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_STATE_DIR="$T/state"
export BUILD_MANIFEST="$BUILD_STATE_DIR/manifest.json"
mkdir -p "$BUILD_STATE_DIR/intent"
SLUG="kernel-fixture"

cat > "$BUILD_MANIFEST" <<JSON
{"prds": {"$SLUG": {"slug": "$SLUG", "status": "in_progress", "build_target": "kernel-extend", "blockers": [], "chained_steps": 1}}}
JSON

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# Even with every OTHER precondition wide open (no blockers, cap unset,
# not the reflect candidate, no lock contention), a kernel-extend PRD is
# refused a second step — it never chains past its one action per tick.
out="$("$CG" check "$SLUG" --step-count 1 --skip-select-guard)"; rc=$?
expect "kernel-extend: chain-guard says stop"            "[ $rc -eq 1 ]"
expect "kernel-extend: stop reason is excluded-kernel-extend" \
  "grep -q 'excluded-kernel-extend' <<<\"\$out\""

unset CHAIN_MAX_STEPS
out="$("$CG" check "$SLUG" --step-count 1 --skip-select-guard)"; rc=$?
expect "kernel-extend: still excluded with CHAIN_MAX_STEPS unset" "[ $rc -eq 1 ]"

# Sanity: a non-kernel-extend PRD with the SAME manifest shape (in_progress,
# no blockers) is not excluded — proves the stop is specific to
# build_target=kernel-extend, not an artifact of the fixture shape.
OTHER="not-kernel-fixture"
cat > "$BUILD_MANIFEST" <<JSON
{"prds": {"$SLUG": {"slug": "$SLUG", "status": "in_progress", "build_target": "kernel-extend", "blockers": [], "chained_steps": 1},
          "$OTHER": {"slug": "$OTHER", "status": "in_progress", "build_target": "shell", "blockers": [], "chained_steps": 1}}}
JSON
out="$("$CG" check "$OTHER" --step-count 1 --skip-select-guard)"; rc=$?
expect "control: same-shaped shell PRD is NOT excluded" "[ $rc -eq 0 ]"

exit $fail
