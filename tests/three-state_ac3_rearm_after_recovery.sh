#!/usr/bin/env bash
# three-state_ac3_rearm_after_recovery.sh — PRD-build-three-state-probes AC3.
#
# Given a could-not-check streak followed by a clean emit, when the next
# could-not-check streak reaches threshold again, then a fresh alarm fires
# (re-armed).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../scripts/probe-result.sh"
[ -r "$LIB" ] || { echo "ac3: $LIB not found" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ts-ac3.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_STATE_DIR="$T/state"
export PROBE_JOURNAL_DIR="$T/journal"
export PROBE_STREAK_ALARM=3

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# shellcheck source=../scripts/probe-result.sh
source "$LIB"

journal="$PROBE_JOURNAL_DIR/$(date -u +%F).md"

probe_emit rearm-demo could-not-check "run1-a" >/dev/null
probe_emit rearm-demo could-not-check "run1-b" >/dev/null
probe_emit rearm-demo could-not-check "run1-c" >/dev/null
expect "first streak alarms once" "[ \"\$(grep -c 'probe-dead: rearm-demo' '$journal')\" -eq 1 ]"

probe_emit rearm-demo clean "recovered" >/dev/null
expect "streak resets to 0 after recovery" "[ \"\$(probe_streak rearm-demo)\" -eq 0 ]"

probe_emit rearm-demo could-not-check "run2-a" >/dev/null
probe_emit rearm-demo could-not-check "run2-b" >/dev/null
expect "no alarm before threshold on the new run" \
  "[ \"\$(grep -c 'probe-dead: rearm-demo' '$journal')\" -eq 1 ]"

probe_emit rearm-demo could-not-check "run2-c" >/dev/null
expect "second streak fires a FRESH alarm (2 total lines now)" \
  "[ \"\$(grep -c 'probe-dead: rearm-demo' '$journal')\" -eq 2 ]"

exit $fail
