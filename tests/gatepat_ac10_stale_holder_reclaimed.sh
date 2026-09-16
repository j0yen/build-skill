#!/usr/bin/env bash
# gatepat_ac10_stale_holder_reclaimed.sh —
# PRD-build-gate-patience-from-queue-depth AC10 (the one selftest-only
# fixture case named in the PRD's own AC10 for extend-gate.sh/chain-guard.sh):
# a holder sidecar whose pid is dead (a prior run crashed after acquiring
# the OS lock but before its own EXIT trap could remove the sidecar) is
# reclaimed on the next run — the OS `flock` itself was already released
# by the kernel when that process died, so the NEXT run's flock succeeds
# immediately; this asserts it also journals
# `gate  lock-reclaimed  (stale_pid=<pid>)` rather than silently trusting
# or silently overwriting the stale identity.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatepat-common.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/gatepat_ac10.XXXXXX")"
trap 'rm -rf "$T"' EXIT

REPO="$T/mcphost"
HEAD_SHA="$(make_dirty_repo "$REPO")"
JOURNAL="$T/journal.md"
: > "$JOURNAL"

# A definitely-dead pid: fork a trivial child, wait for it, its pid is now
# guaranteed unassigned to anything alive (no reuse race in a selftest's
# short lifetime).
( exit 0 ) &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true

LOCKFILE="$REPO/.git/autobuilder-integrate.lock"
HOLDER_FILE="$LOCKFILE.holder"
printf '%s %s %s %s\n' "$dead_pid" "crashed-slug" "main" "$(( $(date +%s) - 999 ))" > "$HOLDER_FILE"

env EXTEND_GATE_JOURNAL="$JOURNAL" RUSTBUILD_SCRIPTS="$GATEPAT_RUSTBUILD_SCRIPTS" \
  "$EXTEND_GATE" "$REPO" --head "$HEAD_SHA" >"$T/out.log" 2>&1
rc=$?

expect "AC10: the lock was NOT reported contended (the OS flock was actually free)" "[ $rc -ne 4 ]"
expect "AC10: run reaches the dirty-tree refusal (lock acquired fine)" "[ $rc -eq 3 ]"
expect "AC10: journal records the stale-pid reclaim" \
  "grep -qE \"gate  lock-reclaimed  \\(stale_pid=$dead_pid\\)\" \"$JOURNAL\""
expect "AC10: the sidecar is gone afterward (this run's own trap fired too)" "[ ! -f \"$HOLDER_FILE\" ]"

echo "-----"
if [ "$gatepat_fail" -eq 0 ]; then
  echo "gatepat_ac10: ALL PASS"
  exit 0
else
  echo "gatepat_ac10: assertion(s) FAILED"
  exit 1
fi
