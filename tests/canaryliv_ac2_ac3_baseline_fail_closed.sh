#!/usr/bin/env bash
# tests/canaryliv_ac2_ac3_baseline_fail_closed.sh — PRD-build-burst-
# canary-live-parity AC2 + AC3 (R2): canary_build_baseline must fail
# closed — a gate that writes no FRESH receipts (even with stale ones
# sitting in the directory, the 2026-09-18 04:36Z bug) never counts as a
# usable baseline, and a baseline directory that has receipts but no
# baseline.json is never trusted as-is, only rebuilt.
#
# Pure fixture: no real box, no network. Same fake-gate-launch convention
# as canaryliv_ac1 / the predecessor canary_ac*.sh suite.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label"; fail=1; fi; }

export PATH="$HERE/fixtures/burst-lane-fake:$PATH"
export BURST_LANE_TEST=1

echo "== AC2: gate exits 1 in <2s, leaves only STALE receipts (mtime before launch) in the worktree =="
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canaryliv-ac2.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

repo="$ROOT/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
head_sha="$(git -C "$repo" rev-parse HEAD)"

# A fake gate-launch that exits 1 and leaves 5 receipts in the worktree's
# receipts dir, but every one backdated to well BEFORE launch_ts -- the
# 2026-09-18 04:36Z incident's exact shape: a receipts directory that is
# NOT empty, but nothing in it was actually written by this launch.
fake_gl="$ROOT/fake-gate-launch"
cat > "$fake_gl" <<'EOF'
#!/usr/bin/env bash
repo="$1"
mkdir -p "$repo/target/autobuilder/receipts"
i=0
while [ "$i" -lt 5 ]; do
  f="$repo/target/autobuilder/receipts/stale-$i.json"
  echo '{"schema":"autobuilder.extended_receipts.v1","verdict":"pass"}' > "$f"
  touch -d "@$(( $(date +%s) - 3600 ))" "$f"
  i=$((i + 1))
done
exit 1
EOF
chmod +x "$fake_gl"

wt_root="$ROOT/wt-root"
export BURST_LANE_STATE_DIR="$ROOT/state"
export BURST_LANE_JOURNAL="$ROOT/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
export BURST_LANE_CANARY_REPO="$repo"
export BURST_LANE_CANARY_GATE_LAUNCH="$fake_gl"
export BURST_LANE_CANARY_WORKTREE_ROOT="$wt_root"
# No real gate-status.sh marker for this fixture slug -> "none", not
# "lost" -- exercises the no-fresh-receipts branch, not wait-lost.
export BURST_LANE_CANARY_GATE_STATUS="/bin/true"
mkdir -p "$BURST_LANE_STATE_DIR/current"
echo '{"server_id":"testbox-ac2","ip":"127.0.0.1"}' > "$BURST_LANE_STATE_DIR/current/session.json"

set +e
"$BL" canary --head "$head_sha" --variants main >/dev/null 2>&1
rc=$?
set -e
expect "AC2: canary exits 4 on baseline-failed refusal" "[ '$rc' -eq 4 ]"
expect "AC2: journal has baseline failed (cause=no-fresh-receipts)" \
  "grep -qE 'canary  baseline  failed  \(cause=no-fresh-receipts' '$BURST_LANE_JOURNAL'"
expect "AC2: journal has canary verdict refused (cause=baseline-failed)" \
  "grep -q 'canary  verdict  refused  (cause=baseline-failed' '$BURST_LANE_JOURNAL'"

baseline_dir="$BURST_LANE_STATE_DIR/canary-baseline/$head_sha/receipts"
expect "AC2: baseline.json records state=failed" \
  "[ \"\$(python3 -c 'import json;print(json.load(open(\"$baseline_dir/baseline.json\")).get(\"state\"))')\" = failed ]"
expect "AC2: baseline.json records zero copied receipts" \
  "[ \"\$(python3 -c 'import json;print(json.load(open(\"$baseline_dir/baseline.json\")).get(\"receipts_n\"))')\" = 0 ]"
