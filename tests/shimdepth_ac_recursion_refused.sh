#!/usr/bin/env bash
# tests/shimdepth_ac_recursion_refused.sh — stopgap for the live 2026-09-18
# 19:39:57-19:46:04Z defect (pid 3902168, 6,779 `--version passthrough
# unrouted-subcommand` route.log lines): burst-lane-bin/cargo had no
# recursion guard at all, so a PATH carrying a stray shim it didn't know
# to skip let its own real_cargo() resolve that shim as "the real cargo"
# and exec into it forever. This test proves the PRD-build-cargo-shim-
# recursion-guard protocol v2 (2026-09-18T15:10Z ruling) guard now added
# to BOTH cargo-budget-bin/cargo and burst-lane-bin/cargo:
#
#   (a) A PATH/env that makes cargo-budget-bin exec itself (its own
#       realpath pre-seeded into WM_CARGO_SHIM_CHAIN — the direct,
#       non-racy way to force check (2), the same style
#       cargoshim_ac2_third_frame_refused.sh already uses to force check
#       (4) via WM_CARGO_SHIM_DEPTH) must exit 9, print the refusal line
#       to stderr, journal it exactly once via the shared route-log
#       helper (cargo_route_log, cause=recursion-refused), spawn no real
#       cargo, and never hang (wrapped in `timeout 20`).
#   (b) The designed, legitimate chain — cargo-budget-bin hands off to
#       burst-lane-bin (burst_configured forced true, hermetically, via
#       BUILD_BURST_ENABLED=1), which hands off to the real cargo — still
#       runs the fake real cargo exactly once with exit 0. Depth only
#       reaches 2 (2 shim frames) in this chain, under the refusal
#       threshold of 2 (which would be the 3rd frame).
#
# Every env seam a shim reads is pinned below (BURST_LANE,
# BUILD_BURST_ENABLED, BURST_LANE_ENV_FILE, WM_CARGO_SHIM_DEPTH,
# WM_CARGO_SHIM_CHAIN, CARGO_BUDGET_* dirs, HOME) so ambient state on
# whatever box runs this can never leak in (self_ambient_knob_leaks_into_
# rust_tests class of defect).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0

mkdir -p "$WORK/scripts/cargo-budget-bin" "$WORK/scripts/burst-lane-bin" \
         "$WORK/scripts/lib" "$WORK/realbin" "$WORK/fakehome" \
         "$WORK/cargo-budget-dirs" "$WORK/burst-state"

cat > "$WORK/realbin/cargo" <<'EOF'
#!/usr/bin/env bash
echo "$$ $*" >> "$FAKE_CARGO_LOG"
exit 0
EOF
chmod +x "$WORK/realbin/cargo"

cp "$REPO/scripts/cargo-budget-bin/cargo" "$WORK/scripts/cargo-budget-bin/cargo"
cp "$REPO/scripts/burst-lane-bin/cargo" "$WORK/scripts/burst-lane-bin/cargo"
cp "$REPO/scripts/lib/cargo-route.sh" "$WORK/scripts/lib/cargo-route.sh"
cp "$REPO/scripts/lib/burst-configured.sh" "$WORK/scripts/lib/burst-configured.sh"
chmod +x "$WORK/scripts/cargo-budget-bin/cargo" "$WORK/scripts/burst-lane-bin/cargo"

# Pin every env seam these shims read — never inherit the box's real
# ~/.config/wm-burst/.env, real ~/.claude/skills/rustbuild, or real
# ~/brain/journal.
export FAKE_CARGO_LOG="$WORK/real-invocations.log"
export CARGO_BUDGET_JOURNAL="$WORK/journal.md"
export BURST_LANE_STATE_DIR="$WORK/burst-state"
export BURST_ROUTE_LOG="$WORK/burst-state/route.log"
export BURST_LANE_ENV_FILE="$WORK/no-such-env-file"
export HOME="$WORK/fakehome"
unset WM_CARGO_SHIM_TRIP_LOG WM_CARGO_SHIM_DEPTH WM_CARGO_SHIM_CHAIN \
      BURST_SHIM_ACTIVE CARGO_ROUTE_STATUS_JSON CARGO_BUDGET_SLOT_ROUTED \
      2>/dev/null || true

# ---- (a) self-chain refusal: cargo-budget-bin's own realpath already in
#          WM_CARGO_SHIM_CHAIN when it starts ----------------------------
SELF_REAL="$(cd "$WORK/scripts/cargo-budget-bin" && pwd -P)/cargo"
: > "$FAKE_CARGO_LOG"
: > "$CARGO_BUDGET_JOURNAL"
: > "$BURST_ROUTE_LOG"
unset BURST_LANE BUILD_BURST_ENABLED 2>/dev/null || true

