#!/usr/bin/env bash
# verdict_receipts_ac3_summa_regression.sh — PRD-build-verdict-receipts AC3.
#
# Given the 2026-09-05 20:44 summa block replayed as a fixture (one
# unspaced probe, no cross-check), when the validator scans it, then it
# is flagged for citing unreachable without the required receipts.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VR="$HERE/../scripts/verdict-receipts.sh"
[ -x "$VR" ] || { echo "ac3: $VR not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/vr-ac3.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_RECEIPTS_DIR="$T/receipts"
mkdir -p "$BUILD_RECEIPTS_DIR"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

cat > "$T/PRD-ac3-summa.md" <<'EOF'
- Status: blocked
- Blocked: RedBaron unreachable (SSH timeout to 100.73.175.108)
EOF

out="$(bash "$VR" scan "$T/PRD-ac3-summa.md")"; rc=$?
expect "summa fixture exits nonzero"    "[ $rc -gt 0 ]"
expect "flagged as unreachable"         "grep -q '\[unreachable\]' <<<\"\$out\""
expect "names missing probe/crosscheck" "grep -qi 'probe' <<<\"\$out\""

exit $fail
