#!/usr/bin/env bash
# tests/canaryliv_ac5_ac8_parity_verdict.sh — PRD-build-burst-canary-
# live-parity R5/AC5-AC8: canary_variant_verdict's parity decision, driven
# end-to-end through `burst-lane.sh canary --variants main` with a fake
# gate-launch, rather than unit-testing the verdict function directly —
# canary_ac2_baseline_build_and_diff.sh already proves the baseline-build
# and diff wiring; this file is the missing "does the ROUTED-EVIDENCE-
# JOINED parity rule itself pick the right verdict" coverage AC5-AC8 call
# for, none of which any existing canary_ac*/canaryliv_ac*.sh fixture
# exercises via a real canary_run_variant_main call.
#
# The fake gate-launch tells baseline vs main-variant calls apart by
# --slug (same convention as canary_ac2) and, for the main-variant call
# only, appends "run  routed" journal lines itself (worktree=$1, the
# canary's own pinned worktree, whatever _canary_core happened to create)
# so R4's canary_routed_runs sees them inside [launch_ts, finish_ts]
# without this test needing to guess the worktree path in advance.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label"; fail=1; fi; }

export PATH="$HERE/fixtures/burst-lane-fake:$PATH"
export BURST_LANE_TEST=1

mk_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$repo" remote add origin https://github.com/fixture/repo.git
}

mk_fake_gh() {
  local path="$1" head_sha="$2"
  cat > "$path" <<EOF
#!/usr/bin/env bash
echo '[{"status":"completed","conclusion":"success","headSha":"$head_sha"}]'
EOF
  chmod +x "$path"
}

# mk_fake_gl <path> <n_producers> <main_verdict_flip> <routed_lines> —
# writes a fake gate-launch.sh that, on every invocation, drops
# <n_producers> matching producer receipts (baseline call: all "pass";
# main-variant call: "pass" unless <main_verdict_flip>=1, in which case
# producer1 alone flips to "block") and, on the main-variant call only,
# appends <routed_lines> "run  routed" journal lines for this repo's own
# worktree.
mk_fake_gl() {
  local path="$1" n="$2" flip="$3" routed_lines="$4"
  cat > "$path" <<EOF
#!/usr/bin/env bash
repo="\$1"; shift
slug=""
prev=""
for a in "\$@"; do
  case "\$prev" in --slug) slug="\$a" ;; esac
  prev="\$a"
done
mkdir -p "\$repo/target/autobuilder/receipts"
is_main=0
case "\$slug" in canary-main-*) is_main=1 ;; esac
for i in \$(seq 1 $n); do
  v="pass"
  if [ "\$is_main" = 1 ] && [ "$flip" = 1 ] && [ "\$i" = 1 ]; then v="block"; fi
  cat > "\$repo/target/autobuilder/receipts/producer\$i-receipt.json" <<JSON
{"verdict":"\$v","route":"burst:testbox"}
JSON
done
if [ "\$is_main" = 1 ]; then
  n_rt=$routed_lines
  i=0
  while [ "\$i" -lt "\$n_rt" ]; do
    printf '%s\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)  burst-lane  run  routed  (server_id=testbox worktree=\$repo runs_served=1 exit=0)" >> "\$BURST_LANE_JOURNAL"
    i=\$((i + 1))
  done
fi
printf '{"verdict":"pass"}\n' > "\$repo/target/autobuilder/last-verdict.json"
exit 1
EOF
  chmod +x "$path"
}

