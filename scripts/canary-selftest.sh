#!/usr/bin/env bash
# scripts/canary-selftest.sh — the one entrypoint for PRD-build-burst-gate-
# canary-invariant's fixture coverage (test_prefix: canary, AC10/AC20).
# Runs every tests/canary_ac*.sh: each is self-contained (own mktemp dir,
# own fixtures), no real box required for any of them — the real-box ACs
# (1, 5, 6, 8, 14, 18-live-half) are exercised by hand against a live
# session, not by this runner.
#
# Usage: canary-selftest.sh
#
# Exit: 0 all green | 1 one or more failed
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

fail=0
shopt -s nullglob
for f in "$SKILL_DIR"/tests/canary_ac*.sh; do
  echo "== canary-selftest: $(basename "$f") ==" >&2
  bash "$f"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "canary-selftest: FAILED $(basename "$f") (rc=$rc)" >&2
    fail=1
  fi
done
shopt -u nullglob

if [ "$fail" -eq 0 ]; then
  echo "canary-selftest: all green"
else
  echo "canary-selftest: one or more failures — see above" >&2
fi
exit "$fail"
