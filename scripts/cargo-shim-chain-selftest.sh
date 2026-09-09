#!/usr/bin/env bash
# cargo-shim-chain-selftest.sh — proves cargo-budget-bin/cargo and
# burst-lane-bin/cargo compose correctly when BOTH are on PATH
# (PRD-build-cargo-shim-reexec-loop). Two rust-extend branches hit a
# silent, indefinite hang this tick: each shim's real_cargo() only
# skipped its OWN directory when resolving the next `cargo` on PATH, so
# with both shim dirs present they resolved into each other forever
# (burst-lane-bin -> cargo-budget-bin -> burst-lane-bin -> ...), never
# reaching the real ~/.cargo/bin/cargo. No error, no exit — just a stuck
# process. This selftest reproduces that exact PATH shape in both
# orderings and asserts, under a hard timeout, that cargo actually runs.
#
# Uses the REAL system cargo (not a fake) — `cargo --version` and `cargo
# check` are both cheap/no-compile per the shims' own routing comments
# (neither is ever routed through cargo-budget.sh or burst-lane.sh), so
# this stays fast and never triggers the OOM/load concerns that
# cargo-budget-selftest.sh is careful to avoid for `cargo test`/`build`.
# BURST_LANE is deliberately left unset so burst-lane-bin/cargo never
# tries to reach burst-lane.sh (no session, no network) — only its
# PATH-walking real_cargo() is under test here.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BUDGET_DIR="$HERE/cargo-budget-bin"
BURST_DIR="$HERE/burst-lane-bin"
TIMEOUT_S="${CARGO_SHIM_CHAIN_SELFTEST_TIMEOUT:-20}"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

[ -x "$BUDGET_DIR/cargo" ] || { echo "selftest: $BUDGET_DIR/cargo not executable" >&2; exit 2; }
[ -x "$BURST_DIR/cargo" ] || { echo "selftest: $BURST_DIR/cargo not executable" >&2; exit 2; }
command -v cargo >/dev/null 2>&1 || { echo "selftest: no real cargo on ambient PATH, cannot run" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cargo-shim-chain-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# --- trivial fixture crate, written directly (no `cargo init` needed) -------
FIXTURE="$T/fixture-crate"
mkdir -p "$FIXTURE/src"
cat > "$FIXTURE/Cargo.toml" <<'EOF'
[package]
name = "cargo-shim-chain-selftest-fixture"
version = "0.1.0"
edition = "2021"

[dependencies]
EOF
cat > "$FIXTURE/src/main.rs" <<'EOF'
fn main() {
    println!("cargo-shim-chain-selftest-fixture");
}
EOF

# --- one order under test: run `cargo --version` and `cargo check` under
# the given PATH, each guarded by a hard timeout so a re-exec loop fails
# loudly (a non-zero exit + message) instead of hanging the whole tick. ---
run_order() {
  local label="$1" test_path="$2"
  local version_out version_rc check_rc

  version_out="$(cd "$FIXTURE" && PATH="$test_path" timeout -k 2 "$TIMEOUT_S" cargo --version 2>&1)"
  version_rc=$?
  expect "$label: cargo --version completes within ${TIMEOUT_S}s (rc=$version_rc)" "[ $version_rc -eq 0 ]"
  expect "$label: cargo --version did not time out" "[ $version_rc -ne 124 ] && [ $version_rc -ne 137 ]"
  expect "$label: cargo --version printed a cargo version" "grep -qi '^cargo ' <<<\"$version_out\""

  (cd "$FIXTURE" && PATH="$test_path" timeout -k 2 "$TIMEOUT_S" cargo check --offline >/dev/null 2>&1)
  check_rc=$?
  expect "$label: cargo check completes within ${TIMEOUT_S}s (rc=$check_rc)" "[ $check_rc -eq 0 ]"
  expect "$label: cargo check did not time out" "[ $check_rc -ne 124 ] && [ $check_rc -ne 137 ]"
}

# AC1: documented order — cargo-budget-bin first, then burst-lane-bin.
run_order "documented order (budget,burst-lane)" "$BUDGET_DIR:$BURST_DIR:$PATH"

# AC2: reverse order — burst-lane-bin first, then cargo-budget-bin.
run_order "reverse order (burst-lane,budget)" "$BURST_DIR:$BUDGET_DIR:$PATH"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "cargo-shim-chain-selftest: ALL PASS"
  exit 0
else
  echo "cargo-shim-chain-selftest: assertion(s) FAILED"
  exit 1
fi
