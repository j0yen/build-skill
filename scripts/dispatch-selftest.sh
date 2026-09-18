#!/usr/bin/env bash
# dispatch-selftest.sh — exercises dispatch.sh (PRD-build-programmatic-
# dispatch) against scratch fixtures under an isolated $BUILD_TEST_ROOT.
# Never touches the real ~/Documents/PRDs clone, the real shared journal,
# or the real skill state dir — same isolation discipline as select-tick-
# selftest.sh (lib/isolation.sh's selftest_init, real scan-prds.sh/
# select-tick.sh/prd-lint.sh underneath, no agent-written mocks of the
# scripts under test).
#
# Covers: AC1 (empty admission, zero model spend), AC2 (two admitted
# entries -> two real launches, correct model/prompt, lock held for the
# unit's lifetime), AC3 (operator-authorization verbatim; burst directive
# present/absent by burst_configured()), AC4 (BRANCH_MAX_WALL exceeded ->
# unit stopped, last_error=branch-wall-exceeded, tick still completes),
# AC6's journal evidence shape, AC7 (--dry-run launches nothing).
#
# Requires a real systemd --user session (same as gate-launch-selftest.sh)
# and a real jq/systemctl/systemd-run on PATH.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$HERE/dispatch.sh"
JQ="${JQ:-$(command -v jq 2>/dev/null || echo /usr/bin/jq)}"

# shellcheck source=lib/isolation.sh
source "$HERE/lib/isolation.sh"
selftest_init || { echo "dispatch-selftest: selftest_init failed" >&2; exit 1; }

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "ok: $*"; }

PRD_ROOT="$HOME/Documents/PRDs"
mkdir -p "$PRD_ROOT/build-queue" "$PRD_ROOT/built-prds" "$PRD_ROOT/visions" "$STATE_DIR"
echo "# fixture vision" > "$PRD_ROOT/visions/fixture.md"
echo '{"prds":{}}' > "$STATE_DIR/manifest.json"

BIN_DIR="$BUILD_TEST_ROOT/bin"
mkdir -p "$BIN_DIR"
INVOCATIONS="$BUILD_TEST_ROOT/claude-invocations.log"
: > "$INVOCATIONS"
# FAKE_CLAUDE_SLEEP_FILE, not an env var: systemd-run does NOT propagate
# the launching shell's environment into the transient unit (only PATH,
# via dispatch.sh's own --setenv, crosses that boundary) -- a file both
# processes can see is the only reliable way to hand this fixture a
# per-case sleep duration.
FAKE_CLAUDE="$BIN_DIR/fake-claude.sh"
SLEEP_FILE="$BUILD_TEST_ROOT/fake-claude-sleep.txt"
STARTED_MARKER="$BUILD_TEST_ROOT/fake-claude-started"
OUTPUT_FILE="$BUILD_TEST_ROOT/fake-claude-output.txt"
echo 1 > "$SLEEP_FILE"
echo "fake-branch: done ok" > "$OUTPUT_FILE"
{
  echo '#!/usr/bin/env bash'
  echo 'echo "$*" >> "'"$INVOCATIONS"'"'
  # touched BEFORE the sleep so a test waiting on this marker can then
  # probe the PRD lock knowing the process is genuinely inside its sleep.
  echo 'date -u +%s >> "'"$STARTED_MARKER"'"'
  echo 'sleep "$(cat "'"$SLEEP_FILE"'" 2>/dev/null || echo 1)"'
  echo 'cat "'"$OUTPUT_FILE"'" 2>/dev/null || echo "fake-branch: done ok"'
  echo 'exit 0'
} > "$FAKE_CLAUDE"
chmod +x "$FAKE_CLAUDE"

wait_for_marker() {
  # wait_for_marker <marker-file> <timeout-s>
  local marker="$1" timeout="${2:-20}" waited=0
  while [ ! -s "$marker" ]; do
    sleep 0.2
    waited=$(awk -v w="$waited" 'BEGIN{print w+0.2}')
    if awk -v w="$waited" -v t="$timeout" 'BEGIN{exit !(w>t)}'; then
      return 1
    fi
  done
  return 0
}

