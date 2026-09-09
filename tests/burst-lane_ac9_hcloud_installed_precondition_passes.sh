#!/usr/bin/env bash
# burst-lane_ac9_hcloud_installed_precondition_passes.sh —
# PRD-build-burst-lane-ccx53 AC9.
#
# Given hcloud installed by this PRD, when gate-burst.sh precondition runs
# on RedBaron, then it passes.
#
# Deliberately REAL, not mocked (matching the sibling gate-cloudburst PRD's
# own precedent: "Real (non-mocked) precondition check on RedBaron today").
# Requirement 2 is specifically about a real, reproducible install (see
# scripts/install-hcloud.sh) landing a real hcloud binary that really
# authenticates — a fake hcloud proving this would prove nothing about the
# actual gap this PRD found (a binary present by hand, no script able to
# reproduce or verify it).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SH="$HERE/../scripts/install-hcloud.sh"
GATE_BURST="$HERE/../scripts/gate-burst.sh"

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi; }

install_out="$(bash "$INSTALL_SH" 2>&1)"; install_rc=$?
expect "install-hcloud.sh exits 0 (already-installed or freshly installed)" "[ $install_rc -eq 0 ]"
expect "install-hcloud.sh reports a recognized outcome" \
  "grep -qE '^(already-installed|installed):' <<<\"$install_out\""

expect "hcloud is on PATH after install-hcloud.sh" "command -v hcloud >/dev/null 2>&1"

precondition_out="$(bash "$GATE_BURST" precondition 2>&1)"; precondition_rc=$?
expect "gate-burst.sh precondition passes for real" "[ $precondition_rc -eq 0 ]"
expect "precondition names the snapshot, not a failure" "grep -q '^ok: hcloud authenticated' <<<\"$precondition_out\""

exit $fail
