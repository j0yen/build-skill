#!/usr/bin/env bash
# three-state_ac6_probe_status_table.sh — PRD-build-three-state-probes AC6.
#
# Given six retrofitted probes with mixed states, when probe-status.sh runs,
# then one table shows each probe's last state, last change time, and live
# streak.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../scripts/probe-result.sh"
PS="$HERE/../scripts/probe-status.sh"
[ -r "$LIB" ] || { echo "ac6: $LIB not found" >&2; exit 2; }
[ -x "$PS" ] || { echo "ac6: $PS not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ts-ac6.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_STATE_DIR="$T/state"
export PROBE_JOURNAL_DIR="$T/journal"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# shellcheck source=../scripts/probe-result.sh
source "$LIB"

# The six named probes this PRD retrofits.
probe_emit lane-has-work clean "0 of 3 selectable" >/dev/null
probe_emit burst-status clean "no active session" >/dev/null
probe_emit burst-subcap clean "sub-cap=6" >/dev/null
probe_emit burst-verify could-not-check "no active session to verify" >/dev/null
probe_emit gate-receipt-freshness clean "installed=0.7.0 expected=0.7.0 (fresh)" >/dev/null
probe_emit quota-watch could-not-check "BUILD_LOG unreadable" >/dev/null
probe_emit quota-watch could-not-check "BUILD_LOG unreadable" >/dev/null

table="$("$PS")"
json="$("$PS" --json)"

for name in lane-has-work burst-status burst-subcap burst-verify gate-receipt-freshness quota-watch; do
  expect "table lists $name" "grep -q '^$name ' <<<\"\$table\" || grep -qE '^${name}[[:space:]]' <<<\"\$table\""
done

expect "table has a header row" "grep -qi 'PROBE' <<<\"\$table\""
expect "quota-watch shows a live streak of 2" \
  "grep -E '^quota-watch[[:space:]]' <<<\"\$table\" | grep -q ' 2$'"
expect "json form is parseable and has 6 keys" \
  "python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert len(d)==6' \"\$json\""
expect "json form reports quota-watch streak=2" \
  "python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d[\"quota-watch\"][\"streak\"]==2' \"\$json\""

exit $fail