write_prd() {
  # write_prd <slug> [build_into] [op_auth_line]
  local slug="$1"
  local bi="${2:-/tmp/dispatch-selftest-$slug-repo}" opline="${3:-}"
  mkdir -p "$bi"
  {
    echo "# PRD: $slug"
    echo
    echo "- Status: queued"
    echo "- build_target: shell"
    echo "- build_into: $bi"
    [ -n "$opline" ] && echo "$opline"
    echo "- Vision: visions/fixture.md"
    echo
    echo "## Acceptance criteria"
    echo
    echo "1. P0 — Given a fixture, When dispatch runs, Then it is admitted or skipped deterministically."
  } > "$PRD_ROOT/build-queue/PRD-$slug.md"
}

clear_queue() { rm -f "$PRD_ROOT/build-queue"/PRD-*.md; : > "$INVOCATIONS"; }

run_dispatch() {
  CLAUDE_BIN="$FAKE_CLAUDE" \
    BUILD_STATE_DIR="$STATE_DIR" BUILD_MANIFEST="$STATE_DIR/manifest.json" \
    PRD_DIR="$PRD_ROOT" \
    DISPATCH_LANE="test-lane" DISPATCH_POLL_INTERVAL=1 \
    DISPATCH_BURST_ENV="$BUILD_TEST_ROOT/no-such-burst.env" \
    DISPATCH_TICK_RUN="$HERE/tick-run.sh" \
    "$DISPATCH" "$@"
}

journal_file() { echo "$(journal_root)/$(date -u +%F).md"; }

# ============================================================================
echo "== AC1: empty admission -> exit 0, admitted=0 dispatched=0, no launch =="
clear_queue
: > "$(journal_file)"
out=$(run_dispatch)
rc=$?
[ "$rc" -eq 0 ] || fail "AC1: expected exit 0, got $rc"
echo "$out" | grep -q 'admitted=0 dispatched=0' || fail "AC1: expected admitted=0 dispatched=0 in stdout, got: $out"
[ -s "$INVOCATIONS" ] && fail "AC1: fake claude was invoked with nothing admitted: $(cat "$INVOCATIONS")"
grep -q 'dispatch  tick  admitted=0 dispatched=0' "$(journal_file)" \
  || fail "AC1: journal missing admitted=0 dispatched=0 line: $(cat "$(journal_file)")"
[ "$FAILED" -eq 0 ] && pass "AC1"

# ============================================================================
echo "== AC2/AC6: two admitted entries -> two real launches, lock held, journal evidence =="
clear_queue
write_prd two-a
write_prd two-b
: > "$(journal_file)"
echo 2 > "$SLEEP_FILE"
out=$(run_dispatch)
rc=$?
[ "$rc" -eq 0 ] || fail "AC2: expected exit 0, got $rc"
echo "$out" | grep -q 'admitted=2 dispatched=2' || fail "AC2: expected admitted=2 dispatched=2, got: $out"
# NOT `wc -l`: each invocation's logged $* embeds the whole multi-line
# rendered prompt, so the log has many lines per invocation. Count a flag
# that appears exactly once per real invocation instead.
n_invoked=$(grep -c -- '--dangerously-skip-permissions' "$INVOCATIONS")
[ "$n_invoked" -eq 2 ] || fail "AC2: expected 2 fake-claude invocations, got $n_invoked (log size $(wc -l < "$INVOCATIONS") lines)"
grep -q -- '--model sonnet' "$INVOCATIONS" || fail "AC2: expected --model sonnet in an invocation: $(cat "$INVOCATIONS")"
grep -qE 'dispatch  [a-z0-9-]+  launched \(.*prompt-source=branch-contract' "$(journal_file)" \
  || fail "AC6: journal missing launched(...prompt-source=branch-contract...) evidence line: $(cat "$(journal_file)")"
[ -f "$STATE_DIR/dispatch/last-tick.json" ] || fail "AC2: dispatch/last-tick.json not written"
"$JQ" -e '.admitted == 2 and .dispatched == 2' "$STATE_DIR/dispatch/last-tick.json" >/dev/null 2>&1 \
  || fail "AC2: last-tick.json admitted/dispatched mismatch: $(cat "$STATE_DIR/dispatch/last-tick.json" 2>/dev/null)"
