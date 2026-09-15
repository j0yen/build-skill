#!/usr/bin/env bash
# scripts/failloud-selftest.sh — acceptance harness for
# PRD-build-fail-loud-evidence-kept (test_prefix `failloud`). One real
# implementation, thin per-AC wrappers under tests/failloud_ac<N>_*.sh pull
# individual `ok  AC<N>: ...` labels out of this one run — same convention
# scripts/archive-commit-selftest.sh already uses (no hand-duplicated
# second copy of the logic to drift from the real scripts/lib/probe.sh,
# scripts/burst-lane.sh, scripts/extend-gate.sh, scripts/select-guard.sh,
# and scripts/lane-status.sh code paths under test).
#
# Runs standalone, offline, no real hcloud/ssh/rsync/network calls — every
# site under test is exercised via a fake SSH_BIN/RSYNC_BIN or a stubbed
# function (documented per-AC below). Isolated: BURST_LANE_STATE_DIR,
# BURST_LANE_JOURNAL, PROBE_LOG_DIR/STATE_DIR, PRD_DIR, BUILD_STATE_DIR all
# point under a disposable tempdir per case — nothing here ever touches
# $HOME/brain or this repo's own state/. Each case writes its OWN journal/
# output to a plain file under its own subdir, read back directly (no
# generated-then-sourced env files — a heredoc is not valid inside a plain
# variable assignment, so this deliberately avoids that shape).
#
# AC1-AC10 map to the PRD's own numbering. AC3 and AC7 test extend-gate.sh's
# exact converted logic via a faithful, isolated reproduction of that same
# code block (real scripts/lib/probe.sh, real fake burst-lane.sh / real
# corrupt-JSON fixture) PLUS a structural grep on extend-gate.sh's actual
# source proving the real file still contains that block — running the
# full extend-gate.sh (25 producers, a real cargo project) end-to-end is
# outside what a fast offline selftest can afford; this is the documented,
# smallest-reasonable scope call for those two.
#
# Run: bash scripts/failloud-selftest.sh   (exit 0 = all pass)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
BL="$HERE/burst-lane.sh"
EG="$HERE/extend-gate.sh"
SG="$HERE/select-guard.sh"
LS="$HERE/lane-status.sh"
LINT="$HERE/lint-fail-loud.sh"
FAKE="$SKILL_DIR/tests/fixtures/burst-lane-fake"

T="$(mktemp -d "${TMPDIR:-/tmp}/failloud-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; PASS=$((PASS+1))
  else echo "FAIL $label" >&2; FAIL=$((FAIL+1)); fi
}