rc=0
timeout 20 env \
  WM_CARGO_SHIM_CHAIN="$SELF_REAL" \
  PATH="$WORK/scripts/cargo-budget-bin:$WORK/realbin:/usr/bin:/bin" \
  "$WORK/scripts/cargo-budget-bin/cargo" --version \
  >"$WORK/stdout.a" 2>"$WORK/stderr.a" || rc=$?

if [ "$rc" -eq 9 ]; then
  echo "ok  shimdepth AC(a): self-chain WM_CARGO_SHIM_CHAIN exits 9"
elif [ "$rc" -eq 124 ]; then
  echo "FAIL: self-chain case hung (timeout 20 killed it)" >&2; fail=1
else
  echo "FAIL: self-chain case exited $rc, expected 9" >&2; fail=1
fi

if grep -q "cargo-shim  recursion-refused (depth=" "$WORK/stderr.a" 2>/dev/null; then
  echo "ok  shimdepth AC(a): PRD refusal line on stderr"
else
  echo "FAIL: stderr missing 'cargo-shim  recursion-refused (depth=' line" >&2
  cat "$WORK/stderr.a" >&2 2>/dev/null || true
  fail=1
fi

if grep -q "cargo-shim  recursion-refused (depth=" "$WORK/journal.md" 2>/dev/null; then
  echo "ok  shimdepth AC(a): journal line present"
else
  echo "FAIL: journal missing the recursion-refused line" >&2; fail=1
fi

n_real=$(wc -l < "$WORK/real-invocations.log")
if [ "$n_real" -eq 0 ]; then
  echo "ok  shimdepth AC(a): no real cargo spawned"
else
  echo "FAIL: real cargo was invoked $n_real times on a self-chain refusal" >&2; fail=1
fi

# route.log: exactly one line for this refusal — "journal it once" via
# the shared route-log helper, cause=recursion-refused, and the total
# frame count stays well under threshold(2)+1=3.
n_route=$(grep -c "recursion-refused" "$BURST_ROUTE_LOG" 2>/dev/null || echo 0)
if [ "$n_route" -eq 1 ]; then
  echo "ok  shimdepth AC(a): route.log carries exactly one recursion-refused line (<= threshold+1=3 shim frames)"
else
  echo "FAIL: route.log had $n_route recursion-refused lines, expected 1" >&2
  cat "$BURST_ROUTE_LOG" >&2 2>/dev/null || true
  fail=1
fi

# ---- (b) legitimate chain: cargo-budget-bin -> burst-lane-bin -> real --
: > "$FAKE_CARGO_LOG"
: > "$CARGO_BUDGET_JOURNAL"
: > "$BURST_ROUTE_LOG"
unset WM_CARGO_SHIM_DEPTH WM_CARGO_SHIM_CHAIN BURST_SHIM_ACTIVE 2>/dev/null || true

rc=0
timeout 20 env \
  BUILD_BURST_ENABLED=1 \
  BURST_LANE=0 \
  PATH="$WORK/scripts/cargo-budget-bin:$WORK/realbin:/usr/bin:/bin" \
  "$WORK/scripts/cargo-budget-bin/cargo" --version \
  >"$WORK/stdout.b" 2>"$WORK/stderr.b" || rc=$?

if [ "$rc" -eq 0 ]; then
  echo "ok  shimdepth AC(b): designed 2-shim chain exits 0"
elif [ "$rc" -eq 124 ]; then
  echo "FAIL: designed-chain case hung (timeout 20 killed it)" >&2; fail=1
else
  echo "FAIL: designed-chain case exited $rc, expected 0" >&2
  cat "$WORK/stderr.b" >&2 2>/dev/null || true
  fail=1
fi

n_real=$(wc -l < "$WORK/real-invocations.log")
if [ "$n_real" -eq 1 ]; then
  echo "ok  shimdepth AC(b): fake real cargo ran exactly once"
else
  echo "FAIL: fake real cargo ran $n_real times (expected 1) — chain: $(cat "$WORK/real-invocations.log" 2>/dev/null)" >&2
  fail=1
fi

if grep -q "recursion-refused" "$CARGO_BUDGET_JOURNAL" "$WORK/stderr.b" "$BURST_ROUTE_LOG" 2>/dev/null; then
  echo "FAIL: designed chain wrongly journaled recursion-refused" >&2; fail=1
else
  echo "ok  shimdepth AC(b): no recursion-refused anywhere on the legitimate 2-shim chain"
fi

exit $fail
