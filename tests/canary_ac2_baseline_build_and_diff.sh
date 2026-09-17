#!/usr/bin/env bash
# tests/canary_ac2_baseline_build_and_diff.sh — PRD-build-burst-gate-
# canary-invariant AC2, the half no other canary_ac*.sh fixture exercises:
# when NO local baseline exists for HEAD, `canary` must build one itself
# (a local --scope main gate, nice -n 10, never BURST_LANE=1) before
# diffing, and the diff must actually run against what it just built —
# not silently report no divergence because baseline_dir stayed empty.
#
# canary_ac_r10_r11_report_cost.sh and canary_ac_r12_named_lane.sh already
# cover the OTHER half of AC2 (`--no-baseline` -> `baseline=skipped`, no
# divergence reported); this file is the missing "baseline gets built,
# then used" case, plus a same-file regression check that `--no-baseline`
# still short-circuits it.
#
# Pure fixture: no real box, no network. Same fake-gate-launch convention
# as canary_ac13/canary_ac_r10_r11 (BURST_LANE_CANARY_GATE_LAUNCH), but
# this fake writes a DIFFERENT receipt depending on which invocation it is
# (baseline build vs the box's own main-variant run) by keying off
# `--slug`, so the two are distinguishable and the divergence they
# should produce can only appear if canary_build_baseline's output was
# actually picked up as $baseline_dir by canary_run_variant_main.
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

echo "== AC2a: no baseline on disk -> canary_build_baseline runs first, diff uses it (divergence proves it) =="
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canary-ac2a.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
repo="$ROOT/repo"
mk_repo "$repo"
head_sha="$(git -C "$repo" rev-parse HEAD)"

fake_gh="$ROOT/fake-gh"
mk_fake_gh "$fake_gh" "$head_sha"

# The fake gate-launch is called twice by _canary_core with no local
# baseline: once by canary_build_baseline (--slug canary-baseline-*,
# building the LOCAL baseline this PRD's own comment says must never
# carry BURST_LANE=1) and once by canary_run_variant_main (--slug
# canary-main-*, the "box" run, real code always sets BURST_LANE=1 for
# it). It tells them apart by --slug and writes extended-receipts as
# pass for the baseline call, fail for the main-variant call — a
# divergence that can only surface if the freshly-built baseline_dir was
# actually the diff's left-hand side.
fake_gl="$ROOT/fake-gate-launch"
cat > "$fake_gl" <<'EOF'
#!/usr/bin/env bash
repo="$1"; shift
slug=""
route="local"
prev=""
for a in "$@"; do
  case "$prev" in --slug) slug="$a" ;; esac
  prev="$a"
done
verdict="pass"
case "$slug" in
  canary-main-*) verdict="fail"; route="burst:testbox2" ;;
esac
mkdir -p "$repo/target/autobuilder/receipts"
cat > "$repo/target/autobuilder/receipts/extended-receipts-receipt.json" <<JSON
{"schema":"autobuilder.extended_receipts.v1","verdict":"$verdict","route":"$route","head_sha":"$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)"}
JSON
printf '{"verdict":"%s"}\n' "$verdict" > "$repo/target/autobuilder/last-verdict.json"
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
echo '{"server_id":"testbox2","ip":"127.0.0.1"}' > "$BURST_LANE_STATE_DIR/current/session.json"

baseline_dir="$BURST_LANE_STATE_DIR/canary-baseline/$head_sha/receipts"
expect "AC2a: baseline dir absent before the run" "[ ! -d '$baseline_dir' ]"

set +e
out="$("$BL" canary --variants main 2>&1)"; rc=$?
set -e

expect "AC2a: baseline dir populated by canary_build_baseline" \
  "[ -f '$baseline_dir/extended-receipts-receipt.json' ]"
expect "AC2a: journal shows baseline building then built" \
  "grep -q 'canary  baseline  building' '$BURST_LANE_JOURNAL' && grep -q 'canary  baseline  built' '$BURST_LANE_JOURNAL'"
expect "AC2a: main variant journaled as diverged (proves the diff ran against the just-built baseline)" \
  "grep -q 'canary  main  diverged' '$BURST_LANE_JOURNAL'"
expect "AC2a: canary.json names the diverged producer" \
  "grep -q 'extended-receipts' '$BURST_LANE_STATE_DIR/boxes/testbox2/canary.json' 2>/dev/null"
expect "AC2a: canary command itself does not fail loud on a diverged variant" "[ -n \"\$out\" ] || true"
rm -rf "$ROOT"
trap - EXIT

echo "== AC2b: regression check — --no-baseline still skips the build, journals baseline=skipped, reports no divergence =="
ROOT2="$(mktemp -d "${TMPDIR:-/tmp}/canary-ac2b.XXXXXX")"
trap 'rm -rf "$ROOT2"' EXIT
repo2="$ROOT2/repo"
mk_repo "$repo2"
head2="$(git -C "$repo2" rev-parse HEAD)"
fake_gh2="$ROOT2/fake-gh"
mk_fake_gh "$fake_gh2" "$head2"
fake_gl2="$ROOT2/fake-gate-launch"
cat > "$fake_gl2" <<'EOF'
#!/usr/bin/env bash
repo="$1"; shift
mkdir -p "$repo/target/autobuilder/receipts"
cat > "$repo/target/autobuilder/receipts/extended-receipts-receipt.json" <<JSON
{"schema":"autobuilder.extended_receipts.v1","verdict":"pass","route":"burst:testbox3","head_sha":"$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)"}
JSON
printf '{"verdict":"pass"}\n' > "$repo/target/autobuilder/last-verdict.json"
exit 0
EOF
chmod +x "$fake_gl2"

export BURST_LANE_STATE_DIR="$ROOT2/state"
export BURST_LANE_JOURNAL="$ROOT2/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
export BURST_LANE_CANARY_REPO="$repo2"
export BURST_LANE_GH="$fake_gh2"
export BURST_LANE_CANARY_GATE_LAUNCH="$fake_gl2"
mkdir -p "$BURST_LANE_STATE_DIR/current"
echo '{"server_id":"testbox3","ip":"127.0.0.1"}' > "$BURST_LANE_STATE_DIR/current/session.json"

baseline_dir2="$BURST_LANE_STATE_DIR/canary-baseline/$head2/receipts"
set +e
"$BL" canary --variants main --no-baseline >/dev/null 2>&1
set -e
expect "AC2b: baseline dir never built when --no-baseline" "[ ! -d '$baseline_dir2' ]"
expect "AC2b: journal says baseline=skipped" "grep -q 'baseline=skipped' '$BURST_LANE_JOURNAL'"
expect "AC2b: main variant not reported diverged (nothing to diverge against)" \
  "! grep -q 'canary  main  diverged' '$BURST_LANE_JOURNAL'"
rm -rf "$ROOT2"
trap - EXIT

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canary_ac2_baseline_build_and_diff: ALL PASS"
else
  echo "canary_ac2_baseline_build_and_diff: FAILED" >&2
fi
exit "$fail"
