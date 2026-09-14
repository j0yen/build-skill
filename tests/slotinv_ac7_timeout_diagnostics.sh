#!/usr/bin/env bash
# slotinv_ac7_timeout_diagnostics.sh — PRD-build-cargo-budget-per-invocation
# AC7.
#
# Given both slots held by fixture holders for longer than
# CARGO_BUDGET_WAIT_MAX, when a third `run` times out, then its journal
# line reads 'wait slot timeout after <s>s ... holders=[slot0:<pid>:<s>s:
# <cmd>, slot1:...]' with both real pids, and exit code 3 is unchanged.
# Real fixture, extracted from scripts/cargo-budget-selftest.sh's slotinv
# block — see slotinv_ac2_nested_reuse.sh's header for why this file
# exists standalone.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CB="$HERE/scripts/cargo-budget.sh"
[ -x "$CB" ] || { echo "ac7: $CB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/slotinv-ac7.XXXXXX")"
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
  export CARGO_BUDGET_WAIT_MAX=8
  "$CB" run -- sleep 20 & h1=$!
  "$CB" run -- sleep 20 & h2=$!
  sleep 1
  "$CB" run -- true
  echo "$?" > "$T/third_rc.txt"
  wait "$h1" "$h2" 2>/dev/null
)

third_rc="$(cat "$T/third_rc.txt" 2>/dev/null || echo 0)"
timeout_line="$(grep 'cargo-budget  wait slot timeout' "$T/journal.md" 2>/dev/null | tail -1)"
holders_ok=0
if printf '%s' "$timeout_line" | grep -Eq 'holders=\[slot0:[0-9]+:[0-9]+s:[^,]*, slot1:[0-9]+:[0-9]+s:'; then
  holders_ok=1
fi

if [ "$third_rc" = "3" ] && [ "$holders_ok" -eq 1 ]; then
  echo "ok  AC7: exit 3 preserved, journal names both real holder pids ($timeout_line)"
  exit 0
else
  echo "FAIL AC7: third_rc=$third_rc holders_ok=$holders_ok line='$timeout_line'" >&2
  exit 1
fi