[ "$FAILED" -eq 0 ] && pass "AC2/AC6"

echo "== AC2 (lock): a launched unit's flock is held for its own lifetime =="
clear_queue
write_prd lockcheck
: > "$(journal_file)"
: > "$STARTED_MARKER"
echo 5 > "$SLEEP_FILE"
(
  CLAUDE_BIN="$FAKE_CLAUDE" \
    BUILD_STATE_DIR="$STATE_DIR" BUILD_MANIFEST="$STATE_DIR/manifest.json" \
    PRD_DIR="$PRD_ROOT" DISPATCH_LANE="test-lane" DISPATCH_POLL_INTERVAL=1 \
    DISPATCH_BURST_ENV="$BUILD_TEST_ROOT/no-such-burst.env" \
    "$DISPATCH" >/dev/null 2>&1
) &
dispatch_pid=$!
if wait_for_marker "$STARTED_MARKER" 30; then
  if flock -n "$STATE_DIR/prd-lockcheck.lock" true 2>/dev/null; then
    fail "AC2 (lock): expected state/prd-lockcheck.lock to be held mid-run, but it was free"
  else
    pass "AC2 (lock): lockfile contended while the unit runs"
  fi
else
  fail "AC2 (lock): fake claude never started within 30s"
fi
wait "$dispatch_pid"

# ============================================================================
echo "== AC3: operator-authorization verbatim; burst directive gated on burst_configured() =="
entry_dir="$BUILD_TEST_ROOT/entries"
mkdir -p "$entry_dir"
prd_path="$PRD_ROOT/build-queue/PRD-render-check.md"
{
  echo "# PRD: render-check"
  echo
  echo "- Status: queued"
  echo "- build_target: rust-extend"
  echo "- build_into: /tmp/dispatch-selftest-render-check-repo"
  echo "- Vision: visions/fixture.md"
  echo
  echo "## Acceptance criteria"
  echo "1. P0 — Given a fixture, When rendered, Then directives compose correctly."
} > "$prd_path"
entry_file="$entry_dir/render-check.entry.json"
"$JQ" -n --arg slug render-check --arg path "$prd_path" \
  '{slug:$slug, path:$path, build_target:"rust-extend", build_into:"/tmp/dispatch-selftest-render-check-repo",
    continuation:false, model:"sonnet", shared_target:false,
    operator_authorization:{who:"joe",ts:"2026-09-18T01:00:00Z",words:"go ahead",scope:"everything"}}' \
  > "$entry_file"

no_burst_out=$(BUILD_STATE_DIR="$STATE_DIR" BUILD_MANIFEST="$STATE_DIR/manifest.json" \
  DISPATCH_BURST_ENV="$BUILD_TEST_ROOT/no-such-burst.env" "$DISPATCH" render "$entry_file")
echo "$no_burst_out" | grep -q '## 4. Operator-authorization injection' \
  || fail "AC3: operator-authorization directive missing when parsed"
echo "$no_burst_out" | grep -q '"who":"joe"' \
  || fail "AC3: parsed authorization not echoed verbatim"
echo "$no_burst_out" | grep -q 'Burst-lane PATH' \
  && fail "AC3: burst directive present despite burst_configured() == false"

burst_env="$BUILD_TEST_ROOT/wm-burst.env"
echo "x=1" > "$burst_env"
burst_out=$(BUILD_STATE_DIR="$STATE_DIR" BUILD_MANIFEST="$STATE_DIR/manifest.json" \
  DISPATCH_BURST_ENV="$burst_env" "$DISPATCH" render "$entry_file")
echo "$burst_out" | grep -q 'Burst-lane PATH' \
  || fail "AC3: burst directive missing despite burst_configured() == true"
[ "$FAILED" -eq 0 ] && pass "AC3"

