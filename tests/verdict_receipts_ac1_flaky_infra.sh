#!/usr/bin/env bash
# verdict_receipts_ac1_flaky_infra.sh — PRD-build-verdict-receipts AC1.
#
# Given a red pytest run followed by a green re-run recorded per the
# protocol, when the agent writes its verdict, then the verdict is
# flaky-infra with both receipts referenced and scan passes (the PRD is
# not blocked by it).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VR="$HERE/../scripts/verdict-receipts.sh"
[ -x "$VR" ] || { echo "ac1: $VR not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/vr-ac1.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_RECEIPTS_DIR="$T/receipts"
mkdir -p "$BUILD_RECEIPTS_DIR"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

mk_receipt() { # <name> <command> <exit> <started-at> <tail...>
  local name="$1" cmd="$2" ex="$3" ts="$4"; shift 4
  {
    printf 'command: %s\n' "$cmd"
    printf 'started-at: %s\n' "$ts"
    printf 'exit: %s\n' "$ex"
    printf 'hostname: test-host\n'
    printf 'output-tail:\n'
    printf '%s\n' "$@"
  } > "$BUILD_RECEIPTS_DIR/$name"
}

mk_receipt "2026-09-06-judge-rerun-red.txt"   "uv run pytest tests/consume -x" 1 "2026-09-06T03:24:00Z" "8 failed, 379 passed"
mk_receipt "2026-09-06-judge-rerun-green.txt" "uv run pytest tests/consume -x" 0 "2026-09-06T03:31:00Z" "0 failed, 387 passed"
cat > "$T/j.md" <<EOF
2026-09-06T03:32:00Z  mcphost-harness-judge-calibration  archive  flaky-infra  (receipt: $BUILD_RECEIPTS_DIR/2026-09-06-judge-rerun-red.txt, receipt: $BUILD_RECEIPTS_DIR/2026-09-06-judge-rerun-green.txt)
EOF

out="$(bash "$VR" scan "$T/j.md")"; rc=$?
expect "scan exits 0 (flaky-infra with both receipts passes)" "[ $rc -eq 0 ]"
expect "scan prints PASS"                                     "grep -q '^PASS' <<<\"\$out\""

exit $fail
