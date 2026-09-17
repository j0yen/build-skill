#!/usr/bin/env bash
# reviewer-receipt-selftest.sh — the one entrypoint for PRD-build-
# reviewer-receipt-primary's fixture coverage (test_prefix: rvrcpt).
# Runs every tests/rvrcpt_ac*.sh: AC1-AC5 and AC6 drive the REAL
# extend-gate.sh through the fake toolchain at tests/fixtures/rvrcpt-fake/
# against a disposable fixture crate (never mcphost, never any production
# repo); AC7 reads the real REVIEWER_PROMPT file this PRD edited in the
# rustbuild skill repo (a second-repo edit, R7) and, when
# RVRCPT_R7_COMMIT is exported, confirms the cited commit exists there.
#
# Usage: reviewer-receipt-selftest.sh
#
# Exit: 0 all green | 1 one or more failed
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

fail_n=0
shopt -s nullglob
for f in "$SKILL_DIR"/tests/rvrcpt_ac*.sh; do
  echo "== reviewer-receipt-selftest: $(basename "$f") ==" >&2
  bash "$f"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "reviewer-receipt-selftest: FAILED $(basename "$f") (rc=$rc)" >&2
    fail_n=$((fail_n + 1))
  fi
done
shopt -u nullglob

if [ "$fail_n" -eq 0 ]; then
  echo "reviewer-receipt-selftest: PASS (0 FAIL)"
  exit 0
else
  echo "reviewer-receipt-selftest: FAIL ($fail_n FAIL)" >&2
  exit 1
fi
