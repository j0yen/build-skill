#!/usr/bin/env bash
# unitlive-selftest.sh — exercises loop-liveness.sh and loop-arm.sh against
# a fake systemctl and scratch state/units files (PRD-buildloop-unit-
# liveness, test_prefix: unitlive). Never touches a real systemd unit.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVENESS="$HERE/loop-liveness.sh"
ARM="$HERE/loop-arm.sh"
FAKE="$HERE/../tests/fixtures/unitlive-fake"
[ -x "$LIVENESS" ] || { echo "FAIL: loop-liveness.sh missing/not executable" >&2; exit 1; }
[ -x "$ARM" ] || { echo "FAIL: loop-arm.sh missing/not executable" >&2; exit 1; }
[ -x "$FAKE/systemctl" ] || { echo "FAIL: fake systemctl fixture missing" >&2; exit 1; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/unitlive-selftest.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

fail=0
ok()  { echo "ok  $1"; }
bad() { echo "FAIL $1" >&2; fail=1; }

UNITS_FILE="$ROOT/loop-units.txt"
cat > "$UNITS_FILE" <<'EOF'
# comment line, and a blank line follow

TestHost unit-a.timer
TestHost unit-b.timer
TestHost unit-c.timer
TestHost unit-d.timer
TestHost unit-e.timer
TestHost unit-f.timer
EOF

STATES="$ROOT/states.txt"
STATE_DIR="$ROOT/state"
export PATH="$FAKE:$PATH"
export LOOP_UNITS_FILE="$UNITS_FILE"
export LOOP_LIVENESS_HOST="TestHost"
export LOOP_LIVENESS_STATE_DIR="$STATE_DIR"
export FAKE_SYSTEMCTL_STATES="$STATES"
export FAKE_SYSTEMCTL_LOG="$ROOT/systemctl.log"

reset_run() { rm -rf "$STATE_DIR" "$ROOT/systemctl.log"; : > "$STATES"; }

# ------------------------------------------------------------- unitlive_ac1
# One of six declared units reported inactive -> per-unit lines, one WARN
# line, exit 1.
reset_run
printf 'unit-c.timer=inactive\n' > "$STATES"
out="$("$LIVENESS" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] \
   && grep -qxF 'unit=unit-c.timer state=inactive' <<<"$out" \
   && [ "$(grep -c '^unit=' <<<"$out")" -eq 6 ] \
   && echo "$out" | grep -qE '^LIVENESS WARN unit=unit-c\.timer inactive_since=[0-9TZ:-]+$'; then
  ok "unitlive_ac1: one inactive unit -> per-unit lines + one WARN line, exit 1"
else
  bad "unitlive_ac1: got rc=$rc out=$out"
fi

# ------------------------------------------------------------- unitlive_ac2
# All six active -> LIVENESS ok n=6, exit 0, no state file lines left.
reset_run
out="$("$LIVENESS" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qxF 'LIVENESS ok n=6' <<<"$out" \
   && [ ! -s "$STATE_DIR/loop-liveness.state" ]; then
  ok "unitlive_ac2: all active -> LIVENESS ok n=6, exit 0, empty state file"
else
  bad "unitlive_ac2: got rc=$rc out=$out state=$(cat "$STATE_DIR/loop-liveness.state" 2>/dev/null)"
fi

# ------------------------------------------------------------- unitlive_ac3
# Two consecutive inactive runs -> digest names the unit + first-seen time;
# after only one run, digest is empty.
reset_run
printf 'unit-d.timer=inactive\n' > "$STATES"
"$LIVENESS" >/dev/null 2>&1  # run 1
digest1="$("$LIVENESS" --digest 2>&1)"; drc1=$?
if [ -z "$digest1" ] && [ "$drc1" -eq 0 ]; then
  ok "unitlive_ac3a: after one inactive run, digest is empty"
else
  bad "unitlive_ac3a: expected empty digest after 1 run, got rc=$drc1 out=$digest1"
fi
"$LIVENESS" >/dev/null 2>&1  # run 2 (still inactive)
digest2="$("$LIVENESS" --digest 2>&1)"; drc2=$?
first_seen="$(awk '$1=="unit-d.timer"{print $2}' "$STATE_DIR/loop-liveness.state")"
if [ "$drc2" -eq 1 ] && grep -qxF "LIVENESS WARN unit=unit-d.timer inactive_since=$first_seen" <<<"$digest2"; then
  ok "unitlive_ac3b: after two consecutive inactive runs, digest names unit + first-seen time"
else
  bad "unitlive_ac3b: got rc=$drc2 out=$digest2 first_seen=$first_seen"
fi

# ------------------------------------------------------------- unitlive_ac5
# loop-arm.sh: argv log shows enable --now for exactly the six declared
# units and nothing else; with one unit still inactive it exits non-zero.
reset_run
printf 'unit-f.timer=inactive\n' > "$STATES"
arm_out="$("$ARM" 2>&1)"; arm_rc=$?
enable_lines="$(grep -c ' enable --now ' "$ROOT/systemctl.log")"
enable_argv="$(grep ' enable --now ' "$ROOT/systemctl.log" | head -n1)"
expect_argv='--user enable --now unit-a.timer unit-b.timer unit-c.timer unit-d.timer unit-e.timer unit-f.timer'
if [ "$enable_lines" -eq 1 ] && [ "$enable_argv" = "$expect_argv" ] && [ "$arm_rc" -ne 0 ] \
   && grep -qF 'LIVENESS WARN unit=unit-f.timer' <<<"$arm_out"; then
  ok "unitlive_ac5: loop-arm enables exactly the declared six, still-inactive unit -> non-zero exit"
else
  bad "unitlive_ac5: got rc=$arm_rc enable_lines=$enable_lines argv=[$enable_argv] out=$arm_out"
fi

# All active this time -> loop-arm exits 0.
reset_run
arm_out2="$("$ARM" 2>&1)"; arm_rc2=$?
if [ "$arm_rc2" -eq 0 ] && grep -qF 'all declared units active' <<<"$arm_out2"; then
  ok "unitlive_ac5b: loop-arm exits 0 once every declared unit is active"
else
  bad "unitlive_ac5b: got rc=$arm_rc2 out=$arm_out2"
fi

# ------------------------------------------------------------- unitlive_ac6
# A host with no lines in loop-units.txt -> LIVENESS unknown host=<h>, exit 0.
reset_run
out="$(LOOP_LIVENESS_HOST=nobody-declared-this-host "$LIVENESS" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "LIVENESS unknown host=nobody-declared-this-host" ]; then
  ok "unitlive_ac6: undeclared host -> LIVENESS unknown, exit 0"
else
  bad "unitlive_ac6: got rc=$rc out=$out"
fi

# ------------------------------------------------------------- unitlive nfr
# Under 1s for six units, no model calls (pure subprocess timing check).
reset_run
t0=$(date +%s%N)
"$LIVENESS" >/dev/null 2>&1
t1=$(date +%s%N)
elapsed_ms=$(( (t1 - t0) / 1000000 ))
if [ "$elapsed_ms" -lt 1000 ]; then
  ok "unitlive_nfr: six-unit check completed in ${elapsed_ms}ms (<1000ms)"
else
  bad "unitlive_nfr: took ${elapsed_ms}ms, wanted <1000ms"
fi

exit $fail
