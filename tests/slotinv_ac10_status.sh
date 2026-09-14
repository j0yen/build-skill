#!/usr/bin/env bash
# slotinv_ac10_status.sh — PRD-build-cargo-budget-per-invocation AC10.
#
# Given two held slots, when `cargo-budget.sh status` runs, then it prints
# one line with each slot's pid, held seconds, and tree CPU. Real fixture,
# extracted from scripts/cargo-budget-selftest.sh's slotinv block — see
# slotinv_ac2_nested_reuse.sh's header for why this file exists standalone.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CB="$HERE/scripts/cargo-budget.sh"
[ -x "$CB" ] || { echo "ac10: $CB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/slotinv-ac10.XXXXXX")"
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
  export CARGO_BUDGET_SLOTS=2
  export CARGO_BUDGET_WAIT_MAX=30
  "$CB" run -- sleep 6 &
  "$CB" run -- sleep 6 &
  sleep 1
  "$CB" status > "$T/status.txt"
  wait
)

status="$(cat "$T/status.txt" 2>/dev/null)"
if printf '%s' "$status" | grep -Eq 'slot0=pid:[0-9]+,held_s:[0-9]+,tree_cpu_s:[0-9]+' \
   && printf '%s' "$status" | grep -Eq 'slot1=pid:[0-9]+,held_s:[0-9]+,tree_cpu_s:[0-9]+'; then
  echo "ok  AC10: both slots report pid/held_s/tree_cpu_s ('$status')"
  exit 0
else
  echo "FAIL AC10: expected both slots' pid/held_s/tree_cpu_s, got '$status'" >&2
  exit 1
fi
