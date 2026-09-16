#!/usr/bin/env bash
# vcrbps-selftest.sh — durable acceptance harness for
# PRD-build-verified-completed-realbox-perserver (test_prefix vcrbps).
# Builds throwaway fixture repos + PRDs + a scratch manifest.json under a
# tempdir (fully hermetic — never touches a real ~/wintermute repo or the
# live state/manifest.json / state/burst-lane/) and asserts AC1-AC6:
#   AC1 — per-server-only proof.json (flat absent) pairs like the flat
#         path used to, via check_real_box_evidence's boxes/*/ glob.
#   AC2 — a stale/older flat proof.json never shadows a fresher, valid
#         per-server proof (and vice versa) — freshest `ts` wins.
#   AC3 — no valid candidate anywhere (flat absent, per-server stale/
#         unrouted/image-mismatched, an orphan box dir with no proof.json
#         inside) still reports MISSING, unchanged, and never crashes the
#         glob.
#   AC4 — the PRD-build-gate-route-parity-ledger-shaped regression this
#         PRD exists to close: a real-box AC backed only by a per-server
#         proof (no flat file) reads PAIRED, and a whole-suite AC (no
#         per-AC test file, evidenced by the named script's own selftest
#         receipt) reads PAIRED instead of ac-number-collision against an
#         unrelated sibling's same-numbered bare file.
#   AC5 — the whole-suite pairing rule itself: a numbered AC whose line
#         names a `scripts/*.sh`/`*-selftest.sh` path and has no per-AC
#         file pairs against that script's last-recorded (receipted) exit
#         code; a nonzero or absent receipt does NOT falsely pair (falls
#         through to existing MISSING/collision behavior unchanged).
#   AC6 — `scripts/run-selftests.sh scripts/vcrbps-selftest.sh` reports
#         0 FAIL (this file, run through the one selftest entrypoint).
#
# Run: bash scripts/vcrbps-selftest.sh   (exit 0 = all pass)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VC="$HERE/verified-completed.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/vcrbps-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ck(){ if eval "$2"; then echo "ok  $1"; PASS=$((PASS+1)); else echo "FAIL  $1" >&2; FAIL=$((FAIL+1)); fi; }

mkdir -p "$T/repo/tests" "$T/repo/scripts" "$T/repo/state/burst-lane/boxes" "$T/prds" "$T/state" "$T/receipts"

cat > "$T/repo/scripts/burst-lane.sh" <<'EOF'
#!/usr/bin/env bash
# fake burst-lane.sh for the selftest — only `status --json`'s image_id
# field is read by verified-completed.sh's real-box rule.
if [ "${1:-}" = "status" ]; then
  echo '{"image_id":"img-current"}'
fi
EOF
chmod +x "$T/repo/scripts/burst-lane.sh"

cat > "$T/state/manifest.json" <<EOF
{"prds":[
  {"slug":"vcrbps-fixture","output_repo_path":"$T/repo"},
  {"slug":"vcrbps-other-sibling","output_repo_path":"$T/repo"}
]}
EOF
export MANIFEST="$T/state/manifest.json"

now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
older_valid_ts="$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
stale_ts="2020-01-01T00:00:00Z"

# =========================================================================
# AC1 — per-server-only proof (flat absent) pairs like the flat path did.
# =========================================================================
cat > "$T/prds/PRD-vcrbps-fixture.md" <<EOF
# PRD: vcrbps real-box + whole-suite fixture
Status: Draft v0.1
build_target: shell
build_into: $T/repo
test_prefix: vcrbps

## Acceptance

1. a normal declared-prefix AC with no file at all (control, stays MISSING).
2. a real-box-only AC. (Real-box; deferrable only with a justification naming why no box was reachable.)
3. a numbered AC whose evidence is the whole suite. Given tests/vcrbps_ac*.sh, When scripts/vcrbps-fixture-selftest.sh runs, Then 0 FAIL.
EOF

mkdir -p "$T/repo/state/burst-lane/boxes/165656705"
rm -f "$T/repo/state/burst-lane/proof.json"
echo '{"routed":true,"bytes":123,"image_id":"img-current","ts":"'"$now_ts"'"}' \
  > "$T/repo/state/burst-lane/boxes/165656705/proof.json"

