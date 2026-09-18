#!/usr/bin/env bash
# scripts/lint-contract-size.sh — size + date-freshness lint for the
# branch-contract split (PRD-build-branch-contract-split requirement 4).
#
# Two checks, run independently so either can be exercised alone by a
# selftest fixture:
#   1. docs/branch-contract.md (the ONLY document a branch agent reads,
#      per that PRD) must be <=400 lines and must contain no dated
#      incident text (a `20YY-MM-DD` pattern) — history lives in
#      docs/history.md instead, linked by `see history.md#<anchor>`.
#      Absent (pre-split, or before this PRD's later steps land the
#      file) is a SKIP, not a FAIL — this tool is useful standalone
#      ahead of the content move itself.
#   2. SKILL.md must be <=200 lines once it becomes the index Requirement
#      3 describes. A caller that needs the one-release migration
#      tolerance the PRD's "Migration / compatibility" section grants
#      passes --skill-tolerate-migration to downgrade a skill-too-long
#      failure to a WARN (exit 0) for that one release; the default (no
#      flag) enforces the cap unconditionally — deliberate, so wiring
#      this into run-selftests.sh --all is a LATER step of this PRD, done
#      once the content actually moves out of SKILL.md, not this one.
#
# Usage:
#   lint-contract-size.sh [--contract PATH] [--skill PATH] [--skill-tolerate-migration]
#
# Exit: 0 clean (or skip-only) | 1 one or more FAILs (each names its file)
#       | 2 usage error
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

CONTRACT="$REPO_ROOT/docs/branch-contract.md"
SKILL="$REPO_ROOT/SKILL.md"
TOLERATE_MIGRATION=0
CONTRACT_MAX=400
SKILL_MAX=200
DATE_RE='20[0-9]{2}-[0-9]{2}-[0-9]{2}'

while [ $# -gt 0 ]; do
  case "$1" in
    --contract) CONTRACT="${2:?lint-contract-size: --contract needs a value}"; shift 2 ;;
    --skill) SKILL="${2:?lint-contract-size: --skill needs a value}"; shift 2 ;;
    --skill-tolerate-migration) TOLERATE_MIGRATION=1; shift ;;
    *) echo "lint-contract-size: unknown arg: $1" >&2; exit 2 ;;
  esac
done

fails=0

check_contract() {
  if [ ! -f "$CONTRACT" ]; then
    echo "SKIP: $CONTRACT not present yet (pre-split)"
    return 0
  fi
  local lines; lines=$(wc -l < "$CONTRACT")
  if [ "$lines" -gt "$CONTRACT_MAX" ]; then
    echo "FAIL: $CONTRACT: $lines lines exceeds cap of $CONTRACT_MAX"
    fails=$((fails+1))
  else
    echo "OK: $CONTRACT: $lines lines (cap $CONTRACT_MAX)"
  fi
  local dates; dates=$(grep -cE "$DATE_RE" "$CONTRACT" || true)
  if [ "$dates" -gt 0 ]; then
    echo "FAIL: $CONTRACT: contains $dates dated line(s) — history.md is where dated text goes"
    fails=$((fails+1))
  else
    echo "OK: $CONTRACT: no dated incident text"
  fi
}

check_skill() {
  if [ ! -f "$SKILL" ]; then
    echo "FAIL: $SKILL: not found"
    fails=$((fails+1))
    return 0
  fi
  local lines; lines=$(wc -l < "$SKILL")
  if [ "$lines" -gt "$SKILL_MAX" ]; then
    if [ "$TOLERATE_MIGRATION" -eq 1 ]; then
      echo "WARN: $SKILL: $lines lines exceeds cap of $SKILL_MAX (migration tolerance)"
    else
      echo "FAIL: $SKILL: $lines lines exceeds cap of $SKILL_MAX"
      fails=$((fails+1))
    fi
  else
    echo "OK: $SKILL: $lines lines (cap $SKILL_MAX)"
  fi
}

check_contract
check_skill

if [ "$fails" -gt 0 ]; then
  echo "lint-contract-size: $fails failure(s)"
  exit 1
fi
echo "lint-contract-size: clean"
exit 0
