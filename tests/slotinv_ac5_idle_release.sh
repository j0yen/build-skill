#!/usr/bin/env bash
# slotinv_ac5_idle_release.sh — PRD-build-cargo-budget-per-invocation AC5.
#
# Given a fixture producer that idles 8s with no cargo child (idle
# threshold 3s), when the threshold passes, then the journal has an
# idle-release line, the slot is acquirable by another `run`, and the
# producer keeps running to completion with its own exit code preserved.
# Real fixture, extracted from scripts/cargo-budget-selftest.sh's slotinv
# block — see slotinv_ac2_nested_reuse.sh's header for why this file
# exists standalone.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CB="$HERE/scripts/cargo-budget.sh"
[ -x "$CB" ] || { echo "ac5: $CB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/slotinv-ac5.XXXXXX")"
trap 'rm -rf "$T"' EXIT

quiet_loadavg() { printf '%s\n' "0.10 0.05 0.01 1/200 12345" > "$1"; }
healthy_meminfo() {
  cat > "$1" <<'EOF'
MemTotal:       31000000 kB
MemFree:        20000000 kB
MemAvailable:   25000000 kB
EOF
}
common_env() {
  local dir="$1"
  export CARGO_BUDGET_STATE_DIR="$dir/state"
  export CARGO_BUDGET_JOURNAL="$dir/journal.md"
  export CARGO_BUDGET_NPROC=16
  export CARGO_BUDGET_HOSTNAME="selftest-not-redbaron"
  quiet_loadavg "$dir/loadavg"
  export CARGO_BUDGET_LOADAVG="$dir/loadavg"
  healthy_meminfo "$dir/meminfo"
  export CARGO_BUDGET_MEMINFO="$dir/meminfo"
  unset CARGO_BUDGET_SLOTS CARGO_BUDGET_WAIT_MAX CARGO_BUDGET_MIN_AVAIL_GB \
        CARGO_BUDGET_TEST_THREADS CARGO_BUDGET_MAX_LOAD CARGO_BUILD_JOBS \
        RUST_TEST_THREADS 2>/dev/null || true
}

(
  common_env "$T"
  export CARGO_BUDGET_SLOTS=1
  export CARGO_BUDGET_WAIT_MAX=30
  export CARGO_BUDGET_IDLE_HOLD_S=3
  export CARGO_BUDGET_IDLE_CPU_PCT=5
  cat > "$T/idle_producer.sh" <<'EOF'
#!/usr/bin/env bash
sleep 8
exit 7
EOF
  chmod +x "$T/idle_producer.sh"
  "$CB" run -- "$T/idle_producer.sh" &
  p1=$!
  # once idle-released (~3s in), a second run must be able to take the
  # (now sole) slot while the first producer is still sleeping.
  sleep 5
  t0=$(date +%s)
  "$CB" run -- true
  second_rc=$?
  t1=$(date +%s)
  echo "$((t1 - t0))" > "$T/second_wall.txt"
  echo "$second_rc" > "$T/second_rc.txt"
  wait "$p1"
  echo "$?" > "$T/first_rc.txt"
)

idle_journaled=0
grep -q 'cargo-budget  idle-release slot=' "$T/journal.md" 2>/dev/null && idle_journaled=1
second_wall="$(cat "$T/second_wall.txt" 2>/dev/null || echo 999)"
second_rc="$(cat "$T/second_rc.txt" 2>/dev/null || echo 1)"
first_rc="$(cat "$T/first_rc.txt" 2>/dev/null || echo x)"

if [ "$idle_journaled" -eq 1 ] && [ "$second_rc" = "0" ] && [ "$second_wall" -le 3 ] && [ "$first_rc" = "7" ]; then
  echo "ok  AC5: journaled after idle threshold, freed slot acquired by another run within ${second_wall}s, producer's own exit code (7) preserved"
  exit 0
else
  echo "FAIL AC5: idle_journaled=$idle_journaled second_rc=$second_rc second_wall=${second_wall}s first_rc=$first_rc" >&2
  exit 1
fi
