#!/usr/bin/env bash
# verified-completed.sh — smoke test for PRD-build-deferred-acs AC2.
#
# Drives scripts/verified-completed.sh against tests/fixtures/PRD-fixture-gate.md
# (4 ACs total, deferred_acs:[1,3]) under two paired-list scenarios:
#   case A — --paired 2,4 -> gate passes (exit 0). Every AC is PAIRED or DEFERRED.
#   case B — --paired 2   -> gate fails (exit 1). stderr names AC4 explicitly.

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

exit $fail
