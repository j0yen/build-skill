#!/usr/bin/env bash
# contractsplit_ac4_history_covers_every_presplit_date.sh —
# PRD-build-branch-contract-split AC4: given every dated paragraph in the
# pre-split SKILL.md, when history.md is grepped for each date, then each
# is present. "Pre-split SKILL.md" is read from git commit 2e66b34 — the
# last commit where SKILL.md was untouched by this PRD (step 2's own
# message says so explicitly: "SKILL.md itself is untouched this step")
# — rather than a frozen date list, so this test keeps working even if a
# later PRD touches SKILL.md/history.md again.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
PRESPLIT_REF="2e66b34"
HISTORY="$REPO_ROOT/docs/history.md"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then
    echo "ok  $label"
  else
    echo "FAIL $label" >&2
    fail=1
  fi
}

expect "AC4: pre-split SKILL.md is reachable at $PRESPLIT_REF" \
  "git -C '$REPO_ROOT' cat-file -e ${PRESPLIT_REF}:SKILL.md 2>/dev/null"
expect "AC4: docs/history.md exists" "[ -f '$HISTORY' ]"

presplit_dates="$(git -C "$REPO_ROOT" show "${PRESPLIT_REF}:SKILL.md" 2>/dev/null \
  | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' | sort -u)"
history_dates="$(grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$HISTORY" 2>/dev/null | sort -u)"

missing="$(comm -23 <(printf '%s\n' "$presplit_dates") <(printf '%s\n' "$history_dates"))"
if [ -n "$missing" ]; then
  echo "FAIL AC4: dates present in pre-split SKILL.md but missing from docs/history.md:" >&2
  printf '%s\n' "$missing" >&2
  fail=1
else
  echo "ok  AC4: every unique date in the pre-split SKILL.md greps present in docs/history.md"
fi

exit "$fail"
