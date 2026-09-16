#!/usr/bin/env bash
# scripts/tick-selftest-summary.sh — PRD-build-journal-single-writer
# requirement 6 (P1 nudge): derives the tick summary's `selftests
# direct=<n> runner=<n>` field from the prelude's own journal notice
# (scripts/lib/isolation.sh's selftest_init, one `journal  test-run
# (via=direct|runner name=<file>)` line per test), never from parsing
# stdout.
#
# Usage: tick-selftest-summary.sh <test-root>
#   <test-root> is the BUILD_TEST_ROOT a tick shared across every selftest
#   it ran this tick (direct invocations and run-selftests.sh alike must
#   have inherited the same root for the counts to mean anything — a tick
#   that lets each test mint its own throwaway root gets 0/0 here, which is
#   itself the signal that no shared root was set up).
#
# Prints exactly one line: "selftests direct=<n> runner=<n>". Exit 0
# always (a report, never a gate); a missing/empty test-root journal
# prints direct=0 runner=0.
set -uo pipefail

root="${1:-}"
if [ -z "$root" ]; then
  echo "usage: tick-selftest-summary.sh <test-root>" >&2
  exit 2
fi

jdir="$root/journal"
direct=0
runner=0
if [ -d "$jdir" ]; then
  direct="$(grep -shoE 'test-run  \(via=direct' "$jdir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  runner="$(grep -shoE 'test-run  \(via=runner' "$jdir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
fi

echo "selftests direct=${direct:-0} runner=${runner:-0}"
