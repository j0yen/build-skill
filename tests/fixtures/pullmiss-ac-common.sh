#!/usr/bin/env bash
# pullmiss-ac-common.sh — shared harness for tests/pullmiss_ac*.sh
# (PRD-build-burst-pull-remote-target-missing).
#
# Unlike the pull-back ACs (tests/fixtures/pullback-ac-common.sh), which
# have to run the whole 5900+-line burst-lane-selftest.sh (their cases are
# woven inline through it), this PRD ships its OWN small standalone suite —
# scripts/burst-lane-pull-remote-target-missing-selftest.sh — so this
# fixture just runs THAT, once, with results cached and flock-serialized
# the same way.
set -uo pipefail
PULLMISS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULLMISS_SUITE="$PULLMISS_HERE/../../scripts/burst-lane-pull-remote-target-missing-selftest.sh"
PULLMISS_BURST_LANE="$PULLMISS_HERE/../../scripts/burst-lane.sh"
[ -f "$PULLMISS_SUITE" ] || { echo "FAIL: $PULLMISS_SUITE not found" >&2; exit 2; }
[ -f "$PULLMISS_BURST_LANE" ] || { echo "FAIL: $PULLMISS_BURST_LANE not found" >&2; exit 2; }

PULLMISS_CACHE_DIR="${TMPDIR:-/tmp}/pullmiss-selftest-cache"
mkdir -p "$PULLMISS_CACHE_DIR" 2>/dev/null || true
_pullmiss_key="$(cat "$PULLMISS_SUITE" "$PULLMISS_BURST_LANE" 2>/dev/null | sha256sum | cut -c1-16)"
PULLMISS_CACHE_OUT="$PULLMISS_CACHE_DIR/$_pullmiss_key.out"
PULLMISS_CACHE_RC="$PULLMISS_CACHE_DIR/$_pullmiss_key.rc"
PULLMISS_CACHE_LOCK="$PULLMISS_CACHE_DIR/$_pullmiss_key.lock"

# pullmiss_run_suite -> sets PULLMISS_OUT (combined stdout+stderr of the
# real offline selftest) and PULLMISS_RC (its exit code).
pullmiss_run_suite() {
  (
    exec 208>"$PULLMISS_CACHE_LOCK"
    flock 208
    if [ ! -s "$PULLMISS_CACHE_OUT" ]; then
      BUILD_BURST_ENABLED=1 bash "$PULLMISS_SUITE" > "$PULLMISS_CACHE_OUT.tmp" 2>&1
      echo $? > "$PULLMISS_CACHE_RC.tmp"
      mv "$PULLMISS_CACHE_OUT.tmp" "$PULLMISS_CACHE_OUT"
      mv "$PULLMISS_CACHE_RC.tmp" "$PULLMISS_CACHE_RC"
    fi
  )
  PULLMISS_OUT="$(cat "$PULLMISS_CACHE_OUT" 2>/dev/null)"
  PULLMISS_RC="$(cat "$PULLMISS_CACHE_RC" 2>/dev/null || echo 1)"
}
