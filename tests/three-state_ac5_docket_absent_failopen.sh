#!/usr/bin/env bash
# three-state_ac5_docket_absent_failopen.sh — PRD-build-three-state-probes
# AC5.
#
# Given docket absent from PATH, when an alarm fires, then the journal line
# still lands and the probe exits 0 (fail-open).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../scripts/probe-result.sh"
[ -r "$LIB" ] || { echo "ac5: $LIB not found" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ts-ac5.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_STATE_DIR="$T/state"
export PROBE_JOURNAL_DIR="$T/journal"
export PROBE_STREAK_ALARM=3

# Build a PATH with no `docket` reachable at all (a minimal bin dir holding
# only what bash/python3/coreutils need, none of them named docket).
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
for tool in bash sh cat mkdir printf date sed tr python3 flock rm mv \
            dirname basename grep wc awk sort head tail ln cp chmod \
            env true false; do
  p="$(command -v "$tool" 2>/dev/null)" || continue
  ln -sf "$p" "$FAKEBIN/$tool"
done
export PATH="$FAKEBIN"
command -v docket >/dev/null 2>&1 && { echo "ac5: docket unexpectedly still on PATH — test setup broken" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# shellcheck source=../scripts/probe-result.sh
source "$LIB"

probe_emit noD-probe could-not-check "a1" >/dev/null; rc1=$?
probe_emit noD-probe could-not-check "a2" >/dev/null; rc2=$?
out3="$(probe_emit noD-probe could-not-check "a3")"; rc3=$?

expect "every emit returns 0 even with docket absent" \
  "[ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] && [ $rc3 -eq 0 ]"
expect "canonical stdout line still lands on the alarming emit" \
  "grep -q 'state=could-not-check' <<<\"\$out3\""

journal="$PROBE_JOURNAL_DIR/$(date -u +%F).md"
expect "journal file exists" "[ -f '$journal' ]"
expect "probe-dead line lands despite docket being absent" \
  "grep -q 'probe-dead: noD-probe streak=3' '$journal'"

exit $fail
