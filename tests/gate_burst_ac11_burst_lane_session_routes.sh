#!/usr/bin/env bash
# gate_burst_ac11_burst_lane_session_routes.sh — PRD-build-burst-lane-ccx53
# requirement 5.
#
# Given a burst-lane.sh session is up, when should-route runs — even for a
# rust-only tick (python=0), the shape that PRD-build-gate-cloudburst's own
# AC2 says must stay local — then it routes to burst anyway, because a live
# session takes every rust gate regardless of tick mix. Given no session,
# the original mixed-tick-only predicate still applies (proven already by
# ac1/ac2; not re-asserted here beyond the negative case below).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GB="$HERE/../scripts/gate-burst.sh"
[ -x "$GB" ] || { echo "ac11: $GB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gb-ac11.XXXXXX")"
trap 'rm -rf "$T"' EXIT

export GATE_BURST_STATE_DIR="$T/state"; mkdir -p "$GATE_BURST_STATE_DIR"
export GATE_BURST_JOURNAL="$T/journal.md"
export GATE_BURST_ENV_FILE="$T/env"; echo "SNAPSHOT_ID=427125061" > "$GATE_BURST_ENV_FILE"
export BURST_LANE_STATE_DIR="$T/burst-lane-state"; mkdir -p "$BURST_LANE_STATE_DIR"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# ---- negative control: no session, rust-only tick stays local -------------
set +e
out_no_session=$("$GB" should-route --rust 3 --python 0); rc_no_session=$?
set -e
expect "no session + rust-only: stays local (exit 1)" "[ $rc_no_session -eq 1 ]"
expect "no session + rust-only: names single-flavor tick" \
  "grep -q '^local: single-flavor tick' <<<\"\$out_no_session\""

# ---- a burst-lane session is up --------------------------------------------
cat > "$BURST_LANE_STATE_DIR/session.json" <<'EOF'
{
  "server_id":"999",
  "ip":"10.0.0.9",
  "server_type":"ccx53",
  "boot_ts":"2026-09-09T09:00:00Z",
  "boot_epoch":1780000000,
  "ttl_hours":6,
  "hard_ttl_hours":12,
  "runs_served":0,
  "sandbox_ok":"true",
  "teardown_scheduled":false,
  "teardown_epoch":""
}
EOF

set +e
out_rust_only=$("$GB" should-route --rust 3 --python 0); rc_rust_only=$?
set -e
expect "session up + rust-only tick: routes to burst anyway (exit 0)" "[ $rc_rust_only -eq 0 ]"
expect "session up: message names burst"                              "grep -q '^route: burst session up' <<<\"\$out_rust_only\""

set +e
out_python_only=$("$GB" should-route --rust 0 --python 4); rc_python_only=$?
set -e
expect "session up + python-only tick: routes to burst anyway (exit 0)" "[ $rc_python_only -eq 0 ]"

# ---- session goes away: falls back to the original mixed-tick predicate ---
rm -f "$BURST_LANE_STATE_DIR/session.json"
set +e
out_after=$("$GB" should-route --rust 3 --python 0); rc_after=$?
set -e
expect "session torn down: rust-only tick stays local again (exit 1)" "[ $rc_after -eq 1 ]"

echo "=== $([ $fail -eq 0 ] && echo PASS || echo FAIL) ==="
exit $fail