out="$("$VC" "$T/prds/PRD-vcrbps-fixture.md" --derive --format table 2>/dev/null)"
ck "AC1 per-server-only proof (flat absent) -> AC2 PAIRED via real-box" \
  'printf "%s\n" "$out" | awk -F"\t" "\$1==2{print \$2\"|\"\$4}" | grep -qx "real-box|PAIRED"'
ck "AC1 evidence names the per-server path, not the retired flat path" \
  'printf "%s\n" "$out" | awk -F"\t" "\$1==2{print \$3}" | grep -q "state/burst-lane/boxes/165656705/proof.json"'

# =========================================================================
# AC2 — freshest `ts` wins, regardless of which source (flat vs per-server)
# is fresher; a stale/older one on either side never shadows the fresher.
# =========================================================================
# 2a: flat is OLDER-but-still-valid, per-server is FRESHER -> per-server wins.
echo '{"routed":true,"bytes":99,"image_id":"img-current","ts":"'"$older_valid_ts"'"}' \
  > "$T/repo/state/burst-lane/proof.json"
echo '{"routed":true,"bytes":123,"image_id":"img-current","ts":"'"$now_ts"'"}' \
  > "$T/repo/state/burst-lane/boxes/165656705/proof.json"
out="$("$VC" "$T/prds/PRD-vcrbps-fixture.md" --derive --format table 2>/dev/null)"
ck "AC2a both valid, per-server fresher -> per-server proof wins" \
  'printf "%s\n" "$out" | awk -F"\t" "\$1==2{print \$3}" | grep -q "state/burst-lane/boxes/165656705/proof.json"'

# 2b: flip it — flat is FRESHER, per-server is OLDER-but-still-valid -> flat wins.
echo '{"routed":true,"bytes":99,"image_id":"img-current","ts":"'"$now_ts"'"}' \
  > "$T/repo/state/burst-lane/proof.json"
echo '{"routed":true,"bytes":123,"image_id":"img-current","ts":"'"$older_valid_ts"'"}' \
  > "$T/repo/state/burst-lane/boxes/165656705/proof.json"
out="$("$VC" "$T/prds/PRD-vcrbps-fixture.md" --derive --format table 2>/dev/null)"
ck "AC2b both valid, flat fresher -> flat proof wins (never shadowed by a source-order rule)" \
  'printf "%s\n" "$out" | awk -F"\t" "\$1==2{print \$3}" | grep -qx "state/burst-lane/proof.json (routed=true image=img-current bytes=99 ts='"$now_ts"')"'

# 2c: flat is STALE (>168h), per-server is valid -> per-server wins, stale
# flat never shadows it (the literal defect this PRD's R2 names).
echo '{"routed":true,"bytes":99,"image_id":"img-current","ts":"'"$stale_ts"'"}' \
  > "$T/repo/state/burst-lane/proof.json"
echo '{"routed":true,"bytes":123,"image_id":"img-current","ts":"'"$now_ts"'"}' \
  > "$T/repo/state/burst-lane/boxes/165656705/proof.json"
out="$("$VC" "$T/prds/PRD-vcrbps-fixture.md" --derive --format table 2>/dev/null)"
ck "AC2c stale flat never shadows a fresher, valid per-server proof" \
  'printf "%s\n" "$out" | awk -F"\t" "\$1==2{print \$3}" | grep -q "state/burst-lane/boxes/165656705/proof.json"'

# =========================================================================
# AC3 — no valid candidate anywhere -> MISSING, unchanged; an orphan box
# dir with no proof.json inside must not error the glob.
# =========================================================================
rm -f "$T/repo/state/burst-lane/proof.json"
rm -rf "$T/repo/state/burst-lane/boxes"
mkdir -p "$T/repo/state/burst-lane/boxes/_orphan-1"
out="$("$VC" "$T/prds/PRD-vcrbps-fixture.md" --derive --format table 2>/dev/null)"
"$VC" "$T/prds/PRD-vcrbps-fixture.md" --derive >/dev/null 2>&1
ck "AC3 flat absent + orphan box dir (no proof.json inside) -> AC2 MISSING, no crash" \
  'printf "%s\n" "$out" | awk -F"\t" "\$1==2{print \$4}" | grep -qx MISSING'

mkdir -p "$T/repo/state/burst-lane/boxes/165656705"
echo '{"routed":false,"bytes":123,"image_id":"img-current","ts":"'"$now_ts"'"}' \
  > "$T/repo/state/burst-lane/boxes/165656705/proof.json"
