#!/usr/bin/env bash
# gatepat_ac7_tick_summary_gate_queue.sh —
# PRD-build-gate-patience-from-queue-depth AC7: given a tick with two
# contended gates and one real verdict on one crate, when
# `lane-status.sh tick-summary` runs, then the journal has
# `gate-queue: crate=<name> depth=3 holder=<slug> hold_max_s=<s>
# contended=2 exhausted=0`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatepat-common.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/gatepat_ac7.XXXXXX")"
trap 'rm -rf "$T"' EXIT

JOURNAL="$T/journal.md"
PRD_DIR="$T/prds"
mkdir -p "$PRD_DIR/build-queue"

cat > "$JOURNAL" <<'EOF'
2026-09-15T10:00:00Z  gate  patience  (crate=mcphost depth=2 wall_est=700 patience=1400)
2026-09-15T10:00:05Z  gate  branch-a  contended  (crate=mcphost holder_pid=123 holder_slug=branch-c holder_age_s=900 waited_s=1400)
2026-09-15T10:05:00Z  gate  patience  (crate=mcphost depth=2 wall_est=700 patience=1400)
2026-09-15T10:05:05Z  gate  branch-b  contended  (crate=mcphost holder_pid=123 holder_slug=branch-c holder_age_s=1200 waited_s=1400)
2026-09-15T10:10:00Z  gate  mcphost  pass  (head=abc123 base=def456 receipts=25 blocking= wall=1541s scope=branch lock_wait=0s cargo=burst:0/local:1)
EOF

STASH_D="$T/stash-target"
mkdir -p "$STASH_D"
git -C "$STASH_D" init -q
git -C "$STASH_D" -c user.name=g -c user.email=g@g commit -q --allow-empty -m init

env PRD_DIR="$STASH_D" BUILD_STATE_DIR="$T/state" \
  "$LANE_STATUS" tick-summary redbaron 0 0 "$JOURNAL" >"$T/out.log" 2>&1
rc=$?
expect "AC7: tick-summary exits 0" "[ $rc -eq 0 ]"
expect "AC7: journal has the gate-queue line with depth=3 holder=branch-c contended=2 exhausted=0" \
  "grep -qE 'gate-queue: crate=mcphost depth=3 holder=branch-c hold_max_s=1541 contended=2 exhausted=0' \"$JOURNAL\""

# --- exhausted counter: a land-retries-exhausted line for a slug this
# tick already saw contended is attributed to that slug's crate ----------
JOURNAL2="$T/journal2.md"
cat > "$JOURNAL2" <<'EOF'
2026-09-15T11:00:00Z  gate  branch-x  contended  (crate=widget holder_pid=1 holder_slug=other holder_age_s=10 waited_s=5)
2026-09-15T11:05:00Z  gate-then-land  branch-x  land-retries-exhausted  (attempts=3 main_shas=a,b,c)
EOF
env PRD_DIR="$STASH_D" BUILD_STATE_DIR="$T/state2" \
  "$LANE_STATUS" tick-summary redbaron 0 0 "$JOURNAL2" >"$T/out2.log" 2>&1
expect "AC7 (exhausted): gate-queue line attributes land-retries-exhausted to the right crate" \
  "grep -qE 'gate-queue: crate=widget depth=1 holder=other hold_max_s=10 contended=1 exhausted=1' \"$JOURNAL2\""

echo "-----"
if [ "$gatepat_fail" -eq 0 ]; then
  echo "gatepat_ac7: ALL PASS"
  exit 0
else
  echo "gatepat_ac7: assertion(s) FAILED"
  exit 1
fi
