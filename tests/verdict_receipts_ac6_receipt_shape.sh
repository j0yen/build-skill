#!/usr/bin/env bash
# verdict_receipts_ac6_receipt_shape.sh — PRD-build-verdict-receipts AC6.
#
# Given a receipt file, when read, then it contains command, start
# timestamp, exit code, output tail, and hostname.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VR="$HERE/../scripts/verdict-receipts.sh"
[ -x "$VR" ] || { echo "ac6: $VR not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/vr-ac6.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_RECEIPTS_DIR="$T/receipts"
mkdir -p "$BUILD_RECEIPTS_DIR"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

rp="$(bash "$VR" record smoke ac6slug -- echo hi)"
expect "record printed a receipt path that exists" "[ -f \"\$rp\" ]"
expect "receipt has command"     "grep -q '^command:' \"\$rp\""
expect "receipt has started-at"  "grep -q '^started-at:' \"\$rp\""
expect "receipt has exit 0"      "grep -q '^exit: 0\$' \"\$rp\""
expect "receipt has hostname"    "grep -q '^hostname:' \"\$rp\""
expect "receipt has output-tail" "grep -q '^output-tail:' \"\$rp\""
expect "receipt captured stdout" "grep -q 'hi' \"\$rp\""

exit $fail
