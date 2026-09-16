#!/usr/bin/env bash
# tests/canary_ac4_receipt_diff_same.sh — PRD-build-burst-gate-canary-
# invariant AC4: fixture receipts identical except wall, timestamps and
# target/ paths must print "same" for every producer and exit 0.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIFF="$HERE/../scripts/gate-receipt-diff.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/canary-ac4.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

baseline="$ROOT/baseline/receipts"
run="$ROOT/run/receipts"
mkdir -p "$baseline" "$run"

cat > "$baseline/flake-audit-receipt.json" <<'EOF'
{
  "schema": "autobuilder.flake_audit_receipt.v1",
  "verdict": "pass",
  "route": "local",
  "head_sha": "deadbeef",
  "captured_at": "2026-09-16T00:00:00Z",
  "wall_seconds": 41.2,
  "artifact_path": "/tmp/target/autobuilder/flake-audit/run1"
}
EOF

cat > "$run/flake-audit-receipt.json" <<'EOF'
{
  "schema": "autobuilder.flake_audit_receipt.v1",
  "verdict": "pass",
  "route": "burst:ccx43-1",
  "head_sha": "deadbeef",
  "captured_at": "2026-09-16T00:09:00Z",
  "wall_seconds": 12.9,
  "artifact_path": "/mnt/data/target/autobuilder/flake-audit/run7"
}
EOF

cat > "$baseline/msrv-verify-receipt.json" <<'EOF'
{ "schema": "autobuilder.msrv_verify.v1", "verdict": "pass", "route": "local", "captured_at": "2026-09-16T00:01:00Z" }
EOF
cat > "$run/msrv-verify-receipt.json" <<'EOF'
{ "schema": "autobuilder.msrv_verify.v1", "verdict": "pass", "route": "burst:ccx43-1", "captured_at": "2026-09-16T00:10:30Z" }
EOF

echo "== AC4: wall/timestamps/target-path differences never trip a divergence =="
out=$("$DIFF" "$baseline" "$run")
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: expected exit 0, got $rc: $out"; exit 1; }
echo "$out" | grep -q ' DIVERGED$' && { echo "FAIL: unexpected DIVERGED in: $out"; exit 1; }
echo "$out" | grep -qx 'flake-audit pass pass burst:ccx43-1 same' \
  || { echo "FAIL: missing flake-audit same line: $out"; exit 1; }
echo "$out" | grep -qx 'msrv-verify pass pass burst:ccx43-1 same' \
  || { echo "FAIL: missing msrv-verify same line: $out"; exit 1; }
echo ok
