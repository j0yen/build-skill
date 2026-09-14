#!/usr/bin/env bash
# slotinv_ac2_nested_reuse.sh — PRD-build-cargo-budget-per-invocation AC2.
#
# Given a slot held by a `cargo-budget.sh run` whose child re-invokes
# `cargo-budget.sh run`, when the nested call starts, then it runs without
# acquiring a second slot, the journal has 'nested reuse slot=<n>', and the
# OTHER slot stays free throughout (real fixture process tree, extracted
# from scripts/cargo-budget-selftest.sh's slotinv block so this AC pairs
# to a real file under this PRD's declared test_prefix, `slotinv`, instead
# of colliding with an unrelated PRD's bare ac<N> file — see
# verified-completed.sh's declared-prefix derivation rule).
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CB="$HERE/scripts/cargo-budget.sh"
[ -x "$CB" ] || { echo "ac2: $CB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/slotinv-ac2.XXXXXX")"
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
  cat > "$T/child.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
"$CB" run -- true
echo "\$?" > "$T/nested_rc.txt"
# hold the outer slot open a little longer so the probe below can check
# the OTHER slot is still free while nesting is in flight.
sleep 2
EOF
  chmod +x "$T/child.sh"
  "$CB" run -- "$T/child.sh" &
  outer_p=$!
  sleep 1
  if flock -n "$T/state/slot-1.lock" -c true 2>/dev/null; then
    echo yes > "$T/other_slot_free_during.txt"
  else
    echo no > "$T/other_slot_free_during.txt"
  fi
  wait "$outer_p"
)

nested_rc="$(cat "$T/nested_rc.txt" 2>/dev/null || echo x)"
other_free_during="$(cat "$T/other_slot_free_during.txt" 2>/dev/null || echo no)"
nested_row="$(jq -c 'select(.nested == true)' "$T/state/ledger.jsonl" 2>/dev/null | head -1)"
nested_journaled=0
grep -q 'cargo-budget  nested reuse slot=' "$T/journal.md" 2>/dev/null && nested_journaled=1

if [ "$nested_rc" = "0" ] && [ "$other_free_during" = "yes" ] && [ -n "$nested_row" ] \
   && [ "$(jq -r '.wait_s' <<<"$nested_row")" = "0" ] && [ "$nested_journaled" -eq 1 ]; then
  echo "ok  AC2: nested run took no second slot (other slot stayed free), wait_s=0, journaled ($nested_row)"
  exit 0
else
  echo "FAIL AC2: rc=$nested_rc other_slot_free_during=$other_free_during journaled=$nested_journaled row=$nested_row" >&2
  exit 1
fi
