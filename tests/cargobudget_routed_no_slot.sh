#!/usr/bin/env bash
# tests/cargobudget_routed_no_slot.sh — PRD-build-cargo-budget-routed-no-slot.
#
# cargo-budget-bin/cargo (the outermost concurrency-budget shim) used to
# acquire one of CARGO_BUDGET_SLOTS local slots via cargo-budget.sh's
# `run --` path for every routable subcommand (test/clippy/deny/nextest/
# build --release) even when the call was actually about to be routed to
# the burst box by burst-lane-bin/cargo behind it — holding a local slot
# for the call's whole REMOTE wall-clock time while burning zero local
# CPU (the 17:07:45Z incident: a routed mcphost gate test run waited
# 250+s on a slot held by unrelated local builds).
#
# Proves:
#   Case A — cargo_route_current() (scripts/lib/cargo-route.sh — the SAME
#     predicate burst-lane-bin/cargo's own routing `if` branches on)
#     resolves to "burst:<id>": cargo-budget-bin/cargo skips slot
#     acquisition entirely and records one ledger row (slotted:false,
#     route:"burst") via cargo-budget.sh's new record-routed subcommand
#     before handing off — and the call still actually runs. Uses
#     CARGO_ROUTE_STATUS_JSON (cargo-route.sh's own documented fixture
#     seam — "a selftest can supply a canned status --json payload
#     without a real box, hcloud, or ssh in the loop") so this is a pure
#     file/env-check fixture, no fake hcloud/ssh/rsync needed: what
#     burst-lane-bin/cargo's OWN independent (real, no override) session
#     check then does with the call — no real session exists in this
#     isolated BURST_LANE_STATE_DIR, so it falls back local — is a
#     separate mechanism this test does not depend on; only cargo-budget-
#     bin/cargo's own no-slot decision is under test here.
#   Case C — the CARGO_BUDGET_SLOT_ROUTED=1 escape hatch restores the old
#     always-slot behavior under the SAME predicate=burst env as case A.
#   Case B (regression guard) — burst not configured at all (RedBaron's
#     actual default policy today), so cargo_route_current() is "local":
#     a slot IS acquired exactly as before (slotted:true, route:"local").
#
# PRD-build-gate-route-cause-parity (2026-09-18): cargo_route_current()
# now also sets CARGO_ROUTE_CAUSE, and cargo-budget-bin/cargo carries it
# into (a) the ledger row's new route_cause field and (b) a route.log
# line of its own (decision local, cause "budget:<cause>") whenever it
# decides local for a routable subcommand — filling the gap where a
# routed-but-actually-local `cargo test` left no record of WHY. Cases A
# and B above are extended to also assert route_cause + the route.log
# line; cases D and E below cover the two other causes that need BURST_LANE
# armed (lane-unarmed, no-active-session) that A/B/C don't exercise.
#   Case D — burst configured, BURST_LANE unarmed (unset): local,
#     cause "lane-unarmed".
#   Case E — burst configured, BURST_LANE=1, CARGO_ROUTE_STATUS_JSON says
#     inactive: local, cause "no-active-session".
# (not-configured is case B; burst is case A — all six causes are
# reachable in principle, but status-probe-failed/no-server-id need a
# broken/malformed real burst-lane.sh call, not just an env-seam value,
# so they are left to cargo-route.sh's own unit coverage rather than
# duplicated here.)
#
# Isolated BURST_LANE_STATE_DIR/BURST_LANE_ENV_FILE/CARGO_BUDGET_STATE_DIR
# per case — never the real state/ dirs or ~/.config/wm-burst/.env.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
BUDGET_DIR="$HERE/cargo-budget-bin"
BURST_DIR="$HERE/burst-lane-bin"

[ -x "$BUDGET_DIR/cargo" ] || { echo "selftest: $BUDGET_DIR/cargo not executable" >&2; exit 2; }
[ -x "$BURST_DIR/cargo" ] || { echo "selftest: $BURST_DIR/cargo not executable" >&2; exit 2; }