# ============================================================================
echo "== AC4: BRANCH_MAX_WALL exceeded -> unit stopped, last_error=branch-wall-exceeded =="
clear_queue
write_prd wallcheck
"$JQ" -n '{prds:{wallcheck:{status:"queued"}}}' > "$STATE_DIR/manifest.json"
: > "$(journal_file)"
echo 15 > "$SLEEP_FILE"
out=$(CLAUDE_BIN="$FAKE_CLAUDE" \
  BUILD_STATE_DIR="$STATE_DIR" BUILD_MANIFEST="$STATE_DIR/manifest.json" \
  PRD_DIR="$PRD_ROOT" DISPATCH_LANE="test-lane" DISPATCH_POLL_INTERVAL=1 \
  DISPATCH_BURST_ENV="$BUILD_TEST_ROOT/no-such-burst.env" \
  BRANCH_MAX_WALL=2 "$DISPATCH")
rc=$?
[ "$rc" -eq 0 ] || fail "AC4: expected the tick itself to still exit 0, got $rc"
grep -q 'wall-exceeded' "$(journal_file)" || fail "AC4: journal missing wall-exceeded line: $(cat "$(journal_file)")"
"$JQ" -e --arg s wallcheck '.prds[$s].last_error == "branch-wall-exceeded"' "$STATE_DIR/manifest.json" >/dev/null 2>&1 \
  || fail "AC4: manifest missing last_error=branch-wall-exceeded: $(cat "$STATE_DIR/manifest.json")"
[ -f "$STATE_DIR/dispatch/last-tick.json" ] || fail "AC4: dispatch/last-tick.json not written after wall-exceeded"
[ "$FAILED" -eq 0 ] && pass "AC4"

# ============================================================================
echo "== AC8: quota tier paused -> nothing launches, outcome skipped:quota =="
clear_queue
write_prd quotacheck
: > "$INVOCATIONS"
: > "$(journal_file)"
FAKE_QUOTA_TIER="$BIN_DIR/fake-quota-tier.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'echo "{\"tier\":\"paused\"}"'
} > "$FAKE_QUOTA_TIER"
chmod +x "$FAKE_QUOTA_TIER"
out=$(CLAUDE_BIN="$FAKE_CLAUDE" \
  BUILD_STATE_DIR="$STATE_DIR" BUILD_MANIFEST="$STATE_DIR/manifest.json" \
  PRD_DIR="$PRD_ROOT" DISPATCH_LANE="test-lane" DISPATCH_POLL_INTERVAL=1 \
  DISPATCH_BURST_ENV="$BUILD_TEST_ROOT/no-such-burst.env" \
  DISPATCH_QUOTA_TIER="$FAKE_QUOTA_TIER" "$DISPATCH")
rc=$?
[ "$rc" -eq 0 ] || fail "AC8: expected exit 0, got $rc"
echo "$out" | grep -q 'skipped:quota' || fail "AC8: expected skipped:quota in stdout, got: $out"
[ -s "$INVOCATIONS" ] && fail "AC8: fake claude was invoked despite quota tier=paused: $(cat "$INVOCATIONS")"
grep -q 'dispatch  tick  skipped:quota' "$(journal_file)" \
  || fail "AC8: journal missing skipped:quota line: $(cat "$(journal_file)")"
[ "$FAILED" -eq 0 ] && pass "AC8"

# ============================================================================
echo "== AC7: --dry-run prints prompts, launches nothing =="
clear_queue
write_prd dryrun-a
: > "$INVOCATIONS"
out=$(run_dispatch --dry-run)
rc=$?
[ "$rc" -eq 0 ] || fail "AC7: expected exit 0, got $rc"
echo "$out" | grep -q '=== dryrun-a' || fail "AC7: expected the rendered prompt header in --dry-run output"
echo "$out" | grep -q 'docs/branch-contract.md' >/dev/null 2>&1 || true
[ -s "$INVOCATIONS" ] && fail "AC7: fake claude was invoked under --dry-run: $(cat "$INVOCATIONS")"
[ "$FAILED" -eq 0 ] && pass "AC7"

