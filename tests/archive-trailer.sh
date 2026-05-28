#!/usr/bin/env bash
# archive-trailer.sh — smoke test for PRD-build-deferred-acs AC3.
#
# Drives scripts/archive-trailer.sh against three scenarios on the
# PRD-fixture-trailer (4 ACs, deferred_acs:[1,3]):
#   case A — paired 2,4 + no reasons -> both blocks emitted, deferred
#            entries say "(no reason given)".
#   case B — paired 2,4 + reasons-json injects AC1 + AC3 reasons ->
#            deferred entries quote the injected reasons verbatim.
#   case C — paired 2 only -> exits 1 with stderr naming AC4; stdout
#            empty (no trailer emitted on a gap).
#
# AC3 of PRD-build-deferred-acs is then exercised end-to-end against
# the real archived-PRD shape.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GEN="$HERE/../scripts/archive-trailer.sh"
FIXTURE="$HERE/fixtures/PRD-fixture-trailer.md"

[ -x "$GEN" ] || { echo "archive-trailer: $GEN not executable" >&2; exit 2; }
[ -r "$FIXTURE" ] || { echo "archive-trailer: $FIXTURE missing" >&2; exit 2; }

fail=0
expect() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "ok  $label"
  else
    echo "FAIL $label" >&2
    echo "    want: $want" >&2
    echo "    got : $got" >&2
    fail=1
  fi
}

# ---- case A — paired 2,4, no reasons ----
out_a="$("$GEN" "$FIXTURE" \
  --paired 2='tests/jsonsnap.rs::roundtrip' \
  --paired 4='tests/schema.rs::roundtrip' 2>/dev/null)"
rc_a=$?
expect "case A: exit 0"                              "0" "$rc_a"
expect "case A: line 1 Verified-completed header"    "Verified-completed:"                                  "$(printf '%s\n' "$out_a" | sed -n '1p')"
expect "case A: line 2 AC2 paired"                   "  AC2 — paired with tests/jsonsnap.rs::roundtrip"     "$(printf '%s\n' "$out_a" | sed -n '2p')"
expect "case A: line 3 AC4 paired"                   "  AC4 — paired with tests/schema.rs::roundtrip"       "$(printf '%s\n' "$out_a" | sed -n '3p')"
expect "case A: line 4 blank"                        ""                                                     "$(printf '%s\n' "$out_a" | sed -n '4p')"
expect "case A: line 5 Deferred header"              "Deferred:"                                            "$(printf '%s\n' "$out_a" | sed -n '5p')"
expect "case A: line 6 AC1 no-reason fallback"       "  AC1 — (no reason given)"                            "$(printf '%s\n' "$out_a" | sed -n '6p')"
expect "case A: line 7 AC3 no-reason fallback"       "  AC3 — (no reason given)"                            "$(printf '%s\n' "$out_a" | sed -n '7p')"

# ---- case B — reasons injected via --reasons-json ----
out_b="$("$GEN" "$FIXTURE" \
  --paired 2='tests/jsonsnap.rs::roundtrip' \
  --paired 4='tests/schema.rs::roundtrip' \
  --reasons-json '{"1":"wake-to-event latency requires real mic","3":"AEC quality requires PipeWire echo-cancel"}' 2>/dev/null)"
rc_b=$?
expect "case B: exit 0"                              "0" "$rc_b"
expect "case B: AC1 reason verbatim"                 "  AC1 — wake-to-event latency requires real mic"      "$(printf '%s\n' "$out_b" | sed -n '6p')"
expect "case B: AC3 reason verbatim"                 "  AC3 — AEC quality requires PipeWire echo-cancel"    "$(printf '%s\n' "$out_b" | sed -n '7p')"

# ---- case C — gap, exit 1, stderr names AC4, stdout empty ----
tmp_out="$(mktemp)"; tmp_err="$(mktemp)"
"$GEN" "$FIXTURE" --paired 2='tests/jsonsnap.rs::roundtrip' >"$tmp_out" 2>"$tmp_err"
rc_c=$?
out_c="$(cat "$tmp_out")"
err_c="$(cat "$tmp_err")"
rm -f "$tmp_out" "$tmp_err"
expect "case C: exit 1"                              "1" "$rc_c"
expect "case C: stdout empty"                        "" "$out_c"
expect "case C: stderr names AC4"                    "AC4: not paired (and not declared deferred)" "$err_c"

if [ "$fail" -ne 0 ]; then
  echo "FAIL: one or more assertions failed" >&2
  exit 1
fi
echo "ok  archive-trailer: all 14 assertions green"
