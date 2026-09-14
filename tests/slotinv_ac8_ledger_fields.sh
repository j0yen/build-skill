#!/usr/bin/env bash
# slotinv_ac8_ledger_fields.sh — PRD-build-cargo-budget-per-invocation AC8.
#
# Given any completed `run`, when the ledger row is read, then it carries
# parent_step, nested, tree_cpu_s, idle_released; and `cargo-budget.sh
# summary` prints holds=/idle_slot_s=/nested=/timeouts= with the correct
# counts for a fixture ledger. Real fixture, extracted from scripts/
# cargo-budget-selftest.sh's slotinv block — see slotinv_ac2_nested_reuse
# .sh's header for why this file exists standalone.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CB="$HERE/scripts/cargo-budget.sh"
[ -x "$CB" ] || { echo "ac8: $CB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/slotinv-ac8.XXXXXX")"
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
  export CARGO_BUDGET_PARENT_STEP="autobuilder-loop"
  "$CB" run -- true
)

row="$(tail -1 "$T/state/ledger.jsonl" 2>/dev/null)"
fields_ok=0
if [ "$(jq -r '.parent_step' <<<"$row")" = "autobuilder-loop" ] \
   && jq -e 'has("nested") and has("tree_cpu_s") and has("idle_released")' <<<"$row" >/dev/null 2>&1; then
  fields_ok=1
fi
summary="$(CARGO_BUDGET_STATE_DIR="$T/state" "$CB" summary --since 0 2>/dev/null)"
summary_ok=0
printf '%s' "$summary" | grep -Eq 'holds=[0-9]+ idle_slot_s=[0-9.]+ nested=[0-9]+ timeouts=[0-9]+' && summary_ok=1

if [ "$fields_ok" -eq 1 ] && [ "$summary_ok" -eq 1 ]; then
  echo "ok  AC8: row carries parent_step/nested/tree_cpu_s/idle_released; summary carries holds=/idle_slot_s=/nested=/timeouts= ('$summary')"
  exit 0
else
  echo "FAIL AC8: fields_ok=$fields_ok summary_ok=$summary_ok row='$row' summary='$summary'" >&2
  exit 1
fi
