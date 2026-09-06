#!/usr/bin/env bash
# gate_burst_ac5_destroy_fail_leak_flag.sh — PRD-build-gate-cloudburst AC5.
#
# Given a failed destroy after retries, when the manager gives up, then a
# docket-visible flag names the server id and estimated bleed rate.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GB="$HERE/../scripts/gate-burst.sh"
FAKE="$HERE/fixtures/gate-burst-fake"
[ -x "$GB" ] || { echo "ac5: $GB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gb-ac5.XXXXXX")"
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

"$GB" up >/dev/null
id="$(grep -oE '"server_id":[0-9]+' "$GATE_BURST_STATE_DIR/active.json" | cut -d: -f2)"

set +e
out=$(FAKE_HCLOUD_DELETE_FAIL=1 "$GB" down 2>&1); rc=$?
set -e
expect "manager gives up with a non-zero exit"        "[ $rc -ne 0 ]"
expect "the flag names the server id"                  "grep -q \"LEAK-FLAG.*$id\" <<<\"\$out\""
expect "the flag names an estimated bleed rate"        "grep -qE 'bleeding \\\$[0-9.]+/hr' <<<\"\$out\""
expect "a docket-visible journal line was written"     "grep -q 'LEAK-FLAG' \"$GATE_BURST_JOURNAL\""
expect "state is NOT cleared (still tracked for retry)" "[ -f \"$GATE_BURST_STATE_DIR/active.json\" ]"

exit $fail