export BURST_LANE_TEST=1
[ "${BURST_LANE_TEST:-}" = "1" ] || {
  echo "cargobudget_routed_no_slot: BURST_LANE_TEST not set in own environment — refusing to start" >&2
  exit 2
}

ORIG_PATH="$PATH"
fail=0
ALL_TMPDIRS=()
cleanup() { for d in "${ALL_TMPDIRS[@]:-}"; do rm -rf "$d"; done; }
trap cleanup EXIT

ok() { echo "ok  $1"; }
bad() { echo "FAIL $1" >&2; fail=1; }

# fresh_env — same isolation technique cargo-route-precedence-selftest.sh's
# own fresh_env uses for the burst-lane side (BURST_LANE_STATE_DIR/
# BURST_LANE_ENV_FILE scoped under a disposable $T, never the real
# ~/.claude/skills/build/state/burst-lane or ~/.config/wm-burst/.env).
fresh_env() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/cargobudget-routed.XXXXXX")"
  ALL_TMPDIRS+=("$T")
  export BURST_LANE_STATE_DIR="$T/bl-state"; mkdir -p "$BURST_LANE_STATE_DIR"
  export BURST_LANE_JOURNAL="$T/bl-journal.log"
  export BURST_LANE_ENV_FILE="$T/bl-env"; echo "SNAPSHOT_ID=427125061" > "$BURST_LANE_ENV_FILE"
  export CARGO_BUDGET_JOURNAL="$T/cb-journal.md"
  WT="$T/worktree"; mkdir -p "$WT"
  FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/cargo" <<'EOF'
#!/usr/bin/env bash
echo "fake-cargo-ran: $*"
exit 0
EOF
  chmod +x "$FAKEBIN/cargo"
}

# check_row <case-label> <ledger-file> <want-slotted> <want-route> <slot-cond: exact-neg1|nonneg>
check_row() {
  local label="$1" ledger="$2" want_slotted="$3" want_route="$4" slot_cond="$5"
  local nrows row slotted route slot
  nrows="$(wc -l < "$ledger" 2>/dev/null || echo 0)"
  if [ "$nrows" -eq 1 ]; then ok "$label: exactly one ledger row written"; else bad "$label: expected exactly one ledger row, got $nrows"; fi
  row="$(tail -1 "$ledger" 2>/dev/null)"
  slotted="$(jq -r '.slotted' <<<"$row" 2>/dev/null)"
  route="$(jq -r '.route' <<<"$row" 2>/dev/null)"
  slot="$(jq -r '.slot' <<<"$row" 2>/dev/null)"
  if [ "$slotted" = "$want_slotted" ]; then ok "$label: ledger row slotted:$want_slotted"; else bad "$label: expected slotted:$want_slotted, got slotted:$slotted"; fi
  if [ "$route" = "$want_route" ]; then ok "$label: ledger row route:$want_route"; else bad "$label: expected route:$want_route, got route:$route"; fi
  if [ "$slot_cond" = "exact-neg1" ]; then
    if [ "$slot" = "-1" ]; then ok "$label: ledger row took no slot (slot=-1)"; else bad "$label: expected slot=-1, got slot=$slot"; fi
  else
    if [ "$slot" -ge 0 ] 2>/dev/null; then ok "$label: ledger row took a real slot (slot=$slot)"; else bad "$label: expected slot>=0, got slot=$slot"; fi
  fi
}

# check_route_cause <case-label> <ledger-file> <want-route-cause>
check_route_cause() {
  local label="$1" ledger="$2" want="$3" row cause
  row="$(tail -1 "$ledger" 2>/dev/null)"
  cause="$(jq -r '.route_cause' <<<"$row" 2>/dev/null)"
  if [ "$cause" = "$want" ]; then ok "$label: ledger row route_cause:$want"; else bad "$label: expected route_cause:$want, got route_cause:$cause"; fi
}

# check_route_log_has <case-label> <route-log-file> <decision> <cause> —
# asserts at least one line matches "... <sub> <decision> <cause> ..."
# (sub is always "test" in this file's fixtures).
check_route_log_has() {
  local label="$1" rl="$2" decision="$3" cause="$4"
  if [ -f "$rl" ] && grep -qE " test $decision $cause " "$rl"; then
    ok "$label: route.log has a 'test $decision $cause' line"
  else
    bad "$label: route.log missing 'test $decision $cause' line (file=$rl)"
  fi
}

