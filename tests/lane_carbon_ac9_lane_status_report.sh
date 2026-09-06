#!/usr/bin/env bash
# lane_carbon_ac9_lane_status_report.sh — PRD-build-second-lane-carbon AC9 (P2).
#
# Given lane-status.sh on either box, when it runs, then it prints both
# lanes' last tick, live claims, and stale claims.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LS="$HERE/../scripts/lane-status.sh"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$LS" ] && [ -x "$LC" ] || { echo "ac9: helper scripts not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/lane-carbon-ac9.XXXXXX")"
trap 'rm -rf "$T"' EXIT
JOURNAL_DIR="$T/journal"; mkdir -p "$JOURNAL_DIR"
J="$JOURNAL_DIR/$(date -u +%F).md"

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
cat > "$T/clone/build-queue/PRD-live.md" <<'EOF'
# PRD: live
- Status: queued
- build_target: shell
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$T/clone" push -q origin master 2>/dev/null || git -C "$T/clone" push -q origin main 2>/dev/null

"$LS" tick-summary RedBaron 4 0 "$J" >/dev/null
"$LS" tick-summary carbon 1 3 "$J" >/dev/null
"$LC" claim "$T/clone/build-queue/PRD-live.md" carbon >/dev/null

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

out=$("$LS" report --prd-dir "$T/clone" --journal-dir "$JOURNAL_DIR" --days 1)
expect "report shows RedBaron's last tick"     "grep -q 'RedBaron:.*claimed=4 skipped=0' <<<\"\$out\""
expect "report shows carbon's last tick"       "grep -q 'carbon:.*claimed=1 skipped=3' <<<\"\$out\""
expect "report shows the live claim"           "grep -q '^PRD-live: carbon .*stale=no' <<<\"\$out\""

exit $fail
