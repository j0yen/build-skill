#!/usr/bin/env bash
# lane-defer.sh — ExecCondition for claude-build.service on secondary lanes.
#
# Exit 0  => this lane may fire its tick.
# Exit 1  => defer: a preferred lane is reachable and has its lane enabled,
#            so this host stays idle (systemd treats ExecCondition exit 1
#            as "skip the unit, not a failure").
#
# Preferred lanes come from BUILD_LANE_PREFER (space-separated hostnames /
# ssh aliases, most preferred first; default "ryzen7"). A host that is
# itself in the list never defers. RedBaron never defers either (it is the
# only lane that can take cargo-bound PRDs).
#
# Joe, 2026-09-06: "route work there [ryzen7] before carbon."
set -uo pipefail
PREFER="${BUILD_LANE_PREFER:-ryzen7}"
LOG="${CLAUDE_BUILD_LOG:-$HOME/brain/journal/build-auto.log}"
me="$(hostname)"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
logline() { echo "$(ts) lane-defer: $*" >> "$LOG"; }

[ "$me" = "RedBaron" ] && exit 0
for lane in $PREFER; do
  [ "$lane" = "$me" ] && exit 0
done

for lane in $PREFER; do
  state="$(timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=6 "$lane" \
    'systemctl --user is-active claude-build.path 2>/dev/null' 2>/dev/null)"
  if [ "$state" = "active" ]; then
    logline "defer: $lane lane is up (claude-build.path active); $me stays idle"
    exit 1
  fi
done
logline "proceed: no preferred lane ($PREFER) reachable with an active lane"
exit 0
