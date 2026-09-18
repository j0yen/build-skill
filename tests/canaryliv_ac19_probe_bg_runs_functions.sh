#!/usr/bin/env bash
# tests/canaryliv_ac19_probe_bg_runs_functions.sh — PRD-build-burst-canary-
# live-parity R11/AC19: "Given `probe_bg t -- some_shell_function arg` where
# the function is defined in the caller and `probe_bg t -- /bin/true`, When
# both run, Then the journal has `probe bg-exit (name=t rc=0)` for each, the
# function received `arg`, and no `rc=127` line exists."
#
# Grounding: burst-lane.log 2026-09-18T04:34:55Z recorded "setsid: failed to
# execute cmd_parity: No such file or directory" rc=127 -- setsid always
# execs $1 as a real binary, which a bash function name never is. R11 fixes
# probe_bg to run a function directly (inherited by the forked subshell
# already, no exec needed) and keep setsid for real binaries.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/.." && pwd -P)"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/canaryliv-ac19-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

echo "=== AC19: probe_bg runs a shell function directly, keeps setsid for real binaries ==="

export STATE_DIR="$T/state"
JOURNAL="$T/journal.md"
export JOURNAL
mkdir -p "$STATE_DIR"

# shellcheck source=lib/journal.sh
source "$REPO_ROOT/scripts/lib/journal.sh" 2>/dev/null || source "$REPO_ROOT/scripts/journal.sh" 2>/dev/null
# shellcheck source=lib/probe.sh
source "$REPO_ROOT/scripts/lib/probe.sh"

RECEIVED_ARG_FILE="$T/received-arg"
some_shell_function() {
  printf '%s' "${1:-}" > "$RECEIVED_ARG_FILE"
  return 0
}

probe_bg t -- some_shell_function "arg"
probe_bg t -- /bin/true

deadline=$(( $(date +%s) + 10 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  n="$(grep -c 'probe  bg-exit  (name=t rc=0)' "$JOURNAL" 2>/dev/null || echo 0)"
  [ "${n:-0}" -ge 2 ] && break
  sleep 0.2
done

echo "  journal contents:"
cat "$JOURNAL" 2>/dev/null || echo "  <no journal file>"

n="$(grep -c 'probe  bg-exit  (name=t rc=0)' "$JOURNAL" 2>/dev/null || echo 0)"
expect "journal has probe bg-exit (name=t rc=0) twice (function + binary)" "[ \"$n\" -eq 2 ]"
expect "the function received its arg" "[ \"\$(cat '$RECEIVED_ARG_FILE' 2>/dev/null)\" = arg ]"
expect "no rc=127 line exists anywhere in the journal" "! grep -q 'rc=127' '$JOURNAL'"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canaryliv_ac19_probe_bg_runs_functions: ALL PASS"
else
  echo "canaryliv_ac19_probe_bg_runs_functions: FAILED" >&2
fi
exit "$fail"
