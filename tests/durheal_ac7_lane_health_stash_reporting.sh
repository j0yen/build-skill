#!/usr/bin/env bash
# durheal_ac7_lane_health_stash_reporting.sh — PRD-build-classification-
# durable-heal AC7.
#
# Given a fixture PRDs checkout with two stashes, one aged 30h, When
# lane-status.sh tick-summary runs, Then the line carries `stashes=2
# oldest=30h` and one `stash-stale` journal line naming the message.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LS="$HERE/../scripts/lane-status.sh"
[ -x "$LS" ] || { echo "ac7: $LS not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/durheal-ac7.XXXXXX")"
trap 'rm -rf "$T"' EXIT

git init -q "$T/prds"
gc() { git -C "$T/prds" -c user.email=t@t -c user.name=t "$@"; }
printf '# MANIFEST\n' > "$T/prds/MANIFEST.md"
gc add -A
gc commit -qm init

# Stash 1: fresh (a few seconds old).
echo "fresh dirt" > "$T/prds/fresh.txt"
gc add -A
gc stash push -q -m "fresh stash"

# Stash 2: backdated to 30h old, so it must be named as stale. `git stash
# push` builds its commits via plumbing that honors GIT_AUTHOR_DATE/
# GIT_COMMITTER_DATE the same as any other commit.
echo "stale dirt" > "$T/prds/stale.txt"
gc add -A
old_ts="$(( $(date -u +%s) - 30*3600 ))"
old_date="$(date -u -d "@$old_ts" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -r "$old_ts" '+%Y-%m-%dT%H:%M:%SZ')"
GIT_AUTHOR_DATE="$old_date" GIT_COMMITTER_DATE="$old_date" \
  git -C "$T/prds" -c user.email=t@t -c user.name=t stash push -q -m "stale stash from a dead rebase"

JOURNAL="$T/journal.md"
PRD_DIR="$T/prds" "$LS" tick-summary redbaron 1 0 "$JOURNAL" >/dev/null

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

expect "lane-health line carries stashes=2" "grep -q 'stashes=2' '$JOURNAL'"
expect "lane-health line carries oldest=30h" "grep -qE 'oldest=(29|30|31)h' '$JOURNAL'"
expect "one stash-stale line journaled" "[ \"\$(grep -c 'lane-health  stash-stale' '$JOURNAL')\" -eq 1 ]"
expect "stash-stale line names the message" "grep -q 'lane-health  stash-stale' '$JOURNAL' && grep -q 'stale stash from a dead rebase' '$JOURNAL'"

exit $fail
