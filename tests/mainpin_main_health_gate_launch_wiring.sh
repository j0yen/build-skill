#!/usr/bin/env bash
# tests/mainpin_main_health_gate_launch_wiring.sh — PRD-build-main-verdict-
# pinned-to-landing R6/AC8: the tick's bare-HEAD "is main green now"
# question must reach extend-gate.sh with --main-health, --scope main,
# and --slug defaulted to the "main-health" sentinel — unlike
# --pinned-landing (which reroutes the unit's exec target entirely to
# main-verdict-pin-gate.sh), --main-health is a plain passthrough flag:
# gate-launch.sh still execs extend-gate.sh directly, just with one more
# flag on the command line.
#
# Reuses gate-launch-selftest.sh's fake systemd-run/systemctl pair and
# fixtures/gatelaunch-fake/extend-gate.sh (now argv-echoing
# --main-health too, see that fixture's own header) — same technique as
# mainpin_gate_launch_pinned_wiring.sh.
#
#   AC-mh-1: `gate-launch.sh <repo> --head <N> --scope main --main-health
#     --wait` (no explicit --slug) execs extend-gate.sh with
#     `--slug main-health ... --main-health` — the sentinel default from
#     both gate-launch.sh's own arg parsing AND main-health-gate.sh's
#     thin wrapper (checked separately below), never left empty.
#   AC-mh-2: `--main-health` with `--scope branch` is a usage error
#     (R6: main-health is main-scope only) — refused before any unit is
#     launched.
#   AC-mh-3: `--main-health` + `--pinned-landing` together is a usage
#     error (mutually exclusive) — refused before any unit is launched.
#   AC-mh-4: main-health-gate.sh (the tick's own convenience entrypoint)
#     resolves <repo>'s current HEAD itself and passes it through to
#     gate-launch.sh — a caller never has to run `git rev-parse HEAD`
#     by hand.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
FIXDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/fixtures/gatelaunch-fake" && pwd -P)"
GATE_LAUNCH="$HERE/gate-launch.sh"
MAIN_HEALTH_GATE="$HERE/main-health-gate.sh"
[ -x "$GATE_LAUNCH" ] || { echo "selftest: $GATE_LAUNCH not executable" >&2; exit 2; }
[ -x "$MAIN_HEALTH_GATE" ] || { echo "selftest: $MAIN_HEALTH_GATE not executable" >&2; exit 2; }
for f in "$FIXDIR/systemd-run" "$FIXDIR/systemctl" "$FIXDIR/extend-gate.sh"; do
  [ -x "$f" ] || { echo "selftest: missing/non-executable: $f" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/mainpin-main-health-launch.XXXXXX")"
trap '[ -n "${MAINPIN_MAIN_HEALTH_LAUNCH_KEEP:-}" ] || rm -rf "$T"' EXIT

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
export MAIN_HEALTH_GATE_GATE_LAUNCH="$GATE_LAUNCH"
export GATE_LAUNCH_SYSTEMD_RUN="$FIXDIR/systemd-run"
export GATE_LAUNCH_SYSTEMCTL="$FIXDIR/systemctl"
export GATE_LAUNCH_BURST_ENV="$T/no-such-wm-burst-env"
export GATE_LAUNCH_CARGO_ROUTE_LIB="$T/no-such-cargo-route.sh"
export GATE_LAUNCH_JOURNAL="$T/gate-launch-journal.md"
export FAKE_EXTEND_GATE_LOG="$T/fake-extend-gate-args.log"

poll_for() { # <file> <grep-pattern>
  local i
  for i in $(seq 1 50); do
    grep -qF "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

echo "=== AC-mh-1: bare --main-health (no --slug) defaults to slug=main-health, forwards the flag ==="
out1="$T/launch1.out"
"$GATE_LAUNCH" "$REPO" --head "$HEAD_SHA" --scope main --main-health >"$out1" 2>&1
rc1=$?
cat "$out1"
expect "AC-mh-1: launch call itself exits 0" "[ $rc1 -eq 0 ]"
poll_for "$FAKE_EXTEND_GATE_LOG" "slug=main-health head=$HEAD_SHA scope=main main_health=1"
expect "AC-mh-1: extend-gate.sh WAS called with slug=main-health ... main_health=1" \
  "grep -qF 'slug=main-health head=$HEAD_SHA scope=main main_health=1' '$FAKE_EXTEND_GATE_LOG'"

echo "=== AC-mh-2: --main-health + --scope branch is refused (main-scope only) ==="
out2="$T/launch2.out"
"$GATE_LAUNCH" "$REPO" --head "$HEAD_SHA" --scope branch --slug whatever --main-health >"$out2" 2>&1
rc2=$?
cat "$out2"
expect "AC-mh-2: exits non-zero" "[ $rc2 -ne 0 ]"
expect "AC-mh-2: names --main-health in the refusal" "grep -q -- '--main-health' '$out2'"

echo "=== AC-mh-3: --main-health + --pinned-landing together is refused ==="
out3="$T/launch3.out"
"$GATE_LAUNCH" "$REPO" --head "$HEAD_SHA" --scope main --slug whatever --main-health --pinned-landing >"$out3" 2>&1
rc3=$?
cat "$out3"
expect "AC-mh-3: exits non-zero" "[ $rc3 -ne 0 ]"
expect "AC-mh-3: names the mutual exclusion" "grep -qi 'mutually exclusive' '$out3'"

echo "=== AC-mh-4: main-health-gate.sh resolves HEAD itself and forwards it ==="
: > "$FAKE_EXTEND_GATE_LOG"
out4="$T/launch4.out"
"$MAIN_HEALTH_GATE" "$REPO" >"$out4" 2>&1
rc4=$?
cat "$out4"
expect "AC-mh-4: main-health-gate.sh itself exits 0" "[ $rc4 -eq 0 ]"
poll_for "$FAKE_EXTEND_GATE_LOG" "slug=main-health head=$HEAD_SHA scope=main main_health=1"
expect "AC-mh-4: extend-gate.sh saw the repo's own current HEAD ($HEAD_SHA), never asked by the caller" \
  "grep -qF 'slug=main-health head=$HEAD_SHA scope=main main_health=1' '$FAKE_EXTEND_GATE_LOG'"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "mainpin_main_health_gate_launch_wiring: ALL PASS"
  exit 0
else
  echo "mainpin_main_health_gate_launch_wiring: assertion(s) FAILED"
  exit 1
fi
