#!/usr/bin/env bash
# tests/canary_acx_canary_json_records_boot_image.sh —
# PRD-build-burst-gate-canary-invariant R5.
#
# R5's schema for canary.json is `{head, image_id, ts, variants, diverged,
# baseline_dir}`. `_canary_core` read image_id from the session state file
# only, and the session state `up` writes does not always carry one — the
# 2026-09-18T04:57Z run on box 166412876 recorded `"image_id": "unknown"`.
# A canary verdict that cannot say WHICH image it judged is unjoinable to
# anything downstream: `enable`'s R6 check and verified-completed.sh's
# real-box evidence rule both key a canary to the image `up` would boot.
#
# This asserts the fallback to resolve_boot_image() — the same
# session-INDEPENDENT resolver `status --json` reports image_id from — so
# the two can never disagree.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label"; fail=1; fi; }

export PATH="$HERE/fixtures/burst-lane-fake:$PATH"
export BURST_LANE_TEST=1

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canary-acx-image.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

repo="$ROOT/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$repo" remote add origin https://github.com/fixture/repo.git
head_sha="$(git -C "$repo" rev-parse HEAD)"

fake_gh="$ROOT/fake-gh"
cat > "$fake_gh" <<EOF
#!/usr/bin/env bash
echo '[{"status":"completed","conclusion":"success","headSha":"$head_sha"}]'
EOF
chmod +x "$fake_gh"

fake_gl="$ROOT/fake-gate-launch"
cat > "$fake_gl" <<'EOF'
#!/usr/bin/env bash
repo="$1"; shift
mkdir -p "$repo/target/autobuilder/receipts"
cat > "$repo/target/autobuilder/receipts/extended-receipts-receipt.json" <<JSON
{"schema":"autobuilder.extended_receipts.v1","verdict":"pass","route":"burst:testbox9","head_sha":"$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)"}
JSON
printf '{"verdict":"pass"}\n' > "$repo/target/autobuilder/last-verdict.json"
exit 0
EOF
chmod +x "$fake_gl"

export BURST_LANE_STATE_DIR="$ROOT/state"
export BURST_LANE_JOURNAL="$ROOT/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
export BURST_LANE_CANARY_REPO="$repo"
export BURST_LANE_GH="$fake_gh"
export BURST_LANE_CANARY_GATE_LAUNCH="$fake_gl"
mkdir -p "$BURST_LANE_STATE_DIR/current"
# The live shape this regression comes from: a session with NO image_id.
echo '{"server_id":"testbox9","ip":"127.0.0.1"}' > "$BURST_LANE_STATE_DIR/current/session.json"

set +e
"$BL" canary --variants main --no-baseline >/dev/null 2>&1
set -e

cj="$BURST_LANE_STATE_DIR/boxes/testbox9/canary.json"
expect "canary.json written" "[ -f '$cj' ]"

recorded="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("image_id", ""))
except Exception:
    print("")
' "$cj")"
status_image="$("$BL" status --json 2>/dev/null | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("image_id", "") or "")
except Exception:
    print("")
')"

expect "canary.json image_id is not the placeholder 'unknown'" "[ '$recorded' != 'unknown' ]"
expect "canary.json image_id is non-empty" "[ -n '$recorded' ]"
expect "canary.json image_id equals what status --json says up would boot" \
  "[ '$recorded' = '$status_image' ]"

exit "$fail"
