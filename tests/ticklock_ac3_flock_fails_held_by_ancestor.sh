#!/usr/bin/env bash
# ticklock_ac3_flock_fails_held_by_ancestor.sh — PRD-build-tick-lock-held AC3.
#
# Given tick-run.sh -- <fixture coordinator> where the fixture runs the
# SKILL Phase 0 check, When the fixture executes `flock -n state/tick.lock
# true`, Then that flock fails and the fixture's own check
# (tick-run.sh --check-held) reports `held-by-ancestor`, so the fixture
# proceeds.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BUILD_STATE_DIR="$TMP/state"
export TICK_RUN_JOURNAL="$TMP/journal.md"
mkdir -p "$BUILD_STATE_DIR"

fail=0

# The fixture coordinator: while running (launched THROUGH tick-run.sh, so
# it inherits fd 9's flock), it independently confirms the raw `flock -n`
# on the same path fails, then runs the actual Phase-0 verification
# subcommand and records the result to a file this test reads back.
FIXTURE="$TMP/fixture-coordinator.sh"
cat > "$FIXTURE" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
RESULT_FILE="$1"
LOCKFILE="$BUILD_STATE_DIR/tick.lock"
raw_flock_rc=0
flock -n "$LOCKFILE" true || raw_flock_rc=$?
check_held_out="$("$SCRIPT" --check-held)"
check_held_rc=$?
{
  echo "raw_flock_rc=$raw_flock_rc"
  echo "check_held_out=$check_held_out"
  echo "check_held_rc=$check_held_rc"
} > "$RESULT_FILE"
EOF
chmod +x "$FIXTURE"

RESULT_FILE="$TMP/result.txt"
export SCRIPT
"$SCRIPT" -- bash "$FIXTURE" "$RESULT_FILE"
tick_run_rc=$?

if [ "$tick_run_rc" -eq 0 ]; then
  echo "ok  AC3: tick-run.sh -- <fixture> exits 0"
else
  echo "FAIL: tick-run.sh -- <fixture> exited $tick_run_rc"
  fail=1
fi

# shellcheck disable=SC1090  # $RESULT_FILE is a fixture-written var dump, not a library
. "$RESULT_FILE" 2>/dev/null || { echo "FAIL: fixture wrote no result file"; exit 1; }

if [ "$raw_flock_rc" -ne 0 ]; then
  echo "ok  AC3: raw flock -n on state/tick.lock fails while tick-run.sh holds it"
else
  echo "FAIL: raw flock -n unexpectedly succeeded (rc=0) while tick-run.sh should hold the lock"
  fail=1
fi

if [ "$check_held_rc" -eq 0 ] && [ "$check_held_out" = "held-by-ancestor" ]; then
  echo "ok  AC3: tick-run.sh --check-held reports held-by-ancestor, exit 0"
else
  echo "FAIL: --check-held gave rc=$check_held_rc out=$check_held_out, want rc=0 held-by-ancestor"
  fail=1
fi

exit "$fail"
