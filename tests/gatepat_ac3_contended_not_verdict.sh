#!/usr/bin/env bash
# gatepat_ac3_contended_not_verdict.sh —
# PRD-build-gate-patience-from-queue-depth AC3/AC4: given a fixture holder
# that keeps the crate lock for longer than patience, when a second gate
# runs, then it exits 4, the journal has exactly one
# `gate  <slug>  contended  (... holder_pid=<pid> holder_slug=<slug> ...)`
# line, and no `gate ... block`, `gate-block`, or `verdict=block` line for
# that slug (AC3); and (AC4) the manifest-facing contract for this exit —
# `next: gate-retry`, `blockers` untouched — is the one gate-then-land.sh
# and SKILL.md actually document (grep conformance, since the manifest
# WRITE itself is the calling branch agent's Phase 7 step, not something
# extend-gate.sh or gate-then-land.sh performs directly).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatepat-common.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/gatepat_ac3.XXXXXX")"
trap 'kill "${holder_job:-0}" 2>/dev/null; rm -rf "$T"' EXIT

REPO="$T/mcphost"
HEAD_SHA="$(make_dirty_repo "$REPO")"
JOURNAL="$T/journal.md"
: > "$JOURNAL"

LOCKFILE="$REPO/.git/autobuilder-integrate.lock"
( exec 9>"$LOCKFILE"; flock -x 9; sleep 6 ) &
holder_job=$!
sleep 0.3

env EXTEND_GATE_JOURNAL="$JOURNAL" EXTEND_GATE_PATIENCE_OVERRIDE=1 \
  RUSTBUILD_SCRIPTS="$GATEPAT_RUSTBUILD_SCRIPTS" \
  "$EXTEND_GATE" "$REPO" --head "$HEAD_SHA" --slug my-branch-slug >"$T/out.log" 2>&1
rc=$?

expect "AC3: exits 4 (contended)" "[ $rc -eq 4 ]"
expect "AC3: exactly one contended line naming crate/holder_pid/holder_slug/waited_s" \
  "[ \"\$(grep -cE 'gate  my-branch-slug  contended  \(crate=mcphost holder_pid=[0-9,]+ holder_slug=[a-z]+ holder_age_s=[a-z0-9]+ waited_s=[0-9]+\)' \"$JOURNAL\")\" -eq 1 ]"
expect "AC3: no 'gate ... block' verdict line was ever written" "! grep -qE 'gate  \S+  block  \(' \"$JOURNAL\""
expect "AC3: no literal 'gate-block' token in the journal" "! grep -q 'gate-block' \"$JOURNAL\""
expect "AC3: no literal 'verdict=block' token in the journal" "! grep -q 'verdict=block' \"$JOURNAL\""

wait "$holder_job" 2>/dev/null || true

# --- AC4: the documented manifest contract for this exit ------------------
SKILL_MD="$HERE/../SKILL.md"
GATE_THEN_LAND="$GATEPAT_SCRIPTS/gate-then-land.sh"
expect "AC4: SKILL.md documents next: gate-retry for this contended exit" \
  "grep -q 'next: gate-retry' \"$SKILL_MD\""
expect "AC4: SKILL.md documents blockers stay untouched on this exit" \
  "tr '\n' ' ' < \"$SKILL_MD\" | grep -qiE 'blockers[^a-zA-Z]*untouched'"
expect "AC4: gate-then-land.sh's own exit-4 path records outcome=contended, next=gate-retry" \
  "grep -q 'outcome=contended, next=gate-retry' \"$GATE_THEN_LAND\""

echo "-----"
if [ "$gatepat_fail" -eq 0 ]; then
  echo "gatepat_ac3: ALL PASS"
  exit 0
else
  echo "gatepat_ac3: assertion(s) FAILED"
  exit 1
fi
