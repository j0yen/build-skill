#!/usr/bin/env bash
# verified-completed.sh — smoke test for PRD-build-deferred-acs AC2 + AC6.
#
# Drives scripts/verified-completed.sh against tests/fixtures/PRD-fixture-gate.md
# (4 ACs total, deferred_acs:[1,3]) under several paired-list scenarios:
#   case A — --paired 2,4 -> gate passes (exit 0). Every AC is PAIRED or DEFERRED.
#   case B — --paired 2   -> gate fails (exit 1). stderr names AC4 explicitly.
#   case C — no-deferral fixture, all ACs paired -> gate passes.
#   case D — --doctor without evidence -> per-AC annotated lines using fallbacks
#           (`(no test)` for PAIRED, `(no reason given)` for DEFERRED). AC6.
#   case E — --doctor with --paired-with + --reasons-json -> evidence/reason
#           text appears verbatim. AC6.
#   case F — --doctor missing-AC -> stdout still annotates, stderr still names
#           the gap, exit 1.
#   case G — AC4 regression: default (non-doctor) text output is byte-identical
#           to a captured baseline so the no-deferral path is unchanged.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/../scripts/verified-completed.sh"
FIXTURE="$HERE/fixtures/PRD-fixture-gate.md"

[ -x "$GATE" ] || { echo "verified-completed: $GATE not executable" >&2; exit 2; }
[ -r "$FIXTURE" ] || { echo "verified-completed: $FIXTURE missing" >&2; exit 2; }

fail=0
expect() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "ok  $label"
  else
    echo "FAIL $label" >&2
    echo "    want: $want" >&2
    echo "    got : $got"  >&2
    fail=1
  fi
}

# ---- case A — paired 2,4 -> gate passes ----
out_a="$("$GATE" "$FIXTURE" --paired 2,4 2>/dev/null)"
rc_a=$?
expect "case A: exit 0"            "0" "$rc_a"
expect "case A: AC1 DEFERRED"      "AC1: DEFERRED" "$(printf '%s\n' "$out_a" | sed -n '1p')"
expect "case A: AC2 PAIRED"        "AC2: PAIRED"   "$(printf '%s\n' "$out_a" | sed -n '2p')"
expect "case A: AC3 DEFERRED"      "AC3: DEFERRED" "$(printf '%s\n' "$out_a" | sed -n '3p')"
expect "case A: AC4 PAIRED"        "AC4: PAIRED"   "$(printf '%s\n' "$out_a" | sed -n '4p')"

# ---- case B — paired 2 -> gate fails, names AC4 ----
err_b="$("$GATE" "$FIXTURE" --paired 2 2>&1 1>/dev/null)"
rc_b=$?
expect "case B: exit 1"                          "1" "$rc_b"
case "$err_b" in
  *"AC4: not paired (and not declared deferred)"*)
    echo "ok  case B: stderr names AC4" ;;
  *)
    echo "FAIL case B: stderr does not name AC4" >&2
    echo "    stderr was:" >&2
    printf '%s\n' "$err_b" | sed 's/^/      /' >&2
    fail=1 ;;
esac

# ---- case C — no-deferral fixture with all ACs paired -> gate passes ----
NO_DEFER="$HERE/fixtures/PRD-fixture-no-deferral.md"
[ -r "$NO_DEFER" ] && {
  "$GATE" "$NO_DEFER" --paired 1,2 >/dev/null 2>&1
  expect "case C: no-deferral all-paired exit 0" "0" "$?"
}

# ---- case D — --doctor without evidence -> fallback strings ----
out_d="$("$GATE" "$FIXTURE" --paired 2,4 --doctor 2>/dev/null)"
rc_d=$?
expect "case D: exit 0"                     "0" "$rc_d"
expect "case D: AC1 DEFERRED no-reason"     "AC1: DEFERRED — (no reason given)" "$(printf '%s\n' "$out_d" | sed -n '1p')"
expect "case D: AC2 PAIRED no-test"         "AC2: PAIRED   — (no test)"         "$(printf '%s\n' "$out_d" | sed -n '2p')"
expect "case D: AC3 DEFERRED no-reason"     "AC3: DEFERRED — (no reason given)" "$(printf '%s\n' "$out_d" | sed -n '3p')"
expect "case D: AC4 PAIRED no-test"         "AC4: PAIRED   — (no test)"         "$(printf '%s\n' "$out_d" | sed -n '4p')"

# ---- case E — --doctor with evidence + reasons-json ----
out_e="$("$GATE" "$FIXTURE" --paired 2,4 --doctor \
        --paired-with 2=tests/cli.rs::snapshot \
        --paired-with 4=tests/cli.rs::round_trip \
        --reasons-json '{"1":"needs real mic","3":"needs PipeWire"}' 2>/dev/null)"
rc_e=$?
expect "case E: exit 0"                     "0" "$rc_e"
expect "case E: AC1 DEFERRED reason"        "AC1: DEFERRED — needs real mic"             "$(printf '%s\n' "$out_e" | sed -n '1p')"
expect "case E: AC2 PAIRED evidence"        "AC2: PAIRED   — tests/cli.rs::snapshot"     "$(printf '%s\n' "$out_e" | sed -n '2p')"
expect "case E: AC3 DEFERRED reason"        "AC3: DEFERRED — needs PipeWire"             "$(printf '%s\n' "$out_e" | sed -n '3p')"
expect "case E: AC4 PAIRED evidence"        "AC4: PAIRED   — tests/cli.rs::round_trip"   "$(printf '%s\n' "$out_e" | sed -n '4p')"

# ---- case F — --doctor missing AC -> stdout annotated, stderr names gap ----
out_f="$("$GATE" "$FIXTURE" --paired 2 --doctor 2>/tmp/verified-completed-f.err)"
rc_f=$?
err_f="$(cat /tmp/verified-completed-f.err)"; rm -f /tmp/verified-completed-f.err
expect "case F: exit 1"                     "1" "$rc_f"
expect "case F: AC4 MISSING annotated"      "AC4: MISSING  — (not paired, not deferred)" "$(printf '%s\n' "$out_f" | sed -n '4p')"
case "$err_f" in
  *"AC4: not paired (and not declared deferred)"*)
    echo "ok  case F: stderr still names AC4" ;;
  *)
    echo "FAIL case F: stderr does not name AC4" >&2
    echo "    stderr was:" >&2
    printf '%s\n' "$err_f" | sed 's/^/      /' >&2
    fail=1 ;;
esac

# ---- case G — AC4 regression: default output byte-identical to baseline ----
baseline="AC1: DEFERRED
AC2: PAIRED
AC3: DEFERRED
AC4: PAIRED"
out_g="$("$GATE" "$FIXTURE" --paired 2,4 2>/dev/null)"
expect "case G: default output unchanged"   "$baseline" "$out_g"

exit $fail
