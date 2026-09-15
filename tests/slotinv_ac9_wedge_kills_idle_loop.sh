#!/usr/bin/env bash
# slotinv_ac9_wedge_kills_idle_loop.sh — PRD-build-cargo-budget-per-invocation
# AC9 / requirement 7.
#
# Given the gate's `autobuilder loop` step under gate-wedge.sh with
# EXTEND_GATE_LOOP_WALL_S small and a fake loop that idles well past it,
# when the wall passes, then the loop is killed, the gate blocks with
# `proof-receipt — autobuilder loop wedged (wall=<s> cpu=<s>)`, and no
# cargo-budget slot is held afterwards.
#
# Reuses extend-gate-phase-timing-selftest.sh's own fixture repo + fake
# toolchain (tests/fixtures/gatephase-fake) and its `run_gate()` harness
# shape — see slotinv_ac1_producer_unslotted.sh's header for why this
# lives as its own file rather than folded into that fixture's shared
# selftest. gate-wedge.sh itself runs for real (not faked); only its
# probe cadence is sped up via its own documented test-only env knobs
# (see scripts/gate-wedge.sh's header), same convention as
# scripts/gate-wedge-selftest.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
EXTEND_GATE="$HERE/scripts/extend-gate.sh"
FAKE="$HERE/tests/fixtures/gatephase-fake"
[ -x "$EXTEND_GATE" ] || { echo "ac9: $EXTEND_GATE not executable" >&2; exit 2; }
[ -d "$FAKE" ] || { echo "ac9: $FAKE fixture dir missing" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/slotinv-ac9.XXXXXX")"
trap 'rm -rf "$T"' EXIT

REPO="$T/repo"
JOURNAL="$T/journal.md"
: > "$JOURNAL"
mkdir -p "$REPO/src"
cat > "$REPO/Cargo.toml" <<'EOF'
[package]
name = "slotinv-ac9-fixture"
version = "0.1.0"
edition = "2021"
license = "MIT"
EOF
cat > "$REPO/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 { a + b }
EOF
echo "/target" > "$REPO/.gitignore"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@t add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m init
echo "fake reviewer prompt" > "$T/reviewer-prompt.md"

PATH="$FAKE:$PATH" \
AUTOBUILDER_CANONICAL_CARGO_TOML="$T/no-such-canonical/Cargo.toml" \
RUSTBUILD_SCRIPTS="$FAKE" \
REVIEWER_PROMPT="$T/reviewer-prompt.md" \
EXTEND_GATE_JOURNAL="$JOURNAL" \
BURST_LANE_SH="$FAKE/burst-lane.sh" \
CARGO_BUDGET="$FAKE/cargo-budget.sh" \
GATE_WEDGE_STATE_DIR="$T/gate-wedge-state" \
CARGO_BUDGET_STATE_DIR="$T/cb-state" \
CARGO_BUDGET_JOURNAL="$T/cb-journal.md" \
EXTEND_GATE_LOOP_WALL_S=3 \
GATE_WEDGE_PROBE_DELAY_S=2 \
GATE_WEDGE_PROBE_EVERY_S=2 \
GATE_WEDGE_SNAPSHOT_GAP_S=2 \
FAKE_LOOP_SLEEP=30 \
  timeout 60 bash "$EXTEND_GATE" "$REPO" --force >"$T/gate.out" 2>&1
gate_rc=$?

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; echo "--- gate.out ---" >&2; tail -60 "$T/gate.out" >&2; fail=1; fi
}

expect "AC9: extend-gate.sh does not hang forever (finished within the 60s timeout)" "[ $gate_rc -ne 124 ]"
expect "AC9: the wedge note is printed naming wall= and cpu=" \
  "grep -Eq 'proof-receipt . autobuilder loop wedged \(wall=[0-9]+s cpu=-?[0-9]+ io=-?[0-9]+ remote=(unsampled|-?[0-9]+) waits=[0-9]+\)' '$T/gate.out'"
expect "AC9: gate-wedge wrote at least one wedge receipt for autobuilder-loop" \
  "ls '$T/gate-wedge-state'/*-autobuilder-loop-wedge-receipt.json >/dev/null 2>&1"
expect "AC9: no leaked fake-loop sleep process remains" "! pgrep -f 'fixtures/gatephase-fake/autobuilder loop' >/dev/null 2>&1"

no_slot_held=1
for f in "$T/cb-state"/slot-*.lock; do
  [ -e "$f" ] || continue
  flock -n "$f" -c true 2>/dev/null || no_slot_held=0
done
expect "AC9: no cargo-budget slot is held after the gate returns" "[ $no_slot_held -eq 1 ]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "slotinv_ac9_wedge_kills_idle_loop: ALL PASSED"
else
  echo "slotinv_ac9_wedge_kills_idle_loop: FAILURES ABOVE" >&2
fi
exit "$fail"
