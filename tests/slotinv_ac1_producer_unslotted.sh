#!/usr/bin/env bash
# slotinv_ac1_producer_unslotted.sh — PRD-build-cargo-budget-per-invocation
# AC1 / requirement 1.
#
# Given extend-gate.sh running against a fixture crate with a fake
# `autobuilder` that sleeps then runs `cargo test` via PATH, when the gate
# runs, then the cargo-budget ledger has no row whose cmd begins
# `autobuilder loop`, exactly one row whose cmd begins `cargo test` with
# parent_step=autobuilder-loop, and that row's duration is under 10s.
#
# Reuses extend-gate-phase-timing-selftest.sh's own fixture repo + fake
# toolchain (tests/fixtures/gatephase-fake) and its `run_gate()` harness
# shape, adding: (1) the REAL cargo-budget.sh + cargo-budget-bin/cargo
# shim on PATH, pointed at an isolated ledger/journal (never production
# state, never a real cargo build), and (2) a tiny fake `cargo` binary
# further down PATH for the shim to resolve as "the real cargo" so `cargo
# test` completes in ~1s instead of actually compiling anything. The
# fake autobuilder's `loop` subcommand only runs `cargo test` when
# FAKE_LOOP_RUN_CARGO_TEST is set (additive knob, added for this AC —
# every other caller of that fixture leaves it unset and is unaffected).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
EXTEND_GATE="$HERE/scripts/extend-gate.sh"
FAKE="$HERE/tests/fixtures/gatephase-fake"
[ -x "$EXTEND_GATE" ] || { echo "ac1: $EXTEND_GATE not executable" >&2; exit 2; }
[ -d "$FAKE" ] || { echo "ac1: $FAKE fixture dir missing" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/slotinv-ac1.XXXXXX")"
trap 'rm -rf "$T"' EXIT

REPO="$T/repo"
JOURNAL="$T/journal.md"
: > "$JOURNAL"
mkdir -p "$REPO/src"
cat > "$REPO/Cargo.toml" <<'EOF'
[package]
name = "slotinv-ac1-fixture"
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

# a fake `cargo` for the shim to resolve as "the real cargo" — sleeps
# briefly on `test` and exits 0; never compiles anything.
mkdir -p "$T/fakecargo"
cat > "$T/fakecargo/cargo" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  test) sleep 1; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T/fakecargo/cargo"

quiet_loadavg() { printf '%s\n' "0.10 0.05 0.01 1/200 12345" > "$1"; }
healthy_meminfo() {
  cat > "$1" <<'EOF'
MemTotal:       31000000 kB
MemFree:        20000000 kB
MemAvailable:   25000000 kB
EOF
}
quiet_loadavg "$T/loadavg"
healthy_meminfo "$T/meminfo"

PATH="$FAKE:$T/fakecargo:$PATH" \
AUTOBUILDER_CANONICAL_CARGO_TOML="$T/no-such-canonical/Cargo.toml" \
RUSTBUILD_SCRIPTS="$FAKE" \
REVIEWER_PROMPT="$T/reviewer-prompt.md" \
EXTEND_GATE_JOURNAL="$JOURNAL" \
BURST_LANE_SH="$FAKE/burst-lane.sh" \
CARGO_BUDGET="$FAKE/cargo-budget.sh" \
GATE_WEDGE_STATE_DIR="$T/gate-wedge-state" \
CARGO_BUDGET_STATE_DIR="$T/cb-state" \
CARGO_BUDGET_JOURNAL="$T/cb-journal.md" \
CARGO_BUDGET_LOADAVG="$T/loadavg" \
CARGO_BUDGET_MEMINFO="$T/meminfo" \
CARGO_BUDGET_HOSTNAME="selftest-not-redbaron" \
CARGO_BUDGET_NPROC=16 \
CARGO_BUDGET_SLOTS=2 \
FAKE_LOOP_SLEEP=1 \
FAKE_LOOP_RUN_CARGO_TEST=1 \
  bash "$EXTEND_GATE" "$REPO" --force >"$T/gate.out" 2>&1
gate_rc=$?

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; echo "--- gate.out ---" >&2; tail -40 "$T/gate.out" >&2; fail=1; fi
}

expect "AC1: extend-gate.sh exits 0 on the fake gate" "[ $gate_rc -eq 0 ]"

no_loop_row=1
grep -q 'autobuilder loop' "$T/cb-journal.md" 2>/dev/null && no_loop_row=0
if [ -f "$T/cb-state/ledger.jsonl" ]; then
  jq -e 'select(.cmd | test("autobuilder loop"))' "$T/cb-state/ledger.jsonl" >/dev/null 2>&1 && no_loop_row=0
fi
expect "AC1: no cargo-budget ledger/journal row names 'autobuilder loop' (the producer ran unslotted)" "[ $no_loop_row -eq 1 ]"

cargo_rows="$(jq -c 'select(.cmd | endswith("cargo test"))' "$T/cb-state/ledger.jsonl" 2>/dev/null)"
cargo_row_count="$(printf '%s' "$cargo_rows" | grep -c . || true)"
expect "AC1: exactly one ledger row's cmd ends 'cargo test'" "[ '$cargo_row_count' -eq 1 ]"
expect "AC1: that row's parent_step is autobuilder-loop" "[ \"\$(jq -r '.parent_step' <<<'$cargo_rows')\" = 'autobuilder-loop' ]"
expect "AC1: that row's duration is under 10s" \
  "[ \"\$(jq -r '(( .ts_end | strptime(\"%Y-%m-%dT%H:%M:%SZ\") | mktime) - (.ts_start | strptime(\"%Y-%m-%dT%H:%M:%SZ\") | mktime))' <<<'$cargo_rows')\" -lt 10 ]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "slotinv_ac1_producer_unslotted: ALL PASSED"
else
  echo "slotinv_ac1_producer_unslotted: FAILURES ABOVE" >&2
fi
exit "$fail"
