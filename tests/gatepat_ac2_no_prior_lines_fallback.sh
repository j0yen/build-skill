#!/usr/bin/env bash
# gatepat_ac2_no_prior_lines_fallback.sh —
# PRD-build-gate-patience-from-queue-depth AC2: given no prior `gate`
# journal lines for the crate, when patience is computed, then
# wall_est=600 and patience is max(EXTEND_GATE_PRODUCER_LOCK_WAIT,
# depth*600). Exercised at two depths so both arms of the max() are
# proven: depth=2 (raw=1200 > floor=90 -> patience=1200) and depth=0
# (raw=0 < floor=90 -> patience=90).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatepat-common.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/gatepat_ac2.XXXXXX")"
trap 'rm -rf "$T"' EXIT

REPO="$T/mcphost"
HEAD_SHA="$(make_dirty_repo "$REPO")"
JOURNAL="$T/journal.md"   # never written to — "no prior gate lines" is the point
: > "$JOURNAL"

# --- depth=2 case: raw (1200) wins over floor (90) ------------------------
PRD_DIR2="$T/prds2"
write_prd_fixture "$PRD_DIR2" a "$REPO"
write_prd_fixture "$PRD_DIR2" b "$REPO"
FAKE_CLAIM2="$T/fake-lane-claim2.sh"
make_fake_lane_claim "$FAKE_CLAIM2" '[
  {"prd":"'"$PRD_DIR2"'/build-queue/PRD-a.md","lane":"redbaron","host":"redbaron","ts":"x","age_s":10,"state":"live","cause":"","probes":""},
  {"prd":"'"$PRD_DIR2"'/build-queue/PRD-b.md","lane":"redbaron","host":"redbaron","ts":"x","age_s":10,"state":"live","cause":"","probes":""}
]'

env GATE_PATIENCE_LANE_CLAIM="$FAKE_CLAIM2" GATE_PATIENCE_PRD_DIR="$PRD_DIR2" \
  EXTEND_GATE_JOURNAL="$JOURNAL" EXTEND_GATE_PRODUCER_LOCK_WAIT=90 \
  RUSTBUILD_SCRIPTS="$GATEPAT_RUSTBUILD_SCRIPTS" \
  "$EXTEND_GATE" "$REPO" --head "$HEAD_SHA" >"$T/out-depth2.log" 2>&1
rc_depth2=$?

expect "AC2 (depth=2): dirty-tree refusal reached (lock section ran)" "[ $rc_depth2 -eq 3 ]"
expect "AC2 (depth=2): wall_est falls back to 600 with no prior gate lines" \
  "grep -qE 'wall_est=600' \"$JOURNAL\""
expect "AC2 (depth=2): patience = depth*600 = 1200 (raw beats the 90s floor)" \
  "grep -qE 'gate  patience  \(crate=mcphost depth=2 wall_est=600 patience=1200\)' \"$JOURNAL\""

# --- depth=0 case: floor (90) wins over raw (0) ---------------------------
: > "$JOURNAL"
PRD_DIR0="$T/prds0"
mkdir -p "$PRD_DIR0/build-queue"
FAKE_CLAIM0="$T/fake-lane-claim0.sh"
make_fake_lane_claim "$FAKE_CLAIM0" '[]'

env GATE_PATIENCE_LANE_CLAIM="$FAKE_CLAIM0" GATE_PATIENCE_PRD_DIR="$PRD_DIR0" \
  EXTEND_GATE_JOURNAL="$JOURNAL" EXTEND_GATE_PRODUCER_LOCK_WAIT=90 \
  RUSTBUILD_SCRIPTS="$GATEPAT_RUSTBUILD_SCRIPTS" \
  "$EXTEND_GATE" "$REPO" --head "$HEAD_SHA" >"$T/out-depth0.log" 2>&1
rc_depth0=$?

expect "AC2 (depth=0): dirty-tree refusal reached (lock section ran)" "[ $rc_depth0 -eq 3 ]"
expect "AC2 (depth=0): patience = max(90, 0) = 90 (floor wins)" \
  "grep -qE 'gate  patience  \(crate=mcphost depth=0 wall_est=600 patience=90\)' \"$JOURNAL\""

echo "-----"
if [ "$gatepat_fail" -eq 0 ]; then
  echo "gatepat_ac2: ALL PASS"
  exit 0
else
  echo "gatepat_ac2: assertion(s) FAILED"
  exit 1
fi