out="$("$VC" "$T/prds/PRD-vcrbps-fixture.md" --derive --format table 2>/dev/null)"
ck "AC3 every per-server proof unrouted/stale/mismatched -> AC2 MISSING" \
  'printf "%s\n" "$out" | awk -F"\t" "\$1==2{print \$4}" | grep -qx MISSING'

# =========================================================================
# AC5 — whole-suite pairing rule: AC3's line names
# scripts/vcrbps-fixture-selftest.sh and has no per-AC test file. A fresh
# (this-PRD-slug-scoped) exit-0 receipt pairs it; a nonzero or absent
# receipt does not.
# =========================================================================
RECEIPTS="$T/receipts"
export VC_RECEIPTS_DIR="$RECEIPTS"

# 5a: no receipt at all yet -> AC3 stays MISSING (heuristic doesn't
# fabricate evidence).
out="$("$VC" "$T/prds/PRD-vcrbps-fixture.md" --derive --format table 2>/dev/null)"
ck "AC5a whole-suite AC with no receipt yet -> MISSING, not falsely paired" \
  'printf "%s\n" "$out" | awk -F"\t" "\$1==3{print \$4}" | grep -qx MISSING'

# 5b: a receipt naming the script but a NONZERO exit -> still not paired.
cat > "$RECEIPTS/2026-09-16-vcrbps-fixture-selftest.txt" <<EOF
command: bash scripts/run-selftests.sh scripts/vcrbps-fixture-selftest.sh
started-at: ${now_ts}
exit: 1
hostname: selftest
output-tail:
FAIL  something
EOF
out="$("$VC" "$T/prds/PRD-vcrbps-fixture.md" --derive --format table 2>/dev/null)"
ck "AC5b receipted nonzero exit -> AC3 still not paired" \
  'printf "%s\n" "$out" | awk -F"\t" "\$1==3{print \$4}" | grep -qx MISSING'

# 5c: a fresh exit-0 receipt -> AC3 PAIRED via whole-suite.
cat > "$RECEIPTS/2026-09-16-vcrbps-fixture-selftest-2.txt" <<EOF
command: bash scripts/run-selftests.sh scripts/vcrbps-fixture-selftest.sh
started-at: ${now_ts}
exit: 0
hostname: selftest
output-tail:
ok  all good
EOF
out="$("$VC" "$T/prds/PRD-vcrbps-fixture.md" --derive --format table 2>/dev/null)"
ck "AC5c receipted exit 0 -> AC3 PAIRED via whole-suite" \
  'printf "%s\n" "$out" | awk -F"\t" "\$1==3{print \$2\"|\"\$4}" | grep -qx "whole-suite|PAIRED"'

# =========================================================================
# AC4 — the actual grounding regression: a sibling PRD declares its own
# test_prefix and lands a bare same-numbered file for AC3's number; the
# whole-suite AC must still PAIR, never ac-number-collision. AC2 (real-box)
# must also still PAIR off the per-server-only proof in the same pass —
# both false negatives from the grounding incident closed together.
# =========================================================================
cat > "$T/prds/PRD-vcrbps-other-sibling.md" <<EOF
# PRD: unrelated sibling declaring its own AC3 under a different prefix
Status: Draft v0.1
build_target: shell
build_into: $T/repo
test_prefix: othersib

## Acceptance

1. a.
2. b.
3. an unrelated requirement, also numbered 3.
EOF
: > "$T/repo/tests/othersib_ac3_unrelated.sh"

rm -f "$T/repo/state/burst-lane/proof.json"
mkdir -p "$T/repo/state/burst-lane/boxes/165656705"
echo '{"routed":true,"bytes":123,"image_id":"img-current","ts":"'"$now_ts"'"}' \
  > "$T/repo/state/burst-lane/boxes/165656705/proof.json"
out="$("$VC" "$T/prds/PRD-vcrbps-fixture.md" --derive --format table 2>/dev/null)"
ck "AC4 real-box AC2 PAIRED (per-server-only proof, no flat file)" \
  'printf "%s\n" "$out" | awk -F"\t" "\$1==2{print \$2\"|\"\$4}" | grep -qx "real-box|PAIRED"'
ck "AC4 whole-suite AC3 PAIRED (not ac-number-collision against othersib_ac3)" \
  'printf "%s\n" "$out" | awk -F"\t" "\$1==3{print \$2\"|\"\$4}" | grep -qx "whole-suite|PAIRED"'

echo "----"
echo "vcrbps-selftest: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