run_scenario() {
  # run_scenario <name> <n_producers> <flip> <routed_lines> <min_common_env>
  local name="$1" n="$2" flip="$3" routed_lines="$4" min_common="${5:-}"
  ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canaryliv-ac5-8-$name.XXXXXX")"
  repo="$ROOT/repo"
  mk_repo "$repo"
  head_sha="$(git -C "$repo" rev-parse HEAD)"
  fake_gh="$ROOT/fake-gh"; mk_fake_gh "$fake_gh" "$head_sha"
  fake_gl="$ROOT/fake-gate-launch"; mk_fake_gl "$fake_gl" "$n" "$flip" "$routed_lines"

  export BURST_LANE_STATE_DIR="$ROOT/state"
  export BURST_LANE_JOURNAL="$ROOT/journal.log"
  export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
  export BURST_LANE_CANARY_REPO="$repo"
  export BURST_LANE_GH="$fake_gh"
  export BURST_LANE_CANARY_GATE_LAUNCH="$fake_gl"
  export BURST_LANE_CANARY_WORKTREE_ROOT="$ROOT/wt"
  touch "$BURST_LANE_JOURNAL"
  if [ -n "$min_common" ]; then
    export CANARY_MIN_COMMON_PRODUCERS="$min_common"
  else
    unset CANARY_MIN_COMMON_PRODUCERS 2>/dev/null || true
  fi
  mkdir -p "$BURST_LANE_STATE_DIR/current"
  echo '{"server_id":"testbox","ip":"127.0.0.1"}' > "$BURST_LANE_STATE_DIR/current/session.json"

  set +e
  "$BL" canary --variants main >/dev/null 2>&1
  set -e
}

echo "== AC5: fresh receipts match baseline, no run-routed line, empty route.log -> block cause=not-routed, routed_runs=0 =="
run_scenario ac5 5 0 0
expect "AC5: journal shows main block cause=not-routed" \
  "grep -q 'canary  main  block  (.*cause=not-routed' '$BURST_LANE_JOURNAL'"
expect "AC5: journal shows routed_runs=0" \
  "grep -q 'canary  main  block' '$BURST_LANE_JOURNAL' && grep 'canary  main  block' '$BURST_LANE_JOURNAL' | grep -q 'routed_runs=0'"
rm -rf "$ROOT"

echo "== AC6: 5 common producers agree, two run-routed lines, fake gate exits 1 -> pass, gate_rc=1, common_producers=5 =="
run_scenario ac6 5 0 2
expect "AC6: journal shows main pass" "grep -q 'canary  main  pass  ' '$BURST_LANE_JOURNAL'"
expect "AC6: gate_rc=1 recorded in journal" \
  "grep 'canary  main  pass' '$BURST_LANE_JOURNAL' | grep -q 'gate_rc=1'"
expect "AC6: common_producers=5 recorded" \
  "grep 'canary  main  pass' '$BURST_LANE_JOURNAL' | grep -q 'common_producers=5'"
expect "AC6: canary.json main variant records gate_rc=1" \
  "grep -q '\"gate_rc\": 1' '$BURST_LANE_STATE_DIR/boxes/testbox/canary.json'"
rm -rf "$ROOT"

echo "== AC7: one common producer, pass in baseline / block in run -> diverged, diverged=1, producer named =="
run_scenario ac7 1 1 1
expect "AC7: journal shows main diverged" "grep -q 'canary  main  diverged  ' '$BURST_LANE_JOURNAL'"
expect "AC7: diverged=1 recorded" \
  "grep 'canary  main  diverged' '$BURST_LANE_JOURNAL' | grep -q 'diverged=1'"
expect "AC7: producer1 named as the diverged producer" \
  "grep -q 'producer1' '$BURST_LANE_STATE_DIR/boxes/testbox/canary.json'"
rm -rf "$ROOT"

echo "== AC8: one common producer, CANARY_MIN_COMMON_PRODUCERS unset (default 3) -> block cause=too-few-common:1 =="
run_scenario ac8 1 0 1
expect "AC8: journal shows main block cause=too-few-common:1" \
  "grep -q 'canary  main  block  (.*cause=too-few-common:1' '$BURST_LANE_JOURNAL'"
rm -rf "$ROOT"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canaryliv_ac5_ac8_parity_verdict: ALL PASS"
else
  echo "canaryliv_ac5_ac8_parity_verdict: FAILED" >&2
fi
exit "$fail"
