#!/usr/bin/env bash
# main-verdict-pin-selftest.sh — the one entrypoint for
# PRD-build-main-verdict-pinned-to-landing's fixture coverage
# (test_prefix: mainpin; R8/AC9 names this file). Runs every
# tests/mainpin_*.sh; each builds its own throwaway git fixture under
# $TMPDIR and tears it down on exit — nothing here touches a real fleet
# repo or the running skill's production state/journal (every test
# exports BUILD_STATE_DIR/BUILD_JOURNAL_ROOT to an isolated tmp path).
#
# This PRD builds out in atomic steps (SKILL.md's chained-tick-actions
# doctrine); this driver picks up whatever tests/mainpin_*.sh files exist
# so far via glob — it is not, itself, evidence that every AC is covered.
# See the PRD's own AC list (PRD-build-main-verdict-pinned-to-landing)
# for which numbered ACs currently have a fixture here; the first fixture
# ("mainpin_landing_check_merge_sha_persist") covers a FOUNDATION piece
# of R1/AC1/AC2/AC4 (the landing record must durably carry merge_sha
# before anything can pin a gate to it) -- it does not yet exercise the
# detached-worktree pinned gate itself.
#
# Usage: main-verdict-pin-selftest.sh
# Exit: 0 all green | 1 one or more failed
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

fail=0
shopt -s nullglob
for f in "$SKILL_DIR"/tests/mainpin_*.sh; do
  echo "== main-verdict-pin-selftest: $(basename "$f") ==" >&2
  bash "$f"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "main-verdict-pin-selftest: FAILED $(basename "$f") (rc=$rc)" >&2
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "main-verdict-pin-selftest: all green"
else
  echo "main-verdict-pin-selftest: one or more failures — see above" >&2
fi
exit "$fail"
