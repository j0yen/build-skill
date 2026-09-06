#!/usr/bin/env bash
# gate_burst_ac7_receipt_equivalence.sh — PRD-build-gate-cloudburst AC7.
#
# Given the same commit gated locally and via burst, when receipts are
# compared, then verdict-relevant content is identical and each records
# its producing host.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GB="$HERE/../scripts/gate-burst.sh"
FAKE="$HERE/fixtures/gate-burst-fake"
[ -x "$GB" ] || { echo "ac7: $GB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gb-ac7.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export PATH="$FAKE:$PATH"
export GATE_BURST_STATE_DIR="$T/state"; mkdir -p "$GATE_BURST_STATE_DIR"
export GATE_BURST_LEDGER="$T/ledger.ndjson"
export GATE_BURST_JOURNAL="$T/journal.md"
export GATE_BURST_ENV_FILE="$T/env"; echo "SNAPSHOT_ID=427125061" > "$GATE_BURST_ENV_FILE"
export GATE_BURST_REMOTE_ROOT="$T/remote"
export FAKE_HCLOUD_STATE="$T/hcloud.state"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# "Local" build of the same commit.
LOCAL_REPO="$T/local-repo"; mkdir -p "$LOCAL_REPO"
echo 'verdict-relevant-content-v1' > "$LOCAL_REPO/receipt.txt"

# "Remote" (burst) build of the same commit — same content-producing
# command, run through gate-burst.sh.
BURST_REPO="$T/burst-repo"; mkdir -p "$BURST_REPO"
echo 'mkdir -p target && echo verdict-relevant-content-v1 > target/receipt.txt' > "$BURST_REPO/gate.sh"
"$GB" run "$BURST_REPO" bash gate.sh >/dev/null

expect "remote receipt content matches the local one" \
  "diff -q <(cat \"$LOCAL_REPO/receipt.txt\") \"$BURST_REPO/target/receipt.txt\" >/dev/null"
expect "the burst run stamped a producing-host file" \
  "[ -s \"$BURST_REPO/.gate-burst-host\" ]"
expect "the producing host is NOT this machine's own hostname (a real remote host)" \
  "[ \"\$(cat \"$BURST_REPO/.gate-burst-host\")\" != \"\$(hostname)\" ]"

exit $fail
