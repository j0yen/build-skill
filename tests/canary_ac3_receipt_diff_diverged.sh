#!/usr/bin/env bash
# tests/canary_ac3_receipt_diff_diverged.sh — PRD-build-burst-gate-canary-
# invariant AC3: fixture receipts where extended-receipts passes locally
# and fails on the box must print the DIVERGED line, exit 1, and name the
# producer and route. Pure fixture, no real box, no baked gate run.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIFF="$HERE/../scripts/gate-receipt-diff.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/canary-ac3.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

baseline="$ROOT/baseline/receipts"
run="$ROOT/run/receipts"
mkdir -p "$baseline" "$run"

cat > "$baseline/extended-receipts-receipt.json" <<'EOF'
{
  "schema": "autobuilder.extended_receipts.v1",
  "verdict": "pass",
  "route": "local",
  "head_sha": "deadbeef",
  "captured_at": "2026-09-16T00:00:00Z"
}
EOF

cat > "$run/extended-receipts-receipt.json" <<'EOF'
{
  "schema": "autobuilder.extended_receipts.v1",
  "verdict": "fail",
  "route": "burst:ccx43-1",
  "head_sha": "deadbeef",
  "captured_at": "2026-09-16T00:05:00Z"
}
EOF

echo "== AC3: local pass / box fail prints DIVERGED and exits 1 =="
set +e
out=$("$DIFF" "$baseline" "$run" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL: expected exit 1, got $rc: $out"; exit 1; }
echo "$out" | grep -qx 'extended-receipts pass fail burst:ccx43-1 DIVERGED' \
  || { echo "FAIL: unexpected line: $out"; exit 1; }
echo ok
