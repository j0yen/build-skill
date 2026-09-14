#!/usr/bin/env bash
# slotinv_ac3_dead_holder_pid.sh — PRD-build-cargo-budget-per-invocation AC3.
#
# Given the same nesting shape as AC2 but with CARGO_BUDGET_HOLDER_PID
# pointing at a dead pid, when the nested call starts, then it acquires a
# slot normally and the ledger row has nested=false. Real fixture,
# extracted from scripts/cargo-budget-selftest.sh's slotinv block — see
# slotinv_ac2_nested_reuse.sh's header for why this file exists standalone.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CB="$HERE/scripts/cargo-budget.sh"
[ -x "$CB" ] || { echo "ac3: $CB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/slotinv-ac3.XXXXXX")"
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
  # a pid that is guaranteed dead by the time we use it.
  sleep 0.1 & dead_pid=$!
  wait "$dead_pid" 2>/dev/null
  export CARGO_BUDGET_HELD_SLOT=0
  export CARGO_BUDGET_HOLDER_PID="$dead_pid"
  "$CB" run -- true
)

dead_row="$(jq -c 'select(true)' "$T/state/ledger.jsonl" 2>/dev/null | tail -1)"
if [ "$(jq -r '.nested' <<<"$dead_row")" = "false" ]; then
  echo "ok  AC3: stale CARGO_BUDGET_HOLDER_PID (already-dead) acquires normally, nested=false ($dead_row)"
  exit 0
else
  echo "FAIL AC3: expected nested=false, got $dead_row" >&2
  exit 1
fi
