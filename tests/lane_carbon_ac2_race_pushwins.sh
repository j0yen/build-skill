#!/usr/bin/env bash
# lane_carbon_ac2_race_pushwins.sh — PRD-build-second-lane-carbon AC2.
#
# Given both lanes racing to claim one PRD within seconds, when both push,
# then exactly one push lands, the loser's rebase shows the winner's
# claim, and the loser skips with a journal-visible reason (exit 2).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$LC" ] || { echo "ac2: $LC not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/lane-carbon-ac2.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
cat > "$T/clone/build-queue/PRD-race.md" <<'EOF'
# PRD: race
- Status: queued
- build_target: shell
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$T/clone" push -q origin master 2>/dev/null || git -C "$T/clone" push -q origin main 2>/dev/null

PRD="$T/clone/build-queue/PRD-race.md"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# RedBaron wins the race (claims + pushes first).
out1=$("$LC" claim "$PRD" RedBaron); rc1=$?
expect "winner (RedBaron) claims cleanly (exit 0)" "[ $rc1 -eq 0 ]"
expect "winner's claim landed on origin"           "grep -q '^- Lane: RedBaron' \"\$PRD\""

# carbon races for the same PRD after losing — its local view is stale
# (it never re-pulled), so its claim attempt must lose and skip.
set +e
out2=$("$LC" claim "$PRD" carbon 2>&1); rc2=$?
set -e
expect "loser (carbon) exits 2 (not blocked, just skipped)" "[ $rc2 -eq 2 ]"
expect "loser's message names the winner's claim"           "grep -q '^held: RedBaron' <<<\"\$out2\""
expect "repo stays clean after the loser's attempt"         "[ -z \"\$(git -C \"$T/clone\" status --porcelain)\" ]"

exit $fail