expect "AC2: no non-baseline.json receipt file was copied into the baseline dir" \
  "[ \"\$(find '$baseline_dir' -maxdepth 1 -name '*.json' ! -name baseline.json 2>/dev/null | wc -l)\" -eq 0 ]"
expect "AC2: no canary.json written for the box" \
  "[ ! -f '$BURST_LANE_STATE_DIR/boxes/testbox-ac2/canary.json' ]"

rm -rf "$ROOT"
trap - EXIT

echo "== AC3: baseline dir has receipts but no baseline.json -> rebuilt, never trusted =="
ROOT2="$(mktemp -d "${TMPDIR:-/tmp}/canaryliv-ac3.XXXXXX")"
trap 'rm -rf "$ROOT2"' EXIT

repo2="$ROOT2/repo"
mkdir -p "$repo2"
git -C "$repo2" init -q
git -C "$repo2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
head2="$(git -C "$repo2" rev-parse HEAD)"

call_log="$ROOT2/gate-launch-calls.log"
fake_gl2="$ROOT2/fake-gate-launch"
cat > "$fake_gl2" <<EOF
#!/usr/bin/env bash
repo="\$1"; shift
slug=""
prev=""
for a in "\$@"; do
  case "\$prev" in --slug) slug="\$a" ;; esac
  prev="\$a"
done
echo "\$slug" >> "$call_log"
mkdir -p "\$repo/target/autobuilder/receipts"
cat > "\$repo/target/autobuilder/receipts/extended-receipts-receipt.json" <<JSON
{"schema":"autobuilder.extended_receipts.v1","verdict":"pass","route":"local","head_sha":"\$(git -C "\$repo" rev-parse HEAD 2>/dev/null || echo unknown)"}
JSON
printf '{"verdict":"pass"}\n' > "\$repo/target/autobuilder/last-verdict.json"
exit 0
EOF
chmod +x "$fake_gl2"

wt_root2="$ROOT2/wt-root"
export BURST_LANE_STATE_DIR="$ROOT2/state"
export BURST_LANE_JOURNAL="$ROOT2/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
export BURST_LANE_CANARY_REPO="$repo2"
export BURST_LANE_CANARY_GATE_LAUNCH="$fake_gl2"
export BURST_LANE_CANARY_WORKTREE_ROOT="$wt_root2"
export BURST_LANE_CANARY_GATE_STATUS="/bin/true"
mkdir -p "$BURST_LANE_STATE_DIR/current"
echo '{"server_id":"testbox-ac3","ip":"127.0.0.1"}' > "$BURST_LANE_STATE_DIR/current/session.json"

# Pre-seed a baseline dir with a receipt but deliberately NO baseline.json
# -- exactly the shape every pre-R2 baseline directory is in (Migration).
baseline_dir2="$BURST_LANE_STATE_DIR/canary-baseline/$head2/receipts"
mkdir -p "$baseline_dir2"
echo '{"schema":"autobuilder.extended_receipts.v1","verdict":"pass"}' > "$baseline_dir2/pre-existing.json"

set +e
"$BL" canary --head "$head2" --variants main >/dev/null 2>&1
rc2=$?
set -e
expect "AC3: canary did not refuse (rebuild succeeded)" "[ '$rc2' -ne 4 ]"
expect "AC3: gate-launch was invoked for a fresh baseline build despite pre-existing receipts" \
  "grep -q '^canary-baseline-' '$call_log'"
expect "AC3: baseline.json now exists and records state=built" \
  "[ \"\$(python3 -c 'import json;print(json.load(open(\"$baseline_dir2/baseline.json\")).get(\"state\"))')\" = built ]"
expect "AC3: the untrusted pre-existing receipt was not left counted as-is (dir was rebuilt)" \
  "[ ! -f '$baseline_dir2/pre-existing.json' ]"

rm -rf "$ROOT2"
trap - EXIT

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canaryliv_ac2_ac3_baseline_fail_closed: ALL PASS"
else
  echo "canaryliv_ac2_ac3_baseline_fail_closed: FAILED" >&2
fi
exit "$fail"
