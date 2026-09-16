#!/usr/bin/env bash
# main-push-gate-selftest.sh — the one entrypoint for
# PRD-build-main-push-gate's fixture coverage (test_prefix: mainpush).
# Runs every tests/mainpush_ac*.sh: AC0-5/8-9 each build their own
# throwaway git+cargo fixture under $TMPDIR (see
# tests/fixtures/mainpush-common.sh) and tear it down on exit — nothing
# there touches a real fleet repo.
#
# AC6 and AC7 are P1 requirements that were EXECUTED live against the real
# j0yen/mcphost repo (branch protection enabled; a real branch/PR/
# auto-merge landing, PR #1, merged 4f1112d) — a fixture can't stand in
# for GitHub's own branch-protection enforcement, so those actions were
# never going to be fixture-shaped. tests/mainpush_ac6_*.sh and
# tests/mainpush_ac7_*.sh instead re-verify the DURABLE evidence those
# live actions left behind (state/branch-protection.json's push_via_branch
# record cross-checked against a live, READ-ONLY `gh api` call; PR #1's
# actual merged state) every time this runs — real regression coverage
# without re-mutating mcphost on every pass. Both skip cleanly (exit 0) if
# `gh` isn't authenticated/reachable, since "can't reach GitHub" is an
# environment gap, not a regression in this PRD's own code.
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
