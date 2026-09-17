#!/usr/bin/env bash
# tests/mainpin_gate_launch_pinned_wiring.sh —
# PRD-build-main-verdict-pinned-to-landing R1 (consumer wiring): the
# coordinator's "gate" step / landing-resume resumption for a
# push_via_branch=true repo must launch the pinned verify (which resolves
# the slug's OWN merge sha M itself) under gate-launch.sh's systemd-run
# survive-tick-teardown wrapping — never a bare `extend-gate.sh --head
# <computed HEAD>` call, which is exactly what produced the 2026-09-17
# 05:15:46Z regression (a re-verify at the checkout's then-current HEAD,
# one PRD later than the slug's own landing).
#
# Reuses gate-launch-selftest.sh's own fake systemd-run/systemctl pair
# (tests/fixtures/gatelaunch-fake) — same technique, so this test only
# needs its own fake main-verdict-pin-gate.sh (mirroring the convention
# mainpin_pin_gate_wiring.sh already uses for a fake extend-gate.sh).
#
#   AC-launch-1: `gate-launch.sh <repo> --head <anything> --scope main
#     --slug <S> --pinned-landing --wait` execs
#     main-verdict-pin-gate.sh <repo> <S> — NEVER extend-gate.sh directly
#     — inside the unit.
#   AC-launch-2: `--pinned-landing` with `--scope branch` is a usage
#     error (R3: a pinned verdict is main-scope only) — refused before
#     any unit is launched.
#   AC-launch-3: without `--pinned-landing` (the ordinary, non-pinned
#     path every other caller already uses), the unit still execs
#     extend-gate.sh directly, byte-identical to before this step —
#     `--pinned-landing` changes nothing about the default path.
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

T="$(mktemp -d "${TMPDIR:-/tmp}/mainpin-gate-launch-pinned.XXXXXX")"
trap '[ -n "${MAINPIN_GATE_LAUNCH_PINNED_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

# Fake main-verdict-pin-gate.sh: records exactly how it was invoked
# (mirroring mainpin_pin_gate_wiring.sh's fake extend-gate.sh convention)
# — no worktree, no landing record needed, this test is about
# gate-launch.sh's own exec-target routing, not main-verdict-pin-gate.sh's
# own internals (already covered by mainpin_pin_gate_wiring.sh /
# mainpin_verdict_cache_r4.sh).
FAKE_PIN_GATE="$T/fake-main-verdict-pin-gate.sh"
PIN_GATE_LOG="$T/pin-gate-args.log"
cat > "$FAKE_PIN_GATE" <<EOF
#!/usr/bin/env bash
printf 'argv: %s\n' "\$*" >> "$PIN_GATE_LOG"
exit 0
EOF
chmod +x "$FAKE_PIN_GATE"

export FAKE_SYSTEMD_STATE_DIR="$T/systemd-state"
mkdir -p "$FAKE_SYSTEMD_STATE_DIR"
# BUILD_STATE_DIR: never the running skill's real state/gate-inflight
# (PRD-build-test-isolation-by-default) — gate-launch-selftest.sh's own
# convention, missed on a first draft of this test (it defaulted to the
# real production state dir and raced real gate-inflight markers on this
# shared host, the actual cause of an early flaky FAIL here).
export BUILD_STATE_DIR="$T/state"
mkdir -p "$BUILD_STATE_DIR"
export GATE_LAUNCH_EXTEND_GATE="$FIXDIR/extend-gate.sh"
export GATE_LAUNCH_MAIN_VERDICT_PIN_GATE="$FAKE_PIN_GATE"
export GATE_LAUNCH_SYSTEMD_RUN="$FIXDIR/systemd-run"
export GATE_LAUNCH_SYSTEMCTL="$FIXDIR/systemctl"
export GATE_LAUNCH_BURST_ENV="$T/no-such-wm-burst-env"
export GATE_LAUNCH_CARGO_ROUTE_LIB="$T/no-such-cargo-route.sh"
export GATE_LAUNCH_JOURNAL="$T/gate-launch-journal.md"
export FAKE_EXTEND_GATE_LOG="$T/fake-extend-gate-args.log"

