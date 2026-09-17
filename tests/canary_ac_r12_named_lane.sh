#!/usr/bin/env bash
# tests/canary_ac_r12_named_lane.sh — PRD-build-burst-gate-canary-invariant
# R12 (P2): "`--variants` accepts a named proof lane from
# `agent/proof-lanes.toml` to run only that lane's required commands as a
# fourth variant." Three scenarios, all local/offline (no real box, no
# gh/gate-launch calls -- an explicit `--head <sha>` short-circuits
# canary_resolve_head with no CI lookup, and `--no-baseline` skips the
# baseline build; `main`/`branch`/`delta` are never in `--variants` here so
# canary_run_variant_main/branch/delta never run either -- same isolation
# convention as canary_ac_r10_r11_report_cost.sh, narrower fixture surface):
#   1. a lane whose required_commands all exit 0 -> canary.json variants.lane
#      = {id, verdict:pass}, canary exits 0.
#   2. a lane whose second command fails -> verdict block, journal names the
#      failing command, canary exits 1 (non-zero, "not pass").
#   3. a lane id absent from agent/proof-lanes.toml -> "unknown-lane",
#      journaled distinctly from block, canary still exits 0 (an unknown
#      lane name is an operator/config mistake, not a producer divergence).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label"; fail=1; fi; }

setup_repo() {
  local root="$1" repo="$1/repo"
  mkdir -p "$repo/agent"
  git -C "$repo" init -q 2>/dev/null || { mkdir -p "$repo"; git -C "$repo" init -q; }
  cat > "$repo/agent/proof-lanes.toml" <<'EOF'
[[lane]]
id = "smoke-ok"
description = "always-pass smoke lane"
required_commands = ["true", "echo hi >/dev/null"]

[[lane]]
id = "smoke-fail"
description = "second command fails"
required_commands = ["true", "false", "echo unreached >/dev/null"]
EOF
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m init
  printf '%s' "$repo"
}

run_canary() {
  local root="$1"; shift
  export BURST_LANE_STATE_DIR="$root/state"
  export BURST_LANE_JOURNAL="$root/journal.log"
  export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
  mkdir -p "$BURST_LANE_STATE_DIR/current"
  echo '{"server_id":"testbox1","ip":"127.0.0.1"}' > "$BURST_LANE_STATE_DIR/current/session.json"
  "$BL" canary "$@"
}

echo "== R12 scenario 1: known lane, all commands pass =="
ROOT1="$(mktemp -d "${TMPDIR:-/tmp}/canary-r12a.XXXXXX")"
repo1="$(setup_repo "$ROOT1")"
sha1="$(git -C "$repo1" rev-parse HEAD)"
export BURST_LANE_CANARY_REPO="$repo1"
set +e
out1="$(run_canary "$ROOT1" --head "$sha1" --no-baseline --variants smoke-ok 2>&1)"; rc1=$?
set -e
echo "RC=$rc1"; echo "$out1"
expect "scenario1: exit 0" "[ '$rc1' -eq 0 ]"
expect "scenario1: journal names lane=smoke-ok pass" \
  "grep -qE 'canary  lane=smoke-ok  pass  ' '$ROOT1/journal.log'"
cf1="$ROOT1/state/boxes/testbox1/canary.json"
expect "scenario1: canary.json has variants.lane.id=smoke-ok" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"variants\"][\"lane\"][\"id\"]==\"smoke-ok\" else 1)' '$cf1'"
expect "scenario1: canary.json has variants.lane.verdict=pass" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"variants\"][\"lane\"][\"verdict\"]==\"pass\" else 1)' '$cf1'"
rm -rf "$ROOT1"

echo "== R12 scenario 2: known lane, second command fails -> block, names it =="
ROOT2="$(mktemp -d "${TMPDIR:-/tmp}/canary-r12b.XXXXXX")"
repo2="$(setup_repo "$ROOT2")"
sha2="$(git -C "$repo2" rev-parse HEAD)"
export BURST_LANE_CANARY_REPO="$repo2"
set +e
out2="$(run_canary "$ROOT2" --head "$sha2" --no-baseline --variants smoke-fail 2>&1)"; rc2=$?
set -e
echo "RC=$rc2"; echo "$out2"
expect "scenario2: exit non-zero (not pass)" "[ '$rc2' -ne 0 ]"
expect "scenario2: journal names lane=smoke-fail block with the failing command" \
  "grep -qE 'canary  lane=smoke-fail  block  \(head=[0-9a-f]+ cmd_failed=false ' '$ROOT2/journal.log'"
cf2="$ROOT2/state/boxes/testbox1/canary.json"
expect "scenario2: canary.json variants.lane.verdict=block" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"variants\"][\"lane\"][\"verdict\"]==\"block\" else 1)' '$cf2'"
rm -rf "$ROOT2"

echo "== R12 scenario 3: unknown lane id -> unknown-lane, canary still exits 0 =="
ROOT3="$(mktemp -d "${TMPDIR:-/tmp}/canary-r12c.XXXXXX")"
repo3="$(setup_repo "$ROOT3")"
sha3="$(git -C "$repo3" rev-parse HEAD)"
export BURST_LANE_CANARY_REPO="$repo3"
set +e
out3="$(run_canary "$ROOT3" --head "$sha3" --no-baseline --variants nope-lane 2>&1)"; rc3=$?
set -e
echo "RC=$rc3"; echo "$out3"
expect "scenario3: exit 0" "[ '$rc3' -eq 0 ]"
expect "scenario3: journal names lane=nope-lane unknown-lane" \
  "grep -qE 'canary  lane=nope-lane  unknown-lane  ' '$ROOT3/journal.log'"
cf3="$ROOT3/state/boxes/testbox1/canary.json"
expect "scenario3: canary.json variants.lane.verdict=unknown-lane" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"variants\"][\"lane\"][\"verdict\"]==\"unknown-lane\" else 1)' '$cf3'"
rm -rf "$ROOT3"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canary_ac_r12_named_lane: ALL PASS"
  exit 0
else
  echo "canary_ac_r12_named_lane: assertion(s) FAILED"
  exit 1
fi
