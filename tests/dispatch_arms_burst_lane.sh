#!/usr/bin/env bash
# tests/dispatch_arms_burst_lane.sh — PRD-build-dispatch-burst-lane-arm.
#
# GAP (observed 2026-09-18 20:08Z): branch-agent units launched by
# dispatch.sh's systemd-run call (scripts/dispatch.sh launch_entry())
# never exported BURST_LANE=1, so a branch's OWN cargo clippy/test calls
# (cargo_route_current() in scripts/lib/cargo-route.sh checks
# burst_configured() THEN BURST_LANE=1) fell through to route.log
# cause=lane-unarmed and burned RedBaron's local cargo-budget slots, even
# while extend-gate.sh's own bridge (~line 1386) armed the SAME flag for
# the parent gate's own cargo calls. Proves launch_entry() now arms the
# identical bridge for the branch unit itself:
#
#   case (a) — burst_configured() true (a fixture DISPATCH_BURST_ENV file
#     with BUILD_BURST_ENABLED=1) -> the captured systemd-run argv
#     carries `-E BURST_LANE=1` (and `-E BUILD_BURST_ENABLED=1` — armed
#     alongside so the branch's own burst_configured() case (a) doesn't
#     depend on the unit's HOME resolving the same env file).
#   case (b) — not configured (DISPATCH_BURST_ENV pointed at a
#     nonexistent file, same "no-such-burst.env" convention
#     dispatch-selftest.sh already uses for its "off" cases) -> the argv
#     carries no BURST_LANE (or BUILD_BURST_ENABLED) mention at all —
#     never an explicit BURST_LANE=0/BUILD_BURST_ENABLED=0 (burst-
#     configured.sh: an exported 0 is a pinned LOCAL opt-out that wins
#     over the env file, which would break hermetic-build's own child,
#     which pins BUILD_BURST_ENABLED=0 for its own nested cargo call).
#
# Fakes systemd-run only (DISPATCH_SYSTEMD_RUN) — it logs its own argv
# and never actually execs/creates a real unit, so the real systemctl
# query wait_units() makes right after resolves "not active" immediately
# (no such unit) and the tick finishes with no wall-clock wait; nothing
# here depends on CLAUDE_BIN actually running.
#
# Every burst-related env var this test (or anything dispatch.sh
# transitively calls) could read is pinned per-case — never ambient
# state (an operator's real ~/.config/wm-burst/.env, an exported ambient
# BUILD_BURST_ENABLED/BURST_LANE/BURST_LANE_ENV_FILE from the invoking
# shell) leaking in and making a case pass or fail for the wrong reason.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
DISPATCH="$HERE/dispatch.sh"
JQ="${JQ:-$(command -v jq 2>/dev/null || echo /usr/bin/jq)}"

# shellcheck source=../scripts/lib/isolation.sh
source "$HERE/lib/isolation.sh"
unset BUILD_BURST_ENABLED BURST_LANE BURST_LANE_ENV_FILE DISPATCH_BURST_ENV 2>/dev/null || true
selftest_init || { echo "dispatch_arms_burst_lane: selftest_init failed" >&2; exit 1; }

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "ok: $*"; }

PRD_ROOT="$HOME/Documents/PRDs"
mkdir -p "$PRD_ROOT/build-queue" "$PRD_ROOT/built-prds" "$PRD_ROOT/visions" "$STATE_DIR"
echo "# fixture vision" > "$PRD_ROOT/visions/fixture.md"
echo '{"prds":{}}' > "$STATE_DIR/manifest.json"

journal_file() { echo "$(journal_root)/$(date -u +%F).md"; }

FAKE_SYSTEMD_RUN="$BUILD_TEST_ROOT/fake-systemd-run.sh"
SYSTEMD_RUN_LOG="$BUILD_TEST_ROOT/systemd-run-argv.log"
cat > "$FAKE_SYSTEMD_RUN" <<'EOF'
#!/usr/bin/env bash
# Logs its own argv (one line per invocation) and exits 0 WITHOUT ever
# creating a real unit -- launch_entry()'s systemd-run argv is all this
# test cares about; the real systemctl query wait_units() makes right
# after resolves a never-created unit as inactive immediately, so the
# tick finishes with no wall-clock wait.
printf '%s\n' "$*" >> "$FAKE_SYSTEMD_RUN_LOG"
exit 0
EOF
chmod +x "$FAKE_SYSTEMD_RUN"

write_prd() {
  local slug="$1"
  local bi="/tmp/dispatch-arms-burst-lane-$slug-repo"
  mkdir -p "$bi"
  {
    echo "# PRD: $slug"
    echo
    echo "- Status: queued"
    echo "- build_target: shell"
    echo "- build_into: $bi"
    echo "- Vision: visions/fixture.md"
    echo
    echo "## Acceptance criteria"
    echo
    echo "1. P0 — Given a fixture, When dispatch runs, Then it is admitted."
  } > "$PRD_ROOT/build-queue/PRD-$slug.md"
}
clear_queue() { rm -f "$PRD_ROOT/build-queue"/PRD-*.md; }

