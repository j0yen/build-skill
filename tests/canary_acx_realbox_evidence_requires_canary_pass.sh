#!/usr/bin/env bash
# tests/canary_acx_realbox_evidence_requires_canary_pass.sh —
# PRD-build-burst-gate-canary-invariant R6, archive-side half.
#
# R6 made `burst-lane.sh enable` refuse on `cause=canary-missing` /
# `cause=canary-diverged`: a routed cargo proof (`proof.json`) is no longer
# sufficient to route real gates to a box. `verified-completed.sh`'s
# real-box pairing rule documents the invariant "a PAIRED real-box AC and a
# passing `enable` always agree" — so it has to require the same canary.
#
# Regression this locks down (observed live, 2026-09-18): `--derive` on
# THIS PRD reported ACs 1/5/6/8/14/18 as PAIRED against
# `state/burst-lane/boxes/166121325/proof.json`, a cargo proof from a box
# deleted on 2026-09-16 that never ran a passing canary, while the same
# `burst-lane.sh status --json` call the rule already makes reported
# `canary.verdict=missing`. An archive could have claimed real-box evidence
# for a canary that has never passed on any box.
#
# Deliberately NOT named canary_ac<N>_*: this file is evidence for the
# archive-side rule that governs the real-box ACs, and a real-box AC must
# never be pairable by a tests/ fixture (verified-completed.sh rule f
# checks real-box FIRST and EXCLUSIVELY). `acx` keeps the file inside
# canary-selftest.sh's `canary_ac*.sh` glob without ever reading as a
# per-AC pairing for AC1/5/6/8/14/18.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VC="$HERE/../scripts/verified-completed.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canary-acx-realbox.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

REPO="$ROOT/repo"
mkdir -p "$REPO/tests" "$REPO/scripts" "$REPO/state/burst-lane/boxes/166121325" "$ROOT/prds" "$ROOT/state"

# Fake burst-lane.sh: only `status --json`'s image_id is read by the rule.
cat > "$REPO/scripts/burst-lane.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "status" ]; then
  echo '{"image_id":"img-current"}'
fi
EOF
chmod +x "$REPO/scripts/burst-lane.sh"

cat > "$ROOT/state/manifest.json" <<EOF
{"prds":[{"slug":"canaryacx-fixture","output_repo_path":"$REPO"}]}
EOF
export MANIFEST="$ROOT/state/manifest.json"

cat > "$ROOT/prds/PRD-canaryacx-fixture.md" <<EOF
# PRD: canary real-box evidence fixture
Status: Draft v0.1
build_target: shell
build_into: $REPO
test_prefix: canaryacx

## Acceptance

1. a control AC with no file at all (stays MISSING).
2. a real-box-only AC. (Real-box; deferrable only with a justification naming why no box was reachable.)
EOF

now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stale_ts="2020-01-01T00:00:00Z"
PROOF="$REPO/state/burst-lane/boxes/166121325/proof.json"
CANARY="$REPO/state/burst-lane/boxes/166121325/canary.json"

write_proof() {
  printf '{"routed":true,"bytes":123,"image_id":"img-current","ts":"%s"}\n' "$now_ts" > "$PROOF"
}
write_canary() {  # $1=image  $2=ts  $3=diverged-json  $4=variants-json
  printf '{"head":"f59b60b","image_id":"%s","ts":"%s","diverged":%s,"variants":%s}\n' \
    "$1" "$2" "$3" "$4" > "$CANARY"
}
# verified-completed.sh exits non-zero whenever any AC is MISSING (AC1 is
# a deliberate always-MISSING control here), so every call is `|| true`d —
# this test asserts on the CLASSIFICATION column, never on that exit code.
ac2_class() {
  { "$VC" "$ROOT/prds/PRD-canaryacx-fixture.md" --derive --format table 2>/dev/null || true; } \
    | awk -F'\t' '$1==2{print $4}'
}
ac2_evidence() {
  { "$VC" "$ROOT/prds/PRD-canaryacx-fixture.md" --derive --format table 2>/dev/null || true; } \
    | awk -F'\t' '$1==2{print $3}'
}
expect() {  # $1=label  $2=expected classification
  local got; got="$(ac2_class)"
  if [ "$got" = "$2" ]; then
    echo "ok  $1"
  else
    echo "FAIL: $1 — expected $2, got '$got'" >&2
    exit 1
  fi
}

PASS_VARIANTS='{"main":"pass","branch":"pass","delta":"pass"}'

echo "== a routed, fresh, image-matching proof with NO canary at all is not real-box evidence =="
write_proof
rm -f "$CANARY"
expect "proof-only (canary missing) -> MISSING" MISSING

echo "== the live regression: proof present, canary blocked on two variants =="
write_canary img-current "$now_ts" '[]' '{"main":"block","branch":"block","delta":"pass"}'
expect "canary with a blocked variant -> MISSING" MISSING

echo "== a canary that passed every variant but named a producer diverged =="
write_canary img-current "$now_ts" '[{"producer":"extended-receipts","local":"pass","box":"fail","route":"burst:1"}]' "$PASS_VARIANTS"
expect "canary with a non-empty diverged[] -> MISSING" MISSING

echo "== a passing canary for a SUPERSEDED image does not vouch for the current one =="
write_canary img-superseded "$now_ts" '[]' "$PASS_VARIANTS"
expect "canary image mismatch -> MISSING" MISSING

echo '== image_id "unknown" (what cmd_canary wrote before the R5 fallback) never matches =='
write_canary unknown "$now_ts" '[]' "$PASS_VARIANTS"
expect "canary image_id=unknown -> MISSING" MISSING

echo "== a passing canary outside the same 168h window enable enforces =="
write_canary img-current "$stale_ts" '[]' "$PASS_VARIANTS"
expect "canary older than 168h -> MISSING" MISSING

echo "== every variant skipped is not a pass =="
write_canary img-current "$now_ts" '[]' '{"main":"skipped","branch":"skipped","delta":"skipped"}'
expect "canary with no judged variant -> MISSING" MISSING

echo "== proof + a fresh, image-matching, all-pass, non-diverged canary DOES pair =="
write_canary img-current "$now_ts" '[]' "$PASS_VARIANTS"
expect "proof + passing canary -> PAIRED" PAIRED
ev="$(ac2_evidence)"
case "$ev" in
  *"boxes/166121325/proof.json"*"canary:"*"boxes/166121325/canary.json"*)
    echo "ok  evidence names BOTH receipts (proof + canary)" ;;
  *) echo "FAIL: evidence line does not name both receipts: $ev" >&2; exit 1 ;;
esac

echo "== and the canary alone, with the proof gone, is still not enough =="
rm -f "$PROOF"
expect "canary-only (proof missing) -> MISSING" MISSING

echo "ok  all cases"
