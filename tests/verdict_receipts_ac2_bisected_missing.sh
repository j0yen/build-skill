#!/usr/bin/env bash
# verdict_receipts_ac2_bisected_missing.sh — PRD-build-verdict-receipts AC2.
#
# Given a journal line containing "bisected" with no bisect-log receipt,
# when verdict-receipts.sh scans it, then it exits nonzero naming the
# line and the missing receipt kind. Replays the 2026-09-05/06 no-bisect
# regression verbatim.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VR="$HERE/../scripts/verdict-receipts.sh"
[ -x "$VR" ] || { echo "ac2: $VR not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/vr-ac2.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_RECEIPTS_DIR="$T/receipts"
mkdir -p "$BUILD_RECEIPTS_DIR"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

cat > "$T/j.md" <<'EOF'
2026-09-06T03:24:19Z  mcphost-harness-judge-calibration  archive-check  NOT-ARCHIVED  (pytest 8 failed/379 passed reproducible at HEAD 340a8ac, bisected regression in consume.py/llm.py)
EOF

out="$(bash "$VR" scan "$T/j.md")"; rc=$?
expect "scan exits nonzero on unreceipted bisected+reproducible" "[ $rc -gt 0 ]"
expect "scan names the bisected line"                            "grep -q '\[bisected\]' <<<\"\$out\""
expect "scan names missing bisect-log receipt"                   "grep -qi 'bisect-log' <<<\"\$out\""
expect "scan also flags the bare reproducible claim"             "grep -q '\[reproducible\]' <<<\"\$out\""

exit $fail