# check_route_log_count <case-label> <route-log-file> <want-n> — used to
# prove cargo-budget-bin never writes a SECOND "burst routed" line when
# burst-lane-bin (already about to run as $REAL_CARGO) writes its own.
check_route_log_count() {
  local label="$1" rl="$2" want="$3" n
  n="$(wc -l < "$rl" 2>/dev/null || echo 0)"
  if [ "$n" -eq "$want" ]; then ok "$label: route.log has exactly $want line(s)"; else bad "$label: expected $want route.log line(s), got $n"; fi
}

# =========================================================================
# Case A — predicate=burst -> no local slot.
# =========================================================================
echo "=== case A: predicate=burst -> no local slot, ledger row slotted:false route:burst ==="
fresh_env
CB_STATE_A="$T/cb-state-a"
out_a="$(cd "$WT" && BUILD_BURST_ENABLED=1 BURST_LANE=1 \
  CARGO_ROUTE_STATUS_JSON='{"active":true,"server_id":"fakebox1"}' \
  CARGO_BUDGET_STATE_DIR="$CB_STATE_A" \
  PATH="$BUDGET_DIR:$BURST_DIR:$FAKEBIN:$ORIG_PATH" cargo test 2>&1)"
check_row "case A" "$CB_STATE_A/ledger.jsonl" false burst exact-neg1
check_route_cause "case A" "$CB_STATE_A/ledger.jsonl" burst
if grep -q 'fake-cargo-ran: test' <<<"$out_a"; then
  ok "case A: the call still actually ran (fake cargo executed)"
else
  bad "case A: fake cargo marker missing (out_a=$out_a)"
fi
# burst-lane-bin/cargo (already $REAL_CARGO for this call, per real_cargo()
# handing off whenever burst_configured) writes its own route.log line
# right before its own exec — cargo-budget-bin/cargo must not write a
# SECOND one for the same call. Note burst-lane-bin makes its OWN real
# session check (burst-lane.sh status --json, not the
# CARGO_ROUTE_STATUS_JSON fixture cargo_route_current used above) — there
# is no real session in this isolated BURST_LANE_STATE_DIR, so its own
# line legitimately says "local no-session", not "burst routed" (see this
# file's header). What matters here is there is exactly one line, and
# it's burst-lane-bin's (no "budget:" cause — that prefix is only ever
# cargo-budget-bin's own).
check_route_log_count "case A" "$BURST_LANE_STATE_DIR/route.log" 1
if grep -q 'budget:' "$BURST_LANE_STATE_DIR/route.log" 2>/dev/null; then
  bad "case A: route.log unexpectedly has a cargo-budget-bin ('budget:') line — should have deferred entirely to burst-lane-bin"
else
  ok "case A: route.log's one line is burst-lane-bin's own (cargo-budget-bin wrote nothing, no duplicate)"
fi

# =========================================================================
# Case C — escape hatch: CARGO_BUDGET_SLOT_ROUTED=1 restores the old
# always-slot behavior, SAME predicate=burst env as case A.
# =========================================================================
echo "=== case C: CARGO_BUDGET_SLOT_ROUTED=1 -> old always-slot behavior even when predicate=burst ==="
CB_STATE_C="$T/cb-state-c"
out_c="$(cd "$WT" && BUILD_BURST_ENABLED=1 BURST_LANE=1 \
  CARGO_ROUTE_STATUS_JSON='{"active":true,"server_id":"fakebox1"}' \
  CARGO_BUDGET_STATE_DIR="$CB_STATE_C" CARGO_BUDGET_SLOT_ROUTED=1 \
  PATH="$BUDGET_DIR:$BURST_DIR:$FAKEBIN:$ORIG_PATH" cargo test 2>&1)"
check_row "case C" "$CB_STATE_C/ledger.jsonl" true local nonneg
if grep -q 'fake-cargo-ran: test' <<<"$out_c"; then
  ok "case C: the call still actually ran (fake cargo executed via the old path)"