run_dispatch_case() {
  # run_dispatch_case <burst-env-file>
  local burst_env="$1"
  : > "$SYSTEMD_RUN_LOG"
  FAKE_SYSTEMD_RUN_LOG="$SYSTEMD_RUN_LOG" \
    CLAUDE_BIN="$BUILD_TEST_ROOT/unused-claude-bin" \
    BUILD_STATE_DIR="$STATE_DIR" BUILD_MANIFEST="$STATE_DIR/manifest.json" \
    PRD_DIR="$PRD_ROOT" DISPATCH_LANE="test-lane" DISPATCH_POLL_INTERVAL=1 \
    DISPATCH_SYSTEMD_RUN="$FAKE_SYSTEMD_RUN" \
    DISPATCH_BURST_ENV="$burst_env" \
    "$DISPATCH"
}

# ============================================================================
echo "== case (a): burst_configured() true -> systemd-run argv arms BURST_LANE=1 =="
clear_queue
write_prd armed-case
: > "$(journal_file)"
BURST_ENV_ON="$BUILD_TEST_ROOT/wm-burst-on.env"
echo "BUILD_BURST_ENABLED=1" > "$BURST_ENV_ON"
out=$(run_dispatch_case "$BURST_ENV_ON")
rc=$?
[ "$rc" -eq 0 ] || fail "case (a): expected tick exit 0, got $rc: $out"
echo "$out" | grep -q 'admitted=1 dispatched=1' \
  || fail "case (a): expected admitted=1 dispatched=1, got: $out"
[ -s "$SYSTEMD_RUN_LOG" ] || fail "case (a): fake systemd-run was never invoked"
grep -q -- '-E BURST_LANE=1' "$SYSTEMD_RUN_LOG" \
  || fail "case (a): systemd-run argv missing -E BURST_LANE=1: $(cat "$SYSTEMD_RUN_LOG" 2>/dev/null)"
grep -q -- '-E BUILD_BURST_ENABLED=1' "$SYSTEMD_RUN_LOG" \
  || fail "case (a): systemd-run argv missing -E BUILD_BURST_ENABLED=1: $(cat "$SYSTEMD_RUN_LOG" 2>/dev/null)"
grep -qE 'dispatch  armed-case  burst-lane armed cause=configured' "$(journal_file)" \
  || fail "case (a): journal missing 'burst-lane armed cause=configured' line: $(cat "$(journal_file)")"
[ "$FAILED" -eq 0 ] && pass "case (a)"

# ============================================================================
echo "== case (b): burst_configured() false (knob absent) -> argv carries no -E BURST_LANE flag =="
clear_queue
write_prd unarmed-case
: > "$(journal_file)"
NO_SUCH_ENV="$BUILD_TEST_ROOT/no-such-wm-burst.env"
out=$(run_dispatch_case "$NO_SUCH_ENV")
rc=$?
[ "$rc" -eq 0 ] || fail "case (b): expected tick exit 0, got $rc: $out"
echo "$out" | grep -q 'admitted=1 dispatched=1' \
  || fail "case (b): expected admitted=1 dispatched=1, got: $out"
[ -s "$SYSTEMD_RUN_LOG" ] || fail "case (b): fake systemd-run was never invoked"
# Exact flag+value substrings, not a bare "BURST_LANE"/"BUILD_BURST_
# ENABLED" grep: the SAME captured line also carries the branch's full
# rendered prompt (docs/branch-contract.md directive 3 mentions
# BURST_LANE_STATE_DIR elsewhere, outside the stripped "Burst-lane PATH"
# paragraph, so a bare substring match false-positives on that prose
# regardless of this test's own arm/unarm decision).
grep -q -- '-E BURST_LANE=1' "$SYSTEMD_RUN_LOG" \
  && fail "case (b): systemd-run argv unexpectedly carries -E BURST_LANE=1: $(cat "$SYSTEMD_RUN_LOG" 2>/dev/null)"
grep -q -- '-E BUILD_BURST_ENABLED=1' "$SYSTEMD_RUN_LOG" \
  && fail "case (b): systemd-run argv unexpectedly carries -E BUILD_BURST_ENABLED=1: $(cat "$SYSTEMD_RUN_LOG" 2>/dev/null)"
grep -qE 'dispatch  unarmed-case  burst-lane unarmed cause=not-configured' "$(journal_file)" \
  || fail "case (b): journal missing 'burst-lane unarmed cause=not-configured' line: $(cat "$(journal_file)")"
[ "$FAILED" -eq 0 ] && pass "case (b)"

echo
if [ "$FAILED" -ne 0 ]; then
  echo "SOME FAILURES"
  exit 1
fi
echo "ALL OK"
exit 0
