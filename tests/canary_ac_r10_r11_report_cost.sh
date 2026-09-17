#!/usr/bin/env bash
# tests/canary_ac_r10_r11_report_cost.sh — PRD-build-burst-gate-canary-
# invariant R10 (`canary --report` prints the last canary.json as a table,
# read-only, never runs a canary) and R11 (each canary journals a
# `canary cost (eur=… minutes=…)` line through the existing cost-rate
# path). Pure fixture: no real box, no network — `--report` is exercised
# by seeding canary.json directly (same convention as
# canary_ac5_ac8_enable_status_gate.sh); the cost line is exercised by a
# real, fast `canary --no-baseline` run against a fake gh + fake
# gate-launch (same convention as canary_ac13's fixture).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label"; fail=1; fi; }

echo "== R10 part 1: --report with no canary.json -> exit 1, nothing fabricated =="
ROOT1="$(mktemp -d "${TMPDIR:-/tmp}/canary-r10a.XXXXXX")"
export PATH="$HERE/fixtures/burst-lane-fake:$PATH"
export BURST_LANE_TEST=1
export BURST_LANE_STATE_DIR="$ROOT1/state"
export BURST_LANE_JOURNAL="$ROOT1/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
mkdir -p "$BURST_LANE_STATE_DIR/current"
echo '{"server_id":"testbox1","ip":"127.0.0.1"}' > "$BURST_LANE_STATE_DIR/current/session.json"
set +e
out="$("$BL" canary --report 2>&1)"; rc=$?
set -e
expect "no-canary: exit 1" "[ '$rc' -eq 1 ]"
expect "no-canary: names the reason" "case \"\$out\" in *'no canary.json recorded'*) true;; *) false;; esac"
rm -rf "$ROOT1"

echo "== R10 part 2: --report against a seeded canary.json -> table, exit 0 =="
ROOT2="$(mktemp -d "${TMPDIR:-/tmp}/canary-r10b.XXXXXX")"
export BURST_LANE_STATE_DIR="$ROOT2/state"
export BURST_LANE_JOURNAL="$ROOT2/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
mkdir -p "$BURST_LANE_STATE_DIR/current" "$BURST_LANE_STATE_DIR/boxes/testbox1"
echo '{"server_id":"testbox1","ip":"127.0.0.1"}' > "$BURST_LANE_STATE_DIR/current/session.json"
cat > "$BURST_LANE_STATE_DIR/boxes/testbox1/canary.json" <<'EOF'
{"head":"abcdef0123456789","head_source":"green-main","image_id":"img-1",
 "ts":"2026-09-16T12:00:00Z",
 "variants":{"main":"pass","branch":"pass","delta":"pass"},
 "diverged":[{"producer":"extended-receipts","local":"pass","box":"fail","route":"burst:testbox1"}],
 "baseline_dir":"/tmp/baseline"}
EOF
set +e
out="$("$BL" canary --report 2>&1)"; rc=$?
set -e
expect "seeded: exit 0" "[ '$rc' -eq 0 ]"
expect "seeded: prints head" "case \"\$out\" in *'head           abcdef0123456789'*) true;; *) false;; esac"
expect "seeded: prints variant lines" "case \"\$out\" in *'variant main   pass'*) true;; *) false;; esac"
expect "seeded: names the diverged producer" "case \"\$out\" in *'extended-receipts local=pass box=fail route=burst:testbox1'*) true;; *) false;; esac"
expect "seeded: --report took no inflight lock (no canary.inflight left behind)" \
  "[ ! -f '$BURST_LANE_STATE_DIR/current/canary.inflight' ]"
rm -rf "$ROOT2"

echo "== R11: a real (fixtured) canary run journals a cost line =="
ROOT3="$(mktemp -d "${TMPDIR:-/tmp}/canary-r11.XXXXXX")"
repo="$ROOT3/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$repo" remote add origin https://github.com/fixture/repo.git
head_sha="$(git -C "$repo" rev-parse HEAD)"

fake_gh="$ROOT3/fake-gh"
cat > "$fake_gh" <<EOF
#!/usr/bin/env bash
echo '[{"status":"completed","conclusion":"success","headSha":"$head_sha"}]'
EOF
chmod +x "$fake_gh"

fake_gl="$ROOT3/fake-gate-launch"
cat > "$fake_gl" <<EOF
#!/usr/bin/env bash
repo="\$1"; shift
mkdir -p "\$repo/target/autobuilder/receipts"
cat > "\$repo/target/autobuilder/receipts/extended-receipts-receipt.json" <<JSON
{"schema":"autobuilder.extended_receipts.v1","verdict":"pass","route":"burst:testbox1","head_sha":"$head_sha"}
JSON
printf '{"verdict":"pass"}\n' > "\$repo/target/autobuilder/last-verdict.json"
exit 0
EOF
chmod +x "$fake_gl"

export BURST_LANE_STATE_DIR="$ROOT3/state"
export BURST_LANE_JOURNAL="$ROOT3/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
export BURST_LANE_CANARY_REPO="$repo"
export BURST_LANE_GH="$fake_gh"
export BURST_LANE_CANARY_GATE_LAUNCH="$fake_gl"
mkdir -p "$BURST_LANE_STATE_DIR/current"
echo '{"server_id":"testbox1","ip":"127.0.0.1"}' > "$BURST_LANE_STATE_DIR/current/session.json"

set +e
out="$("$BL" canary --no-baseline 2>&1)"; rc=$?
set -e
echo "RC=$rc"; echo "OUT=$out"
expect "run: exit 0 (pass)" "[ '$rc' -eq 0 ]"
expect "run: journal has canary cost line" \
  "grep -qE 'burst-lane  canary  cost  \(eur=[0-9.]+ minutes=[0-9]+\)' '$BURST_LANE_JOURNAL'"
rm -rf "$ROOT3"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canary_ac_r10_r11_report_cost: ALL PASS"
  exit 0
else
  echo "canary_ac_r10_r11_report_cost: assertion(s) FAILED"
  exit 1
fi
