#!/usr/bin/env bash
# main-push-pr-path-selftest.sh — the one entrypoint for
# PRD-build-main-push-gate-pr-path's fixture coverage (test_prefix: prpath).
# Runs every tests/prpath_ac*.sh; each builds its own throwaway git fixture
# under $TMPDIR and tears it down on exit — nothing here touches a real
# fleet repo or the running skill's production state/journal (every test
# exports BUILD_STATE_DIR/BUILD_JOURNAL_ROOT to an isolated tmp path).
#
# This PRD builds out in atomic steps (SKILL.md's chained-tick-actions
# doctrine); this driver picks up whatever tests/prpath_ac*.sh files exist
# so far via glob — it is not, itself, evidence that every AC is covered.
# See the PRD's own AC list for which numbered ACs currently have a
# fixture here.
#
# Usage: main-push-pr-path-selftest.sh
# Exit: 0 all green | 1 one or more failed
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

fail=0
shopt -s nullglob
for f in "$SKILL_DIR"/tests/prpath_ac*.sh; do
  echo "== main-push-pr-path-selftest: $(basename "$f") ==" >&2
  bash "$f"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "main-push-pr-path-selftest: FAILED $(basename "$f") (rc=$rc)" >&2
    fail=1
  fi
done

# Guardrail (success-metrics table): no `--force`/`reset --hard` on any
# `main` anywhere in this PRD's own scripts. Static, not behavioral --
# excludes comment lines (a `#`-led line, ignoring leading whitespace)
# so this PRD's own header prose naming the forbidden flags doesn't trip
# itself.
for target in "$SKILL_DIR/scripts/branch-protection.sh"; do
  bad="$(grep -nE -- '--force|reset[[:space:]]+--hard' "$target" | grep -vE '^[0-9]+:[[:space:]]*#')"
  if [ -n "$bad" ]; then
    echo "main-push-pr-path-selftest: FAILED force/reset-hard guardrail in $target:" >&2
    echo "$bad" >&2
    fail=1
  else
    echo "ok  no --force/reset --hard in $(basename "$target")"
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "main-push-pr-path-selftest: all green"
else
  echo "main-push-pr-path-selftest: one or more failures — see above" >&2
fi
exit "$fail"