# --wait is deliberately NOT used below: its polling loop reads the exact
# systemd-run/systemctl fake fixture's timing (already covered by
# gate-launch-selftest.sh's own AC(b)/AC(e2) — not this test's concern),
# and is prone to a real narrow race between "systemd-run returns" and
# "the backgrounded fake unit writes state=active" under host load (this
# box runs many parallel build agents). What THIS test is actually about
# — which binary --pinned-landing routes the unit's exec to — is fully
# provable by the async launch call succeeding plus a short poll of the
# fake binaries' own argv logs, so that's what's checked instead.
poll_for() { # <label> <file> <grep-pattern>
  local i
  for i in $(seq 1 50); do
    grep -qF "$3" "$2" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

echo "=== AC-launch-1: --pinned-landing execs main-verdict-pin-gate.sh, not extend-gate.sh ==="
SLUG="mainpin-launch-fixture"
out="$T/launch1.out"
"$GATE_LAUNCH" "$REPO" --head "$HEAD_SHA" --scope main --slug "$SLUG" --pinned-landing >"$out" 2>&1
rc=$?
cat "$out"
expect "AC-launch-1: launch call itself exits 0" "[ $rc -eq 0 ]"
poll_for "AC-launch-1" "$PIN_GATE_LOG" "argv: $REPO $SLUG"
expect "AC-launch-1: main-verdict-pin-gate.sh WAS called with <repo> <slug>" \
  "grep -qF \"argv: $REPO $SLUG\" \"$PIN_GATE_LOG\""
expect "AC-launch-1: extend-gate.sh was NEVER called directly" \
  "[ ! -f \"$FAKE_EXTEND_GATE_LOG\" ]"

echo "=== AC-launch-2: --pinned-landing + --scope branch is refused (main-scope only) ==="
out2="$T/launch2.out"
"$GATE_LAUNCH" "$REPO" --head "$HEAD_SHA" --scope branch --slug "mainpin-launch-fixture-2" --pinned-landing >"$out2" 2>&1
rc2=$?
cat "$out2"
expect "AC-launch-2: exits non-zero" "[ $rc2 -ne 0 ]"
expect "AC-launch-2: names --pinned-landing in the refusal" "grep -q -- '--pinned-landing' \"$out2\""
expect "AC-launch-2: no unit was launched for it (no new fake-pin-gate argv line)" \
  "! grep -qF 'mainpin-launch-fixture-2' \"$PIN_GATE_LOG\""

echo "=== AC-launch-3: without --pinned-landing, extend-gate.sh is still the exec target ==="
SLUG3="mainpin-launch-fixture-3"
out3="$T/launch3.out"
"$GATE_LAUNCH" "$REPO" --head "$HEAD_SHA" --scope main --slug "$SLUG3" >"$out3" 2>&1
rc3=$?
cat "$out3"
expect "AC-launch-3: launch call itself exits 0" "[ $rc3 -eq 0 ]"
poll_for "AC-launch-3" "$FAKE_EXTEND_GATE_LOG" "slug=$SLUG3 head=$HEAD_SHA scope=main"
expect "AC-launch-3: extend-gate.sh WAS called (default path unchanged)" \
  "grep -q \"slug=$SLUG3 head=$HEAD_SHA scope=main\" \"$FAKE_EXTEND_GATE_LOG\""
expect "AC-launch-3: main-verdict-pin-gate.sh was NOT called for this slug" \
  "! grep -qF \"argv: $REPO $SLUG3\" \"$PIN_GATE_LOG\""

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "mainpin_gate_launch_pinned_wiring: ALL PASS"
  exit 0
else
  echo "mainpin_gate_launch_pinned_wiring: assertion(s) FAILED"
  exit 1
fi
