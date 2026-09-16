#!/usr/bin/env bash
# tests/bgscope_ac9_tick_summary_branch_gates_tally.sh — PRD-build-branch-
# gate-scope-artifacts requirement 7 (P1) / AC9: "Given a tick with branch
# gates, When the tick summary line is written, Then it contains
# `branch_gates pass=<n> block=<n> deferred_only=<n>` matching the
# journal's gate lines for that tick." No cargo/autobuilder needed --
# lane-status.sh's tick-summary reads a plain journal file.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LANE_STATUS="$HERE/../scripts/lane-status.sh"
[ -x "$LANE_STATUS" ] || { echo "selftest: $LANE_STATUS not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/bgscope-ac9-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
J="$T/journal.md"
cat > "$J" <<'EOF'
2026-09-16T02:27:36Z  gate  repo-x  pass  (scope=branch slug=s1 head=abc base=def gate: verdict=pass blocking=none wall=3s) deferred=rollback-plan,ci-checks
2026-09-16T02:28:00Z  gate  repo-x  block  (scope=branch slug=s2 head=abc base=def gate: verdict=block blocking=extended-receipts wall=3s) inherited=0 in-scope=1
2026-09-16T02:29:00Z  gate  repo-x  pass  (scope=main head=abc base=def gate: verdict=pass blocking=none wall=3s)
EOF

echo "=== AC9: tick-summary appends branch_gates pass=1 block=1 deferred_only=1 ==="
PRD_DIR="$T/prds" "$LANE_STATUS" tick-summary bgscope-test 2 1 "$J" >/dev/null
line="$(grep 'BRANCH-GATES' "$J" || true)"
echo "  $line"
expect "BRANCH-GATES line was appended" "[ -n \"$line\" ]"
expect "line reads branch_gates pass=1 block=1 deferred_only=1" \
  "printf '%s' \"$line\" | grep -q 'branch_gates pass=1 block=1 deferred_only=1'"
expect "the main-scope gate line is NOT counted" "! printf '%s' \"$line\" | grep -q 'pass=2'"

echo "-----"
if [ "$fail" -eq 0 ]; then echo "bgscope_ac9: ALL PASS"; else echo "bgscope_ac9: assertion(s) FAILED"; fi
exit "$fail"