# ============================================================================
# AC1/AC2 — scripts/lib/probe.sh's own contract, directly.
# ============================================================================
D="$T/ac12"; mkdir -p "$D/state"
(
  exec 2>"$T/ac12.stderr"
  export STATE_DIR="$D/state" BUILD_JOURNAL_ROOT="$D/journal"
  # shellcheck source=lib/probe.sh
  source "$HERE/lib/probe.sh"

  probe_run demo -- bash -c 'echo boom >&2; exit 7' >"$D/demo.out" 2>/dev/null
  echo "$?" > "$D/rc1"
  cat "$(journal_root)"/*.md > "$D/journal1.txt" 2>/dev/null || : > "$D/journal1.txt"
  find "$D/state/logs/probe" -type f -name 'demo.*' > "$D/log1_path" 2>/dev/null || : > "$D/log1_path"

  out2="$(probe_run demo2 -- bash -c 'echo hello-stdout; echo noise >&2')"
  printf '%s' "$out2" > "$D/stdout2"
  echo "$?" > "$D/rc2"
  cat "$(journal_root)"/*.md > "$D/journal2.txt" 2>/dev/null || : > "$D/journal2.txt"
  find "$D/state/logs/probe" -type f -name 'demo2.*' > "$D/log2_path" 2>/dev/null || : > "$D/log2_path"
)
rc1="$(cat "$D/rc1")"
journal1="$(cat "$D/journal1.txt")"
log1="$(head -n1 "$D/log1_path")"
log1_content="$([ -n "$log1" ] && cat "$log1" 2>/dev/null)"
stdout2="$(cat "$D/stdout2")"
rc2="$(cat "$D/rc2")"
journal2="$(cat "$D/journal2.txt")"
log2="$(head -n1 "$D/log2_path")"

expect "AC1: probe_run returns the command's own rc (7)"          "[ '$rc1' = 7 ]"
expect "AC1: one probe failed journal line with name/rc/err/log"  "grep -q 'probe  failed  (name=demo rc=7 err=\"boom\" log=' <<<\"\$journal1\""
expect "AC1: the kept log file contains the stderr (boom)"        "[ '$log1_content' = boom ]"
expect "AC2: stdout passes through byte-identical"                "[ '$stdout2' = 'hello-stdout' ]"
expect "AC2: rc 0 on success"                                     "[ '$rc2' = 0 ]"
expect "AC2: no new journal line written on success"              "[ \"\$journal1\" = \"\$journal2\" ]"
expect "AC2: no log file remains on success"                      "[ -z '$log2' ]"

# ============================================================================
# AC6 — probe_bg: parent returns immediately, bg-exit lands within 5s.
# ============================================================================
D="$T/ac6"; mkdir -p "$D/state"
(
  export STATE_DIR="$D/state" BUILD_JOURNAL_ROOT="$D/journal"
  # shellcheck source=lib/probe.sh
  source "$HERE/lib/probe.sh"
  t0=$(date +%s%N)
  probe_bg parity -- bash -c 'sleep 2; exit 3'
  t1=$(date +%s%N)
  echo "$(( (t1 - t0) / 1000000 ))" > "$D/parent_ms"
  deadline=$(( $(date +%s) + 5 ))
  : > "$D/bgexit.txt"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    grep -h 'probe  bg-exit  (name=parity rc=3)' "$(journal_root)"/*.md > "$D/bgexit.txt" 2>/dev/null
    [ -s "$D/bgexit.txt" ] && break
    sleep 0.2
  done
)
parent_ms="$(cat "$D/parent_ms" 2>/dev/null || echo 9999)"
bgexit="$(cat "$D/bgexit.txt" 2>/dev/null)"
expect "AC6: probe_bg returns immediately (parent not blocked ~2s)" "[ '$parent_ms' -lt 500 ]"
expect "AC6: bg-exit (name=parity rc=3) journaled within 5s"        "[ -n '$bgexit' ]"

# ============================================================================
# AC4 — cmd_verify's rsync roundtrip: real stderr kept, journaled with
# err="rsync..." and an existing log= path. Fake BURST_LANE_RSYNC_BIN
# (rsync error text on stderr, rc 23) + fake BURST_LANE_SSH_BIN (rc 255,
# irrelevant to this AC — only the rsync leg is asserted). Sourced (not
# exec'd — burst-lane.sh's own `[ "${BASH_SOURCE[0]}" = "$0" ]` main guard
# means sourcing never dispatches a subcommand), then cmd_verify called
# directly inside a subshell so its own `exit` only ends that subshell.
# ============================================================================
D="$T/ac4"; mkdir -p "$D/state" "$D/fakebin"
cat > "$D/fakebin/rsync" <<'FAKE_RSYNC'
#!/usr/bin/env bash
echo "rsync: connection unexpectedly closed (0 bytes received so far) [sender]" >&2
exit 23
FAKE_RSYNC
cat > "$D/fakebin/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
exit 255
FAKE_SSH
chmod +x "$D/fakebin/rsync" "$D/fakebin/ssh"
(
  export BURST_LANE_STATE_DIR="$D/state" BURST_LANE_JOURNAL="$D/journal.log"
  export BURST_LANE_RSYNC_BIN="$D/fakebin/rsync" BURST_LANE_SSH_BIN="$D/fakebin/ssh"
  # shellcheck source=burst-lane.sh
  source "$BL"
  state_write server_id=srv1 ip=1.2.3.4 server_type=cx23 boot_ts=2026-09-15T00:00:00Z \
    boot_epoch=1 create_epoch=1 ttl_hours=4 hard_ttl_hours=8 runs_served=0 \
    sandbox_ok=true teardown_scheduled=false teardown_epoch= remote_user=build \
    gate_ready=true gate_tools_missing= box_cores=4 box_mem_gb=8 box_disk_gb=80 \
    phase=setup phase_epoch=1
  ( cmd_verify ) >/dev/null 2>&1
) >"$T/ac4.out" 2>&1
journal4="$(cat "$D/journal.log" 2>/dev/null)"
expect "AC4: probe failed line names verify-rsync with rsync err= and a log=" \
  "grep -qE 'probe  failed  \\(name=verify-rsync rc=[0-9]+ err=\"rsync[^\"]*\" log=.*\\.log\\)' <<<\"\$journal4\""
ac4_log_path="$(grep -oE 'log=[^)]*\.log' <<<"$journal4" | head -n1 | cut -d= -f2)"
expect "AC4: the named log file exists and contains the rsync error" \
  "[ -n '$ac4_log_path' ] && [ -f '$ac4_log_path' ] && grep -q 'rsync: connection unexpectedly closed' '$ac4_log_path'"

# ============================================================================
# AC5 — prove exit trap: cmd_down failing journals down-failed (with the
# hcloud error, via probe_run's own probe-failed line) and the session
# file is NOT cleared. cmd_down is stubbed here as a test double that
# mirrors its REAL, unchanged contract (state_clear only ever runs on
# cmd_down's own success path) — this PRD does not touch that contract,
# only the caller's wrapping of the call.
# ============================================================================
D="$T/ac5"; mkdir -p "$D/state"
(
  # tests/fixtures/burst-lane-fake on PATH so hcloud/ssh/rsync all resolve
  # to fakes rather than this machine's real binaries — required under
  # BUILD_TEST=1 (e.g. when this whole suite runs via run-selftests.sh):
  # scripts/isolation-guard.sh's isolation_guard_bin refuses to even
  # SOURCE burst-lane.sh if HCLOUD/SSH_BIN/RSYNC_BIN resolve live under
  # BURST_LANE_TEST/BUILD_TEST (a real 2026-09-1x incident class). cmd_down
  # is stubbed below regardless, so none of the fakes are actually invoked.
  export PATH="$FAKE:$PATH"
  export BURST_LANE_STATE_DIR="$D/state" BURST_LANE_JOURNAL="$D/journal.log"
  # shellcheck source=burst-lane.sh
  source "$BL"
  state_write server_id=srv1 ip=1.2.3.4 server_type=cx23 boot_ts=2026-09-15T00:00:00Z \
    boot_epoch=1 create_epoch=1 ttl_hours=4 hard_ttl_hours=8 runs_served=0 \
    sandbox_ok=true teardown_scheduled=false teardown_epoch= remote_user=build \
    gate_ready=true gate_tools_missing= box_cores=4 box_mem_gb=8 box_disk_gb=80 \
    phase=setup phase_epoch=1
  cmd_down() { echo "hcloud: server delete failed: 503 rate limited" >&2; return 7; }
  PROVE_INFLIGHT_FILE="$D/state/prove.inflight"
  PROVE_FINISHED=false
  PROVE_STEP="assert"
  PROVE_ID="test-id"; PROVE_WORKTREE="$D/wt"; PROVE_SHA="deadbeef"
  PROVE_START_EPOCH=$(date +%s)
  PROVE_ERR_LINE=""; PROVE_CLEANUP_WORKTREE=""
  ( prove_exit_trap 1 ) >/dev/null 2>&1
) >"$T/ac5.out" 2>&1
journal5="$(cat "$D/journal.log" 2>/dev/null)"
state5_present="$([ -f "$D/state/session.json" ] && echo yes || echo no)"
expect "AC5: down-failed journaled with the hcloud error" \
  "grep -q 'prove  down-failed  (cause=teardown-failed' <<<\"\$journal5\" && grep -q 'probe  failed  (name=down .*err=\"hcloud: server delete failed' <<<\"\$journal5\""
expect "AC5: the session file is NOT cleared"          "[ '$state5_present' = yes ]"

# ============================================================================
# AC10 — one tool fails during provision_gate_tools: its stderr log
# survives under logs/failed/, only the succeeded tool's own transient
# install log was removed. This site's real behavior predates this PRD
# (PRD-build-burst-provision-forensics) — no code change was needed here;
# this proves the existing contract still holds under this PRD's own
# suite. Reuses tests/fixtures/burst-lane-fake (the repo's own proven fake
# ssh/hcloud/rsync toolchain — same fixture burst-lane-provision-forensics-
# selftest.sh uses) via PATH, no bespoke fake of its own.
# ============================================================================
D="$T/ac10"; mkdir -p "$D/state"
(
  export PATH="$FAKE:$PATH"
  export BURST_LANE_STATE_DIR="$D/state" BURST_LANE_JOURNAL="$D/journal.log"
  export FAKE_SSH_GATE_TOOLS_MISSING="gh jq"
  export FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_TOOL="gh"
  export FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_STDERR="gh: 404 not found"
  export FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_RC=17
  export FAKE_HCLOUD_STATE="$D/hcloud.state"
  export FAKE_HCLOUD_CALLLOG="$D/hcloud.calls"; : > "$FAKE_HCLOUD_CALLLOG"
  export FAKE_GATE_TOOLS_STATE="$D/gate-tools-installed"
  # shellcheck source=burst-lane.sh
  source "$BL"
  state_write server_id=srv1 ip=1.2.3.4
  ( provision_gate_tools 1.2.3.4 ) >/dev/null 2>&1
) >"$T/ac10.out" 2>&1
ac10_failed_log="$(find "$D/state/logs/failed" -type f -name '*-gh.log' 2>/dev/null | head -n1)"
ac10_install_remaining="$(find "$D/state/logs" -maxdepth 1 -name 'gate-tools-install*' 2>/dev/null | wc -l)"
expect "AC10: the failed tool's stderr log survives under logs/failed/" \
  "[ -n '$ac10_failed_log' ] && [ -f '$ac10_failed_log' ] && grep -q '404 not found' '$ac10_failed_log'"
expect "AC10: no transient install logs remain (succeeded tool's was removed)" \
  "[ '$ac10_install_remaining' -eq 0 ]"

# ============================================================================
# AC3 — extend-gate.sh's route computation: a failing `burst-lane.sh
# status --json` journals `probe failed (name=burst-status ...)` AND
# `route unknown (cause=probe-failed)`, never a silent local default.
# Reproduced here with the real scripts/lib/probe.sh against a fake
# burst-lane.sh (exit 1) — the exact block now in extend-gate.sh (asserted
# structurally below) — see this file's header for why the full
# extend-gate.sh isn't run end-to-end by this offline suite.
# ============================================================================
D="$T/ac3"; mkdir -p "$D/state"
cat > "$D/fake-burst-lane.sh" <<'FAKE_BL'
#!/usr/bin/env bash
exit 1
FAKE_BL
chmod +x "$D/fake-burst-lane.sh"
(
  export STATE_DIR="$D/state" BUILD_JOURNAL_ROOT="$D/journal"
  # shellcheck source=lib/probe.sh
  source "$HERE/lib/probe.sh"
  journal="$(journal_root)/gate.md"
  crate_name="demo-crate"
  route_intended="local"
  if route_status_json="$(probe_run burst-status -- "$D/fake-burst-lane.sh" status --json)"; then
    route_intended="burst"
  else
    route_intended="unknown"
    printf '%s  gate  %s  route  unknown  (cause=probe-failed)\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$crate_name" >>"$journal"
  fi
  printf '%s' "$route_intended" > "$D/route.txt"
) >"$T/ac3.out" 2>&1
route3="$(cat "$D/route.txt" 2>/dev/null)"
journal3="$(cat "$D/journal/gate.md" 2>/dev/null)"
expect "AC3: a failed status probe never silently defaults to local"  "[ '$route3' = unknown ]"
expect "AC3: probe failed (name=burst-status) is journaled"           "grep -q 'probe  failed  (name=burst-status' <<<\"\$journal3\""
expect "AC3: route unknown (cause=probe-failed) is journaled"         "grep -q 'route  unknown  (cause=probe-failed)' <<<\"\$journal3\""
expect "AC3 (structural): extend-gate.sh's real source still wraps the status probe with probe_run" \
  "grep -q 'probe_run burst-status -- \"\$BURST_LANE_SH\" status --json' '$EG'"
expect "AC3 (structural): extend-gate.sh's real source still journals route unknown on probe failure" \
  "grep -q 'gate  %s  route  unknown  (cause=probe-failed)' '$EG'"

# ============================================================================
# AC7 — a corrupted verdict cache is journaled (`verdict-cache corrupt`)
# and removed, so the gate runs fresh instead of an empty-verdict path.
# Reproduced here with the exact jq -e detection extend-gate.sh now uses,
# against a real corrupt-JSON fixture file, plus a structural check that
# extend-gate.sh's real source still contains this block.
# ============================================================================
D="$T/ac7"; mkdir -p "$D"
cache_file="$D/last-verdict.json"
printf '{ this is not valid json' > "$cache_file"
journal7f="$D/gate.md"
if [ -f "$cache_file" ] && ! jq -e . "$cache_file" >/dev/null 2>&1; then
  printf '%s  gate  %s  verdict-cache  corrupt  (path=%s)\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "demo-crate" "$cache_file" >>"$journal7f"
  rm -f "$cache_file" 2>/dev/null || true
fi
cache7_removed="$([ ! -f "$cache_file" ] && echo yes || echo no)"
journal7="$(cat "$journal7f" 2>/dev/null)"
expect "AC7: verdict-cache corrupt journaled"       "grep -q 'verdict-cache  corrupt  (path=' <<<\"\$journal7\""
expect "AC7: the corrupt cache file is removed"      "[ '$cache7_removed' = yes ]"
expect "AC7 (structural): extend-gate.sh's real source still detects+removes a corrupt cache" \
  "grep -q 'jq -e . \"\$cache_file\" >/dev/null 2>&1; then' '$EG' && grep -q 'verdict-cache  corrupt' '$EG'"

# ============================================================================
# select-guard.sh half of the same probe shape (Grounding's own
# select-guard.sh:220-223): a failed status probe journals an explicit
# cap-local/cause=probe-failed line instead of leaving gate_ready empty
# with no line at all. Structural — select-guard.sh's cap computation only
# runs deep inside `main`'s PRD-file/build_into resolution, not worth a
# second full fixture beyond the burst-lane-fake-based ones above.
# ============================================================================
expect "select-guard.sh: probe_run wraps the burst status probe" \
  "grep -q 'probe_run burst-status -- \"\$burst_bin\" status --json' '$SG'"
expect "select-guard.sh: a failed probe journals cap-local (cause=probe-failed)" \
  "grep -q 'select_guard_journal_line \"\$slug\" cap-local \"cause=probe-failed\"' '$SG'"

# ============================================================================
# AC8 — lint-fail-loud.sh flags the allowlisted swallow shape and names
# file:line + the matched entry; a non-allowlisted command (mkdir -p) in
# the same shape is never flagged.
# ============================================================================
D="$T/ac8"; mkdir -p "$D"
cat > "$D/pos.sh" <<'EOF'
#!/usr/bin/env bash
( cmd_down >/dev/null 2>&1 ) || true
EOF
cat > "$D/neg.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$dir" >/dev/null 2>&1 || true
EOF
ac8_out="$(LINT_FAIL_LOUD_WARN=0 bash "$LINT" "$D" 2>&1)"; ac8_rc=$?
expect "AC8: the allowlisted swallow is reported with file:line and the entry" \
  "grep -qE 'pos\\.sh:2: matched allowlist entry: cmd_down' <<<\"\$ac8_out\""
expect "AC8: the non-allowlisted mkdir -p shape is never reported"    "! grep -q 'neg.sh' <<<\"\$ac8_out\""
expect "AC8: hard mode (LINT_FAIL_LOUD_WARN=0) exits non-zero on a real offense" "[ '$ac8_rc' -ne 0 ]"

# ============================================================================
# AC9 — lane-status.sh's tick-summary prints PROBES: failed_24h=<n>
# top=<name>:<n> sourced from real `probe failed` journal lines.
# ============================================================================
D="$T/ac9"; mkdir -p "$D/prds/build-queue" "$D/state"
J="$D/journal.md"
cat > "$J" <<EOJ
$(date -u +%Y-%m-%dT%H:%M:%SZ)  extend-gate.sh  probe  failed  (name=burst-status rc=1 err="a" log=/tmp/a.log)
$(date -u +%Y-%m-%dT%H:%M:%SZ)  extend-gate.sh  probe  failed  (name=burst-status rc=1 err="b" log=/tmp/b.log)
$(date -u +%Y-%m-%dT%H:%M:%SZ)  select-guard.sh  probe  failed  (name=burst-status rc=1 err="c" log=/tmp/c.log)
2020-01-01T00:00:00Z  extend-gate.sh  probe  failed  (name=old rc=1 err="ignored" log=/tmp/z.log)
EOJ
(
  export PRD_DIR="$D/prds" BUILD_STATE_DIR="$D/state"
  PROBE_STATUS_SOURCES="$J" bash "$LS" tick-summary testlane 1 0 "$J"
) >"$T/ac9.out" 2>&1
journal9="$(cat "$J" 2>/dev/null)"
expect "AC9: PROBES: failed_24h=3 top=burst-status:3 line appended" \
  "grep -q 'PROBES: failed_24h=3 top=burst-status:3' <<<\"\$journal9\""

echo "----"
echo "failloud-selftest: $PASS/$((PASS+FAIL)) ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
