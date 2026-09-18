#!/usr/bin/env bash
# tests/canaryliv_ac11_ac12_ac13_ac14_enable_report_gate.sh — PRD-build-
# burst-canary-live-parity R8/AC11-14. Reuses canary_ac5_ac8_enable_
# status_gate.sh's exact fixture harness (fake hcloud, proof.json that
# would otherwise let `enable` through, schema-2 canary.json literals).
#
# AC11 — a canary.json with no schema_version refuses cause=canary-legacy,
#        writes no drop-in, status shows canary=legacy@<age>h.
# AC12 — schema_version:2, both variants pass, but main.routed_runs=0
#        refuses cause=canary-not-routed.
# AC13 — schema_version:2, both pass, routed_runs>=1, baseline.state=built
#        at the same head -> enable succeeds, enable.json records
#        canary_schema=2 (canary_ac5_ac8's AC5-part-3 already proves the
#        pass path but never checked canary_schema).
# AC14 — `cmd_canary --report` on a schema-2 file prints per-variant
#        verdict/cause/gate_rc/receipts_n/common_producers/routed_runs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canaryliv-ac11-14.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label"; fail=1; fi; }

export PATH="$HERE/fixtures/burst-lane-fake:$PATH"
export BURST_LANE_TEST=1
export BURST_LANE_STATE_DIR="$ROOT/state"
export BURST_LANE_JOURNAL="$ROOT/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
export BURST_LANE_SYSTEMD_DROPIN="$ROOT/burst.conf"
export FAKE_HCLOUD_STATE="$ROOT/fake-hcloud.state"

STATE_DIR="$ROOT/state"
BOX_DIR="$STATE_DIR/current"
mkdir -p "$BOX_DIR"

SERVER_ID="testbox1"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "$SERVER_ID|$SERVER_ID|alive|$NOW_ISO" > "$FAKE_HCLOUD_STATE"

DEFAULT_SNAPSHOT_ID="$(grep -oE '^DEFAULT_SNAPSHOT_ID="[0-9]+"' "$BL" | head -n1 | grep -oE '[0-9]+')"
cat > "$BOX_DIR/session.json" <<EOF
{"server_id":"$SERVER_ID","ip":"127.0.0.1"}
EOF
cat > "$BOX_DIR/proof.json" <<EOF
{"routed":true,"ts":"$NOW_ISO","image_id":"$DEFAULT_SNAPSHOT_ID"}
EOF
mkdir -p "$STATE_DIR/boxes/$SERVER_ID"

echo "== AC11: no schema_version -> refuse cause=canary-legacy, no drop-in, status=legacy =="
cat > "$STATE_DIR/boxes/$SERVER_ID/canary.json" <<EOF
{"head":"deadbeef00","ts":"$NOW_ISO","variants":{"main":"pass","branch":"pass","delta":"pass"},"diverged":[]}
EOF
set +e
out="$("$BL" enable 2>&1)"; rc=$?
set -e
expect "AC11: enable exits 3" "[ '$rc' -eq 3 ]"
expect "AC11: refused cause=canary-legacy" "case \"\$out\" in *'cause=canary-legacy'*) true;; *) false;; esac"
expect "AC11: no drop-in written" "[ ! -f '$BURST_LANE_SYSTEMD_DROPIN' ]"
expect "AC11: journal has enable refused (cause=canary-legacy)" \
  "grep -q 'enable  refused  (cause=canary-legacy)' '$BURST_LANE_JOURNAL'"
status_out="$("$BL" status)"
line2="$(printf '%s\n' "$status_out" | sed -n '2p')"
echo "  status line 2: $line2"
expect "AC11: status line 2 shows canary=legacy@...h" "case \"\$line2\" in *'canary=legacy@'*) true;; *) false;; esac"

