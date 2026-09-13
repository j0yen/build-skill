#!/usr/bin/env bash
# burst-lane-probe-visibility-selftest.sh — offline proof for
# PRD-build-burst-probe-visibility: the gate-tools probe is journaled
# (phase=pre/final), the install loop is driven from GATE_TOOLS_LIST rather
# than the probe's own output (probe-absent fail-safe), a present tool gets
# an explicit install-skipped record, the summary distinguishes
# not-attempted (na) from a real rc, pre/final disagreement alarms, an
# unparseable probe is distinguishable from a measured empty result, CR-
# padded values are normalized, a hanging --version is bounded, and
# truncated probe output never reads a tool as present. Uses the same fake
# hcloud/ssh/rsync fixtures as burst-lane-selftest.sh — no network calls, no
# real Hetzner spend. Run standalone:
#   BUILD_BURST_ENABLED=1 bash scripts/burst-lane-probe-visibility-selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BL="$HERE/burst-lane.sh"
FAKE="$HERE/../tests/fixtures/burst-lane-fake"
[ -x "$BL" ] || { echo "selftest: $BL not executable" >&2; exit 2; }

export BURST_LANE_TEST=1
[ "${BURST_LANE_TEST:-}" = "1" ] || {
  echo "burst-lane-probe-visibility-selftest: BURST_LANE_TEST not set — refusing to start" >&2
  exit 2
}

fail=0
ALL_TMPDIRS=()
cleanup() { for d in "${ALL_TMPDIRS[@]:-}"; do rm -rf "$d"; done; }
trap cleanup EXIT

expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# shellcheck source=lib/burst-configured.sh
source "$HERE/lib/burst-configured.sh"
if ! burst_configured; then
  echo "SKIP: burst lane dormant (RedBaron-local policy) — see burst-configured.sh"
  exit 0
fi

fresh_env() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/bl-probevis-selftest.XXXXXX")"
  ALL_TMPDIRS+=("$T")
  export PATH="$FAKE:$PATH"
  export BURST_LANE_STATE_DIR="$T/state"; mkdir -p "$BURST_LANE_STATE_DIR"
  export BURST_LANE_JOURNAL="$T/journal.log"
  export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
  export BURST_LANE_ENV_FILE="$T/env"; echo "SNAPSHOT_ID=427125061" > "$BURST_LANE_ENV_FILE"
  export BURST_LANE_REMOTE_ROOT="$T/remote"
  export BURST_LANE_REMOTE_HOME="$T/remote-home"
  export BURST_LANE_ROOT_RUSTUP_HOME="$HOME/.rustup"
  export BURST_LANE_ROOT_CARGO_HOME="$HOME/.cargo"
  export BURST_LANE_PRD_DIR="$T/prds"; mkdir -p "$BURST_LANE_PRD_DIR/build-queue"
  export FAKE_HCLOUD_STATE="$T/hcloud.state"
  export FAKE_HCLOUD_CALLLOG="$T/hcloud.calls"; : > "$FAKE_HCLOUD_CALLLOG"
  export FAKE_RSYNC_STATS_DIR="$T/rsync-stats"; mkdir -p "$FAKE_RSYNC_STATS_DIR"
  export BURST_LANE_COST_LEDGER="$T/cost.jsonl"
  export BUILD_STATE_DIR="$T/state"
  export PROBE_JOURNAL_DIR="$T/probe-journal"
  export BURST_LANE_ATTR_LEDGER="$T/attribution.jsonl"
  export BURST_LANE_REPOS_DIR="$T/repos"; mkdir -p "$BURST_LANE_REPOS_DIR"
  export BURST_LANE_TICK_JOURNAL_DIR="$T/tick-journal"; mkdir -p "$BURST_LANE_TICK_JOURNAL_DIR"
  export FAKE_GATE_TOOLS_STATE="$T/gate-tools-installed"
  export BURST_LANE_GATE_TOOLS_REMOTE_BIN_DIR="$T/remote-cargo-bin"
  export BURST_LANE_GATE_CRED_REMOTE_PATH="$T/remote-cred/.credentials.json"
  # This suite's own local autobuilder binary, versioned to match the fake
  # ssh probe's default remote reply — a real ~/.cargo/bin/autobuilder on
  # the host running this suite must never leak in and trip version-drift.
  mkdir -p "$T/autobuilder-bin"
  printf '#!/bin/sh\necho "autobuilder 9.9.9"\n' > "$T/autobuilder-bin/autobuilder"
  chmod +x "$T/autobuilder-bin/autobuilder"
  export BURST_LANE_AUTOBUILDER_BIN="$T/autobuilder-bin/autobuilder"
  export BURST_GATE_REMOTE=1
  export BURST_LANE_FORCE_NEXTEST_LOCAL=0
  export BURST_VOLUME_NAME=""
  export FAKE_HCLOUD_VOLUME_STATE="$T/hcloud-volume.state"
  export BURST_ORPHAN_AGE_S=600
  unset FAKE_SSH_GATE_TOOLS_MISSING FAKE_SSH_GATE_TOOLS_MISSING_2ND FAKE_SSH_GATE_TOOLS_INSTALL_FAIL \
        FAKE_SSH_AUTOBUILDER_VERSION FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_TOOL FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_RC \
        FAKE_SSH_GATE_TOOLS_INSTALL_FAIL_STDERR FAKE_SSH_GATE_TOOLS_APT_UPDATE_FAIL BURST_LANE_NOW \
        FAKE_SSH_GATE_TOOLS_PROBE_FAIL FAKE_SSH_GATE_TOOLS_PROBE_FAIL_RC FAKE_SSH_GATE_TOOLS_PROBE_OMIT \
        FAKE_SSH_GATE_TOOLS_PROBE_TRUNCATE FAKE_SSH_GATE_TOOLS_PROBE_CRLF FAKE_SSH_GATE_TOOLS_PROBE_NO_SENTINEL \
        FAKE_SSH_GATE_TOOLS_PROBE_CALLCOUNT_FILE BURST_LANE_SSH_BIN
}

