#!/usr/bin/env bash
# gate_burst_ac2_rust_only_stays_local.sh — PRD-build-gate-cloudburst AC2.
#
# Given a tick with only Rust work, when the gate step runs, then cargo
# runs locally and no server is created.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GB="$HERE/../scripts/gate-burst.sh"
FAKE="$HERE/fixtures/gate-burst-fake"
[ -x "$GB" ] || { echo "ac2: $GB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gb-ac2.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export PATH="$FAKE:$PATH"
export GATE_BURST_STATE_DIR="$T/state"; mkdir -p "$GATE_BURST_STATE_DIR"
export FAKE_HCLOUD_STATE="$T/hcloud.state"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

set +e
out=$("$GB" should-route --rust 3 --python 0); rc=$?
set -e
expect "rust-only predicate stays local (exit 1)" "[ $rc -eq 1 ]"
expect "predicate names the single-flavor tick"   "grep -q '^local: single-flavor tick' <<<\"\$out\""

# The tick honoring the predicate never calls `up` at all — prove no
# server was created (no state file, no id in the fake hcloud's ledger).
expect "no active-box state was created" "[ ! -f \"$GATE_BURST_STATE_DIR/active.json\" ]"
expect "fake hcloud never recorded a server" "[ ! -s \"$FAKE_HCLOUD_STATE\" ]"

exit $fail
