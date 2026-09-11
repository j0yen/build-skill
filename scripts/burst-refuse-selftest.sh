#!/usr/bin/env bash
# burst-refuse-selftest.sh — MONEY-CRITICAL regression guard (Joe 2026-09-11
# burst-idle-guard billing incident). Proves the PRIMARY defense holds:
# `burst-lane.sh up` refuses to provision anything unless burst is genuinely
# configured (BUILD_BURST_ENABLED=1 or a populated wm-burst env file — see
# lib/burst-configured.sh). Runs entirely offline: no real hcloud/ssh/rsync
# call is ever reachable from this script, and it never sources the real
# ~/.config/wm-burst/.env (which carries a live HCLOUD_TOKEN) — it points
# burst-lane.sh at an isolated, deliberately-dormant fixture env file
# instead, in an isolated state dir, so this test can never provision a
# real box even if the operator's real env file is populated when it runs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/burst-lane.sh"

T="$(mktemp -d /tmp/burst-refuse-selftest.XXXXXX)"
trap 'rm -rf "$T"' EXIT

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# Isolated, dormant fixture env — mirrors the real ~/.config/wm-burst/.env
# post-2026-06-05 (BUILDER_IP/BUILDER_ID empty), no HCLOUD_TOKEN at all so
# even a bug that DID try to call hcloud would fail closed on auth.
cat > "$T/wm-burst.env" <<'EOF'
export BUILDER_IP=''
export BUILDER_ID=''
EOF

STATE_DIR="$T/state"
mkdir -p "$STATE_DIR"

echo "== burst-lane.sh up refuses when not configured (RedBaron-local policy) =="
set +e
out="$(env -u BUILD_BURST_ENABLED \
  BURST_LANE_ENV_FILE="$T/wm-burst.env" \
  BURST_LANE_STATE_DIR="$STATE_DIR" \
  "$BL" up 2>&1)"
rc=$?
set -e
echo "$out"
expect "up: rc is 3 (non-zero, refused)" "[ $rc -eq 3 ]"
expect "up: refusal message printed" "printf '%s' \"\$out\" | grep -qE 'burst: refused'"
expect "up: no session.json was created" "[ ! -f \"$STATE_DIR/session.json\" ]"

echo "== burst_configured() is conditional, not a permanent lockout =="
# Prove the SAME predicate the gate uses returns true once genuinely
# opted-in — WITHOUT running `up` (a full up under BUILD_BURST_ENABLED=1
# would attempt a real hcloud create; that is explicitly out of scope for
# any automated test — see the skill spec this selftest ships under).
would_proceed="$(BUILD_BURST_ENABLED=1 bash -c '. "$1/lib/burst-configured.sh" && burst_configured && echo would-proceed' _ "$HERE" 2>/dev/null)"
expect "burst_configured() true under BUILD_BURST_ENABLED=1 (gate is conditional)" "[ \"\$would_proceed\" = would-proceed ]"

not_would_proceed="$(env -u BUILD_BURST_ENABLED bash -c '
  BURST_LANE_ENV_FILE="$1" . "$2/lib/burst-configured.sh"
  burst_configured && echo would-proceed || echo refused
' _ "$T/wm-burst.env" "$HERE" 2>/dev/null)"
expect "burst_configured() false against the dormant fixture env (no opt-in)" "[ \"\$not_would_proceed\" = refused ]"

echo "=== $([ $fail -eq 0 ] && echo PASS || echo FAIL) ==="
exit $fail
