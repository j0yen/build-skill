#!/usr/bin/env bash
# slotinv_ac6_idle_release_skipped_live_cargo.sh — PRD-build-cargo-budget-
# per-invocation AC6.
#
# Given a fixture producer that idles 8s but has a running `cargo`
# descendant (fake cargo sleeping), when the idle threshold (3s) passes,
# then no idle-release line is written and the slot stays held until
# cargo exits. Real fixture, extracted from scripts/cargo-budget-
# selftest.sh's slotinv block — see slotinv_ac2_nested_reuse.sh's header
# for why this file exists standalone.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CB="$HERE/scripts/cargo-budget.sh"
[ -x "$CB" ] || { echo "ac6: $CB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/slotinv-ac6.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

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
  # tree_has_cargo_or_rustc matches on /proc/<pid>/comm, which the kernel
  # sets from the EXECUTED FILE's own basename — a `#!/usr/bin/env bash`
  # script named "cargo" would actually run as comm=bash (the interpreter
  # the shebang re-execs to), not comm=cargo. `sleep` on this box is a
  # uutils coreutils multi-call binary that self-dispatches by its own
  # argv[0]/basename (so a copy named "cargo" refuses to run: "unknown
  # program 'cargo'") — use `perl`, a real standalone ELF interpreter that
  # doesn't self-dispatch by name, copied to a file literally named
  # `cargo` so execve-ing it directly (no shebang indirection) gives it
  # real comm=cargo, the same way a real `cargo` binary would show up.
  cp "$(command -v perl)" "$T/bin/cargo"
  chmod +x "$T/bin/cargo"
  cat > "$T/idle_producer_with_cargo.sh" <<EOF
#!/usr/bin/env bash
"$T/bin/cargo" -e 'sleep 8' &
wait
EOF
  chmod +x "$T/idle_producer_with_cargo.sh"
  "$CB" run -- "$T/idle_producer_with_cargo.sh" &
  p1=$!
  sleep 6
  # the sole slot must still be held (idle-release must NOT have fired).
  if flock -n "$T/state/slot-0.lock" -c true 2>/dev/null; then
    echo free > "$T/slot_state.txt"
  else
    echo held > "$T/slot_state.txt"
  fi
  wait "$p1"
)

slot_state="$(cat "$T/slot_state.txt" 2>/dev/null || echo free)"
idle_journaled=0
grep -q 'cargo-budget  idle-release slot=' "$T/journal.md" 2>/dev/null && idle_journaled=1

if [ "$slot_state" = "held" ] && [ "$idle_journaled" -eq 0 ]; then
  echo "ok  AC6: slot stayed held (no idle-release line) while a live 'cargo' descendant existed"
  exit 0
else
  echo "FAIL AC6: expected slot held / no idle-release line, got slot_state=$slot_state idle_journaled=$idle_journaled" >&2
  exit 1
fi
