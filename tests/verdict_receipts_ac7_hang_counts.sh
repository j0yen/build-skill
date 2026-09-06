#!/usr/bin/env bash
# verdict_receipts_ac7_hang_counts.sh — PRD-build-verdict-receipts AC7.
#
# Given a re-run that times out, when the receipt is written, then it
# records kind hang and counts as the second record for the
# reproducibility claim (clears the >=2-records floor, even though a
# hang's output won't share a failure line with the original red run).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VR="$HERE/../scripts/verdict-receipts.sh"
[ -x "$VR" ] || { echo "ac7: $VR not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/vr-ac7.XXXXXX")"
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

hang_out="$(bash "$VR" record probe hangslug --timeout 1 -- sleep 5)"; rc=$?
expect "record exits 0 even when timed out"    "[ $rc -eq 0 ]"
expect "timed-out record path names kind hang" "[[ \"\$hang_out\" == *-hang.txt ]]"
expect "hang receipt file exists"              "[ -f \"\$hang_out\" ]"
expect "hang receipt records exit 124"         "grep -q '^exit: 124\$' \"\$hang_out\""

red="$BUILD_RECEIPTS_DIR/2026-09-06-repro2-red.txt"
mk_receipt "2026-09-06-repro2-red.txt" "uv run pytest -x" 1 "2026-09-06T04:00:00Z" "1 failed"
cat > "$T/j.md" <<EOF
2026-09-06T04:05:00Z  repro2  archive-check  NOT-ARCHIVED  (reproducible; receipt: $red, receipt: $hang_out)
EOF
out="$(bash "$VR" scan "$T/j.md")"
# The hang receipt shares no output-tail line with the red receipt, so
# the "same failure" check still fails here — AC7 only promises the hang
# record COUNTS as a second record (clears the >=2-records floor), not
# that mismatched output passes reproducibility outright.
expect "hang receipt satisfies the >=2-records floor (not a count failure)" \
  '! grep -q "requires >=2 recorded runs" <<<"$out"'

exit $fail
