#!/usr/bin/env bash
# lane_carbon_ac6_timeout_regression.sh — PRD-build-second-lane-carbon AC6.
#
# Given carbon's claude-build.service with the pace drop-in, when
# start-post runs its full sleep, then no timeout/retry cycle occurs
# (TimeoutStartSec exceeds the sleep — regression AC for the 20:12
# incident). Proven offline by parsing the versioned unit, not by
# actually running systemd (no carbon box in this environment).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PACING="$HERE/../systemd/carbon/claude-build.service.d/pacing.conf"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

expect "pacing.conf exists" "[ -f \"$PACING\" ]"

timeout=$(grep -E '^TimeoutStartSec=' "$PACING" | head -n1 | cut -d= -f2)
sleep_secs=$(grep -E '^ExecStartPost=.*sleep ' "$PACING" | head -n1 | sed -E 's/.*sleep ([0-9]+).*/\1/')

expect "TimeoutStartSec parsed"                 "[ -n \"$timeout\" ]"
expect "ExecStartPost sleep duration parsed"    "[ -n \"$sleep_secs\" ]"
expect "TimeoutStartSec ($timeout) > sleep ($sleep_secs)" "[ \"$timeout\" -gt \"$sleep_secs\" ]"

exit $fail
