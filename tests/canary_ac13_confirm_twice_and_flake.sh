#!/usr/bin/env bash
# tests/canary_ac13_confirm_twice_and_flake.sh — PRD-build-burst-gate-
# canary-invariant AC13: given a first divergence, the daily unit alarms
# through alert-deliver.sh at once, journals confirm=pending, and
# immediately re-runs the diverged variant; given the re-run also
# diverges, cmd_disable runs with confirm=2/2; given the re-run passes,
# dispatch stays enabled and the journal shows "canary flake".
#
# Fixture gate-launch ($FAKE_GATE_LAUNCH) writes one producer receipt
# (extended-receipts) per invocation: baseline/branch calls always "pass";
# the "main" variant's non-baseline call diverges on its FIRST invocation
# always, then either passes (SCENARIO=flake) or diverges again
# (SCENARIO=confirmed) on the re-run -- a counter file distinguishes call
# #1 from #2 deterministically. head_sha is the fixture repo's own real
# HEAD (read at fake-gh time) so `git worktree add` for the branch variant
# succeeds for real. No network, no real cargo/gate work.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"

run_scenario() {
  local scenario="$1"
  local ROOT; ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canary-ac13-$scenario.XXXXXX")"

  local repo="$ROOT/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$repo" remote add origin https://github.com/fixture/repo.git
  local head_sha; head_sha="$(git -C "$repo" rev-parse HEAD)"

  local fake_gh="$ROOT/fake-gh"
  cat > "$fake_gh" <<EOF
#!/usr/bin/env bash
echo '[{"status":"completed","conclusion":"success","headSha":"$head_sha"}]'
EOF
  chmod +x "$fake_gh"

  local call_count_file="$ROOT/main-call-count"
  local fake_gl="$ROOT/fake-gate-launch"
  cat > "$fake_gl" <<EOF
#!/usr/bin/env bash
# \$1=repo/worktree; remaining args carry --scope/--slug/--head/--wait.
repo="\$1"; shift
scope=""; slug=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --scope) scope="\$2"; shift 2 ;;
    --slug) slug="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "\$repo/target/autobuilder/receipts"
verdict="pass"
route="burst:testbox1"
case "\$slug" in
  canary-baseline-*) verdict="pass"; route="local" ;;
  *)
    case "\$scope" in
      main)
        n=\$(( \$(cat "$call_count_file" 2>/dev/null || echo 0) + 1 ))
        echo "\$n" > "$call_count_file"
        if [ "\$n" -eq 1 ]; then
          verdict="fail"
        elif [ "$scenario" = "flake" ]; then
          verdict="pass"
        else
          verdict="fail"
        fi
        ;;
      branch) verdict="pass" ;;
    esac
    ;;
esac
cat > "\$repo/target/autobuilder/receipts/extended-receipts-receipt.json" <<JSON
{"schema":"autobuilder.extended_receipts.v1","verdict":"\$verdict","route":"\$route","head_sha":"$head_sha"}
JSON
printf '{"verdict":"pass"}\n' > "\$repo/target/autobuilder/last-verdict.json"
exit 0
EOF
  chmod +x "$fake_gl"

  local alert_calls="$ROOT/alert-calls.log"
  local fake_alert="$ROOT/fake-alert-deliver"
  cat > "$fake_alert" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$alert_calls"
cat > /dev/null 2>&1 || true
exit 0
EOF
  chmod +x "$fake_alert"

  export PATH="$HERE/fixtures/burst-lane-fake:$PATH"
  export BURST_LANE_TEST=1
  export BURST_LANE_STATE_DIR="$ROOT/state"
  export BURST_LANE_JOURNAL="$ROOT/journal.log"
  export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
  export BURST_LANE_CANARY_REPO="$repo"
  export BURST_LANE_GH="$fake_gh"
  export BURST_LANE_CANARY_GATE_LAUNCH="$fake_gl"
  export ALERT_DELIVER="$fake_alert"
  : > "$BURST_LANE_JOURNAL"

  local box_dir="$BURST_LANE_STATE_DIR/current"
  mkdir -p "$box_dir"
  echo '{"server_id":"testbox1","ip":"127.0.0.1"}' > "$box_dir/session.json"
  # No canary-last-routed-main-pass.json -> cadence check never skips.

  set +e
  out="$("$BL" canary-daily 2>&1)"; rc=$?
  set -e

  echo "RC=$rc"
  echo "OUT=$out"
  echo "JOURNAL:"; cat "$BURST_LANE_JOURNAL"
  echo "ALERTS:"; cat "$alert_calls" 2>/dev/null || echo "(none)"
  echo "MARKER:"; cat "$box_dir/canary-disabled-since.json" 2>/dev/null || echo "(none)"

  RESULT_RC="$rc"
  RESULT_JOURNAL="$BURST_LANE_JOURNAL"
  RESULT_ALERTS="$alert_calls"
  RESULT_MARKER="$box_dir/canary-disabled-since.json"
  RESULT_ROOT="$ROOT"
}

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label"; fail=1; fi; }

echo "=========================================================="
echo "== scenario: confirmed (both runs diverge) -> disable, confirm=2/2 =="
echo "=========================================================="
run_scenario confirmed
expect "confirmed: exit 1" "[ '$RESULT_RC' -eq 1 ]"
expect "confirmed: journal has confirm=pending line" \
  "grep -qE 'canary  diverged  \(confirm=pending producer=extended-receipts route=burst:testbox1\)' '$RESULT_JOURNAL'"
expect "confirmed: alert-deliver invoked with rule=gate-red repo=build-loop" \
  "grep -qE '^gate-red build-loop ' '$RESULT_ALERTS'"
expect "confirmed: journal has confirm=2/2 line" \
  "grep -qE 'canary  diverged  \(confirm=2/2 producer=extended-receipts route=burst:testbox1\)' '$RESULT_JOURNAL'"
expect "confirmed: disable ran (journal disable done cause=canary)" \
  "grep -qE 'disable  done  \(cause=canary\)' '$RESULT_JOURNAL'"
expect "confirmed: canary-disabled-since.json marker written" \
  "[ -f '$RESULT_MARKER' ]"
expect "confirmed: no 'canary flake' line" \
  "! grep -q 'canary  flake' '$RESULT_JOURNAL'"
rm -rf "$RESULT_ROOT"

echo "=========================================================="
echo "== scenario: flake (first diverges, re-run passes) -> stays enabled =="
echo "=========================================================="
run_scenario flake
expect "flake: exit 0" "[ '$RESULT_RC' -eq 0 ]"
expect "flake: journal has confirm=pending line" \
  "grep -qE 'canary  diverged  \(confirm=pending producer=extended-receipts route=burst:testbox1\)' '$RESULT_JOURNAL'"
expect "flake: alert-deliver invoked" \
  "grep -qE '^gate-red build-loop ' '$RESULT_ALERTS'"
expect "flake: journal has canary flake line" \
  "grep -qE 'canary  flake  \(producer=extended-receipts route=burst:testbox1\)' '$RESULT_JOURNAL'"
expect "flake: no confirm=2/2 line" \
  "! grep -q 'confirm=2/2' '$RESULT_JOURNAL'"
expect "flake: no disable ran" \
  "! grep -q 'disable  done' '$RESULT_JOURNAL'"
expect "flake: no canary-disabled-since.json marker" \
  "[ ! -f '$RESULT_MARKER' ]"
rm -rf "$RESULT_ROOT"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canary_ac13_confirm_twice_and_flake: ALL PASS"
  exit 0
else
  echo "canary_ac13_confirm_twice_and_flake: assertion(s) FAILED"
  exit 1
fi
