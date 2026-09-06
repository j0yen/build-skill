#!/usr/bin/env bash
# verdict_receipts_ac5_postflight_flag.sh — PRD-build-verdict-receipts AC5.
#
# Given a tick whose journal contains an unreceipted status-changing
# verdict, when postflight runs, then the tick's own journal gains a
# flag line naming it before the tick exits, and postflight itself
# never fails the caller. A clean journal is left untouched.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VR="$HERE/../scripts/verdict-receipts.sh"
[ -x "$VR" ] || { echo "ac5: $VR not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/vr-ac5.XXXXXX")"
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

before_lines="$(wc -l < "$T/j.md")"
bash "$VR" postflight "$T/j.md"; rc=$?
after_lines="$(wc -l < "$T/j.md")"
expect "postflight always exits 0"          "[ $rc -eq 0 ]"
expect "postflight appends a flag line"     "[ $after_lines -gt $before_lines ]"
expect "flag line names postflight-flag"    "grep -q 'postflight-flag' \"$T/j.md\""
expect "flag line names the offending word" "grep -q 'bisected' \"$T/j.md\""

: > "$T/clean.md"
echo "2026-09-06T05:00:00Z  someslug  archive  shipped  (gate: pass=25 block=0)" > "$T/clean.md"
before_clean="$(wc -l < "$T/clean.md")"
bash "$VR" postflight "$T/clean.md" >/dev/null
after_clean="$(wc -l < "$T/clean.md")"
expect "postflight is a no-op on a clean journal" "[ $before_clean -eq $after_clean ]"

exit $fail