else
  bad "case C: fake cargo marker missing (out_c=$out_c)"
fi

# =========================================================================
# Case B (regression guard) — burst not configured at all -> predicate is
# "local": a slot IS acquired exactly as today.
# =========================================================================
echo "=== case B: predicate=local (burst not configured) -> slot acquired as today ==="
fresh_env
CB_STATE_B="$T/cb-state-b"
out_b="$(cd "$WT" && CARGO_BUDGET_STATE_DIR="$CB_STATE_B" \
  PATH="$BUDGET_DIR:$BURST_DIR:$FAKEBIN:$ORIG_PATH" cargo test 2>&1)"
check_row "case B" "$CB_STATE_B/ledger.jsonl" true local nonneg
check_route_cause "case B" "$CB_STATE_B/ledger.jsonl" not-configured
if grep -q 'fake-cargo-ran: test' <<<"$out_b"; then
  ok "case B: the call still actually ran (fake cargo executed)"
else
  bad "case B: fake cargo marker missing (out_b=$out_b)"
fi
# burst not configured at all -> real_cargo() never hands off to
# burst-lane-bin, so the only route.log line is cargo-budget-bin's own.
check_route_log_count "case B" "$BURST_LANE_STATE_DIR/route.log" 1
check_route_log_has "case B" "$BURST_LANE_STATE_DIR/route.log" local "budget:not-configured"

# =========================================================================
# Case D — predicate=burst, BURST_LANE unarmed (unset) -> local,
# cause "lane-unarmed".
# =========================================================================
echo "=== case D: BUILD_BURST_ENABLED=1 but BURST_LANE unarmed -> local, cause lane-unarmed ==="
fresh_env
CB_STATE_D="$T/cb-state-d"
out_d="$(cd "$WT" && BUILD_BURST_ENABLED=1 \
  CARGO_ROUTE_STATUS_JSON='{"active":true,"server_id":"fakebox1"}' \
  CARGO_BUDGET_STATE_DIR="$CB_STATE_D" \
  PATH="$BUDGET_DIR:$BURST_DIR:$FAKEBIN:$ORIG_PATH" cargo test 2>&1)"
check_row "case D" "$CB_STATE_D/ledger.jsonl" true local nonneg
check_route_cause "case D" "$CB_STATE_D/ledger.jsonl" lane-unarmed
if grep -q 'fake-cargo-ran: test' <<<"$out_d"; then
  ok "case D: the call still actually ran (fake cargo executed)"
else
  bad "case D: fake cargo marker missing (out_d=$out_d)"
fi
check_route_log_has "case D" "$BURST_LANE_STATE_DIR/route.log" local "budget:lane-unarmed"

# =========================================================================
# Case E — predicate=burst, BURST_LANE=1, but the session probe says
# inactive -> local, cause "no-active-session".
# =========================================================================
echo "=== case E: BURST_LANE=1 but session inactive -> local, cause no-active-session ==="
fresh_env
CB_STATE_E="$T/cb-state-e"
out_e="$(cd "$WT" && BUILD_BURST_ENABLED=1 BURST_LANE=1 \
  CARGO_ROUTE_STATUS_JSON='{"active":false}' \
  CARGO_BUDGET_STATE_DIR="$CB_STATE_E" \
  PATH="$BUDGET_DIR:$BURST_DIR:$FAKEBIN:$ORIG_PATH" cargo test 2>&1)"
check_row "case E" "$CB_STATE_E/ledger.jsonl" true local nonneg
check_route_cause "case E" "$CB_STATE_E/ledger.jsonl" no-active-session
if grep -q 'fake-cargo-ran: test' <<<"$out_e"; then
  ok "case E: the call still actually ran (fake cargo executed)"
else
  bad "case E: fake cargo marker missing (out_e=$out_e)"
fi
check_route_log_has "case E" "$BURST_LANE_STATE_DIR/route.log" local "budget:no-active-session"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "cargobudget_routed_no_slot: ALL PASS"
else
  echo "cargobudget_routed_no_slot: assertion(s) FAILED"
fi
exit "$fail"