# ============================================================================
# AC1: pre-probe reports jq=MISSING and omits every other tool. Every other
# tool journals probe-absent and gets attempted (fail-safe); no listed tool
# ends the run without a journal record.
# ============================================================================
fresh_env
"$BL" up >/tmp/.probevis-up1.out 2>&1 || { echo "FAIL probevis AC1 setup: up failed" >&2; cat /tmp/.probevis-up1.out >&2; fail=1; }
export FAKE_SSH_GATE_TOOLS_MISSING="jq"
export FAKE_SSH_GATE_TOOLS_PROBE_OMIT="autobuilder gh mold cargo-deny cargo-nextest uv claude"
"$BL" provision >/tmp/.probevis-ac1.out 2>&1
for t in autobuilder gh mold cargo-deny cargo-nextest uv claude; do
  expect "AC1: probe-absent journaled for omitted tool=$t" \
    "grep -q \"gate-tools  probe-absent  (tool=$t)\" \"$BURST_LANE_JOURNAL\""
  expect "AC1: omitted tool=$t is attempted (install-start)" \
    "grep -q \"gate-tools  install-start  (tool=$t)\" \"$BURST_LANE_JOURNAL\""
done
expect "AC1: jq (genuinely reported MISSING) is also attempted" \
  "grep -q 'gate-tools  install-start  (tool=jq)' \"$BURST_LANE_JOURNAL\""
unset FAKE_SSH_GATE_TOOLS_MISSING FAKE_SSH_GATE_TOOLS_PROBE_OMIT

# ============================================================================
# AC2: pre-probe reports gh present (default fixture version) — gh journals
# install-skipped and is never installed.
# ============================================================================
fresh_env
"$BL" up >/tmp/.probevis-up2.out 2>&1 || { echo "FAIL probevis AC2 setup: up failed" >&2; cat /tmp/.probevis-up2.out >&2; fail=1; }
"$BL" provision >/tmp/.probevis-ac2.out 2>&1
expect "AC2: gh journals install-skipped with reason=present and its version" \
  "grep -q 'gate-tools  install-skipped  (tool=gh reason=present version=\"gh-fakeversion\")' \"$BURST_LANE_JOURNAL\""
expect "AC2: gh never gets install-start" \
  "! grep -q 'gate-tools  install-start  (tool=gh)' \"$BURST_LANE_JOURNAL\""

# ============================================================================
# AC3: every provision run journals both a phase=pre and a phase=final probe
# record.
# ============================================================================
expect "AC3: journal has a gate-tools probe record for phase=pre" \
  "grep -q 'gate-tools  probe  (phase=pre' \"$BURST_LANE_JOURNAL\""
