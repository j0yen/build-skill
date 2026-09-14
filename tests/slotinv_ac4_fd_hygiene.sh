#!/usr/bin/env bash
# slotinv_ac4_fd_hygiene.sh — PRD-build-cargo-budget-per-invocation AC4.
#
# Given a `run` whose child backgrounds a `sleep 600` and exits, when
# `cargo-budget.sh run` returns, then `flock -n` on its slot file from a
# fresh shell succeeds immediately (no descendant kept the lock fd alive).
# Real fixture, extracted from scripts/cargo-budget-selftest.sh's slotinv
# block — see slotinv_ac2_nested_reuse.sh's header for why this file
# exists standalone.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CB="$HERE/scripts/cargo-budget.sh"
[ -x "$CB" ] || { echo "ac4: $CB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/slotinv-ac4.XXXXXX")"
trap 'rm -rf "$T"; pkill -f "sleep 600" 2>/dev/null || true' EXIT

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
  cat > "$T/child.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
( sleep 600 & )
exit 0
EOF
  chmod +x "$T/child.sh"
  "$CB" run -- "$T/child.sh"
)

if flock -n "$T/state/slot-0.lock" -c true 2>/dev/null || flock -n "$T/state/slot-1.lock" -c true 2>/dev/null; then
  echo "ok  AC4: a fresh flock -n on the used slot succeeds immediately after run returns (backgrounded grandchild did not inherit the lock fd)"
  exit 0
else
  echo "FAIL AC4: flock -n on both slot files failed right after run returned — a descendant is still holding the fd" >&2
  exit 1
fi