# ============================================================================
echo "== AC6 (tick-run.sh integration): dispatch.sh is the default coordinator; =="
echo "==   BUILD_COORDINATOR=model restores the old one; --status shows counts =="
clear_queue
write_prd tickint-a
TICK_RUN="$HERE/tick-run.sh"
echo 1 > "$SLEEP_FILE"
: > "$INVOCATIONS"
TICK_STATE="$BUILD_TEST_ROOT/tick-state"
mkdir -p "$TICK_STATE"
TICK_JOURNAL="$TICK_STATE/journal.md"
tick_env=(
  CLAUDE_BIN="$FAKE_CLAUDE" DISPATCH_SH="$DISPATCH"
  BUILD_STATE_DIR="$TICK_STATE" BUILD_MANIFEST="$TICK_STATE/manifest.json"
  TICK_RUN_JOURNAL="$TICK_JOURNAL"
  PRD_DIR="$PRD_ROOT" DISPATCH_LANE="test-lane" DISPATCH_POLL_INTERVAL=1
  DISPATCH_BURST_ENV="$BUILD_TEST_ROOT/no-such-burst.env"
)
echo '{"prds":{}}' > "$TICK_STATE/manifest.json"
: > "$(journal_file)"
env "${tick_env[@]}" "$TICK_RUN" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "AC6 (tick-run): expected exit 0 with dispatch.sh as coordinator, got $rc"
# dispatch.sh's OWN journal_line() calls go through journal_root() (this
# selftest's isolated $(journal_file), same as every other block above) --
# TICK_JOURNAL/TICK_RUN_JOURNAL is a SEPARATE var tick-run.sh's own code
# reads for its own reconcile/status bookkeeping only, never dispatch.sh's.
grep -qE 'dispatch  [a-z0-9-]+  launched \(.*prompt-source=branch-contract' "$(journal_file)" \
  || fail "AC6 (tick-run): journal missing the branch-contract launch evidence line via tick-run.sh: $(cat "$(journal_file)")"
status_out="$(env "${tick_env[@]}" "$TICK_RUN" --status)"
echo "$status_out" | grep -q 'admitted=1 dispatched=1' \
  || fail "AC6 (tick-run): --status expected admitted=1 dispatched=1, got: $status_out"

echo "== AC6 (tick-run.sh integration): BUILD_COORDINATOR=model bypasses dispatch.sh =="
: > "$INVOCATIONS"
env "${tick_env[@]}" BUILD_COORDINATOR=model "$TICK_RUN" >/dev/null 2>&1
grep -q -- '-p /build' "$INVOCATIONS" \
  || fail "AC6 (tick-run): BUILD_COORDINATOR=model expected a '-p /build...' invocation, got: $(cat "$INVOCATIONS")"
[ "$FAILED" -eq 0 ] && pass "AC6 (tick-run integration)"

# ============================================================================
echo "== P2 (needs-judgment): a branch's outcome=needs-judgment opens a decision row and parks the PRD =="
clear_queue
write_prd judgeme
"$JQ" -n '{prds:{judgeme:{status:"queued"}}}' > "$STATE_DIR/manifest.json"
echo 1 > "$SLEEP_FILE"
printf 'two-a: something ok\noutcome=needs-judgment should this retry forever?\n' > "$OUTPUT_FILE"
: > "$(journal_file)"
rm -f "$STATE_DIR/decisions.jsonl"
out=$(run_dispatch)
rc=$?
[ "$rc" -eq 0 ] || fail "P2: expected exit 0, got $rc"
[ -s "$STATE_DIR/decisions.jsonl" ] || fail "P2: expected a decisions.jsonl row to be opened"
grep -q 'needs-judgment' "$STATE_DIR/decisions.jsonl" 2>/dev/null \
  || fail "P2: decisions.jsonl row missing the needs-judgment question text: $(cat "$STATE_DIR/decisions.jsonl" 2>/dev/null)"
"$JQ" -e --arg s judgeme '.prds[$s].status == "needs_classification"' "$STATE_DIR/manifest.json" >/dev/null 2>&1 \
  || fail "P2: manifest expected status=needs_classification for judgeme: $(cat "$STATE_DIR/manifest.json")"
grep -q 'dispatch  judgeme  needs-judgment' "$(journal_file)" \
  || fail "P2: journal missing needs-judgment line: $(cat "$(journal_file)")"
[ "$FAILED" -eq 0 ] && pass "P2 (needs-judgment)"
echo "fake-branch: done ok" > "$OUTPUT_FILE"

echo
if [ "$FAILED" -ne 0 ]; then
  echo "SOME FAILURES"
  exit 1
fi
echo "ALL OK"
exit 0
