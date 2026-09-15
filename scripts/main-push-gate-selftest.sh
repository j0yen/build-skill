#!/usr/bin/env bash
# main-push-gate-selftest.sh — the one entrypoint for
# PRD-build-main-push-gate's fixture coverage (test_prefix: mainpush).
# Runs every tests/mainpush_ac*.sh (each builds its own throwaway git+cargo
# fixture under $TMPDIR — see tests/fixtures/mainpush-common.sh — and
# tears it down on exit; nothing here touches a real fleet repo).
#
# AC6 and AC7 are P1 requirements verified LIVE against the real j0yen/
# mcphost repo (branch protection + a real branch/PR/auto-merge landing) —
# they are not fixture-shaped (a fixture can't stand in for GitHub's own
# branch-protection enforcement) and are not run by this script. Their
# verdicts are journaled separately by branch-protection.sh's own run and
# recorded in state/branch-protection.json; see that script and this PRD's
# journal entries for the live evidence.
#
# Usage: main-push-gate-selftest.sh [--via-run-selftests]
#   --via-run-selftests   delegate to scripts/run-selftests.sh mainpush
#                          (production test-isolation wrapper — the
#                          preferred entrypoint per SKILL.md; see that
#                          script's own header). Default (no flag): run
#                          the tests/mainpush_ac*.sh files directly, useful
#                          for iterating on one file without the isolation
#                          wrapper's leak-detection overhead.
#
# Exit: 0 all green | 1 one or more failed
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

if [ "${1:-}" = "--via-run-selftests" ]; then
  exec "$HERE/run-selftests.sh" mainpush
fi

fail=0
shopt -s nullglob
for f in "$SKILL_DIR"/tests/mainpush_ac*.sh; do
  echo "== main-push-gate-selftest: $(basename "$f") ==" >&2
  bash "$f"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "main-push-gate-selftest: FAILED $(basename "$f") (rc=$rc)" >&2
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "main-push-gate-selftest: all green"
else
  echo "main-push-gate-selftest: one or more failures — see above" >&2
fi
exit "$fail"
