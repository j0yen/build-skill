#!/usr/bin/env bash
# tests/canaryliv_ac4_run_scoped_receipts.sh — PRD-build-burst-canary-
# live-parity AC4 (R3): a variant's receipts_n counts exactly the
# receipts written after ITS OWN launch, never whatever else (stale or
# otherwise) sits in the worktree's target/autobuilder/receipts/.
#
# Fixture: 5 receipts already present with an old mtime before the main
# variant runs; the fake gate-launch writes 3 new ones. receipts_n must
# be 3, and the run directory must hold exactly those three files.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label"; fail=1; fi; }

export PATH="$HERE/fixtures/burst-lane-fake:$PATH"
export BURST_LANE_TEST=1

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canaryliv-ac4.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

repo="$ROOT/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
head_sha="$(git -C "$repo" rev-parse HEAD)"

# --no-baseline keeps this fixture isolated to the main variant's own
# filtering (AC2/AC3 already cover baseline behavior separately) --
# otherwise the baseline call's own receipt, written to the same shared
# R1 worktree moments before the main variant's launch_ts, could land in
# the same wall-clock second and confuse the fresh-file count.
fake_gl="$ROOT/fake-gate-launch"
cat > "$fake_gl" <<'EOF'
#!/usr/bin/env bash
repo="$1"; shift
mkdir -p "$repo/target/autobuilder/receipts"
# 5 pre-existing stale receipts (backdated 1h) plus 3 fresh ones this
# invocation writes -- receipts_n must count only the 3.
i=0
while [ "$i" -lt 5 ]; do
  f="$repo/target/autobuilder/receipts/stale-$i.json"
  echo '{"schema":"autobuilder.extended_receipts.v1","verdict":"pass"}' > "$f"
  touch -d "@$(( $(date +%s) - 3600 ))" "$f"
  i=$((i + 1))
done
i=0
while [ "$i" -lt 3 ]; do
  echo '{"schema":"autobuilder.extended_receipts.v1","verdict":"pass"}' > "$repo/target/autobuilder/receipts/fresh-$i.json"
  i=$((i + 1))
done
printf '{"verdict":"pass"}\n' > "$repo/target/autobuilder/last-verdict.json"
exit 0
EOF
chmod +x "$fake_gl"

wt_root="$ROOT/wt-root"
export BURST_LANE_STATE_DIR="$ROOT/state"
export BURST_LANE_JOURNAL="$ROOT/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
export BURST_LANE_CANARY_REPO="$repo"
export BURST_LANE_CANARY_GATE_LAUNCH="$fake_gl"
export BURST_LANE_CANARY_WORKTREE_ROOT="$wt_root"
export BURST_LANE_CANARY_GATE_STATUS="/bin/true"
mkdir -p "$BURST_LANE_STATE_DIR/current"
echo '{"server_id":"testbox-ac4","ip":"127.0.0.1"}' > "$BURST_LANE_STATE_DIR/current/session.json"

set +e
"$BL" canary --head "$head_sha" --variants main --no-baseline >/dev/null 2>&1
rc=$?
set -e
expect "AC4: canary did not refuse" "[ '$rc' -ne 4 ]"

run_dir="$(find "$BURST_LANE_STATE_DIR/canary-runs" -maxdepth 1 -name '*-main' 2>/dev/null | head -1)/receipts"
expect "AC4: main run dir exists" "[ -d '$run_dir' ]"
expect "AC4: run dir holds exactly 3 files" \
  "[ \"\$(find '$run_dir' -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)\" -eq 3 ]"
expect "AC4: run dir holds exactly the 3 fresh files, not the 5 stale ones" \
  "[ \"\$(find '$run_dir' -maxdepth 1 -name 'fresh-*.json' 2>/dev/null | wc -l)\" -eq 3 ] && [ \"\$(find '$run_dir' -maxdepth 1 -name 'stale-*.json' 2>/dev/null | wc -l)\" -eq 0 ]"
expect "AC4: journal records receipts=3 for the main variant" \
  "grep -qE 'canary  main  \S+  \(head=[^ ]+ receipts=3 ' '$BURST_LANE_JOURNAL'"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canaryliv_ac4_run_scoped_receipts: ALL PASS"
else
  echo "canaryliv_ac4_run_scoped_receipts: FAILED" >&2
fi
exit "$fail"
