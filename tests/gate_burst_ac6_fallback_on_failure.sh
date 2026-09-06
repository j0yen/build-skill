#!/usr/bin/env bash
# gate_burst_ac6_fallback_on_failure.sh — PRD-build-gate-cloudburst AC6.
#
# Given a burst failure (API down), when a routed run falls back, then
# the gate completes locally with today's behavior and one journal line
# names the cause.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GB="$HERE/../scripts/gate-burst.sh"
FAKE="$HERE/fixtures/gate-burst-fake"
[ -x "$GB" ] || { echo "ac6: $GB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gb-ac6.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export PATH="$FAKE:$PATH"
export GATE_BURST_STATE_DIR="$T/state"; mkdir -p "$GATE_BURST_STATE_DIR"
export GATE_BURST_LEDGER="$T/ledger.ndjson"
export GATE_BURST_JOURNAL="$T/journal.md"
export GATE_BURST_ENV_FILE="$T/env"; echo "SNAPSHOT_ID=427125061" > "$GATE_BURST_ENV_FILE"
export FAKE_HCLOUD_STATE="$T/hcloud.state"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# API down: hcloud auth fails, so `up` (and therefore `run`) must refuse
# to attempt any network action and report a fallback the caller can act
# on by running the gate cargo locally (today's behavior — this script
# never runs local cargo itself, it only signals that the caller must).
REPO="$T/repo"; mkdir -p "$REPO"
echo 'echo unreachable' > "$REPO/gate.sh"

set +e
out=$(FAKE_HCLOUD_AUTH_FAIL=1 "$GB" run "$REPO" bash gate.sh 2>&1); rc=$?
set -e
expect "run exits 3 (caller must fall back)"     "[ $rc -eq 3 ]"
expect "the message names 'fallback'"            "grep -q '^fallback:' <<<\"\$out\""
expect "the message names the actual cause"      "grep -qi 'not authenticated' <<<\"\$out\""
expect "exactly one journal line names the cause" \
  "[ \"\$(grep -c 'gate-burst  up  fallback' \"$GATE_BURST_JOURNAL\")\" -eq 1 ]"
expect "no server was ever created"              "[ ! -s \"$FAKE_HCLOUD_STATE\" ]"

exit $fail