expect "AC3: journal has a gate-tools probe record for phase=final" \
  "grep -q 'gate-tools  probe  (phase=final' \"$BURST_LANE_JOURNAL\""

# ============================================================================
# AC4: 2 tools missing (genuinely attempted, rc=0), 6 tools present
# (skipped) — the summary renders the 6 as na, never as 0.
# ============================================================================
fresh_env
"$BL" up >/tmp/.probevis-up4.out 2>&1 || { echo "FAIL probevis AC4 setup: up failed" >&2; cat /tmp/.probevis-up4.out >&2; fail=1; }
export FAKE_SSH_GATE_TOOLS_MISSING="jq gh"
ac4_out="$("$BL" provision 2>&1)"
expect "AC4: summary shows na for every non-attempted tool and 0 for the 2 attempted" \
  "grep -qE 'gate-tools  summary  \\(per_tool_rc=\"autobuilder=na jq=0 gh=0 mold=na cargo-deny=na cargo-nextest=na uv=na claude=na\"\\)' \"$BURST_LANE_JOURNAL\""
expect "AC4: provision's own stdout also carries na (never 0) for a skipped tool" \
  "grep -q 'mold=na' <<<\"\$ac4_out\""
unset FAKE_SSH_GATE_TOOLS_MISSING

# ============================================================================
# AC5: pre-probe reports mold present, final probe (same provision run)
# reports mold missing — probe-disagreement journaled.
# ============================================================================
fresh_env
"$BL" up >/tmp/.probevis-up5.out 2>&1 || { echo "FAIL probevis AC5 setup: up failed" >&2; cat /tmp/.probevis-up5.out >&2; fail=1; }
export FAKE_SSH_GATE_TOOLS_PROBE_CALLCOUNT_FILE="$T/probe-callcount"
export FAKE_SSH_GATE_TOOLS_MISSING_2ND="mold"
"$BL" provision >/tmp/.probevis-ac5.out 2>&1
expect "AC5: probe-disagreement journaled for mold (present pre, missing final)" \
  "grep -qE 'gate-tools  probe-disagreement  \\(tool=mold pre=\"mold-fakeversion\" final=\"MISSING\"\\)' \"$BURST_LANE_JOURNAL\""
unset FAKE_SSH_GATE_TOOLS_PROBE_CALLCOUNT_FILE FAKE_SSH_GATE_TOOLS_MISSING_2ND

# ============================================================================
# AC6: the probe fails outright (nonzero exit, no output) — probe-
# unparseable journaled, and the resulting missing-list fallback is
# distinguishable in the journal from a measured result.
# ============================================================================
fresh_env
"$BL" up >/tmp/.probevis-up6.out 2>&1 || { echo "FAIL probevis AC6 setup: up failed" >&2; cat /tmp/.probevis-up6.out >&2; fail=1; }
export FAKE_SSH_GATE_TOOLS_PROBE_FAIL=1
ac6_out="$("$BL" provision 2>&1)"
expect "AC6: probe-unparseable journaled for phase=pre" \
  "grep -qE 'gate-tools  probe-unparseable  \\(phase=pre rc=[0-9]+\\)' \"$BURST_LANE_JOURNAL\""
expect "AC6: probe-unparseable journaled for phase=final" \
  "grep -qE 'gate-tools  probe-unparseable  \\(phase=final rc=[0-9]+\\)' \"$BURST_LANE_JOURNAL\""
expect "AC6: the fallback missing-list covers every tool (never a partial/measured-looking result)" \
  "grep -q 'missing=autobuilder jq gh mold cargo-deny cargo-nextest uv claude' <<<\"\$ac6_out\""
unset FAKE_SSH_GATE_TOOLS_PROBE_FAIL

# ============================================================================
# AC7: probe values carry trailing CRLF — normalized, classification is
# unaffected (a MISSING tool with \r is still installed; a present tool
# with \r is still skipped, and the journal never shows a literal \r).
# ============================================================================
fresh_env
"$BL" up >/tmp/.probevis-up7.out 2>&1 || { echo "FAIL probevis AC7 setup: up failed" >&2; cat /tmp/.probevis-up7.out >&2; fail=1; }
export FAKE_SSH_GATE_TOOLS_PROBE_CRLF=1
export FAKE_SSH_GATE_TOOLS_MISSING="jq"
"$BL" provision >/tmp/.probevis-ac7.out 2>&1
expect "AC7: a CRLF-padded MISSING value still gets attempted" \
  "grep -q 'gate-tools  install-start  (tool=jq)' \"$BURST_LANE_JOURNAL\""
