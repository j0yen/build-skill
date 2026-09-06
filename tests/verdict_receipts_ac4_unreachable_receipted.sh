#!/usr/bin/env bash
# verdict_receipts_ac4_unreachable_receipted.sh — PRD-build-verdict-receipts AC4.
#
# Given a Blocked: value citing SSH timeout with two probes >=60s apart
# and a cross-check receipt, when the validator scans it, then it
# passes.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VR="$HERE/../scripts/verdict-receipts.sh"
[ -x "$VR" ] || { echo "ac4: $VR not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/vr-ac4.XXXXXX")"
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

mk_receipt "2026-09-06-fleetx-probe.txt"      "ssh -o ConnectTimeout=5 100.73.175.108 true" 255 "2026-09-06T20:44:00Z" "ssh: connect to host 100.73.175.108 port 22: Connection timed out"
mk_receipt "2026-09-06-fleetx-probe-2.txt"    "ssh -o ConnectTimeout=5 100.73.175.108 true" 255 "2026-09-06T20:47:10Z" "ssh: connect to host 100.73.175.108 port 22: Connection timed out"
mk_receipt "2026-09-06-fleetx-crosscheck.txt" "ssh -o ConnectTimeout=5 carbon true"          0   "2026-09-06T20:45:00Z" "ok"
cat > "$T/PRD-ac4-fleetx.md" <<EOF
- Status: blocked
- Blocked: RedBaron unreachable (SSH timeout; receipt: $BUILD_RECEIPTS_DIR/2026-09-06-fleetx-probe.txt, receipt: $BUILD_RECEIPTS_DIR/2026-09-06-fleetx-probe-2.txt, receipt: $BUILD_RECEIPTS_DIR/2026-09-06-fleetx-crosscheck.txt)
EOF

out="$(bash "$VR" scan "$T/PRD-ac4-fleetx.md")"; rc=$?
expect "spaced probes + crosscheck passes" "[ $rc -eq 0 ]"
expect "prints PASS"                       "grep -q '^PASS' <<<\"\$out\""

exit $fail
