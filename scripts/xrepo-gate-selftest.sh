#!/usr/bin/env bash
# xrepo-gate-selftest.sh — the one entrypoint for PRD-build-cross-repo-
# commit-gate's fixture coverage (test_prefix: xrepo). Runs every
# tests/xrepo_ac*.sh: AC1/AC4/AC5/AC6/AC7 are fast (real git only, no
# cargo/autobuilder); AC2/AC3 build a real disposable rust-extend fixture
# crate under $TMPDIR (never mcphost, never any production repo) and run
# the real `extend-gate.sh --scope branch` producer sequence against it,
# so each takes roughly a minute.
#
# Usage: xrepo-gate-selftest.sh [--via-run-selftests]
#   --via-run-selftests   delegate to scripts/run-selftests.sh xrepo
#                          (production test-isolation wrapper — the
#                          preferred entrypoint per SKILL.md). Default (no
#                          flag): run the tests/xrepo_ac*.sh files
#                          directly, useful for iterating on one file
#                          without the isolation wrapper's overhead.
#
# Exit: 0 all green | 1 one or more failed
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

if [ "${1:-}" = "--via-run-selftests" ]; then
  exec "$HERE/run-selftests.sh" xrepo
fi

fail=0
shopt -s nullglob
for f in "$SKILL_DIR"/tests/xrepo_ac*.sh; do
  echo "== xrepo-gate-selftest: $(basename "$f") ==" >&2
  bash "$f"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "xrepo-gate-selftest: FAILED $(basename "$f") (rc=$rc)" >&2
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "xrepo-gate-selftest: all green"
else
  echo "xrepo-gate-selftest: one or more failures — see above" >&2
fi
exit "$fail"
