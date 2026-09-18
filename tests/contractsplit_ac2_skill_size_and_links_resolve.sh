#!/usr/bin/env bash
# contractsplit_ac2_skill_size_and_links_resolve.sh —
# PRD-build-branch-contract-split AC2: given the split landed, when
# `wc -l SKILL.md` runs, then it is <= 200 and every link in it resolves.
# "Link" here is every backtick-quoted `<path>.md`/`<path>.sh` reference —
# a file this PRD explicitly documents as not-yet-existing (an AC7-style
# generated artifact, or a not-yet-written script named as future work)
# is exempted via $KNOWN_FUTURE below rather than silently ignored.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
FILE="$REPO_ROOT/SKILL.md"

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

expect "AC2: SKILL.md exists" "[ -f '$FILE' ]"
lines="$(wc -l < "$FILE" 2>/dev/null || echo 999999)"
expect "AC2: wc -l SKILL.md <= 200 (got $lines)" "[ '$lines' -le 200 ]"

# Every explicitly-future/not-yet-existing path SKILL.md is allowed to
# name without it resolving today (must still be named IN this file,
# with prose explaining why — see the Scripts section).
KNOWN_FUTURE=()

miss=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  skip=0
  for kf in "${KNOWN_FUTURE[@]:-}"; do
    [ "$p" = "$kf" ] && skip=1 && break
  done
  [ "$skip" -eq 1 ] && continue
  if [ ! -e "$REPO_ROOT/$p" ]; then
    echo "FAIL AC2: link does not resolve: $p" >&2
    miss=1
  fi
done < <(grep -oE '`[a-zA-Z0-9_./-]+\.(md|sh)`' "$FILE" | tr -d '`' | sort -u)
expect "AC2: every SKILL.md link resolves (or is an explicitly-named future path)" "[ $miss -eq 0 ]"

exit "$fail"