expect "AC7: a CRLF-padded present value still gets skipped, normalized" \
  "grep -q 'gate-tools  install-skipped  (tool=gh reason=present version=\"gh-fakeversion\")' \"$BURST_LANE_JOURNAL\""
expect "AC7: no raw carriage return ever lands in the journal" \
  "! grep -qP '\\r' \"$BURST_LANE_JOURNAL\""
unset FAKE_SSH_GATE_TOOLS_PROBE_CRLF FAKE_SSH_GATE_TOOLS_MISSING

# ============================================================================
# AC8: bounded probe execution. Structural — the fake ssh's own
# gate-tools-probe case is fully canned (never runs the real remote
# for-loop text), so a real hang can't be reproduced through it; this
# proves the actual command gate_tools_probe() builds wraps each
# `--version` call in `timeout $GATE_TOOLS_PROBE_TIMEOUT_S` (so no single
# hanging binary can stall the sweep) and always emits the sentinel after
# the loop (so the sweep still reports all 8 regardless of any one tool),
# by capturing the literal command text sent over ssh — the same
# "gate_tools_install_cmd is a pure function" structural-proof model the
# forensics selftest's own goal5 check already uses for the apt-lock-
# timeout requirement.
# ============================================================================
fresh_env
CAP_SSH_DIR="$T/capture-ssh-bin"; mkdir -p "$CAP_SSH_DIR"
CAP_OUT="$T/gt-probe-cmd.txt"
cat > "$CAP_SSH_DIR/ssh" <<EOF
#!/usr/bin/env bash
args=("\$@")
printf '%s' "\${args[-1]}" > "$CAP_OUT"
exit 0
EOF
chmod +x "$CAP_SSH_DIR/ssh"
export BURST_LANE_SSH_BIN="$CAP_SSH_DIR/ssh"
ac8_check_rc=0
(
  # shellcheck source=burst-lane.sh
  source "$BL"
  gate_tools_probe "1.2.3.4" >/dev/null
) || ac8_check_rc=1
expect "AC8 setup: gate_tools_probe ran without error" "[ $ac8_check_rc -eq 0 ]"
expect "AC8: each --version call is bounded by a timeout wrapper" \
  "grep -qE 'timeout [0-9]+ \"\\\$t\" --version' \"$CAP_OUT\""
expect "AC8: the sweep always emits the completion sentinel after the loop" \
  "grep -q '__GATE_PROBE_DONE__' \"$CAP_OUT\""
unset BURST_LANE_SSH_BIN

# ============================================================================
# AC9: probe output truncated before the sentinel (only 3 of 8 tool lines
# ever printed) — probe-truncated is journaled, and every tool NOT seen is
# treated as MISSING (attempted), never as present.
# ============================================================================
fresh_env
"$BL" up >/tmp/.probevis-up9.out 2>&1 || { echo "FAIL probevis AC9 setup: up failed" >&2; cat /tmp/.probevis-up9.out >&2; fail=1; }
# up's own initial provision already journaled a full (untruncated) round
# where every tool reported present — reset the journal so the "never
# present" assertions below are scoped to THIS (truncated) provision call,
# not a false positive from that earlier, unrelated run.
: > "$BURST_LANE_JOURNAL"
export FAKE_SSH_GATE_TOOLS_PROBE_TRUNCATE=3
"$BL" provision >/tmp/.probevis-ac9.out 2>&1
expect "AC9: probe-truncated journaled for phase=pre naming 3 of 8 seen" \
  "grep -q 'gate-tools  probe-truncated  (phase=pre tools_seen=3 expected=8)' \"$BURST_LANE_JOURNAL\""
for t in mold cargo-deny cargo-nextest uv claude; do
  expect "AC9: unseen tool=$t is treated as MISSING (attempted), never present" \
    "grep -q \"gate-tools  install-start  (tool=$t)\" \"$BURST_LANE_JOURNAL\" && ! grep -q \"gate-tools  install-skipped  (tool=$t \" \"$BURST_LANE_JOURNAL\""
done
unset FAKE_SSH_GATE_TOOLS_PROBE_TRUNCATE

echo "=== $([ $fail -eq 0 ] && echo PASS || echo FAIL) ==="
exit $fail
