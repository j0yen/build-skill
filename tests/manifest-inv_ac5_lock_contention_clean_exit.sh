#!/usr/bin/env bash
# manifest-inv_ac5_lock_contention_clean_exit.sh — PRD-build-manifest-
# invariants AC5.
#
# Given a concurrent tick holding tick.lock, When the reconciler cannot
# acquire it within the wait ceiling, Then it exits cleanly having changed
# nothing. LOCK_WAIT_SECS is shrunk so this test stays fast (the SKILL.md/
# PRD contract's real ceiling is 60s; see the script's own header).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MI="$HERE/../scripts/manifest-invariants.sh"
[ -x "$MI" ] || { echo "ac5: $MI not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/manifest-inv-ac5.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state/intent" "$T/build-queue" "$T/built-prds" "$T/parked"

python3 -c "
import json
json.dump({'prds': {'ac5-fixture': {
  'slug': 'ac5-fixture', 'status': 'blocked', 'blockers': [], 'iter_log': []
}}}, open('$T/state/manifest.json', 'w'))
"
before_hash="$(sha256sum "$T/state/manifest.json" | awk '{print $1}')"

export BUILD_STATE_DIR="$T/state"
export BUILD_MANIFEST="$T/state/manifest.json"
export LOCK="$T/state/tick.lock"
export JOURNAL="$T/journal.md"
export PATH=/usr/bin:/bin
export LOCK_WAIT_SECS=1

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# Hold the lock for longer than LOCK_WAIT_SECS in a background subshell.
(
  exec 8>"$LOCK"
  flock 8
  sleep 3
) &
holder_pid=$!
# Give the holder a moment to actually acquire the lock first.
sleep 0.3

out="$("$MI" --prd-dir "$T" --format json)"; rc=$?
expect "exits 0 (clean)" "[ $rc -eq 0 ]"
expect "reports lock-contended" "grep -q 'lock-contended' <<<\"\$out\""
expect "reports zero healed/alarmed" "grep -q '\"healed\":0' <<<\"\$out\" && grep -q '\"alarmed\":0' <<<\"\$out\""

wait "$holder_pid"
after_hash="$(sha256sum "$T/state/manifest.json" | awk '{print $1}')"
expect "manifest byte-unchanged" "[ '$before_hash' = '$after_hash' ]"

exit $fail
