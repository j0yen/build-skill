#!/usr/bin/env bash
# lane_carbon_ac3_target_exclusivity.sh — PRD-build-second-lane-carbon AC3.
#
# Given a live claim naming build_into repo R, when the other lane selects
# a second PRD targeting R, then it defers that PRD this tick and the
# exclusivity skip is visible in the predicate's own output (what the
# tick journals).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
LP="$HERE/../scripts/lane-predicate.sh"
[ -x "$LC" ] && [ -x "$LP" ] || { echo "ac3: helper scripts not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/lane-carbon-ac3.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
cat > "$T/clone/build-queue/PRD-first.md" <<'EOF'
# PRD: first
- Status: queued
- build_target: shell
- build_into: /tmp/shared-target-repo
EOF
cat > "$T/clone/build-queue/PRD-second.md" <<'EOF'
# PRD: second
- Status: queued
- build_target: shell
- build_into: /tmp/shared-target-repo
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$T/clone" push -q origin master 2>/dev/null || git -C "$T/clone" push -q origin main 2>/dev/null

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

"$LC" claim "$T/clone/build-queue/PRD-first.md" RedBaron >/dev/null

set +e
out=$("$LP" select "$T/clone/build-queue/PRD-second.md" carbon "$T/clone" 2>&1); rc=$?
set -e
expect "second PRD is deferred this tick (exit 1)"       "[ $rc -eq 1 ]"
expect "the skip names the busy target and holding lane" "grep -q '^skip: busy: first RedBaron' <<<\"\$out\""

exit $fail
