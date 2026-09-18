#!/usr/bin/env bash
# governor_ac7_units_ship_disabled.sh —
# PRD-dream-depth-governor AC7: given the shipped unit files, when
# installed on RedBaron, then `systemctl --user is-enabled
# dream-governor.timer` reports `disabled` until the operator enables it.
# Static source check (a selftest should not install units onto the real
# host's systemd user dir): asserts the units ship in the repo and that
# nothing in install.sh references dream-governor, so the only way it
# becomes enabled is the operator's own README.md one-liner -- exactly
# like claude-build.timer. Mirrors dream-governor-selftest.sh's AC7 block.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

fail=0
if [ ! -f "$HERE/../systemd/dream-governor.timer" ]; then
  echo "FAIL AC7: systemd/dream-governor.timer missing"
  fail=1
fi
if [ ! -f "$HERE/../systemd/dream-governor.service" ]; then
  echo "FAIL AC7: systemd/dream-governor.service missing"
  fail=1
fi
if grep -q "dream-governor" "$HERE/../install.sh"; then
  echo "FAIL AC7: install.sh references dream-governor (would auto-enable it)"
  fail=1
fi
if ! grep -q "dream-governor.timer" "$HERE/../README.md"; then
  echo "FAIL AC7: README.md missing the operator enable one-liner"
  fail=1
fi
[ "$fail" -eq 0 ] && echo "ok  AC7: units ship in the repo, install.sh never auto-enables, README carries the operator enable one-liner"
exit "$fail"