echo "== AC12: schema-2, both pass, main.routed_runs=0 -> refuse cause=canary-not-routed =="
cat > "$STATE_DIR/boxes/$SERVER_ID/canary.json" <<EOF
{"schema_version":2,"head":"cafef00d01","head_source":"green-main","ts":"$NOW_ISO","image_id":"$DEFAULT_SNAPSHOT_ID",
 "baseline":{"head":"cafef00d01","launch_ts":0,"gate_rc":0,"receipts_n":1,"state":"built"},
 "variants":{"main":{"verdict":"pass","cause":"","gate_rc":0,"receipts_n":1,"common_producers":3,"routed_runs":0,"worktree":"/tmp/x","launch_ts":0,"finish_ts":1},
             "branch":{"verdict":"pass","cause":"","gate_rc":0,"receipts_n":1,"common_producers":3,"routed_runs":1,"worktree":"/tmp/y","launch_ts":0,"finish_ts":1},
             "delta":"pass"},
 "diverged":[],
 "baseline_dir":""}
EOF
set +e
out="$("$BL" enable 2>&1)"; rc=$?
set -e
expect "AC12: enable exits 3" "[ '$rc' -eq 3 ]"
expect "AC12: refused cause=canary-not-routed" "case \"\$out\" in *'cause=canary-not-routed'*) true;; *) false;; esac"
expect "AC12: no drop-in written" "[ ! -f '$BURST_LANE_SYSTEMD_DROPIN' ]"

echo "== AC13: schema-2, both pass, routed_runs>=1, baseline built at same head -> enable succeeds, enable.json canary_schema=2 =="
cat > "$STATE_DIR/boxes/$SERVER_ID/canary.json" <<EOF
{"schema_version":2,"head":"ac13head0123","head_source":"green-main","ts":"$NOW_ISO","image_id":"$DEFAULT_SNAPSHOT_ID",
 "baseline":{"head":"ac13head0123","launch_ts":0,"gate_rc":0,"receipts_n":5,"state":"built"},
 "variants":{"main":{"verdict":"pass","cause":"","gate_rc":0,"receipts_n":5,"common_producers":5,"routed_runs":2,"worktree":"/tmp/x","launch_ts":0,"finish_ts":1},
             "branch":{"verdict":"pass","cause":"","gate_rc":0,"receipts_n":3,"common_producers":3,"routed_runs":1,"worktree":"/tmp/y","launch_ts":0,"finish_ts":1},
             "delta":"pass"},
 "diverged":[],
 "baseline_dir":""}
EOF
set +e
out="$("$BL" enable 2>&1)"; rc=$?
set -e
expect "AC13: enable exits 0" "[ '$rc' -eq 0 ]"
expect "AC13: drop-in written" "[ -f '$BURST_LANE_SYSTEMD_DROPIN' ]"
expect "AC13: enable.json exists" "[ -f '$STATE_DIR/enable.json' ]"
schema_val="$(python3 -c 'import json;print(json.load(open("'"$STATE_DIR"'/enable.json")).get("canary_schema"))' 2>/dev/null || true)"
echo "  enable.json canary_schema: $schema_val"
expect "AC13: enable.json records canary_schema=2" "[ \"\$schema_val\" = 2 ]"

echo "== AC14: cmd_canary --report on the AC13 schema-2 file shows per-variant columns =="
set +e
report_out="$("$BL" canary --report 2>&1)"; report_rc=$?
set -e
echo "$report_out"
expect "AC14: --report exits 0" "[ '$report_rc' -eq 0 ]"
expect "AC14: report has schema_version 2" "case \"\$report_out\" in *'schema_version 2'*) true;; *) false;; esac"
expect "AC14: report names main variant with verdict/cause/gate_rc/receipts_n/common_producers/routed_runs" \
  "case \"\$report_out\" in *'variant main'*'verdict=pass'*'cause='*'gate_rc=0'*'receipts_n=5'*'common_producers=5'*'routed_runs=2'*) true;; *) false;; esac"
expect "AC14: report names branch variant with the same columns" \
  "case \"\$report_out\" in *'variant branch'*'verdict=pass'*'routed_runs=1'*) true;; *) false;; esac"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canaryliv_ac11_ac12_ac13_ac14_enable_report_gate: ALL PASS"
else
  echo "canaryliv_ac11_ac12_ac13_ac14_enable_report_gate: FAILED" >&2
fi
exit "$fail"
