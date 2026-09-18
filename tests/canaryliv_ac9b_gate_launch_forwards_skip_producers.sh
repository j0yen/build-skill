#!/usr/bin/env bash
# tests/canaryliv_ac9b_gate_launch_forwards_skip_producers.sh —
# PRD-build-burst-canary-live-parity R6 regression: canaryliv_ac9 already
# proves extend-gate.sh honors EXTEND_GATE_SKIP_PRODUCERS when called
# directly, but that never exercises gate-launch.sh's systemd-run wrapping
# — and systemd-run does NOT inherit the invoking shell's environment, only
# what --setenv names explicitly (PATH and EXTEND_GATE_HOST_CONTRACT_CHECK,
# before this fix). A real canary run on RedBaron (2026-09-18 ~19:54Z,
# canary-branch-1789760444) proved this out live: EXTEND_GATE_SKIP_PRODUCERS
# was set on gate-launch.sh's own invocation but never reached the unit, so
# extend-gate.sh ran ci-checks for real and polled CI_CHECKS_BRANCH_WAIT
# (900s) for a throwaway canary branch that was never going to get CI.
#
# This test asserts gate-launch.sh's systemd-run call carries
# --setenv=EXTEND_GATE_SKIP_PRODUCERS=<value> whenever the variable is set
# on gate-launch.sh's own invocation with a canary-* slug, and omits it
# when unset — using the same fake systemd-run/systemctl pair
# mainpin_gate_launch_pinned_wiring.sh already uses (that fake's own
# comment header documents it inherits the calling process's environment
# regardless of --setenv, i.e. it does NOT itself catch this class of bug
# — only inspecting the recorded argv does).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
FIXDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/fixtures/gatelaunch-fake" && pwd -P)"
GATE_LAUNCH="$HERE/gate-launch.sh"
[ -x "$GATE_LAUNCH" ] || { echo "selftest: $GATE_LAUNCH not executable" >&2; exit 2; }
for f in "$FIXDIR/systemd-run" "$FIXDIR/systemctl" "$FIXDIR/extend-gate.sh"; do
  [ -x "$f" ] || { echo "selftest: missing/non-executable: $f" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/canaryliv-ac9b-selftest.XXXXXX")"
trap '[ -n "${CANARYLIV_AC9B_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

export FAKE_SYSTEMD_STATE_DIR="$T/systemd-state"
mkdir -p "$FAKE_SYSTEMD_STATE_DIR"
export BUILD_STATE_DIR="$T/state"
mkdir -p "$BUILD_STATE_DIR"
export GATE_LAUNCH_EXTEND_GATE="$FIXDIR/extend-gate.sh"
export GATE_LAUNCH_SYSTEMD_RUN="$FIXDIR/systemd-run"
export GATE_LAUNCH_SYSTEMCTL="$FIXDIR/systemctl"
export GATE_LAUNCH_BURST_ENV="$T/no-such-wm-burst-env"
export GATE_LAUNCH_CARGO_ROUTE_LIB="$T/no-such-cargo-route.sh"
export GATE_LAUNCH_JOURNAL="$T/gate-launch-journal.md"
export FAKE_EXTEND_GATE_LOG="$T/fake-extend-gate-args.log"

echo "=== AC9b-1: EXTEND_GATE_SKIP_PRODUCERS set on a canary-* slug is forwarded via --setenv ==="
export FAKE_SYSTEMD_LOG="$T/systemd-run-argv-1.log"
: > "$FAKE_SYSTEMD_LOG"
EXTEND_GATE_SKIP_PRODUCERS="ci-checks,reviewer-agent,session-trace" \
  "$GATE_LAUNCH" "$REPO" --head "$HEAD_SHA" --scope branch --slug "canary-branch-ac9b" >"$T/launch1.out" 2>&1
rc=$?
cat "$T/launch1.out"
expect "AC9b-1: launch call itself exits 0" "[ $rc -eq 0 ]"
expect "AC9b-1: systemd-run argv carries --setenv=EXTEND_GATE_SKIP_PRODUCERS=..." \
  "grep -qF -- '--setenv=EXTEND_GATE_SKIP_PRODUCERS=ci-checks,reviewer-agent,session-trace' '$FAKE_SYSTEMD_LOG'"

echo "=== AC9b-2: unset EXTEND_GATE_SKIP_PRODUCERS forwards nothing ==="
export FAKE_SYSTEMD_LOG="$T/systemd-run-argv-2.log"
: > "$FAKE_SYSTEMD_LOG"
unset EXTEND_GATE_SKIP_PRODUCERS
"$GATE_LAUNCH" "$REPO" --head "$HEAD_SHA" --scope main --slug "gate-launch-ac9b-plain" >"$T/launch2.out" 2>&1
rc2=$?
cat "$T/launch2.out"
expect "AC9b-2: launch call itself exits 0" "[ $rc2 -eq 0 ]"
expect "AC9b-2: systemd-run argv carries no EXTEND_GATE_SKIP_PRODUCERS setenv" \
  "! grep -qF -- '--setenv=EXTEND_GATE_SKIP_PRODUCERS=' '$FAKE_SYSTEMD_LOG'"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canaryliv_ac9b_gate_launch_forwards_skip_producers: ALL PASS"
  exit 0
else
  echo "canaryliv_ac9b_gate_launch_forwards_skip_producers: assertion(s) FAILED"
  exit 1
fi
